import Foundation
import Testing
@testable import AgentMeterCore

struct FiveHourResetAlertTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func freshDepletedFiveHourCreatesCandidateAtResetTime() {
        let resetsAt = now.addingTimeInterval(3600)
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: resetsAt, kind: .fiveHour)]
        )

        let candidate = FiveHourResetAlertPlanner.candidate(from: snapshot, now: now)

        #expect(candidate?.tool == .claudeCode)
        #expect(candidate?.resetsAt == resetsAt)
        #expect(candidate?.identifier == FiveHourResetAlertCandidate.identifier(tool: .claudeCode, resetsAt: resetsAt))
    }

    @Test func staleSnapshotDoesNotCreateCandidate() {
        let snapshot = snapshot(
            confidence: .stale,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(3600), kind: .fiveHour)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(from: snapshot, now: now) == nil)
    }

    @Test func unknownSnapshotDoesNotCreateCandidate() {
        let snapshot = snapshot(
            confidence: .unknown,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(3600), kind: .fiveHour)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(from: snapshot, now: now) == nil)
    }

    @Test func missingFiveHourWindowDoesNotCreateCandidate() {
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(3600), kind: .sevenDay)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(from: snapshot, now: now) == nil)
    }

    @Test func nonDepletedFiveHourDoesNotCreateCandidate() {
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 99, resetsAt: now.addingTimeInterval(3600), kind: .fiveHour)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(from: snapshot, now: now) == nil)
    }

    @Test func pastResetTimeDoesNotCreateCandidate() {
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(-1), kind: .fiveHour)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(from: snapshot, now: now) == nil)
    }

    @Test func existingIdentifierSuppressesDuplicateCandidate() {
        let resetsAt = now.addingTimeInterval(3600)
        let existing = FiveHourResetAlertCandidate.identifier(tool: .claudeCode, resetsAt: resetsAt)
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: resetsAt, kind: .fiveHour)]
        )

        #expect(FiveHourResetAlertPlanner.candidate(
            from: snapshot,
            now: now,
            existingIdentifiers: [existing]
        ) == nil)
    }

    @Test func changedResetTimeCreatesNewCandidate() {
        let oldReset = now.addingTimeInterval(3600)
        let newReset = now.addingTimeInterval(7200)
        let snapshot = snapshot(
            confidence: .fresh,
            windows: [QuotaWindow(usedPercent: 100, resetsAt: newReset, kind: .fiveHour)]
        )

        let candidate = FiveHourResetAlertPlanner.candidate(
            from: snapshot,
            now: now,
            existingIdentifiers: [FiveHourResetAlertCandidate.identifier(tool: .claudeCode, resetsAt: oldReset)]
        )

        #expect(candidate?.resetsAt == newReset)
    }

    private func snapshot(
        confidence: DataConfidence,
        windows: [QuotaWindow],
        tool: ToolKind = .claudeCode
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            plan: nil,
            windows: windows,
            confidence: confidence,
            source: "test",
            updatedAt: now.addingTimeInterval(-60)
        )
    }
}
