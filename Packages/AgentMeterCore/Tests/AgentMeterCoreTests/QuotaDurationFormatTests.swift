import Testing
@testable import AgentMeterCore

struct QuotaDurationFormatTests {
    @Test func shortDurationUsesMinutesBelowOneHour() {
        #expect(QuotaDurationFormat.short(seconds: 59 * 60) == "59m")
    }

    @Test func shortDurationUsesHoursBelowOneDay() {
        #expect(QuotaDurationFormat.short(seconds: 23 * 3_600 + 15 * 60) == "23h15m")
    }

    @Test func shortDurationUsesDaysAtOneDayAndAbove() {
        #expect(QuotaDurationFormat.short(seconds: 24 * 3_600) == "1d0h")
        #expect(QuotaDurationFormat.short(seconds: 49 * 3_600 + 15 * 60) == "2d1h")
    }
}
