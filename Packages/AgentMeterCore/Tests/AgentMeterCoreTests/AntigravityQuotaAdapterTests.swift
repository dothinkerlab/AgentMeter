import Foundation
import Testing
@testable import AgentMeterCore

struct AntigravityQuotaAdapterTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func parsesQuotaSummaryFixtureAndWindowKinds() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let snapshot = try AntigravityQuotaAdapter().parseQuotaSummary(
            data: try fixture("antigravity_quota_summary_sample"),
            plan: "Google AI Pro",
            now: now
        )

        #expect(snapshot.tool == .antigravity)
        #expect(snapshot.plan == "Google AI Pro")
        #expect(snapshot.confidence == .fresh)
        #expect(snapshot.source == AntigravityQuotaAdapter.source)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.map(\.kind) == [.fiveHour, .sevenDay])

        #expect(abs((snapshot.window(.fiveHour)?.usedPercent ?? 0) - 28.0) < 0.001)
        #expect(abs((snapshot.window(.sevenDay)?.usedPercent ?? 0) - 46.0) < 0.001)
        #expect(snapshot.window(.claudeGPTFiveHour) == nil)
        #expect(snapshot.window(.claudeGPTWeekly) == nil)
        #expect(snapshot.window(.geminiFiveHour) == nil)
        #expect(snapshot.window(.geminiWeekly) == nil)

        // tightestWindow evaluates Gemini windows only and finds 7d (46% used)
        #expect(snapshot.tightestWindow?.kind == .sevenDay)

        #expect(QuotaWindowLabel.string(for: .fiveHour, style: .compactAbbrev) == "5h")
        #expect(QuotaWindowLabel.string(for: .sevenDay, style: .compactAbbrev) == "7d")
        #expect(QuotaWindowLabel.string(for: .geminiFiveHour, style: .compactAbbrev) == "5h")
        #expect(QuotaWindowLabel.string(for: .geminiWeekly, style: .compactAbbrev) == "7d")
    }

    @Test func quotaSummarySkipsDisabledStarterWeeklyOnlyAndRejectsErrors() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        // Starter tier with weekly-only buckets + disabled 5h bucket + duplicate tighter bucket
        let starterPayload = Data(#"""
        {
          "code": "ok",
          "summary": {
            "groups": [
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {"bucketId": "gemini-5h", "disabled": true, "remainingFraction": 1.0, "window": "5h"},
                  {"bucketId": "gemini-weekly", "remainingFraction": 0.90, "window": "weekly"},
                  {"bucketId": "gemini-weekly-2", "remainingFraction": 0.75, "window": "weekly"}
                ]
              },
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {"bucketId": "3p-weekly", "remainingFraction": 0.60, "window": "weekly"},
                  {"bucketId": "3p-missing-fraction", "window": "5h"}
                ]
              }
            ]
          }
        }
        """#.utf8)
        let snapshot = try AntigravityQuotaAdapter().parseQuotaSummary(data: starterPayload, now: now)
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.window(.fiveHour) == nil)
        #expect(snapshot.window(.claudeGPTFiveHour) == nil)
        #expect(snapshot.window(.claudeGPTWeekly) == nil)
        #expect(abs((snapshot.window(.sevenDay)?.usedPercent ?? 0) - 25.0) < 0.001)

        // Non-OK code rejected
        let errorCode = Data(#"{"code": 13, "groups": [{"displayName": "Gemini", "buckets": [{"bucketId": "g", "remainingFraction": 0.5}]}]}"#.utf8)
        #expect(throws: AntigravityQuotaAdapter.FetchError.self) {
            try AntigravityQuotaAdapter().parseQuotaSummary(data: errorCode, now: now)
        }
    }

    @Test func parsesCLIUsageReportWithSnakeCaseOneofAndPreamble() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let rawFixture = try fixture("antigravity_cli_usage_sample")
        var withPreamble = Data("Warning: debug notice\n".utf8)
        withPreamble.append(rawFixture)
        withPreamble.append(Data("\nDone.\n".utf8))

        let snapshot = try AntigravityQuotaAdapter().parseCLIUsageReport(data: withPreamble, now: now)
        #expect(snapshot.source == AntigravityQuotaAdapter.cliSource)
        #expect(snapshot.plan == "Google AI Pro")
        #expect(snapshot.windows.count == 2)
        #expect(abs((snapshot.window(.fiveHour)?.usedPercent ?? 0) - 40.0) < 0.001)
        #expect(abs((snapshot.window(.sevenDay)?.usedPercent ?? 0) - 20.0) < 0.001)
        #expect(snapshot.window(.claudeGPTFiveHour) == nil)
        #expect(snapshot.window(.claudeGPTWeekly) == nil)

        let authFailed = Data(#"{"status":"ERROR","error":{"message":"Authentication required. Run agy to sign in."}}"#.utf8)
        #expect(throws: AntigravityQuotaAdapter.FetchError.unauthorized) {
            try AntigravityQuotaAdapter().parseCLIUsageReport(data: authFailed, now: now)
        }

        let badCommand = Data(#"{"status":"SUCCESS","command":{"name":"other","data":{}}}"#.utf8)
        #expect(throws: AntigravityQuotaAdapter.FetchError.self) {
            try AntigravityQuotaAdapter().parseCLIUsageReport(data: badCommand, now: now)
        }
    }

    @Test func parsesUserStatusAndCommandModelConfigsExcludingLiteAndAutocomplete() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let userStatusData = try fixture("antigravity_user_status_sample")

        #expect(AntigravityQuotaAdapter.parsePlanFromUserStatus(data: userStatusData) == "Google AI Ultra")

        let snapshot = try AntigravityQuotaAdapter().parseUserStatus(data: userStatusData, now: now)
        #expect(snapshot.plan == "Google AI Ultra")
        #expect(snapshot.windows.count == 1)
        // Excluded gemini-3.7-flash-lite (0.10), tab_autocomplete_v2 (0.05), and Claude/GPT models
        #expect(abs((snapshot.window(.antigravityGemini)?.usedPercent ?? 0) - 30.0) < 0.001)
        #expect(snapshot.window(.antigravityClaudeGPT) == nil)

        let commandConfigsData = Data(#"""
        {
          "code": 0,
          "clientModelConfigs": [
            {"label": "Gemini 3.7 Pro", "modelOrAlias": {"model": "gemini-3.7-pro"}, "quotaInfo": {"remainingFraction": 0.72}},
            {"label": "GPT OSS", "modelOrAlias": {"model": "gpt-oss-120b"}, "quotaInfo": {"remainingFraction": 0.85}},
            {"label": "Gemini Image", "modelOrAlias": {"model": "gemini-image"}, "quotaInfo": {"remainingFraction": 0.1}}
          ]
        }
        """#.utf8)
        let cmdSnap = try AntigravityQuotaAdapter().parseCommandModelConfigs(data: commandConfigsData, plan: "Pro", now: now)
        #expect(cmdSnap.plan == "Pro")
        #expect(cmdSnap.windows.count == 1)
        #expect(abs((cmdSnap.window(.antigravityGemini)?.usedPercent ?? 0) - 28.0) < 0.001)
        #expect(cmdSnap.window(.antigravityClaudeGPT) == nil)

        let claudeAndImageOnlyData = Data(#"""
        {
          "code": 0,
          "clientModelConfigs": [
            {"label": "GPT OSS", "modelOrAlias": {"model": "gpt-oss-120b"}, "quotaInfo": {"remainingFraction": 0.85}},
            {"label": "Gemini Image", "modelOrAlias": {"model": "gemini-image"}, "quotaInfo": {"remainingFraction": 0.1}}
          ]
        }
        """#.utf8)
        #expect(throws: AntigravityQuotaAdapter.FetchError.self) {
            try AntigravityQuotaAdapter().parseCommandModelConfigs(data: claudeAndImageOnlyData, plan: "Pro", now: now)
        }
    }

    @Test func parsesLocalProcessListAndListeningPorts() {
        let psOutput = """
          101 /usr/libexec/logd
          412 /Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --app_data_dir antigravity --csrf_token tok-abc --extension_server_port 51002 --extension_server_csrf_token ext-xyz
          413 /Applications/Windsurf.app/Contents/Resources/language_server_macos_arm --csrf_token windsurf-tok
          414 /Applications/Antigravity IDE.app/Contents/bin/language_server_macos --csrf_token=tok-eq
          415 /Applications/Antigravity.app/Contents/bin/language_server_macos
        """
        let processes = AntigravityQuotaAdapter.parseProcessList(psOutput)
        #expect(processes.count == 2)
        #expect(processes[0].pid == 412)
        #expect(processes[0].csrfToken == "tok-abc")
        #expect(processes[0].extensionPort == 51002)
        #expect(processes[0].extensionServerCSRFToken == "ext-xyz")
        #expect(processes[1].pid == 414)
        #expect(processes[1].csrfToken == "tok-eq")

        let lsofOutput = """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        language_ 412 user   10u  IPv4 0x123      0t0  TCP 127.0.0.1:51002 (LISTEN)
        language_ 412 user   11u  IPv4 0x124      0t0  TCP 127.0.0.1:51001 (LISTEN)
        language_ 412 user   12u  IPv6 0x125      0t0  TCP [::1]:51001 (LISTEN)
        """
        #expect(AntigravityQuotaAdapter.parseListeningPorts(lsofOutput) == [51002, 51001])
    }

    #if os(macOS)
    @Test func runtimeFetchesLoopbackSummaryWithPlanAndFallsBackToUserStatusAndCLI() async throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let summaryData = try fixture("antigravity_quota_summary_sample")
        let userStatusData = try fixture("antigravity_user_status_sample")
        let cliData = try fixture("antigravity_cli_usage_sample")

        // 1. Path A: RetrieveUserQuotaSummary + GetUserStatus plan enrichment
        let pathARuntime = AntigravityQuotaAdapter.Runtime(
            listProcesses: {
                [.init(pid: 412, commandLine: "language_server_macos", csrfToken: "csrf-1", extensionPort: 51002)]
            },
            listeningPorts: { _ in [51002, 51001] },
            sendLocalRequest: { request in
                let path = request.url?.path ?? ""
                #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "csrf-1")
                #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
                let body: Data = path.hasSuffix("RetrieveUserQuotaSummary") ? summaryData : userStatusData
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            resolveAgyBinary: { nil },
            runCLIUsage: { _ in Issue.record("CLI should not run when local RPC succeeds"); return (0, Data(), Data()) },
            now: { now }
        )
        let pathASnap = try await AntigravityQuotaAdapter(runtime: pathARuntime, cliCache: AntigravityCLICache()).fetch()
        #expect(pathASnap.plan == "Google AI Ultra")
        #expect(pathASnap.windows.count == 2)
        #expect(pathASnap.windows.map(\.kind) == [.fiveHour, .sevenDay])

        // 2. Fallback from RetrieveUserQuotaSummary (404) -> GetUserStatus (200)
        let fallbackRuntime = AntigravityQuotaAdapter.Runtime(
            listProcesses: {
                [.init(pid: 412, commandLine: "language_server_macos", csrfToken: "csrf-1")]
            },
            listeningPorts: { _ in [51001] },
            sendLocalRequest: { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("RetrieveUserQuotaSummary") {
                    return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
                }
                return (userStatusData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            resolveAgyBinary: { nil },
            runCLIUsage: { _ in (0, Data(), Data()) },
            now: { now }
        )
        let fallbackSnap = try await AntigravityQuotaAdapter(runtime: fallbackRuntime, cliCache: AntigravityCLICache()).fetch()
        #expect(fallbackSnap.window(.antigravityGemini) != nil)
        #expect(fallbackSnap.window(.antigravityClaudeGPT) == nil)

        // 3. Path B: agy CLI fallback + 4-minute cache + forceRefresh bypass
        let invocationCounter = InvocationCounter()
        let cache = AntigravityCLICache(ttl: 240)
        let cliRuntime = AntigravityQuotaAdapter.Runtime(
            listProcesses: { [] },
            listeningPorts: { _ in [] },
            sendLocalRequest: { _ in throw AntigravityQuotaAdapter.FetchError.notRunning },
            resolveAgyBinary: { URL(fileURLWithPath: "/opt/homebrew/bin/agy") },
            runCLIUsage: { _ in
                await invocationCounter.increment()
                return (0, cliData, Data())
            },
            now: { now }
        )
        let cliAdapter = AntigravityQuotaAdapter(runtime: cliRuntime, cliCache: cache)
        let cliFirst = try await cliAdapter.fetch()
        #expect(cliFirst.source == AntigravityQuotaAdapter.cliSource)
        #expect(await invocationCounter.count == 1)

        // Cached hit
        _ = try await cliAdapter.fetch()
        #expect(await invocationCounter.count == 1)

        // forceRefresh bypasses cache
        _ = try await cliAdapter.fetch(forceRefresh: true)
        #expect(await invocationCounter.count == 2)
    }

    @Test func runtimeMapsNotRunningUnauthorizedAndAuthoritativeCliPathOverride() async throws {
        let notRunningAdapter = AntigravityQuotaAdapter(
            runtime: .init(
                listProcesses: { [] },
                listeningPorts: { _ in [] },
                sendLocalRequest: { _ in throw AntigravityQuotaAdapter.FetchError.notRunning },
                resolveAgyBinary: { nil },
                runCLIUsage: { _ in (0, Data(), Data()) }
            ),
            cliCache: AntigravityCLICache()
        )
        await #expect(throws: AntigravityQuotaAdapter.FetchError.notRunning) {
            try await notRunningAdapter.fetch()
        }

        let unauthorizedAdapter = AntigravityQuotaAdapter(
            runtime: .init(
                listProcesses: { [.init(pid: 1, commandLine: "language_server_macos", csrfToken: "c")] },
                listeningPorts: { _ in [50000] },
                sendLocalRequest: { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                },
                resolveAgyBinary: { nil },
                runCLIUsage: { _ in (0, Data(), Data()) }
            ),
            cliCache: AntigravityCLICache()
        )
        await #expect(throws: AntigravityQuotaAdapter.FetchError.unauthorized) {
            try await unauthorizedAdapter.fetch()
        }

        // ANTIGRAVITY_CLI_PATH empty or nonexistent skips fallback discovery
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fakeAgy = tempDir.appendingPathComponent("agy")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeAgy)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeAgy.path)

        #expect(AntigravityQuotaAdapter.resolveAgyBinary(environment: ["PATH": tempDir.path]) == fakeAgy)
        #expect(AntigravityQuotaAdapter.resolveAgyBinary(environment: [
            "PATH": tempDir.path,
            "ANTIGRAVITY_CLI_PATH": "",
        ]) == nil)
        #expect(AntigravityQuotaAdapter.resolveAgyBinary(environment: [
            "PATH": tempDir.path,
            "ANTIGRAVITY_CLI_PATH": tempDir.appendingPathComponent("missing").path,
        ]) == nil)
    }
    #endif
}

private actor InvocationCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
