import Foundation
import Testing
@testable import AgentMeterCore

private final class PolicyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor PolicyNetwork {
    var calls = 0
    var status = 429
    var header: String?
    func configure(_ status: Int, header: String? = nil) { self.status = status; self.header = header }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        try await Task.sleep(for: .milliseconds(20))
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: header.map { ["Retry-After": $0] })!)
    }
}

struct SubscriptionRequestPolicyTests {
    @Test func overlappingRequestsJoinAndSuccessfulCadenceIsUnchanged() async throws {
        let suite = "SubscriptionPolicy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = SubscriptionRequestCoordinator(defaults: UserDefaults(suiteName: suite)!)
        let network = PolicyNetwork()
        await network.configure(200)
        let request = URLRequest(url: URL(string: "https://fixture.test/quota")!)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await coordinator.data(for: request, service: "kimiCode", send: { try await network.send($0) }) }
            }
            try await group.waitForAll()
        }
        #expect(await network.calls == 1)
        _ = try await coordinator.data(for: request, service: "kimiCode", send: { try await network.send($0) })
        #expect(await network.calls == 2) // No five-minute billing interval imposed on quota.
    }

    @Test func signedRequestsKeepCooldownAcrossTimestampChanges() async throws {
        let suite = "ArkPolicy.\(UUID())", clock = PolicyClock(), network = PolicyNetwork()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = SubscriptionRequestCoordinator(defaults: UserDefaults(suiteName: suite)!, now: { clock.now() })
        let adapter = ArkPlanAdapter(product: .coding)
        let credentials = try ArkPlanCredentials(accessKeyID: "test-ak", secretAccessKey: "test-secret")
        let identity = credentials.accessKeyID + "\n" + credentials.secretAccessKey
        await #expect(throws: ProviderRequestFailure.self) {
            try await coordinator.data(for: adapter.request(credentials: credentials, now: clock.now()),
                service: adapter.product.source, credentialIdentity: identity, send: { try await network.send($0) })
        }
        clock.advance(10)
        await #expect(throws: ProviderRequestFailure.self) {
            try await coordinator.data(for: adapter.request(credentials: credentials, now: clock.now()),
                service: adapter.product.source, credentialIdentity: identity, send: { try await network.send($0) })
        }
        #expect(await network.calls == 1)
        let persisted = try #require(defaults.data(forKey: "subscriptionRequest.v1.ark_coding_plan_api"))
        #expect(!String(decoding: persisted, as: UTF8.self).contains("test-secret"))
        await network.configure(200)
        _ = try await coordinator.data(for: adapter.request(credentials: credentials, now: clock.now()),
            service: adapter.product.source, credentialIdentity: "different-key", send: { try await network.send($0) })
        #expect(await network.calls == 2)
    }

    @Test func persistedCooldownBackoffAndRecovery() async throws {
        let suite = "SubscriptionPolicy.\(UUID())"
        defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
        let clock = PolicyClock(), network = PolicyNetwork()
        var coordinator = SubscriptionRequestCoordinator(defaults: UserDefaults(suiteName: suite)!, now: { clock.now() })
        let request = URLRequest(url: URL(string: "https://fixture.test/quota")!)
        for delay in [60.0, 120, 240, 480, 900, 900] {
            do {
                _ = try await coordinator.data(for: request, service: "codex", send: { try await network.send($0) })
                Issue.record("expected rate limit")
            } catch let error as ProviderRequestFailure {
                #expect(error.retryAt == clock.now() + delay)
            }
            let calls = await network.calls
            coordinator = SubscriptionRequestCoordinator(defaults: UserDefaults(suiteName: suite)!, now: { clock.now() })
            clock.advance(delay - 1)
            await #expect(throws: ProviderRequestFailure.self) {
                try await coordinator.data(for: request, service: "codex", send: { try await network.send($0) })
            }
            #expect(await network.calls == calls)
            clock.advance(1)
        }
        await network.configure(200)
        _ = try await coordinator.data(for: request, service: "codex", send: { try await network.send($0) })
        await network.configure(429)
        do {
            _ = try await coordinator.data(for: request, service: "codex", send: { try await network.send($0) })
            Issue.record("expected rate limit")
        } catch let error as ProviderRequestFailure { #expect(error.retryAt == clock.now() + 60) }
    }

    @Test func serverWaitAndCredentialIsolation() async throws {
        let suite = "SubscriptionPolicy.\(UUID())", clock = PolicyClock(), network = PolicyNetwork()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = SubscriptionRequestCoordinator(defaults: UserDefaults(suiteName: suite)!, now: { clock.now() })
        var request = URLRequest(url: URL(string: "https://fixture.test/quota")!)
        request.setValue("Bearer old-secret", forHTTPHeaderField: "Authorization")
        await network.configure(503, header: "3600")
        do {
            _ = try await coordinator.data(for: request, service: "claudeCode", send: { try await network.send($0) })
            Issue.record("expected wait")
        } catch let error as ProviderRequestFailure {
            #expect(!error.isRateLimited && error.retryAt == clock.now() + 3600)
        }
        let stored = try #require(defaults.data(forKey: "subscriptionRequest.v1.claudeCode"))
        #expect(!String(decoding: stored, as: UTF8.self).contains("old-secret"))
        request.setValue("Bearer new-secret", forHTTPHeaderField: "Authorization")
        await network.configure(200)
        _ = try await coordinator.data(for: request, service: "claudeCode", send: { try await network.send($0) })
        #expect(await network.calls == 2)
    }

    @Test func businessErrorsAreNotResponseChangesOrFalseRateLimits() throws {
        let miniMax = Data(#"{"base_resp":{"status_code":1002,"status_msg":"limit"}}"#.utf8)
        #expect(throws: ProviderRequestFailure(isRateLimited: true, httpStatus: 200)) {
            try MiniMaxTokenPlanAdapter(region: .global).parse(data: miniMax)
        }
        for code in ["1302", "1305", "1113", "1308", "1309", "1310"] {
            let data = Data("{\"error\":{\"code\":\"\(code)\"}}".utf8)
            do {
                try ProviderRequestFailure.check(HTTPURLResponse(url: URL(string: "https://fixture.test")!, statusCode: 429,
                    httpVersion: nil, headerFields: ["Retry-After": "600"])!, data: data, service: "glmCoding", now: Date(timeIntervalSince1970: 0))
                Issue.record("expected business error")
            } catch let error as ProviderRequestFailure {
                let limited = ["1302", "1305"].contains(code)
                #expect(error.isRateLimited == limited)
                #expect(error.retryAt == (limited ? Date(timeIntervalSince1970: 600) : nil))
                #expect(DeviceCodingQuotaCollector.staleReason(for: error) == .endpointFailure)
            }
        }
        let exhausted = Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)
        #expect(throws: ProviderRequestFailure(isRateLimited: false, httpStatus: 429)) {
            try ProviderRequestFailure.check(HTTPURLResponse(url: URL(string: "https://fixture.test")!, statusCode: 429,
                httpVersion: nil, headerFields: nil)!, data: exhausted, service: "openAIAPI")
        }
    }
}

