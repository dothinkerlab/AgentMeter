import Foundation

/// OpenRouter 当前 API key 的消费信息。
///
/// OpenRouter 返回美元计价的绝对消费与可选 key 限额，没有 Claude/Codex 那种订阅
/// 百分比窗口，因此走本地旁路：Mac/iPhone 各自持 key、各自查询，不进 CloudKit/Watch。
public struct OpenRouterUsage: Codable, Sendable, Equatable {
    public let keyLabel: String?
    public let usage: Decimal
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let byokUsage: Decimal
    public let byokUsageDaily: Decimal
    public let byokUsageWeekly: Decimal
    public let byokUsageMonthly: Decimal
    public let limit: Decimal?
    public let limitRemaining: Decimal?
    public let limitReset: String?
    public let includeBYOKInLimit: Bool
    public let expiresAt: Date?
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    public let updatedAt: Date

    public var hasKnownUsage: Bool { confidence != .unknown }
    public var hasBYOKUsage: Bool { byokUsage > 0 }

    public init(
        keyLabel: String?,
        usage: Decimal,
        usageDaily: Decimal,
        usageWeekly: Decimal,
        usageMonthly: Decimal,
        byokUsage: Decimal,
        byokUsageDaily: Decimal,
        byokUsageWeekly: Decimal,
        byokUsageMonthly: Decimal,
        limit: Decimal?,
        limitRemaining: Decimal?,
        limitReset: String?,
        includeBYOKInLimit: Bool,
        expiresAt: Date?,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.keyLabel = keyLabel
        self.usage = usage
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.byokUsage = byokUsage
        self.byokUsageDaily = byokUsageDaily
        self.byokUsageWeekly = byokUsageWeekly
        self.byokUsageMonthly = byokUsageMonthly
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.limitReset = limitReset
        self.includeBYOKInLimit = includeBYOKInLimit
        self.expiresAt = expiresAt
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public func markedStale(reason: QuotaStaleReason? = nil) -> OpenRouterUsage {
        OpenRouterUsage(
            keyLabel: keyLabel,
            usage: usage,
            usageDaily: usageDaily,
            usageWeekly: usageWeekly,
            usageMonthly: usageMonthly,
            byokUsage: byokUsage,
            byokUsageDaily: byokUsageDaily,
            byokUsageWeekly: byokUsageWeekly,
            byokUsageMonthly: byokUsageMonthly,
            limit: limit,
            limitRemaining: limitRemaining,
            limitReset: limitReset,
            includeBYOKInLimit: includeBYOKInLimit,
            expiresAt: expiresAt,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }

    public static func degraded(
        from existing: OpenRouterUsage?,
        reason: QuotaStaleReason,
        now: Date = Date()
    ) -> OpenRouterUsage {
        existing?.markedStale(reason: reason) ?? .unknown(now: now, reason: reason)
    }

    public static func unknown(
        source: String = OpenRouterUsageAdapter.source,
        now: Date = Date(),
        reason: QuotaStaleReason? = nil
    ) -> OpenRouterUsage {
        OpenRouterUsage(
            keyLabel: nil,
            usage: 0,
            usageDaily: 0,
            usageWeekly: 0,
            usageMonthly: 0,
            byokUsage: 0,
            byokUsageDaily: 0,
            byokUsageWeekly: 0,
            byokUsageMonthly: 0,
            limit: nil,
            limitRemaining: nil,
            limitReset: nil,
            includeBYOKInLimit: false,
            expiresAt: nil,
            confidence: .unknown,
            staleReason: reason,
            source: source,
            updatedAt: now
        )
    }
}
