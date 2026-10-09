import XCTest
import AgentMeterCore
@testable import AgentMeter

private actor ArkTestCloud {
    var records: [ToolKind: QuotaSnapshot] = [:]
    var fail = false
    var writes = 0
    var blockNext = false
    var waiter: CheckedContinuation<Void, Never>?
    func blockOneWrite() { blockNext = true }
    func releaseWrite() { waiter?.resume(); waiter = nil }
    func setFailure(_ value: Bool) { fail = value }
    func save(_ value: QuotaSnapshot) async throws {
        writes += 1
        if blockNext { blockNext = false; await withCheckedContinuation { waiter = $0 } }
        if fail { throw ArkPlanAdapter.FetchError.transport }
        records[value.tool] = value
    }
    func delete(_ tool: ToolKind) throws {
        if fail { throw ArkPlanAdapter.FetchError.transport }
        records[tool] = nil
    }
    func record(_ tool: ToolKind) -> QuotaSnapshot? { records[tool] }
}

private actor ArkTestFetch {
    var calls = 0
    var failed = false
    var failure: Error?
    var blocked = false
    var waiter: CheckedContinuation<Void, Never>?
    func configure(failed: Bool = false, blocked: Bool = false) { self.failed = failed; self.blocked = blocked }
    func setFailure(_ value: Error?) { failure = value }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func fetch(_ product: ArkPlanAdapter.Product, _ credentials: ArkPlanCredentials) async throws -> QuotaSnapshot {
        calls += 1
        if blocked && calls == 2 { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw failure }
        if failed { throw ArkPlanAdapter.FetchError.transport }
        return QuotaSnapshot(tool: product.tool, plan: nil, windows: [.init(usedPercent: credentials.accessKeyID == "second" ? 80 : 20,
            resetsAt: Date().addingTimeInterval(3600), kind: .fiveHour)], confidence: .fresh,
            source: product.source, updatedAt: Date())
    }
}

@MainActor
final class MacArkPlanControllerTests: XCTestCase {
    private final class Store { var values: [ArkPlanAdapter.Product: String] = [:]; var failWrite = false; var failRemove = false }
    private final class Clock { var date = Date() }
    private var latestDefaults: UserDefaults!
    private var latestDependencies: MacArkPlanController.Dependencies!
    private let clock = Clock()
    private func harness() -> (MacArkPlanController, Store, ArkTestFetch, ArkTestCloud) {
        let name = "ArkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        latestDefaults = defaults
        let store = Store(), fetch = ArkTestFetch(), cloud = ArkTestCloud()
        let deps = MacArkPlanController.Dependencies(read: { store.values[$0] }, write: { if store.failWrite { throw ArkPlanAdapter.FetchError.transport }; store.values[$0] = $1 },
            remove: { if store.failRemove { throw ArkPlanAdapter.FetchError.transport }; store.values[$0] = nil }, fetch: { try await fetch.fetch($0, $1) },
            publish: { try await cloud.save($0) }, delete: { try await cloud.delete($0) })
        latestDependencies = deps
        return (MacArkPlanController(defaults: defaults, dependencies: deps, now: { self.clock.date }), store, fetch, cloud)
    }
    func testUnconfiguredAndPauseResumePreserveFacts() async throws {
        let (controller, _, fetch, cloud) = harness()
        controller.loadSettings(.coding)
        XCTAssertEqual(controller.state(.coding), .unconfigured)
        XCTAssertFalse(controller.canQuery(.coding))
        await controller.setEnabled(true, product: .coding)
        XCTAssertFalse(controller.isEnabled(.coding))
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await controller.setEnabled(false, product: .coding)
        XCTAssertEqual(controller.state(.coding), .disabled)
        XCTAssertEqual(controller.snapshots.first?.windows.first?.usedPercent, 20)
        let before = await fetch.calls
        await controller.collect()
        let after = await fetch.calls
        XCTAssertEqual(before, after)
        let record = await cloud.record(.arkCoding)
        XCTAssertNotNil(record)
        let restored = MacArkPlanController(defaults: latestDefaults, dependencies: latestDependencies)
        XCTAssertFalse(restored.isEnabled(.coding))
        XCTAssertEqual(restored.snapshots.first?.confidence, .stale)
        XCTAssertEqual(restored.snapshots.first?.windows.first?.usedPercent, 20)
        await controller.setEnabled(true, product: .coding)
        XCTAssertEqual(controller.snapshots.first?.confidence, .fresh)
    }
    func testCooldownAndPermissionHaveDistinctMessages() async throws {
        let (controller, _, fetch, _) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await fetch.setFailure(ProviderRequestFailure(isRateLimited: true, retryAt: clock.date + 60, httpStatus: 429))
        await controller.refresh(.coding)
        XCTAssertEqual(controller.status(.coding).issue, .rateLimited)
        XCTAssertFalse(controller.canQuery(.coding))
        let before = await fetch.calls
        await controller.refresh(.coding)
        let after = await fetch.calls
        XCTAssertEqual(before, after)
        clock.date += 61
        await fetch.setFailure(ArkPlanAdapter.FetchError.permissionDenied)
        await controller.refresh(.coding)
        XCTAssertEqual(controller.status(.coding).issue, .permissionDenied)
        XCTAssertNil(controller.status(.coding).retryAt)
    }
    func testRemovalQueueSurvivesRestartAndDeletesWithoutFetching() async throws {
        let (controller, _, fetch, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await cloud.setFailure(true)
        try await controller.remove(.coding)
        XCTAssertTrue(controller.snapshots.isEmpty)
        XCTAssertEqual(controller.syncState(.coding), .deletePending)
        let restored = MacArkPlanController(defaults: latestDefaults, dependencies: latestDependencies)
        XCTAssertEqual(restored.syncState(.coding), .deletePending)
        await cloud.setFailure(false)
        await restored.collect()
        XCTAssertEqual(restored.syncState(.coding), .idle)
        let calls = await fetch.calls
        XCTAssertEqual(calls, 1)
        let record = await cloud.record(.arkCoding)
        XCTAssertNil(record)
    }
    func testFailedKeychainWriteOrRemovalPreservesCurrentAccount() async throws {
        let (controller, store, _, _) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        store.failWrite = true
        do { try await controller.save(.coding, accessKeyID: "second", secretAccessKey: "replacement"); XCTFail() } catch {}
        XCTAssertEqual(controller.snapshots.first?.windows.first?.usedPercent, 20)
        store.failRemove = true
        do { try await controller.remove(.coding); XCTFail() } catch {}
        XCTAssertTrue(controller.isEnabled(.coding))
        XCTAssertNotNil(store.values[.coding])
    }
    func testUploadQueuePersistsAndRetryDoesNotRequestProvider() async throws {
        let (controller, _, fetch, cloud) = harness()
        await cloud.setFailure(true)
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await cloud.setFailure(false)
        await controller.retrySync(.coding)
        XCTAssertEqual(controller.syncState(.coding), .idle)
        await cloud.setFailure(true)
        await controller.refresh(.coding)
        XCTAssertEqual(controller.syncState(.coding), .uploadPending)
        let restored = MacArkPlanController(defaults: latestDefaults, dependencies: latestDependencies)
        XCTAssertEqual(restored.syncState(.coding), .uploadPending)
        let before = await fetch.calls
        await cloud.setFailure(false)
        await restored.retrySync(.coding)
        let after = await fetch.calls
        XCTAssertEqual(before, after)
        XCTAssertEqual(restored.syncState(.coding), .idle)
    }
    func testPauseDuringCloudWriteRetainsFactsWithoutFurtherUploads() async throws {
        let (controller, _, _, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await cloud.blockOneWrite()
        let refresh = Task { await controller.refresh(.coding) }
        while await cloud.writes < 2 { await Task.yield() }
        let pause = Task { await controller.setEnabled(false, product: .coding) }
        while controller.isEnabled(.coding) { await Task.yield() }
        await cloud.releaseWrite()
        await pause.value; await refresh.value
        await controller.retrySync(.coding)
        let writes = await cloud.writes
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(controller.snapshots.first?.confidence, .stale)
        XCTAssertFalse(controller.isEnabled(.coding))
    }
    func testRemovalDuringCloudWriteWinsOverOldCompletion() async throws {
        let (controller, _, _, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await cloud.blockOneWrite()
        let refresh = Task { await controller.refresh(.coding) }
        while await cloud.writes < 2 { await Task.yield() }
        let removal = Task { try await controller.remove(.coding) }
        while controller.isEnabled(.coding) { await Task.yield() }
        await cloud.releaseWrite()
        try await removal.value; await refresh.value
        let record = await cloud.record(.arkCoding)
        XCTAssertNil(record)
        XCTAssertTrue(controller.snapshots.isEmpty)
        XCTAssertEqual(controller.syncState(.coding), .idle)
    }
    func testDisabledByDefaultAndProductsRemainIndependent() async throws {
        let (controller, store, fetch, cloud) = harness()
        await controller.collect()
        let initialCalls = await fetch.calls
        XCTAssertEqual(initialCalls, 0)
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        XCTAssertEqual(controller.snapshots.map(\.tool), [.arkCoding])
        XCTAssertNotNil(store.values[.coding]); XCTAssertNil(store.values[.agent])
        let record = await cloud.record(.arkCoding)
        XCTAssertEqual(record?.windows.first?.usedPercent, 20)
    }
    func testFailureRetainsFactsAndCloudFailureIsPending() async throws {
        let (controller, _, fetch, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await fetch.configure(failed: true)
        await cloud.setFailure(true)
        await controller.refresh(.coding)
        XCTAssertEqual(controller.snapshots.first?.confidence, .stale)
        XCTAssertEqual(controller.snapshots.first?.windows.first?.usedPercent, 20)
        XCTAssertTrue(controller.pending.contains(.arkCoding))
        await cloud.setFailure(false)
        await controller.refresh(.coding)
        XCTAssertFalse(controller.pending.contains(.arkCoding))
    }
    func testDisableDuringFetchCannotRestoreCloudRecord() async throws {
        let (controller, _, fetch, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await fetch.configure(blocked: true)
        let refreshing = Task { await controller.refresh(.coding) }
        while await fetch.calls < 2 { await Task.yield() }
        await controller.setEnabled(false, product: .coding)
        await fetch.release()
        await refreshing.value
        XCTAssertEqual(controller.snapshots.first?.confidence, .stale)
        let record = await cloud.record(.arkCoding)
        XCTAssertEqual(record?.windows.first?.usedPercent, 20)
    }
    func testReplacingCredentialsDuringFetchKeepsNewAccountRecord() async throws {
        let (controller, _, fetch, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await fetch.configure(blocked: true)
        let old = Task { await controller.refresh(.coding) }
        while await fetch.calls < 2 { await Task.yield() }
        try await controller.save(.coding, accessKeyID: "second", secretAccessKey: "another-secret")
        await fetch.release()
        await old.value
        XCTAssertEqual(controller.snapshots.first?.windows.first?.usedPercent, 80)
        let record = await cloud.record(.arkCoding)
        XCTAssertEqual(record?.windows.first?.usedPercent, 80)
    }
    func testMissingCredentialMarksPriorFactsStale() async throws {
        let (controller, store, _, _) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        store.values[.coding] = nil
        await controller.refresh(.coding)
        XCTAssertEqual(controller.snapshots.first?.confidence, .stale)
        XCTAssertEqual(controller.snapshots.first?.staleReason, .credentialReadFailed)
        XCTAssertEqual(controller.snapshots.first?.windows.first?.usedPercent, 20)
    }
    func testCredentialChangeDiscardsOldAccountFactsOnFailure() async throws {
        let (controller, _, fetch, cloud) = harness()
        try await controller.save(.coding, accessKeyID: "first", secretAccessKey: "fixture-secret")
        await fetch.configure(failed: true)
        try await controller.save(.coding, accessKeyID: "second", secretAccessKey: "another-secret")
        XCTAssertEqual(controller.snapshots.first?.confidence, .unknown)
        XCTAssertTrue(controller.snapshots.first?.windows.isEmpty == true)
        let record = await cloud.record(.arkCoding)
        XCTAssertTrue(record?.windows.isEmpty == true)
    }
}
