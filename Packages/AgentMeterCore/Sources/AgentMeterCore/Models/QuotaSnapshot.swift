import Foundation

/// 一次额度采集的完整结果。这是手表唯一消费的对象 —— 手表不直连 Anthropic,
/// 只读 CloudKit 里清洗好的 `QuotaSnapshot`(CLAUDE.md 铁律 1)。
public struct QuotaSnapshot: Codable, Sendable, Equatable {
    public let tool: ToolKind
    /// 订阅档位,如 "Max 5x"。能拿到就填,拿不到为 nil。
    public let plan: String?
    public let windows: [QuotaWindow]
    public let confidence: DataConfidence
    /// 数据来源标识,便于 UI 显示,如 "oauth_usage_endpoint"。
    public let source: String
    /// 这条数据**真正成功获取**的时间。UI 用它算"几分钟前"并判断是否陈旧。
    public let updatedAt: Date

    public init(
        tool: ToolKind,
        plan: String?,
        windows: [QuotaWindow],
        confidence: DataConfidence,
        source: String,
        updatedAt: Date
    ) {
        self.tool = tool
        self.plan = plan
        self.windows = windows
        self.confidence = confidence
        self.source = source
        self.updatedAt = updatedAt
    }

    public func window(_ kind: WindowKind) -> QuotaWindow? {
        windows.first { $0.kind == kind }
    }

    /// Complication 主显示用:在 5 小时窗口和每周窗口里取"剩余 % 更低"(即已用 % 更高)
    /// 的那个 —— 用户关心的是哪个先把他卡住(TECHNICAL_DESIGN §4.1)。
    /// 若两个窗口都缺失,返回任意已有窗口;全空则 nil。
    public var tightestWindow: QuotaWindow? {
        let primary = [window(.fiveHour), window(.sevenDay)].compactMap { $0 }
        let pool = primary.isEmpty ? windows : primary
        return pool.max { $0.usedPercent < $1.usedPercent }
    }

    /// 取数失败时:保留上次成功的窗口和 `updatedAt`(真实数据年龄),仅把 confidence
    /// 降级为 `.stale`。UI 据此显示"数据陈旧",绝不用旧数冒充新数(铁律 2)。
    public func markedStale() -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, plan: plan, windows: windows,
                      confidence: .stale, source: source, updatedAt: updatedAt)
    }

    /// 从没成功拉到过时的占位 snapshot(confidence `.unknown`,无窗口)。
    public static func unknown(tool: ToolKind, source: String, now: Date = Date()) -> QuotaSnapshot {
        QuotaSnapshot(tool: tool, plan: nil, windows: [],
                      confidence: .unknown, source: source, updatedAt: now)
    }
}
