import Foundation
import Darwin
import SQLite3

/// Keep Codex's database read-only, including when an idle WAL database has no sidecars.
enum CodexResumeIndexDatabase {
    static func read<T>(at url: URL, query: (OpaquePointer) throws -> T) throws -> T {
        if try journalsAbsent(at: url) { return try readCheckpoint(at: url, query: query) }
        do {
            return try withConnection(at: url, immutable: false, query: query)
        } catch let error as CodexDesktopAutoResume.Blocked where error.reason == .sessionIndexUnavailable {
            // The last writer can checkpoint and remove WAL between the existence check and open.
            guard try journalsAbsent(at: url) else { throw error }
            return try readCheckpoint(at: url, query: query)
        }
    }

    private static var unavailable: CodexDesktopAutoResume.Blocked { .init(reason: .sessionIndexUnavailable) }

    private static func journalsAbsent(at url: URL) throws -> Bool {
        for suffix in ["-wal", "-journal"] {
            var info = stat()
            if lstat(url.path + suffix, &info) == 0 { return false }
            guard errno == ENOENT else { throw unavailable }
        }
        return true
    }

    private static func readCheckpoint<T>(at url: URL, query: (OpaquePointer) throws -> T) throws -> T {
        do {
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw unavailable }
            let source = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? source.close() }
            let version = try FileVersion.read(fd: fd)

            func revalidate() throws {
                guard try journalsAbsent(at: url), try FileVersion.read(fd: fd) == version,
                      try FileVersion.read(url: url) == version else { throw unavailable }
            }
            try revalidate()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let snapshot = directory.appendingPathComponent("index.sqlite")
            guard FileManager.default.createFile(atPath: snapshot.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { throw unavailable }
            let output = try FileHandle(forWritingTo: snapshot)
            defer { try? output.close() }
            var remaining = version.size
            while remaining > 0 {
                let data = try source.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                guard !data.isEmpty else { throw unavailable }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
            try output.close()
            try revalidate()
            // Only our stable private copy is immutable. Never ignore WAL on the live database.
            let result = try withConnection(at: snapshot, immutable: true, query: query)
            try revalidate()
            return result
        } catch let error as CodexDesktopAutoResume.Blocked { throw error }
        catch { throw unavailable }
    }

    private static func withConnection<T>(at url: URL, immutable: Bool,
                                           query: (OpaquePointer) throws -> T) throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [.init(name: "mode", value: "ro")]
        if immutable { components?.queryItems?.append(.init(name: "immutable", value: "1")) }
        guard let uri = components?.string else { throw unavailable }
        var database: OpaquePointer?
        guard sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        return try query(database)
    }

    private struct FileVersion: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        private init(_ info: stat) throws {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw unavailable }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }

        static func read(fd: Int32) throws -> Self {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw unavailable }
            return try Self(info)
        }

        static func read(url: URL) throws -> Self {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw unavailable }
            return try Self(info)
        }
    }
}
