import XCTest
@testable import AgentMeter

final class CodexManualResumeVerificationTests: XCTestCase {
    private let id = "019fdcb3-13aa-74f2-ac90-5bbd931dd40c"
    private let now = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!

    func testOnlyNewExactPromptAndAssistantActivityVerify() throws {
        let url = try fixture()
        try append(message("user", "继续"), to: url)
        var verifier = try CodexManualResumeVerification(url: url, expectedThreadID: id, now: now)
        defer { verifier.close() }
        try verifier.poll()
        XCTAssertEqual(verifier.status, .waiting)
        try append(event("task_started", extra: ["turn_id": "new-turn"]), to: url)
        try append(message("user", "继续"), to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .submitted)
        try append(message("assistant", "Working"), to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .running)
        XCTAssertEqual(verifier.turnID, "new-turn")
    }

    func testSubstringAndRepeatedPromptAreUncertain() throws {
        for texts in [["请继续解释"], ["继续", "继续"]] {
            let url = try fixture()
            var verifier = try CodexManualResumeVerification(url: url, expectedThreadID: id, now: now)
            defer { verifier.close() }
            for text in texts { try append(message("user", text), to: url) }
            try verifier.poll()
            XCTAssertEqual(verifier.status, .uncertain)
        }
    }

    func testPartialAndMissingTimestampCannotVerify() throws {
        let url = try fixture()
        var verifier = try CodexManualResumeVerification(url: url, expectedThreadID: id, now: now)
        defer { verifier.close() }
        let line = message("user", "继续")
        try append(String(line.dropLast()), to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .waiting)
        try append("\n", to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .submitted)
        try append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"t\"}}\n", to: url)
        try append(message("assistant", "Working"), to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .submitted)
    }

    func testWrongThreadAndRewrittenSourceFailClosed() throws {
        let url = try fixture()
        XCTAssertThrowsError(try CodexManualResumeVerification(url: url, expectedThreadID: UUID().uuidString))
        var verifier = try CodexManualResumeVerification(url: url, expectedThreadID: id, now: now)
        defer { verifier.close() }
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: 0)
        try writer.close()
        XCTAssertThrowsError(try verifier.poll())
    }

    func testFailureAfterPromptDoesNotCountAsRunning() throws {
        let url = try fixture()
        var verifier = try CodexManualResumeVerification(url: url, expectedThreadID: id, now: now)
        defer { verifier.close() }
        try append(event("task_started", extra: ["turn_id": "t"]), to: url)
        try append(message("user", "继续"), to: url)
        try append(event("task_complete"), to: url)
        try append(message("assistant", "Working"), to: url)
        try verifier.poll()
        XCTAssertEqual(verifier.status, .uncertain)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"originator\":\"Codex Desktop\"}}\n"
        try Data(header.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func message(_ role: String, _ text: String) -> String {
        record("response_item", ["type": "message", "role": role,
            "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]])
    }
    private func event(_ type: String, extra: [String: Any] = [:]) -> String {
        var payload = extra; payload["type"] = type
        return record("event_msg", payload)
    }
    private func record(_ type: String, _ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-09-15T00:00:01Z", "payload": payload])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
}
