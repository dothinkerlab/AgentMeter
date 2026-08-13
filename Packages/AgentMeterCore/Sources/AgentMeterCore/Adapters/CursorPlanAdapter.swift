import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cursor's desktop dashboard RPC is undocumented and may change without notice.
public struct CursorPlanAdapter: Sendable {
    public static let source = "cursor_dashboard_current_period_usage"
    public static let defaultUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    public static let defaultPlanInfoURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!

    public let usageURL: URL
    public let planInfoURL: URL

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(
        usageURL: URL = Self.defaultUsageURL,
        planInfoURL: URL = Self.defaultPlanInfoURL
    ) {
        self.usageURL = usageURL
        self.planInfoURL = planInfoURL
    }

    public func parseUsage(data: Data, plan: String? = nil, now: Date = Date()) throws -> QuotaSnapshot {
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) }
        catch { throw FetchError.decode(String(describing: error)) }

        let usage = root["planUsage"] as? [String: Any] ?? [:]
        guard let reset = CodingAdapterSupport.date(root, keys: ["billingCycleEnd"], now: now),
              reset > now else {
            throw FetchError.decode("missing or invalid billingCycleEnd")
        }

        let percent: Double
        if let explicit = CodingAdapterSupport.number(usage, keys: ["totalPercentUsed"]) {
            guard explicit >= 0 else { throw FetchError.decode("negative totalPercentUsed") }
            percent = min(100, explicit)
        } else {
            guard let limit = CodingAdapterSupport.number(usage, keys: ["limit"]), limit > 0,
                  let remaining = CodingAdapterSupport.number(usage, keys: ["remaining"]), remaining >= 0 else {
                throw FetchError.decode("missing plan usage percentage and limit facts")
            }
            percent = min(100, max(0, (limit - remaining) / limit * 100))
        }

        return QuotaSnapshot(
            tool: .cursor,
            plan: plan,
            windows: [QuotaWindow(usedPercent: percent, resetsAt: reset, kind: .monthly)],
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public func parsePlan(data: Data) -> String? {
        guard let root = try? CodingAdapterSupport.jsonObject(data),
              let info = root["planInfo"] as? [String: Any] else { return nil }
        return CodingAdapterSupport.string(info, keys: ["planName"])
    }

    public func fetch(
        accessToken: String,
        fallbackPlan: String? = nil,
        transport: (any APICostHTTPTransport)? = nil,
        now: Date = Date()
    ) async throws -> QuotaSnapshot {
        let transport = transport ?? SameOriginAPICostHTTPTransport(originURL: usageURL)
        let usageData = try await request(url: usageURL, accessToken: accessToken, transport: transport)
        var plan = fallbackPlan
        if APICostRequestOrigin(url: usageURL)?.permits(planInfoURL) == true,
           let planData = try? await request(url: planInfoURL, accessToken: accessToken, transport: transport) {
            plan = parsePlan(data: planData) ?? plan
        }
        return try parseUsage(data: usageData, plan: plan, now: now)
    }

    private func request(
        url: URL,
        accessToken: String,
        transport: any APICostHTTPTransport
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { throw FetchError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return data
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
