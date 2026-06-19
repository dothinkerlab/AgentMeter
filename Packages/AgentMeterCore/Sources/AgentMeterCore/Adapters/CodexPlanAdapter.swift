import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Codex plan 剩余用量采集 adapter。
///
/// Codex 的额度接口不是稳定公开 API,所以和 Claude adapter 一样把纯解析与网络取数拆开:
/// 单测只覆盖录制 fixture,live fetch 失败时由调用方降级为 stale/unknown。
public struct CodexPlanAdapter: Sendable {

    public static let source = "codex_plan_usage_endpoint"
    public static let defaultUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public let usageURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(usageURL: URL = CodexPlanAdapter.defaultUsageURL) {
        self.usageURL = usageURL
    }

    // MARK: - 解析(可单测)

    /// 把 Codex plan usage 响应解析成 `fresh` 的 `QuotaSnapshot`。
    /// Codex 返回的是"剩余 %",内部统一转成"已用 %"再入库。
    public func parse(data: Data, plan explicitPlan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISODate)

        let raw: CodexPlanUsageResponse
        do {
            raw = try decoder.decode(CodexPlanUsageResponse.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        var windows: [QuotaWindow] = []
        func append(_ w: CodexPlanUsageResponse.Window?, _ kind: WindowKind) {
            guard let w, let resetsAt = w.resetsAt else { return }
            let used: Double
            if let usedPercent = w.usedPercent {
                used = Self.clampedPercent(usedPercent)
            } else if let remaining = w.remainingPercent {
                used = Self.usedPercent(fromRemaining: remaining)
            } else {
                return
            }
            windows.append(QuotaWindow(usedPercent: used, resetsAt: resetsAt, kind: kind))
        }

        append(raw.fiveHour, .fiveHour)
        append(raw.sevenDay, .sevenDay)
        append(raw.monthly, .monthly)
        appendRateLimit(raw.rateLimit?.primaryWindow, to: &windows)
        appendRateLimit(raw.rateLimit?.secondaryWindow, to: &windows)

        guard !windows.isEmpty else {
            throw FetchError.decode("Codex 响应没有可用额度窗口")
        }

        return QuotaSnapshot(
            tool: .codex,
            plan: explicitPlan ?? raw.plan,
            windows: windows,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    // MARK: - 取数(网络)

    public func fetch(
        accessToken: String,
        accountID: String? = nil,
        plan: String? = nil,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> QuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15  // 一次性进程,别被挂死连接拖住。
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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

    static func usedPercent(fromRemaining remaining: Double) -> Double {
        clampedPercent(100 - remaining)
    }

    static func clampedPercent(_ percent: Double) -> Double {
        max(0, min(100, percent))
    }

    private func appendRateLimit(_ window: CodexPlanUsageResponse.Window?, to windows: inout [QuotaWindow]) {
        guard let window, let kind = Self.windowKind(forLimitSeconds: window.limitWindowSeconds) else {
            return
        }
        if !windows.contains(where: { $0.kind == kind }) {
            let before = windows.count
            func append(_ w: CodexPlanUsageResponse.Window?, _ kind: WindowKind) {
                guard let w, let resetsAt = w.resetsAt else { return }
                let used: Double
                if let usedPercent = w.usedPercent {
                    used = Self.clampedPercent(usedPercent)
                } else if let remaining = w.remainingPercent {
                    used = Self.usedPercent(fromRemaining: remaining)
                } else {
                    return
                }
                windows.append(QuotaWindow(usedPercent: used, resetsAt: resetsAt, kind: kind))
            }
            append(window, kind)
            assert(windows.count == before || windows.last?.kind == kind)
        }
    }

    static func windowKind(forLimitSeconds seconds: Int?) -> WindowKind? {
        guard let seconds else { return nil }
        switch seconds {
        case 17_900...18_100:
            return .fiveHour
        case 604_000...605_000:
            return .sevenDay
        default:
            return seconds >= 2_400_000 ? .monthly : nil
        }
    }

    /// 端点时间戳按 ISO8601 解析,兼容有无小数秒。
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
