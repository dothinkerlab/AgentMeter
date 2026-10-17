import XCTest
import AgentMeterCore
@testable import AgentMeter

final class CodexDesktopQueueSenderTests: XCTestCase {
    let thread = "019fdcb3-13aa-74f2-ac90-5bbd931dd40c"
    let turn = "01a0aa82-a53e-7522-ade7-bd37b2b8ddbe"
    let message = "01a0aa82-a4d3-7020-9873-2e6b502c0345"

    func testReceiptBindsMessageToThread() throws {
        let output = "Queued message \(message) for thread \(thread).\n"
        XCTAssertEqual(try CodexDesktopQueueSender.receipt(Data(output.utf8), threadID: thread), message)
        for text in [output + output, "warning\n" + output, output.replacingOccurrences(of: thread, with: turn),
                     output.replacingOccurrences(of: message, with: "invalid")] {
            XCTAssertThrowsError(try CodexDesktopQueueSender.receipt(Data(text.utf8), threadID: thread))
        }
        XCTAssertEqual(CodexDesktopQueueSender.arguments(threadID: thread), ["queue", "--thread", thread, "--message", "继续"])
    }

    func testExclusiveReservationSurvivesNewStoreAndCorruption() throws {
        let url = try fixture()
        let target = try CodexQueueTarget.read(url, threadID: thread)
        let store = CodexQueueAttemptStore(directory: url.deletingLastPathComponent().appendingPathComponent("attempts"))
        let handle = try store.reserve(target)
        try store.record(handle, target: target, state: "queued", messageID: message)
        try handle.close()
        let record = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: store.file(for: target.key)))
        XCTAssertEqual(record["queuedMessageID"], message)
        XCTAssertNil(record["submittedTurnID"])
        XCTAssertThrowsError(try store.reserve(target))
        try Data().write(to: store.file(for: target.key))
        XCTAssertThrowsError(try CodexQueueAttemptStore(directory: store.directory).reserve(target))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file(for: target.key).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSourceChangeAndOtherFailuresBlockSending() throws {
        let url = try fixture()
        let target = try CodexQueueTarget.read(url, threadID: thread)
        try target.revalidate()
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd(); try file.write(contentsOf: Data("{}\n".utf8)); try file.close()
        XCTAssertThrowsError(try target.revalidate())
        XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
        let other = try fixture(error: "server_overloaded")
        XCTAssertThrowsError(try CodexQueueTarget.read(other, threadID: thread))
        let valid = try fixture()
        XCTAssertThrowsError(try CodexQueueTarget.read(valid, threadID: turn))
    }

    func testSettingsAfterFailureRemainEligible() throws {
        let url = try fixture()
        let failure = try CodexQueueTarget.read(url, threadID: thread)
        try appendSettings(to: url)
        let target = try CodexQueueTarget.read(url, threadID: thread)
        XCTAssertEqual(target.failedTurnID, failure.failedTurnID)
        XCTAssertEqual(target.failedAt, failure.failedAt)
        XCTAssertEqual(target.lastEvidenceAt.timeIntervalSince1970, 1791647894.412, accuracy: 0.001)
        try target.revalidate()
        try appendSettings(to: url)
        XCTAssertThrowsError(try target.revalidate())
        XCTAssertEqual(try CodexQueueTarget.read(url, threadID: thread).failedTurnID, turn)
    }

    func testOnlyMatchingWellFormedSettingsCanBeSkipped() throws {
        let settings: [String: Any] = ["type": "thread_settings_applied", "thread_id": thread]
        let invalidRows: [[String: Any]] = [
            ["timestamp": "2026-10-10T15:58:14.412Z", "type": "event_msg",
             "payload": ["type": "thread_settings_applied", "thread_id": message]],
            ["timestamp": "invalid", "type": "event_msg", "payload": settings],
            ["type": "event_msg", "payload": settings],
            ["timestamp": "2999-10-10T15:58:14Z", "type": "event_msg", "payload": settings],
            ["timestamp": "2026-10-10T14:00:00Z", "type": "event_msg", "payload": settings],
            ["timestamp": "2026-10-10T15:58:14Z", "type": "response_item", "payload": settings],
            ["timestamp": "2026-10-10T15:58:14Z", "type": "event_msg",
             "payload": ["type": "unknown_event"]]
        ]
        for row in invalidRows {
            let url = try fixture()
            try appendRow(row, to: url)
            XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
        }
        for kind in ["task_started", "user_message", "turn_aborted", "task_complete"] {
            let url = try fixture()
            try appendRow(["timestamp": "2026-10-10T15:00:00Z", "type": "event_msg",
                           "payload": ["type": kind]], to: url)
            try appendSettings(to: url)
            XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
        }
    }

    func testDelayedCommandsFromFailedTurnExplainTailAndRemainRevalidated() throws {
        let url = try fixture()
        let failure = try CodexQueueTarget.read(url, threadID: thread)
        try appendRow(commandCompletion(), to: url)
        var failed = commandCompletion()
        var payload = failed["payload"] as! [String: Any]
        payload["item"] = ["type": "CommandExecution", "id": "exec-failed", "status": "failed"]
        failed["payload"] = payload
        try appendRow(failed, to: url)
        try appendSettings(to: url)
        let target = try CodexQueueTarget.read(url, threadID: thread)
        XCTAssertEqual(target.failedTurnID, turn)
        XCTAssertEqual(target.failedAt, failure.failedAt)
        XCTAssertEqual(target.lastCommandCompletedAt, ISO8601DateFormatter().date(from: "2026-10-10T15:00:00Z"))
        XCTAssertEqual(target.lastEvidenceAt, target.lastSettingsAt)
        try target.revalidate()
        try appendRow(["timestamp": "2026-10-10T16:00:00Z", "type": "event_msg",
                       "payload": ["type": "task_started", "turn_id": message]], to: url)
        XCTAssertThrowsError(try target.revalidate())
        XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
    }

    func testUnrelatedMalformedOrNewCommandsCannotExplainTail() throws {
        let valid = commandCompletion()
        let validPayload = valid["payload"] as! [String: Any]
        let invalidPayloads: [[String: Any]] = [
            ["thread_id": message], ["turn_id": message], ["turn_id": NSNull()],
            ["started_at_ms": ISO8601DateFormatter().date(from: "2026-10-10T14:59:37Z")!.timeIntervalSince1970 * 1000],
            ["started_at_ms": 0], ["started_at_ms": NSNull()], ["completed_at_ms": 1],
            ["item": ["type": "AgentMessage", "id": "item", "status": "completed"]],
            ["item": ["type": "CommandExecution", "id": "item", "status": "inProgress"]],
            ["item": ["type": "CommandExecution", "status": "completed"]]
        ]
        for changes in invalidPayloads {
            let url = try fixture()
            var row = valid
            row["payload"] = validPayload.merging(changes) { _, new in new }
            try appendRow(row, to: url)
            XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread), "Accepted \(changes)")
        }
        for timestamp in ["invalid", "2999-10-10T15:00:00Z", "2026-10-10T14:00:00Z"] {
            let url = try fixture()
            var row = valid
            row["timestamp"] = timestamp
            try appendRow(row, to: url)
            XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
        }
        let url = try fixture()
        try appendSettings(to: url)
        try appendRow(valid, to: url) // Earlier completion appended after newer settings.
        XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
    }

    private func commandCompletion() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["timestamp": "2026-10-10T15:00:00Z", "type": "event_msg", "payload": [
            "type": "item_completed", "thread_id": thread, "turn_id": turn,
            "started_at_ms": formatter.date(from: "2026-10-10T14:59:00Z")!.timeIntervalSince1970 * 1000,
            "completed_at_ms": formatter.date(from: "2026-10-10T15:00:00Z")!.timeIntervalSince1970 * 1000,
            "item": ["type": "CommandExecution", "id": "exec-completed", "status": "completed"]]]
    }

    func testMalformedPartialAndOutOfBoundsEvidenceBlocks() throws {
        for suffix in [Data("{broken}\n".utf8), Data("{\"type\":\"event_msg\"".utf8), Data([10])] {
            let url = try fixture()
            try appendData(suffix, to: url)
            XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
        }
        let url = try fixture()
        try appendRow(["timestamp": "2026-10-10T15:58:14Z", "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "thread_id": thread,
                        "thread_settings": ["padding": String(repeating: "x", count: 512 * 1024)]]], to: url)
        XCTAssertThrowsError(try CodexQueueTarget.read(url, threadID: thread))
    }

    private func appendSettings(to url: URL) throws {
        try appendRow(["timestamp": "2026-10-10T15:58:14.412Z", "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "thread_id": thread, "thread_settings": [:]]], to: url)
    }

    private func appendRow(_ row: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(10)
        try appendData(data, to: url)
    }

    private func appendData(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testSymlinkSourceIsRejected() throws {
        let url = try fixture()
        let alias = url.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertThrowsError(try CodexQueueTarget.read(alias, threadID: thread))
    }

    func testProcessDrainsStderrAndRejectsNonzeroExit() throws {
        let home = try directory()
        let output = try CodexDesktopQueueSender.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'private diagnostic' >&2; printf 'receipt'"], home: home)
        XCTAssertEqual(String(data: output, encoding: .utf8), "receipt")
        XCTAssertThrowsError(try CodexDesktopQueueSender.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'receipt'; exit 1"], home: home))
    }

    func testProcessTimeoutAndOutputLimit() throws {
        let home = try directory()
        let start = Date()
        XCTAssertThrowsError(try CodexDesktopQueueSender.run(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["2"], home: home, timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertThrowsError(try CodexDesktopQueueSender.run(executable: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [], home: home, timeout: 2))
    }

    func testHistoryPreservesReceiptAndReportsCorruption() throws {
        let target = try CodexQueueTarget.read(fixture(), threadID: thread)
        let store = CodexQueueAttemptStore(directory: try directory())
        let handle = try store.reserve(target)
        try store.record(handle, target: target, state: "queued", messageID: message)
        try handle.close()
        var history = store.recent()
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.messageID, message)
        XCTAssertEqual(history.records.first?.state, "queued")
        XCTAssertFalse(history.unreadable)
        try Data("{}".utf8).write(to: store.directory.appendingPathComponent("invalid.json"))
        history = store.recent()
        XCTAssertEqual(history.records.count, 1)
        XCTAssertTrue(history.unreadable)
        XCTAssertThrowsError(try store.reserve(target))
    }

    @MainActor
    func testCandidatePrefillSelectsMatchingFailureAcrossMultipleSources() throws {
        let home = try directory(), file = home.appendingPathComponent("checkpoint.json")
        let source = home.appendingPathComponent("sessions/test.jsonl")
        let older = home.appendingPathComponent("sessions/older.jsonl")
        try writeFixture(to: source, turnID: turn)
        try appendSettings(to: source)
        try writeFixture(to: older, turnID: message)
        var state = CodexMonitorCheckpoint(homePath: home.path, monitoringSince: Date())
        let candidate = CodexResumeCandidate(threadID: thread, failedTurnID: turn, detectedAt: Date())
        state.queue.insert(candidate)
        let cursor = CodexMonitorCheckpoint.Cursor(fileID: 1, offset: 0, discardUntilNewline: false, threadID: thread)
        state.cursors[source.path] = cursor
        state.cursors[older.path] = cursor
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "codexSessionMonitoringEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        try CodexMonitorCheckpointStore(url: file).save(state)
        let coordinator = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file)
        XCTAssertEqual(coordinator.sourceForManualResume(candidateID: candidate.id), source)
        coordinator.cancel(id: candidate.id)
        XCTAssertNil(coordinator.sourceForManualResume(candidateID: candidate.id))
        let duplicate = home.appendingPathComponent("sessions/duplicate.jsonl")
        try writeFixture(to: duplicate, turnID: turn)
        state.cursors[duplicate.path] = cursor
        try CodexMonitorCheckpointStore(url: file).save(state)
        let ambiguous = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file)
        XCTAssertNil(ambiguous.sourceForManualResume(candidateID: candidate.id))
        let outsideSource = home.appendingPathComponent("outside.jsonl")
        try writeFixture(to: outsideSource, turnID: turn)
        state.cursors = [outsideSource.path: cursor]
        try CodexMonitorCheckpointStore(url: file).save(state)
        let outside = CodexResumeCoordinator(defaults: defaults, home: home, storeURL: file)
        XCTAssertNil(outside.sourceForManualResume(candidateID: candidate.id))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(error: String = "usage_limit_exceeded") throws -> URL {
        let url = try directory().appendingPathComponent("rollout.jsonl")
        try writeFixture(to: url, turnID: turn, error: error)
        return url
    }
    private func writeFixture(to url: URL, turnID: String,
                              error: String = "usage_limit_exceeded") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": thread, "originator": "Codex Desktop"]],
            ["timestamp": "2026-10-10T14:59:36.558Z", "type": "event_msg", "payload": ["type": "task_complete", "turn_id": turnID,
              "error": ["codex_error_info": error]]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: url)
    }
}
