import Foundation

/// Local error classification; no new stale enum cases enter older Watch snapshots.
public struct ProviderRequestFailure: Error, Sendable, Equatable, Codable {
    public let isRateLimited: Bool
    public let retryAt: Date?
    public let httpStatus: Int
    public let reason: QuotaStaleReason

    public init(isRateLimited: Bool, retryAt: Date? = nil, httpStatus: Int, reason: QuotaStaleReason = .endpointFailure) {
        self.isRateLimited = isRateLimited
        self.retryAt = retryAt
        self.httpStatus = httpStatus
        self.reason = reason
    }

    static func check(_ http: HTTPURLResponse, data: Data, service: String, now: Date = Date()) throws {
        // Known business errors take precedence: HTTP 429 can also mean exhausted credit.
        let retryAt = BillingRetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After"), now: now)
        do { try checkBusiness(data, service: service, httpStatus: http.statusCode) }
        catch let failure as Self {
            throw Self(isRateLimited: failure.isRateLimited,
                       retryAt: failure.isRateLimited ? retryAt : nil,
                       httpStatus: http.statusCode, reason: failure.reason)
        }
        if http.statusCode == 429 {
            throw Self(isRateLimited: true, retryAt: retryAt, httpStatus: 429)
        }
        if http.statusCode == 503, let retryAt {
            throw Self(isRateLimited: false, retryAt: retryAt, httpStatus: 503)
        }
    }

    static func checkBusiness(_ data: Data, service: String, httpStatus: Int = 200) throws {
        guard ["miniMax", "glmCoding", "openAIAPI", "ark_coding_plan_api", "ark_agent_plan_api"].contains(service) else { return }
        let root: [String: Any]
        do { root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        catch { return } // The adapter still validates and reports malformed payloads.
        let error = root["error"] as? [String: Any] ?? [:]
        if service.hasPrefix("ark_"), let meta = root["ResponseMetadata"] as? [String: Any],
           let error = meta["Error"] as? [String: Any], let code = error["Code"] as? String,
           code.contains("Throttl") || code.contains("LimitExceeded") {
            throw Self(isRateLimited: true, httpStatus: httpStatus)
        }

        if service == "openAIAPI", error["code"] as? String == "insufficient_quota" {
            throw Self(isRateLimited: false, httpStatus: httpStatus)
        }
        if service == "miniMax", let response = root["base_resp"] as? [String: Any],
           let code = response["status_code"] as? Int, code != 0 {
            throw Self(isRateLimited: code == 1002, httpStatus: httpStatus,
                       reason: code == 1004 ? .authExpired : .endpointFailure)
        }
        if service == "glmCoding", let raw = error["code"] ?? root["code"] {
            let code = String(describing: raw)
            if ["1302", "1305"].contains(code) {
                throw Self(isRateLimited: true, httpStatus: httpStatus)
            }
            if ["1113", "1308", "1309", "1310"].contains(code) {
                throw Self(isRateLimited: false, httpStatus: httpStatus)
            }
            if ["1000", "1001", "1002", "1003", "1004"].contains(code) {
                throw Self(isRateLimited: false, httpStatus: httpStatus, reason: .authExpired)
            }
        }
    }
}
