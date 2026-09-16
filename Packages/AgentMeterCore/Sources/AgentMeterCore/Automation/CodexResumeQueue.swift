import Foundation

public struct CodexResumeCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case pending, cancelled, superseded, attempting, submitted, resumed, failed, uncertain
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

    public mutating func insert(_ candidate: CodexResumeCandidate) {
        guard !candidate.threadID.isEmpty, !candidate.failedTurnID.isEmpty,
              lastActivityByThread[candidate.threadID].map({ candidate.detectedAt <= $0 }) != true,
              !candidates.contains(where: { $0.id == candidate.id }) else { return }
        var incoming = candidate
        let newerExists = candidates.contains {
            $0.detectedAt > candidate.detectedAt || ($0.detectedAt == candidate.detectedAt && $0.id > candidate.id)
        }
        if newerExists {
            incoming.state = .superseded
        } else {
            // Latest-only means older sessions never become automatic fallback work.
            for index in candidates.indices where candidates[index].state == .pending {
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
        guard let candidate = latestPending, candidate.id == id,
              !candidates.contains(where: { [.attempting, .submitted, .uncertain].contains($0.state) }),
              CodexResumePolicy.evaluate(candidate, quota: quota, session: session, now: now) == .ready,
              let index = candidates.firstIndex(where: { $0.id == id }) else { return false }
        candidates[index].state = .attempting
        return true
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
