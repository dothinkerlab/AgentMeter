import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Console reads only. The POST invokes the billing overview getter, not inference.
public actor TypeSafeBillingAdapter {
    public static let origin = URL(string: "https://console.typesafe.ai")!
    public static let billingURL = origin.appendingPathComponent("settings/billing")
    public static let usageURL = URL(string: "https://console.typesafe.ai/api/usage?granularity=hour")!
    private let transport: any APICostHTTPTransport
    private var action: (id: String, expiresAt: Date)?

    public init(transport: any APICostHTTPTransport = TypeSafeHTTPTransport()) {
        self.transport = transport
    }

    public func fetch(cookieHeader: String, usageCookieHeader: String? = nil, previous: TypeSafeUsage = .init(),
                      calendar: Calendar = .current, now: Date = Date()) async -> TypeSafeUsage {
        let cookie: String
        do { cookie = try TypeSafeCookieHeader.normalize(cookieHeader) }
        catch { return previous.degraded(.invalidCookie) }
        async let billing = fetchBillingMetric(cookie: cookie, previous: previous.billing, now: now)
        async let tokens = fetchTokenMetric(cookie: usageCookieHeader ?? cookie, previous: previous.tokens, calendar: calendar, now: now)
        return await TypeSafeUsage(billing: billing, tokens: tokens)
    }

    private func fetchBillingMetric(cookie: String, previous: TypeSafeMetric<TypeSafeBilling>,
                                    now: Date) async -> TypeSafeMetric<TypeSafeBilling> {
        do {
            var id = try await actionID(cookie: cookie, now: now)
            var response = try await post(cookie: cookie, id: id)
            if response.1.statusCode == 404,
               response.1.value(forHTTPHeaderField: "x-nextjs-action-not-found") == "1" {
                action = nil
                id = try await actionID(cookie: cookie, now: now)
                response = try await post(cookie: cookie, id: id)
            }
            try Self.validate(response)
            return .init(value: try Self.parseBilling(response.0, now: now), updatedAt: now)
        } catch {
            return previous.degraded(Self.failure(error))
        }
    }

    private func fetchTokenMetric(cookie: String, previous: TypeSafeMetric<TypeSafeTokenUsage>,
                                  calendar: Calendar, now: Date) async -> TypeSafeMetric<TypeSafeTokenUsage> {
        do {
            guard !cookie.isEmpty else { throw TypeSafeFailure.missingCookie }
            let normalized = try TypeSafeCookieHeader.normalize(cookie)
            let response = try await request(url: Self.usageURL, cookie: normalized, accept: "application/json")
            try Self.validate(response)
            return .init(value: try Self.parseTokens(response.0, calendar: calendar, now: now), updatedAt: now)
        } catch {
            return previous.degraded(Self.failure(error))
        }
    }

    private func actionID(cookie: String, now: Date) async throws -> String {
        if let action, action.expiresAt > now { return action.id }
        let response = try await request(url: Self.billingURL, cookie: cookie, accept: "text/html")
        try Self.validate(response)
        let html = String(decoding: response.0, as: UTF8.self)
        let scripts = try NSRegularExpression(pattern: #"<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>"#,
                                              options: .caseInsensitive)
        let actionPattern = try NSRegularExpression(
            pattern: #""([0-9a-f]{40,})"[^)]{0,150}"getBillingOverviewResult""#,
            options: .caseInsensitive)
        var seen = Set<URL>()
        var transientFailure: TypeSafeFailure?
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        for match in scripts.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(60) {
            guard ContinuousClock.now < deadline else { throw transientFailure ?? .network }
            guard let range = Range(match.range(at: 1), in: html),
                  let url = URL(string: String(html[range]), relativeTo: Self.origin)?.absoluteURL,
                  Self.permits(url), url.path.hasSuffix(".js"), seen.insert(url).inserted else { continue }
            do {
                // Static scripts never need the session Cookie.
                let chunkResponse = try await request(url: url, cookie: nil, accept: "application/javascript", timeout: 2)
                try Self.validate(chunkResponse)
                let chunk = String(decoding: chunkResponse.0, as: UTF8.self)
                if let found = actionPattern.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)),
                   let range = Range(found.range(at: 1), in: chunk) {
                    let id = String(chunk[range])
                    action = (id, now.addingTimeInterval(12 * 60 * 60))
                    return id
                }
            } catch {
                let failure = Self.failure(error)
                if [.network, .rateLimited, .unavailable, .challenge].contains(failure) {
                    transientFailure = transientFailure ?? failure
                }
            }
        }
        throw transientFailure ?? .responseChanged
    }

    private func post(cookie: String, id: String) async throws -> (Data, HTTPURLResponse) {
        try await request(url: Self.billingURL, cookie: cookie, accept: "text/x-component", actionID: id)
    }

    private func request(url: URL, cookie: String?, accept: String, actionID: String? = nil,
                         timeout: TimeInterval = 6) async throws -> (Data, HTTPURLResponse) {
        guard Self.permits(url) else { throw TypeSafeFailure.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(#""Chromium";v="140", "Google Chrome";v="140", "Not_A Brand";v="99""#, forHTTPHeaderField: "sec-ch-ua")
        request.setValue("?0", forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue(#""macOS""#, forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let actionID {
            request.httpMethod = "POST"
            request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(actionID, forHTTPHeaderField: "Next-Action")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("[]".utf8)
        }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, Self.permits(http.url),
                  data.count <= 2 * 1024 * 1024 else { throw TypeSafeFailure.responseChanged }
            return (data, http)
        } catch let failure as TypeSafeFailure {
            throw failure
        } catch {
            // Raw transport errors may contain URLs or headers; never retain their descriptions.
            throw TypeSafeFailure.network
        }
    }

    public nonisolated static func permits(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == origin.host && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private static func validate(_ response: (Data, HTTPURLResponse)) throws {
        let status = response.1.statusCode
        let text = String(decoding: response.0.prefix(8000), as: UTF8.self).lowercased()
        if response.1.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
            || ((status == 403 || text.contains("<html"))
                && ["just a moment", "attention required", "challenge-platform", "cf-chl"].contains(where: text.contains)) {
            throw TypeSafeFailure.challenge
        }
        if status == 401 || status == 403 || (300..<400).contains(status) { throw TypeSafeFailure.authExpired }
        if status == 429 { throw TypeSafeFailure.rateLimited }
        guard (200..<300).contains(status) else { throw TypeSafeFailure.unavailable }
        let fullText = String(decoding: response.0, as: UTF8.self)
        let normalized = fullText.replacingOccurrences(of: "\\\"", with: "\"")
        if (normalized.contains("\"(auth)\"") && normalized.contains("\"login\""))
            || (text.contains("<html") && (text.contains("continue with google") || text.contains("welcome to typesafe"))) {
            throw TypeSafeFailure.authExpired
        }
    }

    private static func failure(_ error: Error) -> TypeSafeFailure {
        (error as? TypeSafeFailure) ?? .responseChanged
    }

    public nonisolated static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public nonisolated static func parseBilling(_ data: Data, now: Date = Date()) throws -> TypeSafeBilling {
        struct Credit: Decodable {
            let amount: Decimal?
            let remaining: Decimal?
            let expiresAt: String?
            enum CodingKeys: CodingKey { case amount, remaining, expiresAt }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                amount = try? values.decode(Decimal.self, forKey: .amount)
                remaining = try? values.decode(Decimal.self, forKey: .remaining)
                expiresAt = try? values.decode(String.self, forKey: .expiresAt)
            }
        }
        struct Billing: Decodable {
            let balance: Decimal
            let spent: Decimal
            let cycleLabel: String?
            let plan: String?
            let credits: [Credit]?
        }
        struct Payload: Decodable { let billing: Billing }
        struct Result: Decodable { let ok: Bool; let data: Payload? }
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let json = Data(line[line.index(after: colon)...].utf8)
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  object["ok"] != nil else { continue }
            guard let result = try? JSONDecoder().decode(Result.self, from: json) else {
                throw TypeSafeFailure.responseChanged
            }
            guard result.ok else { throw TypeSafeFailure.unavailable }
            guard let billing = result.data?.billing, !billing.balance.isNaN, !billing.spent.isNaN,
                  billing.balance >= 0, billing.spent >= 0 else { throw TypeSafeFailure.responseChanged }
            let credits = (billing.credits ?? []).compactMap { credit -> TypeSafeCredit? in
                guard let amount = credit.amount, let remaining = credit.remaining,
                      !amount.isNaN, !remaining.isNaN, amount >= 0, remaining > 0,
                      let text = credit.expiresAt, let expires = date(text), expires > now else { return nil }
                return TypeSafeCredit(amount: amount, remaining: remaining, expiresAt: expires)
            }.sorted { $0.expiresAt < $1.expiresAt }
            return TypeSafeBilling(balance: billing.balance, spent: billing.spent,
                                   cycleLabel: billing.cycleLabel, plan: billing.plan, credits: credits)
        }
        throw TypeSafeFailure.responseChanged
    }

    public nonisolated static func parseTokens(_ data: Data, calendar: Calendar = .current,
                                               now: Date = Date()) throws -> TypeSafeTokenUsage {
        struct Bucket: Decodable { let day: String; let inputTokens: Int64; let outputTokens: Int64; let requests: Int64 }
        struct Response: Decodable { let buckets: [Bucket] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
              let monthStart = calendar.dateInterval(of: .month, for: now)?.start else {
            throw TypeSafeFailure.responseChanged
        }
        let dayStart = calendar.startOfDay(for: now)
        var today: Int64 = 0, week: Int64 = 0, input: Int64 = 0, output: Int64 = 0, requests: Int64 = 0
        var earliest: Date?
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw TypeSafeFailure.responseChanged }
            return value
        }
        for bucket in response.buckets {
            guard let timestamp = date(bucket.day), bucket.inputTokens >= 0,
                  bucket.outputTokens >= 0, bucket.requests >= 0 else { throw TypeSafeFailure.responseChanged }
            guard timestamp <= now else { continue }
            earliest = min(earliest ?? timestamp, timestamp)
            let total = try add(bucket.inputTokens, bucket.outputTokens)
            if timestamp >= dayStart { today = try add(today, total) }
            if timestamp >= weekStart { week = try add(week, total) }
            if timestamp >= monthStart {
                input = try add(input, bucket.inputTokens)
                output = try add(output, bucket.outputTokens)
                requests = try add(requests, bucket.requests)
            }
        }
        _ = try add(input, output)
        return TypeSafeTokenUsage(todayTokens: today, sevenDayTokens: week, monthInputTokens: input,
                                 monthOutputTokens: output, monthRequests: requests, earliestBucketAt: earliest)
    }
}

/// Even same-host redirects are refused: a login redirect must remain visible as auth expiry.
public final class TypeSafeHTTPTransport: APICostHTTPTransport, @unchecked Sendable {
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private let delegate = RedirectDelegate()
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard TypeSafeBillingAdapter.permits(request.url) else { throw TypeSafeFailure.unavailable }
        return try await session.data(for: request)
    }
    deinit { session.invalidateAndCancel() }
}
