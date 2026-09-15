import Foundation
import AgentMeterCore

enum CodexObservedSessionEvent: Equatable {
    case quotaBlocked(CodexResumeCandidate)
    case progressed(threadID: String, at: Date)
}

enum CodexSessionEventParser {
    static func header(_ data: Data) -> (threadID: String, projectName: String?)? {
        guard let end = data.firstIndex(of: 10),
              let object = json(Data(data.prefix(upTo: end))), object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              payload["originator"] as? String == "Codex Desktop",
              let thread = identifier(payload["id"]) else { return nil }
        // Desktop can store a different session_id. The id field matches the rollout filename
        // and thread index; do not conflate these identifiers or discard otherwise valid headers.
        let name = (payload["cwd"] as? String).map { String(URL(fileURLWithPath: $0).lastPathComponent.prefix(128)) }
        return (thread, name)
    }

    static func parse(_ data: Data, cursor: CodexMonitorCheckpoint.Cursor,
                      since: Date, now: Date) -> CodexObservedSessionEvent? {
        guard let object = json(data), let timestamp = object["timestamp"] as? String,
              let at = date(timestamp), at >= since, at <= now else { return nil }
        // Runtime envelopes are recognized only at the top level, never inside chat/tool text.
        if object["method"] as? String == "turn/completed",
           let params = object["params"] as? [String: Any],
           params["threadId"] as? String == cursor.threadID,
           let turn = params["turn"] as? [String: Any], let turnID = identifier(turn["id"]) {
            if turn["status"] as? String == "failed",
               let error = turn["error"] as? [String: Any], error["codexErrorInfo"] as? String == "usageLimitExceeded" {
                return .quotaBlocked(candidate(cursor, turnID, at))
            }
            if ["completed", "interrupted", "failed"].contains(turn["status"] as? String ?? "") {
                return .progressed(threadID: cursor.threadID, at: at)
            }
        }
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
              let kind = payload["type"] as? String else { return nil }
        // Real Desktop rollouts carry the quota failure as a nested error on the closing task_complete:
        // payload.error.codex_error_info == "usage_limit_exceeded" with payload.turn_id set. This must be
        // matched before the progress list below, otherwise the record reporting the interruption would
        // revoke the candidate it should create (task_complete alone is otherwise treated as progress).
        if kind == "task_complete", let error = payload["error"] as? [String: Any],
           isQuotaBlocked(error["codex_error_info"] as? String ?? error["codexErrorInfo"] as? String),
           let turnID = identifier(payload["turn_id"]) {
            return .quotaBlocked(candidate(cursor, turnID, at))
        }
        // Compatibility branch for a top-level error record; not observed in Desktop rollout files so far.
        if kind == "error", let turnID = identifier(payload["turn_id"]),
           isQuotaBlocked(payload["codex_error_info"] as? String) {
            return .quotaBlocked(candidate(cursor, turnID, at))
        }
        if ["task_started", "task_complete", "turn_aborted", "user_message"].contains(kind) {
            return .progressed(threadID: cursor.threadID, at: at)
        }
        return nil
    }

    private static func candidate(_ cursor: CodexMonitorCheckpoint.Cursor, _ turn: String, _ at: Date) -> CodexResumeCandidate {
        // Local files alone cannot attest account, bucket, current runtime state, or control ownership.
        CodexResumeCandidate(threadID: cursor.threadID, failedTurnID: turn, detectedAt: at, projectName: cursor.projectName)
    }
    /// Both spellings appear across versions: rollout JSONL uses snake_case, the runtime schema camelCase.
    private static func isQuotaBlocked(_ value: String?) -> Bool {
        ["usage_limit_exceeded", "usageLimitExceeded"].contains(value ?? "")
    }
    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 256 else { return nil }
        return string
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
