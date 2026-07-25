import Foundation

public struct CodingProviderCredential: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case manualKeychain
        case kimiCLI
        case claudeSettings
        case miniMaxCLI
    }
    public let secret: String
    public let region: ProviderRegion
    public let source: Source
    public let plan: String?

    public init(secret: String, region: ProviderRegion = .global,
                source: Source, plan: String? = nil) {
        self.secret = secret
        self.region = region
        self.source = source
        self.plan = plan
    }
}

public protocol DeviceCodingSnapshotSyncing: Sendable {
    func save(_ snapshot: QuotaSnapshot, collector: QuotaCollectorDevice) async throws
    func fetch(tool: ToolKind, collector: QuotaCollectorDevice) async throws -> QuotaSnapshot?
    func delete(tool: ToolKind, collector: QuotaCollectorDevice) async throws
}

extension CloudKitSync: DeviceCodingSnapshotSyncing {}

public enum DeviceCodingCloudSyncState: Sendable, Equatable {
    case synced
    case pending
}

public enum DeviceCodingRefreshOutcome: Sendable {
    case snapshot(QuotaSnapshot, cloudSync: DeviceCodingCloudSyncState)
    case superseded
}

/// Serializes CloudKit mutations for one device/provider and invalidates stale
/// refreshes. Endpoint requests may overlap, but their writes/deletes cannot.
public actor DeviceCodingOperationGate {
    public static let shared = DeviceCodingOperationGate()

    private struct Key: Hashable, Sendable {
        let device: QuotaCollectorDevice
        let tool: ToolKind
    }

    private var generations: [Key: UInt64] = [:]
    private var mutationTails: [Key: Task<Void, Never>] = [:]

    public init() {}

    public func begin(device: QuotaCollectorDevice, tool: ToolKind) -> UInt64 {
        let key = Key(device: device, tool: tool)
        generations[key, default: 0] &+= 1
        return generations[key, default: 0]
    }

    public func performIfCurrent<Value: Sendable>(
        device: QuotaCollectorDevice,
        tool: ToolKind,
        generation: UInt64,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let key = Key(device: device, tool: tool)
        let previous = mutationTails[key]
        let task = Task<Value?, Never> { [weak self] in
            if let previous { await previous.value }
            guard let self,
                  await self.isCurrent(key: key, generation: generation) else { return nil }
            return await operation()
        }
        mutationTails[key] = Task { _ = await task.value }
        return await task.value
    }

    public func invalidateAndPerform<Value: Sendable>(
        device: QuotaCollectorDevice,
        tool: ToolKind,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let key = Key(device: device, tool: tool)
        generations[key, default: 0] &+= 1
        let previous = mutationTails[key]
        let task = Task<Value, Never> {
            if let previous { await previous.value }
            return await operation()
        }
        mutationTails[key] = Task { _ = await task.value }
        return await task.value
    }

    private func isCurrent(key: Key, generation: UInt64) -> Bool {
        generations[key] == generation
    }
}

public struct DeviceCodingRequestGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}

/// Cross-platform orchestration for providers collected independently on Mac
/// and iPhone. A failed request only degrades that device's record.
public struct DeviceCodingQuotaCollector: Sendable {
    public let device: QuotaCollectorDevice
    public let sync: any DeviceCodingSnapshotSyncing
    public let operationGate: DeviceCodingOperationGate
    private let fetchOverride: (@Sendable (ToolKind, CodingProviderCredential) async throws -> QuotaSnapshot)?

    public init(
        device: QuotaCollectorDevice,
        sync: any DeviceCodingSnapshotSyncing = CloudKitSync(),
        operationGate: DeviceCodingOperationGate = .shared
    ) {
        self.device = device
        self.sync = sync
        self.operationGate = operationGate
        self.fetchOverride = nil
    }

    init(
        device: QuotaCollectorDevice,
        sync: any DeviceCodingSnapshotSyncing,
        operationGate: DeviceCodingOperationGate,
        fetchOverride: @escaping @Sendable (
            ToolKind,
            CodingProviderCredential
        ) async throws -> QuotaSnapshot
    ) {
        self.device = device
        self.sync = sync
        self.operationGate = operationGate
        self.fetchOverride = fetchOverride
    }

    public func refresh(
        tool: ToolKind,
        credential: CodingProviderCredential
    ) async -> DeviceCodingRefreshOutcome {
        precondition(tool.supportsDeviceScopedSnapshots)
        let generation = await operationGate.begin(device: device, tool: tool)
        do {
            guard tool == .kimiCode || tool == .glmCoding || tool == .miniMax else {
                return .snapshot(.unknown(
                    tool: tool,
                    source: "unsupported",
                    reason: .unknownFailure,
                    collectedBy: device
                ), cloudSync: .pending)
            }
            let fresh = try await fetch(tool: tool, credential: credential)
            let scoped = fresh.collected(on: device)
            let saved = await operationGate.performIfCurrent(
                device: device, tool: tool, generation: generation
            ) {
                do {
                    try await sync.save(scoped, collector: device)
                    return true
                } catch {
                    return false
                }
            }
            return Self.outcome(scoped: scoped, saved: saved)
        } catch {
            return await degrade(
                tool: tool,
                reason: Self.staleReason(for: error),
                generation: generation
            )
        }
    }

    public func credentialReadFailed(tool: ToolKind) async -> DeviceCodingRefreshOutcome {
        let generation = await operationGate.begin(device: device, tool: tool)
        return await degrade(tool: tool, reason: .credentialReadFailed, generation: generation)
    }

    public func disable(tool: ToolKind) async throws {
        let deleted = await operationGate.invalidateAndPerform(device: device, tool: tool) {
            do {
                try await sync.delete(tool: tool, collector: device)
                return true
            } catch {
                return false
            }
        }
        guard deleted else { throw OperationError.deleteFailed }
    }

    private enum DegradeResult: Sendable {
        case snapshot(QuotaSnapshot, DeviceCodingCloudSyncState)
        case readFailed
    }

    public enum OperationError: Error, Equatable {
        case deleteFailed
    }

    private func degrade(
        tool: ToolKind,
        reason: QuotaStaleReason,
        generation: UInt64
    ) async -> DeviceCodingRefreshOutcome {
        let result = await operationGate.performIfCurrent(
            device: device, tool: tool, generation: generation
        ) {
            let existing: QuotaSnapshot?
            do {
                existing = try await sync.fetch(tool: tool, collector: device)
            } catch {
                return DegradeResult.readFailed
            }
            let snapshot = existing?.markedStale(reason: reason)
                ?? .unknown(tool: tool, source: Self.source(for: tool), reason: reason,
                            collectedBy: device)
            do { try await sync.save(snapshot, collector: device) }
            catch { return .snapshot(snapshot, .pending) }
            return .snapshot(snapshot, .synced)
        }
        switch result {
        case .snapshot(let snapshot, let cloudSync):
            return .snapshot(snapshot, cloudSync: cloudSync)
        case .readFailed:
            // Never persist an invented unknown over a possibly valid fact.
            return .snapshot(.unknown(
                tool: tool,
                source: Self.source(for: tool),
                reason: reason,
                collectedBy: device
            ), cloudSync: .pending)
        case nil:
            return .superseded
        }
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case is KimiCodeAdapter.FetchError: KimiCodeAdapter.staleReason(for: error)
        case is GLMCodingPlanAdapter.FetchError: GLMCodingPlanAdapter.staleReason(for: error)
        case is MiniMaxTokenPlanAdapter.FetchError: MiniMaxTokenPlanAdapter.staleReason(for: error)
        default: .unknownFailure
        }
    }

    static func outcome(
        scoped: QuotaSnapshot,
        saved: Bool?
    ) -> DeviceCodingRefreshOutcome {
        guard let saved else { return .superseded }
        return .snapshot(scoped, cloudSync: saved ? .synced : .pending)
    }

    private func fetch(
        tool: ToolKind,
        credential: CodingProviderCredential
    ) async throws -> QuotaSnapshot {
        if let fetchOverride {
            return try await fetchOverride(tool, credential)
        }
        switch tool {
        case .kimiCode:
            return try await KimiCodeAdapter().fetch(
                accessToken: credential.secret,
                plan: credential.plan
            )
        case .glmCoding:
            return try await GLMCodingPlanAdapter(region: credential.region)
                .fetch(apiKey: credential.secret, plan: credential.plan)
        case .miniMax:
            return try await MiniMaxTokenPlanAdapter(region: credential.region)
                .fetch(apiKey: credential.secret, plan: credential.plan)
        default:
            preconditionFailure("unsupported device coding provider")
        }
    }

    public static func source(for tool: ToolKind) -> String {
        switch tool {
        case .kimiCode: KimiCodeAdapter.source
        case .glmCoding: GLMCodingPlanAdapter.source
        case .miniMax: MiniMaxTokenPlanAdapter.source
        default: "unsupported"
        }
    }
}
