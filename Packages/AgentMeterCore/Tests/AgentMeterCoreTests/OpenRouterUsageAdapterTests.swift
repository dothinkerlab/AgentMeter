import Foundation
import Testing
@testable import AgentMeterCore

struct OpenRouterUsageAdapterTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesUsageLimitAndBYOK() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let usage = try OpenRouterUsageAdapter().parse(
            data: try fixture("openrouter_usage_sample"), now: now)

        #expect(usage.keyLabel == "AgentMeter")
        #expect(usage.usage == Decimal(string: "25.5"))
        #expect(usage.usageDaily == Decimal(string: "1.25"))
        #expect(usage.usageWeekly == Decimal(string: "8.75"))
        #expect(usage.usageMonthly == Decimal(string: "25.5"))
        #expect(usage.limit == Decimal(100))
        #expect(usage.limitRemaining == Decimal(string: "74.5"))
        #expect(usage.limitReset == "monthly")
        #expect(usage.hasBYOKUsage)
        #expect(usage.confidence == .fresh)
        #expect(usage.updatedAt == now)
        #expect(usage.expiresAt != nil)
    }

    @Test func parsesUnlimitedKey() throws {
        let json = #"""
        {"data": {
          "label": "Unlimited", "limit": null, "limit_remaining": null, "limit_reset": null,
          "include_byok_in_limit": false,
          "usage": 1, "usage_daily": 0.1, "usage_weekly": 0.5, "usage_monthly": 1,
          "byok_usage": 0, "byok_usage_daily": 0, "byok_usage_weekly": 0, "byok_usage_monthly": 0,
          "expires_at": null
        }}
        """#
        let usage = try OpenRouterUsageAdapter().parse(data: Data(json.utf8))
        #expect(usage.limit == nil)
        #expect(usage.limitRemaining == nil)
        #expect(!usage.hasBYOKUsage)
    }

    @Test func supportsEveryDocumentedResetCycle() throws {
        for reset in ["daily", "weekly", "monthly"] {
            let json = #"""
            {"data": {
              "label": null, "limit": 10, "limit_remaining": 9, "limit_reset": "\#(reset)",
              "include_byok_in_limit": true,
              "usage": 1, "usage_daily": 1, "usage_weekly": 1, "usage_monthly": 1,
              "byok_usage": 0, "byok_usage_daily": 0, "byok_usage_weekly": 0, "byok_usage_monthly": 0,
              "expires_at": null
            }}
            """#
            let usage = try OpenRouterUsageAdapter().parse(data: Data(json.utf8))
            #expect(usage.limitReset == reset)
            #expect(usage.includeBYOKInLimit)
        }
    }

    @Test func malformedOrInvalidResponseThrowsDecode() {
        let invalid = [
            "not json",
            #"{"data":{"usage":-1}}"#,
            #"{"data":{"label":null,"limit":null,"limit_remaining":1,"limit_reset":null,"include_byok_in_limit":false,"usage":1,"usage_daily":1,"usage_weekly":1,"usage_monthly":1,"byok_usage":0,"byok_usage_daily":0,"byok_usage_weekly":0,"byok_usage_monthly":0,"expires_at":null}}"#,
        ]
        for json in invalid {
            #expect(throws: OpenRouterUsageAdapter.FetchError.self) {
                try OpenRouterUsageAdapter().parse(data: Data(json.utf8))
            }
        }
    }

    @Test func staleAndUnknownNeverInventFreshZero() throws {
        let fresh = try OpenRouterUsageAdapter().parse(data: try fixture("openrouter_usage_sample"))
        let stale = OpenRouterUsage.degraded(from: fresh, reason: .networkFailure)
        #expect(stale.confidence == .stale)
        #expect(stale.usage == fresh.usage)
        #expect(stale.updatedAt == fresh.updatedAt)

        let unknown = OpenRouterUsage.degraded(from: nil, reason: .authExpired)
        #expect(unknown.confidence == .unknown)
        #expect(!unknown.hasKnownUsage)
        #expect(unknown.usage == 0)
    }

    @Test func requestGateOnlyAcceptsLatestGeneration() {
        var gate = OpenRouterRequestGate()
        let first = gate.begin()
        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    @Test func errorCategoriesMapToStaleReasons() {
        #expect(OpenRouterUsageAdapter.staleReason(for: OpenRouterUsageAdapter.FetchError.unauthorized) == .authExpired)
        #expect(OpenRouterUsageAdapter.staleReason(for: OpenRouterUsageAdapter.FetchError.transport("timeout")) == .networkFailure)
        #expect(OpenRouterUsageAdapter.staleReason(for: OpenRouterUsageAdapter.FetchError.httpStatus(500)) == .endpointFailure)
        #expect(OpenRouterUsageAdapter.staleReason(for: OpenRouterUsageAdapter.FetchError.decode("bad")) == .responseChanged)
    }
}
