import Foundation

/// Kimi Open Platform developer balance. This is intentionally separate from
/// Kimi Code subscription quota and keeps decimal currency values exact.
public struct KimiAPIBalance: Codable, Sendable, Equatable {
    public let availableBalance: Decimal
    public let voucherBalance: Decimal
    public let cashBalance: Decimal
    public let region: ProviderRegion
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    public let updatedAt: Date

    public var hasKnownValue: Bool { confidence != .unknown }

    public init(availableBalance: Decimal, voucherBalance: Decimal, cashBalance: Decimal,
                region: ProviderRegion, confidence: DataConfidence,
                staleReason: QuotaStaleReason? = nil, source: String, updatedAt: Date) {
        self.availableBalance = availableBalance
        self.voucherBalance = voucherBalance
        self.cashBalance = cashBalance
        self.region = region
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public static func degraded(from previous: Self?, region: ProviderRegion,
                                reason: QuotaStaleReason, now: Date = Date()) -> Self {
        previous?.markedStale(reason: reason)
            ?? Self(availableBalance: 0, voucherBalance: 0, cashBalance: 0, region: region,
                    confidence: .unknown, staleReason: reason,
                    source: KimiAPIBalanceAdapter.source, updatedAt: now)
    }

    public func markedStale(reason: QuotaStaleReason? = nil) -> Self {
        Self(
            availableBalance: availableBalance,
            voucherBalance: voucherBalance,
            cashBalance: cashBalance,
            region: region,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }
}

public struct KimiAPIRequestGate: Sendable {
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
