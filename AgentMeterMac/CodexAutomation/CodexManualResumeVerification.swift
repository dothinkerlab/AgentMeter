import Foundation

/// Read-only evidence for a user-operated test. Never opens a thread or sends input.
struct CodexManualResumeVerification {
    enum Status: Equatable { case waiting, submitted, running, uncertain }
    enum Failure: Error { case invalidFile, sourceChanged, oversized }
    private(set) var status: Status = .waiting
    private(set) var turnID: String?
    let threadID: String
    private let handle: FileHandle
    private var offset: UInt64
    private var anchor: Data
    private var startedTurn: String?
    private let beganAt: Date

    init(url: URL, expectedThreadID: String, now: Date = Date()) throws {
        guard UUID(uuidString: expectedThreadID) != nil,
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw Failure.invalidFile
        }
        let file = try FileHandle(forReadingFrom: url)
        do {
            let header = try file.read(upToCount: 64 * 1024) ?? Data()
            guard CodexSessionEventParser.header(header)?.threadID == expectedThreadID else { throw Failure.invalidFile }
            let end = try file.seekToEnd()
            try file.seek(toOffset: end > 64 ? end - 64 : 0)
            let tail = try file.readToEnd() ?? Data()
            guard tail.last == 10 else { throw Failure.invalidFile }
            handle = file; offset = end; anchor = tail
            threadID = expectedThreadID; beganAt = now
        } catch { try? file.close(); throw error }
    }

    mutating func poll() throws {
        guard status != .running, status != .uncertain else { return }
        let end = try handle.seekToEnd()
        guard end >= offset else { throw Failure.sourceChanged }
        try handle.seek(toOffset: offset - UInt64(anchor.count))
        guard try handle.read(upToCount: anchor.count) == anchor else { throw Failure.sourceChanged }
        guard end - offset <= 1024 * 1024 else { throw Failure.oversized }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: Int(end - offset)) ?? Data()
        guard let last = data.lastIndex(of: 10) else { return }
        let complete = Data(data.prefix(through: last))
        for line in complete.split(separator: 10) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let date = Self.date(timestamp), date >= beganAt,
                  let payload = object["payload"] as? [String: Any] else { continue }
            consume(type: object["type"] as? String, payload: payload)
            if status == .uncertain || status == .running { break }
        }
        offset += UInt64(complete.count)
        try handle.seek(toOffset: offset > 64 ? offset - 64 : 0)
        anchor = try handle.read(upToCount: Int(min(64, offset))) ?? Data()
    }

    private mutating func consume(type: String?, payload: [String: Any]) {
        let kind = payload["type"] as? String
        if type == "event_msg", kind == "task_started", let id = payload["turn_id"] as? String {
            guard startedTurn == nil else { status = .uncertain; return }
            startedTurn = id
        }
        var userText: String?
        if type == "event_msg", kind == "user_message" { userText = payload["message"] as? String }
        if type == "response_item", kind == "message", payload["role"] as? String == "user" {
            let content = payload["content"] as? [[String: Any]] ?? []
            if content.count == 1, content[0]["type"] as? String == "input_text" {
                userText = content[0]["text"] as? String
            } else { status = .uncertain; return }
        }
        if let text = userText {
            guard text == "继续", status == .waiting else { status = .uncertain; return }
            status = .submitted
        }
        if type == "event_msg", ["turn_aborted", "task_complete"].contains(kind ?? "") {
            status = .uncertain
        }
        if status == .submitted, let startedTurn,
           type == "response_item", kind == "message", payload["role"] as? String == "assistant",
           let content = payload["content"] as? [[String: Any]],
           content.contains(where: { $0["type"] as? String == "output_text" && !($0["text"] as? String ?? "").isEmpty }) {
            turnID = startedTurn; status = .running
        }
    }

    func close() { try? handle.close() }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
