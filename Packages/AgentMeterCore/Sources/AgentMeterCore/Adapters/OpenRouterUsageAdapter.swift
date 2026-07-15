import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenRouter 当前 API key 用量采集 adapter。
public struct OpenRouterUsageAdapter: Sendable {
    public static let source = "openrouter_key_endpoint"
    public static let defaultUsageURL = URL(string: "https://openrouter.ai/api/v1/key")!

    public let usageURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(usageURL: URL = Self.defaultUsageURL) {
        self.usageURL = usageURL
    }

    private struct Response: Decodable {
        let data: KeyInfo
    }

    private struct KeyInfo: Decodable {
        let label: String?
        let limit: Decimal?
        let limitRemaining: Decimal?
        let limitReset: String?
        let includeBYOKInLimit: Bool
        let usage: Decimal
        let usageDaily: Decimal
        let usageWeekly: Decimal
        let usageMonthly: Decimal
        let byokUsage: Decimal
        let byokUsageDaily: Decimal
        let byokUsageWeekly: Decimal
        let byokUsageMonthly: Decimal
        let expiresAt: Date?

        enum CodingKeys: String, CodingKey {
            case label, limit, usage
            case limitRemaining = "limit_remaining"
            case limitReset = "limit_reset"
            case includeBYOKInLimit = "include_byok_in_limit"
            case usageDaily = "usage_daily"
            case usageWeekly = "usage_weekly"
            case usageMonthly = "usage_monthly"
            case byokUsage = "byok_usage"
            case byokUsageDaily = "byok_usage_daily"
            case byokUsageWeekly = "byok_usage_weekly"
            case byokUsageMonthly = "byok_usage_monthly"
            case expiresAt = "expires_at"
        }
    }

    public func parse(data: Data, now: Date = Date()) throws -> OpenRouterUsage {
        let decoded: Response
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = try decoder.decode(Response.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        let info = decoded.data
        let nonnegative = [
            info.usage, info.usageDaily, info.usageWeekly, info.usageMonthly,
            info.byokUsage, info.byokUsageDaily, info.byokUsageWeekly, info.byokUsageMonthly,
        ]
        guard nonnegative.allSatisfy({ $0 >= 0 }), info.limit.map({ $0 >= 0 }) ?? true else {
            throw FetchError.decode("usage/limit 包含负数")
        }
        if info.limit == nil, info.limitRemaining != nil {
            throw FetchError.decode("无限额 key 不应返回 limit_remaining")
        }

        return OpenRouterUsage(
            keyLabel: info.label,
            usage: info.usage,
            usageDaily: info.usageDaily,
            usageWeekly: info.usageWeekly,
            usageMonthly: info.usageMonthly,
            byokUsage: info.byokUsage,
            byokUsageDaily: info.byokUsageDaily,
            byokUsageWeekly: info.byokUsageWeekly,
            byokUsageMonthly: info.byokUsageMonthly,
            limit: info.limit,
            limitRemaining: info.limitRemaining,
            limitReset: info.limitReset,
            includeBYOKInLimit: info.includeBYOKInLimit,
            expiresAt: info.expiresAt,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public func fetch(
        apiKey: String,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> OpenRouterUsage {
        var request = URLRequest(url: usageURL)
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
        case 200...299: break
        case 401, 403: throw FetchError.unauthorized
        default: throw FetchError.httpStatus(http.statusCode)
        }
        return try parse(data: data, now: now)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized: return .authExpired
        case FetchError.transport: return .networkFailure
        case FetchError.httpStatus: return .endpointFailure
        case FetchError.decode: return .responseChanged
        default: return .unknownFailure
        }
    }
}

public struct OpenRouterRequestGate: Sendable {
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
