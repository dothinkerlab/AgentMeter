import Foundation

/// Implement only for an authenticated connection to the original Desktop runtime.
/// Each operation must have a bounded timeout. A local rollout or separate CLI is insufficient.
@MainActor
public protocol CodexResumeTransport {
    func preflight(candidate: CodexResumeCandidate) async throws -> CodexResumePreflight
    /// The implementation must reject without sending if the failed turn, idle state, account,
    /// quota or original runtime ownership changed. Do not turn a read/start race into a guarantee.
    /// Always submit exactly "继续", without changing model, permissions or other thread settings.
    func submitContinue(candidate: CodexResumeCandidate, operationID: String) async throws -> CodexResumeSubmission
    func observeQueuedMessage(threadID: String, messageID: String) async throws -> CodexResumeExecution?
    func observeExecution(threadID: String, turnID: String) async throws -> CodexResumeExecution
}

public extension CodexResumeTransport {
    func observeQueuedMessage(threadID: String, messageID: String) async throws -> CodexResumeExecution? { nil }
}

public struct CodexResumePreflight: Sendable {
    public let originalDesktopVerified: Bool
    public let quota: CodexResumeQuota?
    public let session: CodexResumeSessionEvidence?
    public init(originalDesktopVerified: Bool, quota: CodexResumeQuota?, session: CodexResumeSessionEvidence?) {
        self.originalDesktopVerified = originalDesktopVerified; self.quota = quota; self.session = session
    }
}

public enum CodexResumeSubmission: Sendable {
    /// Explicit rejection before any message was sent. Timeouts must throw instead.
    case notSent
    case submitted(threadID: String, turnID: String)
    case queued(threadID: String, messageID: String)
}

public struct CodexResumeExecution: Sendable {
    public enum Status: Sendable { case ran, failed, unknown }
    public let threadID: String
    public let turnID: String
    public let status: Status
    public init(threadID: String, turnID: String, status: Status) {
        self.threadID = threadID; self.turnID = turnID; self.status = status
    }
}

/// Single in-process owner of a durable queue. Production must not construct concurrent owners
/// for the same store. No concrete Desktop sender is enabled by this orchestration layer.
@MainActor
public final class CodexResumeExecutor {
    public enum Result: Equatable {
        case busy, noCandidate, needsVerification, waiting(until: Date?), cancelled
        case resumed, failed, uncertain, storageFailed
    }
    public private(set) var queue: CodexResumeQueue
    public private(set) var isExecuting = false
    public private(set) var storageFailed = false
    private let save: (CodexResumeQueue) throws -> Void
    private let now: () -> Date
    private var cancelled = false

    /// `save` must atomically and durably commit before returning, alongside any scanner offsets.
    public init(queue: CodexResumeQueue, now: @escaping () -> Date = Date.init,
                save: @escaping (CodexResumeQueue) throws -> Void) {
        self.queue = queue; self.now = now; self.save = save
    }

    public func cancel() { cancelled = true }

    public func executeLatest(using transport: any CodexResumeTransport) async -> Result {
        await execute(candidateID: queue.latestPending?.id, using: transport)
    }

    public func execute(candidateID: String?, using transport: any CodexResumeTransport) async -> Result {
        guard !isExecuting else { return .busy }
        guard !storageFailed else { return .storageFailed }
        guard let candidate = queue.candidates.first(where: { $0.id == candidateID && $0.state == .pending }) else { return .noCandidate }
        // Fail closed before contacting a transport when another attempt is unresolved.
        guard !queue.candidates.contains(where: { [.attempting, .submitted].contains($0.state) ||
            ($0.threadID == candidate.threadID && $0.state == .uncertain) }) else {
            return .uncertain
        }
        isExecuting = true; cancelled = false
        defer { isExecuting = false }
        let evidence: CodexResumePreflight
        do { evidence = try await transport.preflight(candidate: candidate) }
        catch { return stopped ? .cancelled : .needsVerification }
        guard !stopped else { return .cancelled }
        guard evidence.originalDesktopVerified else { return .needsVerification }
        let decision = CodexResumePolicy.evaluate(candidate, quota: evidence.quota, session: evidence.session, now: now())
        switch decision {
        case .needsVerification: return .needsVerification
        case .waiting(let date): return .waiting(until: date)
        case .ready: break
        }
        var next = queue
        guard next.beginAttempt(id: candidate.id, quota: evidence.quota, session: evidence.session, now: now()) else {
            return .needsVerification
        }
        guard commit(next) else { return .storageFailed }
        guard !stopped else { return finish(candidate.id, uncertain: false) }
        do {
            // Candidate identity is a stable operation key, NOT a promise of server-side deduplication.
            let receipt = try await transport.submitContinue(candidate: candidate, operationID: candidate.id)
            switch receipt {
            case .notSent: return finish(candidate.id, uncertain: false)
            case .queued(let threadID, let messageID):
                guard threadID == candidate.threadID, !messageID.isEmpty else {
                    return finish(candidate.id, uncertain: true)
                }
                next = queue
                next.recordQueued(id: candidate.id, messageID: messageID)
                guard commit(next) else { return .storageFailed }
                guard !stopped,
                      let execution = try await transport.observeQueuedMessage(threadID: threadID, messageID: messageID),
                      !stopped, execution.threadID == threadID, !execution.turnID.isEmpty,
                      execution.turnID != candidate.failedTurnID, execution.status != .unknown else {
                    return finish(candidate.id, uncertain: true)
                }
                // Only a transport with strict message-to-turn evidence may return an execution.
                next = queue
                next.bindQueuedTurn(id: candidate.id, turnID: execution.turnID)
                next.recordExecution(id: candidate.id, turnID: execution.turnID, didRun: execution.status == .ran)
                return commit(next) ? (execution.status == .ran ? .resumed : .failed) : .storageFailed
            case .submitted(let threadID, let turnID):
                guard threadID == candidate.threadID, !turnID.isEmpty, turnID != candidate.failedTurnID else {
                    return finish(candidate.id, uncertain: true)
                }
                next = queue
                next.recordSubmission(id: candidate.id, turnID: turnID)
                guard commit(next) else { return .storageFailed }
                guard !stopped else { return finish(candidate.id, uncertain: true) }
                let execution = try await transport.observeExecution(threadID: threadID, turnID: turnID)
                guard !stopped, execution.threadID == threadID, execution.turnID == turnID else {
                    return finish(candidate.id, uncertain: true)
                }
                switch execution.status {
                case .unknown: return finish(candidate.id, uncertain: true)
                case .ran, .failed:
                    next = queue
                    let ran = execution.status == .ran
                    next.recordExecution(id: candidate.id, turnID: turnID, didRun: ran)
                    return commit(next) ? (ran ? .resumed : .failed) : .storageFailed
                }
            }
        } catch {
            // Cancellation after invoking submit has the same ambiguity as a lost response.
            return finish(candidate.id, uncertain: true)
        }
    }

    private var stopped: Bool { cancelled || Task.isCancelled }
    private func finish(_ id: String, uncertain: Bool) -> Result {
        var next = queue
        if uncertain { next.recordUncertain(id: id) } else { next.recordNotSent(id: id) }
        return commit(next) ? (uncertain ? .uncertain : .failed) : .storageFailed
    }
    private func commit(_ next: CodexResumeQueue) -> Bool {
        do { try save(next); queue = next; return true }
        catch { storageFailed = true; return false }
    }
}
