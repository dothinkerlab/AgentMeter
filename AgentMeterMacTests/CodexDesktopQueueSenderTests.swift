import XCTest
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

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func fixture(error: String = "usage_limit_exceeded") throws -> URL {
        let url = try directory().appendingPathComponent("rollout.jsonl")
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": thread, "originator": "Codex Desktop"]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn,
              "error": ["codex_error_info": error]]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: url)
        return url
    }
}
