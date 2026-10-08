import Foundation

public enum PerplexityCookieSource: String, Codable, CaseIterable, Sendable { case auto, manual }

public enum PerplexityFailure: String, Codable, Sendable, Error {
    case missingCookie, invalidCookie, accessDenied, authExpired, rateLimited, challenge, unavailable, network, responseChanged

    public var staleReason: QuotaStaleReason {
        switch self {
        case .missingCookie, .invalidCookie, .authExpired: .authExpired
        case .accessDenied: .credentialReadFailed
        case .network: .networkFailure
        case .responseChanged: .responseChanged
        default: .endpointFailure
        }
    }
}

public struct PerplexityCreditPool: Codable, Equatable, Sendable {
    public let total: Decimal
    public let used: Decimal
    public let date: Date?
    public var remaining: Decimal { max(0, total - used) }
    public var usedPercent: Double {
        guard total > 0 else { return 100 }
        return min(100, max(0, NSDecimalNumber(decimal: used / total * 100).doubleValue))
    }
    public init(total: Decimal, used: Decimal, date: Date? = nil) {
        self.total = total; self.used = used; self.date = date
    }
    public func validate() throws {
        guard !total.isNaN, !used.isNaN, total >= 0, used >= 0, used <= total,
              date.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true
        else { throw PerplexityFailure.responseChanged }
    }
}

/// Web account credits, never developer API dollars. Pool consumption is attributed locally.
public struct PerplexityCredits: Codable, Equatable, Sendable {
    public let recurring: PerplexityCreditPool
    public let purchased: PerplexityCreditPool
    public let bonus: PerplexityCreditPool
    public init(recurring: PerplexityCreditPool, purchased: PerplexityCreditPool, bonus: PerplexityCreditPool) {
        self.recurring = recurring; self.purchased = purchased; self.bonus = bonus
    }
    public var preferredPool: PerplexityCreditPool {
        recurring.total > 0 ? recurring : (purchased.total > 0 ? purchased : bonus)
    }
    public var preferredLabelKey: String {
        recurring.total > 0 ? "周期积分" : (purchased.total > 0 ? "购买积分" : "奖励积分")
    }
    public var displayPools: [(labelKey: String, pool: PerplexityCreditPool)] {
        [("周期积分", recurring), ("购买积分", purchased), ("奖励积分", bonus)]
    }
    public func validate() throws {
        try recurring.validate(); try purchased.validate(); try bonus.validate()
    }
}

public struct PerplexityUsage: Equatable, Sendable {
    public let credits: PerplexityCredits?
    public let updatedAt: Date?
    public let failure: PerplexityFailure?
    public var confidence: DataConfidence { credits == nil ? .unknown : (failure == nil ? .fresh : .stale) }
    public init(credits: PerplexityCredits? = nil, updatedAt: Date? = nil, failure: PerplexityFailure? = nil) {
        self.credits = credits; self.updatedAt = updatedAt; self.failure = failure
    }
    public func degraded(_ failure: PerplexityFailure) -> Self {
        Self(credits: credits, updatedAt: updatedAt, failure: failure)
    }
}

public enum PerplexityPreferences {
    public static let sourceKey = "perplexity.cookieSource"
    public static let profileKey = "perplexity.chromeProfile"
    public static func source(defaults: UserDefaults = .standard) -> PerplexityCookieSource {
        PerplexityCookieSource(rawValue: defaults.string(forKey: sourceKey) ?? "") ?? .auto
    }
}
