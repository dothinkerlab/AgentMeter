import Foundation

/// 被监控的 AI 编程工具。第一版只用 `.claudeCode`,其余为将来多工具预留。
public enum ToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case codex
    case openCode
}

/// 额度窗口类型。Claude 端点返回 `five_hour` / `seven_day` / `seven_day_opus` /
/// `seven_day_sonnet`;`.monthly` 为将来其他工具预留。
public enum WindowKind: String, Codable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case monthly
}

/// 数据新鲜度。不用 high/medium/low 这种主观档位 —— UI 靠 `source` + `updatedAt`
/// 自己判断新旧(见 TECHNICAL_DESIGN §2.3)。
public enum DataConfidence: String, Codable, Sendable {
    /// 来自端点、刚成功获取。
    case fresh
    /// 端点失败 / token 过期,用的是上次缓存。
    case stale
    /// 从没成功拉到过。
    case unknown
}
