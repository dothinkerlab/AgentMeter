import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MiniMaxTokenPlanAdapter: Sendable {
    public static let source = "minimax_token_plan_endpoint"
    public let region: ProviderRegion
    public let remainsURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(region: ProviderRegion, remainsURL: URL? = nil) {
        self.region = region
        self.remainsURL = remainsURL ?? region.miniMaxTokenPlanURL
    }

    public func parse(data: Data, plan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) }
        catch { throw FetchError.decode(String(describing: error)) }
        let status = root["base_resp"] as? [String: Any]
        if let code = CodingAdapterSupport.number(status ?? [:], keys: ["status_code"]), code != 0 {
            throw FetchError.decode("base_resp status \(Int(code))")
        }
        guard let entries = root["model_remains"] as? [[String: Any]] else {
            throw FetchError.decode("model_remains missing")
        }
        let candidates = entries.filter(isTextCodingEntry)
        guard let selected = disambiguate(candidates) else {
            throw FetchError.decode(candidates.isEmpty ? "text plan missing" : "ambiguous text plan entries")
        }

        var windows: [QuotaWindow] = []
        if let window = makeWindow(selected, kind: .fiveHour,
            usedKeys: ["current_interval_usage_count", "current_interval_used_count", "current_interval_used"],
            remainingKeys: ["current_interval_remaining_count", "current_interval_remain_count", "current_interval_remaining"],
            limitKeys: ["current_interval_total_count", "current_interval_limit"],
            resetKeys: ["current_interval_end_time", "current_interval_reset_time"], now: now) {
            windows.append(window)
        }
        if let window = makeWindow(selected, kind: .sevenDay,
            usedKeys: ["weekly_usage_count", "week_usage_count", "weekly_used_count"],
            remainingKeys: ["weekly_remaining_count", "week_remaining_count", "weekly_remain_count"],
            limitKeys: ["weekly_total_count", "week_total_count", "weekly_limit"],
            resetKeys: ["weekly_end_time", "week_end_time", "weekly_reset_time"], now: now) {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw FetchError.decode("no valid text quota window") }
        let model = CodingAdapterSupport.string(selected, keys: ["model_name", "model", "name"])
        return QuotaSnapshot(tool: .miniMax, plan: plan ?? model, windows: windows,
                             confidence: .fresh, source: Self.source, updatedAt: now)
    }

    private func isTextCodingEntry(_ item: [String: Any]) -> Bool {
        let name = CodingAdapterSupport.string(item, keys: ["model_name", "model", "name", "resource_type"])?.lowercased() ?? ""
        let excluded = ["speech", "tts", "image", "video", "hailuo", "music", "voice"]
        guard !excluded.contains(where: name.contains) else { return false }
        if name.isEmpty { return item["current_interval_total_count"] != nil }
        return name.contains("m2") || name.contains("minimax") || name.contains("text") || name.contains("coding")
    }

    private func disambiguate(_ candidates: [[String: Any]]) -> [String: Any]? {
        if candidates.count == 1 { return candidates[0] }
        let latest = candidates.filter {
            let name = CodingAdapterSupport.string($0, keys: ["model_name", "model", "name"])?.lowercased() ?? ""
            return name.contains("m2.7")
        }
        return latest.count == 1 ? latest[0] : nil
    }

    private func makeWindow(_ item: [String: Any], kind: WindowKind,
                            usedKeys: [String], remainingKeys: [String], limitKeys: [String],
                            resetKeys: [String], now: Date) -> QuotaWindow? {
        guard let percent = CodingAdapterSupport.usedPercent(
            used: CodingAdapterSupport.number(item, keys: usedKeys),
            remaining: CodingAdapterSupport.number(item, keys: remainingKeys),
            limit: CodingAdapterSupport.number(item, keys: limitKeys)),
              let reset = CodingAdapterSupport.date(item, keys: resetKeys, now: now), reset > now else { return nil }
        return QuotaWindow(usedPercent: percent, resetsAt: reset, kind: kind)
    }

    public func fetch(apiKey: String, plan: String? = nil,
                      session: URLSession = .shared, now: Date = Date()) async throws -> QuotaSnapshot {
        var request = URLRequest(url: remainsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
}
