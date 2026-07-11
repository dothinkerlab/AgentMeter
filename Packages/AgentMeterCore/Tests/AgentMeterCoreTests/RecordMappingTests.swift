import Foundation
import CloudKit
import Testing
@testable import AgentMeterCore

struct RecordMappingTests {

    private func sampleSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claudeCode,
            plan: "Max 5x",
            windows: [
                QuotaWindow(usedPercent: 37, resetsAt: Date(timeIntervalSince1970: 1_750_000_000), kind: .fiveHour),
                QuotaWindow(usedPercent: 26, resetsAt: Date(timeIntervalSince1970: 1_750_400_000), kind: .sevenDay),
            ],
            confidence: .fresh,
            source: "oauth_usage_endpoint",
            updatedAt: Date(timeIntervalSince1970: 1_749_900_000)
        )
    }

    @Test func roundTripsThroughCKRecord() throws {
        let original = sampleSnapshot()
        let record = try RecordMapping.makeRecord(from: original)
        let restored = try RecordMapping.snapshot(from: record)
        #expect(restored == original)
    }

    @Test func usesFixedRecordNamePerTool() throws {
        let record = try RecordMapping.makeRecord(from: sampleSnapshot())
        #expect(record.recordID.recordName == "snapshot-claudeCode")
        #expect(record.recordType == "QuotaSnapshot")
    }

    @Test func codexUsesItsOwnFixedRecordName() throws {
        let snap = QuotaSnapshot(tool: .codex, plan: "Plus", windows: [],
                                 confidence: .fresh, source: "codex_plan_usage_endpoint",
                                 updatedAt: Date(timeIntervalSince1970: 1_749_900_000))
        let record = try RecordMapping.makeRecord(from: snap)
        #expect(record.recordID.recordName == "snapshot-codex")
        #expect(try RecordMapping.snapshot(from: record) == snap)
    }

    @Test func windowsAreStoredAsJSONStringField() throws {
        let record = try RecordMapping.makeRecord(from: sampleSnapshot())
        let json = try #require(record["windowsJSON"] as? String)
        #expect(json.contains("fiveHour"))
        // 嵌套 windows 不能是 CKRecord 的原生数组字段,必须是序列化后的 string。
        #expect(record["windows"] == nil)
    }

    @Test func nilPlanRoundTrips() throws {
        var snap = sampleSnapshot()
        snap = QuotaSnapshot(tool: snap.tool, plan: nil, windows: snap.windows,
                             confidence: snap.confidence, source: snap.source, updatedAt: snap.updatedAt)
        let restored = try RecordMapping.snapshot(from: try RecordMapping.makeRecord(from: snap))
        #expect(restored.plan == nil)
    }

    @Test func staleReasonRoundTripsWhenPresent() throws {
        let snap = QuotaSnapshot(tool: .codex, plan: "Plus", windows: [],
                                 confidence: .stale, staleReason: .networkFailure,
                                 source: "codex_plan_usage_endpoint",
                                 updatedAt: Date(timeIntervalSince1970: 1_749_900_000))
        let record = try RecordMapping.makeRecord(from: snap)
        #expect(record["staleReason"] as? String == "networkFailure")
        #expect(try RecordMapping.snapshot(from: record) == snap)
    }

    @Test func freshSnapshotClearsStaleReasonField() throws {
        let snap = sampleSnapshot()
        let record = try RecordMapping.makeRecord(from: snap)
        #expect(record["staleReason"] == nil)
        #expect(try RecordMapping.snapshot(from: record).staleReason == nil)
    }

    @Test func missingStaleReasonFieldKeepsOldRecordsCompatible() throws {
        let snap = QuotaSnapshot(tool: .codex, plan: "Plus", windows: [],
                                 confidence: .stale, staleReason: .networkFailure,
                                 source: "codex_plan_usage_endpoint",
                                 updatedAt: Date(timeIntervalSince1970: 1_749_900_000))
        let record = try RecordMapping.makeRecord(from: snap)
        record["staleReason"] = nil
        let restored = try RecordMapping.snapshot(from: record)
        #expect(restored.confidence == .stale)
        #expect(restored.staleReason == nil)
    }

    @Test func missingToolFieldThrows() {
        let record = CKRecord(recordType: RecordMapping.recordType,
                              recordID: RecordMapping.recordID(for: .claudeCode))
        #expect(throws: RecordMapping.MappingError.self) {
            try RecordMapping.snapshot(from: record)
        }
    }

    @Test func emptyWindowsRoundTrips() throws {
        let snap = QuotaSnapshot(tool: .claudeCode, plan: nil, windows: [],
                                 confidence: .unknown, source: "oauth_usage_endpoint",
                                 updatedAt: Date(timeIntervalSince1970: 1_749_900_000))
        let restored = try RecordMapping.snapshot(from: try RecordMapping.makeRecord(from: snap))
        #expect(restored == snap)
    }
}
