#if os(macOS)
import Foundation

/// 逐工具采集编排(从旧 AgentMeterAgent/AgentMain 下沉)。
/// 读凭据 → 查过期 → 取数 → 写 store → 失败降级。一个工具失败不影响其它(容错铁律 2)。
/// 依赖通过闭包/协议注入,默认接真实实现,便于单测不打网络、不碰真 CloudKit。
public struct QuotaCollector: Sendable {

    public enum Outcome: Int, Sendable, Equatable {
        case ok = 0        // 取数并写入成功
        case skipped = 1   // 工具未配置(无凭据),跳过、不写占位
        case degraded = 2  // 取数失败,已降级为 stale/unknown
        case writeFailed = 3
    }

    public struct Result: Sendable, Equatable {
        public let tool: ToolKind
        public let outcome: Outcome
        /// 给 UI 显示:ok=fresh,degraded=stale/unknown,skipped=nil。
        public let snapshot: QuotaSnapshot?
    }

    public typealias CredentialsProvider = @Sendable (ToolKind) throws -> KeychainReader.Credentials
    public typealias SnapshotFetcher = @Sendable (ToolKind, KeychainReader.Credentials) async throws -> QuotaSnapshot
    public typealias Logger = @Sendable (String) -> Void

    let store: any QuotaStore
    let credentials: CredentialsProvider
    let fetcher: SnapshotFetcher
    let log: Logger

    public init(
        store: any QuotaStore = CloudKitSync(),
        credentials: @escaping CredentialsProvider = { try KeychainReader.readCredentials(tool: $0) },
        fetcher: @escaping SnapshotFetcher = QuotaCollector.defaultFetcher,
        log: @escaping Logger = { _ in }
    ) {
        self.store = store
        self.credentials = credentials
        self.fetcher = fetcher
        self.log = log
    }

    public func collectAll(tools: [ToolKind]) async -> [Result] {
        var results: [Result] = []
        for tool in tools {
            results.append(await collect(tool: tool))
        }
        return results
    }

    public func collect(tool: ToolKind) async -> Result {
        let tag = "[\(tool.rawValue)]"

        let creds: KeychainReader.Credentials
        do {
            creds = try credentials(tool)
        } catch KeychainReader.ReadError.notFound {
            log("\(tag) 未配置(没找到凭据),跳过")
            return Result(tool: tool, outcome: .skipped, snapshot: nil)
        } catch {
            log("\(tag) ✗ 读凭据失败: \(error)")
            return await degrade(tool: tool, reason: "无法读取凭据")
        }

        if creds.isExpired {
            log("\(tag) ⚠️ token 已过期,需重新登录")
            return await degrade(tool: tool, reason: "token 过期")
        }

        let snapshot: QuotaSnapshot
        do {
            snapshot = try await fetcher(tool, creds)
        } catch {
            log("\(tag) ✗ 取数失败: \(error)")
            return await degrade(tool: tool, reason: "取数失败")
        }

        do {
            try await store.save(snapshot)
            log("\(tag) ✓ 已写入")
            return Result(tool: tool, outcome: .ok, snapshot: snapshot)
        } catch {
            log("\(tag) ✗ 写入失败: \(error)")
            return Result(tool: tool, outcome: .writeFailed, snapshot: snapshot)
        }
    }

    /// 降级:有旧记录翻 stale,没有写 unknown 占位。返回降级后的 snapshot 给 UI。
    private func degrade(tool: ToolKind, reason: String) async -> Result {
        let existing = try? await store.fetch(tool: tool)
        let degraded = existing?.markedStale() ?? .unknown(tool: tool, source: Self.source(for: tool))
        try? await store.save(degraded)
        log("  → 降级为 \(degraded.confidence.rawValue)(原因:\(reason))")
        return Result(tool: tool, outcome: .degraded, snapshot: degraded)
    }

    static func source(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode: return ClaudeCodeAdapter.source
        case .codex: return CodexPlanAdapter.source
        case .openCode: return "unsupported"
        }
    }

    /// 默认取数:按工具走对应 adapter。
    public static let defaultFetcher: SnapshotFetcher = { tool, creds in
        switch tool {
        case .claudeCode:
            return try await ClaudeCodeAdapter().fetch(
                accessToken: creds.accessToken, plan: creds.subscriptionType)
        case .codex:
            return try await CodexPlanAdapter().fetch(
                accessToken: creds.accessToken, accountID: creds.accountID, plan: creds.subscriptionType)
        case .openCode:
            throw UnsupportedTool(tool: tool)
        }
    }

    struct UnsupportedTool: Error { let tool: ToolKind }
}
#endif
