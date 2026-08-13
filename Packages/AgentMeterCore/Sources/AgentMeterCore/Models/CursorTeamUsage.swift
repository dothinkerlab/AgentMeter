import Foundation

public struct CursorTeamMemberUsage: Sendable, Equatable, Identifiable {
    public let name: String
    public let email: String
    public let role: String
    public let includedSpendCents: Decimal?
    public let onDemandSpendCents: Decimal
    public let totalPercentUsed: Double?

    public var id: String { email.lowercased() }
    public var totalUsageCents: Decimal { (includedSpendCents ?? 0) + onDemandSpendCents }

    public init(
        name: String,
        email: String,
        role: String,
        includedSpendCents: Decimal?,
        onDemandSpendCents: Decimal,
        totalPercentUsed: Double?
    ) {
        self.name = name
        self.email = email
        self.role = role
        self.includedSpendCents = includedSpendCents
        self.onDemandSpendCents = onDemandSpendCents
        self.totalPercentUsed = totalPercentUsed
    }
}

/// Cursor Team billing data is device-local. It must never be put in
/// `QuotaSnapshot`, CloudKit, App Group storage, or WatchConnectivity.
public struct CursorTeamUsage: Sendable, Equatable {
    public let members: [CursorTeamMemberUsage]
    public let totalMembers: Int
    public let subscriptionCycleStart: Date
    public let includedSpendCents: Decimal?
    public let onDemandSpendCents: Decimal
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    public let updatedAt: Date

    public var hasKnownUsage: Bool { confidence != .unknown }
    public var totalUsageCents: Decimal? {
        includedSpendCents.map { $0 + onDemandSpendCents }
    }

    public init(
        members: [CursorTeamMemberUsage],
        totalMembers: Int,
        subscriptionCycleStart: Date,
        includedSpendCents: Decimal?,
        onDemandSpendCents: Decimal,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.members = members
        self.totalMembers = totalMembers
        self.subscriptionCycleStart = subscriptionCycleStart
        self.includedSpendCents = includedSpendCents
        self.onDemandSpendCents = onDemandSpendCents
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(
            members: members,
            totalMembers: totalMembers,
            subscriptionCycleStart: subscriptionCycleStart,
            includedSpendCents: includedSpendCents,
            onDemandSpendCents: onDemandSpendCents,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source,
            updatedAt: updatedAt
        )
    }

    public static func degraded(
        from existing: Self?,
        reason: QuotaStaleReason,
        now: Date = Date()
    ) -> Self {
        existing?.markedStale(reason: reason) ?? Self(
            members: [],
            totalMembers: 0,
            subscriptionCycleStart: now,
            includedSpendCents: nil,
            onDemandSpendCents: 0,
            confidence: .unknown,
            staleReason: reason,
            source: CursorTeamUsageAdapter.source,
            updatedAt: now
        )
    }
}

public struct CursorTeamRequestGate: Sendable {
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
