import Foundation

public enum TypeSafeCookieSource: String, Codable, CaseIterable, Sendable {
    case auto, manual
}

/// These settings contain no session material. TypeSafe always requires explicit opt-in.
public enum TypeSafePreferences {
    public static let sourceKey = "typesafe.cookieSource"
    public static let profileKey = "typesafe.chromeProfile"

    public static func source(defaults: UserDefaults = .standard) -> TypeSafeCookieSource {
        TypeSafeCookieSource(rawValue: defaults.string(forKey: sourceKey) ?? "") ?? .auto
    }
}

public enum TypeSafeFailure: String, Error, Codable, Sendable, Equatable {
    case missingCookie, accessDenied, invalidCookie, authExpired
    case rateLimited, challenge, unavailable, network, responseChanged

    public var staleReason: QuotaStaleReason {
        switch self {
        case .missingCookie, .accessDenied, .invalidCookie: .credentialReadFailed
        case .authExpired: .authExpired
        case .rateLimited, .challenge, .unavailable: .endpointFailure
        case .network: .networkFailure
        case .responseChanged: .responseChanged
        }
    }
}

/// Independent timestamps prevent a successful usage query from freshening an old balance.
public struct TypeSafeMetric<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let value: Value?
    public let updatedAt: Date?
    public let failure: TypeSafeFailure?

    public init(value: Value? = nil, updatedAt: Date? = nil, failure: TypeSafeFailure? = nil) {
        self.value = value
        self.updatedAt = updatedAt
        self.failure = failure
    }

    public var confidence: DataConfidence {
        value == nil ? .unknown : (failure == nil ? .fresh : .stale)
    }

    public func degraded(_ failure: TypeSafeFailure) -> Self {
        Self(value: value, updatedAt: updatedAt, failure: failure)
    }
}

public struct TypeSafeCredit: Codable, Sendable, Equatable {
    public let amount: Decimal
    public let remaining: Decimal
    public let expiresAt: Date

    public init(amount: Decimal, remaining: Decimal, expiresAt: Date) {
        self.amount = amount
        self.remaining = remaining
        self.expiresAt = expiresAt
    }
}

public struct TypeSafeBilling: Codable, Sendable, Equatable {
    public let balance: Decimal
    public let spent: Decimal
    public let cycleLabel: String?
    public let plan: String?
    public let credits: [TypeSafeCredit]

    public init(balance: Decimal, spent: Decimal, cycleLabel: String? = nil,
                plan: String? = nil, credits: [TypeSafeCredit] = []) {
        self.balance = balance
        self.spent = spent
        self.cycleLabel = cycleLabel
        self.plan = plan
        self.credits = credits
    }
}

public struct TypeSafeTokenUsage: Codable, Sendable, Equatable {
    public let todayTokens: Int64
    public let sevenDayTokens: Int64
    public let monthInputTokens: Int64
    public let monthOutputTokens: Int64
    public let monthRequests: Int64
    public let earliestBucketAt: Date?

    public var monthTokens: Int64 { monthInputTokens + monthOutputTokens }

    public init(todayTokens: Int64, sevenDayTokens: Int64, monthInputTokens: Int64,
                monthOutputTokens: Int64, monthRequests: Int64, earliestBucketAt: Date?) {
        self.todayTokens = todayTokens
        self.sevenDayTokens = sevenDayTokens
        self.monthInputTokens = monthInputTokens
        self.monthOutputTokens = monthOutputTokens
        self.monthRequests = monthRequests
        self.earliestBucketAt = earliestBucketAt
    }
}

/// Mac-local billing; deliberately never represented as a quota or CloudKit record.
public struct TypeSafeUsage: Codable, Sendable, Equatable {
    public let billing: TypeSafeMetric<TypeSafeBilling>
    public let tokens: TypeSafeMetric<TypeSafeTokenUsage>

    public init(billing: TypeSafeMetric<TypeSafeBilling> = .init(),
                tokens: TypeSafeMetric<TypeSafeTokenUsage> = .init()) {
        self.billing = billing
        self.tokens = tokens
    }

    public var failure: TypeSafeFailure? { billing.failure ?? tokens.failure }
    public var confidence: DataConfidence {
        if billing.confidence == .fresh && tokens.confidence == .fresh { return .fresh }
        return billing.value != nil || tokens.value != nil ? .stale : .unknown
    }
    public var updatedAt: Date? { [billing.updatedAt, tokens.updatedAt].compactMap { $0 }.min() }

    public func degraded(_ failure: TypeSafeFailure) -> Self {
        Self(billing: billing.degraded(failure), tokens: tokens.degraded(failure))
    }
}

/// Validate before trimming so pasted CR/LF cannot become an accepted header.
public enum TypeSafeCookieHeader {
    public static func normalize(_ input: String) throws -> String {
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TypeSafeFailure.invalidCookie
        }
        var value = input.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)
        let nameCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_\u{0060}|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var pairs: [String] = []
        for part in parts {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else { throw TypeSafeFailure.invalidCookie }
            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespaces)
            let content = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ nameCharacters.contains($0) }),
                  content.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else {
                throw TypeSafeFailure.invalidCookie
            }
            pairs.append("\(name)=\(content)")
        }
        guard !pairs.isEmpty else { throw TypeSafeFailure.invalidCookie }
        return pairs.joined(separator: "; ")
    }
}
