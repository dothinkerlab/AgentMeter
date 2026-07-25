import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Kimi Code managed usage (`/coding/v1/usages`). The parser mirrors the
/// official CLI's deliberately loose field handling while remaining strict
/// about percentages and reset dates before producing a fresh snapshot.
public struct KimiCodeAdapter: Sendable {
    public static let source = "kimi_code_usage_endpoint"
    public static let defaultURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    public let usageURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(usageURL: URL = Self.defaultURL) { self.usageURL = usageURL }

    public func parse(data: Data, plan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) }
        catch { throw FetchError.decode(String(describing: error)) }

        var windows: [QuotaWindow] = []
        if let summary = root["usage"] as? [String: Any],
           let weekly = makeWindow(summary, kind: .sevenDay, now: now) {
            windows.append(weekly)
        }

        if let limits = root["limits"] as? [[String: Any]] {
            for item in limits {
                let detail = item["detail"] as? [String: Any] ?? item
                let window = item["window"] as? [String: Any] ?? [:]
                let label = ([item, detail].compactMap {
                    CodingAdapterSupport.string($0, keys: ["name", "title", "scope"])
                }.first ?? inferredLabel(window: window)).lowercased()
                guard label.contains("5h") || label.contains("5 h") || label.contains("5-hour")
                        || label.contains("5 hour") else { continue }
                if let parsed = makeWindow(detail.merging(window) { current, _ in current }, kind: .fiveHour, now: now) {
                    windows.removeAll { $0.kind == .fiveHour }
                    windows.append(parsed)
                }
            }
        }

        guard !windows.isEmpty else { throw FetchError.decode("no valid quota windows") }
        return QuotaSnapshot(tool: .kimiCode, plan: plan, windows: windows,
                             confidence: .fresh, source: Self.source, updatedAt: now)
    }

    private func inferredLabel(window: [String: Any]) -> String {
        let duration = CodingAdapterSupport.number(window, keys: ["duration"])
        let unit = CodingAdapterSupport.string(window, keys: ["timeUnit", "time_unit"])?.lowercased() ?? ""
        if unit.contains("minute"), duration == 300 { return "5h" }
        if unit.contains("hour"), duration == 5 { return "5h" }
        return ""
    }

    private func makeWindow(_ value: [String: Any], kind: WindowKind, now: Date) -> QuotaWindow? {
        let used = CodingAdapterSupport.number(value, keys: ["used"])
        let remaining = CodingAdapterSupport.number(value, keys: ["remaining"])
        let limit = CodingAdapterSupport.number(value, keys: ["limit"])
        guard let percent = CodingAdapterSupport.usedPercent(used: used, remaining: remaining, limit: limit),
              let reset = CodingAdapterSupport.date(value,
                keys: ["resetAt", "reset_at", "resetTime", "reset_time", "resetIn", "reset_in", "ttl"],
                now: now), reset > now else { return nil }
        return QuotaWindow(usedPercent: percent, resetsAt: reset, kind: kind)
    }

    public func fetch(accessToken: String, plan: String? = nil,
                      session: URLSession = .shared, now: Date = Date()) async throws -> QuotaSnapshot {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
}
