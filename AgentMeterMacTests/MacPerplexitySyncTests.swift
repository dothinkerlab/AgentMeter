import XCTest
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class MacPerplexitySyncTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "PerplexitySyncTests.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }
    func testDefaultOffDoesNotUpload() async {
        let store = FakePerplexitySyncStore()
        let sync = MacPerplexitySyncController(defaults: defaults(), store: store)
        sync.update(.init())
        await sync.flush()
        XCTAssertFalse(sync.enabled)
        let writes = await store.writes
        XCTAssertTrue(writes.isEmpty)
    }
    func testDisableDuringUploadFinishesWithTombstone() async {
        let store = FakePerplexitySyncStore()
        await store.holdFirstWrite()
        let sync = MacPerplexitySyncController(defaults: defaults(), store: store)
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
        let failed = FakePerplexitySyncStore()
        await failed.setFail(true)
        let sync = MacPerplexitySyncController(defaults: prefs, store: failed)
        sync.setEnabled(false, snapshot: .init())
        await sync.flush()
        XCTAssertNotNil(prefs.data(forKey: "perplexity.cloudSync.pending"))
        let recovered = FakePerplexitySyncStore()
        let restarted = MacPerplexitySyncController(defaults: prefs, store: recovered)
        await restarted.flush()
        let writes = await recovered.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertNil(writes.first?.snapshot)
        XCTAssertNil(prefs.data(forKey: "perplexity.cloudSync.pending"))
    }
    func testUnboundRestoredOutboxCannotLeakToANewAccount() async throws {
        let prefs = defaults()
        prefs.set(true, forKey: "perplexity.cloudSync.enabled")
        prefs.set(try JSONEncoder().encode(PerplexitySyncEnvelope(snapshot: .init())), forKey: "perplexity.cloudSync.pending")
        let store = FakePerplexitySyncStore()
        let sync = MacPerplexitySyncController(defaults: prefs, store: store)
        await sync.flush()
        XCTAssertFalse(sync.enabled)
        let writes = await store.writes
        XCTAssertTrue(writes.isEmpty)
    }
    func testAccountChangeDoesNotUploadOldFacts() async {
        let prefs = defaults()
        prefs.set("former", forKey: "perplexity.cloudSync.account")
        let store = FakePerplexitySyncStore()
        let sync = MacPerplexitySyncController(defaults: prefs, store: store)
        sync.setEnabled(true, snapshot: .init())
        await sync.flush()
        XCTAssertFalse(sync.enabled)
        let writes = await store.writes
        XCTAssertTrue(writes.isEmpty)
    }
}

private actor FakePerplexitySyncStore: PerplexitySyncStore {
    var writes: [PerplexitySyncEnvelope] = []
    private var fail = false
    private var hold = false
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func accountIdentifier() async throws -> String { "test-account" }
    func fetch() async throws -> PerplexitySyncEnvelope? { nil }
    func setFail(_ value: Bool) { fail = value }
    func holdFirstWrite() { hold = true }
    func waitForWrite() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func save(_ envelope: PerplexitySyncEnvelope) async throws {
        if fail { throw PerplexitySyncError.network }
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
