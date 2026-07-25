import Foundation

/// Account region for providers whose mainland-China and international keys
/// are issued separately and cannot be mixed.
public enum ProviderRegion: String, Codable, Sendable, CaseIterable, Hashable {
    case china
    case global

    public var glmQuotaURL: URL {
        switch self {
        case .china: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
        case .global: URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        }
    }

    public var miniMaxTokenPlanURL: URL {
        switch self {
        case .china: URL(string: "https://api.minimaxi.com/v1/token_plan/remains")!
        case .global: URL(string: "https://api.minimax.io/v1/token_plan/remains")!
        }
    }

    public var kimiAPIBalanceURL: URL {
        switch self {
        case .china: URL(string: "https://api.moonshot.cn/v1/users/me/balance")!
        case .global: URL(string: "https://api.moonshot.ai/v1/users/me/balance")!
        }
    }
}
