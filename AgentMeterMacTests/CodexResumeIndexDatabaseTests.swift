import Foundation
import XCTest
import SQLite3
@testable import AgentMeter

final class CodexResumeIndexDatabaseTests: XCTestCase {
    private enum QueryError: Error { case failed }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("index # \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state_5.sqlite")
        let writer = try openWriter(url)
        do {
            try execute(writer, "PRAGMA journal_mode = DELETE; CREATE TABLE flags (archived INTEGER); INSERT INTO flags VALUES (0); PRAGMA journal_mode = WAL")
        } catch { sqlite3_close(writer); throw error }
        XCTAssertEqual(sqlite3_close(writer), SQLITE_OK)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        return url
    }

    func testCheckpointSnapshotIsReadOnlyPrivateAndRemovedAfterUse() throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let snapshot = try CodexResumeIndexDatabase.read(at: url) { database -> URL in
            XCTAssertEqual(sqlite3_db_readonly(database, "main"), 1)
            XCTAssertEqual(try archived(database), 0)
            XCTAssertEqual(sqlite3_exec(database, "UPDATE flags SET archived = 1", nil, nil, nil), SQLITE_READONLY)
            let path = URL(fileURLWithPath: String(cString: try XCTUnwrap(sqlite3_db_filename(database, "main"))))
            XCTAssertNotEqual(path, url)
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let directory = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)
            XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            return path
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testLiveWALUpdatesAreNeverIgnored() throws {
        let url = try fixture()
        let writer = try openWriter(url)
        defer { sqlite3_close(writer) }
        try execute(writer, "UPDATE flags SET archived = 1")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path + "-wal")
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertEqual(try CodexResumeIndexDatabase.read(at: url) { try archived($0) }, 1)
    }

    func testNewWALDuringSnapshotQueryInvalidatesTheResult() throws {
        let url = try fixture()
        var writer: OpaquePointer?
        defer { if let writer { sqlite3_close(writer) } }
        assertUnavailable {
            try CodexResumeIndexDatabase.read(at: url) { database in
                let value = try self.archived(database)
                writer = try self.openWriter(url)
                try self.execute(try XCTUnwrap(writer), "UPDATE flags SET archived = 1")
                return value
            }
        }
        XCTAssertEqual(try CodexResumeIndexDatabase.read(at: url) { try archived($0) }, 1)
    }

    func testSourceReplacementDuringSnapshotQueryInvalidatesTheResult() throws {
        let url = try fixture()
        assertUnavailable {
            try CodexResumeIndexDatabase.read(at: url) { database in
                let saved = url.deletingLastPathComponent().appendingPathComponent("previous.sqlite")
                try FileManager.default.moveItem(at: url, to: saved)
                try FileManager.default.copyItem(at: saved, to: url)
                return try self.archived(database)
            }
        }
    }

    func testSnapshotIsRemovedWhenQueryFails() throws {
        let url = try fixture()
        var snapshot: URL?
        XCTAssertThrowsError(try CodexResumeIndexDatabase.read(at: url) { database -> Int in
            snapshot = URL(fileURLWithPath: String(cString: try XCTUnwrap(sqlite3_db_filename(database, "main"))))
            throw QueryError.failed
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(snapshot).deletingLastPathComponent().path))
    }

    func testMissingCorruptAndSymlinkSourcesFailClosed() throws {
        let url = try fixture()
        let alias = url.deletingLastPathComponent().appendingPathComponent("alias.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        assertUnavailable { try CodexResumeIndexDatabase.read(at: alias) { try self.archived($0) } }
        try Data("not a database".utf8).write(to: url)
        assertUnavailable { try CodexResumeIndexDatabase.read(at: url) { try self.archived($0) } }
        try FileManager.default.removeItem(at: url)
        assertUnavailable { try CodexResumeIndexDatabase.read(at: url) { try self.archived($0) } }
    }

    private func openWriter(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw QueryError.failed }
        do { try execute(database, "PRAGMA journal_mode = WAL"); return database }
        catch { sqlite3_close(database); throw error }
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw QueryError.failed }
    }

    private func archived(_ database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT archived FROM flags", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CodexDesktopAutoResume.Blocked(reason: .sessionIndexUnavailable) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QueryError.failed }
        return sqlite3_column_int(statement, 0)
    }

    private func assertUnavailable<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? CodexDesktopAutoResume.Blocked)?.reason, .sessionIndexUnavailable, file: file, line: line)
        }
    }
}
