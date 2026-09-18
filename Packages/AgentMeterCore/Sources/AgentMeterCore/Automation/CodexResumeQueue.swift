import Foundation

public struct CodexResumeCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending, cancelled, superseded, attempting, submitted, observed, resumed, failed, uncertain
    }
    public let threadID: String
    public let failedTurnID: String
    public let detectedAt: Date
    public let projectName: String?
    public let accountID: String?
    public let limitID: String?
    public let requiredWindowIDs: [String]
    public let runtimeEvidenceVerified: Bool
    public fileprivate(set) var state: State = .pending
    public fileprivate(set) var submittedTurnID: String?
    public fileprivate(set) var queuedMessageID: String?
    /// Length prefixes prevent delimiter collisions. No reset timestamp in identity.
    public var id: String { "\(threadID.utf8.count):\(threadID)\(failedTurnID.utf8.count):\(failedTurnID)" }

    public init(threadID: String, failedTurnID: String, detectedAt: Date, projectName: String? = nil,
                accountID: String? = nil, limitID: String? = nil, requiredWindowIDs: [String] = [],
                runtimeEvidenceVerified: Bool = false) {
        self.threadID = threadID; self.failedTurnID = failedTurnID; self.detectedAt = detectedAt
        self.projectName = projectName; self.accountID = accountID; self.limitID = limitID
        self.requiredWindowIDs = requiredWindowIDs; self.runtimeEvidenceVerified = runtimeEvidenceVerified
    }
}

public struct CodexResumeQueue: Codable, Equatable, Sendable {
    public private(set) var candidates: [CodexResumeCandidate] = []
    private var lastActivityByThread: [String: Date] = [:]
    public init() {}

    public var latestPending: CodexResumeCandidate? {
        candidates.filter { $0.state == .pending }.max {
            $0.detectedAt == $1.detectedAt ? $0.id < $1.id : $0.detectedAt < $1.detectedAt
        }
    }

    public var pendingInOrder: [CodexResumeCandidate] {
        candidates.filter { $0.state == .pending }.sorted {
            $0.detectedAt == $1.detectedAt ? $0.id < $1.id : $0.detectedAt < $1.detectedAt
        }
    }

    public mutating func insert(_ candidate: CodexResumeCandidate) {
        guard !candidate.threadID.isEmpty, !candidate.failedTurnID.isEmpty,
              lastActivityByThread[candidate.threadID].map({ candidate.detectedAt <= $0 }) != true,
              !candidates.contains(where: { $0.id == candidate.id }) else { return }
        var incoming = candidate
        let newerExists = candidates.contains {
            $0.threadID == candidate.threadID &&
                ($0.detectedAt > candidate.detectedAt || ($0.detectedAt == candidate.detectedAt && $0.id > candidate.id))
        }
        if newerExists {
            incoming.state = .superseded
        } else {
            // Only a newer failure in the same thread supersedes its pending predecessor.
            for index in candidates.indices where candidates[index].state == .pending
                && candidates[index].threadID == candidate.threadID {
                candidates[index].state = .superseded
            }
        }
        candidates.append(incoming)
    }

    public mutating func cancel(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return }
        candidates[index].state = .cancelled
    }

    public mutating func cancelPending() {
        for index in candidates.indices where candidates[index].state == .pending {
            candidates[index].state = .cancelled
        }
    }

    public mutating func invalidate(threadID: String, at: Date) {
        lastActivityByThread[threadID] = max(lastActivityByThread[threadID] ?? .distantPast, at)
        for index in candidates.indices where candidates[index].threadID == threadID
            && candidates[index].detectedAt <= at && candidates[index].state == .pending {
            candidates[index].state = .superseded
        }
    }

    /// The caller MUST durably save this transition before invoking any transport.
    /// There is deliberately no automatic retry transition from uncertain/failed.
    @discardableResult
    public mutating func beginAttempt(id: String, quota: CodexResumeQuota?,
                                      session: CodexResumeSessionEvidence?, now: Date) -> Bool {
        guard let candidate = candidates.first(where: { $0.id == id && $0.state == .pending }),
              !candidates.contains(where: { [.attempting, .submitted].contains($0.state) ||
                  ($0.threadID == candidate.threadID && $0.state == .uncertain) }),
              CodexResumePolicy.evaluate(candidate, quota: quota, session: session, now: now) == .ready,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return false }
        candidates[index].state = .attempting
        return true
    }

    /// Explicit user-triggered recovery still shares the same durable lifecycle and sender lock.
    public mutating func beginManualAttempt(id: String) -> Bool { beginLocalAttempt(id: id) }

    /// Caller must validate fresh endpoint quota, account binding and local session evidence first.
    /// This does not label local evidence as an authenticated runtime preflight.
    public mutating func beginLocalAttempt(id: String) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .pending }),
              !candidates.contains(where: { [.attempting, .submitted].contains($0.state) }) else { return false }
        candidates[index].state = .attempting
        return true
    }

    /// Only before the sender has reserved an attempt file or invoked the queue command.
    public mutating func deferUnsentAttempt(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .attempting }) else { return }
        candidates[index].state = .pending
    }

    public mutating func recordQueued(id: String, messageID: String) {
        guard !messageID.isEmpty,
              let index = candidates.firstIndex(where: { $0.id == id && $0.state == .attempting }) else { return }
        candidates[index].queuedMessageID = messageID
        candidates[index].state = .submitted
    }

    public mutating func bindQueuedTurn(id: String, turnID: String) {
        guard !turnID.isEmpty, let index = candidates.firstIndex(where: {
            $0.id == id && $0.state == .submitted && $0.queuedMessageID != nil && $0.failedTurnID != turnID
        }) else { return }
        candidates[index].submittedTurnID = turnID
    }

    public mutating func recordObserved(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .submitted }) else { return }
        candidates[index].state = .observed
    }

    public mutating func recordSubmission(id: String, turnID: String) {
        guard !turnID.isEmpty, let index = candidates.firstIndex(where: { $0.id == id && $0.state == .attempting }),
              turnID != candidates[index].failedTurnID else { return }
        candidates[index].state = .submitted
        candidates[index].submittedTurnID = turnID
    }

    /// A user-message echo or turn/started alone is not evidence of resumed model execution.
    public mutating func recordExecution(id: String, turnID: String, didRun: Bool) {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .submitted }),
              candidates[index].submittedTurnID == turnID else { return }
        candidates[index].state = didRun ? .resumed : .failed
    }

    public mutating func recoverAfterRestart() {
        for index in candidates.indices where [.attempting, .submitted].contains(candidates[index].state) {
            candidates[index].state = .uncertain
        }
    }

    /// A transport may have submitted even when its response was lost. Never retry this state.
    public mutating func recordUncertain(id: String) {
        guard let index = candidates.firstIndex(where: {
            $0.id == id && [.attempting, .submitted].contains($0.state)
        }) else { return }
        candidates[index].state = .uncertain
    }

    /// Only for cancellation before the transport was invoked, or an explicit no-send receipt.
    public mutating func recordNotSent(id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id && $0.state == .attempting }) else { return }
        candidates[index].state = .failed
    }
}
