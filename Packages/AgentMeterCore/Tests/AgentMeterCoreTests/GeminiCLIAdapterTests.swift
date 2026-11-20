import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentMeterCore

struct GeminiCLIAdapterTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesQuotaFixtureGroupingAndTightestPerTier() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = try GeminiCLIAdapter().parseQuota(
            data: try fixture("gemini_cli_quota_sample"),
            plan: "Workspace",
            now: now
        )

        #expect(snapshot.tool == .geminiCLI)
        #expect(snapshot.plan == "Workspace")
        #expect(snapshot.confidence == .fresh)
        #expect(snapshot.source == GeminiCLIAdapter.source)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.windows.count == 3)

        // gemini-2.5-pro has 0.65 (35% used) and 0.80 -> keeps 0.65 (tighter than gemini-3.1-pro-preview's 0.90)
        let pro = try #require(snapshot.window(.geminiPro))
        #expect(abs(pro.usedPercent - 35.0) < 0.001)
        #expect(pro.resetsAt != nil)

        // gemini-2.5-flash 0.45 -> 55% used (fractional ISO8601 seconds parsed)
        let flash = try #require(snapshot.window(.geminiFlash))
        #expect(abs(flash.usedPercent - 55.0) < 0.001)
        #expect(flash.resetsAt != nil)

        // gemini-2.5-flash-lite 0.95 -> 5% used
        let lite = try #require(snapshot.window(.geminiFlashLite))
        #expect(abs(lite.usedPercent - 5.0) < 0.001)

        // tightestWindow picks Flash (55% used)
        #expect(snapshot.tightestWindow?.kind == .geminiFlash)
    }

    @Test func unknownModelsFallBackToDailyAndInvalidPayloadsFailDecode() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let unknownOnly = Data(#"""
        {
          "buckets": [
            {"modelId": "custom-model-a", "remainingFraction": 0.4},
            {"modelId": "custom-model-b", "remainingFraction": 0.7}
          ]
        }
        """#.utf8)
        let snapshot = try GeminiCLIAdapter().parseQuota(data: unknownOnly, now: now)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows.first?.kind == .daily)
        #expect(abs((snapshot.windows.first?.usedPercent ?? 0) - 60.0) < 0.001)

        for badBody in ["{}", #"{"buckets":[]}"#, #"{"buckets":[{"modelId":"gemini-pro"}]}"#, "not-json"] {
            #expect(throws: GeminiCLIAdapter.FetchError.self) {
                try GeminiCLIAdapter().parseQuota(data: Data(badBody.utf8), now: now)
            }
        }
    }

    @Test func parsesLoadCodeAssistTiersProjectsAndDeprecationSignals() throws {
        let stringProject = Data(#"""
        {
          "cloudaicompanionProject": "managed-project-123",
          "currentTier": {"id": "free-tier"}
        }
        """#.utf8)
        let s1 = try GeminiCLIAdapter.parseCodeAssistStatus(data: stringProject, hostedDomain: "corp.example.com")
        #expect(s1.projectID == "managed-project-123")
        #expect(s1.tierID == "free-tier")
        #expect(GeminiCLIAdapter.resolvePlan(status: s1, hostedDomain: "corp.example.com") == "Workspace")
        #expect(GeminiCLIAdapter.resolvePlan(status: s1, hostedDomain: nil) == "Free")

        let dictProjectWithPaidTier = Data(#"""
        {
          "cloudaicompanionProject": {"projectId": "dict-proj-456"},
          "currentTier": {"id": "standard-tier"},
          "paidTier": {"name": "Google AI Pro"},
          "ineligibleTiers": [{"reasonCode": "UNSUPPORTED_CLIENT"}]
        }
        """#.utf8)
        let s2 = try GeminiCLIAdapter.parseCodeAssistStatus(data: dictProjectWithPaidTier, hostedDomain: nil)
        #expect(s2.projectID == "dict-proj-456")
        #expect(!s2.isConsumerClientUnsupported)
        #expect(GeminiCLIAdapter.resolvePlan(status: s2, hostedDomain: nil) == "Google AI Pro")

        let standardFallback = GeminiCLIAdapter.CodeAssistStatus(
            tierID: "standard-tier", projectID: nil, paidTierName: nil, isConsumerClientUnsupported: false
        )
        #expect(GeminiCLIAdapter.resolvePlan(status: standardFallback, hostedDomain: nil) == "Paid")

        let legacyFallback = GeminiCLIAdapter.CodeAssistStatus(
            tierID: "legacy-tier", projectID: nil, paidTierName: nil, isConsumerClientUnsupported: false
        )
        #expect(GeminiCLIAdapter.resolvePlan(status: legacyFallback, hostedDomain: nil) == "Legacy")

        // June 2026 consumer shutdown: no currentTier + UNSUPPORTED_CLIENT
        let consumerShutdown = Data(#"""
        {
          "ineligibleTiers": [
            {"tierId": "free-tier", "reasonCode": "UNSUPPORTED_CLIENT", "reasonMessage": "Please migrate to Antigravity"}
          ]
        }
        """#.utf8)
        #expect(throws: GeminiCLIAdapter.FetchError.consumerTierDeprecated) {
            try GeminiCLIAdapter.parseCodeAssistStatus(data: consumerShutdown, hostedDomain: nil)
        }

        // Workspace accounts (hd claim) suppress consumer shutdown flag even when ineligibleTiers contains UNSUPPORTED_CLIENT
        let workspaceAllowed = Data(#"""
        {
          "currentTier": {"id": "free-tier"},
          "ineligibleTiers": [{"reasonCode": "UNSUPPORTED_CLIENT"}]
        }
        """#.utf8)
        let s3 = try GeminiCLIAdapter.parseCodeAssistStatus(data: workspaceAllowed, hostedDomain: "school.edu")
        #expect(!s3.isConsumerClientUnsupported)
        #expect(GeminiCLIAdapter.resolvePlan(status: s3, hostedDomain: "school.edu") == "Workspace")
    }

    @Test func extractsHostedDomainFromIDTokenJWT() {
        let header = Data(#"{"alg":"RS256"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"email":"user@example.edu","hd":"example.edu"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "\(header).\(payload).sig"
        #expect(GeminiCLIAdapter.extractHostedDomain(fromIDToken: jwt) == "example.edu")
        #expect(GeminiCLIAdapter.extractHostedDomain(fromIDToken: "invalid") == nil)
    }

    @Test func fetchDiscoversProjectFallbackAndRefreshesInMemoryOnly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let credsFile = tempDir.appendingPathComponent("oauth_creds.json")
        let originalCredsData = Data(#"{"access_token":"old-atk","refresh_token":"rtk-1","expiry_date":1000}"#.utf8)
        try originalCredsData.write(to: credsFile)

        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let tokenCache = GeminiTokenMemoryCache()
        let quotaPayload = try fixture("gemini_cli_quota_sample")

        let transport = MockGeminiTransport(responses: [
            // 1. OAuth refresh
            .init(status: 200, data: Data(#"{"access_token":"fresh-atk","expires_in":3600}"#.utf8)),
            // 2. loadCodeAssist without projectID
            .init(status: 200, data: Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)),
            // 3. projects fallback
            .init(status: 200, data: Data(#"{"projects":[{"projectId":"other-proj"},{"projectId":"gen-lang-client-999"}]}"#.utf8)),
            // 4. retrieveUserQuota
            .init(status: 200, data: quotaPayload),
            // Second fetch (cache hit skips OAuth refresh!):
            // 5. loadCodeAssist
            .init(status: 200, data: Data(#"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"p-direct"}"#.utf8)),
            // 6. retrieveUserQuota
            .init(status: 200, data: quotaPayload),
        ])

        let adapter = GeminiCLIAdapter()
        let clientCreds = GeminiCLIAdapter.OAuthClientCredentials(clientID: "cid", clientSecret: "csec")

        let first = try await adapter.fetch(
            accessToken: "old-atk",
            refreshToken: "rtk-1",
            expiresAt: now.addingTimeInterval(-30),
            transport: transport,
            oauthClientResolver: { clientCreds },
            tokenCache: tokenCache,
            now: now
        )
        #expect(first.plan == "Paid")
        #expect(first.windows.count == 3)

        // Verify disk credentials were never modified
        #expect(try Data(contentsOf: credsFile) == originalCredsData)

        // Second fetch within 60s reuses in-memory refreshed token without hitting token endpoint again
        let second = try await adapter.fetch(
            accessToken: "old-atk",
            refreshToken: "rtk-1",
            expiresAt: now.addingTimeInterval(-30),
            transport: transport,
            oauthClientResolver: { Issue.record("Should use cached token"); return nil },
            tokenCache: tokenCache,
            now: now.addingTimeInterval(30)
        )
        #expect(second.plan == "Paid")

        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests[0].url?.absoluteString == GeminiCLIAdapter.defaultTokenRefreshURL.absoluteString)
        #expect(requests[2].url?.absoluteString == GeminiCLIAdapter.defaultProjectsURL.absoluteString)
        #expect(requests[3].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-atk")
        let body3 = try #require(requests[3].httpBody)
        let json3 = try #require(try JSONSerialization.jsonObject(with: body3) as? [String: Any])
        #expect(json3["project"] as? String == "gen-lang-client-999")
    }

    @Test func fetchMapsHTTPTransportAndDeprecationFailures() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let adapter = GeminiCLIAdapter()

        let unauthorizedTransport = MockGeminiTransport(responses: [
            .init(status: 200, data: Data(#"{"currentTier":{"id":"free-tier"}}"#.utf8)),
            .init(status: 200, data: Data(#"{"projects":[]}"#.utf8)),
            .init(status: 401, data: Data()),
        ])
        await #expect(throws: GeminiCLIAdapter.FetchError.unauthorized) {
            try await adapter.fetch(accessToken: "atk", expiresAt: now.addingTimeInterval(3600), transport: unauthorizedTransport, now: now)
        }

        // Consumer shutdown: loadCodeAssist has currentTier free-tier + UNSUPPORTED_CLIENT, then quota returns 403
        let deprecation403Transport = MockGeminiTransport(responses: [
            .init(status: 200, data: Data(#"{"currentTier":{"id":"free-tier"},"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#.utf8)),
            .init(status: 200, data: Data(#"{"projects":[]}"#.utf8)),
            .init(status: 403, data: Data(#"{"error":{"status":"PERMISSION_DENIED","message":"SUBSCRIPTION_REQUIRED"}}"#.utf8)),
        ])
        await #expect(throws: GeminiCLIAdapter.FetchError.consumerTierDeprecated) {
            try await adapter.fetch(accessToken: "atk", expiresAt: now.addingTimeInterval(3600), transport: deprecation403Transport, now: now)
        }

        let server500Transport = MockGeminiTransport(responses: [
            .init(status: 500, data: Data()), // loadCodeAssist failure is non-fatal
            .init(status: 200, data: Data(#"{"projects":[]}"#.utf8)),
            .init(status: 503, data: Data()),
        ])
        await #expect(throws: GeminiCLIAdapter.FetchError.httpStatus(503)) {
            try await adapter.fetch(accessToken: "atk", expiresAt: now.addingTimeInterval(3600), transport: server500Transport, now: now)
        }

        await #expect(throws: GeminiCLIAdapter.FetchError.transport("offline")) {
            try await adapter.fetch(accessToken: "atk", expiresAt: now.addingTimeInterval(3600), transport: FailingGeminiTransport(), now: now)
        }

        #expect(GeminiCLIAdapter.staleReason(for: GeminiCLIAdapter.FetchError.unauthorized) == .authExpired)
        #expect(GeminiCLIAdapter.staleReason(for: GeminiCLIAdapter.FetchError.consumerTierDeprecated) == .authExpired)
        #expect(GeminiCLIAdapter.staleReason(for: GeminiCLIAdapter.FetchError.transport("x")) == .networkFailure)
        #expect(GeminiCLIAdapter.staleReason(for: GeminiCLIAdapter.FetchError.httpStatus(500)) == .endpointFailure)
        #expect(GeminiCLIAdapter.staleReason(for: GeminiCLIAdapter.FetchError.decode("x")) == .responseChanged)
    }

    @Test func extractsOAuthClientCredentialsFromSourceAndEnv() throws {
        let jsSource = """
        const OAUTH_CLIENT_ID = '12345-abc.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = "GOCSPX-secret_99";
        """
        let parsed = try #require(GeminiCLIAdapter.parseOAuthClientCredentials(from: jsSource))
        #expect(parsed.clientID == "12345-abc.apps.googleusercontent.com")
        #expect(parsed.clientSecret == "GOCSPX-secret_99")

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("oauth2-\(UUID().uuidString).js")
        try jsSource.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let fromFile = GeminiCLIAdapter.discoverOAuthClientCredentials(
            environment: ["GEMINI_OAUTH2_JS_PATH": tempFile.path]
        )
        #expect(fromFile == parsed)

        let fromEnv = GeminiCLIAdapter.discoverOAuthClientCredentials(
            environment: [
                "GEMINI_OAUTH_CLIENT_ID": "env-id",
                "GEMINI_OAUTH_CLIENT_SECRET": "env-sec",
            ]
        )
        #expect(fromEnv == .init(clientID: "env-id", clientSecret: "env-sec"))
    }

    #if os(macOS)
    @Test func readsGeminiCLICredentialsFromHomeDirectoryRespectingAuthType() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-home-\(UUID().uuidString)", isDirectory: true)
        let geminiDir = tempHome.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        #expect(throws: KeychainReader.ReadError.self) {
            try KeychainReader.readGeminiCLICredentials(home: tempHome)
        }

        let settingsURL = geminiDir.appendingPathComponent("settings.json")
        let credsURL = geminiDir.appendingPathComponent("oauth_creds.json")

        try Data(#"{"access_token":"atk","refresh_token":"rtk","id_token":"idt","expiry_date":1781474284318}"#.utf8)
            .write(to: credsURL)

        // oauth-personal allowed
        try Data(#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#.utf8).write(to: settingsURL)
        let credsMs = try KeychainReader.readGeminiCLICredentials(home: tempHome)
        #expect(credsMs.accessToken == "atk")
        #expect(credsMs.refreshToken == "rtk")
        #expect(credsMs.idToken == "idt")
        #expect(abs((credsMs.expiresAt?.timeIntervalSince1970 ?? 0) - 1781474284.318) < 0.01)

        // epoch seconds expiry_date also supported
        try Data(#"{"access_token":"atk2","expiry_date":1781474284}"#.utf8).write(to: credsURL)
        let credsSec = try KeychainReader.readGeminiCLICredentials(home: tempHome)
        #expect(abs((credsSec.expiresAt?.timeIntervalSince1970 ?? 0) - 1781474284) < 0.01)

        // refresh_token only allowed (access_token missing)
        try Data(#"{"refresh_token":"rtk-only"}"#.utf8).write(to: credsURL)
        let refreshOnly = try KeychainReader.readGeminiCLICredentials(home: tempHome)
        #expect(refreshOnly.accessToken.isEmpty)
        #expect(refreshOnly.refreshToken == "rtk-only")

        // Non-OAuth auth types skipped as notFound
        for authType in ["gemini-api-key", "api-key", "vertex-ai"] {
            try Data(#"{"security":{"auth":{"selectedType":"\#(authType)"}}}"#.utf8).write(to: settingsURL)
            #expect(throws: KeychainReader.ReadError.self) {
                try KeychainReader.readGeminiCLICredentials(home: tempHome)
            }
        }
    }
    #endif
}

private actor MockGeminiTransport: APICostHTTPTransport {
    struct Stub {
        let status: Int
        let data: Data
    }

    private var queue: [Stub]
    private(set) var requests: [URLRequest] = []

    init(responses: [Stub]) {
        self.queue = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let stub = queue.isEmpty ? Stub(status: 500, data: Data()) : queue.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? GeminiCLIAdapter.defaultQuotaURL,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (stub.data, response)
    }
}

private struct FailingGeminiTransport: APICostHTTPTransport {
    struct OfflineError: LocalizedError {
        var errorDescription: String? { "offline" }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw OfflineError()
    }
}
