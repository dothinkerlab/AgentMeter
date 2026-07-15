import Foundation
import Testing
@testable import AgentMeterCore

struct GrokAPIUsageAdapterTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func parsesAndAggregatesCalendarPeriods() throws {
        let json = #"""
        {
          "timeSeries": [
            {"dataPoints": [
              {"timestamp":"2026-07-01T00:00:00Z","values":[1.10]},
              {"timestamp":"2026-07-06T00:00:00Z","values":[2.20]},
              {"timestamp":"2026-07-13T00:00:00Z","values":[3.30,0.40]}
            ]},
            {"dataPoints": [
              {"timestamp":"2026-07-13T00:00:00Z","values":[0.25]}
            ]}
          ],
          "limitReached": false
        }
        """#
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-13T12:00:00Z"))
        let usage = try GrokAPIUsageAdapter().parseUsage(
            data: Data(json.utf8),
            calendar: utcCalendar,
            now: now
        )

        #expect(usage.daily == Decimal(string: "3.95"))
        #expect(usage.weekly == Decimal(string: "3.95"))
        #expect(usage.monthly == Decimal(string: "7.25"))
    }

    @Test func parsesCentsWithoutLosingPrecision() throws {
        let adapter = GrokAPIUsageAdapter()
        let balance = try adapter.parsePrepaidBalance(
            data: Data(#"{"changes":[],"total":{"val":"-12345"}}"#.utf8)
        )
        let limit = try adapter.parsePostpaidLimit(
            data: Data(#"{"spendingLimits":{"effectiveSl":{"val":"20000"}}}"#.utf8)
        )
        #expect(balance == Decimal(string: "123.45"))
        #expect(limit == Decimal(string: "200"))
    }

    @Test func rejectsUnreliableAmountsAndUsage() {
        let adapter = GrokAPIUsageAdapter()
        #expect(throws: GrokAPIUsageAdapter.FetchError.self) {
            try adapter.parsePrepaidBalance(data: Data(#"{"total":{"val":"100"}}"#.utf8))
        }
        #expect(throws: GrokAPIUsageAdapter.FetchError.self) {
            try adapter.parsePostpaidLimit(
                data: Data(#"{"spendingLimits":{"effectiveSl":{"val":"-1"}}}"#.utf8)
            )
        }
        let usage = #"{"timeSeries":[{"dataPoints":[{"timestamp":"2026-07-13T00:00:00Z","values":[-1]}]}]}"#
        #expect(throws: GrokAPIUsageAdapter.FetchError.self) {
            try adapter.parseUsage(data: Data(usage.utf8), calendar: utcCalendar)
        }
    }

    @Test func staleAndUnknownPreserveTrustBoundary() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let fresh = GrokAPIUsage(
            usageDaily: 1,
            usageWeekly: 2,
            usageMonthly: 3,
            prepaidBalance: 10,
            postpaidMonthlyLimit: 100,
            confidence: .fresh,
            source: GrokAPIUsageAdapter.source,
            updatedAt: now
        )
        let stale = GrokAPIUsage.degraded(from: fresh, reason: .networkFailure)
        #expect(stale.confidence == .stale)
        #expect(stale.usageMonthly == 3)
        #expect(stale.updatedAt == now)

        let unknown = GrokAPIUsage.degraded(from: nil, reason: .authExpired, now: now)
        #expect(unknown.confidence == .unknown)
        #expect(!unknown.hasKnownUsage)
        #expect(unknown.staleReason == .authExpired)
    }

    @Test func requestGateOnlyAcceptsLatestGeneration() {
        var gate = GrokRequestGate()
        let first = gate.begin()
        let second = gate.begin()
        #expect(!gate.isCurrent(first))
        #expect(gate.isCurrent(second))
    }

    @Test func errorCategoriesMapToStaleReasons() {
        #expect(GrokAPIUsageAdapter.staleReason(for: GrokAPIUsageAdapter.FetchError.unauthorized) == .authExpired)
        #expect(GrokAPIUsageAdapter.staleReason(for: GrokAPIUsageAdapter.FetchError.transport("timeout")) == .networkFailure)
        #expect(GrokAPIUsageAdapter.staleReason(for: GrokAPIUsageAdapter.FetchError.httpStatus(500)) == .endpointFailure)
        #expect(GrokAPIUsageAdapter.staleReason(for: GrokAPIUsageAdapter.FetchError.decode("bad")) == .responseChanged)
    }
}
