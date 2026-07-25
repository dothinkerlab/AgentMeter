import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GLMCodingPlanAdapter: Sendable {
    public static let source = "glm_coding_quota_endpoint"
    public let region: ProviderRegion
    public let quotaURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(region: ProviderRegion, quotaURL: URL? = nil) {
        self.region = region
        self.quotaURL = quotaURL ?? region.glmQuotaURL
    }

    public func parse(data: Data, plan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) }
        catch { throw FetchError.decode(String(describing: error)) }
        let payload = root["data"] as? [String: Any] ?? root
        guard let limits = payload["limits"] as? [[String: Any]] else {
            throw FetchError.decode("data.limits missing")
        }
        let tokenLimits = limits.filter {
            ($0["type"] as? String)?.uppercased() == "TOKENS_LIMIT"
        }
        var windows: [QuotaWindow] = []
        for item in tokenLimits {
            guard let percentage = CodingAdapterSupport.number(item, keys: ["percentage"]),
                  percentage.isFinite, (0...100).contains(percentage),
                  let reset = CodingAdapterSupport.date(item,
                    keys: ["nextResetTime", "resetTime", "reset_at", "resetAt", "endTime", "end_time"],
                    now: now), reset > now else { continue }
            let label = CodingAdapterSupport.string(item,
                keys: ["name", "title", "scope", "period", "unit", "windowType"])?.lowercased() ?? ""
            guard let kind = Self.windowKind(for: label) else { continue }
            windows.removeAll { $0.kind == kind }
            windows.append(QuotaWindow(usedPercent: percentage, resetsAt: reset, kind: kind))
        }
        guard !windows.isEmpty else { throw FetchError.decode("no valid TOKENS_LIMIT window") }
        return QuotaSnapshot(tool: .glmCoding, plan: plan, windows: windows,
                             confidence: .fresh, source: Self.source, updatedAt: now)
    }

    public func fetch(apiKey: String, plan: String? = nil,
                      session: URLSession = .shared, now: Date = Date()) async throws -> QuotaSnapshot {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport("non-HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, plan: plan, now: now)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized: .authExpired
        case FetchError.transport: .networkFailure
        case FetchError.httpStatus: .endpointFailure
        case FetchError.decode: .responseChanged
        default: .unknownFailure
        }
    }

    private static func windowKind(for label: String) -> WindowKind? {
        let normalized = label
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        if normalized.contains("week")
            || normalized.contains("7 day")
            || normalized.contains("7day")
            || normalized == "7d" {
            return .sevenDay
        }
        if normalized.contains("month")
            || normalized.contains("30 day")
            || normalized == "30d" {
            return .monthly
        }
        if normalized.contains("5 hour")
            || normalized.contains("5hour")
            || normalized.contains("five hour")
            || normalized == "5h" {
            return .fiveHour
        }
        return nil
    }
}
