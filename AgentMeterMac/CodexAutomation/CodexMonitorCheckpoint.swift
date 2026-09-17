import Foundation
import AgentMeterCore
import Darwin

struct CodexMonitorCheckpoint: Codable, Sendable, Equatable {
    struct Cursor: Codable, Sendable, Equatable {
        var fileID: UInt64
        var offset: UInt64
        var discardUntilNewline: Bool
        var threadID: String
        var projectName: String?
        var lastProgressAt: Date?
        var anchorDigest: String?
    }
    var version = 1
    var homePath: String
    var monitoringSince: Date
    var baselineComplete = false
    var cursors: [String: Cursor] = [:]
    var queue = CodexResumeQueue()
    var notifications: CodexResumeNotificationLedger?
}

/// One atomic file commits candidates and read offsets together. No transcript/partial-line data.
struct CodexMonitorCheckpointStore {
    let url: URL
    enum StoreError: Error { case invalid, writeFailed }

    func load() throws -> CodexMonitorCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4 * 1024 * 1024 else { throw StoreError.invalid }
        let checkpoint = try JSONDecoder().decode(CodexMonitorCheckpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == 1, checkpoint.cursors.count <= 200,
              checkpoint.queue.candidates.count <= 500,
              checkpoint.monitoringSince.timeIntervalSince1970.isFinite else { throw StoreError.invalid }
        return checkpoint
    }

    func save(_ checkpoint: CodexMonitorCheckpoint) throws {
        let data = try JSONEncoder().encode(checkpoint)
        guard data.count <= 4 * 1024 * 1024 else { throw StoreError.invalid }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StoreError.writeFailed
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        // POSIX rename atomically replaces the old checkpoint without exposing a permissive temp file.
        guard rename(temporary.path, url.path) == 0 else { throw StoreError.writeFailed }
    }
}

enum CodexLocalPaths {
    static var home: URL {
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        return configured.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    static var checkpoint: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentMeter/CodexAutomation/checkpoint.json")
    }
}
