import AgentMeterCore
import XCTest
@testable import AgentMeter

final class MacAntigravityQuotaTests: XCTestCase {
    func testParsesIndependentBucketsWithSameWindowAndKeepsRealZero() throws {
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(snapshot.groups.map(\.name), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(snapshot.groups.flatMap(\.buckets).map(\.id), ["gemini-weekly", "gemini-five-hour", "3p-weekly"])
        XCTAssertEqual(snapshot.groups.flatMap(\.buckets).map(\.remainingFraction), [0.8792, 0, 0.7084])
        XCTAssertNotNil(snapshot.groups[0].buckets[0].resetsAt)
        XCTAssertNil(snapshot.groups[0].buckets[1].resetsAt)
        XCTAssertNotNil(snapshot.groups[1].buckets[0].resetsAt)
    }

    func testCloudMappingUsesTheSameQuotaFactsAsTheMacReport() throws {
        let report = try MacAntigravityQuota.parse(Self.report, now: Date(timeIntervalSince1970: 42))
        let record = try RecordMapping.makeRecord(from: report.snapshot)
        let decoded = try RecordMapping.snapshot(from: record)
        XCTAssertEqual(record.recordID.recordName, "snapshot-antigravity")
        XCTAssertEqual(decoded.windows.compactMap { $0.antigravityBucket?.id },
                       ["gemini-weekly", "gemini-five-hour", "3p-weekly"])
        XCTAssertEqual(decoded.windows[0].remainingPercent, 87.92, accuracy: 0.0001)
        XCTAssertEqual(decoded.tightestWindow?.remainingPercent, 0)
        XCTAssertNil(decoded.tightestWindow?.resetsAt)
        XCTAssertEqual(decoded.updatedAt, report.updatedAt)
    }

    @MainActor
    func testFailedWriteRetriesAndPendingFactsDoNotCrossAccounts() async throws {
        let defaults = testDefaults()
        defaults.set(true, forKey: MacAntigravityController.enabledKey)
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date()).snapshot
        var account = "account-a"
        var offline = true
        var saved: [QuotaSnapshot] = []
        let store = MacAntigravityCloudSync.Store(
            account: { account }, fetch: { saved.last },
            save: { snapshot in
                if offline { throw URLError(.notConnectedToInternet) }
                saved.append(snapshot)
            }, delete: { saved.removeAll() }
        )
        let sync = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        sync.publish(snapshot)
        await sync.flush()
        XCTAssertTrue(sync.failed)
        XCTAssertTrue(saved.isEmpty)

        offline = false
        let restarted = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        await restarted.flush()
        XCTAssertEqual(saved, [snapshot])

        restarted.publish(snapshot.markedStale(reason: .networkFailure))
        account = "account-b"
        await restarted.flush()
        XCTAssertEqual(saved, [snapshot])
    }

    @MainActor
    func testDisableDeletesAfterAnInFlightSave() async throws {
        let defaults = testDefaults()
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date()).snapshot
        let started = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        var operations: [String] = []
        let store = MacAntigravityCloudSync.Store(
            account: { "account" }, fetch: { nil },
            save: { _ in
                started.continuation.yield(())
                for await _ in released.stream { break }
                operations.append("save")
            }, delete: { operations.append("delete") }
        )
        let sync = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        sync.publish(snapshot)
        let upload = Task { await sync.flush() }
        for await _ in started.stream { break }
        sync.remove()
        released.continuation.yield(())
        await upload.value
        XCTAssertEqual(operations, ["save", "delete"])
    }

    @MainActor
    func testRestartKeepsUnuploadedSuccessWhenTheNextCollectionFails() async throws {
        let defaults = testDefaults()
        defaults.set(true, forKey: MacAntigravityController.enabledKey)
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date(timeIntervalSince1970: 42)).snapshot
        var offline = true
        var saved: QuotaSnapshot?
        let store = MacAntigravityCloudSync.Store(
            account: { "account" }, fetch: { saved },
            save: {
                if offline { throw URLError(.notConnectedToInternet) }
                saved = $0
            }, delete: { saved = nil }
        )
        let initial = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        initial.publish(snapshot)
        await initial.flush()

        let restarted = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        restarted.publish(.unknown(tool: .antigravity, source: snapshot.source, reason: .authExpired))
        offline = false
        await restarted.flush()
        XCTAssertEqual(saved?.windows, snapshot.windows)
        XCTAssertEqual(saved?.updatedAt, snapshot.updatedAt)
        XCTAssertEqual(saved?.confidence, .stale)
        XCTAssertEqual(saved?.staleReason, .authExpired)
    }

    @MainActor
    func testDisabledRecordDeletionSurvivesOfflineRestart() async throws {
        let defaults = testDefaults()
        defaults.set(true, forKey: MacAntigravityController.enabledKey)
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date()).snapshot
        var saved: QuotaSnapshot?
        var offline = false
        var deletions = 0
        let store = MacAntigravityCloudSync.Store(
            account: { "account" }, fetch: { saved }, save: { saved = $0 },
            delete: {
                if offline { throw URLError(.notConnectedToInternet) }
                saved = nil
                deletions += 1
            }
        )
        let sync = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        sync.publish(snapshot)
        await sync.flush()
        defaults.set(false, forKey: MacAntigravityController.enabledKey)
        offline = true
        sync.remove()
        await sync.flush()
        XCTAssertTrue(sync.failed)
        XCTAssertNotNil(saved)

        offline = false
        let restarted = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        await restarted.flush()
        XCTAssertNil(saved)
        XCTAssertEqual(deletions, 1)
    }

    @MainActor
    func testAccountSwitchDuringCachedReadDiscardsTheOldAccountFacts() async throws {
        let defaults = testDefaults()
        let snapshot = try MacAntigravityQuota.parse(Self.report, now: Date()).snapshot
        var account = "account-a"
        var saves = 0
        let store = MacAntigravityCloudSync.Store(
            account: { account },
            fetch: { account = "account-b"; return snapshot },
            save: { _ in saves += 1 }, delete: {}
        )
        let sync = MacAntigravityCloudSync(defaults: defaults, store: store, automatic: false)
        sync.publish(.unknown(tool: .antigravity, source: snapshot.source, reason: .networkFailure))
        await sync.flush()
        await sync.flush()
        XCTAssertEqual(saves, 0)
    }

    func testRejectsMissingQuotaOrResultsFromAnAgentTurn() {
        for input in [
            "",
            #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[]}}}"#,
            #"{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"name":"Gemini","buckets":[{"id":"weekly","remaining_fraction":2}]}]}}}"#,
            String(decoding: Self.report, as: UTF8.self).replacingOccurrences(of: #""usage""#, with: #""model""#),
            String(decoding: Self.report, as: UTF8.self).replacingOccurrences(of: #""num_turns": 0"#, with: #""num_turns": 1"#),
            String(decoding: Self.report, as: UTF8.self).replacingOccurrences(of: #""SUCCESS""#, with: #""ERROR""#)
        ] {
            XCTAssertThrowsError(try MacAntigravityQuota.parse(Data(input.utf8), now: Date())) {
                XCTAssertEqual($0 as? MacAntigravityFailure, .invalidReport)
            }
        }
    }

    func testSkipsIDELauncherAndOldCLIAndQueriesOnlyCompatibleCandidate() async throws {
        let runner = FakeAgy()
        let home = try temporaryHome()
        let cli = MacAntigravityCLI(home: home, systemPaths: ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"],
                                    isExecutable: { _ in true }, run: { executable, args, directory, environment in
            if args == MacAntigravityCLI.usageArguments {
                XCTAssertEqual(environment["HOME"], home.path)
                XCTAssertNil(environment["GEMINI_API_KEY"])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
            }
            return try await runner.run(executable: executable, args: args)
        })
        let result = try await cli.fetch()
        XCTAssertEqual(result.groups.count, 2)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [
            ["--help"], ["--help"], ["--version"], ["--help"], ["--version"], MacAntigravityCLI.usageArguments
        ])
        XCTAssertEqual(calls.last?.path, "/usr/local/bin/agy")
    }

    func testSettingsBlockQueryBeforeSendingTheSlashCommand() async throws {
        let runner = FakeAgy()
        let home = try temporaryHome()
        let settings = home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cases: [(String, MacAntigravityFailure)] = [
            (#"{"disableSlashCommands":true}"#, .slashCommandsDisabled),
            (#"{"disableSlashCommands":1}"#, .unverifiedSettings),
            ("{", .unverifiedSettings)
        ]
        for (contents, expected) in cases {
            try Data(contents.utf8).write(to: settings)
            await checkFailure(testCLI(home: home, runner: runner), expected)
            XCTAssertEqual(try Data(contentsOf: settings), Data(contents.utf8))
        }
        let calls = await runner.calls
        XCTAssertFalse(calls.contains { $0.arguments == MacAntigravityCLI.usageArguments })
    }

    func testClassifiesMissingLoginAndTimeout() async throws {
        let home = try temporaryHome()
        await checkFailure(testCLI(home: home, runner: FakeAgy(behavior: .signedOut)), .signInRequired)
        await checkFailure(testCLI(home: home, runner: FakeAgy(behavior: .timeout)), .timedOut)
    }

    func testProcessDrainsOutputAndStopsTimedOutChild() async throws {
        let directory = try temporaryHome()
        let echo = try await MacAntigravityProcess().run(URL(fileURLWithPath: "/bin/echo"), ["report"], directory, [:])
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(String(decoding: echo.stdout, as: UTF8.self), "report\n")
        do {
            _ = try await MacAntigravityProcess(timeout: 0.05).run(URL(fileURLWithPath: "/bin/sleep"), ["30"], directory, [:])
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? MacAntigravityFailure, .timedOut)
        }
        do {
            _ = try await MacAntigravityProcess(outputLimit: 32).run(URL(fileURLWithPath: "/usr/bin/yes"), [], directory, [:])
            XCTFail("Expected output limit")
        } catch {
            XCTAssertEqual(error as? MacAntigravityFailure, .invalidReport)
        }
    }

    @MainActor
    func testOptInCadenceAndRetainingLastSuccess() async throws {
        let defaults = testDefaults()
        var ticks: TimeInterval = 0
        let quota = try MacAntigravityQuota.parse(Self.report, now: Date(timeIntervalSince1970: 42))
        let source = FakeAntigravityQuotaSource(quota: quota)
        let controller = MacAntigravityController(defaults: defaults, uptime: { ticks }, fetch: { try await source.fetch() })

        await controller.collect(force: true)
        var calls = await source.calls
        XCTAssertEqual(calls, 0)
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertEqual(controller.quota, quota)
        await source.setFailure(.commandFailed)
        ticks = 119
        await controller.collect()
        XCTAssertNil(controller.failure)
        await controller.collect(force: true)
        XCTAssertEqual(controller.failure, .commandFailed)
        XCTAssertEqual(controller.quota, quota)
        ticks = 239
        await controller.collect()
        calls = await source.calls
        XCTAssertEqual(calls, 3)
        controller.setEnabled(false)
        XCTAssertNil(controller.quota)
        XCTAssertNil(controller.failure)
        XCTAssertFalse(defaults.bool(forKey: MacAntigravityController.enabledKey))
    }

    @MainActor
    func testDisablingDiscardsLateResultAndPreventsConcurrentProbe() async throws {
        let quota = try MacAntigravityQuota.parse(Self.report, now: Date())
        let source = FakeAntigravityQuotaSource(quota: quota, suspended: true)
        let controller = MacAntigravityController(defaults: testDefaults(), fetch: { try await source.fetch() })
        controller.setEnabled(true)
        let refresh = Task { await controller.collect() }
        await source.waitForCall()
        await controller.collect()
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        controller.setEnabled(false)
        await source.release()
        await refresh.value
        XCTAssertNil(controller.quota)
        XCTAssertNil(controller.failure)
        XCTAssertFalse(controller.checking)
    }

    private func checkFailure(_ cli: MacAntigravityCLI, _ expected: MacAntigravityFailure,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await cli.fetch()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? MacAntigravityFailure, expected, file: file, line: line)
        }
    }

    private func testCLI(home: URL, runner: FakeAgy) -> MacAntigravityCLI {
        MacAntigravityCLI(home: home, systemPaths: ["/usr/local/bin/agy"],
                          isExecutable: { $0.path == "/usr/local/bin/agy" },
                          run: { executable, args, _, _ in try await runner.run(executable: executable, args: args) })
    }

    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func testDefaults() -> UserDefaults {
        let suite = "AntigravityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // Quota fields from the headless /usage envelope, with synthetic timestamps and fractions.
    fileprivate static let report = Data("""
    {
        "status": "SUCCESS", "num_turns": 0, "response": "ignored human-readable report",
        "command": {"name": "usage", "data": {"groups": [
            {"name": "Gemini Models", "buckets": [
                {"id": "gemini-weekly", "name": "Weekly", "window": "weekly",
                 "remaining_fraction": 0.8792, "reset_time": "2026-09-26T22:16:37Z"},
                {"id": "gemini-five-hour", "name": "5-hour", "remaining_fraction": 0},
                {"id": "missing", "name": "Missing quota"},
                {"id": "invalid", "remaining_fraction": "not numeric"},
                {"id": "gemini-weekly", "remaining_fraction": 0.1}
            ]},
            {"name": "Claude and GPT models", "buckets": [
                {"id": "3p-weekly", "name": "Weekly", "window": "weekly",
                 "remaining_fraction": 0.7084, "reset_time": "2026-09-26T22:25:09.123Z"}
            ]}
        ]}}
    }
    """.utf8)
}

private actor FakeAgy {
    enum Behavior { case ok, signedOut, timeout }
    let behavior: Behavior
    private(set) var calls: [(path: String, arguments: [String])] = []

    init(behavior: Behavior = .ok) { self.behavior = behavior }

    func run(executable: URL, args: [String]) throws -> MacAntigravityCommandResult {
        calls.append((executable.path, args))
        let output: String
        switch args {
        case ["--help"]:
            output = executable.path.hasSuffix("/.local/bin/agy") ? "Antigravity IDE --goto --install-extension"
                : "Antigravity CLI --print --output-format --disable-slash-commands"
        case ["--version"]:
            output = executable.path == "/opt/homebrew/bin/agy" ? "1.1.10" : "agy version v1.2.15"
        case MacAntigravityCLI.usageArguments:
            switch behavior {
            case .ok: return .init(status: 0, stdout: MacAntigravityQuotaTests.report, stderr: Data())
            case .signedOut: return .init(status: 1, stdout: Data(), stderr: Data("authentication required".utf8))
            case .timeout: throw MacAntigravityFailure.timedOut
            }
        default:
            XCTFail("Unexpected arguments \(args)")
            throw MacAntigravityFailure.commandFailed
        }
        return .init(status: 0, stdout: Data(output.utf8), stderr: Data())
    }
}

private actor FakeAntigravityQuotaSource {
    private(set) var calls = 0
    let quota: MacAntigravityQuota
    let suspended: Bool
    var failure: MacAntigravityFailure?
    var started: CheckedContinuation<Void, Never>?
    var result: CheckedContinuation<Void, Never>?

    init(quota: MacAntigravityQuota, suspended: Bool = false) {
        self.quota = quota
        self.suspended = suspended
    }

    func setFailure(_ value: MacAntigravityFailure) { failure = value }

    func fetch() async throws -> MacAntigravityQuota {
        calls += 1
        started?.resume()
        started = nil
        if suspended { await withCheckedContinuation { result = $0 } }
        if let failure { throw failure }
        return quota
    }

    func waitForCall() async {
        if calls == 0 { await withCheckedContinuation { started = $0 } }
    }

    func release() {
        result?.resume()
        result = nil
    }
}
