#if os(macOS)
import Foundation
import Testing
@testable import AgentMeterCore

// MARK: - 测试替身(文件作用域,避免 @Sendable 闭包捕获 self)

private struct FetchBoom: Error {}

private func sampleCreds(expired: Bool = false) -> KeychainReader.Credentials {
    KeychainReader.Credentials(
        accessToken: "token",
        expiresAt: expired ? Date(timeIntervalSince1970: 0) : nil
    )
}

private func sampleSnap(_ tool: ToolKind, confidence: DataConfidence = .fresh) -> QuotaSnapshot {
    QuotaSnapshot(
        tool: tool, plan: nil,
        windows: [QuotaWindow(usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 2_000_000_000), kind: .fiveHour)],
        confidence: confidence, source: "test",
        updatedAt: Date(timeIntervalSince1970: 1_000_000_000)
    )
}

private actor FakeStore: QuotaStore {
    private(set) var saved: [ToolKind: QuotaSnapshot] = [:]
    private let preset: [ToolKind: QuotaSnapshot]
    private let failSave: Bool

    init(preset: [ToolKind: QuotaSnapshot] = [:], failSave: Bool = false) {
        self.preset = preset
        self.failSave = failSave
    }
    func save(_ snapshot: QuotaSnapshot) async throws {
        if failSave { throw FetchBoom() }
        saved[snapshot.tool] = snapshot
    }
    func fetch(tool: ToolKind) async throws -> QuotaSnapshot? { preset[tool] }
    func savedSnapshot(_ tool: ToolKind) -> QuotaSnapshot? { saved[tool] }
    var savedCount: Int { saved.count }
}

// MARK: - 测试

struct QuotaCollectorTests {

    @Test func okSavesFreshSnapshot() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in sampleCreds() },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let result = await collector.collect(tool: .claudeCode)
        #expect(result.outcome == .ok)
        #expect(result.snapshot?.confidence == .fresh)
        #expect(await store.savedSnapshot(.claudeCode)?.confidence == .fresh)
    }

    @Test func skippedWhenCredentialsNotFound() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in throw KeychainReader.ReadError.notFound("svc") },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let result = await collector.collect(tool: .codex)
        #expect(result.outcome == .skipped)
        #expect(result.snapshot == nil)
        #expect(await store.savedCount == 0)
    }

    @Test func degradedMarksExistingStale() async {
        let store = FakeStore(preset: [.claudeCode: sampleSnap(.claudeCode)])
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in sampleCreds() },
            fetcher: { _, _ in throw FetchBoom() }
        )
        let result = await collector.collect(tool: .claudeCode)
        #expect(result.outcome == .degraded)
        #expect(result.snapshot?.confidence == .stale)
        #expect(result.snapshot?.staleReason == .unknownFailure)
        #expect(await store.savedSnapshot(.claudeCode)?.confidence == .stale)
    }

    @Test func degradedWritesUnknownWhenNoExisting() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in sampleCreds() },
            fetcher: { _, _ in throw FetchBoom() }
        )
        let result = await collector.collect(tool: .codex)
        #expect(result.outcome == .degraded)
        #expect(result.snapshot?.confidence == .unknown)
        #expect(result.snapshot?.staleReason == .unknownFailure)
    }

    @Test func expiredTokenDegradesWithoutFetching() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in sampleCreds(expired: true) },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let result = await collector.collect(tool: .claudeCode)
        #expect(result.outcome == .degraded)
        #expect(result.snapshot?.confidence == .unknown)
        #expect(result.snapshot?.staleReason == .authExpired)
    }

    @Test func credentialReadFailureUsesCredentialReason() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in throw KeychainReader.ReadError.osStatus(-1) },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let result = await collector.collect(tool: .claudeCode)
        #expect(result.outcome == .degraded)
        #expect(result.snapshot?.staleReason == .credentialReadFailed)
    }

    @Test func adapterErrorsMapToStaleReasons() {
        #expect(QuotaCollector.staleReason(for: ClaudeCodeAdapter.FetchError.unauthorized) == .authExpired)
        #expect(QuotaCollector.staleReason(for: CodexPlanAdapter.FetchError.unauthorized) == .authExpired)
        #expect(QuotaCollector.staleReason(for: ClaudeCodeAdapter.FetchError.transport("lost")) == .networkFailure)
        #expect(QuotaCollector.staleReason(for: CodexPlanAdapter.FetchError.transport("lost")) == .networkFailure)
        #expect(QuotaCollector.staleReason(for: ClaudeCodeAdapter.FetchError.httpStatus(500)) == .endpointFailure)
        #expect(QuotaCollector.staleReason(for: CodexPlanAdapter.FetchError.httpStatus(500)) == .endpointFailure)
        #expect(QuotaCollector.staleReason(for: ClaudeCodeAdapter.FetchError.decode("bad")) == .responseChanged)
        #expect(QuotaCollector.staleReason(for: CodexPlanAdapter.FetchError.decode("bad")) == .responseChanged)
        #expect(QuotaCollector.staleReason(for: FetchBoom()) == .unknownFailure)
    }

    @Test func writeFailureReportsWriteFailed() async {
        let store = FakeStore(failSave: true)
        let collector = QuotaCollector(
            store: store,
            credentials: { _ in sampleCreds() },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let result = await collector.collect(tool: .claudeCode)
        #expect(result.outcome == .writeFailed)
        #expect(result.snapshot?.confidence == .fresh)
    }

    @Test func collectAllReturnsPerToolResults() async {
        let store = FakeStore()
        let collector = QuotaCollector(
            store: store,
            credentials: { tool in
                if tool == .codex { return sampleCreds() }
                throw KeychainReader.ReadError.notFound("x")
            },
            fetcher: { tool, _ in sampleSnap(tool) }
        )
        let results = await collector.collectAll(tools: [.claudeCode, .codex])
        #expect(results.count == 2)
        #expect(results[0].outcome == .skipped)
        #expect(results[1].outcome == .ok)
    }
}
#endif
