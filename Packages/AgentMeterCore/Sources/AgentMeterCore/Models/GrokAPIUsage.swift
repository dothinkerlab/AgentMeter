import Foundation

/// xAI Management API 返回的团队级 xAI API 账单摘要。
///
/// 这是本地旁路模型：Mac/iPhone 各自持 Management Key、各自查询，
/// 不进入 QuotaSnapshot / CloudKit / Apple Watch。
public struct GrokAPIUsage: Codable, Sendable, Equatable {
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let prepaidBalance: Decimal
    public let postpaidMonthlyLimit: Decimal
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    public let updatedAt: Date

    public var hasKnownUsage: Bool { confidence != .unknown }

    public init(
        usageDaily: Decimal,
        usageWeekly: Decimal,
        usageMonthly: Decimal,
        prepaidBalance: Decimal,
        postpaidMonthlyLimit: Decimal,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.prepaidBalance = prepaidBalance
        self.postpaidMonthlyLimit = postpaidMonthlyLimit
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public func markedStale(reason: QuotaStaleReason? = nil) -> GrokAPIUsage {
        GrokAPIUsage(
            usageDaily: usageDaily,
            usageWeekly: usageWeekly,
            usageMonthly: usageMonthly,
            prepaidBalance: prepaidBalance,
            postpaidMonthlyLimit: postpaidMonthlyLimit,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }

    public static func degraded(
        from existing: GrokAPIUsage?,
        reason: QuotaStaleReason,
        now: Date = Date()
    ) -> GrokAPIUsage {
        existing?.markedStale(reason: reason) ?? .unknown(now: now, reason: reason)
    }

    public static func unknown(
        source: String = GrokAPIUsageAdapter.source,
        now: Date = Date(),
        reason: QuotaStaleReason? = nil
    ) -> GrokAPIUsage {
        GrokAPIUsage(
            usageDaily: 0,
            usageWeekly: 0,
            usageMonthly: 0,
            prepaidBalance: 0,
            postpaidMonthlyLimit: 0,
            confidence: .unknown,
            staleReason: reason,
            source: source,
            updatedAt: now
        )
    }
}
