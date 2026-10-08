import Foundation
import CryptoKit
import Combine
import SweetCookieKit
import AgentMeterCore

struct MacPerplexityProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct MacPerplexityCookies: Sendable {
    let header: String
}

protocol MacPerplexityCookieImporting: Sendable {
    func profiles() -> [MacPerplexityProfile]
    func cookies(profileID: String, allowInteraction: Bool) throws -> MacPerplexityCookies
}

struct MacPerplexityChromeImporter: MacPerplexityCookieImporting {
    private let client = BrowserCookieClient()

    func profiles() -> [MacPerplexityProfile] {
        let profiles = client.stores(for: .chrome).map(\.profile)
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
            .map { MacPerplexityProfile(id: $0.id, name: $0.name) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    func cookies(profileID: String, allowInteraction: Bool) throws -> MacPerplexityCookies {
        let read = {
            let stores = client.stores(for: .chrome).filter { $0.profile.id == profileID }
                .sorted { $0.kind == .network && $1.kind != .network }
            guard !stores.isEmpty else { throw PerplexityFailure.missingCookie }
            let query = BrowserCookieQuery(domains: ["www.perplexity.ai", "perplexity.ai"],
                                           domainMatch: .exact, includeExpired: false)
            for store in stores {
                let records = try client.records(matching: query, in: store)
                let billing = Self.header(records, path: "/rest/billing/credits")
                if !billing.isEmpty {
                    return MacPerplexityCookies(header: try PerplexityCookieHeader.normalize(billing))
                }
            }
            throw PerplexityFailure.missingCookie
        }
        do {
            return try MacBrowserCookieAccess.read(allowInteraction: allowInteraction, read)
        } catch let failure as PerplexityFailure {
            throw failure
        } catch let error as BrowserCookieError {
            switch error {
            case .accessDenied: throw PerplexityFailure.accessDenied
            case .notFound: throw PerplexityFailure.missingCookie
            case .loadFailed: throw PerplexityFailure.unavailable
            }
        } catch {
            throw PerplexityFailure.accessDenied
        }
    }

    static func header(_ records: [BrowserCookieRecord], path: String, now: Date = Date()) -> String {
        records.enumerated().filter { _, record in
            let domain = record.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = record.scope == .hostOnly
                ? domain == "www.perplexity.ai"
                : (domain == "www.perplexity.ai" || domain == "perplexity.ai")
            let matchesPath = record.path == path || (path.hasPrefix(record.path)
                && (record.path.hasSuffix("/") || path.dropFirst(record.path.count).first == "/"))
            let sessionName = PerplexityCookieHeader.sessionNames.contains { name in
                record.name.lowercased() == name.lowercased() || record.name.lowercased().hasPrefix(name.lowercased() + ".")
            }
            return sessionName && matchesDomain && matchesPath && (record.expires == nil || record.expires! > now)
        }.sorted {
            $0.element.path.count == $1.element.path.count
                ? $0.offset < $1.offset : $0.element.path.count > $1.element.path.count
        }.map { "\($0.element.name)=\($0.element.value)" }.joined(separator: "; ")
    }
}

protocol MacPerplexityCredentialStoring: Sendable {
    func read(allowInteraction: Bool) throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

struct MacPerplexityCredentialStore: MacPerplexityCredentialStoring {
    func read(allowInteraction: Bool) throws -> String? {
        try MacBrowserCookieAccess.read(allowInteraction: allowInteraction) {
            try ProviderCredentialStore.read(kind: .perplexityCookie, allowInteraction: allowInteraction)
        }
    }
    func save(_ value: String) throws { try ProviderCredentialStore.save(value, kind: .perplexityCookie) }
    func delete() throws { try ProviderCredentialStore.delete(kind: .perplexityCookie) }
}

/// Owns account selection and request generations. Status getters never read browser secrets.
@MainActor
final class MacPerplexityController: ObservableObject {
    @Published private(set) var usage: PerplexityUsage? {
        didSet { cloudSync.update(PerplexityDisplaySnapshot(usage ?? .init(), paused: !enabled)) }
    }
    let cloudSync: MacPerplexitySyncController
    @Published private(set) var profiles: [MacPerplexityProfile] = []
    @Published private(set) var source: PerplexityCookieSource
    @Published private(set) var profileID: String
    @Published private(set) var enabled: Bool
    @Published private(set) var checking = false
    @Published private(set) var hasManualCookie = false
    @Published private(set) var storageFailed = false

    private let defaults: UserDefaults
    private let importer: any MacPerplexityCookieImporting
    private let credentials: any MacPerplexityCredentialStoring
    private let adapter: PerplexityCreditsAdapter
    private var generation: UInt64 = 0
    // Imported cookies are never written to disk or included in diagnostics.
    private var automaticCookies: MacPerplexityCookies?
    // Retain only an in-memory fingerprint across failures to detect a replaced session.
    private var credentialFingerprint: SHA256.Digest?

    init(defaults: UserDefaults = .standard,
         importer: any MacPerplexityCookieImporting = MacPerplexityChromeImporter(),
         credentials: any MacPerplexityCredentialStoring = MacPerplexityCredentialStore(),
         adapter: PerplexityCreditsAdapter = PerplexityCreditsAdapter()) {
        self.defaults = defaults
        self.cloudSync = MacPerplexitySyncController(defaults: defaults)
        self.importer = importer
        self.credentials = credentials
        self.adapter = adapter
        source = PerplexityPreferences.source(defaults: defaults)
        profileID = defaults.string(forKey: PerplexityPreferences.profileKey) ?? ""
        enabled = ManualProviderPreferences.isEnabled(.perplexity, credentialExists: false, defaults: defaults)
    }

    var state: ProviderConnectionState {
        if storageFailed { return .storageFailure }
        if checking { return .checking }
        if !enabled { return .disabled }
        guard let usage else { return .unconfigured }
        if usage.failure == .authExpired { return .invalidCredential }
        if let failure = usage.failure {
            return .pendingVerification(failure.staleReason)
        }
        return usage.confidence == .fresh ? .connected : .unconfigured
    }

    /// Metadata discovery does not decrypt cookies and is performed only on explicit settings interaction.
    func loadSettings() async {
        guard enabled else { return }
        let settingsGeneration = generation
        if source == .auto && enabled {
            let importer = self.importer
            let discovered = await Task.detached { importer.profiles() }.value
            guard generation == settingsGeneration else { return }
            profiles = discovered
            if profileID.isEmpty {
                profileID = Self.defaultProfile(discovered)?.id ?? ""
                if !profileID.isEmpty { defaults.set(profileID, forKey: PerplexityPreferences.profileKey) }
            }
        }
        do {
            hasManualCookie = try credentials.read(allowInteraction: false)?.isEmpty == false
            storageFailed = false
        } catch { storageFailed = true }
    }

    static func defaultProfile(_ profiles: [MacPerplexityProfile]) -> MacPerplexityProfile? {
        profiles.first(where: { $0.name == "Default" })
            ?? profiles.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.first
    }

    private func invalidate() {
        generation &+= 1
        automaticCookies = nil
        credentialFingerprint = nil
        usage = nil
        checking = false
        storageFailed = false
    }

    func setSource(_ value: PerplexityCookieSource) {
        guard source != value else { return }
        invalidate()
        source = value
        defaults.set(value.rawValue, forKey: PerplexityPreferences.sourceKey)
    }

    func setProfile(_ value: String) {
        guard profileID != value else { return }
        invalidate()
        profileID = value
        defaults.set(value, forKey: PerplexityPreferences.profileKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        ManualProviderPreferences.setEnabled(value, for: .perplexity, defaults: defaults)
        generation &+= 1
        checking = false
        automaticCookies = nil
        cloudSync.update(PerplexityDisplaySnapshot(usage ?? .init(), paused: !value))
    }

    func saveManualCookie(_ input: String) throws {
        let cookie = try PerplexityCookieHeader.normalize(input)
        do { try credentials.save(cookie) }
        catch { storageFailed = true; throw PerplexityFailure.accessDenied }
        invalidate()
        hasManualCookie = true
    }

    func deleteManualCookie() throws {
        do { try credentials.delete() }
        catch { storageFailed = true; throw PerplexityFailure.accessDenied }
        hasManualCookie = false
        if source == .manual { invalidate(); setEnabled(false) }
    }

    func collect(allowInteraction: Bool = false) async {
        guard enabled else { return }
        // Do not let a timer supersede a user-triggered Keychain prompt or another refresh.
        if checking && !allowInteraction { return }
        generation &+= 1
        let requestGeneration = generation
        checking = true
        defer { if requestGeneration == generation { checking = false } }
        var previous = usage ?? .init()
        let cookies: MacPerplexityCookies
        do {
            if source == .manual {
                guard let cookie = try credentials.read(allowInteraction: allowInteraction), !cookie.isEmpty else { throw PerplexityFailure.missingCookie }
                cookies = .init(header: try PerplexityCookieHeader.normalize(cookie))
                hasManualCookie = true
            } else {
                let importer = self.importer
                if profileID.isEmpty {
                    let discovered = await Task.detached { importer.profiles() }.value
                    guard generation == requestGeneration, enabled else { return }
                    profiles = discovered
                    guard let profile = Self.defaultProfile(discovered) else { throw PerplexityFailure.missingCookie }
                    profileID = profile.id
                    defaults.set(profile.id, forKey: PerplexityPreferences.profileKey)
                }
                let selected = profileID
                cookies = try await Task.detached {
                    try importer.cookies(profileID: selected, allowInteraction: allowInteraction)
                }.value
                guard generation == requestGeneration, enabled else { return }
                automaticCookies = cookies
            }
        } catch {
            guard generation == requestGeneration, enabled else { return }
            automaticCookies = nil
            usage = previous.degraded((error as? PerplexityFailure) ?? .accessDenied)
            return
        }
        let fingerprint = SHA256.hash(data: Data(cookies.header.utf8))
        if let credentialFingerprint, credentialFingerprint != fingerprint {
            // The same Chrome profile may now belong to a different account. A failed
            // new request must not retain or synchronize the former account's facts.
            usage = nil
            previous = .init()
        }
        credentialFingerprint = fingerprint
        let fetched = await adapter.fetch(cookie: cookies.header, previous: previous)
        guard generation == requestGeneration, enabled else { return }
        usage = fetched
        if fetched.failure == .authExpired { automaticCookies = nil }
    }
}

/// Diagnostics exclude credit amounts, credentials, profiles and raw errors.
enum MacPerplexityDiagnostics {
    static func statuses(for usage: PerplexityUsage?) -> [AgentMeterDiagnosticReport.LocalServiceStatus] {
        guard let usage else { return [] }
        return [.init(service: "Perplexity account credits", confidence: usage.confidence,
                      staleReason: usage.failure?.staleReason, updatedAt: usage.updatedAt ?? .distantPast)]
    }
}
