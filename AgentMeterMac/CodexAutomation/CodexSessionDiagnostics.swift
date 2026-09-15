import Foundation

/// A bounded, read-only sample of local rollouts. This is NOT a pending-session detector:
/// Desktop may omit errors from rollouts, and historical errors do not prove a thread is blocked.
struct CodexSessionDiagnostics: Sendable, Equatable {
    var filesInspected = 0
    var filesTruncated = 0
    var unreadableFiles = 0
    var malformedLines = 0
    var incompleteLines = 0
    var structuredQuotaErrors = 0
    var enumerationIncomplete = false
    var sessionDirectoryAvailable = false
}

struct CodexSessionDiagnosticScanner: Sendable {
    let home: URL
    let fileLimit: Int
    let bytesPerFile: Int
    let entryLimit: Int

    init(home: URL, fileLimit: Int = 30, bytesPerFile: Int = 512 * 1024, entryLimit: Int = 20_000) {
        self.home = home
        self.fileLimit = max(1, min(fileLimit, 30))
        self.bytesPerFile = max(1, min(bytesPerFile, 512 * 1024))
        self.entryLimit = max(1, min(entryLimit, 20_000))
    }

    func scan() -> CodexSessionDiagnostics {
        let manager = FileManager.default
        let directory = home.appendingPathComponent("sessions", isDirectory: true)
        var report = CodexSessionDiagnostics()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let root = try? directory.resourceValues(forKeys: keys),
              root.isDirectory == true, root.isSymbolicLink != true else { return report }
        report.sessionDirectoryAvailable = true
        guard let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in report.enumerationIncomplete = true; return true }
        ) else {
            report.enumerationIncomplete = true
            return report
        }

        var recent: [(url: URL, modified: Date)] = []
        var entries = 0
        for case let url as URL in enumerator {
            if Task.isCancelled { report.enumerationIncomplete = true; break }
            entries += 1
            if entries > entryLimit { report.enumerationIncomplete = true; break }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                report.enumerationIncomplete = true
                continue
            }
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            recent.append((url, values.contentModificationDate ?? .distantPast))
            recent.sort {
                $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified
            }
            if recent.count > fileLimit { recent.removeLast() }
        }

        for file in recent {
            if Task.isCancelled { report.enumerationIncomplete = true; break }
            do {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                let start = size > UInt64(bytesPerFile) ? size - UInt64(bytesPerFile) : 0
                // Include the previous byte so a line exactly at the tail boundary is retained.
                try handle.seek(toOffset: start > 0 ? start - 1 : 0)
                var data = try handle.read(upToCount: bytesPerFile + (start > 0 ? 1 : 0)) ?? Data()
                if start > 0 {
                    report.filesTruncated += 1
                    if let newline = data.firstIndex(of: 0x0A) {
                        data = Data(data.suffix(from: data.index(after: newline)))
                    } else {
                        data = Data()
                    }
                }
                report.filesInspected += 1
                Self.inspect(data, report: &report)
            } catch {
                report.unreadableFiles += 1
            }
        }
        return report
    }

    static func inspect(_ data: Data, report: inout CodexSessionDiagnostics) {
        // A live writer can leave a partial last record. Do not interpret it as an event.
        let complete: Data
        if data.isEmpty { return }
        if data.last == 0x0A { complete = data }
        else {
            report.incompleteLines += 1
            complete = data.lastIndex(of: 0x0A).map { Data(data.prefix(through: $0)) } ?? Data()
        }
        for line in complete.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                report.malformedLines += 1
                continue
            }
            if isStructuredQuotaError(object) { report.structuredQuotaErrors += 1 }
        }
    }

    private static func isStructuredQuotaError(_ object: [String: Any]) -> Bool {
        // Official App Server wire shape. Never search message text or nested tool output.
        if object["method"] as? String == "turn/completed",
           let params = object["params"] as? [String: Any],
           let threadID = params["threadId"] as? String, !threadID.isEmpty,
           let turn = params["turn"] as? [String: Any],
           let turnID = turn["id"] as? String, !turnID.isEmpty,
           turn["status"] as? String == "failed",
           let error = turn["error"] as? [String: Any] {
            return error["codexErrorInfo"] as? String == "usageLimitExceeded"
        }
        // Structured rollout events; only task_complete is verified against Desktop persistence.
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any] else { return false }
        // Verified on this machine: Desktop rollouts nest the failure on the closing task_complete
        // record as payload.error.codex_error_info. Text mentions alone never count.
        if payload["type"] as? String == "task_complete",
           let error = payload["error"] as? [String: Any],
           quotaInfo(error["codex_error_info"] ?? error["codexErrorInfo"]) { return true }
        guard payload["type"] as? String == "error" else { return false }
        return quotaInfo(payload["codex_error_info"] as? String)
    }

    private static func quotaInfo(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value == "usage_limit_exceeded" || value == "usageLimitExceeded"
    }
}
