import Foundation
import Testing
@testable import AgentMeterCore

struct CodexResumePolicyTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func waitsForAllBlockingWindows() {
        let decision = CodexResumePolicy.evaluate(candidate(), quota: quota(short: 100, weekly: 100), session: session(), now: now)
        #expect(decision == .waiting(until: now.addingTimeInterval(7220)))
        #expect(CodexResumePolicy.evaluate(candidate(), quota: quota(short: 0, weekly: 100), session: session(), now: now)
                == .waiting(until: now.addingTimeInterval(7220)))
    }

    @Test func expiredResetDoesNotProveRecovery() {
        let expired = CodexResumeQuota(accountID: "account", limitID: "codex", observedAt: now, windows: [
            .init(id: "short", usedPercent: 100, resetsAt: now.addingTimeInterval(-1)),
            .init(id: "week", usedPercent: 0, resetsAt: now.addingTimeInterval(7200))
        ], blockingState: .windowLimit)
        #expect(CodexResumePolicy.evaluate(candidate(), quota: expired, session: session(), now: now) == .waiting(until: nil))
    }

    @Test func onlyFreshMatchingEvidenceIsReady() {
        #expect(CodexResumePolicy.evaluate(candidate(), quota: quota(), session: session(), now: now) == .ready)
        for q in [quota(account: "other"), quota(limit: "other"), quota(age: 61), quota(age: -1)] {
            #expect(CodexResumePolicy.evaluate(candidate(), quota: q, session: session(), now: now) == .needsVerification)
        }
        for s in [session(turn: "new-turn"), session(account: "other"), session(idle: false), session(archived: true), session(age: 16)] {
            #expect(CodexResumePolicy.evaluate(candidate(), quota: quota(), session: s, now: now) == .needsVerification)
        }
        #expect(CodexResumePolicy.evaluate(candidate(), quota: nil, session: session(), now: now) == .needsVerification)
    }

    @Test func missingDuplicateAndInvalidWindowsFailClosed() {
        let invalid: [[CodexResumeQuota.Window]] = [
            [], [.init(id: "short", usedPercent: 0, resetsAt: now.addingTimeInterval(60))],
            [.init(id: "short", usedPercent: .nan, resetsAt: now.addingTimeInterval(60)), .init(id: "week", usedPercent: 0, resetsAt: now.addingTimeInterval(60))],
            [.init(id: "short", usedPercent: 0, resetsAt: now.addingTimeInterval(60)), .init(id: "short", usedPercent: 0, resetsAt: now.addingTimeInterval(60))]
        ]
        for windows in invalid {
            let q = CodexResumeQuota(accountID: "account", limitID: "codex", observedAt: now, windows: windows, blockingState: .clear)
            #expect(CodexResumePolicy.evaluate(candidate(), quota: q, session: session(), now: now) == .needsVerification)
        }
    }

    @Test func localLogCannotAuthorizeSending() {
        let local = CodexResumeCandidate(threadID: "thread", failedTurnID: "failed", detectedAt: now.addingTimeInterval(-120))
        #expect(CodexResumePolicy.evaluate(local, quota: quota(), session: session(), now: now) == .needsVerification)
        var queue = CodexResumeQueue()
        queue.insert(local)
        let began = queue.beginAttempt(id: local.id, quota: quota(), session: session(), now: now)
        #expect(!began)
    }

    @Test func accountRestrictionsAndUnknownStateCannotResume() {
        for state in [CodexResumeQuota.BlockingState.unknown, .windowLimit, .accountRestriction] {
            let q = CodexResumeQuota(accountID: "account", limitID: "codex", observedAt: now,
                                     windows: quota().windows, blockingState: state)
            #expect(CodexResumePolicy.evaluate(candidate(), quota: q, session: session(), now: now) != .ready)
        }
    }

    @Test func latestOnlyNeverFallsBackToOldSessions() {
        var queue = CodexResumeQueue()
        let old = candidate(turn: "old", age: 180)
        let newest = candidate()
        queue.insert(newest)
        queue.insert(old) // File enumeration can deliver events out of chronological order.
        #expect(queue.latestPending?.id == newest.id)
        queue.cancel(id: newest.id)
        queue.insert(newest) // Replayed event must not undo cancellation.
        #expect(queue.latestPending == nil)
        #expect(queue.candidates.count == 2)
    }

    @Test func manualActivityInvalidatesPendingCandidate() {
        var queue = CodexResumeQueue()
        queue.insert(candidate())
        queue.invalidate(threadID: "other", at: now)
        #expect(queue.latestPending != nil)
        queue.invalidate(threadID: "thread", at: now)
        #expect(queue.latestPending == nil)
    }

    @Test func activityObservedBeforeAnOlderFilePreventsStaleCandidate() throws {
        var queue = CodexResumeQueue()
        queue.invalidate(threadID: "thread", at: now)
        var restored = try JSONDecoder().decode(CodexResumeQueue.self, from: JSONEncoder().encode(queue))
        restored.insert(candidate())
        #expect(restored.latestPending == nil)
    }

    @Test func attemptRequiresPersistenceAndCannotBeRepeatedAfterRestart() throws {
        var queue = CodexResumeQueue()
        let item = candidate()
        queue.insert(item)
        let first = queue.beginAttempt(id: item.id, quota: quota(), session: session(), now: now)
        let repeated = queue.beginAttempt(id: item.id, quota: quota(), session: session(), now: now)
        #expect(first)
        #expect(!repeated)
        var restored = try JSONDecoder().decode(CodexResumeQueue.self, from: JSONEncoder().encode(queue))
        restored.recoverAfterRestart()
        #expect(restored.candidates.first?.state == .uncertain)
        let afterRestart = restored.beginAttempt(id: item.id, quota: quota(), session: session(), now: now)
        #expect(!afterRestart)
    }

    @Test func submissionIsNotExecutionAndVerificationMatchesTurn() {
        var queue = CodexResumeQueue()
        let item = candidate()
        queue.insert(item)
        let began = queue.beginAttempt(id: item.id, quota: quota(), session: session(), now: now)
        #expect(began)
        queue.recordSubmission(id: item.id, turnID: "new")
        #expect(queue.candidates.first?.state == .submitted)
        queue.recordExecution(id: item.id, turnID: "wrong", didRun: true)
        #expect(queue.candidates.first?.state == .submitted)
        queue.recordExecution(id: item.id, turnID: "new", didRun: true)
        #expect(queue.candidates.first?.state == .resumed)
    }

    private func candidate(turn: String = "failed", age: Double = 120) -> CodexResumeCandidate {
        .init(threadID: "thread", failedTurnID: turn, detectedAt: now.addingTimeInterval(-age),
              accountID: "account", limitID: "codex", requiredWindowIDs: ["short", "week"], runtimeEvidenceVerified: true)
    }
    private func quota(short: Double = 0, weekly: Double = 0, account: String = "account", limit: String = "codex", age: Double = 0) -> CodexResumeQuota {
        .init(accountID: account, limitID: limit, observedAt: now.addingTimeInterval(-age), windows: [
            .init(id: "short", usedPercent: short, resetsAt: now.addingTimeInterval(3600)),
            .init(id: "week", usedPercent: weekly, resetsAt: now.addingTimeInterval(7200))
        ], blockingState: .clear)
    }
    private func session(turn: String = "failed", account: String = "account", idle: Bool = true, archived: Bool = false, age: Double = 0) -> CodexResumeSessionEvidence {
        .init(threadID: "thread", latestTurnID: turn, accountID: account, isIdle: idle, isArchived: archived, observedAt: now.addingTimeInterval(-age))
    }
}
