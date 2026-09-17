import Foundation
import AgentMeterCore

/// Shares the manual sender's exclusive on-disk reservation across processes and restarts.
/// Wrapping a transport does not grant it runtime ownership or conditional-submit capabilities.
@MainActor
struct CodexRecordedResumeTransport: CodexResumeTransport {
    let base: any CodexResumeTransport
    let target: CodexQueueTarget
    let store: CodexQueueAttemptStore

    func preflight(candidate: CodexResumeCandidate) async throws -> CodexResumePreflight {
        try target.revalidate()
        return try await base.preflight(candidate: candidate)
    }

    func submitContinue(candidate: CodexResumeCandidate, operationID: String) async throws -> CodexResumeSubmission {
        guard candidate.threadID == target.threadID, candidate.failedTurnID == target.failedTurnID else { return .notSent }
        try target.revalidate()
        let reservation = try store.reserve(target)
        defer { try? reservation.close() }
        do {
            try target.revalidate()
            let receipt = try await base.submitContinue(candidate: candidate, operationID: operationID)
            if case .queued(let threadID, let messageID) = receipt {
                guard threadID == target.threadID, UUID(uuidString: messageID) != nil else { throw CodexDesktopQueueError.uncertain }
                try store.record(reservation, target: target, state: "queued", messageID: messageID)
            }
            return receipt
        } catch {
            try? store.record(reservation, target: target, state: "uncertain", messageID: nil)
            throw error
        }
    }

    func observeQueuedMessage(threadID: String, messageID: String) async throws -> CodexResumeExecution? {
        try await base.observeQueuedMessage(threadID: threadID, messageID: messageID)
    }

    func observeExecution(threadID: String, turnID: String) async throws -> CodexResumeExecution {
        try await base.observeExecution(threadID: threadID, turnID: turnID)
    }
}
