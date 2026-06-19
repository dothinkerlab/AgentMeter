import Foundation
import Testing
@testable import AgentMeterCore

struct CodexPlanAdapterTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesPlanAndWindowsSkippingNulls() throws {
        let data = try fixture("codex_usage_sample")
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = try CodexPlanAdapter().parse(data: data, now: now)

        #expect(snapshot.tool == .codex)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.confidence == .fresh)
        #expect(snapshot.source == "codex_plan_usage_endpoint")
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.window(.monthly) == nil)
    }

    @Test func keepsWhamUsedPercentAsUsedPercent() throws {
        let snapshot = try CodexPlanAdapter().parse(data: try fixture("codex_usage_sample"))
        let fiveHour = try #require(snapshot.window(.fiveHour))
        let weekly = try #require(snapshot.window(.sevenDay))

        #expect(fiveHour.usedPercent == 27.5)
        #expect(fiveHour.remainingPercent == 72.5)
        #expect(weekly.usedPercent == 59.0)
        #expect(weekly.remainingPercent == 41.0)
    }

    @Test func convertsRemainingPercentToUsedPercent() throws {
        let data = Data(#"""
        {
          "usage": {
            "five_hour": {
              "remaining_percent": 72.5,
              "resets_at": "2026-06-14T20:59:59+00:00"
            }
          }
        }
        """#.utf8)
        let snapshot = try CodexPlanAdapter().parse(data: data)
        let fiveHour = try #require(snapshot.window(.fiveHour))
        #expect(fiveHour.usedPercent == 27.5)
        #expect(fiveHour.remainingPercent == 72.5)
    }

    @Test func explicitPlanOverridesResponsePlan() throws {
        let snapshot = try CodexPlanAdapter().parse(
            data: try fixture("codex_usage_sample"),
            plan: "Pro"
        )
        #expect(snapshot.plan == "Pro")
    }

    @Test func clampsRemainingPercentBeforeStoringUsedPercent() throws {
        let high = Data(#"{ "five_hour": { "remaining": 125, "resets_at": "2026-06-14T20:59:59+00:00" } }"#.utf8)
        let low = Data(#"{ "five_hour": { "remaining": -5, "resets_at": "2026-06-14T20:59:59+00:00" } }"#.utf8)

        let highWindow = try #require(CodexPlanAdapter().parse(data: high).window(.fiveHour))
        let lowWindow = try #require(CodexPlanAdapter().parse(data: low).window(.fiveHour))

        #expect(highWindow.usedPercent == 0)
        #expect(lowWindow.usedPercent == 100)
    }

    @Test func malformedJSONThrowsDecodeError() {
        let bad = Data("{ not json".utf8)
        #expect(throws: CodexPlanAdapter.FetchError.self) {
            try CodexPlanAdapter().parse(data: bad)
        }
    }

    @Test func emptyObjectThrowsDecodeErrorInsteadOfFreshEmptySnapshot() {
        #expect(throws: CodexPlanAdapter.FetchError.self) {
            try CodexPlanAdapter().parse(data: Data("{}".utf8))
        }
    }

    @Test func snapshotRoundTripsThroughJSONCodable() throws {
        let snapshot = try CodexPlanAdapter().parse(data: try fixture("codex_usage_sample"))
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: encoded)
        #expect(decoded == snapshot)
    }
}
