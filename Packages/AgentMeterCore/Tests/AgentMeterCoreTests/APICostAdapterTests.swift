import Foundation
import Network
import Testing
@testable import AgentMeterCore

@Suite(.serialized)
struct APICostAdapterTests {
    private let now = Date(timeIntervalSince1970: 1_784_548_800) // 2026-07-20T12:00:00Z

    @Test func openAIParsesExactDecimalAndAggregatesCalendarPeriods() throws {
        let adapter = OpenAIAPICostAdapter()
        let page = try adapter.parsePage(data: try fixture("openai_costs_sample"))
        let usage = try adapter.aggregate(buckets: page.buckets, calendar: utcCalendar(), now: now)
        #expect(page.nextPage == nil)
        #expect(usage.usageDaily == Decimal(string: "1.30"))
        #expect(usage.usageWeekly == Decimal(string: "1.30"))
        #expect(usage.usageMonthly == Decimal(string: "13.4234"))
        #expect(usage.confidence == .fresh)
    }

    @Test func anthropicConvertsDecimalCentsWithoutLosingPrecision() throws {
        let adapter = AnthropicAPICostAdapter()
        let page = try adapter.parsePage(data: try fixture("anthropic_costs_sample"))
        let usage = try adapter.aggregate(buckets: page.buckets, calendar: utcCalendar(), now: now)
        #expect(usage.usageDaily == Decimal(string: "1.30"))
        #expect(usage.usageWeekly == Decimal(string: "1.30"))
        #expect(usage.usageMonthly == Decimal(string: "13.4234"))
    }

    @Test func dailyBucketsUseUTCDayEvenWhenDeviceCalendarIsAhead() throws {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        shanghai.firstWeekday = 2
        let localMidnight = try #require(
            ISO8601DateFormatter().date(from: "2026-07-19T16:30:00Z")
        )
        let utcBucketStart = try #require(
            ISO8601DateFormatter().date(from: "2026-07-19T00:00:00Z")
        )

        let openAI = try OpenAIAPICostAdapter().aggregate(
            buckets: [.init(startsAt: utcBucketStart, amountUSD: 1)],
            calendar: shanghai,
            now: localMidnight
        )
        let anthropic = try AnthropicAPICostAdapter().aggregate(
            buckets: [.init(startsAt: utcBucketStart, amountUSD: 1)],
            calendar: shanghai,
            now: localMidnight
        )

        #expect(openAI.usageDaily == 1)
        #expect(anthropic.usageDaily == 1)
    }

    @Test func adaptersRejectInvalidCurrencyNegativeCostAndBrokenPagination() {
        let openAIWrongCurrency = Data(#"{"data":[{"start_time":1784505600,"results":[{"amount":{"value":1,"currency":"eur"}}]}],"has_more":false,"next_page":null}"#.utf8)
        #expect(throws: OpenAIAPICostAdapter.FetchError.self) {
            try OpenAIAPICostAdapter().parsePage(data: openAIWrongCurrency)
        }
        let anthropicNegative = Data(#"{"data":[{"starting_at":"2026-07-20T00:00:00Z","results":[{"amount":"-1","currency":"USD"}]}],"has_more":false,"next_page":null}"#.utf8)
        #expect(throws: AnthropicAPICostAdapter.FetchError.self) {
            try AnthropicAPICostAdapter().parsePage(data: anthropicNegative)
        }
        let missingPage = Data(#"{"data":[],"has_more":true,"next_page":null}"#.utf8)
        #expect(throws: OpenAIAPICostAdapter.FetchError.self) {
            try OpenAIAPICostAdapter().parsePage(data: missingPage)
        }
    }

    @Test func authorizationHeadersQueriesAndHTTPFailuresAreMapped() async throws {
        let session = apiCostSession { request in
            if request.url?.host == "openai.test" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-admin")
                #expect(request.url?.query?.contains("bucket_width=1d") == true)
                return apiCostResponse(request, status: 200, data: try fixture("openai_costs_sample"))
            }
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-admin")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.url?.query?.contains("bucket_width=1d") == true)
            return apiCostResponse(request, status: 200, data: try fixture("anthropic_costs_sample"))
        }
        _ = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
            .fetch(
                adminKey: "openai-admin",
                transport: URLSessionAPICostHTTPTransport(session: session),
                calendar: utcCalendar(),
                now: now
            )
        _ = try await AnthropicAPICostAdapter(costURL: URL(string: "https://anthropic.test/costs")!)
            .fetch(
                adminKey: "anthropic-admin",
                transport: URLSessionAPICostHTTPTransport(session: session),
                calendar: utcCalendar(),
                now: now
            )
        session.invalidateAndCancel()

        for status in [401, 403, 429, 500] {
            let failureSession = apiCostSession { request in apiCostResponse(request, status: status, data: Data()) }
            do {
                _ = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
                    .fetch(
                        adminKey: "key",
                        transport: URLSessionAPICostHTTPTransport(session: failureSession),
                        calendar: utcCalendar(),
                        now: now
                    )
                Issue.record("HTTP \(status) should fail")
            } catch let error as OpenAIAPICostAdapter.FetchError {
                if status == 401 || status == 403 { #expect(error == .unauthorized) }
                else { #expect(error == .httpStatus(status)) }
            }
            failureSession.invalidateAndCancel()
        }
    }

    @Test func fetchFollowsOpaquePaginationTokens() async throws {
        let finalPage = try fixture("openai_costs_sample")
        let session = apiCostSession { request in
            if request.url?.query?.contains("page=opaque-next") == true {
                return apiCostResponse(request, status: 200, data: finalPage)
            }
            let first = Data(#"{"data":[],"has_more":true,"next_page":"opaque-next"}"#.utf8)
            return apiCostResponse(request, status: 200, data: first)
        }
        let usage = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
            .fetch(
                adminKey: "admin",
                transport: URLSessionAPICostHTTPTransport(session: session),
                calendar: utcCalendar(),
                now: now
            )
        #expect(usage.usageMonthly == Decimal(string: "13.4234"))
        session.invalidateAndCancel()
    }

    @Test func paginationDeduplicatesIdenticalBuckets() async throws {
        let start = Int(now.timeIntervalSince1970) - 12 * 3_600
        let openAIFirst = Data(#"{"data":[{"start_time":\#(start),"results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":true,"next_page":"next"}"#.utf8)
        let openAISecond = Data(#"{"data":[{"start_time":\#(start),"results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#.utf8)
        let anthropicStart = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(start)))
        let anthropicFirst = Data(#"{"data":[{"starting_at":"\#(anthropicStart)","results":[{"amount":"100","currency":"USD"}]}],"has_more":true,"next_page":"next"}"#.utf8)
        let anthropicSecond = Data(#"{"data":[{"starting_at":"\#(anthropicStart)","results":[{"amount":"100","currency":"USD"}]}],"has_more":false,"next_page":null}"#.utf8)
        let session = apiCostSession { request in
            let isNext = request.url?.query?.contains("page=next") == true
            let isOpenAI = request.url?.host == "openai.test"
            let data = isOpenAI
                ? (isNext ? openAISecond : openAIFirst)
                : (isNext ? anthropicSecond : anthropicFirst)
            return apiCostResponse(request, status: 200, data: data)
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        let openAI = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
            .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
        let anthropic = try await AnthropicAPICostAdapter(costURL: URL(string: "https://anthropic.test/costs")!)
            .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)

        #expect(openAI.usageDaily == 1)
        #expect(anthropic.usageDaily == 1)
        session.invalidateAndCancel()
    }

    @Test func adaptersRejectConflictingOrOutOfRangeBuckets() async throws {
        let validStart = Int(now.timeIntervalSince1970) - 12 * 3_600
        let futureStart = Int(now.timeIntervalSince1970) + 86_400
        let session = apiCostSession { request in
            let isOpenAI = request.url?.host == "openai.test"
            let isNext = request.url?.query?.contains("page=next") == true
            if isOpenAI {
                let amount = isNext ? 2 : 1
                let start = request.url?.path.contains("future") == true ? futureStart : validStart
                let data = Data(#"{"data":[{"start_time":\#(start),"results":[{"amount":{"value":\#(amount),"currency":"usd"}}]}],"has_more":\#(!isNext),"next_page":\#(isNext ? "null" : "\"next\"")}"#.utf8)
                return apiCostResponse(request, status: 200, data: data)
            }
            let start = request.url?.path.contains("future") == true
                ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(futureStart)))
                : ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(validStart)))
            let amount = isNext ? "200" : "100"
            let data = Data(#"{"data":[{"starting_at":"\#(start)","results":[{"amount":"\#(amount)","currency":"USD"}]}],"has_more":\#(!isNext),"next_page":\#(isNext ? "null" : "\"next\"")}"#.utf8)
            return apiCostResponse(request, status: 200, data: data)
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        await expectOpenAIDecodeFailure(
            URL(string: "https://openai.test/conflict")!,
            transport: transport,
            contains: "conflicting duplicate"
        )
        await expectAnthropicDecodeFailure(
            URL(string: "https://anthropic.test/conflict")!,
            transport: transport,
            contains: "conflicting duplicate"
        )
        await expectOpenAIDecodeFailure(
            URL(string: "https://openai.test/future")!,
            transport: transport,
            contains: "outside requested interval"
        )
        await expectAnthropicDecodeFailure(
            URL(string: "https://anthropic.test/future")!,
            transport: transport,
            contains: "outside requested interval"
        )
        session.invalidateAndCancel()
    }

    @Test func adaptersRejectDailyBucketsNotAlignedToUTCMidnight() async {
        let unalignedStart = Int(now.timeIntervalSince1970) - 12 * 3_600 + 1
        let anthropicStart = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: TimeInterval(unalignedStart))
        )
        let session = apiCostSession { request in
            let data: Data
            if request.url?.host == "openai.test" {
                data = Data(#"{"data":[{"start_time":\#(unalignedStart),"results":[{"amount":{"value":1,"currency":"usd"}}]}],"has_more":false,"next_page":null}"#.utf8)
            } else {
                data = Data(#"{"data":[{"starting_at":"\#(anthropicStart)","results":[{"amount":"100","currency":"USD"}]}],"has_more":false,"next_page":null}"#.utf8)
            }
            return apiCostResponse(request, status: 200, data: data)
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        await expectOpenAIDecodeFailure(
            URL(string: "https://openai.test/unaligned")!,
            transport: transport,
            contains: "not aligned to UTC midnight"
        )
        await expectAnthropicDecodeFailure(
            URL(string: "https://anthropic.test/unaligned")!,
            transport: transport,
            contains: "not aligned to UTC midnight"
        )
        session.invalidateAndCancel()
    }

    @Test func fetchIncludesPreviousMonthDaysWhenCalendarWeekCrossesMonth() async throws {
        let calendar = utcCalendar()
        let crossMonthNow = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)
        ))
        let expectedStart = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 29)
        ))
        let emptyPage = Data(#"{"data":[],"has_more":false,"next_page":null}"#.utf8)
        let session = apiCostSession { request in
            let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            if request.url?.host == "openai.test" {
                #expect(query["start_time"] == String(Int(expectedStart.timeIntervalSince1970)))
            } else {
                let value = try #require(query["starting_at"])
                #expect(ISO8601DateFormatter().date(from: value) == expectedStart)
            }
            return apiCostResponse(request, status: 200, data: emptyPage)
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        _ = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
            .fetch(adminKey: "admin", transport: transport, calendar: calendar, now: crossMonthNow)
        _ = try await AnthropicAPICostAdapter(costURL: URL(string: "https://anthropic.test/costs")!)
            .fetch(adminKey: "admin", transport: transport, calendar: calendar, now: crossMonthNow)
        session.invalidateAndCancel()
    }

    @Test func adaptersRejectUnboundedUniquePagination() async {
        let session = apiCostSession { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let current = components?.queryItems?.first(where: { $0.name == "page" })?.value
                .flatMap { Int($0.dropFirst()) } ?? 0
            let next = "p\(current + 1)"
            let data = Data(#"{"data":[],"has_more":true,"next_page":"\#(next)"}"#.utf8)
            return apiCostResponse(request, status: 200, data: data)
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        do {
            _ = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("OpenAI pagination should be bounded")
        } catch let error as OpenAIAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected OpenAI error: \(error)")
                session.invalidateAndCancel()
                return
            }
            #expect(message.contains("maximum page count"))
        } catch {
            Issue.record("Unexpected OpenAI error: \(error)")
        }

        do {
            _ = try await AnthropicAPICostAdapter(costURL: URL(string: "https://anthropic.test/costs")!)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("Anthropic pagination should be bounded")
        } catch let error as AnthropicAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected Anthropic error: \(error)")
                session.invalidateAndCancel()
                return
            }
            #expect(message.contains("maximum page count"))
        } catch {
            Issue.record("Unexpected Anthropic error: \(error)")
        }
        session.invalidateAndCancel()
    }

    @Test func adaptersRejectOversizedBucketResponses() async throws {
        let openAIBuckets: [[String: Any]] = (0...OpenAIAPICostAdapter.maximumBucketCount).map { offset in
            [
                "start_time": Int(now.timeIntervalSince1970) - offset * 86_400,
                "results": [["amount": ["value": 1, "currency": "usd"]]]
            ]
        }
        let anthropicBuckets: [[String: Any]] = (0...AnthropicAPICostAdapter.maximumBucketCount).map { offset in
            [
                "starting_at": ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(TimeInterval(-offset * 86_400))
                ),
                "results": [["amount": "1", "currency": "USD"]]
            ]
        }
        let openAIData = try JSONSerialization.data(withJSONObject: [
            "data": openAIBuckets, "has_more": false, "next_page": NSNull()
        ])
        let anthropicData = try JSONSerialization.data(withJSONObject: [
            "data": anthropicBuckets, "has_more": false, "next_page": NSNull()
        ])
        let session = apiCostSession { request in
            apiCostResponse(
                request,
                status: 200,
                data: request.url?.host == "openai.test" ? openAIData : anthropicData
            )
        }
        let transport = URLSessionAPICostHTTPTransport(session: session)

        do {
            _ = try await OpenAIAPICostAdapter(costsURL: URL(string: "https://openai.test/costs")!)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("OpenAI bucket count should be bounded")
        } catch let error as OpenAIAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected OpenAI error: \(error)")
                session.invalidateAndCancel()
                return
            }
            #expect(message.contains("maximum bucket count"))
        } catch {
            Issue.record("Unexpected OpenAI error: \(error)")
        }

        do {
            _ = try await AnthropicAPICostAdapter(costURL: URL(string: "https://anthropic.test/costs")!)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("Anthropic bucket count should be bounded")
        } catch let error as AnthropicAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected Anthropic error: \(error)")
                session.invalidateAndCancel()
                return
            }
            #expect(message.contains("maximum bucket count"))
        } catch {
            Issue.record("Unexpected Anthropic error: \(error)")
        }
        session.invalidateAndCancel()
    }

    @Test func requestOriginRejectsCrossHostSchemeAndPortRedirects() throws {
        let origin = try #require(APICostRequestOrigin(
            url: URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        ))
        #expect(origin.permits(URL(string: "https://api.anthropic.com/next")))
        #expect(origin.permits(URL(string: "https://api.anthropic.com:443/next")))
        #expect(!origin.permits(URL(string: "https://attacker.example/next")))
        #expect(!origin.permits(URL(string: "http://api.anthropic.com/next")))
        #expect(!origin.permits(URL(string: "https://api.anthropic.com:8443/next")))
    }

    @Test func productionTransportDoesNotFollowCrossOriginRedirect() async throws {
        let attacker = LocalHTTPServer { _ in
            LocalHTTPServer.ok(body: "should not be reached")
        }
        let attackerPort = try await attacker.start()
        let origin = LocalHTTPServer { _ in
            LocalHTTPServer.redirect(to: "http://localhost:\(attackerPort)/steal")
        }
        let originPort = try await origin.start()
        defer {
            origin.stop()
            attacker.stop()
        }
        let originURL = URL(string: "http://127.0.0.1:\(originPort)/costs")!
        let transport = SameOriginAPICostHTTPTransport(originURL: originURL)
        var request = URLRequest(url: originURL)
        request.setValue("secret-admin-key", forHTTPHeaderField: "x-api-key")

        let (_, response) = try await transport.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(origin.requestCount == 1)
        #expect(attacker.requestCount == 0)
        #expect(attacker.receivedRequests.allSatisfy { !$0.contains("secret-admin-key") })
    }

    @Test func degradationPreservesFactsAndUnknownNeverClaimsFreshZero() {
        let known = APICostUsage(
            usageDaily: 1, usageWeekly: 2, usageMonthly: 3,
            confidence: .fresh, source: OpenAIAPICostAdapter.source, updatedAt: now
        )
        let stale = APICostUsage.degraded(
            from: known, source: OpenAIAPICostAdapter.source, reason: .networkFailure
        )
        #expect(stale.usageMonthly == 3)
        #expect(stale.confidence == .stale)
        #expect(stale.updatedAt == now)

        let unknown = APICostUsage.degraded(
            from: nil, source: AnthropicAPICostAdapter.source, reason: .authExpired, now: now
        )
        #expect(unknown.confidence == .unknown)
        #expect(!unknown.hasKnownUsage)
        #expect(unknown.usageMonthly == 0)
        #expect(OpenAIAPICostAdapter.staleReason(for: OpenAIAPICostAdapter.FetchError.unauthorized) == .authExpired)
        #expect(AnthropicAPICostAdapter.staleReason(for: AnthropicAPICostAdapter.FetchError.transport("offline")) == .networkFailure)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func expectOpenAIDecodeFailure(
        _ url: URL,
        transport: any APICostHTTPTransport,
        contains expected: String
    ) async {
        do {
            _ = try await OpenAIAPICostAdapter(costsURL: url)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("OpenAI response should have failed validation")
        } catch let error as OpenAIAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected OpenAI error: \(error)")
                return
            }
            #expect(message.contains(expected))
        } catch {
            Issue.record("Unexpected OpenAI error: \(error)")
        }
    }

    private func expectAnthropicDecodeFailure(
        _ url: URL,
        transport: any APICostHTTPTransport,
        contains expected: String
    ) async {
        do {
            _ = try await AnthropicAPICostAdapter(costURL: url)
                .fetch(adminKey: "admin", transport: transport, calendar: utcCalendar(), now: now)
            Issue.record("Anthropic response should have failed validation")
        } catch let error as AnthropicAPICostAdapter.FetchError {
            guard case .decode(let message) = error else {
                Issue.record("Unexpected Anthropic error: \(error)")
                return
            }
            #expect(message.contains(expected))
        } catch {
            Issue.record("Unexpected Anthropic error: \(error)")
        }
    }
}

private func apiCostSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    APICostURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [APICostURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func apiCostResponse(_ request: URLRequest, status: Int, data: Data) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
}

private final class APICostURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class LocalHTTPServer: @unchecked Sendable {
    typealias ResponseProvider = @Sendable (String) -> String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "AgentMeter.APICostRedirectTestServer")
    private let responseProvider: ResponseProvider
    private let lock = NSLock()
    private var requests: [String] = []

    init(responseProvider: @escaping ResponseProvider) {
        self.listener = try! NWListener(using: .tcp, on: .any)
        self.responseProvider = responseProvider
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    var receivedRequests: [String] {
        lock.withLock { requests }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ServerStartContinuation(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { gate.succeed(port.rawValue) }
                case .failed(let error):
                    gate.fail(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            self.lock.withLock { self.requests.append(request) }
            let response = self.responseProvider(request)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    static func ok(body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    static func redirect(to url: String) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(url)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }
}

private final class ServerStartContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, any Error>?

    init(_ continuation: CheckedContinuation<UInt16, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ port: UInt16) {
        take()?.resume(returning: port)
    }

    func fail(_ error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<UInt16, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
