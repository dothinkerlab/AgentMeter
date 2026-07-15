import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentMeterCore

@Suite(.serialized)
struct CodexResetCreditsAdapterTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    @Test func parsesAvailableCountAndOnlyAvailableCredits() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let parsed = try CodexResetCreditsAdapter().parse(
            data: try fixture("codex_reset_credits_sample"),
            now: now
        )

        #expect(parsed.availableCount == 2)
        #expect(parsed.credits.count == 2)
        #expect(parsed.confidence == .fresh)
        #expect(parsed.updatedAt == now)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-07-26T23:37:59Z"))
        let actual = try #require(parsed.nearestExpiration)
        #expect(abs(actual.timeIntervalSince(expected) - 0.168175) < 0.001)
    }

    @Test func supportsEpochAndNullExpiration() throws {
        let data = Data(#"""
        {
          "available_count": 2,
          "credits": [
            { "status": "available", "granted_at": 1780000000, "expires_at": 1782592000000 },
            { "status": "available", "granted_at": 1781000000, "expires_at": null }
          ]
        }
        """#.utf8)

        let parsed = try CodexResetCreditsAdapter().parse(data: data)
        #expect(parsed.credits.count == 2)
        #expect(parsed.credits[0].expiresAt == Date(timeIntervalSince1970: 1_782_592_000))
        #expect(parsed.hasIncompleteExpirationDetails)
    }

    @Test func zeroCountIsARealFreshValue() throws {
        let parsed = try CodexResetCreditsAdapter().parse(
            data: Data(#"{ "available_count": 0, "credits": [] }"#.utf8)
        )
        #expect(parsed.availableCount == 0)
        #expect(parsed.confidence == .fresh)
    }

    @Test func malformedAndNegativeResponsesFailDecode() {
        #expect(throws: CodexResetCreditsAdapter.FetchError.self) {
            try CodexResetCreditsAdapter().parse(data: Data("{}".utf8))
        }
        #expect(throws: CodexResetCreditsAdapter.FetchError.self) {
            try CodexResetCreditsAdapter().parse(
                data: Data(#"{ "available_count": -1, "credits": [] }"#.utf8)
            )
        }
    }

    @Test func unknownNeverFabricatesZeroAndStaleKeepsKnownData() {
        let unknown = RateLimitResetCredits.unknown(reason: .networkFailure)
        #expect(unknown.availableCount == nil)
        #expect(unknown.confidence == .unknown)

        let fresh = RateLimitResetCredits(
            availableCount: 2,
            credits: [],
            confidence: .fresh,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let stale = fresh.markedStale(reason: .endpointFailure)
        #expect(stale.availableCount == 2)
        #expect(stale.updatedAt == fresh.updatedAt)
        #expect(stale.staleReason == .endpointFailure)
    }

    @Test func fetchMaps401And5xxWithoutParsingBody() async {
        for (status, expected) in [
            (401, CodexResetCreditsAdapter.FetchError.unauthorized),
            (503, CodexResetCreditsAdapter.FetchError.httpStatus(503))
        ] {
            let session = mockSession { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account")
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                ))
                return (response, Data("not json".utf8))
            }
            do {
                _ = try await CodexResetCreditsAdapter().fetch(
                    accessToken: "token", accountID: "account", session: session
                )
                Issue.record("状态码 \(status) 应失败")
            } catch let error as CodexResetCreditsAdapter.FetchError {
                #expect(error == expected)
            } catch {
                Issue.record("错误类型不正确: \(error)")
            }
            session.invalidateAndCancel()
        }
    }

    @Test func fetchMapsNetworkFailureToTransport() async {
        let session = mockSession { _ in throw URLError(.timedOut) }
        do {
            _ = try await CodexResetCreditsAdapter().fetch(accessToken: "token", session: session)
            Issue.record("网络错误应失败")
        } catch let error as CodexResetCreditsAdapter.FetchError {
            guard case .transport = error else {
                Issue.record("应映射为 transport，实际为 \(error)")
                session.invalidateAndCancel()
                return
            }
        } catch {
            Issue.record("错误类型不正确: \(error)")
        }
        session.invalidateAndCancel()
    }

    private func mockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        ResetCreditsURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetCreditsURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class ResetCreditsURLProtocol: URLProtocol, @unchecked Sendable {
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
