import Foundation
import XCTest
@testable import AgentMeter

final class CodexSessionDiagnosticsTests: XCTestCase {
    private let quotaEvent = #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"failed","error":{"codexErrorInfo":"usageLimitExceeded"}}}}"#

    func testOnlyStructuredQuotaFailureCounts() {
        let records = [
            quotaEvent,
            #"{"type":"event_msg","payload":{"type":"error","codex_error_info":"usage_limit_exceeded"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"usage_limit_exceeded"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"usageLimitExceeded"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"usage_limit_exceeded"}}"#,
            #"{"type":"event_msg","payload":{"type":"error","message":"usage_limit_exceeded","codex_error_info":"serverOverloaded"}}"#,
            quotaEvent.replacingOccurrences(of: "failed", with: "completed"),
            quotaEvent.replacingOccurrences(of: "usageLimitExceeded", with: "sessionBudgetExceeded"),
            quotaEvent.replacingOccurrences(of: "thread-1", with: ""),
            quotaEvent.replacingOccurrences(of: "turn-1", with: "")
        ]
        var report = CodexSessionDiagnostics()
        CodexSessionDiagnosticScanner.inspect(Data((records.joined(separator: "\n") + "\n").utf8), report: &report)
        XCTAssertEqual(report.structuredQuotaErrors, 2)
        XCTAssertEqual(report.malformedLines, 0)
    }

    func testInvalidAndPartialRecordsAreNotErrors() {
        var report = CodexSessionDiagnostics()
        CodexSessionDiagnosticScanner.inspect(Data(("not json\n" + quotaEvent).utf8), report: &report)
        XCTAssertEqual(report.structuredQuotaErrors, 0)
        XCTAssertEqual(report.malformedLines, 1)
        XCTAssertEqual(report.incompleteLines, 1)
    }

    func testMissingDirectoryIsExplicit() throws {
        let home = try temporaryHome()
        let report = CodexSessionDiagnosticScanner(home: home).scan()
        XCTAssertFalse(report.sessionDirectoryAvailable)
        XCTAssertEqual(report.filesInspected, 0)
    }

    func testOnlyNewestFilesAreSampled() throws {
        let home = try temporaryHome()
        let old = try write(quotaEvent + "\n", name: "old.jsonl", home: home)
        let new = try write("{}\n", name: "new.jsonl", home: home)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: new.path)
        let report = CodexSessionDiagnosticScanner(home: home, fileLimit: 1).scan()
        XCTAssertEqual(report.filesInspected, 1)
        XCTAssertEqual(report.structuredQuotaErrors, 0)
    }

    func testBoundedTailRetainsRecordExactlyAtBoundary() throws {
        let home = try temporaryHome()
        let event = quotaEvent + "\n"
        _ = try write("{}\n" + event, name: "session.jsonl", home: home)
        let report = CodexSessionDiagnosticScanner(home: home, bytesPerFile: event.utf8.count).scan()
        XCTAssertEqual(report.filesTruncated, 1)
        XCTAssertEqual(report.structuredQuotaErrors, 1)
        XCTAssertEqual(report.malformedLines, 0)
    }

    func testTailDropsPartialLeadingRecord() throws {
        let home = try temporaryHome()
        _ = try write(quotaEvent + "\n{}\n", name: "session.jsonl", home: home)
        let report = CodexSessionDiagnosticScanner(home: home, bytesPerFile: 30).scan()
        XCTAssertEqual(report.filesTruncated, 1)
        XCTAssertEqual(report.structuredQuotaErrors, 0)
        XCTAssertEqual(report.malformedLines, 0)
    }

    func testOversizedSingleRecordDoesNotAllocateUnboundedData() throws {
        let home = try temporaryHome()
        _ = try write(String(repeating: "x", count: 4096), name: "session.jsonl", home: home)
        let report = CodexSessionDiagnosticScanner(home: home, bytesPerFile: 64).scan()
        XCTAssertEqual(report.filesInspected, 1)
        XCTAssertEqual(report.filesTruncated, 1)
        XCTAssertEqual(report.structuredQuotaErrors, 0)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        let home = try temporaryHome()
        let target = home.appendingPathComponent("external.jsonl")
        try Data((quotaEvent + "\n").utf8).write(to: target)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("link.jsonl"), withDestinationURL: target)
        XCTAssertEqual(CodexSessionDiagnosticScanner(home: home).scan().filesInspected, 0)
    }

    func testEnumerationLimitIsReported() throws {
        let home = try temporaryHome()
        _ = try write("{}\n", name: "a.jsonl", home: home)
        _ = try write("{}\n", name: "b.jsonl", home: home)
        let report = CodexSessionDiagnosticScanner(home: home, entryLimit: 1).scan()
        XCTAssertTrue(report.enumerationIncomplete)
        XCTAssertEqual(report.filesInspected, 1)
    }

    func testInspectionDoesNotChangeSourceFile() throws {
        let home = try temporaryHome()
        let file = try write(quotaEvent + "\n", name: "session.jsonl", home: home)
        let before = try Data(contentsOf: file)
        _ = CodexSessionDiagnosticScanner(home: home).scan()
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func write(_ text: String, name: String, home: URL) throws -> URL {
        let directory = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
