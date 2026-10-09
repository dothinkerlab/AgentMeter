import Foundation
import Testing
@testable import AgentMeterCore

private let arkNow = Date(timeIntervalSince1970: 1_791_504_000 - 120)
private func planFixture(_ name: String) throws -> Data {
    try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!)
}

@Test func arkCodingParsesOfficialWindowFieldsAndPreservesSuccessTime() throws {
    let value = try ArkPlanAdapter(product: .coding).parse(data: planFixture("ark_coding_plan_sample"), now: arkNow)
    #expect(value.tool == .arkCoding)
    #expect(value.window(.fiveHour)?.usedPercent == 25)
    #expect(value.window(.sevenDay)?.usedPercent == 40)
    #expect(value.window(.monthly)?.usedPercent == 60)
    #expect(value.updatedAt == Date(timeIntervalSince1970: 1_791_503_940))
}
@Test func arkAgentConvertsAFPAndIncludesDaily() throws {
    let value = try ArkPlanAdapter(product: .agent).parse(data: planFixture("ark_agent_plan_sample"), now: arkNow)
    #expect(value.tool == .arkAgent)
    #expect(value.plan == "Large")
    #expect(value.windows.count == 4)
    #expect(value.window(.fiveHour)?.usedPercent == 2.5)
    #expect(value.window(.daily)?.usedPercent == 4.5)
    #expect(value.window(.sevenDay)?.usedPercent == 30)
    #expect(value.window(.monthly)?.resetsAt == Date(timeIntervalSince1970: 1_791_763_200))
}
@Test func arkRejectsMalformedWindowsAndDoesNotInventReset() throws {
    for field in ["true", "101", "-1", "\"NaN\""] {
        let data = Data("{\"Result\":{\"QuotaUsage\":[{\"Level\":\"Session\",\"Percent\":\(field)}]}}".utf8)
        #expect(throws: ArkPlanAdapter.FetchError.self) { try ArkPlanAdapter(product: .coding).parse(data: data, now: arkNow) }
    }
    let unknownReset = Data(#"{"Result":{"QuotaUsage":[{"Level":"Session","Percent":10,"ResetTimestamp":0}]}}"#.utf8)
    #expect(try ArkPlanAdapter(product: .coding).parse(data: unknownReset, now: arkNow).window(.fiveHour)?.resetsAt == nil)
    for body in [#"{"Result":null}"#, #"{"Result":{"QuotaUsage":[]}}"#,
                 #"{"Result":{"QuotaUsage":[{"Level":"other","Percent":0}]}}"#,
                 #"{"Result":{"AFPFiveHour":{"Used":"2","Quota":"1"}}}"#] {
        #expect(throws: ArkPlanAdapter.FetchError.self) { try ArkPlanAdapter(product: body.contains("AFPFive") ? .agent : .coding).parse(data: Data(body.utf8), now: arkNow) }
    }
}
@Test func arkBusinessErrorsAreExplicitAndOldServerDataIsStale() throws {
    let denied = Data(#"{"ResponseMetadata":{"Error":{"Code":"AccessDenied"}}}"#.utf8)
    #expect(throws: ArkPlanAdapter.FetchError.permissionDenied) { try ArkPlanAdapter(product: .coding).parse(data: denied) }
    let throttled = Data(#"{"ResponseMetadata":{"Error":{"Code":"Throttling"}}}"#.utf8)
    #expect(throws: ProviderRequestFailure.self) { try ArkPlanAdapter(product: .coding).parse(data: throttled) }
    let old = Data(#"{"Result":{"QuotaUsage":[{"Level":"Session","Percent":20}],"UpdateTimestamp":1791500000000}}"#.utf8)
    #expect(try ArkPlanAdapter(product: .coding).parse(data: old, now: arkNow).confidence == .stale)
}
@Test func arkSigningMatchesIndependentOfficialSDKAlgorithmVector() throws {
    let credentials = try ArkPlanCredentials(accessKeyID: "test-ak", secretAccessKey: "test-secret")
    let request = ArkPlanAdapter(product: .coding).request(credentials: credentials, now: Date(timeIntervalSince1970: 1_791_504_000))
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == Data("{}".utf8))
    #expect(request.url?.host == "ark.cn-beijing.volcengineapi.com")
    #expect(request.value(forHTTPHeaderField: "X-Date") == "20261009T000000Z")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "HMAC-SHA256 Credential=test-ak/20261009/cn-beijing/ark/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=3db1eaaaf1f9d26a9c5011ee77d9832c93aad7445cbca4ad6070dd67e5796e45")
    #expect(try ArkPlanCredentials.decode(credentials.encoded) == credentials)
    #expect(throws: ArkPlanAdapter.FetchError.self) { try ArkPlanCredentials(accessKeyID: "key\nHost: other", secretAccessKey: "secret") }
}
@Test func arkUsesStableRecordNamesAndMacOnlySource() {
    #expect(!ToolKind.arkCoding.supportsDeviceScopedSnapshots)
    #expect(RecordMapping.recordID(for: .arkCoding, collector: .mac).recordName == "snapshot-arkCoding")
    #expect(RecordMapping.recordID(for: .arkAgent, collector: .mac).recordName == "snapshot-arkAgent")
    #expect(PlanProviderKind.arkCoding.collectionMode == .macAutomatic)
}
@Test func miniMaxGeneralPoolUsesRemainingPercentAndExcludesVideo() throws {
    let value = try MiniMaxTokenPlanAdapter(region: .china).parse(data: planFixture("minimax_general_pool_sample"), now: arkNow)
    #expect(value.window(.fiveHour)?.usedPercent == 20)
    #expect(value.window(.sevenDay)?.usedPercent == 70)
    #expect(value.windows.count == 2)
}
@Test func miniMaxM3PoolsAreNeverSummedOrSelectedByVersion() throws {
    let row = #""current_interval_remaining_percent":70,"end_time":1791763200000"#
    let same = Data("{\"model_remains\":[{\"model_name\":\"MiniMax-M3\",\(row)},{\"model_name\":\"MiniMax-M2.7\",\(row)}]}".utf8)
    #expect(try MiniMaxTokenPlanAdapter(region: .global).parse(data: same, now: arkNow).window(.fiveHour)?.usedPercent == 30)
    let different = String(decoding: same, as: UTF8.self).replacingOccurrences(of: "MiniMax-M2.7\",\"current_interval_remaining_percent\":70", with: "MiniMax-M2.7\",\"current_interval_remaining_percent\":60")
    #expect(throws: MiniMaxTokenPlanAdapter.FetchError.self) { try MiniMaxTokenPlanAdapter(region: .global).parse(data: Data(different.utf8), now: arkNow) }
    let uncovered = Data(#"{"model_remains":[{"model_name":"MiniMax-M3","current_interval_status":3,"current_interval_remaining_percent":100,"end_time":1791763200000}]}"#.utf8)
    #expect(throws: MiniMaxTokenPlanAdapter.FetchError.self) { try MiniMaxTokenPlanAdapter(region: .global).parse(data: uncovered, now: arkNow) }
}

@Test func malformedPresentAFPAndInfiniteMiniMaxResetAreRejected() {
    let data = Data(#"{"Result":{"AFPFiveHour":false,"AFPWeekly":{"Used":"2","Quota":"10"}}}"#.utf8)
    #expect(throws: ArkPlanAdapter.FetchError.self) { try ArkPlanAdapter(product: .agent).parse(data: data, now: arkNow) }
    let invalid = Data(#"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":80,"end_time":"Infinity"}]}"#.utf8)
    #expect(throws: MiniMaxTokenPlanAdapter.FetchError.self) { try MiniMaxTokenPlanAdapter(region: .china).parse(data: invalid, now: arkNow) }
}
