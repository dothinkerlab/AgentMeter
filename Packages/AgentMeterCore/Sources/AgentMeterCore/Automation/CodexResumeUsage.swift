import Foundation

/// Fresh authenticated endpoint evidence, intentionally separate from display snapshots.
/// No clamping, guessed windows or cached data may authorize a queue submission.
public struct CodexResumeUsage: Sendable {
    public enum Failure: Error { case invalidResponse, accountMismatch }
    public enum Decision: Equatable, Sendable { case ready, waiting(Date?), restricted }
    public let accountID: String
    public let observedAt: Date
    public let decision: Decision

    public static func parse(_ data: Data, accountID: String, now: Date = Date()) throws -> Self {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard !accountID.isEmpty, response.accountID == accountID else { throw Failure.accountMismatch }
        guard response.hasClassification else { throw Failure.invalidResponse }
        var buckets = [response.rateLimit]
        // Require all reported model limits to be clear; never guess which limited model will run next.
        buckets += response.additional?.map(\.rateLimit) ?? []
        var resets: [Date] = []
        var blocked = false
        for bucket in buckets {
            let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
            guard !windows.isEmpty else { throw Failure.invalidResponse }
            for window in windows {
                guard window.used.isFinite, (0...100).contains(window.used), window.duration > 0,
                      window.reset.isFinite, window.reset > now.timeIntervalSince1970 else { throw Failure.invalidResponse }
                if window.used >= 100 { blocked = true; resets.append(Date(timeIntervalSince1970: window.reset)) }
            }
            if bucket.reached || !bucket.allowed { blocked = true }
        }
        let classification = response.classification
        if let classification, classification != "rate_limit_reached" {
            return .init(accountID: accountID, observedAt: now, decision: .restricted)
        }
        if response.spendRestricted {
            return .init(accountID: accountID, observedAt: now, decision: .restricted)
        }
        if blocked || classification == "rate_limit_reached" {
            return .init(accountID: accountID, observedAt: now,
                         decision: .waiting(resets.max()?.addingTimeInterval(20)))
        }
        return .init(accountID: accountID, observedAt: now, decision: .ready)
    }

    private struct Window: Decodable {
        let used: Double
        let duration: Int
        let reset: Double
        enum CodingKeys: String, CodingKey {
            case used = "used_percent", duration = "limit_window_seconds", reset = "reset_at"
        }
    }
    private struct Bucket: Decodable {
        let allowed: Bool
        let reached: Bool
        let primary: Window?
        let secondary: Window?
        enum CodingKeys: String, CodingKey {
            case allowed, reached = "limit_reached", primary = "primary_window", secondary = "secondary_window"
        }
    }
    private struct Additional: Decodable {
        let rateLimit: Bucket
        enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
    }
    private struct SpendControl: Decodable { let reached: Bool }
    private struct Response: Decodable {
        let accountID: String
        let rateLimit: Bucket
        let additional: [Additional]?
        let classification: String?
        let hasClassification: Bool
        let spendRestricted: Bool
        enum CodingKeys: String, CodingKey {
            case accountID = "account_id", rateLimit = "rate_limit", additional = "additional_rate_limits"
            case classification = "rate_limit_reached_type", spend = "spend_control"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accountID = try values.decode(String.self, forKey: .accountID)
            rateLimit = try values.decode(Bucket.self, forKey: .rateLimit)
            additional = try values.decodeIfPresent([Additional].self, forKey: .additional)
            hasClassification = values.contains(.classification)
            classification = try values.decodeIfPresent(String.self, forKey: .classification)
            guard values.contains(.spend) else { throw Failure.invalidResponse }
            spendRestricted = try values.decodeIfPresent(SpendControl.self, forKey: .spend)?.reached ?? false
        }
    }
}
