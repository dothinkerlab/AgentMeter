import Foundation
import Testing
@testable import AgentMeterCore

struct RotatingFileLogTests {

    @Test func shouldRotateOnlyWhenNonEmptyAndOverLimit() {
        #expect(RotatingFileLog.shouldRotate(currentSize: 500, addingBytes: 600, maxBytes: 1000) == true)
        #expect(RotatingFileLog.shouldRotate(currentSize: 100, addingBytes: 100, maxBytes: 1000) == false)
        // 空文件永不轮转,保证哪怕单行超限也写得进去。
        #expect(RotatingFileLog.shouldRotate(currentSize: 0, addingBytes: 5000, maxBytes: 1000) == false)
    }

    @Test func appendsThenRotatesKeepingOneBackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-log-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("agent.log")
        let backup = url.appendingPathExtension("1")
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = RotatingFileLog(fileURL: url, maxBytes: 10)
        log.append("first")    // 6 bytes,空文件先写
        log.append("second")   // 触发轮转:first → agent.log.1,second 进新文件

        let current = try String(contentsOf: url, encoding: .utf8)
        let rotated = try String(contentsOf: backup, encoding: .utf8)
        #expect(current.contains("second"))
        #expect(!current.contains("first"))
        #expect(rotated.contains("first"))
    }
}
