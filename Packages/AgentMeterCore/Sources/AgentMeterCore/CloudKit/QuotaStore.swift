import Foundation

/// `QuotaCollector` 读写 snapshot 的抽象。真实现是 `CloudKitSync`;
/// 单测用假实现注入,避免打真 CloudKit。
public protocol QuotaStore: Sendable {
    func save(_ snapshot: QuotaSnapshot) async throws
    func fetch(tool: ToolKind) async throws -> QuotaSnapshot?
}

extension CloudKitSync: QuotaStore {}
