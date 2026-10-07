import Foundation
import Testing
@testable import AgentMeterCore

struct TypeSafeBillingAdapterTests {
    static let now = ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!
    static let oldID = String(repeating: "a", count: 40)
    static let newID = String(repeating: "b", count: 40)
    static let html = #"<script src="https://evil.test/x.js"></script><script src="/_next/static/billing.js"></script>"#
    static let billing = #"0:{"a":"$@1"}"# + "\n" +
        #"1:{"ok":true,"data":{"billing":{"balance":4.987654,"spent":0.000042,"plan":"free_plan","cycleLabel":"October 2026","credits":[{"amount":5,"remaining":4.98,"expiresAt":"2026-11-01T00:00:00Z"},{"amount":5,"remaining":0,"expiresAt":"2026-11-01T00:00:00Z"},{"amount":2,"remaining":1,"expiresAt":"2026-09-01T00:00:00Z"},{"amount":2,"remaining":1,"expiresAt":"invalid"}]}}}"#
    static let usage = #"{"buckets":[{"day":"2026-09-30T20:00:00Z","inputTokens":100,"outputTokens":10,"requests":1},{"day":"2026-10-01T00:00:00Z","inputTokens":200,"outputTokens":20,"requests":2},{"day":"2026-10-06T01:00:00.000Z","inputTokens":300,"outputTokens":30,"requests":3}]}"#

    @Test func defaultsAndCookieValidation() throws {
        let suite = "typesafe-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TypeSafePreferences.source(defaults: defaults) == .auto)
        #expect(!ManualProviderPreferences.isEnabled(.typesafe, credentialExists: true, defaults: defaults))
        #expect(ManualProviderKind.typesafe.toolKind == nil)
        #expect(ManualProviderKind.typesafe.localBillingService == nil)
        #expect(ManualProviderKind.typesafe.credentialShape == .cookieHeader)
        #expect(try TypeSafeCookieHeader.normalize(" Cookie: session=fixture; empty= ") == "session=fixture; empty=")
        #expect(try TypeSafeCookieHeader.normalize("a=x=y") == "a=x=y")
        for value in ["", "sk-api-key", "bad name=x", "a=x\n", "a=x\r\nX-Injected: y", "a=x\t", "a=x;", "a=中文"] {
            #expect(throws: TypeSafeFailure.invalidCookie) { try TypeSafeCookieHeader.normalize(value) }
        }
    }

    @Test func parsesDecimalMoneyAndOnlyActiveCredits() throws {
        let billing = try TypeSafeBillingAdapter.parseBilling(Data(Self.billing.utf8), now: Self.now)
        #expect(billing.balance == Decimal(string: "4.987654"))
        #expect(billing.spent == Decimal(string: "0.000042"))
        #expect(billing.credits.count == 1)
        #expect(billing.plan == "free_plan")
        let zero = Self.billing.replacingOccurrences(of: "4.987654", with: "0")
        #expect(try TypeSafeBillingAdapter.parseBilling(Data(zero.utf8), now: Self.now).balance == 0)
    }

    @Test func badRequiredMoneyAndMissingResultFail() {
        for data in [
            Self.billing.replacingOccurrences(of: "4.987654", with: "null"),
            Self.billing.replacingOccurrences(of: "4.987654", with: "-1"),
            Self.billing.replacingOccurrences(of: "0.000042", with: #""invalid""#),
            #"0:{"other":true}"#
        ] {
            #expect(throws: TypeSafeFailure.responseChanged) {
                try TypeSafeBillingAdapter.parseBilling(Data(data.utf8), now: Self.now)
            }
        }
    }

    @Test func tokenPeriodsUseLocalCalendarAndCrossMonthCorrectly() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = try TypeSafeBillingAdapter.parseTokens(Data(Self.usage.utf8), calendar: utc, now: Self.now)
        #expect(result.todayTokens == 330)
        #expect(result.sevenDayTokens == 660) // Starts September 30, six calendar days before today.
        #expect(result.monthTokens == 550)
        #expect(result.monthRequests == 5)
        var shanghai = utc
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let local = try TypeSafeBillingAdapter.parseTokens(Data(Self.usage.utf8), calendar: shanghai, now: Self.now)
        #expect(local.monthTokens == 660) // September 30 20:00 UTC is October 1 locally.
        #expect(local.monthRequests == 6)
    }

    @Test func futureAndEmptyBucketsDoNotInventHistory() throws {
        let empty = try TypeSafeBillingAdapter.parseTokens(Data(#"{"buckets":[]}"#.utf8), now: Self.now)
        #expect(empty.monthTokens == 0)
        #expect(empty.earliestBucketAt == nil)
        let future = Data(#"{"buckets":[{"day":"2099-01-01T00:00:00Z","inputTokens":9,"outputTokens":2,"requests":1}]}"#.utf8)
        #expect(try TypeSafeBillingAdapter.parseTokens(future, now: Self.now).monthTokens == 0)
    }

    @Test func invalidCountsAndOverflowAreRejected() {
        for body in [
            #"{"buckets":[{"day":"invalid","inputTokens":1,"outputTokens":0,"requests":1}]}"#,
            #"{"buckets":[{"day":"2026-10-01T00:00:00Z","inputTokens":-1,"outputTokens":0,"requests":1}]}"#,
            #"{"buckets":[{"day":"2026-10-01T00:00:00Z","inputTokens":1.5,"outputTokens":0,"requests":1}]}"#,
            #"{"buckets":[{"day":"2026-10-01T00:00:00Z","inputTokens":9223372036854775807,"outputTokens":1,"requests":1}]}"#
        ] {
            #expect(throws: TypeSafeFailure.responseChanged) {
                try TypeSafeBillingAdapter.parseTokens(Data(body.utf8), now: Self.now)
            }
        }
    }

    @Test func requestShapeOriginRestrictionsAndCacheReuse() async {
        let transport = TypeSafeTestTransport { request, _ in Self.success(request) }
        let adapter = TypeSafeBillingAdapter(transport: transport)
        let first = await adapter.fetch(cookieHeader: "session=fixture", now: Self.now)
        let second = await adapter.fetch(cookieHeader: "session=fixture", now: Self.now.addingTimeInterval(120))
        #expect(first.confidence == .fresh)
        #expect(second.confidence == .fresh)
        let requests = await transport.requests
        #expect(requests.filter { $0.url?.path.hasSuffix(".js") == true }.count == 1)
        #expect(requests.allSatisfy { $0.url?.host == "console.typesafe.ai" })
        #expect(requests.filter { $0.url?.path.hasSuffix(".js") == true }
            .allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        let posts = requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        #expect(posts.allSatisfy { $0.httpBody == Data("[]".utf8) })
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Next-Action") == Self.newID })
        #expect(posts.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "https://console.typesafe.ai" })
        #expect(!TypeSafeBillingAdapter.permits(URL(string: "https://console.typesafe.ai.evil.test")))
        #expect(!TypeSafeBillingAdapter.permits(URL(string: "http://console.typesafe.ai")))
        #expect(!TypeSafeBillingAdapter.permits(URL(string: "https://console.typesafe.ai:8443")))
    }

    @Test func staleActionRediscoveredOnceAndTTLExpires() async {
        let transport = TypeSafeTestTransport { request, count in
            if request.url?.path.hasSuffix(".js") == true {
                return (200, Self.chunk(count == 1 ? Self.oldID : Self.newID), [:])
            }
            if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Next-Action") == Self.oldID {
                return (404, "stale", ["x-nextjs-action-not-found": "1"])
            }
            return Self.success(request)
        }
        let adapter = TypeSafeBillingAdapter(transport: transport)
        #expect(await adapter.fetch(cookieHeader: "session=fixture", now: Self.now).confidence == .fresh)
        #expect(await transport.requests.filter { $0.httpMethod == "POST" }.count == 2)
        _ = await adapter.fetch(cookieHeader: "session=fixture", now: Self.now.addingTimeInterval(13 * 3600))
        #expect(await transport.requests.filter { $0.url?.path.hasSuffix(".js") == true }.count == 3)
    }

    @Test func repeatedStaleIDDoesNotLoop() async {
        let transport = TypeSafeTestTransport { request, _ in
            request.httpMethod == "POST"
                ? (404, "stale", ["x-nextjs-action-not-found": "1"]) : Self.success(request)
        }
        let result = await TypeSafeBillingAdapter(transport: transport).fetch(cookieHeader: "a=x", now: Self.now)
        #expect(result.billing.failure == .unavailable)
        #expect(result.tokens.confidence == .fresh)
        #expect(await transport.requests.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test func independentQueriesRetainTheirOwnSuccessfulTimestamps() async {
        let transport = TypeSafeTestTransport { request, count in
            if request.url?.path == "/api/usage", count > 1 { return (503, "unavailable", [:]) }
            return Self.success(request)
        }
        let adapter = TypeSafeBillingAdapter(transport: transport)
        let first = await adapter.fetch(cookieHeader: "a=x", now: Self.now)
        let later = Self.now.addingTimeInterval(120)
        let second = await adapter.fetch(cookieHeader: "a=x", previous: first, now: later)
        #expect(second.billing.confidence == .fresh)
        #expect(second.billing.updatedAt == later)
        #expect(second.tokens.confidence == .stale)
        #expect(second.tokens.updatedAt == Self.now)
        #expect(second.tokens.value == first.tokens.value)
        #expect(second.tokens.failure == .unavailable)
    }

    @Test func unavailableBillingStillAllowsFreshTokens() async {
        let transport = TypeSafeTestTransport { request, _ in
            request.url?.path == "/settings/billing" ? (503, "down", [:]) : Self.success(request)
        }
        let result = await TypeSafeBillingAdapter(transport: transport).fetch(cookieHeader: "a=x", now: Self.now)
        #expect(result.billing.confidence == .unknown)
        #expect(result.billing.updatedAt == nil)
        #expect(result.tokens.confidence == .fresh)
    }

    @Test(arguments: [
        (401, "", TypeSafeFailure.authExpired),
        (403, "", .authExpired),
        (307, "", .authExpired),
        (429, "", .rateLimited),
        (503, "", .unavailable),
        (403, "<html>Just a moment challenge-platform</html>", .challenge),
        (200, "<html>Just a moment challenge-platform</html>", .challenge),
        (200, #"<script>self.push({\"children\":[\"(auth)\",{\"children\":[\"login\"]}]})</script>"#, .authExpired),
        (200, "<html>Welcome to TypeSafe Continue with Google</html>", .authExpired)
    ])
    func errorsStayClassified(status: Int, body: String, failure: TypeSafeFailure) async {
        let transport = TypeSafeTestTransport { _, _ in (status, body, [:]) }
        let result = await TypeSafeBillingAdapter(transport: transport).fetch(cookieHeader: "a=x")
        #expect(result.billing.failure == failure)
        #expect(result.tokens.failure == failure)
    }

    @Test func transportErrorsAreSanitizedAndFormatsRemainUnknown() async {
        let transport = ThrowingTypeSafeTransport()
        let result = await TypeSafeBillingAdapter(transport: transport).fetch(cookieHeader: "session=secret")
        #expect(result.failure == .network)
        #expect(result.billing.value == nil)
        #expect(result.tokens.value == nil)
        let json = String(decoding: try! JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("secret"))
        #expect(!json.contains("987.654"))
        let changed = TypeSafeTestTransport { _, _ in (200, "<html>changed format</html>", [:]) }
        let unknown = await TypeSafeBillingAdapter(transport: changed).fetch(cookieHeader: "a=x")
        #expect(unknown.billing.failure == .responseChanged)
        #expect(unknown.tokens.failure == .responseChanged)
    }

    @Test func invalidCookieNeverMakesNetworkRequest() async {
        let transport = TypeSafeTestTransport { request, _ in Self.success(request) }
        let result = await TypeSafeBillingAdapter(transport: transport).fetch(cookieHeader: "a=x\n")
        #expect(result.failure == .invalidCookie)
        #expect(await transport.requests.isEmpty)
    }

    static func chunk(_ id: String) -> String {
        "\"\(id)\",c.callServer,void 0,c.findSourceMapURL,\"getBillingOverviewResult\""
    }

    static func success(_ request: URLRequest) -> (Int, String, [String: String]) {
        if request.url?.path == "/api/usage" { return (200, usage, [:]) }
        if request.httpMethod == "POST" { return (200, billing, ["Content-Type": "text/x-component"]) }
        if request.url?.path.hasSuffix(".js") == true { return (200, chunk(newID), [:]) }
        return (200, html, [:])
    }
}

private actor TypeSafeTestTransport: APICostHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private var counts: [String: Int] = [:]
    private let handler: @Sendable (URLRequest, Int) -> (Int, String, [String: String])

    init(_ handler: @escaping @Sendable (URLRequest, Int) -> (Int, String, [String: String])) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        counts[key, default: 0] += 1
        let (status, body, headers) = handler(request, counts[key]!)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: nil, headerFields: headers)!)
    }
}

private struct ThrowingTypeSafeTransport: APICostHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw NSError(domain: "Cookie: session=secret; balance=987.654", code: -1)
    }
}
