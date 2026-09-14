import Foundation
import XCTest
import AgentMeterCore
@testable import AgentMeter

final class CodexIncrementalSessionMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let header = #"{"type":"session_meta","payload":{"id":"thread","session_id":"thread","originator":"Codex Desktop","cwd":"/private/project"}}"# + "\n"

    func testBaselineIgnoresHistoricalFailuresAndReadsOnlyAppends() throws {
        let home = try temporaryHome()
        let file = try write(header + error(at: now.addingTimeInterval(-30)), home: home)
        let engine = CodexIncrementalSessionMonitor()
        let initial = engine.scan(checkpoint(home), now: now)
        XCTAssertTrue(initial.checkpoint.queue.candidates.isEmpty)
        XCTAssertEqual(initial.filesRead, 0)
        try append(error(at: now.addingTimeInterval(1)), to: file)
        let next = engine.scan(initial.checkpoint, now: now.addingTimeInterval(2))
        XCTAssertEqual(next.checkpoint.queue.candidates.count, 1)
        XCTAssertFalse(next.checkpoint.queue.candidates[0].runtimeEvidenceVerified)
        XCTAssertEqual(next.bytesRead, error(at: now.addingTimeInterval(1)).utf8.count + 128)
        let unchanged = engine.scan(next.checkpoint, now: now.addingTimeInterval(3))
        XCTAssertEqual(unchanged.filesRead, 0)
        XCTAssertEqual(unchanged.bytesRead, 128) // Only fingerprint checks, no transcript replay.
        XCTAssertEqual(unchanged.checkpoint.queue.candidates.count, 1)
    }

    func testPartialRecordSurvivesCheckpointRoundTrip() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        let event = error(at: now.addingTimeInterval(1))
        let halves = event.index(event.startIndex, offsetBy: event.count / 2)
        try append(String(event[..<halves]), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        XCTAssertTrue(state.queue.candidates.isEmpty)
        let store = CodexMonitorCheckpointStore(url: home.appendingPathComponent("state/checkpoint.json"))
        try store.save(state)
        let stored = try Data(contentsOf: store.url)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("codex_error_info"))
        state = try XCTUnwrap(store.load())
        try append(String(event[halves...]), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(3)).checkpoint
        XCTAssertEqual(state.queue.candidates.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNewFilesAndManualContinue() throws {
        let home = try temporaryHome()
        _ = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        let file = try write(header + error(at: now.addingTimeInterval(1)), home: home, name: "new.jsonl")
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        XCTAssertNotNil(state.queue.latestPending)
        try append(event(type: "task_started", at: now.addingTimeInterval(3)), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(4)).checkpoint
        XCTAssertNil(state.queue.latestPending)
        // An out-of-order replay cannot reintroduce the stale failed turn.
        try append(error(at: now.addingTimeInterval(1), turn: "other-old"), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(5)).checkpoint
        XCTAssertNil(state.queue.latestPending)
    }

    func testTruncationAndRemovalInvalidateCandidate() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        try append(error(at: now.addingTimeInterval(1)), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        XCTAssertNotNil(state.queue.latestPending)
        try Data(header.utf8).write(to: file)
        state = engine.scan(state, now: now.addingTimeInterval(3)).checkpoint
        XCTAssertNil(state.queue.latestPending)
        try append(error(at: now.addingTimeInterval(4), turn: "second"), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(5)).checkpoint
        XCTAssertNotNil(state.queue.latestPending)
        try FileManager.default.removeItem(at: file)
        state = engine.scan(state, now: now.addingTimeInterval(6)).checkpoint
        XCTAssertNil(state.queue.latestPending)
    }

    func testDisableCancelAndRestartDeduplication() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        try append(error(at: now.addingTimeInterval(1)), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        state.queue.cancelPending()
        let store = CodexMonitorCheckpointStore(url: home.appendingPathComponent("state/checkpoint.json"))
        try store.save(state)
        try append(error(at: now.addingTimeInterval(1)), to: file)
        state = engine.scan(try XCTUnwrap(store.load()), now: now.addingTimeInterval(4)).checkpoint
        XCTAssertNil(state.queue.latestPending)
        XCTAssertEqual(state.queue.candidates.count, 1)
    }

    func testOversizedLinesDoNotPreventLaterErrors() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        var engine = CodexIncrementalSessionMonitor()
        engine.bytesPerFile = 256
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        try append(String(repeating: "x", count: 700) + "\n" + error(at: now.addingTimeInterval(1)), to: file)
        for _ in 0..<6 { state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint }
        XCTAssertEqual(state.queue.candidates.count, 1)
    }

    func testFutureUndatedAndTextOnlyErrorsAreIgnored() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        try append(error(at: now.addingTimeInterval(60)), to: file)
        try append(#"{"type":"event_msg","payload":{"type":"error","turn_id":"x","codex_error_info":"usage_limit_exceeded"}}"# + "\n", to: file)
        try append(event(type: "agent_message", at: now.addingTimeInterval(1), extra: ["message": "usage_limit_exceeded"]), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        XCTAssertTrue(state.queue.candidates.isEmpty)
    }

    func testCorruptStoreDoesNotBecomeEmptyQueue() throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent("checkpoint.json")
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try CodexMonitorCheckpointStore(url: file).load())
    }

    func testDistinctSessionIDUsesThreadIDFromHeader() {
        let distinct = header.replacingOccurrences(of: "\"session_id\":\"thread\"", with: "\"session_id\":\"different-session\"")
        XCTAssertEqual(CodexSessionEventParser.header(Data(distinct.utf8))?.threadID, "thread")
        XCTAssertNil(CodexSessionEventParser.header(Data(header.replacingOccurrences(of: "Codex Desktop", with: "codex_cli_rs").utf8)))
    }

    func testInPlaceRewritePastOldOffsetInvalidatesCandidate() throws {
        let home = try temporaryHome()
        let file = try write(header, home: home)
        let engine = CodexIncrementalSessionMonitor()
        var state = engine.scan(checkpoint(home), now: now).checkpoint
        try append(error(at: now.addingTimeInterval(1)), to: file)
        state = engine.scan(state, now: now.addingTimeInterval(2)).checkpoint
        XCTAssertNotNil(state.queue.latestPending)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((header + String(repeating: " ", count: 1000) + "\n").utf8))
        try handle.close()
        state = engine.scan(state, now: now.addingTimeInterval(3)).checkpoint
        XCTAssertNil(state.queue.latestPending)
    }

    @MainActor
    func testCoordinatorRemainsOffWithCorruptCheckpoint() throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent("checkpoint.json")
        try Data("invalid".utf8).write(to: file)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "codexSessionMonitoringEnabled")
        let coordinator = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file, now: now)
        XCTAssertTrue(coordinator.storageFailed)
        XCTAssertFalse(coordinator.enabled)
        coordinator.setEnabled(true)
        XCTAssertFalse(coordinator.enabled)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "invalid")
    }

    @MainActor
    func testCoordinatorPersistsCancellationBeforePublishing() throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent("state/checkpoint.json")
        let store = CodexMonitorCheckpointStore(url: file)
        var saved = checkpoint(home)
        let candidate = CodexResumeCandidate(threadID: "thread", failedTurnID: "turn", detectedAt: now)
        saved.queue.insert(candidate)
        try store.save(saved)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "codexSessionMonitoringEnabled")
        let coordinator = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file, now: now)
        coordinator.cancel(id: candidate.id)
        XCTAssertEqual(coordinator.candidates.first?.state, .cancelled)
        XCTAssertEqual(try store.load()?.queue.candidates.first?.state, .cancelled)
        coordinator.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: "codexSessionMonitoringEnabled"))
    }

    @MainActor
    func testRecoveredUncertainAttemptIsSavedEvenWithoutNewEvents() async throws {
        let home = try temporaryHome()
        let file = home.appendingPathComponent("checkpoint.json")
        var saved = checkpoint(home)
        saved.queue.insert(CodexResumeCandidate(threadID: "thread", failedTurnID: "turn", detectedAt: now))
        let encoded = try JSONEncoder().encode(saved)
        let crashState = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\"state\":\"pending\"", with: "\"state\":\"attempting\"")
        try Data(crashState.utf8).write(to: file)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "codexSessionMonitoringEnabled")
        let coordinator = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file, now: now)
        XCTAssertEqual(coordinator.candidates.first?.state, .uncertain)
        await coordinator.poll(now: now)
        XCTAssertEqual(try CodexMonitorCheckpointStore(url: file).load()?.queue.candidates.first?.state, .uncertain)
    }

    private func checkpoint(_ home: URL) -> CodexMonitorCheckpoint {
        .init(homePath: home.path, monitoringSince: now)
    }
    private func error(at: Date, turn: String = "failed") -> String {
        event(type: "error", at: at, extra: ["turn_id": turn, "codex_error_info": "usage_limit_exceeded"])
    }
    private func event(type: String, at: Date, extra: [String: String] = [:]) -> String {
        var payload = extra; payload["type"] = type
        let object: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: at), "type": "event_msg", "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self) + "\n"
    }
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, home: URL, name: String = "session.jsonl") throws -> URL {
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
