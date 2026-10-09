import Foundation
import Combine
import CryptoKit
import AgentMeterCore

/// AK/SK and cached facts stay on this Mac; only QuotaSnapshot goes to CloudKit.
@MainActor
final class MacArkPlanController: ObservableObject {
    typealias Product = ArkPlanAdapter.Product
    @Published private(set) var snapshots: [QuotaSnapshot] = []
    @Published private(set) var pending: Set<ToolKind> = []
    @Published private(set) var states: [Product: ProviderConnectionState] = [:]
    private let defaults: UserDefaults
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
    private let dependencies: Dependencies
    private let gate = DeviceCodingOperationGate()
    private var generations: [Product: UInt64] = [:]
    private var flights: [Product: Task<Void, Never>] = [:]
    private var flightsID: [Product: UUID] = [:]

    init(defaults: UserDefaults = .standard, sync: CloudKitSync = CloudKitSync(), dependencies: Dependencies? = nil) {
        self.defaults = defaults
        self.dependencies = dependencies ?? .live(sync: sync)
        for product in Product.allCases {
            if isEnabled(product), let data = defaults.data(forKey: cacheKey(product)) {
                do {
                    let cached = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
                    guard cached.tool == product.tool, cached.source == product.source else { throw ArkPlanAdapter.FetchError.decode }
                    snapshots.append(cached.markedStale(reason: .unknownFailure))
                }
                catch { states[product] = .pendingVerification(.responseChanged) }
            }
            if states[product] == nil { states[product] = isEnabled(product) ? .pendingVerification(.unknownFailure) : .disabled }
        }
    }
    func isEnabled(_ product: Product) -> Bool { defaults.bool(forKey: "arkPlan.\(product.rawValue).enabled") }
    func state(_ product: Product) -> ProviderConnectionState { states[product] ?? .unconfigured }
    func hasCredentials(_ product: Product) throws -> Bool { try dependencies.read(product) != nil }

    func save(_ product: Product, accessKeyID: String, secretAccessKey: String) async throws {
        let value = try ArkPlanCredentials(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
        generations[product, default: 0] &+= 1
        flights[product]?.cancel(); flights[product] = nil; flightsID[product] = nil
        try dependencies.write(product, value.encoded)
        defaults.removeObject(forKey: identityKey(product))
        snapshots.removeAll { $0.tool == product.tool }
        defaults.removeObject(forKey: cacheKey(product))
        defaults.set(true, forKey: "arkPlan.\(product.rawValue).enabled")
        await refresh(product)
    }
    func setEnabled(_ enabled: Bool, product: Product) async {
        generations[product, default: 0] &+= 1
        flights[product]?.cancel(); flights[product] = nil; flightsID[product] = nil
        defaults.set(enabled, forKey: "arkPlan.\(product.rawValue).enabled")
        if enabled { await refresh(product) }
        else {
            states[product] = .disabled
            snapshots.removeAll { $0.tool == product.tool }
            defaults.removeObject(forKey: cacheKey(product))
            defaults.set(true, forKey: deleteKey(product))
            _ = await gate.invalidateAndPerform(device: .mac, tool: product.tool) { true }
            await deletePending(product)
        }
    }
    func remove(_ product: Product) async throws {
        try dependencies.remove(product)
        await setEnabled(false, product: product)
        defaults.removeObject(forKey: identityKey(product))
        states[product] = .unconfigured
    }
    func collect() async { for product in Product.allCases { await refresh(product) } }
    func refresh(_ product: Product) async {
        if let task = flights[product] { await task.value; return }
        let id = UUID()
        let task = Task { await performRefresh(product) }
        flights[product] = task; flightsID[product] = id
        await task.value
        if flightsID[product] == id { flights[product] = nil; flightsID[product] = nil }
    }
    private func performRefresh(_ product: Product) async {
        guard isEnabled(product) else { await deletePending(product); return }
        let generation = generations[product, default: 0]
        let snapshot: QuotaSnapshot
        do {
            guard let stored = try dependencies.read(product) else {
                guard current(product, generation) else { return }
                throw ArkPlanAdapter.FetchError.unauthorized
            }
            let credentials = try ArkPlanCredentials.decode(stored)
            let identity = SHA256.hash(data: Data((credentials.accessKeyID + "\n" + credentials.secretAccessKey).utf8))
                .map { String(format: "%02x", $0) }.joined()
            if defaults.string(forKey: identityKey(product)) != identity {
                snapshots.removeAll { $0.tool == product.tool }
                defaults.removeObject(forKey: cacheKey(product))
                defaults.set(identity, forKey: identityKey(product))
                defaults.set(true, forKey: deleteKey(product))
                await deletePending(product)
            }
            guard current(product, generation), !Task.isCancelled else { return }
            states[product] = .checking
            do { snapshot = try await dependencies.fetch(product, credentials) }
            catch {
                if error is CancellationError { return }
                snapshot = degraded(product, reason: ArkPlanAdapter.staleReason(for: error))
            }
        } catch {
            snapshot = degraded(product, reason: .credentialReadFailed)
        }
        guard current(product, generation), !Task.isCancelled else { return }
        snapshots.removeAll { $0.tool == product.tool }; snapshots.append(snapshot)
        states[product] = .resolved(hasCredential: true, isEnabled: true,
            confidence: snapshot.confidence, staleReason: snapshot.staleReason)
        do { defaults.set(try JSONEncoder().encode(snapshot), forKey: cacheKey(product)) }
        catch { states[product] = .storageFailure }
        let operation = await gate.begin(device: .mac, tool: product.tool)
        guard current(product, generation) else { return }
        let publish = dependencies.publish
        let saved = await gate.performIfCurrent(device: .mac, tool: product.tool, generation: operation) {
            do { try await publish(snapshot); return true } catch { return false }
        }
        guard current(product, generation) else { return }
        if saved == true {
            pending.remove(product.tool); defaults.removeObject(forKey: deleteKey(product))
        } else { pending.insert(product.tool) }
    }
    private func deletePending(_ product: Product) async {
        guard defaults.bool(forKey: deleteKey(product)) else { return }
        let delete = dependencies.delete
        let removed = await gate.invalidateAndPerform(device: .mac, tool: product.tool) {
            do { try await delete(product.tool); return true } catch { return false }
        }
        if removed { defaults.removeObject(forKey: deleteKey(product)); pending.remove(product.tool) }
        else { pending.insert(product.tool) }
    }
    private func current(_ product: Product, _ generation: UInt64) -> Bool {
        generations[product, default: 0] == generation && isEnabled(product)
    }
    private func degraded(_ product: Product, reason: QuotaStaleReason) -> QuotaSnapshot {
        snapshots.first { $0.tool == product.tool }?.markedStale(reason: reason)
            ?? .unknown(tool: product.tool, source: product.source, reason: reason)
    }
    private func cacheKey(_ product: Product) -> String { "arkPlan.\(product.rawValue).snapshot" }
    private func identityKey(_ product: Product) -> String { "arkPlan.\(product.rawValue).identity" }
    private func deleteKey(_ product: Product) -> String { "arkPlan.\(product.rawValue).pendingDelete" }
}
