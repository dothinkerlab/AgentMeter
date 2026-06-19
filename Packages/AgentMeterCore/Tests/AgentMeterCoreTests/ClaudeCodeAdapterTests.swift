import Foundation
import Testing
@testable import AgentMeterCore

struct ClaudeCodeAdapterTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesAllPresentWindowsSkippingNulls() throws {
        let data = try fixture("usage_sample")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = try ClaudeCodeAdapter().parse(data: data, now: now)

        #expect(snapshot.tool == .claudeCode)
        #expect(snapshot.confidence == .fresh)
        #expect(snapshot.source == "oauth_usage_endpoint")
        #expect(snapshot.updatedAt == now)
        // five_hour / seven_day / seven_day_sonnet 三个;seven_day_opus 为 null 跳过。
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.window(.sevenDayOpus) == nil)
    }

    @Test func keepsUtilizationAsUsedPercentWithoutInversion() throws {
        let snapshot = try ClaudeCodeAdapter().parse(data: try fixture("usage_sample"))
        let fiveHour = try #require(snapshot.window(.fiveHour))
        // 端点 utilization=37 是"已用",直接入库为 usedPercent;remaining 才是 63。
        #expect(fiveHour.usedPercent == 37.0)
        #expect(fiveHour.remainingPercent == 63.0)
    }

    @Test func parsesISO8601ResetWithOffset() throws {
        let snapshot = try ClaudeCodeAdapter().parse(data: try fixture("usage_sample"))
        let fiveHour = try #require(snapshot.window(.fiveHour))
        // 2026-06-14T20:59:59+00:00
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 14
        comps.hour = 20; comps.minute = 59; comps.second = 59
        comps.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: comps)!
        #expect(abs(fiveHour.resetsAt.timeIntervalSince(expected)) < 1)
    }

    @Test func tightestWindowPicksHighestUsedAmongPrimaryWindows() throws {
        let snapshot = try ClaudeCodeAdapter().parse(data: try fixture("usage_sample"))
        // five_hour 已用 37 > seven_day 26 → 5 小时窗口更紧,先卡住用户。
        let tightest = try #require(snapshot.tightestWindow)
        #expect(tightest.kind == .fiveHour)
    }

    @Test func malformedJSONThrowsDecodeError() {
        let bad = Data("{ not json".utf8)
        #expect(throws: ClaudeCodeAdapter.FetchError.self) {
            try ClaudeCodeAdapter().parse(data: bad)
        }
    }

    @Test func emptyObjectYieldsZeroWindowsNotCrash() throws {
        let snapshot = try ClaudeCodeAdapter().parse(data: Data("{}".utf8))
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.tightestWindow == nil)
        #expect(snapshot.confidence == .fresh)
    }

    @Test func snapshotRoundTripsThroughJSONCodable() throws {
        let snapshot = try ClaudeCodeAdapter().parse(data: try fixture("usage_sample"))
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}
