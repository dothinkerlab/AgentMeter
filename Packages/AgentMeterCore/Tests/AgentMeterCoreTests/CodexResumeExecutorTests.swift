import Foundation
import Testing
@testable import AgentMeterCore

@MainActor
struct CodexResumeExecutorTests {
    enum Failure: Error { case simulated }
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func savesBeforeSendingAndWaitsForExecution() async {
        let transport = MockTransport(evidence: evidence())
        var saved: [CodexResumeCandidate.State] = []
        let executor = executor { saved.append($0.candidates[0].state) }
        transport.beforeSubmit = { #expect(saved == [.attempting]) }
        transport.beforeObserve = { #expect(saved == [.attempting, .submitted]) }
        #expect(await executor.executeLatest(using: transport) == .resumed)
        #expect(saved == [.attempting, .submitted, .resumed])
        #expect(transport.operations == [executor.queue.candidates[0].id])
        #expect(await executor.executeLatest(using: transport) == .noCandidate)
        #expect(transport.operations.count == 1)
    }

    @Test func storageFailurePreventsSend() async {
        let transport = MockTransport(evidence: evidence())
        let executor = executor { _ in throw Failure.simulated }
        #expect(await executor.executeLatest(using: transport) == .storageFailed)
        #expect(transport.operations.isEmpty)
        #expect(await executor.executeLatest(using: transport) == .storageFailed)
    }

    @Test func failedReceiptSavePreservesDurableAttemptAndBlocksRetry() async {
        let transport = MockTransport(evidence: evidence())
        var durable = queue()
        let executor = executor {
            if $0.candidates[0].state == .submitted { throw Failure.simulated }
            durable = $0
        }
        #expect(await executor.executeLatest(using: transport) == .storageFailed)
        #expect(durable.candidates[0].state == .attempting)
        durable.recoverAfterRestart()
        #expect(durable.candidates[0].state == .uncertain)
        #expect(await executor.executeLatest(using: transport) == .storageFailed)
        #expect(transport.operations.count == 1)
    }

    @Test func lostReceiptIsUncertainAndNeverRetries() async {
        let transport = MockTransport(evidence: evidence())
        transport.throwOnSubmit = true
        let executor = executor { _ in }
        #expect(await executor.executeLatest(using: transport) == .uncertain)
        #expect(executor.queue.candidates[0].state == .uncertain)
        #expect(await executor.executeLatest(using: transport) == .noCandidate)
        #expect(transport.operations.count == 1)
    }

    @Test func wrongThreadOldTurnAndUncertainObservationNeverSucceed() async {
        for receipt in [CodexResumeSubmission.submitted(threadID: "other", turnID: "new"),
                        .submitted(threadID: "thread", turnID: "failed"),
                        .submitted(threadID: "thread", turnID: "")] {
            let transport = MockTransport(evidence: evidence()); transport.receipt = receipt
            let executor = executor { _ in }
            #expect(await executor.executeLatest(using: transport) == .uncertain)
        }
        for observation in [CodexResumeExecution(threadID: "other", turnID: "new", status: .ran),
                            .init(threadID: "thread", turnID: "other", status: .ran),
                            .init(threadID: "thread", turnID: "new", status: .unknown)] {
            let transport = MockTransport(evidence: evidence()); transport.observation = observation
            #expect(await executor { _ in }.executeLatest(using: transport) == .uncertain)
        }
    }

    @Test func ownershipQuotaAndStaleEvidencePreventSending() async {
        for evidence in [evidence(verified: false), evidence(used: 100), evidence(age: 61), evidence(turn: "changed")] {
            let transport = MockTransport(evidence: evidence)
            let result = await executor { _ in }.executeLatest(using: transport)
            #expect(result != .resumed)
            #expect(transport.operations.isEmpty)
        }
    }

    @Test func localCandidateCannotAuthorizeSend() async {
        var local = CodexResumeQueue()
        local.insert(.init(threadID: "thread", failedTurnID: "failed", detectedAt: now.addingTimeInterval(-100)))
        let executor = CodexResumeExecutor(queue: local, now: { now }, save: { _ in })
        let transport = MockTransport(evidence: evidence())
        #expect(await executor.executeLatest(using: transport) == .needsVerification)
        #expect(transport.operations.isEmpty)
    }

    @Test func cancelledPreflightDoesNotSend() async {
        let executor = executor { _ in }
        let transport = MockTransport(evidence: evidence())
        transport.beforePreflight = { executor.cancel() }
        #expect(await executor.executeLatest(using: transport) == .cancelled)
        #expect(transport.operations.isEmpty)
    }

    @Test func cancellationDuringSubmissionIsUncertain() async {
        let executor = executor { _ in }
        let transport = MockTransport(evidence: evidence())
        transport.beforeSubmit = { executor.cancel() }
        #expect(await executor.executeLatest(using: transport) == .uncertain)
        #expect(executor.queue.candidates[0].submittedTurnID == "new")
        #expect(transport.observations == 0)
    }

    @Test func rejectionAndExecutionFailureAreTerminal() async {
        let rejected = MockTransport(evidence: evidence()); rejected.receipt = .notSent
        let first = executor { _ in }
        #expect(await first.executeLatest(using: rejected) == .failed)
        #expect(await first.executeLatest(using: rejected) == .noCandidate)
        let failed = MockTransport(evidence: evidence())
        failed.observation = .init(threadID: "thread", turnID: "new", status: .failed)
        #expect(await executor { _ in }.executeLatest(using: failed) == .failed)
    }

    @Test func reentrantRequestCannotSendAgain() async {
        let executor = executor { _ in }
        let transport = MockTransport(evidence: evidence())
        transport.duringPreflight = { #expect(await executor.executeLatest(using: transport) == .busy) }
        #expect(await executor.executeLatest(using: transport) == .resumed)
        #expect(transport.operations.count == 1)
    }

    @Test func queuedReceiptWithoutCorrelationRemainsUncertain() async {
        let transport = MockTransport(evidence: evidence())
        transport.receipt = .queued(threadID: "thread", messageID: "message")
        let executor = executor { _ in }
        #expect(await executor.executeLatest(using: transport) == .uncertain)
        #expect(executor.queue.candidates[0].queuedMessageID == "message")
        #expect(executor.queue.candidates[0].submittedTurnID == nil)
        #expect(await executor.executeLatest(using: transport) == .noCandidate)
    }

    @Test func queuedReceiptWithStrictCorrelationConfirmsSeparateTurn() async {
        let transport = MockTransport(evidence: evidence())
        transport.receipt = .queued(threadID: "thread", messageID: "message")
        transport.queuedObservation = .init(threadID: "thread", turnID: "new-turn", status: .ran)
        let executor = executor { _ in }
        #expect(await executor.executeLatest(using: transport) == .resumed)
        #expect(executor.queue.candidates[0].queuedMessageID == "message")
        #expect(executor.queue.candidates[0].submittedTurnID == "new-turn")
    }

    private func executor(save: @escaping (CodexResumeQueue) throws -> Void) -> CodexResumeExecutor {
        CodexResumeExecutor(queue: queue(), now: { now }, save: save)
    }
    private func queue() -> CodexResumeQueue {
        var q = CodexResumeQueue()
        q.insert(.init(threadID: "thread", failedTurnID: "failed", detectedAt: now.addingTimeInterval(-120),
                       accountID: "account", limitID: "codex", requiredWindowIDs: ["primary"], runtimeEvidenceVerified: true))
        return q
    }
    private func evidence(verified: Bool = true, used: Double = 1, age: Double = 0, turn: String = "failed") -> CodexResumePreflight {
        .init(originalDesktopVerified: verified,
              quota: .init(accountID: "account", limitID: "codex", observedAt: now.addingTimeInterval(-age),
                           windows: [.init(id: "primary", usedPercent: used, resetsAt: now.addingTimeInterval(3600))], blockingState: .clear),
              session: .init(threadID: "thread", latestTurnID: turn, accountID: "account", isIdle: true,
                             isArchived: false, observedAt: now.addingTimeInterval(-age)))
    }
}

@MainActor
private final class MockTransport: CodexResumeTransport {
    let evidence: CodexResumePreflight
    var queuedObservation: CodexResumeExecution?
    var operations: [String] = []
    var observations = 0
    var beforePreflight: () -> Void = {}
    var duringPreflight: () async -> Void = {}
    var beforeSubmit: () -> Void = {}
    var beforeObserve: () -> Void = {}
    var throwOnSubmit = false
    var receipt = CodexResumeSubmission.submitted(threadID: "thread", turnID: "new")
    var observation = CodexResumeExecution(threadID: "thread", turnID: "new", status: .ran)
    init(evidence: CodexResumePreflight) { self.evidence = evidence }
    func preflight(candidate: CodexResumeCandidate) async throws -> CodexResumePreflight {
        beforePreflight(); await duringPreflight(); return evidence
    }
    func submitContinue(candidate: CodexResumeCandidate, operationID: String) async throws -> CodexResumeSubmission {
        operations.append(operationID); beforeSubmit()
        if throwOnSubmit { throw CodexResumeExecutorTests.Failure.simulated }
        return receipt
    }
    func observeQueuedMessage(threadID: String, messageID: String) async throws -> CodexResumeExecution? {
        queuedObservation
    }
    func observeExecution(threadID: String, turnID: String) async throws -> CodexResumeExecution {
        observations += 1; beforeObserve(); return observation
    }
}
