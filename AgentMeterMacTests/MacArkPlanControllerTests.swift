import XCTest
import AgentMeterCore
@testable import AgentMeter

private actor ArkTestCloud {
    var records: [ToolKind: QuotaSnapshot] = [:]
    var fail = false
    func setFailure(_ value: Bool) { fail = value }
    func save(_ value: QuotaSnapshot) throws {
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
    var blocked = false
    var waiter: CheckedContinuation<Void, Never>?
    func configure(failed: Bool = false, blocked: Bool = false) { self.failed = failed; self.blocked = blocked }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
    func fetch(_ product: ArkPlanAdapter.Product, _ credentials: ArkPlanCredentials) async throws -> QuotaSnapshot {
        calls += 1
        if blocked && calls == 2 { await withCheckedContinuation { waiter = $0 } }
        if failed { throw ArkPlanAdapter.FetchError.transport }
        return QuotaSnapshot(tool: product.tool, plan: nil, windows: [.init(usedPercent: credentials.accessKeyID == "second" ? 80 : 20,
            resetsAt: Date().addingTimeInterval(3600), kind: .fiveHour)], confidence: .fresh,
            source: product.source, updatedAt: Date())
    }
}

@MainActor
final class MacArkPlanControllerTests: XCTestCase {
    private final class Store { var values: [ArkPlanAdapter.Product: String] = [:] }
    private func harness() -> (MacArkPlanController, Store, ArkTestFetch, ArkTestCloud) {
        let name = "ArkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let store = Store(), fetch = ArkTestFetch(), cloud = ArkTestCloud()
        let deps = MacArkPlanController.Dependencies(read: { store.values[$0] }, write: { store.values[$0] = $1 },
            remove: { store.values[$0] = nil }, fetch: { try await fetch.fetch($0, $1) },
            publish: { try await cloud.save($0) }, delete: { try await cloud.delete($0) })
        return (MacArkPlanController(defaults: defaults, dependencies: deps), store, fetch, cloud)
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
        XCTAssertTrue(controller.snapshots.isEmpty)
        let record = await cloud.record(.arkCoding)
        XCTAssertNil(record)
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
