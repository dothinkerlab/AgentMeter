import Foundation

/// 单个额度窗口的状态。
///
/// **口径统一:内部一律存"已用 %"(`usedPercent`),UI 层才换算成"剩余"。**
/// Claude 端点的 `utilization` 本就是已用 %,直接入库;将来接 Codex(返回 remaining)
/// 时必须在其 adapter 里转成已用再构造本结构(见 TECHNICAL_DESIGN §2.3 / CLAUDE.md 铁律 3)。
public struct QuotaWindow: Codable, Sendable, Equatable {
    /// 已用百分比,0–100。
    public let usedPercent: Double
    /// 该窗口的重置时刻。Claude 的 5 小时是滚动窗口,这个值会变,倒计时要实时算。
    public let resetsAt: Date
    public let kind: WindowKind

    public init(usedPercent: Double, resetsAt: Date, kind: WindowKind) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.kind = kind
    }

    /// 剩余百分比,0–100。UI 展示用。
    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}
