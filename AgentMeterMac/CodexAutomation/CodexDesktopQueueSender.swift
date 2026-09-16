import Foundation
import CryptoKit
import Darwin

enum CodexDesktopQueueError: Error { case invalidSource, duplicate, storage, process, uncertain }

/// Explicitly selected local failure. Revalidate immediately before sending; this is not a
/// runtime idle/archival/permissions attestation and must not enable unattended sends.
struct CodexQueueTarget {
    let threadID: String
    let failedTurnID: String
    let source: URL
    let size: UInt64
    let fileID: UInt64
    let tail: Data
    var key: String { threadID + ":" + failedTurnID }

    static func read(_ url: URL, threadID: String) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              UUID(uuidString: threadID) != nil,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw CodexDesktopQueueError.invalidSource }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 64 * 1024) ?? Data()
        guard CodexSessionEventParser.header(header)?.threadID == threadID else { throw CodexDesktopQueueError.invalidSource }
        let size = try file.seekToEnd()
        try file.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        let tail = try file.readToEnd() ?? Data()
        guard tail.last == 10, let line = tail.split(separator: 10).last,
              let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "task_complete",
              let error = payload["error"] as? [String: Any], error["codex_error_info"] as? String == "usage_limit_exceeded",
              let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else {
            throw CodexDesktopQueueError.invalidSource
        }
        return .init(threadID: threadID, failedTurnID: turn, source: url, size: size,
                     fileID: inode.uint64Value, tail: tail)
    }

    func revalidate() throws {
        let latest = try Self.read(source, threadID: threadID)
        guard latest.failedTurnID == failedTurnID, latest.size == size, latest.fileID == fileID,
              latest.tail == tail else { throw CodexDesktopQueueError.invalidSource }
    }
}

/// Exclusive creation makes duplicate submissions fail closed across app instances and restarts.
/// Even an empty/corrupt attempt file is retained and blocks automatic retry.
struct CodexQueueAttemptStore {
    let directory: URL
    static let standard = Self(directory: CodexLocalPaths.checkpoint.deletingLastPathComponent().appendingPathComponent("queue-attempts"))
    func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    func reserve(_ target: CodexQueueTarget) throws -> FileHandle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(file(for: target.key).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw errno == EEXIST ? CodexDesktopQueueError.duplicate : .storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try record(handle, target: target, state: "attempting", messageID: nil); return handle }
        catch { try? handle.close(); throw error }
    }
    func record(_ handle: FileHandle, target: CodexQueueTarget, state: String, messageID: String?) throws {
        var record = ["threadID": target.threadID, "failedTurnID": target.failedTurnID, "state": state]
        if let messageID { record["queuedMessageID"] = messageID }
        let data = try JSONEncoder().encode(record)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }
}

enum CodexDesktopQueueSender {
    static func arguments(threadID: String) -> [String] {
        ["queue", "--thread", threadID, "--message", "继续"]
    }
    static func receipt(_ data: Data, threadID: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw CodexDesktopQueueError.uncertain }
        let lines = text.split(separator: "\n").map(String.init)
        guard lines.count == 1 else { throw CodexDesktopQueueError.uncertain }
        let words = lines[0].split(separator: " ").map(String.init)
        guard words.count == 6, words[0] == "Queued", words[1] == "message",
              UUID(uuidString: words[2]) != nil, words[3] == "for", words[4] == "thread",
              words[5] == threadID + "." else { throw CodexDesktopQueueError.uncertain }
        return words[2]
    }

    /// Runs on a background worker. Reads both pipes with bounded buffers; never logs stderr.
    /// Terminating this short-lived queue client does not cancel a message already enqueued.
    static func run(executable: URL, arguments: [String], home: URL, timeout: TimeInterval = 10) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable; process.arguments = arguments
        var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        defer {
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        }
        try process.run()
        try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles { _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var result = Data(), total = 0, ended = Set<Int>()
        while true {
            for (index, handle) in handles.enumerated() where !ended.contains(index) {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    total += count
                    guard total <= 256 * 1024 else { throw CodexDesktopQueueError.uncertain }
                    if index == 0 { result.append(contentsOf: bytes.prefix(count)) }
                } else if count == 0 { ended.insert(index) }
                else if errno != EAGAIN && errno != EINTR { throw CodexDesktopQueueError.uncertain }
            }
            if !process.isRunning && ended.count == 2 {
                guard process.terminationStatus == 0 else { throw CodexDesktopQueueError.process }
                return result
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexDesktopQueueError.uncertain }
            usleep(10_000)
        }
    }
}
