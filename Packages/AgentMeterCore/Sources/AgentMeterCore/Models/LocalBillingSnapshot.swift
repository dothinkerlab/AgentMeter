import Foundation

/// iPhone Widget 与配对 Apple Watch 可展示的本地账单服务。
public enum LocalBillingService: String, Codable, CaseIterable, Sendable {
    case deepSeek
    case openRouter
    case xAI
    case kimiAPI
    case openAIAPI
    case anthropicAPI
}

/// OpenAI/Anthropic 组织级 API 成本的显示白名单。Admin API key 不在该类型中。
public struct APICostDisplaySnapshot: Codable, Sendable, Equatable {
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let updatedAt: Date

    public init(_ usage: APICostUsage) {
        usageDaily = usage.usageDaily
        usageWeekly = usage.usageWeekly
        usageMonthly = usage.usageMonthly
        confidence = usage.confidence
        staleReason = usage.staleReason
        updatedAt = usage.updatedAt
    }

    public var hasKnownValue: Bool { confidence != .unknown }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(
            usageDaily: usageDaily,
            usageWeekly: usageWeekly,
            usageMonthly: usageMonthly,
            confidence: hasKnownValue ? .stale : .unknown,
            staleReason: reason,
            updatedAt: updatedAt
        )
    }

    public init(
        usageDaily: Decimal,
        usageWeekly: Decimal,
        usageMonthly: Decimal,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason?,
        updatedAt: Date
    ) {
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.updatedAt = updatedAt
    }
}

public struct KimiAPIDisplaySnapshot: Codable, Sendable, Equatable {
    public let availableBalance: Decimal
    public let voucherBalance: Decimal
    public let cashBalance: Decimal
    public let region: ProviderRegion
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let updatedAt: Date

    public var hasKnownValue: Bool { confidence != .unknown }

    public init(_ balance: KimiAPIBalance) {
        availableBalance = balance.availableBalance
        voucherBalance = balance.voucherBalance
        cashBalance = balance.cashBalance
        region = balance.region
        confidence = balance.confidence
        staleReason = balance.staleReason
        updatedAt = balance.updatedAt
    }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(availableBalance: availableBalance, voucherBalance: voucherBalance,
             cashBalance: cashBalance, region: region,
             confidence: confidence == .unknown ? .unknown : .stale,
             staleReason: reason, updatedAt: updatedAt)
    }

    public init(availableBalance: Decimal, voucherBalance: Decimal, cashBalance: Decimal,
                region: ProviderRegion, confidence: DataConfidence,
                staleReason: QuotaStaleReason?, updatedAt: Date) {
        self.availableBalance = availableBalance
        self.voucherBalance = voucherBalance
        self.cashBalance = cashBalance
        self.region = region
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.updatedAt = updatedAt
    }
}

/// DeepSeek 的显示白名单。刻意不复用上游响应或凭据模型。
public struct DeepSeekDisplaySnapshot: Codable, Sendable, Equatable {
    public let isAvailable: Bool
    public let currency: String
    public let totalBalance: String
    public let grantedBalance: String
    public let toppedUpBalance: String
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let updatedAt: Date

    public init(_ balance: DeepSeekBalance) {
        isAvailable = balance.isAvailable
        currency = balance.currency
        totalBalance = balance.totalBalance
        grantedBalance = balance.grantedBalance
        toppedUpBalance = balance.toppedUpBalance
        confidence = balance.confidence
        staleReason = balance.staleReason
        updatedAt = balance.updatedAt
    }

    public var hasKnownValue: Bool { confidence != .unknown }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(
            isAvailable: isAvailable, currency: currency, totalBalance: totalBalance,
            grantedBalance: grantedBalance, toppedUpBalance: toppedUpBalance,
            confidence: hasKnownValue ? .stale : .unknown, staleReason: reason,
            updatedAt: updatedAt
        )
    }

    public init(
        isAvailable: Bool, currency: String, totalBalance: String,
        grantedBalance: String, toppedUpBalance: String,
        confidence: DataConfidence, staleReason: QuotaStaleReason?, updatedAt: Date
    ) {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.updatedAt = updatedAt
    }
}

/// OpenRouter 的显示白名单。API key 与 key label 均不进入跨进程/跨设备缓存。
public struct OpenRouterDisplaySnapshot: Codable, Sendable, Equatable {
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let byokUsageDaily: Decimal
    public let byokUsageWeekly: Decimal
    public let byokUsageMonthly: Decimal
    public let limit: Decimal?
    public let limitRemaining: Decimal?
    public let limitReset: String?
    public let includeBYOKInLimit: Bool
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let updatedAt: Date

    public init(_ usage: OpenRouterUsage) {
        usageDaily = usage.usageDaily
        usageWeekly = usage.usageWeekly
        usageMonthly = usage.usageMonthly
        byokUsageDaily = usage.byokUsageDaily
        byokUsageWeekly = usage.byokUsageWeekly
        byokUsageMonthly = usage.byokUsageMonthly
        limit = usage.limit
        limitRemaining = usage.limitRemaining
        limitReset = usage.limitReset
        includeBYOKInLimit = usage.includeBYOKInLimit
        confidence = usage.confidence
        staleReason = usage.staleReason
        updatedAt = usage.updatedAt
    }

    public var hasKnownValue: Bool { confidence != .unknown }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(
            usageDaily: usageDaily, usageWeekly: usageWeekly, usageMonthly: usageMonthly,
            byokUsageDaily: byokUsageDaily, byokUsageWeekly: byokUsageWeekly,
            byokUsageMonthly: byokUsageMonthly, limit: limit, limitRemaining: limitRemaining,
            limitReset: limitReset, includeBYOKInLimit: includeBYOKInLimit,
            confidence: hasKnownValue ? .stale : .unknown, staleReason: reason,
            updatedAt: updatedAt
        )
    }

    public init(
        usageDaily: Decimal, usageWeekly: Decimal, usageMonthly: Decimal,
        byokUsageDaily: Decimal, byokUsageWeekly: Decimal, byokUsageMonthly: Decimal,
        limit: Decimal?, limitRemaining: Decimal?, limitReset: String?, includeBYOKInLimit: Bool,
        confidence: DataConfidence, staleReason: QuotaStaleReason?, updatedAt: Date
    ) {
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.byokUsageDaily = byokUsageDaily
        self.byokUsageWeekly = byokUsageWeekly
        self.byokUsageMonthly = byokUsageMonthly
        self.limit = limit
        self.limitRemaining = limitRemaining
        self.limitReset = limitReset
        self.includeBYOKInLimit = includeBYOKInLimit
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.updatedAt = updatedAt
    }
}

/// xAI API 团队账单的显示白名单。Management Key 与 Team ID 不在该类型中。
public struct XAIAPIUsageDisplaySnapshot: Codable, Sendable, Equatable {
    public let usageDaily: Decimal
    public let usageWeekly: Decimal
    public let usageMonthly: Decimal
    public let prepaidBalance: Decimal
    public let postpaidMonthlyLimit: Decimal
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let updatedAt: Date

    public init(_ usage: GrokAPIUsage) {
        usageDaily = usage.usageDaily
        usageWeekly = usage.usageWeekly
        usageMonthly = usage.usageMonthly
        prepaidBalance = usage.prepaidBalance
        postpaidMonthlyLimit = usage.postpaidMonthlyLimit
        confidence = usage.confidence
        staleReason = usage.staleReason
        updatedAt = usage.updatedAt
    }

    public var hasKnownValue: Bool { confidence != .unknown }

    public func markedStale(reason: QuotaStaleReason) -> Self {
        Self(
            usageDaily: usageDaily, usageWeekly: usageWeekly, usageMonthly: usageMonthly,
            prepaidBalance: prepaidBalance, postpaidMonthlyLimit: postpaidMonthlyLimit,
            confidence: hasKnownValue ? .stale : .unknown, staleReason: reason,
            updatedAt: updatedAt
        )
    }

    public init(
        usageDaily: Decimal, usageWeekly: Decimal, usageMonthly: Decimal,
        prepaidBalance: Decimal, postpaidMonthlyLimit: Decimal,
        confidence: DataConfidence, staleReason: QuotaStaleReason?, updatedAt: Date
    ) {
        self.usageDaily = usageDaily
        self.usageWeekly = usageWeekly
        self.usageMonthly = usageMonthly
        self.prepaidBalance = prepaidBalance
        self.postpaidMonthlyLimit = postpaidMonthlyLimit
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.updatedAt = updatedAt
    }
}

/// App Group 与 WatchConnectivity 共用的版本化 envelope。
/// 这里只允许出现经过白名单清洗的显示数据，绝不加入任何 provider 凭据。
public struct LocalBillingSnapshotBundle: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public var deepSeek: DeepSeekDisplaySnapshot?
    public var openRouter: OpenRouterDisplaySnapshot?
    public var xAI: XAIAPIUsageDisplaySnapshot?
    public var kimiAPI: KimiAPIDisplaySnapshot?
    public var openAIAPI: APICostDisplaySnapshot?
    public var anthropicAPI: APICostDisplaySnapshot?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        deepSeek: DeepSeekDisplaySnapshot? = nil,
        openRouter: OpenRouterDisplaySnapshot? = nil,
        xAI: XAIAPIUsageDisplaySnapshot? = nil,
        kimiAPI: KimiAPIDisplaySnapshot? = nil,
        openAIAPI: APICostDisplaySnapshot? = nil,
        anthropicAPI: APICostDisplaySnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deepSeek = deepSeek
        self.openRouter = openRouter
        self.xAI = xAI
        self.kimiAPI = kimiAPI
        self.openAIAPI = openAIAPI
        self.anthropicAPI = anthropicAPI
    }

    public var isEmpty: Bool {
        deepSeek == nil && openRouter == nil && xAI == nil && kimiAPI == nil
            && openAIAPI == nil && anthropicAPI == nil
    }

    public func contains(_ service: LocalBillingService) -> Bool {
        switch service {
        case .deepSeek: return deepSeek != nil
        case .openRouter: return openRouter != nil
        case .xAI: return xAI != nil
        case .kimiAPI: return kimiAPI != nil
        case .openAIAPI: return openAIAPI != nil
        case .anthropicAPI: return anthropicAPI != nil
        }
    }
}
