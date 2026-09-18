import Foundation
import Testing
@testable import AgentMeterCore

struct CodexResumeUsageTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func realEndpointShapeAuthorizesMatchingAccount() throws {
        let usage = try CodexResumeUsage.parse(data(), accountID: "account", now: now)
        #expect(usage.decision == .ready)
        #expect(usage.accountID == "account")
    }

    @Test func waitsForLatestExhaustedWindowPlusTwentySeconds() throws {
        let usage = try CodexResumeUsage.parse(data(primary: 100, secondary: 100, allowed: false, reached: true), accountID: "account", now: now)
        #expect(usage.decision == .waiting(now.addingTimeInterval(7220)))
    }

    @Test func allowedFlagAndRestrictionOverridePercentages() throws {
        #expect(try CodexResumeUsage.parse(data(allowed: false), accountID: "account", now: now).decision == .waiting(nil))
        #expect(try CodexResumeUsage.parse(data(spend: true), accountID: "account", now: now).decision == .restricted)
        #expect(try CodexResumeUsage.parse(data(classification: "workspace_member_credits_depleted"), accountID: "account", now: now).decision == .restricted)
        #expect(try CodexResumeUsage.parse(data(classification: "future_limit_type"), accountID: "account", now: now).decision == .restricted)
    }

    @Test func rejectsWrongAccountExpiredWindowsAndOutOfRangePercentages() {
        #expect(throws: (any Error).self) { try CodexResumeUsage.parse(data(), accountID: "other", now: now) }
        #expect(throws: (any Error).self) { try CodexResumeUsage.parse(data(resetOffset: -1), accountID: "account", now: now) }
        #expect(throws: (any Error).self) { try CodexResumeUsage.parse(data(primary: -1), accountID: "account", now: now) }
        #expect(throws: (any Error).self) { try CodexResumeUsage.parse(data(secondary: 101), accountID: "account", now: now) }
    }

    @Test func missingFlagsAndUnknownSpendShapeFailClosed() throws {
        for key in ["account_id", "rate_limit_reached_type", "spend_control"] {
            var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
            object.removeValue(forKey: key)
            let json = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try CodexResumeUsage.parse(json, accountID: "account", now: now) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        object["spend_control"] = ["unknown": false]
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try CodexResumeUsage.parse(json, accountID: "account", now: now) }
    }

    @Test func checksAdditionalModelLimitsInsteadOfIgnoringThem() throws {
        var object = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        let exhausted = try #require(JSONSerialization.jsonObject(with: data(primary: 100)) as? [String: Any])
        object["additional_rate_limits"] = [["limit_name": "another-model", "rate_limit": exhausted["rate_limit"]!]]
        let usage = try CodexResumeUsage.parse(JSONSerialization.data(withJSONObject: object), accountID: "account", now: now)
        #expect(usage.decision == .waiting(now.addingTimeInterval(3620)))
    }

    private func data(primary: Double = 17, secondary: Double = 71, allowed: Bool = true,
                      reached: Bool = false, spend: Bool = false, classification: String? = nil,
                      resetOffset: Double = 3600) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "account_id": "account",
            "rate_limit": ["allowed": allowed, "limit_reached": reached,
                "primary_window": ["used_percent": primary, "limit_window_seconds": 18000, "reset_at": now.timeIntervalSince1970 + resetOffset],
                "secondary_window": ["used_percent": secondary, "limit_window_seconds": 604800, "reset_at": now.timeIntervalSince1970 + 7200]],
            "additional_rate_limits": NSNull(), "rate_limit_reached_type": classification as Any? ?? NSNull(),
            "spend_control": ["reached": spend, "individual_limit": NSNull()]
        ])
    }
}
