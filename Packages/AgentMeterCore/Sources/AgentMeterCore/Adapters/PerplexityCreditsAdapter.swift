import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PerplexityCreditsAdapter: Sendable {
    public static let usageURL = URL(string: "https://www.perplexity.ai/account/usage")!
    public static let creditsURL = URL(string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")!
    private let transport: any APICostHTTPTransport
    public init(transport: any APICostHTTPTransport = PerplexityHTTPTransport()) { self.transport = transport }

    public func fetch(cookie: String, previous: PerplexityUsage = .init(), now: Date = Date()) async -> PerplexityUsage {
        do {
            for header in try PerplexityCookieHeader.candidates(cookie) {
                var request = URLRequest(url: Self.creditsURL)
                request.timeoutInterval = 15
                request.setValue(header, forHTTPHeaderField: "Cookie")
                request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
                request.setValue(Self.usageURL.absoluteString, forHTTPHeaderField: "Referer")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
                let data: Data
                let response: URLResponse
                do { (data, response) = try await transport.data(for: request) }
                catch { throw PerplexityFailure.network }
                guard let http = response as? HTTPURLResponse, http.url == Self.creditsURL,
                      data.count <= 1024 * 1024 else { throw PerplexityFailure.responseChanged }
                let text = String(decoding: data.prefix(8000), as: UTF8.self).lowercased()
                if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
                    || ((http.statusCode == 403 || text.contains("<html"))
                        && ["just a moment", "challenge-platform", "cf-chl", "attention required"].contains(where: text.contains)) {
                    throw PerplexityFailure.challenge
                }
                if http.statusCode == 401 || http.statusCode == 403 { continue }
                if (300..<400).contains(http.statusCode) { throw PerplexityFailure.authExpired }
                if http.statusCode == 429 { throw PerplexityFailure.rateLimited }
                guard http.statusCode == 200 else { throw PerplexityFailure.unavailable }
                return PerplexityUsage(credits: try Self.parse(data, now: now), updatedAt: now)
            }
            throw PerplexityFailure.authExpired
        } catch {
            return previous.degraded((error as? PerplexityFailure) ?? .responseChanged)
        }
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> PerplexityCredits {
        // Decode typed JSON with Decimal, keeping the provider's credit precision.
        struct Grant: Decodable {
            let type: String
            let amount_cents: Decimal?
            let amountCents: Decimal?
            let expires_at_ts: Double?
            let expiresAtTs: Double?
        }
        struct Response: Decodable {
            let balance_cents: Decimal?; let balanceCents: Decimal?
            let renewal_date_ts: Double?; let renewalDateTs: Double?
            let current_period_purchased_cents: Decimal?; let currentPeriodPurchasedCents: Decimal?
            let total_usage_cents: Decimal?; let totalUsageCents: Decimal?
            let credit_grants: [Grant]?; let creditGrants: [Grant]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let balance = response.balance_cents ?? response.balanceCents,
              let purchasedField = response.current_period_purchased_cents ?? response.currentPeriodPurchasedCents,
              var usage = response.total_usage_cents ?? response.totalUsageCents,
              let grants = response.credit_grants ?? response.creditGrants,
              [balance, purchasedField, usage].allSatisfy({ !$0.isNaN && $0 >= 0 })
        else { throw PerplexityFailure.responseChanged }
        func date(_ timestamp: Double?) throws -> Date? {
            guard let timestamp else { return nil }
            guard timestamp.isFinite, timestamp >= 0, timestamp <= 253402300799 else { throw PerplexityFailure.responseChanged }
            return timestamp == 0 ? nil : Date(timeIntervalSince1970: timestamp)
        }
        let renewal = try date(response.renewal_date_ts ?? response.renewalDateTs)
        var recurring: Decimal = 0, purchased: Decimal = 0, bonus: Decimal = 0
        var bonusExpiry: Date?
        for grant in grants {
            guard let amount = grant.amount_cents ?? grant.amountCents, !amount.isNaN, amount >= 0
            else { throw PerplexityFailure.responseChanged }
            let expiry = try date(grant.expires_at_ts ?? grant.expiresAtTs)
            switch grant.type {
            case "recurring": recurring += amount
            case "purchased": purchased += amount
            case "promotional":
                if expiry == nil || expiry! > now {
                    bonus += amount
                    if let expiry, amount > 0 { bonusExpiry = min(bonusExpiry ?? expiry, expiry) }
                }
            default: throw PerplexityFailure.responseChanged
            }
        }
        purchased = max(purchased, purchasedField)
        guard [recurring, purchased, bonus].allSatisfy({ !$0.isNaN }) else { throw PerplexityFailure.responseChanged }
        let recurringUsed = min(usage, recurring); usage -= recurringUsed
        let purchasedUsed = min(usage, purchased); usage -= purchasedUsed
        let result = PerplexityCredits(
            recurring: .init(total: recurring, used: recurringUsed, date: renewal),
            purchased: .init(total: purchased, used: purchasedUsed),
            bonus: .init(total: bonus, used: min(usage, bonus), date: bonusExpiry))
        try result.validate()
        return result
    }
}

public final class PerplexityHTTPTransport: APICostHTTPTransport, @unchecked Sendable {
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
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.url == PerplexityCreditsAdapter.creditsURL, request.httpMethod == "GET" else { throw PerplexityFailure.unavailable }
        return try await session.data(for: request)
    }
    deinit { session.invalidateAndCancel() }
}
