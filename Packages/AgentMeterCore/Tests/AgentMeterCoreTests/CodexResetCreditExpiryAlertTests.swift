import Foundation
import Testing
@testable import AgentMeterCore

struct CodexResetCreditExpiryAlertTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func schedulesExactlyThreeDaysBeforeExpiration() throws {
        let expiresAt = now.addingTimeInterval(10 * 24 * 60 * 60)
        let candidate = try #require(CodexResetCreditExpiryAlertPlanner.candidates(
            from: [snapshot(expiresAt: expiresAt)], now: now
        ).first)
        #expect(candidate.fireAt == expiresAt.addingTimeInterval(-3 * 24 * 60 * 60))
        #expect(!candidate.isImmediate)
    }

    @Test func insideWindowSchedulesImmediateCandidate() throws {
        let expiresAt = now.addingTimeInterval(2 * 24 * 60 * 60)
        let candidate = try #require(CodexResetCreditExpiryAlertPlanner.candidates(
            from: [snapshot(expiresAt: expiresAt)], now: now
        ).first)
        #expect(candidate.fireAt == now)
        #expect(candidate.isImmediate)
    }

    @Test func staleUnknownExpiredAndMissingExpirationDoNotSchedule() {
        #expect(CodexResetCreditExpiryAlertPlanner.candidates(
            from: [snapshot(expiresAt: now.addingTimeInterval(10), confidence: .stale)], now: now
        ).isEmpty)
        #expect(CodexResetCreditExpiryAlertPlanner.candidates(
            from: [snapshot(expiresAt: now.addingTimeInterval(-1))], now: now
        ).isEmpty)
        #expect(CodexResetCreditExpiryAlertPlanner.candidates(
            from: [snapshot(expiresAt: nil)], now: now
        ).isEmpty)
    }

    @Test func oldFreshPayloadDoesNotSchedule() {
        let snapshot = snapshot(
            expiresAt: now.addingTimeInterval(10 * 24 * 60 * 60),
            updatedAt: now.addingTimeInterval(-16 * 60)
        )
        #expect(CodexResetCreditExpiryAlertPlanner.candidates(from: [snapshot], now: now).isEmpty)
    }

    @Test func countLimitsCandidatesWhenDetailsDisagree() {
        let credits = RateLimitResetCredits(
            availableCount: 1,
            credits: [
                credit(grantedOffset: -100, expiresOffset: 5 * 24 * 60 * 60),
                credit(grantedOffset: -50, expiresOffset: 6 * 24 * 60 * 60)
            ],
            confidence: .fresh,
            updatedAt: now
        )
        let snapshot = QuotaSnapshot(
            tool: .codex, plan: nil, windows: [], resetCredits: credits,
            confidence: .fresh, source: "test", updatedAt: now
        )
        #expect(CodexResetCreditExpiryAlertPlanner.candidates(from: [snapshot], now: now).count == 1)
    }

    private func snapshot(
        expiresAt: Date?,
        confidence: DataConfidence = .fresh,
        updatedAt: Date? = nil
    ) -> QuotaSnapshot {
        let resetCredits = RateLimitResetCredits(
            availableCount: confidence == .unknown ? nil : 1,
            credits: [RateLimitResetCredit(
                grantedAt: now.addingTimeInterval(-100),
                expiresAt: expiresAt
            )],
            confidence: confidence,
            updatedAt: updatedAt ?? now
        )
        return QuotaSnapshot(
            tool: .codex, plan: nil, windows: [], resetCredits: resetCredits,
            confidence: .fresh, source: "test", updatedAt: now
        )
    }

    private func credit(grantedOffset: TimeInterval, expiresOffset: TimeInterval) -> RateLimitResetCredit {
        RateLimitResetCredit(
            grantedAt: now.addingTimeInterval(grantedOffset),
            expiresAt: now.addingTimeInterval(expiresOffset)
        )
    }
}
