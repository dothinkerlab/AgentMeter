import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// DeepSeek 余额采集 adapter(`GET https://api.deepseek.com/user/balance`)。
///
/// DeepSeek 走静态 API key(`Authorization: Bearer <api-key>`),没有 OAuth 也没有滚动窗口。
/// 这与 Claude Code/Codex(OAuth + 已用%/重置时间)完全不同,所以它**是项目里唯一不进
/// `QuotaSnapshot`/`QuotaCollector` 体系**的 adapter —— 各端旁路调用,失败降级
/// `DeepSeekBalance.unknown(...)` / `markedStale(...)`(架构铁律 1 的 DeepSeek 例外,
/// 详见 AGENTS.md / TECHNICAL_DESIGN.md)。
///
/// 纯解析 `parse(...)` 与网络 `fetch(...)` 分离:单测只跑录制 fixture,live 失败由调用方降级。
public struct DeepSeekBalanceAdapter: Sendable {

    public static let source = "deepseek_balance_endpoint"
    public static let defaultBalanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    public let balanceURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(balanceURL: URL = DeepSeekBalanceAdapter.defaultBalanceURL) {
        self.balanceURL = balanceURL
    }

    // MARK: - 响应模型

    /// API 原始响应。`balance_infos` 同时含 CNY / USD 两条,parse 时挑一条有余额的。
    struct RawResponse: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    struct BalanceInfo: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }

        /// 端点金额必须是非负、以 `.` 分隔的小数字符串。校验时转 Decimal 只用于比较,
        /// 最终模型仍保留原始 String,避免精度或格式损失。
        func validatedTotal() -> Decimal? {
            guard
                let total = Self.decimalAmount(totalBalance),
                Self.decimalAmount(grantedBalance) != nil,
                Self.decimalAmount(toppedUpBalance) != nil
            else {
                return nil
            }
            return total
        }

        private static func decimalAmount(_ value: String) -> Decimal? {
            guard !value.isEmpty else { return nil }

            let scalars = value.unicodeScalars
            var decimalSeparatorCount = 0
            for scalar in scalars {
                switch scalar.value {
                case 48...57:
                    continue
                case 46: // "."
                    decimalSeparatorCount += 1
                    guard decimalSeparatorCount == 1 else { return nil }
                default:
                    return nil
                }
            }

            guard value.first != ".", value.last != "." else { return nil }
            return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        }
    }

    // MARK: - 解析(可单测)

    /// 把端点原始响应解析成 `fresh` 的 `DeepSeekBalance`。
    ///
    /// 多币种选择策略:挑 `total_balance > 0` 的那条;若全部为 0,挑第一条(展示 0 余额
    /// —— 比 fallback 到固定 CNY 更诚实,真实反映账号现状)。`is_available` 透传给 UI。
    public func parse(data: Data, now: Date = Date()) throws -> DeepSeekBalance {
        let raw: RawResponse
        do {
            raw = try JSONDecoder().decode(RawResponse.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        guard !raw.balanceInfos.isEmpty else {
            throw FetchError.decode("balance_infos 为空")
        }

        let totals = try raw.balanceInfos.map { info in
            guard let total = info.validatedTotal() else {
                throw FetchError.decode("balance_infos 包含非法金额")
            }
            return total
        }
        let chosenIndex = totals.firstIndex { $0 > 0 } ?? 0
        let chosen = raw.balanceInfos[chosenIndex]

        return DeepSeekBalance(
            isAvailable: raw.isAvailable,
            currency: chosen.currency,
            totalBalance: chosen.totalBalance,
            grantedBalance: chosen.grantedBalance,
            toppedUpBalance: chosen.toppedUpBalance,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    // MARK: - 取数(网络)

    /// 调端点取数并解析。失败时抛 `FetchError`,由调用方决定降级 stale / unknown。
    public func fetch(
        apiKey: String,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> DeepSeekBalance {
        var request = URLRequest(url: balanceURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.httpStatus(http.statusCode)
        }

        return try parse(data: data, now: now)
    }

    /// 把 `FetchError`(以及其它错误)映射到统一 `QuotaStaleReason`。
    /// 跨平台 —— 不依赖 macOS-only 的 `QuotaCollector.staleReason`。
    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized:    return .authExpired
        case FetchError.transport:      return .networkFailure
        case FetchError.httpStatus:     return .endpointFailure
        case FetchError.decode:         return .responseChanged
        default:                        return .unknownFailure
        }
    }
}

/// 给 DeepSeek 旁路请求分配单调递增代际,确保较旧请求不能覆盖较新的 key 状态。
public struct DeepSeekRequestGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation
    }
}
