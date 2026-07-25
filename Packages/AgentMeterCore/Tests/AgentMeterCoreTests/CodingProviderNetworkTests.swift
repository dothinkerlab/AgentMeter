import Foundation
import Testing
@testable import AgentMeterCore

@Suite(.serialized)
struct CodingProviderNetworkTests {
    @Test func authorizationHeadersMatchEachProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = mockSession { request in
            let body: String
            switch request.url?.host {
            case "kimi.test":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-key")
                body = #"{"usage":{"used":1,"limit":10,"resetAt":"2030-07-24T00:00:00Z"}}"#
            case "glm.test":
                #expect(request.value(forHTTPHeaderField: "Authorization") == "glm-key")
                body = #"{"data":{"limits":[{"type":"TOKENS_LIMIT","name":"5 hour","percentage":10,"nextResetTime":"2030-07-24T00:00:00Z"}]}}"#
            default:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer minimax-key")
                body = #"{"model_remains":[{"model_name":"MiniMax-M2.7","current_interval_total_count":100,"current_interval_usage_count":10,"current_interval_end_time":1911081600}]}"#
            }
            return response(request, status: 200, data: Data(body.utf8))
        }
        _ = try await KimiCodeAdapter(usageURL: URL(string: "https://kimi.test/usages")!)
            .fetch(accessToken: "kimi-key", session: session, now: now)
        _ = try await GLMCodingPlanAdapter(region: .global, quotaURL: URL(string: "https://glm.test/limit")!)
            .fetch(apiKey: "glm-key", session: session, now: now)
        _ = try await MiniMaxTokenPlanAdapter(region: .global, remainsURL: URL(string: "https://minimax.test/remains")!)
            .fetch(apiKey: "minimax-key", session: session, now: now)
        session.invalidateAndCancel()
    }

    @Test func httpAndNetworkFailuresMapWithoutParsingFakeZeros() async {
        for status in [401, 403, 429, 500] {
            let session = mockSession { request in response(request, status: status, data: Data()) }
            do {
                _ = try await KimiCodeAdapter(usageURL: URL(string: "https://kimi.test/usages")!)
                    .fetch(accessToken: "key", session: session)
                Issue.record("HTTP \(status) should fail")
            } catch let error as KimiCodeAdapter.FetchError {
                if status == 401 || status == 403 { #expect(error == .unauthorized) }
                else { #expect(error == .httpStatus(status)) }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            session.invalidateAndCancel()
        }
        let session = mockSession { _ in throw URLError(.timedOut) }
        do {
            _ = try await MiniMaxTokenPlanAdapter(region: .global).fetch(apiKey: "key", session: session)
            Issue.record("timeout should fail")
        } catch let error as MiniMaxTokenPlanAdapter.FetchError {
            guard case .transport = error else { Issue.record("expected transport") ; return }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        session.invalidateAndCancel()
    }

    private func mockSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        CodingProviderURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodingProviderURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(_ request: URLRequest, status: Int, data: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
    }
}

private final class CodingProviderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.unknown)); return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
