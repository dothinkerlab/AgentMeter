import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DeepSeek 余额采集结果。
///
/// 与 `QuotaSnapshot` 不同 —— DeepSeek 返回的是**绝对余额**(人民币/美元金额),
/// 没有「已用 %」也没有「重置时间」,与铁律 3「内部统一存已用 %」不兼容。
/// 所以 DeepSeek **不入 `QuotaSnapshot` / `QuotaWindow`** —— 它是 QuotaCollector 之外的
/// 旁路,各端各自 fetch、各自展示,不进 CloudKit、不上 Apple Watch。
///
/// 复用 `DataConfidence` / `QuotaStaleReason` 描述数据陈旧原因(采集容错铁律 2 不变)。
public struct DeepSeekBalance: Codable, Sendable, Equatable {
    /// 当前账户是否有可用余额(API `is_available`)。false 表示已无可用余额,UI 应明确提示。
    public let isAvailable: Bool
    /// 货币代码,如 "CNY" / "USD"。挑「有余额」的币种(见 `DeepSeekBalanceAdapter`)。
    public let currency: String
    /// 总余额(含赠金 + 充值)。API 返回字符串保精度,UI 按需转 `Decimal`。
    public let totalBalance: String
    /// 赠金余额(可能过期,UI 应单独标识)。
    public let grantedBalance: String
    /// 充值余额。
    public let toppedUpBalance: String
    public let confidence: DataConfidence
    public let staleReason: QuotaStaleReason?
    public let source: String
    /// 真正成功采集的时刻。UI 用它算数据年龄。
    public let updatedAt: Date

    /// 只有成功取到过端点数据时,余额数字才可作为事实展示。
    /// `.unknown` 的 0 只是 Codable 占位,绝不能渲染成真实余额。
    public var hasKnownBalance: Bool { confidence != .unknown }

    /// “账户无可用余额”只允许由成功响应或其 stale 历史值得出。
    public var shouldShowUnavailable: Bool { hasKnownBalance && !isAvailable }

    public init(
        isAvailable: Bool,
        currency: String,
        totalBalance: String,
        grantedBalance: String,
        toppedUpBalance: String,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason? = nil,
        source: String,
        updatedAt: Date
    ) {
        self.isAvailable = isAvailable
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.confidence = confidence
        self.staleReason = confidence == .fresh ? nil : staleReason
        self.source = source
        self.updatedAt = updatedAt
    }

    /// 把已有余额翻成 stale,保留旧数值 + 真实数据年龄(铁律 2:不拿旧冒新)。
    public func markedStale(reason: QuotaStaleReason? = nil) -> DeepSeekBalance {
        DeepSeekBalance(
            isAvailable: isAvailable, currency: currency,
            totalBalance: totalBalance, grantedBalance: grantedBalance,
            toppedUpBalance: toppedUpBalance,
            confidence: confidence == .unknown ? .unknown : .stale,
            staleReason: reason,
            source: source, updatedAt: updatedAt
        )
    }

    /// 统一失败降级:有可信旧值则翻 stale;从未成功过则保持 unknown。
    public static func degraded(
        from existing: DeepSeekBalance?,
        reason: QuotaStaleReason,
        now: Date = Date()
    ) -> DeepSeekBalance {
        existing?.markedStale(reason: reason)
            ?? .unknown(now: now, reason: reason)
    }

    /// 从没成功拉到时的占位(unknown,数字全 0)。
    public static func unknown(
        currency: String = "CNY",
        source: String = DeepSeekBalanceAdapter.source,
        now: Date = Date(),
        reason: QuotaStaleReason? = nil
    ) -> DeepSeekBalance {
        DeepSeekBalance(
            isAvailable: false, currency: currency,
            totalBalance: "0", grantedBalance: "0", toppedUpBalance: "0",
            confidence: .unknown, staleReason: reason,
            source: source, updatedAt: now
        )
    }
}
