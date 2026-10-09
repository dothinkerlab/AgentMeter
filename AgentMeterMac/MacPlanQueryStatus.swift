import Foundation
import AgentMeterCore

struct MacPlanQueryStatus: Codable, Equatable {
    enum Issue: String, Codable {
        case invalidCredential, permissionDenied, network, rateLimited, unavailable, responseChanged, ambiguous, credentialRead, storage
        var message: String {
            switch self {
            case .invalidCredential: return L10n.string("凭据无效，请重新配置。")
            case .permissionDenied: return L10n.string("权限不足，请检查当前身份的个人套餐查询权限。")
            case .network: return L10n.string("网络异常，显示上次成功获取的数据。")
            case .rateLimited: return L10n.string("查询受限，请等待后重试。")
            case .unavailable: return L10n.string("服务暂不可用或当前身份没有有效套餐。")
            case .responseChanged: return L10n.string("额度响应无法可靠解析，显示上次数据。")
            case .ambiguous: return L10n.string("多个文本额度池存在冲突，无法确定共享额度；保留上次数据。")
            case .credentialRead: return L10n.string("无法读取本机凭据，请检查 Keychain 后重试。")
            case .storage: return L10n.string("无法安全保存本机数据，请重试。")
            }
        }
    }
    var issue: Issue?
    var retryAt: Date?
    var lastSuccess: Date?
    var credentialAvailable = false
    var source: String?
    var region: ProviderRegion?

    func canQuery(now: Date = Date()) -> Bool { retryAt.map { $0 <= now } ?? true }
    var message: String? { issue?.message }

    mutating func receive(_ error: Error?) {
        guard let error else { issue = nil; retryAt = nil; return }
        if let failure = error as? ProviderRequestFailure {
            issue = failure.isRateLimited ? .rateLimited : (failure.reason == .authExpired ? .invalidCredential : .unavailable)
            retryAt = failure.retryAt
            return
        }
        retryAt = nil
        switch error {
        case ArkPlanAdapter.FetchError.unauthorized, MiniMaxTokenPlanAdapter.FetchError.unauthorized: issue = .invalidCredential
        case ArkPlanAdapter.FetchError.permissionDenied: issue = .permissionDenied
        case ArkPlanAdapter.FetchError.transport, MiniMaxTokenPlanAdapter.FetchError.transport: issue = .network
        case let MiniMaxTokenPlanAdapter.FetchError.decode(detail): issue = detail.contains("ambiguous") ? .ambiguous : .responseChanged
        case ArkPlanAdapter.FetchError.decode: issue = .responseChanged
        default: issue = .unavailable
        }
    }
}
