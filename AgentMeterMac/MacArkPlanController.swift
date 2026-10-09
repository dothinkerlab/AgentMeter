import Foundation
import Combine
import CryptoKit
import AgentMeterCore

/// Only sanitized quota facts cross devices. Query diagnostics and queues are local.
@MainActor
final class MacArkPlanController: ObservableObject {
    typealias Product = ArkPlanAdapter.Product
    @Published private(set) var snapshots: [QuotaSnapshot] = []
    @Published private(set) var pending: Set<ToolKind> = []
    @Published private(set) var states: [Product: ProviderConnectionState] = [:]
    @Published private(set) var statuses: [Product: MacPlanQueryStatus] = [:]
    enum SyncState { case idle, uploadPending, deletePending }
    struct Dependencies {
        var read: (Product) throws -> String?
        var write: (Product, String) throws -> Void
        var remove: (Product) throws -> Void
        var fetch: @Sendable (Product, ArkPlanCredentials) async throws -> QuotaSnapshot
        var publish: @Sendable (QuotaSnapshot) async throws -> Void
        var delete: @Sendable (ToolKind) async throws -> Void
        static func live(sync: CloudKitSync) -> Self {
            func kind(_ product: Product) -> ProviderCredentialStore.Kind { product == .coding ? .arkCoding : .arkAgent }
            return Self(read: { try ProviderCredentialStore.read(kind: kind($0)) },
                write: { try ProviderCredentialStore.save($1, kind: kind($0)) },
                remove: { try ProviderCredentialStore.delete(kind: kind($0)) },
                fetch: { try await ArkPlanAdapter(product: $0).fetch(credentials: $1) },
                publish: { try await sync.save($0) }, delete: { try await sync.delete(tool: $0) })
        }
    }
    private let defaults: UserDefaults
    private let dependencies: Dependencies
    private let now: () -> Date
    private let gate = DeviceCodingOperationGate()
    private var factRevisions: [Product: UInt64] = [:]
    private var generations: [Product: UInt64] = [:]
    private var flights: [Product: Task<Void, Never>] = [:]
    private var flightsID: [Product: UUID] = [:]

    init(defaults: UserDefaults = .standard, sync: CloudKitSync = CloudKitSync(),
         dependencies: Dependencies? = nil, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.dependencies = dependencies ?? .live(sync: sync); self.now = now
        for product in Product.allCases {
            statuses[product] = MacPlanQueryStatus()
            if let data = defaults.data(forKey: key(product, "status")) {
                do { statuses[product] = try JSONDecoder().decode(MacPlanQueryStatus.self, from: data) }
                catch { statuses[product]?.issue = .storage }
            }
            if let data = defaults.data(forKey: key(product, "snapshot")) {
                do {
                    let cached = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
                    guard cached.tool == product.tool, cached.source == product.source else { throw ArkPlanAdapter.FetchError.decode }
                    snapshots.append(cached.markedStale())
                } catch { statuses[product]?.issue = .responseChanged }
            }
            updateState(product)
            updatePending(product)
        }
    }
    func isEnabled(_ product: Product) -> Bool { defaults.bool(forKey: key(product, "enabled")) }
    func state(_ product: Product) -> ProviderConnectionState { states[product] ?? .unconfigured }
    func status(_ product: Product) -> MacPlanQueryStatus { statuses[product] ?? .init() }
    func hasCredentials(_ product: Product) throws -> Bool { try dependencies.read(product) != nil }
    func canQuery(_ product: Product) -> Bool {
        status(product).credentialAvailable && status(product).canQuery(now: now()) && flights[product] == nil
    }
    func syncState(_ product: Product) -> SyncState {
        if defaults.bool(forKey: key(product, "pendingDelete")) { return .deletePending }
        if defaults.bool(forKey: key(product, "pendingUpload")) { return .uploadPending }
        return .idle
    }
    /// Settings inspection reads Keychain locally, never performs a provider request.
    func loadSettings(_ product: Product) {
        do {
            statuses[product]?.credentialAvailable = try hasCredentials(product)
            if statuses[product]?.issue == .credentialRead { statuses[product]?.issue = nil }
        } catch { statuses[product]?.credentialAvailable = false; statuses[product]?.issue = .credentialRead }
        updateState(product); persistStatus(product)
    }
    private func invalidate(_ product: Product) async -> UInt64 {
        generations[product, default: 0] &+= 1
        let generation = generations[product, default: 0]
        flights[product]?.cancel(); flights[product] = nil; flightsID[product] = nil
        _ = await gate.invalidateAndPerform(device: .mac, tool: product.tool) { true }
        return generation
    }
    func save(_ product: Product, accessKeyID: String, secretAccessKey: String) async throws {
        let credentials = try ArkPlanCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
        // A failed Keychain write keeps the old account and its current operation intact.
        do { try dependencies.write(product, credentials.encoded) }
        catch { statuses[product]?.issue = .storage; updateState(product); persistStatus(product); throw error }
        let generation = await invalidate(product)
        guard current(product, generation) else { return }
        clearFacts(product)
        defaults.removeObject(forKey: key(product, "identity"))
        statuses[product] = MacPlanQueryStatus(credentialAvailable: true)
        defaults.set(true, forKey: key(product, "enabled"))
        defaults.set(true, forKey: key(product, "pendingDelete"))
        updatePending(product); persistStatus(product)
        await refresh(product)
    }
    func setEnabled(_ enabled: Bool, product: Product) async {
        if enabled {
            loadSettings(product)
            guard canQuery(product) else { return }
            defaults.set(true, forKey: key(product, "enabled"))
            await refresh(product)
        } else {
            defaults.set(false, forKey: key(product, "enabled"))
            let generation = await invalidate(product)
            guard current(product, generation), !isEnabled(product) else { return }
            if let old = snapshots.first(where: { $0.tool == product.tool }) { store(old.markedStale(), product) }
            updateState(product)
        }
    }
    func remove(_ product: Product) async throws {
        do { try dependencies.remove(product) }
        catch { statuses[product]?.issue = .storage; updateState(product); persistStatus(product); throw error }
        defaults.set(false, forKey: key(product, "enabled"))
        let generation = await invalidate(product)
        guard current(product, generation) else { return }
        clearFacts(product)
        defaults.removeObject(forKey: key(product, "identity"))
        statuses[product] = MacPlanQueryStatus()
        defaults.set(true, forKey: key(product, "pendingDelete"))
        updateState(product); persistStatus(product); updatePending(product)
        await retrySync(product)
    }
    func collect() async { for product in Product.allCases { await refresh(product) } }
    func refresh(_ product: Product) async {
        if let task = flights[product] { await task.value; return }
        let id = UUID(), generation = generations[product, default: 0]
        let task = Task { await performRefresh(product, generation) }
        flights[product] = task; flightsID[product] = id
        await task.value
        if flightsID[product] == id { flights[product] = nil; flightsID[product] = nil }
    }
    private func performRefresh(_ product: Product, _ generation: UInt64) async {
        guard isEnabled(product) else {
            if syncState(product) == .deletePending { await retrySync(product) }
            return
        }
        guard status(product).canQuery(now: now()) else { await retrySync(product); return }
        let snapshot: QuotaSnapshot
        do {
            let credentials: ArkPlanCredentials
            do {
                guard let stored = try dependencies.read(product) else {
                    statuses[product]?.credentialAvailable = false
                    throw ArkPlanAdapter.FetchError.unauthorized
                }
                credentials = try ArkPlanCredentials.decode(stored)
                statuses[product]?.credentialAvailable = true
            } catch {
                statuses[product]?.issue = .credentialRead
                throw error
            }
            let identity = SHA256.hash(data: Data((credentials.accessKeyID + "\n" + credentials.secretAccessKey).utf8))
                .map { String(format: "%02x", $0) }.joined()
            if defaults.string(forKey: key(product, "identity")) != identity {
                clearFacts(product)
                defaults.set(identity, forKey: key(product, "identity"))
                statuses[product]?.lastSuccess = nil
                defaults.set(true, forKey: key(product, "pendingDelete"))
                await retrySync(product)
            }
            guard current(product, generation), isEnabled(product) else { return }
            states[product] = .checking
            do {
                snapshot = try await dependencies.fetch(product, credentials)
                guard current(product, generation), isEnabled(product) else { return }
                statuses[product]?.receive(nil)
                if snapshot.confidence == .fresh { statuses[product]?.lastSuccess = snapshot.updatedAt }
            } catch {
                guard current(product, generation) else { return }
                if error is CancellationError { updateState(product); return }
                statuses[product]?.receive(error)
                snapshot = degraded(product, reason: ArkPlanAdapter.staleReason(for: error))
            }
        } catch {
            snapshot = degraded(product, reason: .credentialReadFailed)
        }
        guard current(product, generation), isEnabled(product) else { return }
        store(snapshot, product)
        defaults.set(true, forKey: key(product, "pendingUpload"))
        persistStatus(product); updateState(product); updatePending(product)
        await retrySync(product)
    }
    func retrySync(_ product: Product) async {
        let generation = generations[product, default: 0]
        if defaults.bool(forKey: key(product, "pendingDelete")) {
            let delete = dependencies.delete
            let removed = await gate.invalidateAndPerform(device: .mac, tool: product.tool) {
                do { try await delete(product.tool); return true } catch { return false }
            }
            guard current(product, generation) else { return }
            if removed { defaults.removeObject(forKey: key(product, "pendingDelete")) }
            else { updatePending(product); return }
        }
        // A paused collector may finish explicit removal, but never upload cached facts.
        if isEnabled(product), defaults.bool(forKey: key(product, "pendingUpload")),
           let snapshot = snapshots.first(where: { $0.tool == product.tool }) {
            let revision = factRevisions[product, default: 0]
            let operation = await gate.begin(device: .mac, tool: product.tool)
            guard current(product, generation), isEnabled(product) else { return }
            let publish = dependencies.publish
            let saved = await gate.performIfCurrent(device: .mac, tool: product.tool, generation: operation) {
                do { try await publish(snapshot); return true } catch { return false }
            }
            guard current(product, generation), isEnabled(product) else { return }
            if saved == true, factRevisions[product, default: 0] == revision { defaults.removeObject(forKey: key(product, "pendingUpload")) }
        }
        updatePending(product)
    }
    private func current(_ product: Product, _ generation: UInt64) -> Bool {
        generations[product, default: 0] == generation && !Task.isCancelled
    }
    private func updateState(_ product: Product) {
        let info = status(product)
        if info.issue == .credentialRead || info.issue == .storage { states[product] = .storageFailure }
        else if !info.credentialAvailable { states[product] = .unconfigured }
        else if !isEnabled(product) { states[product] = .disabled }
        else if info.issue == .invalidCredential { states[product] = .invalidCredential }
        else if info.issue != nil { states[product] = .pendingVerification(.endpointFailure) }
        else { states[product] = .resolved(hasCredential: true, isEnabled: true,
            confidence: snapshots.first { $0.tool == product.tool }?.confidence, staleReason: nil) }
    }
    private func degraded(_ product: Product, reason: QuotaStaleReason) -> QuotaSnapshot {
        snapshots.first { $0.tool == product.tool }?.markedStale(reason: reason)
            ?? .unknown(tool: product.tool, source: product.source, reason: reason)
    }
    private func store(_ snapshot: QuotaSnapshot, _ product: Product) {
        factRevisions[product, default: 0] &+= 1
        snapshots.removeAll { $0.tool == product.tool }; snapshots.append(snapshot)
        do { defaults.set(try JSONEncoder().encode(snapshot), forKey: key(product, "snapshot")) }
        catch { statuses[product]?.issue = .storage }
    }
    private func clearFacts(_ product: Product) {
        factRevisions[product, default: 0] &+= 1
        snapshots.removeAll { $0.tool == product.tool }
        defaults.removeObject(forKey: key(product, "snapshot"))
        defaults.removeObject(forKey: key(product, "pendingUpload"))
    }
    private func updatePending(_ product: Product) {
        if syncState(product) == .idle { pending.remove(product.tool) } else { pending.insert(product.tool) }
    }
    private func persistStatus(_ product: Product) {
        do { defaults.set(try JSONEncoder().encode(status(product)), forKey: key(product, "status")) }
        catch { states[product] = .storageFailure }
    }
    private func key(_ product: Product, _ suffix: String) -> String { "arkPlan.\(product.rawValue).\(suffix)" }
}
