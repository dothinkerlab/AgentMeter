import Foundation

/// 被监控的 AI 编程工具。raw value 同时用作持久化和 CloudKit 身份，必须保持稳定。
public enum ToolKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claudeCode
    case codex
    case cursor
    case kimiCode
    case glmCoding
    case miniMax
    case openCode
    case deepSeek
    case openRouter
    case grok
}

public extension ToolKind {
    /// Providers that are collected independently by both the Mac and iPhone.
    var supportsDeviceScopedSnapshots: Bool {
        switch self {
        case .kimiCode, .glmCoding, .miniMax: true
        default: false
        }
    }
}

/// Device that fetched a sanitized quota snapshot. Provider credentials never
/// accompany this value into CloudKit.
public enum QuotaCollectorDevice: String, Codable, Sendable, CaseIterable, Hashable {
    case mac
    case iPhone = "iphone"
}

/// 额度窗口类型。Claude 端点返回 `five_hour` / `seven_day` / `seven_day_opus` /
/// `seven_day_sonnet`; Cursor 个人套餐使用 `.monthly`。
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

/// stale/unknown 数据的失败原因。只用于解释数据为什么陈旧,不参与额度决策。
public enum QuotaStaleReason: String, Codable, Sendable, Equatable {
    /// token 过期或服务端返回 401/403。
    case authExpired
    /// Keychain 或本地凭据文件读取失败。
    case credentialReadFailed
    /// 网络中断、超时或非 HTTP 响应。
    case networkFailure
    /// 服务端返回非 2xx、且不是认证错误。
    case endpointFailure
    /// 响应结构变化或无法解析。
    case responseChanged
    /// 未能归类的失败。
    case unknownFailure
}
