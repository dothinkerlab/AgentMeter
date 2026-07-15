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
    public typealias ResetCreditsFetcher = @Sendable (KeychainReader.Credentials) async throws -> RateLimitResetCredits
    public typealias Logger = @Sendable (String) -> Void

    let store: any QuotaStore
    let credentials: CredentialsProvider
    let fetcher: SnapshotFetcher
    let resetCreditsFetcher: ResetCreditsFetcher
    let log: Logger

    public init(
        store: any QuotaStore = CloudKitSync(),
        credentials: @escaping CredentialsProvider = { try KeychainReader.readCredentials(tool: $0) },
        fetcher: @escaping SnapshotFetcher = QuotaCollector.defaultFetcher,
        resetCreditsFetcher: @escaping ResetCreditsFetcher = QuotaCollector.defaultResetCreditsFetcher,
        log: @escaping Logger = { _ in }
    ) {
        self.store = store
        self.credentials = credentials
        self.fetcher = fetcher
        self.resetCreditsFetcher = resetCreditsFetcher
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
            return await degrade(tool: tool, reason: .credentialReadFailed, logReason: "无法读取凭据")
        }

        if creds.isExpired {
            log("\(tag) ⚠️ token 已过期,需重新登录")
            return await degrade(tool: tool, reason: .authExpired, logReason: "token 过期")
        }

        if tool == .codex {
            return await collectCodex(credentials: creds)
        }

        let snapshot: QuotaSnapshot
        do {
            snapshot = try await fetcher(tool, creds)
        } catch {
            log("\(tag) ✗ 取数失败: \(error)")
            return await degrade(tool: tool, reason: Self.staleReason(for: error), logReason: "取数失败")
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

    /// Codex 的额度窗口与 banked resets 来自两个端点，必须分别容错后合并写一次。
    private func collectCodex(credentials creds: KeychainReader.Credentials) async -> Result {
        let existing: QuotaSnapshot?
        do {
            existing = try await store.fetch(tool: .codex)
        } catch {
            existing = nil
            log("[codex] ⚠️ 读取旧记录失败，附加状态无法使用缓存: \(error)")
        }

        async let quotaAttempt = captureSnapshotFetch(tool: .codex, credentials: creds)
        async let resetAttempt = captureResetCreditsFetch(credentials: creds)
        let (quotaResult, resetResult) = await (quotaAttempt, resetAttempt)

        let snapshot: QuotaSnapshot
        let primaryOutcome: Outcome
        switch quotaResult {
        case .success(let fresh):
            snapshot = fresh
            primaryOutcome = .ok
        case .failure(let error):
            let reason = Self.staleReason(for: error)
            snapshot = existing?.markedStale(reason: reason)
                ?? .unknown(tool: .codex, source: Self.source(for: .codex), reason: reason)
            primaryOutcome = .degraded
            log("[codex] ✗ 主额度取数失败，已独立降级: \(error)")
        }

        let resetCredits: RateLimitResetCredits
        switch resetResult {
        case .success(let fresh):
            resetCredits = fresh
        case .failure(let error):
            let reason = Self.staleReason(for: error)
            resetCredits = existing?.resetCredits?.markedStale(reason: reason)
                ?? .unknown(reason: reason)
            log("[codex] ⚠️ 可用重置取数失败，主额度不受影响: \(error)")
        }

        let combined = snapshot.replacingResetCredits(resetCredits)
        do {
            try await store.save(combined)
            log("[codex] ✓ 主额度与可用重置已合并写入")
            return Result(tool: .codex, outcome: primaryOutcome, snapshot: combined)
        } catch {
            log("[codex] ✗ 合并记录写入失败: \(error)")
            return Result(tool: .codex, outcome: .writeFailed, snapshot: combined)
        }
    }

    private func captureSnapshotFetch(
        tool: ToolKind,
        credentials: KeychainReader.Credentials
    ) async -> Swift.Result<QuotaSnapshot, Error> {
        do {
            return .success(try await fetcher(tool, credentials))
        } catch {
            return .failure(error)
        }
    }

    private func captureResetCreditsFetch(
        credentials: KeychainReader.Credentials
    ) async -> Swift.Result<RateLimitResetCredits, Error> {
        do {
            return .success(try await resetCreditsFetcher(credentials))
        } catch {
            return .failure(error)
        }
    }

    /// 降级:有旧记录翻 stale,没有写 unknown 占位。返回降级后的 snapshot 给 UI。
    private func degrade(tool: ToolKind, reason: QuotaStaleReason, logReason: String) async -> Result {
        let existing: QuotaSnapshot?
        do {
            existing = try await store.fetch(tool: tool)
        } catch {
            existing = nil
            log("  → 读取降级缓存失败: \(error)")
        }
        var degraded = existing?.markedStale(reason: reason)
            ?? .unknown(tool: tool, source: Self.source(for: tool), reason: reason)
        if tool == .codex {
            let resetCredits = existing?.resetCredits?.markedStale(reason: reason)
                ?? .unknown(reason: reason)
            degraded = degraded.replacingResetCredits(resetCredits)
        }
        do {
            try await store.save(degraded)
        } catch {
            log("  → 降级记录写入失败: \(error)")
            return Result(tool: tool, outcome: .writeFailed, snapshot: degraded)
        }
        log("  → 降级为 \(degraded.confidence.rawValue)(原因:\(logReason), staleReason:\(reason.rawValue))")
        return Result(tool: tool, outcome: .degraded, snapshot: degraded)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case ClaudeCodeAdapter.FetchError.unauthorized,
             CodexPlanAdapter.FetchError.unauthorized,
             CodexResetCreditsAdapter.FetchError.unauthorized,
             DeepSeekBalanceAdapter.FetchError.unauthorized,
             OpenRouterUsageAdapter.FetchError.unauthorized,
             GrokAPIUsageAdapter.FetchError.unauthorized:
            return .authExpired
        case ClaudeCodeAdapter.FetchError.transport,
             CodexPlanAdapter.FetchError.transport,
             CodexResetCreditsAdapter.FetchError.transport,
             DeepSeekBalanceAdapter.FetchError.transport,
             OpenRouterUsageAdapter.FetchError.transport,
             GrokAPIUsageAdapter.FetchError.transport:
            return .networkFailure
        case ClaudeCodeAdapter.FetchError.httpStatus,
             CodexPlanAdapter.FetchError.httpStatus,
             CodexResetCreditsAdapter.FetchError.httpStatus,
             DeepSeekBalanceAdapter.FetchError.httpStatus,
             OpenRouterUsageAdapter.FetchError.httpStatus,
             GrokAPIUsageAdapter.FetchError.httpStatus:
            return .endpointFailure
        case ClaudeCodeAdapter.FetchError.decode,
             CodexPlanAdapter.FetchError.decode,
             CodexResetCreditsAdapter.FetchError.decode,
             DeepSeekBalanceAdapter.FetchError.decode,
             OpenRouterUsageAdapter.FetchError.decode,
             GrokAPIUsageAdapter.FetchError.decode:
            return .responseChanged
        default:
            return .unknownFailure
        }
    }

    static func source(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode: return ClaudeCodeAdapter.source
        case .codex: return CodexPlanAdapter.source
        case .openCode: return "unsupported"
        case .deepSeek: return "deepseek_balance_endpoint"
        case .openRouter: return OpenRouterUsageAdapter.source
        case .grok: return GrokAPIUsageAdapter.source
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
        case .openCode, .deepSeek, .openRouter, .grok:
            throw UnsupportedTool(tool: tool)
        }
    }

    public static let defaultResetCreditsFetcher: ResetCreditsFetcher = { creds in
        try await CodexResetCreditsAdapter().fetch(
            accessToken: creds.accessToken,
            accountID: creds.accountID
        )
    }

    struct UnsupportedTool: Error { let tool: ToolKind }
}
#endif
