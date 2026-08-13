import Foundation
import Testing
@testable import AgentMeterCore

private func codingFixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Test func kimiCodeParsesUsedAndRemainingAndExcludesBooster() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let value = try KimiCodeAdapter().parse(data: codingFixture("kimi_code_usage_sample"), now: now)
    #expect(value.window(.fiveHour)?.usedPercent == 40)
    #expect(value.window(.sevenDay)?.usedPercent == 25)
    #expect(value.windows.count == 2)
}

@Test func glmParsesTokenWindowsAndIgnoresMCP() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let value = try GLMCodingPlanAdapter(region: .global)
        .parse(data: codingFixture("glm_coding_usage_sample"), now: now)
    #expect(value.window(.fiveHour)?.usedPercent == 37.5)
    #expect(value.window(.sevenDay)?.usedPercent == 20)
    #expect(value.windows.count == 2)
}

@Test func glmMapsExplicitMonthlyWindowWithoutInventingFiveHour() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let data = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","name":"Monthly","percentage":35,"nextResetTime":"2030-07-24T00:00:00Z"}]}}"#.utf8)
    let value = try GLMCodingPlanAdapter(region: .global).parse(data: data, now: now)
    #expect(value.window(.monthly)?.usedPercent == 35)
    #expect(value.window(.fiveHour) == nil)
}

@Test func glmRejectsAmbiguousOrMisleadingSingleTokenWindow() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    for name in ["", "15 day"] {
        let data = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","name":"\#(name)","percentage":35,"nextResetTime":"2030-07-24T00:00:00Z"}]}}"#.utf8)
        #expect(throws: GLMCodingPlanAdapter.FetchError.self) {
            try GLMCodingPlanAdapter(region: .global).parse(data: data, now: now)
        }
    }
}

@Test func glmAcceptsCompactExplicitWindowLabels() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let data = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","name":"5hour","percentage":10,"nextResetTime":"2030-07-18T05:00:00Z"},{"type":"TOKENS_LIMIT","name":"7day","percentage":20,"nextResetTime":"2030-07-24T00:00:00Z"}]}}"#.utf8)
    let value = try GLMCodingPlanAdapter(region: .global).parse(data: data, now: now)
    #expect(value.window(.fiveHour)?.usedPercent == 10)
    #expect(value.window(.sevenDay)?.usedPercent == 20)
}

@Test func miniMaxSelectsTextAndConvertsRemainingWeekly() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let value = try MiniMaxTokenPlanAdapter(region: .global)
        .parse(data: codingFixture("minimax_token_plan_sample"), now: now)
    #expect(value.window(.fiveHour)?.usedPercent == 20)
    #expect(value.window(.sevenDay)?.usedPercent == 20)
    #expect(value.plan == "MiniMax-M2.7")
}

@Test func providerRegionsResolveOfficialHosts() {
    #expect(ProviderRegion.china.glmQuotaURL.host == "open.bigmodel.cn")
    #expect(ProviderRegion.global.glmQuotaURL.host == "api.z.ai")
    #expect(ProviderRegion.china.miniMaxTokenPlanURL.host == "api.minimaxi.com")
    #expect(ProviderRegion.global.miniMaxTokenPlanURL.host == "api.minimax.io")
    #expect(ProviderRegion.china.kimiAPIBalanceURL.host == "api.moonshot.cn")
    #expect(ProviderRegion.global.kimiAPIBalanceURL.host == "api.moonshot.ai")
}

@Test func adaptersRejectInvalidPercentAndMissingReset() {
    let badKimi = Data(#"{"usage":{"used":120,"limit":100,"resetAt":"2030-01-01T00:00:00Z"}}"#.utf8)
    #expect(throws: KimiCodeAdapter.FetchError.self) { try KimiCodeAdapter().parse(data: badKimi) }
    let badGLM = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":20}]}}"#.utf8)
    #expect(throws: GLMCodingPlanAdapter.FetchError.self) { try GLMCodingPlanAdapter(region: .global).parse(data: badGLM) }
}

@Test func codingAdaptersRejectBooleanValuesInNumericFields() {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    #expect(CodingAdapterSupport.number(true) == nil)

    let kimi = Data(#"{"usage":{"used":true,"limit":100,"resetAt":"2030-07-24T00:00:00Z"}}"#.utf8)
    #expect(throws: KimiCodeAdapter.FetchError.self) {
        try KimiCodeAdapter().parse(data: kimi, now: now)
    }

    let glm = Data(#"{"data":{"limits":[{"type":"TOKENS_LIMIT","name":"5h","percentage":true,"nextResetTime":"2030-07-24T00:00:00Z"}]}}"#.utf8)
    #expect(throws: GLMCodingPlanAdapter.FetchError.self) {
        try GLMCodingPlanAdapter(region: .global).parse(data: glm, now: now)
    }

    let miniMax = Data(#"{"model_remains":[{"model_name":"MiniMax-M2.7","current_interval_used_count":1,"current_interval_total_count":true,"current_interval_end_time":2000000000}]}"#.utf8)
    #expect(throws: MiniMaxTokenPlanAdapter.FetchError.self) {
        try MiniMaxTokenPlanAdapter(region: .global).parse(data: miniMax, now: now)
    }
}

@Test func miniMaxRejectsAmbiguousTextEntries() {
    let data = Data(#"{"model_remains":[{"model_name":"MiniMax-M2.5"},{"model_name":"MiniMax-M2.6"}]}"#.utf8)
    #expect(throws: MiniMaxTokenPlanAdapter.FetchError.self) {
        try MiniMaxTokenPlanAdapter(region: .global).parse(data: data)
    }
}

@Test func kimiAPIBalanceKeepsDecimalPrecisionAndAllowsNegativeCash() throws {
    let data = Data(#"{"code":0,"status":true,"data":{"available_balance":49.5889400000001,"voucher_balance":50.0000000000001,"cash_balance":-0.41106}}"#.utf8)
    let value = try KimiAPIBalanceAdapter(region: .china).parse(data: data)
    #expect(value.availableBalance == Decimal(string: "49.5889400000001"))
    #expect(value.cashBalance == Decimal(string: "-0.41106"))
}

@Test func deviceRecordIDsAreIndependentAndLegacyIDsStayStable() {
    #expect(RecordMapping.recordID(for: .kimiCode, collector: .mac).recordName == "snapshot-kimiCode-mac")
    #expect(RecordMapping.recordID(for: .kimiCode, collector: .iPhone).recordName == "snapshot-kimiCode-iphone")
    #expect(RecordMapping.recordID(for: .claudeCode, collector: .iPhone).recordName == "snapshot-claudeCode")
    #expect(RecordMapping.recordID(for: .cursor).recordName == "snapshot-cursor")
}

@Test func watchPrefersActivePhoneEvenWhenStaleThenFallsBackAfter48Hours() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let phone = QuotaSnapshot(tool: .kimiCode, plan: nil, windows: [], confidence: .stale,
        staleReason: .networkFailure, collectedBy: .iPhone, source: "test", updatedAt: now.addingTimeInterval(-47 * 3600))
    let mac = QuotaSnapshot(tool: .kimiCode, plan: nil, windows: [], confidence: .fresh,
        collectedBy: .mac, source: "test", updatedAt: now)
    #expect(WatchSnapshotSelection.choose(iPhone: phone, mac: mac, now: now)?.collectedBy == .iPhone)
    let inactive = QuotaSnapshot(tool: .kimiCode, plan: nil, windows: [], confidence: .stale,
        collectedBy: .iPhone, source: "test", updatedAt: now.addingTimeInterval(-49 * 3600))
    #expect(WatchSnapshotSelection.choose(iPhone: inactive, mac: mac, now: now)?.collectedBy == .mac)
    #expect(WatchSnapshotSelection.choose(iPhone: nil, mac: mac, now: now)?.collectedBy == .mac)
}

@Test func codingOperationGateRejectsRefreshInvalidatedByDisable() async {
    let gate = DeviceCodingOperationGate()
    let generation = await gate.begin(device: .iPhone, tool: .kimiCode)
    let deleted = await gate.invalidateAndPerform(device: .iPhone, tool: .kimiCode) { true }
    let staleCommit = await gate.performIfCurrent(
        device: .iPhone, tool: .kimiCode, generation: generation
    ) { true }
    #expect(deleted)
    #expect(staleCommit == nil)
}

@Test func collectorMapsInvalidatedCommitToSupersededInsteadOfSnapshot() {
    let snapshot = QuotaSnapshot(
        tool: .kimiCode,
        plan: nil,
        windows: [],
        confidence: .fresh,
        source: "test",
        updatedAt: Date()
    )
    guard case .superseded = DeviceCodingQuotaCollector.outcome(
        scoped: snapshot,
        saved: nil
    ) else {
        Issue.record("An invalidated refresh must not return a snapshot")
        return
    }
}

@Test func collectorKeepsFreshLocalFactWhenCloudSaveFails() async {
    let store = DeviceCodingTestStore(saveShouldFail: true)
    let collector = DeviceCodingQuotaCollector(
        device: .mac,
        sync: store,
        operationGate: DeviceCodingOperationGate()
    ) { tool, _ in
        QuotaSnapshot(
            tool: tool,
            plan: "test",
            windows: [],
            confidence: .fresh,
            source: "test",
            updatedAt: Date()
        )
    }

    let outcome = await collector.refresh(
        tool: .kimiCode,
        credential: CodingProviderCredential(secret: "secret", source: .manualKeychain)
    )

    guard case .snapshot(let snapshot, let cloudSync) = outcome else {
        Issue.record("A successful endpoint fetch must remain available locally")
        return
    }
    #expect(snapshot.confidence == .fresh)
    #expect(snapshot.staleReason == nil)
    #expect(cloudSync == .pending)
    #expect(await store.saveCount == 1)
}

@Test func collectorRefreshDisableRaceExercisesFullMutationPath() async {
    let fetchStarted = CodingTestLatch()
    let releaseFetch = CodingTestLatch()
    let store = DeviceCodingTestStore()
    let collector = DeviceCodingQuotaCollector(
        device: .mac,
        sync: store,
        operationGate: DeviceCodingOperationGate()
    ) { tool, _ in
        await fetchStarted.open()
        await releaseFetch.wait()
        return QuotaSnapshot(
            tool: tool,
            plan: "test",
            windows: [],
            confidence: .fresh,
            source: "test",
            updatedAt: Date()
        )
    }

    let refresh = Task {
        await collector.refresh(
            tool: .kimiCode,
            credential: CodingProviderCredential(secret: "secret", source: .manualKeychain)
        )
    }
    await fetchStarted.wait()
    try? await collector.disable(tool: .kimiCode)
    await releaseFetch.open()
    let outcome = await refresh.value

    guard case .superseded = outcome else {
        Issue.record("Disable must supersede a refresh that fetched before deletion")
        return
    }
    #expect(await store.deleteCount == 1)
    #expect(await store.saveCount == 0)
}

@Test func watchFallsBackOnlyForRecordLocalMappingErrors() {
    #expect(CloudKitSync.shouldFallBackToMac(
        afterIPhoneError: .mapping(CocoaError(.propertyListReadCorrupt))
    ))
    #expect(!CloudKitSync.shouldFallBackToMac(
        afterIPhoneError: .accountUnavailable
    ))
    #expect(!CloudKitSync.shouldFallBackToMac(
        afterIPhoneError: .cloudKit(CocoaError(.fileReadNoPermission))
    ))
}

private actor DeviceCodingTestStore: DeviceCodingSnapshotSyncing {
    private let saveShouldFail: Bool
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private var snapshot: QuotaSnapshot?

    init(saveShouldFail: Bool = false) {
        self.saveShouldFail = saveShouldFail
    }

    func save(_ snapshot: QuotaSnapshot, collector: QuotaCollectorDevice) async throws {
        saveCount += 1
        if saveShouldFail { throw TestError.expected }
        self.snapshot = snapshot.collected(on: collector)
    }

    func fetch(
        tool: ToolKind,
        collector: QuotaCollectorDevice
    ) async throws -> QuotaSnapshot? {
        snapshot?.tool == tool ? snapshot : nil
    }

    func delete(tool: ToolKind, collector: QuotaCollectorDevice) async throws {
        deleteCount += 1
        snapshot = nil
    }

    private enum TestError: Error {
        case expected
    }
}

private actor CodingTestLatch {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

@Test func newRequestGatesRejectOlderResults() {
    var kimiAPI = KimiAPIRequestGate()
    let firstKimi = kimiAPI.begin()
    let secondKimi = kimiAPI.begin()
    #expect(!kimiAPI.isCurrent(firstKimi))
    #expect(kimiAPI.isCurrent(secondKimi))

    var coding = DeviceCodingRequestGate()
    let firstCoding = coding.begin()
    let secondCoding = coding.begin()
    #expect(!coding.isCurrent(firstCoding))
    #expect(coding.isCurrent(secondCoding))
}
