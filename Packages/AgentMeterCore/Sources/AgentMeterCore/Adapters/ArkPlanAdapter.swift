import Foundation
import CryptoKit

/// Personal Ark subscriptions. Query credentials are cloud AK/SK, never the inference key.
public struct ArkPlanCredentials: Codable, Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public init(accessKeyID: String, secretAccessKey: String) throws {
        let ak = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sk.isEmpty,
              ak.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !sk.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ArkPlanAdapter.FetchError.unauthorized
        }
        self.accessKeyID = ak
        self.secretAccessKey = sk
    }
    public var encoded: String { get throws { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) } }
    public static func decode(_ value: String) throws -> Self {
        let saved = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        return try Self(accessKeyID: saved.accessKeyID, secretAccessKey: saved.secretAccessKey)
    }
}

public struct ArkPlanAdapter: Sendable {
    public enum Product: String, Sendable, CaseIterable {
        case coding, agent
        public var tool: ToolKind { self == .coding ? .arkCoding : .arkAgent }
        public var action: String { self == .coding ? "GetCodingPlanUsage" : "GetAFPUsage" }
        public var source: String { self == .coding ? "ark_coding_plan_api" : "ark_agent_plan_api" }
    }
    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized, httpStatus(Int), transport, decode, business
    }
    public let product: Product
    public init(product: Product) { self.product = product }

    /// Fixed host and action prevent cloud credentials from being redirected elsewhere.
    public func request(credentials: ArkPlanCredentials, now: Date = Date()) -> URLRequest {
        let host = "ark.cn-beijing.volcengineapi.com"
        let query = "Action=\(product.action)&Version=2024-01-01"
        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: now)
        let date = String(timestamp.prefix(8))
        let hash = Self.sha256(request.httpBody!)
        let headers = "content-type:application/json\nhost:\(host)\nx-content-sha256:\(hash)\nx-date:\(timestamp)\n"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonical = "POST\n/\n\(query)\n\(headers)\n\(signedHeaders)\n\(hash)"
        let scope = "\(date)/cn-beijing/ark/request"
        let signingText = "HMAC-SHA256\n\(timestamp)\n\(scope)\n\(Self.sha256(Data(canonical.utf8)))"
        var key = Data(credentials.secretAccessKey.utf8)
        for component in [date, "cn-beijing", "ark", "request"] { key = Self.hmac(key, component) }
        let signature = Self.hmac(key, signingText).map { String(format: "%02x", $0) }.joined()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(timestamp, forHTTPHeaderField: "X-Date")
        request.setValue(hash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue("HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        let root: [String: Any]
        do { root = try CodingAdapterSupport.jsonObject(data) } catch { throw FetchError.decode }
        if let metadata = root["ResponseMetadata"] as? [String: Any],
           let error = metadata["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            if ["AccessDenied", "InvalidAccessKey", "SignatureDoesNotMatch", "InvalidToken", "InvalidAccessKeyId"].contains(code) { throw FetchError.unauthorized }
            if code.contains("Throttl") || code.contains("LimitExceeded") {
                throw ProviderRequestFailure(isRateLimited: true, httpStatus: 200)
            }
            throw FetchError.business
        }
        guard let result = root["Result"] as? [String: Any] else { throw FetchError.decode }
        var windows: [QuotaWindow] = []
        var updatedAt = now
        if product == .agent {
            for (field, kind) in [("AFPFiveHour", WindowKind.fiveHour), ("AFPDaily", .daily), ("AFPWeekly", .sevenDay), ("AFPMonthly", .monthly)] {
                guard let raw = result[field], !(raw is NSNull) else { continue }
                guard let item = raw as? [String: Any] else { throw FetchError.decode }
                guard let percent = CodingAdapterSupport.usedPercent(
                    used: CodingAdapterSupport.number(item, keys: ["Used"]), remaining: nil,
                    limit: CodingAdapterSupport.number(item, keys: ["Quota"])) else { throw FetchError.decode }
                windows.append(QuotaWindow(usedPercent: percent, resetsAt: try reset(item, key: "ResetTime", scale: 1000, now: now), kind: kind))
            }
        } else {
            guard let entries = result["QuotaUsage"] as? [[String: Any]] else { throw FetchError.decode }
            for item in entries {
                let level = CodingAdapterSupport.string(item, keys: ["Level"])?.lowercased()
                let kind: WindowKind
                switch level {
                case "session": kind = .fiveHour
                case "weekly": kind = .sevenDay
                case "monthly": kind = .monthly
                default: throw FetchError.decode
                }
                guard !windows.contains(where: { $0.kind == kind }),
                      let percent = CodingAdapterSupport.number(item, keys: ["Percent"]),
                      (0...100).contains(percent) else { throw FetchError.decode }
                windows.append(QuotaWindow(usedPercent: percent, resetsAt: try reset(item, key: "ResetTimestamp", scale: 1, now: now), kind: kind))
            }
            if result["UpdateTimestamp"] != nil {
                guard let milliseconds = CodingAdapterSupport.number(result, keys: ["UpdateTimestamp"]), milliseconds > 0 else { throw FetchError.decode }
                updatedAt = Date(timeIntervalSince1970: milliseconds / 1000)
                guard updatedAt <= now.addingTimeInterval(60) else { throw FetchError.decode }
            }
        }
        guard !windows.isEmpty else { throw FetchError.decode }
        let isOld = now.timeIntervalSince(updatedAt) > 15 * 60
        return QuotaSnapshot(tool: product.tool, plan: result["PlanType"] as? String, windows: windows,
            confidence: isOld ? .stale : .fresh, source: product.source, updatedAt: updatedAt)
    }

    private func reset(_ item: [String: Any], key: String, scale: Double, now: Date) throws -> Date? {
        guard let raw = item[key] else { return nil }
        guard let value = CodingAdapterSupport.number(raw), value.isFinite else { throw FetchError.decode }
        // Zero is an upstream sentinel for no active reset; never invent one.
        if value == 0 { return nil }
        let date = Date(timeIntervalSince1970: value / scale)
        guard value > 0, date > now, date <= .distantFuture else { throw FetchError.decode }
        return date
    }

    public func fetch(credentials: ArkPlanCredentials, session: URLSession? = nil, now: Date = Date()) async throws -> QuotaSnapshot {
        let ownSession = session ?? URLSession(configuration: .ephemeral, delegate: ArkNoRedirectDelegate(), delegateQueue: nil)
        defer { if session == nil { ownSession.finishTasksAndInvalidate() } }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await SubscriptionRequestCoordinator.shared.data(
                for: request(credentials: credentials, now: now), service: product.source,
                credentialIdentity: credentials.accessKeyID + "\n" + credentials.secretAccessKey, session: ownSession)
        } catch {
            if error is ProviderRequestFailure || error is CancellationError { throw error }
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw FetchError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, now: now)
    }
    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case let failure as ProviderRequestFailure: failure.reason
        case FetchError.unauthorized: .authExpired
        case FetchError.transport: .networkFailure
        case FetchError.decode: .responseChanged
        case FetchError.business, FetchError.httpStatus: .endpointFailure
        default: .unknownFailure
        }
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }
}
private final class ArkNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
