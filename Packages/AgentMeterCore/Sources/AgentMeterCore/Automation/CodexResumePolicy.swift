import Foundation

/// Local automation evidence. Deliberately separate from the display/CloudKit QuotaSnapshot.
public struct CodexResumeQuota: Sendable {
    public struct Window: Sendable {
        public let id: String
        public let usedPercent: Double
        public let resetsAt: Date
        public init(id: String, usedPercent: Double, resetsAt: Date) {
            self.id = id; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        }
    }
    public let accountID: String
    public let limitID: String
    public let observedAt: Date
    public let windows: [Window]
    public init(accountID: String, limitID: String, observedAt: Date, windows: [Window]) {
        self.accountID = accountID; self.limitID = limitID
        self.observedAt = observedAt; self.windows = windows
    }
}

public struct CodexResumeSessionEvidence: Sendable {
    public let threadID: String
    public let latestTurnID: String
    public let accountID: String
    public let isIdle: Bool
    public let isArchived: Bool
    public let observedAt: Date
    public init(threadID: String, latestTurnID: String, accountID: String,
                isIdle: Bool, isArchived: Bool, observedAt: Date) {
        self.threadID = threadID; self.latestTurnID = latestTurnID; self.accountID = accountID
        self.isIdle = isIdle; self.isArchived = isArchived; self.observedAt = observedAt
    }
}

public enum CodexResumeDecision: Equatable, Sendable {
    case needsVerification
    case waiting(until: Date?)
    case ready
}

public enum CodexResumePolicy {
    public static func evaluate(_ candidate: CodexResumeCandidate, quota: CodexResumeQuota?,
                                session: CodexResumeSessionEvidence?, now: Date) -> CodexResumeDecision {
        guard candidate.state == .pending, candidate.runtimeEvidenceVerified,
              let account = candidate.accountID, !account.isEmpty,
              let limit = candidate.limitID, !limit.isEmpty,
              !candidate.requiredWindowIDs.isEmpty,
              let quota, quota.accountID == account, quota.limitID == limit,
              quota.observedAt >= candidate.detectedAt,
              (0...60).contains(now.timeIntervalSince(quota.observedAt)),
              let session, session.threadID == candidate.threadID,
              session.latestTurnID == candidate.failedTurnID, session.accountID == account,
              session.isIdle, !session.isArchived,
              session.observedAt >= candidate.detectedAt,
              (0...15).contains(now.timeIntervalSince(session.observedAt)),
              !quota.windows.isEmpty,
              Set(quota.windows.map(\.id)).count == quota.windows.count,
              Set(candidate.requiredWindowIDs).isSubset(of: Set(quota.windows.map(\.id))),
              quota.windows.allSatisfy({ !$0.id.isEmpty && $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                  && $0.resetsAt.timeIntervalSince1970.isFinite }) else { return .needsVerification }

        let blocking = quota.windows.filter { $0.usedPercent >= 100 }
        if !blocking.isEmpty {
            // A timestamp is a check schedule, never proof that quota has recovered.
            let latestReset = blocking.map(\.resetsAt).max()!
            return .waiting(until: latestReset > now ? latestReset.addingTimeInterval(20) : nil)
        }
        // A supposedly fresh response with expired windows is not sufficient evidence.
        guard quota.windows.allSatisfy({ $0.resetsAt > now }) else { return .needsVerification }
        return .ready
    }
}
