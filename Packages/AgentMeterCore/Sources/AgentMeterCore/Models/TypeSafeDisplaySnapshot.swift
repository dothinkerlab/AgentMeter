import Foundation

/// Explicit display whitelist. No session, browser profile, or raw response can be represented here.
public struct TypeSafeDisplaySnapshot: Codable, Sendable, Equatable {
    public var billing: TypeSafeMetric<TypeSafeBilling>
    public var tokens: TypeSafeMetric<TypeSafeTokenUsage>
    public var paused: Bool
    public var syncFailure: QuotaStaleReason?

    public init(_ usage: TypeSafeUsage = .init(), paused: Bool = false) {
        billing = usage.billing
        tokens = usage.tokens
        self.paused = paused
    }

    private enum CodingKeys: String, CodingKey { case billing, tokens, paused, syncFailure }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        billing = try values.decode(TypeSafeMetric<TypeSafeBilling>.self, forKey: .billing)
        tokens = try values.decode(TypeSafeMetric<TypeSafeTokenUsage>.self, forKey: .tokens)
        paused = try values.decode(Bool.self, forKey: .paused)
        syncFailure = try values.decodeIfPresent(QuotaStaleReason.self, forKey: .syncFailure)
        try validate()
    }
    public func validate() throws {
        if let value = billing.value {
            guard !value.balance.isNaN, !value.spent.isNaN, value.balance >= 0, value.spent >= 0,
                  billing.updatedAt != nil else { throw TypeSafeSyncError.responseChanged }
            for credit in value.credits {
                guard !credit.amount.isNaN, !credit.remaining.isNaN, credit.amount >= 0, credit.remaining >= 0
                else { throw TypeSafeSyncError.responseChanged }
            }
        }
        if let value = tokens.value {
            guard value.todayTokens >= 0, value.sevenDayTokens >= 0, value.monthInputTokens >= 0,
                  value.monthOutputTokens >= 0, value.monthRequests >= 0, tokens.updatedAt != nil,
                  !value.monthInputTokens.addingReportingOverflow(value.monthOutputTokens).overflow
            else { throw TypeSafeSyncError.responseChanged }
        }
    }

    public var updatedAt: Date? { billing.updatedAt }
    public func billingIsStale(now: Date = Date()) -> Bool {
        paused || syncFailure != nil || billing.confidence != .fresh
            || billing.updatedAt.map { now.timeIntervalSince($0) > 900 } != false
    }
    public func tokensAreStale(now: Date = Date()) -> Bool {
        paused || syncFailure != nil || tokens.confidence != .fresh
            || tokens.updatedAt.map { now.timeIntervalSince($0) > 900 } != false
    }
    public var needsMacLogin: Bool {
        [billing.failure, tokens.failure].contains(.authExpired)
            || [billing.failure, tokens.failure].contains(.missingCookie)
    }
    public var needsMacVerification: Bool {
        [billing.failure, tokens.failure].contains(.challenge)
    }
    public var activeCredits: [TypeSafeCredit] {
        activeCredits(now: Date())
    }
    public func activeCredits(now: Date) -> [TypeSafeCredit] {
        (billing.value?.credits ?? []).filter { $0.remaining > 0 && $0.expiresAt > now }
            .sorted { $0.expiresAt < $1.expiresAt }
    }
    public func markedSyncFailed(_ reason: QuotaStaleReason) -> Self {
        var result = self
        result.syncFailure = reason
        return result
    }
}

/// A disabled envelope is a tombstone: readers clear cached facts instead of waiting for expiry.
public struct TypeSafeSyncEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: Date
    public let snapshot: TypeSafeDisplaySnapshot?
    public init(snapshot: TypeSafeDisplaySnapshot?, revision: Date = Date()) {
        schemaVersion = 1
        self.revision = revision
        self.snapshot = snapshot
    }
}
