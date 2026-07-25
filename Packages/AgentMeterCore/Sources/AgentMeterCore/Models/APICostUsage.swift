import Foundation

/// Organization-level developer API costs. This is a device-local billing
/// bypass and deliberately does not use `QuotaSnapshot` or CloudKit.
public struct APICostUsage: Codable, Sendable, Equatable {
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    public let updatedAt: Date

    public var hasKnownUsage: Bool { confidence != .unknown }

    public init(
        usageDaily: Decimal,
        usageWeekly: Decimal,
        usageMonthly: Decimal,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public func markedStale(reason: QuotaStaleReason? = nil) -> Self {
        Self(
            usageDaily: usageDaily,
            usageWeekly: usageWeekly,
            usageMonthly: usageMonthly,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }

    public static func degraded(
        from existing: Self?,
        source: String,
        reason: QuotaStaleReason,
        now: Date = Date()
    ) -> Self {
        existing?.markedStale(reason: reason) ?? Self(
            usageDaily: 0,
            usageWeekly: 0,
            usageMonthly: 0,
            confidence: .unknown,
            staleReason: reason,
            source: source,
            updatedAt: now
        )
    }
}

public struct APICostRequestGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}
