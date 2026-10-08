import Foundation
import CloudKit
import Testing
@testable import AgentMeterCore

private let perplexityNow = Date(timeIntervalSince1970: 1_800_000_000)
private func perplexityFixture() throws -> Data {
    let url = Bundle.module.url(forResource: "credits", withExtension: "json", subdirectory: "Fixtures/Perplexity")!
    return try Data(contentsOf: url)
}
private func perplexityDisplay() throws -> PerplexityDisplaySnapshot {
    .init(.init(credits: try PerplexityCreditsAdapter.parse(perplexityFixture(), now: perplexityNow), updatedAt: perplexityNow))
}

struct PerplexityCreditsTests {
    @Test func poolsUseWaterfallExcludeExpiredAndAvoidDoubleCountingPurchased() throws {
        let credits = try PerplexityCreditsAdapter.parse(perplexityFixture(), now: perplexityNow)
        #expect(credits.recurring.total == 10000)
        #expect(credits.recurring.used == 10000)
        #expect(credits.purchased.total == 40000)
        #expect(credits.purchased.used == 40000)
        #expect(credits.bonus.total == 55000)
        #expect(credits.bonus.used == 31935)
        #expect(credits.bonus.remaining == 23065)
        #expect(credits.bonus.date == perplexityNow.addingTimeInterval(86400))
        #expect(credits.recurring.date == perplexityNow.addingTimeInterval(3600))
        #expect(credits.purchased.date == nil)
    }
    @Test func camelCaseAndDecimalCreditsRemainCredits() throws {
        let json = Data(#"{"balanceCents":0.123456,"renewalDateTs":0,"currentPeriodPurchasedCents":3.123456,"creditGrants":[{"type":"purchased","amountCents":2.5}],"totalUsageCents":0.123456}"#.utf8)
        let value = try PerplexityCreditsAdapter.parse(json)
        #expect(value.purchased.total == Decimal(string: "3.123456"))
        #expect(value.purchased.remaining == 3)
        #expect(value.recurring.date == nil)
        #expect(value.preferredLabelKey == "购买积分")
        let bonusOnly = PerplexityCredits(recurring: .init(total: 0, used: 0), purchased: .init(total: 0, used: 0), bonus: .init(total: 5, used: 1))
        #expect(bonusOnly.preferredLabelKey == "奖励积分")
        #expect(bonusOnly.preferredPool.remaining == 4)
    }
    @Test func zeroPoolsAndMissingRenewalDoNotInventQuota() throws {
        let value = try PerplexityCreditsAdapter.parse(Data(#"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#.utf8))
        #expect(value.recurring.total == 0)
        #expect(value.preferredPool.usedPercent == 100)
        #expect(value.recurring.date == nil)
    }
    @Test(arguments: ["{}", "[]", "not-json",
        #"{"balance_cents":-1,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#,
        #"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":-1}"#,
        #"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[{"type":"new-pool","amount_cents":5}],"total_usage_cents":0}"#,
        #"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":1e200}],"total_usage_cents":0}"#])
    func changedOrInvalidResponsesFail(_ json: String) {
        #expect(throws: PerplexityFailure.self) { try PerplexityCreditsAdapter.parse(Data(json.utf8)) }
    }
    @Test func cookieHeadersChunksAndBareTokens() throws {
        #expect(try PerplexityCookieHeader.candidates("bare-token").count == 4)
        for name in PerplexityCookieHeader.sessionNames {
            #expect(try PerplexityCookieHeader.candidates(" Cookie: irrelevant=private; \(name)=token=pad ") == ["\(name)=token=pad"])
            #expect(try PerplexityCookieHeader.candidates("\(name).1=two; \(name).0=one") == ["\(name)=onetwo"])
        }
        #expect(try PerplexityCookieHeader.normalize("bare-token") == "bare-token")
    }
    @Test(arguments: ["", "token\n", "token\rInjected: x", "authjs.session-token.1=gap", "authjs.session-token.0=one; authjs.session-token.2=gap", "authjs.session-token.-1=bad", "authjs.session-token.99999=bad", "authjs.session-token=a; authjs.session-token=b", "other=x", "authjs.session-token=", "authjs.session-token=x; broken"])
    func invalidCookiesAreRejected(_ value: String) {
        #expect(throws: PerplexityFailure.self) { try PerplexityCookieHeader.candidates(value) }
    }
    @Test func bareTokenTriesNamesOnlyAfterAuthRejection() async throws {
        let transport = PerplexityTestTransport(statuses: [401, 403, 200], body: try perplexityFixture())
        let usage = await PerplexityCreditsAdapter(transport: transport).fetch(cookie: "secret-test", now: perplexityNow)
        #expect(usage.confidence == .fresh)
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[2].value(forHTTPHeaderField: "Cookie") == "__Secure-next-auth.session-token=secret-test")
        #expect(requests.allSatisfy { $0.url == PerplexityCreditsAdapter.creditsURL && $0.httpMethod == "GET" })
        #expect(requests[0].value(forHTTPHeaderField: "Origin") == "https://www.perplexity.ai")
        #expect(requests[0].value(forHTTPHeaderField: "Referer") == PerplexityCreditsAdapter.usageURL.absoluteString)
    }
    @Test(arguments: [(429, PerplexityFailure.rateLimited), (503, .unavailable), (302, .authExpired), (200, .responseChanged)])
    func nonAuthFailuresNeverRetryAndKeepOldFacts(_ status: Int, _ failure: PerplexityFailure) async throws {
        let old = PerplexityUsage(credits: try PerplexityCreditsAdapter.parse(perplexityFixture(), now: perplexityNow), updatedAt: perplexityNow)
        let transport = PerplexityTestTransport(statuses: [status], body: Data("not json".utf8))
        let value = await PerplexityCreditsAdapter(transport: transport).fetch(cookie: "bare", previous: old)
        #expect(value.failure == failure)
        #expect(value.confidence == .stale)
        #expect(value.updatedAt == old.updatedAt)
        #expect(value.credits == old.credits)
        #expect(await transport.requests.count == 1)
    }
    @Test func challengeNetworkAndExhaustedAuthAreDistinct() async {
        let challenge = PerplexityTestTransport(statuses: [403], body: Data("<html>Just a moment challenge-platform</html>".utf8))
        let first = await PerplexityCreditsAdapter(transport: challenge).fetch(cookie: "bare")
        #expect(first.failure == .challenge)
        #expect(await challenge.requests.count == 1)
        #expect(first.confidence == .unknown)
        let network = PerplexityTestTransport(statuses: [], body: Data(), networkFailure: true)
        #expect(await PerplexityCreditsAdapter(transport: network).fetch(cookie: "bare").failure == .network)
        let auth = PerplexityTestTransport(statuses: [401, 401, 401, 401], body: Data())
        #expect(await PerplexityCreditsAdapter(transport: auth).fetch(cookie: "bare").failure == .authExpired)
        #expect(await auth.requests.count == 4)
    }
    @Test func fixedOriginAndResponseBoundAreEnforced() async throws {
        let transport = PerplexityHTTPTransport()
        await #expect(throws: PerplexityFailure.self) {
            try await transport.data(for: URLRequest(url: URL(string: "https://evil.example/rest/billing/credits")!))
        }
        let oversized = PerplexityTestTransport(statuses: [200], body: Data(repeating: 32, count: 1_048_577))
        #expect(await PerplexityCreditsAdapter(transport: oversized).fetch(cookie: "bare").failure == .responseChanged)
    }
    @Test func displaySyncRoundTripAndStalePauseTombstone() throws {
        let value = try perplexityDisplay()
        let envelope = PerplexitySyncEnvelope(snapshot: value, revision: perplexityNow)
        let record = CKRecord(recordType: PerplexityRecordMapping.recordType, recordID: PerplexityRecordMapping.recordID)
        try PerplexityRecordMapping.apply(envelope, to: record)
        #expect(try PerplexityRecordMapping.decode(record) == envelope)
        #expect(!value.isStale(now: perplexityNow))
        #expect(value.isStale(now: perplexityNow.addingTimeInterval(901)))
        var paused = value; paused.paused = true
        #expect(paused.isStale(now: perplexityNow))
        #expect(value.markedSyncFailed(.networkFailure).credits == value.credits)
        let disabled = PerplexitySyncEnvelope(snapshot: nil, revision: perplexityNow.addingTimeInterval(1))
        #expect(!PerplexityRecordMapping.shouldReplace(disabled, with: envelope))
        try PerplexityRecordMapping.apply(disabled, to: record)
        #expect(try PerplexityRecordMapping.decode(record).snapshot == nil)
        record["revision"] = perplexityNow as CKRecordValue
        #expect(throws: PerplexitySyncError.self) { try PerplexityRecordMapping.decode(record) }
    }
    @Test func additiveBundlePreservesJevAndContainsNoSessionMaterial() throws {
        let jev = TypeSafeDisplaySnapshot(.init(billing: .init(value: .init(balance: 42, spent: 8), updatedAt: perplexityNow)))
        let bundle = LocalBillingSnapshotBundle(typesafe: jev, perplexity: try perplexityDisplay())
        let data = try LocalBillingCache.encodeForTransfer(bundle)
        #expect(try LocalBillingCache.decodeTransferred(data) == bundle)
        #expect(bundle.contains(.perplexity))
        struct OldV3: Decodable { let schemaVersion: Int; let typesafe: TypeSafeDisplaySnapshot? }
        #expect(try JSONDecoder().decode(OldV3.self, from: data).typesafe == jev)
        for forbidden in ["cookie", "Cookie", "profileID", "chrome", "rawResponse", "secret-test"] {
            #expect(!String(decoding: data, as: UTF8.self).contains(forbidden))
        }
        #expect(try LocalBillingCache.decodeTransferred(Data(#"{"schemaVersion":3}"#.utf8)).perplexity == nil)
    }
    @Test func invalidSnapshotCannotEnterCloudOrCache() throws {
        let credits = PerplexityCredits(recurring: .init(total: 1, used: 2), purchased: .init(total: 0, used: 0), bonus: .init(total: 0, used: 0))
        let data = try JSONEncoder().encode(PerplexityDisplaySnapshot(.init(credits: credits, updatedAt: perplexityNow)))
        #expect(throws: PerplexityFailure.self) { try JSONDecoder().decode(PerplexityDisplaySnapshot.self, from: data) }
        #expect(throws: PerplexityFailure.self) { try PerplexityDisplaySnapshot(.init(credits: credits)).validate() }
    }
}

private actor PerplexityTestTransport: APICostHTTPTransport {
    private var statuses: [Int]
    private let body: Data
    private let networkFailure: Bool
    var requests: [URLRequest] = []
    init(statuses: [Int], body: Data, networkFailure: Bool = false) {
        self.statuses = statuses; self.body = body; self.networkFailure = networkFailure
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if networkFailure { throw URLError(.notConnectedToInternet) }
        let status = statuses.isEmpty ? 500 : statuses.removeFirst()
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
