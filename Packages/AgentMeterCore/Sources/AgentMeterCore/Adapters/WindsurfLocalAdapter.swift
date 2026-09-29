#if os(macOS)
import Foundation
import SQLite3

public struct WindsurfLocalAdapter: Sendable {
    public static let source = "windsurf_local_sqlite"
    public enum FetchError: Error, Equatable { case notFound, database(Int32), decode }

    public init() {}

    public func fetch(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> QuotaSnapshot {
        let url = home.appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: url.path) else { throw FetchError.notFound }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let opened = sqlite3_open_v2(url.path, &db, flags, nil)
        guard opened == SQLITE_OK, let db else { if db != nil { sqlite3_close(db) }; throw FetchError.database(opened) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FetchError.database(sqlite3_errcode(db))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "windsurf.settings.cachedPlanInfo", -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
            throw FetchError.notFound
        }
        let data = Data(String(cString: bytes).utf8)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        return try parse(data: data, updatedAt: modified)
    }

    public func parse(data: Data, updatedAt: Date) throws -> QuotaSnapshot {
        guard let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw FetchError.decode
        }
        let value: Any
        if let encoded = decoded as? String,
           let nested = try? JSONSerialization.jsonObject(with: Data(encoded.utf8), options: [.fragmentsAllowed]) {
            value = nested
        } else {
            value = decoded
        }
        guard let root = value as? [String: Any] else { throw FetchError.decode }
        let plan = Self.string(root, keys: ["planName", "plan", "name"])
        let resetDaily = Self.date(root, keys: ["dailyQuotaResetAt", "dailyResetAt", "daily_reset_at"])
        let resetWeekly = Self.date(root, keys: ["weeklyQuotaResetAt", "weeklyResetAt", "weekly_reset_at"])
        var windows: [QuotaWindow] = []
        if let value = Self.number(root, keys: ["dailyQuotaUsedPercent", "dailyUsagePercent", "daily_quota_used_percent"]) {
            windows.append(.init(usedPercent: value, resetsAt: resetDaily, kind: .daily))
        }
        if let value = Self.number(root, keys: ["weeklyQuotaUsedPercent", "weeklyUsagePercent", "weekly_quota_used_percent"]) {
            windows.append(.init(usedPercent: value, resetsAt: resetWeekly, kind: .weekly))
        }
        if windows.isEmpty,
           let used = Self.number(root, keys: ["usedMessages"]),
           let total = Self.number(root, keys: ["messages"]), total > 0 {
            windows.append(.init(usedPercent: used / total * 100, resetsAt: nil, kind: .messages))
        }
        if !windows.contains(where: { $0.kind == .weekly }),
           let used = Self.number(root, keys: ["usedFlowActions"]),
           let total = Self.number(root, keys: ["flowActions"]), total > 0 {
            windows.append(.init(usedPercent: used / total * 100, resetsAt: nil, kind: .flowActions))
        }
        guard !windows.isEmpty else { throw FetchError.decode }
        return QuotaSnapshot(tool: .windsurf, plan: plan, windows: windows, confidence: .fresh,
                             source: Self.source, updatedAt: updatedAt)
    }

    private static func walk(_ value: Any, key: String) -> Any? {
        if let dict = value as? [String: Any] {
            if let found = dict[key] { return found }
            for child in dict.values { if let found = walk(child, key: key) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = walk(child, key: key) { return found } }
        }
        return nil
    }
    private static func number(_ root: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = walk(root, key: key) as? NSNumber { return number.doubleValue }
            if let text = walk(root, key: key) as? String, let value = Double(text) { return value }
        }
        return nil
    }
    private static func string(_ root: [String: Any], keys: [String]) -> String? {
        for key in keys { if let value = walk(root, key: key) as? String, !value.isEmpty { return value } }
        return nil
    }
    private static func date(_ root: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = walk(root, key: key) as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
            if let text = walk(root, key: key) as? String {
                if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
                if let value = ISO8601DateFormatter().date(from: text) { return value }
            }
        }
        return nil
    }
}
#endif
