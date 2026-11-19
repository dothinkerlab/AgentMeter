import AgentMeterCore
import CloudKit
import Combine
import Foundation

@MainActor
final class MacAntigravityController: ObservableObject {
    static let enabledKey = "antigravityQuota.enabled"
    static let interval: TimeInterval = 120

    @Published private(set) var enabled: Bool
    @Published private(set) var quota: MacAntigravityQuota?
    @Published private(set) var failure: MacAntigravityFailure?
    @Published private(set) var checking = false

    let cloudSync: MacAntigravityCloudSync?
    private var accountObserver: NSObjectProtocol?

    private let defaults: UserDefaults
    private let fetch: @Sendable () async throws -> MacAntigravityQuota
    private let uptime: () -> TimeInterval
    private var lastAttempt: TimeInterval?
    private var inFlight: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         cloudSync: MacAntigravityCloudSync? = nil,
         fetch: @escaping @Sendable () async throws -> MacAntigravityQuota = { try await MacAntigravityCLI().fetch() }) {
        self.defaults = defaults
        self.uptime = uptime
        self.fetch = fetch
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.cloudSync = cloudSync
        if cloudSync != nil {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.handleAccountChange() }
            }
        }
    }

    deinit {
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }

    private func handleAccountChange() {
        cloudSync?.accountChanged()
        inFlight?.cancel()
        quota = nil
        failure = nil
        lastAttempt = nil
        Task { await collect(force: true) }
    }

    var state: ProviderConnectionState {
        if !enabled { return .disabled }
        if checking { return .checking }
        switch failure {
        case .signInRequired: return .invalidCredential
        case .missingCLI, .unsupportedCLI, .slashCommandsDisabled, .unverifiedSettings: return .unconfigured
        case .timedOut: return .pendingVerification(.networkFailure)
        case .commandFailed: return .pendingVerification(.endpointFailure)
        case .invalidReport: return .pendingVerification(.responseChanged)
        case nil: return quota == nil ? .unconfigured : .connected
        }
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if !value {
            cloudSync?.remove()
            inFlight?.cancel()
            quota = nil
            failure = nil
            checking = false
            lastAttempt = nil
        }
    }

    func collect(force: Bool = false) async {
        guard enabled else { return }
        if let inFlight {
            guard force else { return }
            await inFlight.value
            // If toggled back on before the cancelled process exited, start now.
            if inFlight.isCancelled { await collect(force: true) }
            return
        }
        let now = uptime()
        guard force || lastAttempt.map({ now - $0 >= Self.interval }) != false else { return }
        lastAttempt = now
        checking = true
        let fetch = self.fetch
        let task = Task { [weak self] in
            defer {
                self?.checking = false
                self?.inFlight = nil
            }
            do {
                let quota = try await fetch()
                guard !Task.isCancelled else { return }
                self?.quota = quota
                self?.failure = nil
                self?.cloudSync?.publish(quota.snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? MacAntigravityFailure ?? .commandFailed
                self?.failure = failure
                let reason = failure.staleReason
                let degraded = self?.quota?.snapshot.markedStale(reason: reason)
                    ?? .unknown(tool: .antigravity, source: MacAntigravityQuota.source,
                                reason: reason, collectedBy: .mac)
                self?.cloudSync?.publish(degraded)
            }
        }
        inFlight = task
        await task.value
    }
}

private extension MacAntigravityFailure {
    var staleReason: QuotaStaleReason {
        switch self {
        case .signInRequired: .authExpired
        case .missingCLI, .unsupportedCLI, .slashCommandsDisabled, .unverifiedSettings: .credentialReadFailed
        case .timedOut: .networkFailure
        case .commandFailed: .endpointFailure
        case .invalidReport: .responseChanged
        }
    }
}
