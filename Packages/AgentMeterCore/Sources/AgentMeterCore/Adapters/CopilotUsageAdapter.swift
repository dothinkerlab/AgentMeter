import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CopilotUsageAdapter: Sendable {
    public static let source = "github_copilot_internal_api"
    public static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    public enum FetchError: Error, Equatable {
        case unauthorized, transport, httpStatus(Int), decode
    }

    private struct Response: Decodable {
        let copilotPlan: String?
        let quotaResetDate: String?
        let quotaResetDateUTC: String?
        let quotaSnapshots: Snapshots

        enum CodingKeys: String, CodingKey {
            case copilotPlan = "copilot_plan"
            case quotaResetDate = "quota_reset_date"
            case quotaResetDateUTC = "quota_reset_date_utc"
            case quotaSnapshots = "quota_snapshots"
        }
    }

    private struct Snapshots: Decodable {
        let premiumInteractions: Quota?
        let chat: Quota?
        enum CodingKeys: String, CodingKey {
            case premiumInteractions = "premium_interactions"
            case chat
        }
    }

    private struct Quota: Decodable {
        let entitlement: Double?
        let remaining: Double?
        let percentRemaining: Double?
        let creditsUsed: Double?
        let unlimited: Bool?
        let hasQuota: Bool?

        enum CodingKeys: String, CodingKey {
            case entitlement, remaining, unlimited
            case percentRemaining = "percent_remaining"
            case creditsUsed = "credits_used"
            case hasQuota = "has_quota"
        }
    }

    public init() {}

    public func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw FetchError.decode
        }
        let reset = Self.parseDate(response.quotaResetDateUTC) ?? Self.parseDate(response.quotaResetDate)
        var windows: [QuotaWindow] = []
        if let window = Self.window(response.quotaSnapshots.premiumInteractions, kind: .premiumInteractions, reset: reset) {
            windows.append(window)
        }
        if let window = Self.window(response.quotaSnapshots.chat, kind: .chat, reset: reset) {
            windows.append(window)
        }
        let hasUnlimited = response.quotaSnapshots.premiumInteractions?.unlimited == true
            || response.quotaSnapshots.chat?.unlimited == true
        guard !windows.isEmpty || hasUnlimited || response.copilotPlan != nil else { throw FetchError.decode }
        return QuotaSnapshot(
            tool: .copilot,
            plan: response.copilotPlan?.replacingOccurrences(of: "_", with: " ").capitalized,
            windows: windows,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public func fetch(token: String, session: URLSession = .shared, now: Date = Date()) async throws -> QuotaSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 15
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.transport }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard http.statusCode == 200 else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, now: now)
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

    private static func window(_ quota: Quota?, kind: WindowKind, reset: Date?) -> QuotaWindow? {
        guard let quota, quota.unlimited != true else { return nil }
        let used: Double?
        if let entitlement = quota.entitlement, entitlement > 0, let credits = quota.creditsUsed {
            used = credits / entitlement * 100
        } else if let percentRemaining = quota.percentRemaining {
            used = 100 - percentRemaining
        } else if let entitlement = quota.entitlement, entitlement > 0, let remaining = quota.remaining {
            used = (entitlement - remaining) / entitlement * 100
        } else {
            used = nil
        }
        guard let used, used.isFinite, quota.hasQuota != false else { return nil }
        return QuotaWindow(usedPercent: used, resetsAt: reset, kind: kind)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        let standard = ISO8601DateFormatter()
        if let value = standard.date(from: raw) { return value }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}
