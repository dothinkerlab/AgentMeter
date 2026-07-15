import Foundation

/// Codex 账户中可用的 banked rate-limit resets。
///
/// 它不是百分比额度窗口，因此不复用 `QuotaWindow`。数据仍由 Mac 采集并随
/// `QuotaSnapshot` 写入 Private CloudKit；iPhone / Watch 只消费这里的清洗结果。
public struct RateLimitResetCredits: Codable, Sendable, Equatable {
    public static let source = "codex_rate_limit_reset_credits_endpoint"

    /// 服务端报告的可用次数。unknown 时必须为 nil，不能用 0 冒充真实值。
    public let availableCount: Int?
    /// 仅包含服务端状态为 available 的明细；次数仍以 availableCount 为准。
    public let credits: [RateLimitResetCredit]
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    /// 最近一次真正成功获取 reset credits 的时间。
    public let updatedAt: Date

    public init(
        availableCount: Int?,
        credits: [RateLimitResetCredit],
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String = Self.source,
        updatedAt: Date
    ) {
        self.availableCount = confidence == .unknown ? nil : availableCount
        self.credits = credits.sorted {
            switch ($0.expiresAt, $1.expiresAt) {
            case let (lhs?, rhs?): return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.grantedAt < $1.grantedAt
            }
        }
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public var nearestExpiration: Date? {
        credits.compactMap(\.expiresAt).min()
    }

    public var hasIncompleteExpirationDetails: Bool {
        guard let availableCount, availableCount > 0 else { return false }
        return credits.count < availableCount || credits.contains { $0.expiresAt == nil }
    }

    public func markedStale(reason: QuotaStaleReason? = nil) -> RateLimitResetCredits {
        RateLimitResetCredits(
            availableCount: availableCount,
            credits: credits,
            confidence: .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }

    public static func unknown(
        now: Date = Date(),
        reason: QuotaStaleReason? = nil
    ) -> RateLimitResetCredits {
        RateLimitResetCredits(
            availableCount: nil,
            credits: [],
            confidence: .unknown,
            staleReason: reason,
            updatedAt: now
        )
    }
}

public struct RateLimitResetCredit: Codable, Sendable, Equatable, Hashable {
    public let grantedAt: Date
    public let expiresAt: Date?

    public init(grantedAt: Date, expiresAt: Date?) {
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }

    /// 跨端通知去重使用，不包含上游可用于 consume 的 creditId。
    public var stableKey: String {
        let granted = Int64((grantedAt.timeIntervalSince1970 * 1_000).rounded())
        let expires = expiresAt.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded()) } ?? -1
        return "\(granted)-\(expires)"
    }
}
