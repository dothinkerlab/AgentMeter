import XCTest
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class MacTypeSafeSyncTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "JevSyncTests.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    func testDefaultOffDoesNotUpload() async {
        let store = FakeJevSyncStore()
        let sync = MacTypeSafeSyncController(defaults: defaults(), store: store)
        sync.update(.init())
        await sync.flush()
        XCTAssertFalse(sync.enabled)
        let writes = await store.writes
        XCTAssertTrue(writes.isEmpty)
    }
    func testDisableDuringUploadFinishesWithTombstone() async {
        let store = FakeJevSyncStore()
        await store.holdFirstWrite()
        let sync = MacTypeSafeSyncController(defaults: defaults(), store: store)
        sync.setEnabled(true, snapshot: .init())
        await store.waitForWrite()
        sync.setEnabled(false, snapshot: .init())
        await store.release()
        while sync.uploading { await Task.yield() }
        await sync.flush()
        let writes = await store.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertNotNil(writes.first?.snapshot)
        XCTAssertNil(writes.last?.snapshot)
    }
    func testFailedDisablePersistsAcrossRestartAndRetries() async {
        let prefs = defaults()
        let failed = FakeJevSyncStore()
        await failed.setFail(true)
        let sync = MacTypeSafeSyncController(defaults: prefs, store: failed)
        sync.setEnabled(false, snapshot: .init())
        await sync.flush()
        XCTAssertNotNil(prefs.data(forKey: "typesafe.cloudSync.pending"))
        let recovered = FakeJevSyncStore()
        let restarted = MacTypeSafeSyncController(defaults: prefs, store: recovered)
        await restarted.flush()
        let writes = await recovered.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertNil(writes.first?.snapshot)
        XCTAssertNil(prefs.data(forKey: "typesafe.cloudSync.pending"))
    }
    func testAccountChangeDoesNotUploadOldFacts() async {
        let prefs = defaults()
        prefs.set("former", forKey: "typesafe.cloudSync.account")
        let store = FakeJevSyncStore()
        let sync = MacTypeSafeSyncController(defaults: prefs, store: store)
        sync.setEnabled(true, snapshot: .init())
        await sync.flush()
        XCTAssertFalse(sync.enabled)
        let writes = await store.writes
        XCTAssertTrue(writes.isEmpty)
    }
}

private actor FakeJevSyncStore: TypeSafeSyncStore {
    var writes: [TypeSafeSyncEnvelope] = []
    private var fail = false
    private var hold = false
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func accountIdentifier() async throws -> String { "test-account" }
    func fetch() async throws -> TypeSafeSyncEnvelope? { nil }
    func setFail(_ value: Bool) { fail = value }
    func holdFirstWrite() { hold = true }
    func waitForWrite() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func save(_ envelope: TypeSafeSyncEnvelope) async throws {
        if fail { throw TypeSafeSyncError.network }
        if hold {
            hold = false
            await withCheckedContinuation { continuation in
                gate = continuation; started = true
                startedWaiter?.resume(); startedWaiter = nil
            }
        }
        writes.append(envelope)
    }
}
