import Foundation
import Testing
@testable import AgentMeterCore

struct CodexResetCreditExpiryReconciliationTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func duplicateRefreshDoesNotScheduleAgain() {
        let candidate = candidate(fireOffset: 3600, expiresOffset: 300_000)
        let ledger = [candidate.identifier: entry(for: candidate)]
        let plan = CodexResetCreditExpiryReconciler.plan(
            candidates: [candidate],
            pendingIdentifiers: [candidate.identifier],
            ledger: ledger,
            now: now
        )
        #expect(plan.candidatesToSchedule.isEmpty)
        #expect(plan.identifiersToCancel.isEmpty)
    }

    @Test func redeemedCreditCancelsPendingAndDropsLedger() {
        let candidate = candidate(fireOffset: 3600, expiresOffset: 300_000)
        let plan = CodexResetCreditExpiryReconciler.plan(
            candidates: [],
            pendingIdentifiers: [candidate.identifier],
            ledger: [candidate.identifier: entry(for: candidate)],
            now: now
        )
        #expect(plan.identifiersToCancel == [candidate.identifier])
        #expect(plan.retainedLedger.isEmpty)
    }

    @Test func disablingKeepsFiredEntryButDropsFutureEntry() {
        let fired = candidate(fireOffset: -1, expiresOffset: 1000)
        let future = candidate(fireOffset: 3600, expiresOffset: 300_000, grantedOffset: -200)
        let result = CodexResetCreditExpiryReconciler.ledgerWhenDisabled(
            [fired.identifier: entry(for: fired), future.identifier: entry(for: future)],
            now: now
        )
        #expect(Set(result.keys) == [fired.identifier])
    }

    @Test func reenableRestoresFutureAlertAfterDisable() {
        let future = candidate(fireOffset: 3600, expiresOffset: 300_000)
        let disabledLedger = CodexResetCreditExpiryReconciler.ledgerWhenDisabled(
            [future.identifier: entry(for: future)], now: now
        )
        let plan = CodexResetCreditExpiryReconciler.plan(
            candidates: [future], pendingIdentifiers: [], ledger: disabledLedger, now: now
        )
        #expect(plan.candidatesToSchedule == [future])
    }

    @Test func firedImmediateAlertDoesNotRepeatAfterNotificationIsCleared() {
        let immediate = candidate(fireOffset: 0, expiresOffset: 1000)
        let plan = CodexResetCreditExpiryReconciler.plan(
            candidates: [immediate],
            pendingIdentifiers: [],
            ledger: [immediate.identifier: entry(for: immediate)],
            now: now.addingTimeInterval(1)
        )
        #expect(plan.candidatesToSchedule.isEmpty)
    }

    private func candidate(
        fireOffset: TimeInterval,
        expiresOffset: TimeInterval,
        grantedOffset: TimeInterval = -100
    ) -> CodexResetCreditExpiryAlertCandidate {
        let credit = RateLimitResetCredit(
            grantedAt: now.addingTimeInterval(grantedOffset),
            expiresAt: now.addingTimeInterval(expiresOffset)
        )
        return CodexResetCreditExpiryAlertCandidate(
            credit: credit,
            expiresAt: now.addingTimeInterval(expiresOffset),
            fireAt: now.addingTimeInterval(fireOffset),
            isImmediate: fireOffset <= 0,
            snapshotUpdatedAt: now
        )
    }

    private func entry(
        for candidate: CodexResetCreditExpiryAlertCandidate
    ) -> CodexResetCreditExpiryLedgerEntry {
        CodexResetCreditExpiryLedgerEntry(
            fireAt: candidate.fireAt,
            expiresAt: candidate.expiresAt
        )
    }
}
