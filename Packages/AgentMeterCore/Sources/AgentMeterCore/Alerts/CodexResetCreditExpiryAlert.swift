import Foundation

public struct CodexResetCreditExpiryAlertCandidate: Sendable, Equatable {
    public let credit: RateLimitResetCredit
    public let expiresAt: Date
    public let fireAt: Date
    public let isImmediate: Bool
    public let snapshotUpdatedAt: Date

    public init(
        credit: RateLimitResetCredit,
        expiresAt: Date,
        fireAt: Date,
        isImmediate: Bool,
        snapshotUpdatedAt: Date
    ) {
        self.credit = credit
        self.expiresAt = expiresAt
        self.fireAt = fireAt
        self.isImmediate = isImmediate
        self.snapshotUpdatedAt = snapshotUpdatedAt
    }

    public var identifier: String {
        "agentmeter.codex.resetCredit.expiry.\(credit.stableKey)"
    }
}

public enum CodexResetCreditExpiryAlertPlanner {
    public static let leadTime: TimeInterval = 3 * 24 * 60 * 60
    public static let freshnessThreshold: TimeInterval = 15 * 60

    /// 只用 fresh 且未超过阈值的 Mac 采集数据生成候选；stale/unknown 不参与通知决策。
    public static func candidates(
        from snapshots: [QuotaSnapshot],
        now: Date = Date()
    ) -> [CodexResetCreditExpiryAlertCandidate] {
        guard let snapshot = snapshots.first(where: { $0.tool == .codex }),
              let resetCredits = snapshot.resetCredits,
              resetCredits.confidence == .fresh,
              now.timeIntervalSince(resetCredits.updatedAt) <= freshnessThreshold,
              now.timeIntervalSince(resetCredits.updatedAt) >= -freshnessThreshold,
              let availableCount = resetCredits.availableCount,
              availableCount > 0 else {
            return []
        }

        return resetCredits.credits
            .compactMap { credit -> CodexResetCreditExpiryAlertCandidate? in
                guard let expiresAt = credit.expiresAt, expiresAt > now else { return nil }
                let normalFireAt = expiresAt.addingTimeInterval(-leadTime)
                return CodexResetCreditExpiryAlertCandidate(
                    credit: credit,
                    expiresAt: expiresAt,
                    fireAt: max(normalFireAt, now),
                    isImmediate: normalFireAt <= now,
                    snapshotUpdatedAt: resetCredits.updatedAt
                )
            }
            .sorted { $0.expiresAt < $1.expiresAt }
            .prefix(availableCount)
            .map { $0 }
    }
}
