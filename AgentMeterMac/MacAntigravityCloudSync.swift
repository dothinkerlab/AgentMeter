import AgentMeterCore
import CloudKit
import Combine
import Foundation

/// Publishes the latest display facts and serializes deletion with in-flight writes.
@MainActor
final class MacAntigravityCloudSync: ObservableObject {
    struct Store {
        var account: () async throws -> String
        var fetch: () async throws -> QuotaSnapshot?
        var save: (QuotaSnapshot) async throws -> Void
        var delete: () async throws -> Void

        static var live: Self {
            let cloud = CloudKitSync()
            return Self(
                account: {
                    let container = CKContainer(identifier: cloud.containerIdentifier)
                    guard try await container.accountStatus() == .available else {
                        throw CloudKitSync.SyncError.accountUnavailable
                    }
                    return try await container.userRecordID().recordName
                },
                fetch: { try await cloud.fetch(tool: .antigravity) },
                save: { try await cloud.save($0) },
                delete: { try await cloud.delete(tool: .antigravity) }
            )
        }
    }

    @Published private(set) var failed = false

    private struct Outbox: Codable {
        var account: String?
        var delete = false
        var recordMayExist = false
        var snapshot: QuotaSnapshot?
    }

    private static let storageKey = "antigravityQuota.cloudOutbox"
    private let defaults: UserDefaults
    private let store: Store
    private var outbox = Outbox()
    private var generation = 0
    private var publishing = false
    private var worker: Task<Void, Never>?
    private let automatic: Bool

    init(defaults: UserDefaults, store: Store = .live, automatic: Bool = true) {
        self.defaults = defaults
        self.store = store
        self.automatic = automatic
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                outbox = try JSONDecoder().decode(Outbox.self, from: data)
                if !defaults.bool(forKey: MacAntigravityController.enabledKey), outbox.snapshot != nil || outbox.recordMayExist {
                    outbox.snapshot = nil
                    outbox.delete = true
                    persist()
                }
            } catch {
                failed = true
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
        if automatic {
            worker = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.flush()
                    do { try await Task.sleep(for: .seconds(MacAntigravityController.interval)) }
                    catch { return }
                }
            }
        }
    }

    deinit { worker?.cancel() }

    func publish(_ snapshot: QuotaSnapshot) {
        if snapshot.confidence == .unknown, let previous = outbox.snapshot, !previous.windows.isEmpty {
            outbox.snapshot = previous.markedStale(reason: snapshot.staleReason)
        } else {
            outbox.snapshot = snapshot
        }
        schedule()
    }

    func remove() {
        outbox.snapshot = nil
        // A Mac that has never identified its iCloud account has never uploaded a record.
        if outbox.account != nil { outbox.delete = true }
        schedule()
    }

    func accountChanged() {
        generation += 1
        outbox = Outbox()
        failed = false
        persist()
    }

    private func schedule() {
        persist()
        if automatic { Task { await flush() } }
    }

    private func persist() {
        guard outbox.account != nil else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        do { defaults.set(try JSONEncoder().encode(outbox), forKey: Self.storageKey) }
        catch { failed = true }
    }

    func flush() async {
        guard !publishing, outbox.delete || outbox.snapshot != nil else { return }
        publishing = true
        defer { publishing = false }
        let requestedGeneration = generation
        do {
            let account = try await store.account()
            guard generation == requestedGeneration else { return }
            if let previous = outbox.account, previous != account {
                accountChanged()
                return
            }
            outbox.account = account
            persist()

            while generation == requestedGeneration, outbox.delete || outbox.snapshot != nil {
                guard try await store.account() == account else {
                    if generation == requestedGeneration { accountChanged() }
                    return
                }
                guard generation == requestedGeneration else { return }
                if outbox.delete {
                    try await store.delete()
                    guard generation == requestedGeneration else { return }
                    outbox.delete = false
                    outbox.recordMayExist = false
                } else if let snapshot = outbox.snapshot {
                    var next = snapshot
                    if snapshot.confidence == .unknown, let previous = try await store.fetch(), !previous.windows.isEmpty {
                        next = previous.markedStale(reason: snapshot.staleReason)
                    }
                    // Disable, a newer collection, or an account change may have arrived during the fetch.
                    guard generation == requestedGeneration else { return }
                    guard !outbox.delete, outbox.snapshot == snapshot else { continue }
                    guard try await store.account() == account else {
                        if generation == requestedGeneration { accountChanged() }
                        return
                    }
                    guard generation == requestedGeneration else { return }
                    guard !outbox.delete, outbox.snapshot == snapshot else { continue }
                    outbox.recordMayExist = true
                    persist()
                    try await store.save(next)
                    guard generation == requestedGeneration else { return }
                    if outbox.snapshot == snapshot { outbox.snapshot = nil }
                }
                persist()
                failed = false
            }
        } catch {
            if generation == requestedGeneration { failed = true }
        }
    }
}
