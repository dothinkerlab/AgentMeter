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
        try ProviderRequestFailure.checkBusiness(data, service: "miniMax")
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) }
        catch { throw FetchError.decode(String(describing: error)) }
        let status = root["base_resp"] as? [String: Any]
        if let code = CodingAdapterSupport.number(status ?? [:], keys: ["status_code"]), code != 0 {
            throw FetchError.decode("base_resp status \(Int(code))")
        }
        let payload = root["data"] as? [String: Any] ?? root
        guard let entries = payload["model_remains"] as? [[String: Any]] else {
            throw FetchError.decode("model_remains missing")
        }
        let candidates = entries.filter(isTextCodingEntry)
        let general = candidates.filter {
            CodingAdapterSupport.string($0, keys: ["model_name", "model", "name"])?.lowercased() == "general"
        }
        // A named general pool is the authoritative shared text pool. Otherwise
        // multiple model rows are only coalesced when their actual windows agree.
        let selected = general.isEmpty ? candidates : general
        guard !selected.isEmpty else { throw FetchError.decode("text plan missing") }
        let parsed = try selected.map { try textWindows($0, now: now) }
        guard let windows = parsed.first, !windows.isEmpty,
              parsed.allSatisfy({ $0 == windows }) else {
            throw FetchError.decode("ambiguous text plan entries")
        }
        let model = selected.count == 1
            ? CodingAdapterSupport.string(selected[0], keys: ["model_name", "model", "name"]) : nil
        return QuotaSnapshot(tool: .miniMax, plan: plan ?? (model == "general" ? nil : model), windows: windows,
                             confidence: .fresh, source: Self.source, updatedAt: now)
    }

    private func isTextCodingEntry(_ item: [String: Any]) -> Bool {
        let names = ["model_name", "model", "name", "resource_type"].compactMap { item[$0] as? String }
            .joined(separator: " ").lowercased()
        let excluded = ["speech", "tts", "image", "video", "hailuo", "music", "voice", "audio"]
        guard !excluded.contains(where: names.contains) else { return false }
        // Unlabelled/new resource classes must not be mistaken for Coding quota.
        return names.contains("general") || names.contains("m2") || names.contains("m3")
            || names.contains("text") || names.contains("coding")
    }

    private func textWindows(_ item: [String: Any], now: Date) throws -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        if let value = try makeWindow(item, kind: .fiveHour,
            usedKeys: ["current_interval_used_count", "current_interval_used", "current_interval_usage_count"],
            remainingKeys: ["current_interval_remaining_count", "current_interval_remain_count", "current_interval_remaining"],
            limitKeys: ["current_interval_total_count", "current_interval_limit"],
            percentKeys: ["current_interval_remaining_percent"],
            resetKeys: ["end_time", "current_interval_end_time", "current_interval_reset_time"],
            statusKeys: ["current_interval_status"], now: now) { windows.append(value) }
        if let value = try makeWindow(item, kind: .sevenDay,
            usedKeys: ["current_weekly_used_count", "weekly_used_count", "week_usage_count", "weekly_usage_count", "current_weekly_usage_count"],
            remainingKeys: ["current_weekly_remaining_count", "weekly_remaining_count", "week_remaining_count", "weekly_remain_count"],
            limitKeys: ["current_weekly_total_count", "weekly_total_count", "week_total_count", "weekly_limit"],
            percentKeys: ["current_weekly_remaining_percent"],
            resetKeys: ["weekly_end_time", "week_end_time", "weekly_reset_time"],
            statusKeys: ["current_weekly_status"], now: now) { windows.append(value) }
        guard !windows.isEmpty else { throw FetchError.decode("no valid text quota window") }
        return windows
    }

    private func makeWindow(_ item: [String: Any], kind: WindowKind,
                            usedKeys: [String], remainingKeys: [String], limitKeys: [String],
                            percentKeys: [String], resetKeys: [String], statusKeys: [String], now: Date) throws -> QuotaWindow? {
        if let key = statusKeys.first(where: { item[$0] != nil }) {
            guard let status = CodingAdapterSupport.number(item[key]) else { throw FetchError.decode("invalid quota status") }
            if status == 3 { return nil } // This resource is not covered by the plan.
            guard status == 1 else { throw FetchError.decode("unknown quota status") }
        }
        let relevant = usedKeys + remainingKeys + limitKeys + percentKeys + resetKeys
        guard relevant.contains(where: { item[$0] != nil }) else { return nil }
        let percent: Double
        if let key = percentKeys.first(where: { item[$0] != nil }) {
            guard let remaining = CodingAdapterSupport.number(item[key]), remaining.isFinite,
                  (0...100).contains(remaining) else { throw FetchError.decode("invalid remaining percent") }
            // Explicit remaining percent avoids ambiguous legacy *_usage_count semantics.
            percent = 100 - remaining
        } else {
            guard let used = CodingAdapterSupport.usedPercent(
                used: CodingAdapterSupport.number(item, keys: usedKeys),
                remaining: CodingAdapterSupport.number(item, keys: remainingKeys),
                limit: CodingAdapterSupport.number(item, keys: limitKeys)) else {
                throw FetchError.decode("invalid quota counts")
            }
            percent = used
        }
        guard let reset = CodingAdapterSupport.date(item, keys: resetKeys, now: now),
              reset.timeIntervalSince1970.isFinite, reset > now, reset <= .distantFuture else {
            throw FetchError.decode("missing or expired quota reset")
        }
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
        do { (data, response) = try await SubscriptionRequestCoordinator.shared.data(for: request, service: "miniMax", session: session) }
        catch {
            if error is ProviderRequestFailure { throw error }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw FetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport("non-HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, plan: plan, now: now)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case let failure as ProviderRequestFailure: failure.reason
        case FetchError.unauthorized: .authExpired
        case FetchError.transport: .networkFailure
        case FetchError.httpStatus: .endpointFailure
        case FetchError.decode: .responseChanged
        default: .unknownFailure
        }
    }
}
