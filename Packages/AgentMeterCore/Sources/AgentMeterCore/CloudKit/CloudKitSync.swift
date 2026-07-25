import Foundation
import CloudKit

/// CloudKit Private Database 的读写封装(项目核心文件之一),Mac / iPhone / Watch 共用。
///
/// - **写**(Mac agent):每 5 分钟覆盖写同一条固定 record,last-write-wins,不堆历史。
/// - **读**(iPhone / Watch):按固定 ID fetch;没有则返回 nil。
///
/// 容器标识符是构造参数,默认占位常量。**接真容器前必须改成你 Apple Developer 账号下
/// 真实的 iCloud 容器 ID**(在 Xcode 的 Signing & Capabilities → iCloud 里创建/选择)。
/// 不存 CKDatabase(非 Sendable),每次调用内部用 containerID 现取,保持本类型 Sendable。
public struct CloudKitSync: Sendable {

    /// iCloud 容器 ID。对应 app id `com.dothinker.app.agentmeter`。
    /// ⚠️ 必须和 Apple Developer 账号里注册的容器**完全一致**,否则签名失败。
    public static let defaultContainerIdentifier = "iCloud.com.dothinker.app.agentmeter"

    public let containerIdentifier: String

    public init(containerIdentifier: String = CloudKitSync.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    public enum SyncError: Error {
        /// 未登录 iCloud,或账号不可用。
        case accountUnavailable
        /// CloudKit 返回的其他错误。
        case cloudKit(Error)
        /// 映射失败(字段缺失/损坏)。
        case mapping(Error)
    }

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    // MARK: - 写

    /// 覆盖写某工具的 snapshot(last-write-wins)。
    ///
    /// **先直接 save 一条新 record**:全新/空容器首写会在 Development 环境即时建 schema,
    /// 不能先 fetch(record type 还不存在会被服务端拒)。若该 record 已存在会触发
    /// `.serverRecordChanged`,再取回服务端 record(带 change tag)覆盖字段重存。
    public func save(_ snapshot: QuotaSnapshot) async throws {
        try await save(snapshot, recordID: RecordMapping.recordID(for: snapshot.tool))
    }

    /// Writes one side of a dual-device provider without touching the other.
    public func save(_ snapshot: QuotaSnapshot, collector: QuotaCollectorDevice) async throws {
        let scoped = snapshot.collected(on: collector)
        try await save(scoped, recordID: RecordMapping.recordID(for: snapshot.tool, collector: collector))
    }

    private func save(_ snapshot: QuotaSnapshot, recordID id: CKRecord.ID) async throws {
        let db = privateDatabase

        let record = CKRecord(recordType: RecordMapping.recordType, recordID: id)
        do {
            try RecordMapping.apply(snapshot, to: record)
        } catch {
            throw SyncError.mapping(error)
        }

        do {
            _ = try await db.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // 已存在:取回服务端 record 复用其 change tag,覆盖字段后重存。
            do {
                let existing = try await db.record(for: id)
                try RecordMapping.apply(snapshot, to: existing)
                _ = try await db.save(existing)
            } catch let e as CKError {
                throw mapCKError(e)
            } catch {
                throw SyncError.mapping(error)
            }
        } catch let error as CKError {
            throw mapCKError(error)
        }
    }

    // MARK: - 读

    /// 读某工具最新 snapshot;还没有任何记录时返回 nil(而非抛错)。
    public func fetch(tool: ToolKind = .claudeCode) async throws -> QuotaSnapshot? {
        try await fetch(recordID: RecordMapping.recordID(for: tool))
    }

    /// Reads only the requested device record. It never falls back to another
    /// device, which is the contract used by the Mac and iPhone apps/widgets.
    public func fetch(tool: ToolKind, collector: QuotaCollectorDevice) async throws -> QuotaSnapshot? {
        try await fetch(recordID: RecordMapping.recordID(for: tool, collector: collector))
    }

    /// Watch policy: iPhone wins while its last successful fact is at most 48h
    /// old, even when it is marked stale. Only then may the Mac record be used.
    public func fetchForWatch(tool: ToolKind, now: Date = Date()) async throws -> QuotaSnapshot? {
        guard tool.supportsDeviceScopedSnapshots else { return try await fetch(tool: tool) }
        let phone: QuotaSnapshot?
        do {
            phone = try await fetch(tool: tool, collector: .iPhone)
        } catch let error as SyncError {
            if Self.shouldFallBackToMac(afterIPhoneError: error) {
                // A corrupt device-local record is not a valid iPhone fact.
                // Keep the Watch useful by trying the independent Mac record.
                phone = nil
            } else {
                throw error
            }
        }
        if let phone, !phone.isInactive(now: now) {
            return phone
        }
        let mac = try await fetch(tool: tool, collector: .mac)
        return WatchSnapshotSelection.choose(iPhone: phone, mac: mac, now: now)
    }

    /// Explicit disable/delete is scoped to one device. Missing records are a
    /// successful no-op.
    public func delete(tool: ToolKind, collector: QuotaCollectorDevice) async throws {
        let id = RecordMapping.recordID(for: tool, collector: collector)
        do {
            _ = try await privateDatabase.deleteRecord(withID: id)
        } catch let error as CKError where error.code == .unknownItem {
            return
        } catch let error as CKError {
            throw mapCKError(error)
        }
    }

    private func fetch(recordID id: CKRecord.ID) async throws -> QuotaSnapshot? {
        let db = privateDatabase

        let record: CKRecord
        do {
            record = try await db.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        } catch let error as CKError {
            throw mapCKError(error)
        }

        do {
            return try RecordMapping.snapshot(from: record)
        } catch {
            throw SyncError.mapping(error)
        }
    }

    private func mapCKError(_ error: CKError) -> SyncError {
        switch error.code {
        case .notAuthenticated, .managedAccountRestricted:
            return .accountUnavailable
        default:
            return .cloudKit(error)
        }
    }

    static func shouldFallBackToMac(afterIPhoneError error: SyncError) -> Bool {
        if case .mapping = error { return true }
        return false
    }
}

public enum WatchSnapshotSelection {
    public static func choose(iPhone: QuotaSnapshot?, mac: QuotaSnapshot?,
                              now: Date = Date()) -> QuotaSnapshot? {
        if let iPhone, !iPhone.isInactive(now: now) { return iPhone }
        return mac
    }
}
