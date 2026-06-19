import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude Code 取数核心(项目核心文件之一)。
///
/// 职责:用 OAuth access token 调 `/api/oauth/usage`,把原始响应清洗成统一口径的
/// `QuotaSnapshot`。**纯解析 `parse(...)` 与网络 `fetch(...)` 分离**,前者用录制的
/// JSON fixture 做单测,不打真端点。
public struct ClaudeCodeAdapter: Sendable {

    public static let source = "oauth_usage_endpoint"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    public enum FetchError: Error, Sendable, Equatable {
        /// HTTP 401 或端点明确拒绝 —— 通常是 token 过期,需手动重激活。
        case unauthorized
        /// 其他非 2xx 状态码。
        case httpStatus(Int)
        /// 网络层失败。
        case transport(String)
        /// 响应不是合法 JSON / 字段无法解析。
        case decode(String)
    }

    public init() {}

    // MARK: - 解析(可单测)

    /// 把端点原始响应字节解析成 `fresh` 的 `QuotaSnapshot`。
    /// - Parameter now: 采集成功的时刻,作为 `updatedAt`。注入便于测试。
    public func parse(data: Data, plan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISODate)

        let raw: UsageEndpointResponse
        do {
            raw = try decoder.decode(UsageEndpointResponse.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        var windows: [QuotaWindow] = []
        // utilization 本就是"已用 %",直接入库,不做 100- 反转(口径统一,铁律 3)。
        func append(_ w: UsageEndpointResponse.Window?, _ kind: WindowKind) {
            guard let w, let used = w.utilization, let resetsAt = w.resetsAt else { return }
            windows.append(QuotaWindow(usedPercent: used, resetsAt: resetsAt, kind: kind))
        }
        append(raw.fiveHour, .fiveHour)
        append(raw.sevenDay, .sevenDay)
        append(raw.sevenDayOpus, .sevenDayOpus)
        append(raw.sevenDaySonnet, .sevenDaySonnet)

        return QuotaSnapshot(
            tool: .claudeCode,
            plan: plan,
            windows: windows,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    // MARK: - 取数(网络)

    /// 调端点取数并解析。失败时抛 `FetchError`,由调用方决定降级为 stale/unknown。
    public func fetch(
        accessToken: String,
        plan: String? = nil,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> QuotaSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15  // 一次性进程,别被挂死连接拖住。
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        return try parse(data: data, plan: plan, now: now)
    }

    // MARK: - 日期解析

    /// 端点用带偏移的 ISO8601,如 "2026-06-14T20:59:59+00:00"。兼容有无小数秒。
    /// formatter 局部构造:ISO8601DateFormatter 非 Sendable,不能做 static 共享。
    static func decodeISODate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractional.date(from: string) ?? plain.date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "无法解析 ISO8601 日期: \(string)"
        )
    }
}
