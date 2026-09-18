import Foundation
import XCTest
import SQLite3
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class CodexDesktopAutoResumeTests: XCTestCase {
    private struct Fixture {
        let home: URL
        let source: URL
        let candidate: CodexResumeCandidate
        let store: CodexMonitorCheckpointStore
        let defaults: UserDefaults
    }
    private let executable = URL(fileURLWithPath: "/test/codex")

    private func fixture(bound: Bool = true, observeAccount: Bool = false) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let defaultsName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: CodexResumeCoordinator.enabledKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: home) }
        try auth(home: home)
        let now = Date()
        let candidate = CodexResumeCandidate(threadID: UUID().uuidString, failedTurnID: UUID().uuidString,
            detectedAt: now.addingTimeInterval(-5), projectName: "Fixture")
        let source = sessions.appendingPathComponent("rollout.jsonl")
        try rows([
            ["type": "session_meta", "payload": ["id": candidate.threadID, "originator": "Codex Desktop"]],
            ["timestamp": ISO8601DateFormatter().string(from: candidate.detectedAt), "type": "event_msg", "payload": [
                "type": "task_complete", "turn_id": candidate.failedTurnID,
                "error": ["codex_error_info": "usage_limit_exceeded"]]]
        ]).write(to: source)
        try execute(home, "CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER, model_provider TEXT, updated_at_ms INTEGER, updated_at INTEGER)")
        try execute(home, "INSERT INTO threads VALUES ('\(candidate.threadID)', '\(source.path)', 0, 'openai', \(Int64(candidate.detectedAt.timeIntervalSince1970 * 1000)), 0)")
        var checkpoint = CodexMonitorCheckpoint(homePath: home.path, monitoringSince: now.addingTimeInterval(-10))
        checkpoint.queue.insert(candidate)
        checkpoint = CodexIncrementalSessionMonitor().scan(checkpoint, now: now).checkpoint
        if bound { checkpoint.accountBindings = [candidate.id: "account"] }
        if observeAccount {
            checkpoint.observedAccount = .init(accountID: "account", observedAt: now.addingTimeInterval(-10), fileModifiedAt: now.addingTimeInterval(-20))
        }
        let store = CodexMonitorCheckpointStore(url: home.appendingPathComponent("checkpoint.json"))
        try store.save(checkpoint)
        return .init(home: home, source: source, candidate: candidate, store: store, defaults: defaults)
    }

    func testProductionCoordinatorQueuesWithoutSocketAndObservesActivity() async throws {
        let f = try fixture()
        let process = FakeQueueProcess(source: f.source, threadID: f.candidate.threadID)
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in try self.usage() })
        let sender = CodexDesktopQueueController(resolveExecutable: { self.executable }, runProcess: { try process.run($0, $1, $2) })
        let coordinator = CodexResumeCoordinator(defaults: f.defaults, home: f.home, storeURL: f.store.url,
            notificationsEnabled: false, desktop: service, sender: sender)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent("app-server-control/app-server-control.sock").path))
        await coordinator.checkPending()
        XCTAssertEqual(coordinator.candidates.first?.state, .observed)
        XCTAssertNotNil(coordinator.candidates.first?.queuedMessageID)
        XCTAssertNil(coordinator.candidates.first?.submittedTurnID)
        XCTAssertEqual(process.sends, 1)
        await coordinator.checkPending()
        XCTAssertEqual(process.sends, 1)
        XCTAssertEqual(try f.store.load()?.queue.candidates.first?.state, .observed)
    }

    func testQuotaExhaustionWaitsAndNeverLaunchesQueue() async throws {
        let f = try fixture()
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in try self.usage(used: 100) })
        let check = await service.prepare(candidate: f.candidate, source: f.source, accountID: "account")
        guard case .waiting(let date) = check else { return XCTFail("Expected quota wait") }
        XCTAssertNotNil(date)
    }

    func testAccountAndSessionFailuresHaveSpecificReasons() async throws {
        let f = try fixture()
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in try self.usage() })
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: nil), .accountUnknown)
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: "different"), .accountMismatch)
        try execute(f.home, "UPDATE threads SET archived = 1")
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: "account"), .sessionArchived)
        try execute(f.home, "UPDATE threads SET archived = 0, updated_at_ms = \(Int64(Date().timeIntervalSince1970 * 1000))")
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: "account"), .sessionChanged)
    }

    func testUnauthorizedQuotaIsNotReportedAsCodexDisconnected() async throws {
        let f = try fixture()
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in throw CodexPlanAdapter.FetchError.unauthorized })
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: "account"), .authenticationRequired)
    }

    func testAccountChangeDuringHelpDefersBeforeReservation() async throws {
        let f = try fixture()
        let process = FakeQueueProcess(source: f.source, threadID: f.candidate.threadID)
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in try self.usage() })
        let prepared: CodexDesktopAutoResume.Prepared
        guard case .ready(let value) = await service.prepare(candidate: f.candidate, source: f.source, accountID: "account") else {
            return XCTFail("Expected ready")
        }
        prepared = value
        try auth(home: f.home, account: "changed")
        let attempts = CodexQueueAttemptStore(directory: f.home.appendingPathComponent("attempts"))
        let sender = CodexDesktopQueueController(resolveExecutable: { self.executable }, runProcess: { try process.run($0, $1, $2) })
        let outcome = await sender.send(source: f.source, threadID: f.candidate.threadID, home: f.home, store: attempts,
            expectedTarget: prepared.target, authorize: { try service.validate(prepared) }, onQueued: { _ in XCTFail("Must not queue") })
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(process.sends, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempts.file(for: prepared.target.key).path))
    }

    func testCancellationBeforeReservationKeepsAttemptUnsent() async throws {
        let f = try fixture()
        let process = FakeQueueProcess(source: f.source, threadID: f.candidate.threadID)
        let attempts = CodexQueueAttemptStore(directory: f.home.appendingPathComponent("attempts"))
        let target = try CodexQueueTarget.read(f.source, threadID: f.candidate.threadID)
        let sender = CodexDesktopQueueController(resolveExecutable: { self.executable }, runProcess: { try process.run($0, $1, $2) })
        let outcome = await sender.send(source: f.source, threadID: f.candidate.threadID, home: f.home,
            store: attempts, authorize: { throw CancellationError() }, onQueued: { _ in XCTFail("Must not queue") })
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(process.sends, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempts.file(for: target.key).path))
    }

    func testNewCandidatesBindOnlyWithStableObservedLogin() async throws {
        let f = try fixture(bound: false, observeAccount: true)
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in try self.usage(used: 100) })
        let coordinator = CodexResumeCoordinator(defaults: f.defaults, home: f.home, storeURL: f.store.url,
            notificationsEnabled: false, desktop: service)
        await coordinator.poll()
        XCTAssertEqual(try f.store.load()?.accountBindings?[f.candidate.id], "account")
        let old = try fixture(bound: false)
        let oldService = CodexDesktopAutoResume(home: old.home, host: { self.executable }, fetchUsage: { _ in try self.usage(used: 100) })
        let oldCoordinator = CodexResumeCoordinator(defaults: old.defaults, home: old.home, storeURL: old.store.url,
            notificationsEnabled: false, desktop: oldService)
        await oldCoordinator.poll()
        XCTAssertNil(try old.store.load()?.accountBindings?[old.candidate.id])
        XCTAssertEqual(oldCoordinator.checks[old.candidate.id], .blocked(.accountUnknown))
    }

    func testAccountChangeWhileQuotaLoadsDoesNotAuthorize() async throws {
        let f = try fixture()
        let service = CodexDesktopAutoResume(home: f.home, host: { self.executable }, fetchUsage: { _ in
            try self.auth(home: f.home, account: "changed")
            return try self.usage()
        })
        assertBlocked(await service.prepare(candidate: f.candidate, source: f.source, accountID: "account"), .accountMismatch)
    }

    private func assertBlocked(_ check: CodexDesktopAutoResume.Check, _ reason: CodexResumeBlock,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked(let actual) = check else { return XCTFail("Expected blocked", file: file, line: line) }
        XCTAssertEqual(actual, reason, file: file, line: line)
    }
    private func auth(home: URL, account: String = "account") throws {
        let url = home.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "fixture-only", "account_id": account]]).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: url.path)
    }
    private func usage(used: Double = 10) throws -> CodexResumeUsage {
        let data = try JSONSerialization.data(withJSONObject: [
            "account_id": "account", "rate_limit_reached_type": NSNull(), "spend_control": ["reached": false],
            "rate_limit": ["allowed": used < 100, "limit_reached": used >= 100,
                "primary_window": ["used_percent": used, "limit_window_seconds": 18000, "reset_at": Date().addingTimeInterval(3600).timeIntervalSince1970]]
        ])
        return try CodexResumeUsage.parse(data, accountID: "account")
    }
    private func rows(_ rows: [[String: Any]]) throws -> Data {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        return data
    }
    private func execute(_ home: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}

private final class FakeQueueProcess: @unchecked Sendable {
    let source: URL
    let threadID: String
    private let lock = NSLock()
    private var count = 0
    var sends: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(source: URL, threadID: String) { self.source = source; self.threadID = threadID }
    func run(_ executable: URL, _ arguments: [String], _ home: URL) throws -> Data {
        if arguments == ["queue", "--help"] { return Data("--thread --message".utf8) }
        guard arguments == ["queue", "--thread", threadID, "--message", "继续"] else { throw CodexDesktopQueueError.process }
        lock.lock(); count += 1; lock.unlock()
        let turn = UUID().uuidString
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = timestamp.string(from: Date().addingTimeInterval(0.1))
        let rows: [[String: Any]] = [
            ["timestamp": date, "type": "event_msg", "payload": ["type": "task_started", "turn_id": turn]],
            ["timestamp": date, "type": "event_msg", "payload": ["type": "user_message", "message": "继续"]],
            ["timestamp": date, "type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "fixture response"]]]]
        ]
        let file = try FileHandle(forWritingTo: source)
        defer { try? file.close() }
        try file.seekToEnd()
        for row in rows { try file.write(contentsOf: JSONSerialization.data(withJSONObject: row)); try file.write(contentsOf: Data([10])) }
        return Data("Queued message \(UUID().uuidString) for thread \(threadID).\n".utf8)
    }
}
