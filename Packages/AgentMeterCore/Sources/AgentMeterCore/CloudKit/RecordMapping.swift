import Foundation
import CloudKit

/// `QuotaSnapshot` ⇄ `CKRecord` 的双向映射。
///
/// CloudKit 字段是扁平的,所以嵌套的 `windows` 序列化成一个 JSON string 字段
/// `windowsJSON` 存,读出来再 decode(TECHNICAL_DESIGN §3 / CLAUDE.md 代码风格)。
///
/// 每个工具用**固定 recordName**(如 `snapshot-claudeCode`),Mac agent 每次覆盖写同一条,
/// last-write-wins,不堆历史。
public enum RecordMapping {

    public static let recordType = "QuotaSnapshot"

    enum Field {
        static let tool = "tool"
        static let plan = "plan"
        static let windowsJSON = "windowsJSON"
        static let confidence = "confidence"
        static let staleReason = "staleReason"
        static let source = "source"
        static let updatedAt = "updatedAt"
    }

    public enum MappingError: Error, Equatable {
        case missingField(String)
        case badValue(String)
    }

    /// 某工具 snapshot 的固定 record ID。
    public static func recordID(for tool: ToolKind) -> CKRecord.ID {
        CKRecord.ID(recordName: "snapshot-\(tool.rawValue)")
    }

    // windows 的 JSON 编解码用 ISO8601 日期,跨端稳定、人也读得懂。
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 把 snapshot 的字段写进一条 record(新建或复用已有 record 都可传入)。
    /// 复用已有 record 是为了保留 server change tag,实现可靠的覆盖写。
    public static func apply(_ snapshot: QuotaSnapshot, to record: CKRecord) throws {
        record[Field.tool] = snapshot.tool.rawValue as CKRecordValue
        if let plan = snapshot.plan {
            record[Field.plan] = plan as CKRecordValue
        } else {
            record[Field.plan] = nil
        }
        let data = try makeEncoder().encode(snapshot.windows)
        guard let json = String(data: data, encoding: .utf8) else {
            throw MappingError.badValue("windows 无法编码为 UTF-8 JSON")
        }
        record[Field.windowsJSON] = json as CKRecordValue
        record[Field.confidence] = snapshot.confidence.rawValue as CKRecordValue
        if snapshot.confidence == .fresh {
            record[Field.staleReason] = nil
        } else {
            record[Field.staleReason] = snapshot.staleReason?.rawValue as CKRecordValue?
        }
        record[Field.source] = snapshot.source as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
    }

    /// 新建一条带固定 ID、已填好字段的 record。
    public static func makeRecord(from snapshot: QuotaSnapshot) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(for: snapshot.tool))
        try apply(snapshot, to: record)
        return record
    }

    /// 从 record 还原 snapshot。任一关键字段缺失/损坏即抛错,绝不静默编造默认值。
    public static func snapshot(from record: CKRecord) throws -> QuotaSnapshot {
        guard let toolRaw = record[Field.tool] as? String else {
            throw MappingError.missingField(Field.tool)
        }
        guard let tool = ToolKind(rawValue: toolRaw) else {
            throw MappingError.badValue("未知 tool: \(toolRaw)")
        }
        guard let json = record[Field.windowsJSON] as? String,
              let data = json.data(using: .utf8) else {
            throw MappingError.missingField(Field.windowsJSON)
        }
        let windows: [QuotaWindow]
        do {
            windows = try makeDecoder().decode([QuotaWindow].self, from: data)
        } catch {
            throw MappingError.badValue("windowsJSON 解析失败: \(error)")
        }
        guard let confidenceRaw = record[Field.confidence] as? String,
              let confidence = DataConfidence(rawValue: confidenceRaw) else {
            throw MappingError.missingField(Field.confidence)
        }
        let staleReason = (record[Field.staleReason] as? String).flatMap(QuotaStaleReason.init(rawValue:))
        guard let source = record[Field.source] as? String else {
            throw MappingError.missingField(Field.source)
        }
        guard let updatedAt = record[Field.updatedAt] as? Date else {
            throw MappingError.missingField(Field.updatedAt)
        }
        let plan = record[Field.plan] as? String

        return QuotaSnapshot(
            tool: tool,
            plan: plan,
            windows: windows,
            confidence: confidence,
            staleReason: staleReason,
            source: source,
            updatedAt: updatedAt
        )
    }
}
