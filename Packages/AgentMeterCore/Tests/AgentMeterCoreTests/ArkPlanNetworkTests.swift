import Foundation
import Testing
@testable import AgentMeterCore

@Suite(.serialized)
struct ArkPlanNetworkTests {
    private func session(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        ArkTestURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArkTestURLProtocol.self]
        return URLSession(configuration: config)
    }
    @Test func signedTransportParsesPersonalPlans() async throws {
        let credentials = try ArkPlanCredentials(accessKeyID: "network-fixture", secretAccessKey: "test-secret")
        let session = session { request in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Credential=network-fixture/") == true)
            #expect(request.value(forHTTPHeaderField: "X-Content-Sha256") != nil)
            let body = #"{"Result":{"QuotaUsage":[{"Level":"Session","Percent":42}]}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        defer { session.invalidateAndCancel() }
        let value = try await ArkPlanAdapter(product: .coding).fetch(credentials: credentials, session: session)
        #expect(value.confidence == .fresh && value.windows.first?.usedPercent == 42)
    }
    @Test func transportFailuresAreClassifiedAndBusinessThrottlingIsRetriedLater() async throws {
        for status in [401, 403, 429, 500, 200] {
            let credentials = try ArkPlanCredentials(accessKeyID: "fixture-\(status)-\(UUID())", secretAccessKey: "test-secret")
            let session = session { request in
                let body = status == 200 ? #"{"ResponseMetadata":{"Error":{"Code":"Throttling"}}}"# : "{}"
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await ArkPlanAdapter(product: .coding).fetch(credentials: credentials, session: session)
                Issue.record("failure should not produce quota")
            } catch let failure as ProviderRequestFailure {
                #expect([200, 429].contains(status))
                #expect(failure.isRateLimited && failure.retryAt != nil)
            } catch let error as ArkPlanAdapter.FetchError {
                #expect(error == (status == 401 ? .unauthorized : status == 403 ? .permissionDenied : .httpStatus(status)))
            }
        }
        let timedOut = session { _ in throw URLError(.timedOut) }
        defer { timedOut.invalidateAndCancel() }
        let credentials = try ArkPlanCredentials(accessKeyID: "timeout-fixture", secretAccessKey: "test-secret")
        await #expect(throws: ArkPlanAdapter.FetchError.transport) {
            try await ArkPlanAdapter(product: .agent).fetch(credentials: credentials, session: timedOut)
        }
    }
}
private final class ArkTestURLProtocol: URLProtocol, @unchecked Sendable {
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
