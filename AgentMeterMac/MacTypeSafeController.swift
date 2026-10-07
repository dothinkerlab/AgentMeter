import Foundation
import Combine
import SweetCookieKit
import AgentMeterCore

struct MacTypeSafeProfile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct MacTypeSafeCookies: Sendable {
    let billing: String
    let usage: String
}

protocol MacTypeSafeCookieImporting: Sendable {
    func profiles() -> [MacTypeSafeProfile]
    func cookies(profileID: String, allowInteraction: Bool) throws -> MacTypeSafeCookies
}

struct MacTypeSafeChromeImporter: MacTypeSafeCookieImporting {
    private let client = BrowserCookieClient()

    func profiles() -> [MacTypeSafeProfile] {
        let profiles = client.stores(for: .chrome).map(\.profile)
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
            .map { MacTypeSafeProfile(id: $0.id, name: $0.name) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    func cookies(profileID: String, allowInteraction: Bool) throws -> MacTypeSafeCookies {
        let read = {
            let stores = client.stores(for: .chrome).filter { $0.profile.id == profileID }
                .sorted { $0.kind == .network && $1.kind != .network }
            guard !stores.isEmpty else { throw TypeSafeFailure.missingCookie }
            let query = BrowserCookieQuery(domains: ["console.typesafe.ai", "typesafe.ai"],
                                           domainMatch: .exact, includeExpired: false)
            for store in stores {
                let records = try client.records(matching: query, in: store)
                let billing = Self.header(records, path: "/settings/billing")
                if !billing.isEmpty {
                    return MacTypeSafeCookies(billing: try TypeSafeCookieHeader.normalize(billing),
                                              usage: Self.header(records, path: "/api/usage"))
                }
            }
            throw TypeSafeFailure.missingCookie
        }
        do {
            if allowInteraction { return try read() }
            return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(read)
        } catch let failure as TypeSafeFailure {
            throw failure
        } catch let error as BrowserCookieError {
            switch error {
            case .accessDenied: throw TypeSafeFailure.accessDenied
            case .notFound: throw TypeSafeFailure.missingCookie
            case .loadFailed: throw TypeSafeFailure.unavailable
            }
        } catch {
            throw TypeSafeFailure.accessDenied
        }
    }

    static func header(_ records: [BrowserCookieRecord], path: String, now: Date = Date()) -> String {
        records.enumerated().filter { _, record in
            let domain = record.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = record.scope == .hostOnly
                ? domain == "console.typesafe.ai"
                : (domain == "console.typesafe.ai" || domain == "typesafe.ai")
            let matchesPath = record.path == path || (path.hasPrefix(record.path)
                && (record.path.hasSuffix("/") || path.dropFirst(record.path.count).first == "/"))
            return matchesDomain && matchesPath && (record.expires == nil || record.expires! > now)
        }.sorted {
            $0.element.path.count == $1.element.path.count
                ? $0.offset < $1.offset : $0.element.path.count > $1.element.path.count
        }.map { "\($0.element.name)=\($0.element.value)" }.joined(separator: "; ")
    }
}

protocol MacTypeSafeCredentialStoring: Sendable {
    func read(allowInteraction: Bool) throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

struct MacTypeSafeCredentialStore: MacTypeSafeCredentialStoring {
    func read(allowInteraction: Bool) throws -> String? { try ProviderCredentialStore.read(kind: .typesafeCookie, allowInteraction: allowInteraction) }
    func save(_ value: String) throws { try ProviderCredentialStore.save(value, kind: .typesafeCookie) }
    func delete() throws { try ProviderCredentialStore.delete(kind: .typesafeCookie) }
}

/// Owns account selection and request generations. Status getters never read browser secrets.
@MainActor
final class MacTypeSafeController: ObservableObject {
    @Published private(set) var usage: TypeSafeUsage? {
        didSet { cloudSync.update(TypeSafeDisplaySnapshot(usage ?? .init(), paused: !enabled)) }
    }
    let cloudSync: MacTypeSafeSyncController
    @Published private(set) var profiles: [MacTypeSafeProfile] = []
    @Published private(set) var source: TypeSafeCookieSource
    @Published private(set) var profileID: String
    @Published private(set) var enabled: Bool
    @Published private(set) var checking = false
    @Published private(set) var hasManualCookie = false
    @Published private(set) var storageFailed = false

    private let defaults: UserDefaults
    private let importer: any MacTypeSafeCookieImporting
    private let credentials: any MacTypeSafeCredentialStoring
    private let adapter: TypeSafeBillingAdapter
    private var generation: UInt64 = 0
    // Imported cookies are never written to disk or included in diagnostics.
    private var automaticCookies: MacTypeSafeCookies?

    init(defaults: UserDefaults = .standard,
         importer: any MacTypeSafeCookieImporting = MacTypeSafeChromeImporter(),
         credentials: any MacTypeSafeCredentialStoring = MacTypeSafeCredentialStore(),
         adapter: TypeSafeBillingAdapter = TypeSafeBillingAdapter()) {
        self.defaults = defaults
        self.cloudSync = MacTypeSafeSyncController(defaults: defaults)
        self.importer = importer
        self.credentials = credentials
        self.adapter = adapter
        source = TypeSafePreferences.source(defaults: defaults)
        profileID = defaults.string(forKey: TypeSafePreferences.profileKey) ?? ""
        enabled = ManualProviderPreferences.isEnabled(.typesafe, credentialExists: false, defaults: defaults)
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
        let settingsGeneration = generation
        if source == .auto && enabled {
            let importer = self.importer
            let discovered = await Task.detached { importer.profiles() }.value
            guard generation == settingsGeneration else { return }
            profiles = discovered
            if profileID.isEmpty {
                profileID = Self.defaultProfile(discovered)?.id ?? ""
                if !profileID.isEmpty { defaults.set(profileID, forKey: TypeSafePreferences.profileKey) }
            }
        }
        do {
            hasManualCookie = try credentials.read(allowInteraction: false)?.isEmpty == false
            storageFailed = false
        } catch { storageFailed = true }
    }

    static func defaultProfile(_ profiles: [MacTypeSafeProfile]) -> MacTypeSafeProfile? {
        profiles.first(where: { $0.name == "Default" })
            ?? profiles.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }.first
    }

    private func invalidate() {
        generation &+= 1
        automaticCookies = nil
        usage = nil
        checking = false
        storageFailed = false
    }

    func setSource(_ value: TypeSafeCookieSource) {
        guard source != value else { return }
        invalidate()
        source = value
        defaults.set(value.rawValue, forKey: TypeSafePreferences.sourceKey)
    }

    func setProfile(_ value: String) {
        guard profileID != value else { return }
        invalidate()
        profileID = value
        defaults.set(value, forKey: TypeSafePreferences.profileKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        ManualProviderPreferences.setEnabled(value, for: .typesafe, defaults: defaults)
        if !value {
            let previous = usage
            invalidate()
            cloudSync.update(TypeSafeDisplaySnapshot(previous ?? .init(), paused: true))
        }
    }

    func saveManualCookie(_ input: String) throws {
        let cookie = try TypeSafeCookieHeader.normalize(input)
        do { try credentials.save(cookie) }
        catch { storageFailed = true; throw TypeSafeFailure.accessDenied }
        invalidate()
        hasManualCookie = true
    }

    func deleteManualCookie() throws {
        do { try credentials.delete() }
        catch { storageFailed = true; throw TypeSafeFailure.accessDenied }
        hasManualCookie = false
        if source == .manual { setEnabled(false) }
    }

    func collect(allowInteraction: Bool = false) async {
        guard enabled else { return }
        // Do not let a timer supersede a user-triggered Keychain prompt or another refresh.
        if checking && !allowInteraction { return }
        generation &+= 1
        let requestGeneration = generation
        checking = true
        defer { if requestGeneration == generation { checking = false } }
        let previous = usage ?? .init()
        let cookies: MacTypeSafeCookies
        do {
            if source == .manual {
                guard let cookie = try credentials.read(allowInteraction: allowInteraction), !cookie.isEmpty else { throw TypeSafeFailure.missingCookie }
                cookies = .init(billing: try TypeSafeCookieHeader.normalize(cookie), usage: cookie)
            } else {
                let importer = self.importer
                if profileID.isEmpty {
                    let discovered = await Task.detached { importer.profiles() }.value
                    guard generation == requestGeneration, enabled else { return }
                    profiles = discovered
                    guard let profile = Self.defaultProfile(discovered) else { throw TypeSafeFailure.missingCookie }
                    profileID = profile.id
                    defaults.set(profile.id, forKey: TypeSafePreferences.profileKey)
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
            usage = previous.degraded((error as? TypeSafeFailure) ?? .accessDenied)
            return
        }
        let fetched = await adapter.fetch(cookieHeader: cookies.billing, usageCookieHeader: cookies.usage,
                                          previous: previous)
        guard generation == requestGeneration, enabled else { return }
        usage = fetched
        if fetched.failure == .authExpired { automaticCookies = nil }
    }
}

/// Export only state and successful timestamps; never serialize the local billing model.
enum MacTypeSafeDiagnostics {
    static func statuses(for usage: TypeSafeUsage?) -> [AgentMeterDiagnosticReport.LocalServiceStatus] {
        guard let usage else { return [] }
        return [status("TypeSafe Billing", usage.billing), status("TypeSafe Usage", usage.tokens)]
    }
    private static func status<Value>(_ service: String, _ value: TypeSafeMetric<Value>)
        -> AgentMeterDiagnosticReport.LocalServiceStatus {
        .init(service: service, confidence: value.confidence,
              staleReason: value.failure?.staleReason, updatedAt: value.updatedAt ?? .distantPast)
    }
}
