import Foundation
import AppKit
import ServiceManagement
import AgentMeterCore

struct DeviceCodingCollectedValue: Sendable {
    let snapshot: QuotaSnapshot
    let cloudSync: DeviceCodingCloudSyncState
}

enum DeviceCodingProviderCollectionResult: Sendable {
    case collected(DeviceCodingCollectedValue, generation: UInt64)
    case unavailable(ToolKind, generation: UInt64)
    case superseded(ToolKind, generation: UInt64)

    var tool: ToolKind {
        switch self {
        case .collected(let value, _): value.snapshot.tool
        case .unavailable(let tool, _), .superseded(let tool, _): tool
        }
    }

    var generation: UInt64 {
        switch self {
        case .collected(_, let generation),
             .unavailable(_, let generation),
             .superseded(_, let generation):
            generation
        }
    }
}

struct DeviceCodingCollectionBatch: Sendable {
    let results: [DeviceCodingProviderCollectionResult]
}

struct DeviceCodingCollectionState: Sendable {
    let snapshots: [QuotaSnapshot]
    let cloudSyncPendingTools: Set<ToolKind>

    static func merging(
        currentSnapshots: [QuotaSnapshot],
        currentPendingTools: Set<ToolKind>,
        batch: DeviceCodingCollectionBatch,
        activeTools: Set<ToolKind>,
        latestGenerations: [ToolKind: UInt64]
    ) -> Self {
        var snapshotsByTool: [ToolKind: QuotaSnapshot] = [:]
        for snapshot in currentSnapshots where activeTools.contains(snapshot.tool) {
            snapshotsByTool[snapshot.tool] = snapshot
        }
        var pendingTools = currentPendingTools.intersection(activeTools)

        for result in batch.results {
            guard activeTools.contains(result.tool) else { continue }
            guard latestGenerations[result.tool] == result.generation else {
                // A later request owns this provider, even when this batch
                // finished fetching it before the later request began.
                continue
            }
            switch result {
            case .collected(let value, _):
                snapshotsByTool[value.snapshot.tool] = value.snapshot
                if value.cloudSync == .pending {
                    pendingTools.insert(value.snapshot.tool)
                } else {
                    pendingTools.remove(value.snapshot.tool)
                }
            case .unavailable(let tool, _):
                snapshotsByTool.removeValue(forKey: tool)
                pendingTools.remove(tool)
            case .superseded:
                // A later per-provider request owns this tool. Preserve the
                // state it may already have published.
                break
            }
        }

        return Self(
            snapshots: MacCodingProviderPreferences.tools.compactMap { snapshotsByTool[$0] },
            cloudSyncPendingTools: pendingTools
        )
    }
}

/// 菜单栏 app 的运行时大脑:启动即采、每 2 分钟采(额度 < 10% 时 1 分钟)、唤醒补采;登录项开关;状态供 UI/菜单栏 label 用。
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var results: [QuotaCollector.Result] = []
    @Published private(set) var lastCollectedAt: Date?
    @Published private(set) var isCollecting = false
    @Published private(set) var loginItemEnabled = false
    /// DeepSeek 余额(旁路采集,不入 CloudKit/QuotaSnapshot 体系)。
    /// 缺 API key 时为 nil;取数失败时翻 stale(若有旧值)或 unknown(无旧值)。
    @Published private(set) var deepSeekBalance: DeepSeekBalance?
    /// OpenRouter 当前 key 用量(本地旁路,不入 CloudKit/Watch)。
    @Published private(set) var openRouterUsage: OpenRouterUsage?
    /// xAI API 团队账单(本地旁路,不入 CloudKit/Watch)。
    @Published private(set) var grokAPIUsage: GrokAPIUsage?
    @Published private(set) var kimiAPIBalance: KimiAPIBalance?
    @Published private(set) var openAIAPIUsage: APICostUsage?
    @Published private(set) var anthropicAPIUsage: APICostUsage?
    @Published private(set) var deviceCodingSnapshots: [QuotaSnapshot] = []
    @Published private(set) var deviceCodingCloudSyncPendingTools: Set<ToolKind> = []
    @Published private(set) var displayOrder: [MacDisplayItemID]
    @Published private(set) var hiddenDisplayItems: Set<MacDisplayItemID>
    @Published var toolDisplayOrder: String {
        didSet { defaults.set(toolDisplayOrder, forKey: Self.toolDisplayOrderKey) }
    }
    @Published var showsStatusPercentage: Bool {
        didSet { defaults.set(showsStatusPercentage, forKey: Self.showsStatusPercentageKey) }
    }
    @Published var hidesInactiveTools: Bool {
        didSet { defaults.set(hidesInactiveTools, forKey: Self.hidesInactiveToolsKey) }
    }
    @Published var showsChatGPTOnMain: Bool {
        didSet {
            MainToolVisibilityPreferences.setVisible(
                showsChatGPTOnMain, for: .codex, defaults: defaults
            )
        }
    }
    @Published var showsClaudeOnMain: Bool {
        didSet {
            MainToolVisibilityPreferences.setVisible(
                showsClaudeOnMain, for: .claudeCode, defaults: defaults
            )
        }
    }
    @Published var fiveHourResetNotificationsEnabled: Bool {
        didSet {
            defaults.set(fiveHourResetNotificationsEnabled, forKey: Self.fiveHourResetNotificationsKey)
            Task { await handleFiveHourResetNotificationSettingChange(fiveHourResetNotificationsEnabled) }
        }
    }

    static let defaultInterval: TimeInterval = 2 * 60
    static let lowQuotaInterval: TimeInterval = 1 * 60
    static let lowQuotaThreshold: Double = 10
    static let staleThreshold: TimeInterval = 15 * 60
    static let legacyTools: [ToolKind] = AgentToolSelection.defaultTools
    static let tools: [ToolKind] = legacyTools + MacCodingProviderPreferences.tools
    private static let toolDisplayOrderKey = "toolDisplayOrder"
    private static let showsStatusPercentageKey = "macShowsStatusPercentage"
    private static let hidesInactiveToolsKey = "hideInactiveTools"
    private static let fiveHourResetNotificationsKey = "fiveHourResetNotificationsEnabled"

    private let collector: QuotaCollector
    private let defaults: UserDefaults
    private let resetNotificationScheduler: FiveHourResetNotificationScheduling
    private let cloudKitDeletionCoordinator: MacPendingCloudKitDeletionCoordinator
    private var loopTask: Task<Void, Never>?
    private var started = false
    private var deepSeekRequestGate = DeepSeekRequestGate()
    private var openRouterRequestGate = OpenRouterRequestGate()
    private var grokRequestGate = GrokRequestGate()
    private var kimiAPIRequestGate = KimiAPIRequestGate()
    private var openAIAPIRequestGate = APICostRequestGate()
    private var anthropicAPIRequestGate = APICostRequestGate()
    private var deviceCodingRequestGate = DeviceCodingRequestGate()
    private var deviceCodingPublishGenerations: [ToolKind: UInt64] = [:]

    init(
        defaults: UserDefaults = .standard,
        resetNotificationScheduler: FiveHourResetNotificationScheduling = FiveHourResetNotificationScheduler()
    ) {
        self.defaults = defaults
        self.resetNotificationScheduler = resetNotificationScheduler
        self.cloudKitDeletionCoordinator = MacPendingCloudKitDeletionCoordinator(defaults: defaults)
        let legacyOrder = defaults.string(forKey: Self.toolDisplayOrderKey) ?? ""
        toolDisplayOrder = legacyOrder
        displayOrder = MacDisplayPreferences.order(defaults: defaults, legacyToolOrder: legacyOrder)
        var migratedHidden = MacDisplayPreferences.hidden(defaults: defaults)
        if defaults.object(forKey: MacDisplayPreferences.hiddenKey) == nil {
            if !MainToolVisibilityPreferences.isVisible(.codex, defaults: defaults) { migratedHidden.insert(.codex) }
            if !MainToolVisibilityPreferences.isVisible(.claudeCode, defaults: defaults) { migratedHidden.insert(.claudeCode) }
        }
        hiddenDisplayItems = migratedHidden
        showsStatusPercentage = defaults.object(forKey: Self.showsStatusPercentageKey) as? Bool ?? true
        hidesInactiveTools = defaults.object(forKey: Self.hidesInactiveToolsKey) as? Bool ?? true
        showsChatGPTOnMain = MainToolVisibilityPreferences.isVisible(.codex, defaults: defaults)
        showsClaudeOnMain = MainToolVisibilityPreferences.isVisible(.claudeCode, defaults: defaults)
        fiveHourResetNotificationsEnabled = defaults.object(forKey: Self.fiveHourResetNotificationsKey) as? Bool ?? false
        let fileLog = RotatingFileLog(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/AgentMeter/agent.log"))
        collector = QuotaCollector(log: { message in
            let ts = ISO8601DateFormatter().string(from: Date())
            fileLog.append("[\(ts)] \(message)")
        })
        loginItemEnabled = (SMAppService.mainApp.status == .enabled)
    }

    /// 由 AppDelegate 在启动完成时调一次:订阅唤醒 + 开启定时采集循环。
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            await self?.resumePendingCloudKitDeletions()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.collectNow() }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectNow()
                let interval = self?.nextCollectionInterval() ?? Self.defaultInterval
                // `try?` 是有意为之:取消时 sleep 抛 CancellationError 被吞掉,
                // 下一轮 `while` 读到 isCancelled==true 干净退出。别改成 `try`。
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func collectNow() async {
        // Claude/Codex 正在采集时仍刷新 DeepSeek。设置页保存/删除 key 会触发这里,
        // 不能因全局采集锁而丢掉这次旁路刷新。
        if isCollecting {
            async let coding: Void = collectCurrentDeviceCodingProviders()
            async let deepSeek: Void = collectDeepSeek()
            async let openRouter: Void = collectOpenRouter()
            async let grok: Void = collectGrok()
            async let kimiAPI: Void = collectKimiAPI()
            async let openAIAPI: Void = collectOpenAIAPI()
            async let anthropicAPI: Void = collectAnthropicAPI()
            _ = await (coding, deepSeek, openRouter, grok, kimiAPI, openAIAPI, anthropicAPI)
            return
        }
        isCollecting = true
        async let legacyResults = collector.collectAll(tools: Self.legacyTools)
        async let coding: Void = collectCurrentDeviceCodingProviders()
        // 本地旁路与 Claude/Codex、设备 Coding providers 互不依赖，首轮同时启动。
        async let deepSeek: Void = collectDeepSeek()
        async let openRouter: Void = collectOpenRouter()
        async let grok: Void = collectGrok()
        async let kimiAPI: Void = collectKimiAPI()
        async let openAIAPI: Void = collectOpenAIAPI()
        async let anthropicAPI: Void = collectAnthropicAPI()
        results = await legacyResults
        _ = await (coding, deepSeek, openRouter, grok, kimiAPI, openAIAPI, anthropicAPI)
        lastCollectedAt = Date()
        isCollecting = false
        if fiveHourResetNotificationsEnabled {
            await resetNotificationScheduler.scheduleResetAlerts(for: snapshots)
        }
    }

    /// 基于刚采集到的 snapshots 决定下一轮采集间隔:
    /// 剩余额度 < 10% 用 1 分钟,否则默认 2 分钟。
    /// 数据陈旧不提速(架构铁律 2/4:不可靠数据不参与调度决策)。
    private func nextCollectionInterval() -> TimeInterval {
        guard let s = preferredSnapshot,
              !isStale(s),
              let w = preferredStatusWindow(in: s) else {
            return Self.defaultInterval
        }
        return w.remainingPercent < Self.lowQuotaThreshold
            ? Self.lowQuotaInterval
            : Self.defaultInterval
    }

    /// DeepSeek 余额采集编排:读 Keychain API key → 调端点 → 失败时保留旧值翻 stale 或写 unknown。
    /// 与 Claude/Codex 路径相互独立(铁律 2 容错):DeepSeek 失败不影响其余工具展示。
    private func collectDeepSeek() async {
        let requestGeneration = deepSeekRequestGate.begin()
        let apiKey: String
        do {
            guard let key = try DeepSeekKeyStore.read(), !key.isEmpty else {
                guard deepSeekRequestGate.isCurrent(requestGeneration) else { return }
                deepSeekBalance = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.deepSeek, credentialExists: true) else {
                guard deepSeekRequestGate.isCurrent(requestGeneration) else { return }
                deepSeekBalance = nil
                return
            }
            apiKey = key
        } catch {
            guard deepSeekRequestGate.isCurrent(requestGeneration) else { return }
            deepSeekBalance = .degraded(
                from: deepSeekBalance,
                reason: .credentialReadFailed
            )
            return
        }

        do {
            let fetchedBalance = try await DeepSeekBalanceAdapter().fetch(apiKey: apiKey)
            guard deepSeekRequestGate.isCurrent(requestGeneration) else { return }
            deepSeekBalance = fetchedBalance
        } catch {
            guard deepSeekRequestGate.isCurrent(requestGeneration) else { return }
            let reason = DeepSeekBalanceAdapter.staleReason(for: error)
            deepSeekBalance = .degraded(from: deepSeekBalance, reason: reason)
        }
    }

    /// OpenRouter 本地旁路采集。普通 API key 只发送给 OpenRouter 官方 `/api/v1/key`。
    private func collectOpenRouter() async {
        let requestGeneration = openRouterRequestGate.begin()
        let apiKey: String
        do {
            guard let key = try OpenRouterKeyStore.read(), !key.isEmpty else {
                guard openRouterRequestGate.isCurrent(requestGeneration) else { return }
                openRouterUsage = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.openRouter, credentialExists: true) else {
                guard openRouterRequestGate.isCurrent(requestGeneration) else { return }
                openRouterUsage = nil
                return
            }
            apiKey = key
        } catch {
            guard openRouterRequestGate.isCurrent(requestGeneration) else { return }
            openRouterUsage = .degraded(from: openRouterUsage, reason: .credentialReadFailed)
            return
        }

        do {
            let fetched = try await OpenRouterUsageAdapter().fetch(apiKey: apiKey)
            guard openRouterRequestGate.isCurrent(requestGeneration) else { return }
            openRouterUsage = fetched
        } catch {
            guard openRouterRequestGate.isCurrent(requestGeneration) else { return }
            openRouterUsage = .degraded(
                from: openRouterUsage,
                reason: OpenRouterUsageAdapter.staleReason(for: error)
            )
        }
    }

    /// xAI API 团队账单旁路。Management Key 与 Team ID 只从本机 Keychain 读取。
    private func collectGrok() async {
        let requestGeneration = grokRequestGate.begin()
        let credentials: GrokManagementCredentials
        do {
            guard let stored = try GrokManagementKeyStore.read(),
                  !stored.managementKey.isEmpty,
                  !stored.teamID.isEmpty else {
                guard grokRequestGate.isCurrent(requestGeneration) else { return }
                grokAPIUsage = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.xAI, credentialExists: true) else {
                guard grokRequestGate.isCurrent(requestGeneration) else { return }
                grokAPIUsage = nil
                return
            }
            credentials = stored
        } catch {
            guard grokRequestGate.isCurrent(requestGeneration) else { return }
            grokAPIUsage = .degraded(from: grokAPIUsage, reason: .credentialReadFailed)
            return
        }

        do {
            let fetched = try await GrokAPIUsageAdapter().fetch(credentials: credentials)
            guard grokRequestGate.isCurrent(requestGeneration) else { return }
            grokAPIUsage = fetched
        } catch {
            guard grokRequestGate.isCurrent(requestGeneration) else { return }
            grokAPIUsage = .degraded(
                from: grokAPIUsage,
                reason: GrokAPIUsageAdapter.staleReason(for: error)
            )
        }
    }

    private func collectDeviceCodingProviders() async -> DeviceCodingCollectionBatch {
        let collector = DeviceCodingQuotaCollector(device: .mac)
        let enabledTools = Set(
            MacCodingProviderPreferences.tools.filter {
                MacCodingProviderPreferences.isEnabled($0)
            }
        )
        let results = await withTaskGroup(
            of: DeviceCodingProviderCollectionResult.self,
            returning: [DeviceCodingProviderCollectionResult].self
        ) { group in
            for tool in enabledTools {
                group.addTask { await self.collectDeviceCodingProvider(tool, collector: collector) }
            }
            var values: [DeviceCodingProviderCollectionResult] = []
            for await value in group { values.append(value) }
            return values
        }
        return DeviceCodingCollectionBatch(results: results)
    }

    private func collectCurrentDeviceCodingProviders() async {
        let generation = deviceCodingRequestGate.begin()
        let batch = await collectDeviceCodingProviders()
        guard deviceCodingRequestGate.isCurrent(generation) else { return }
        let activeTools = Set(
            MacCodingProviderPreferences.tools.filter {
                MacCodingProviderPreferences.isEnabled($0)
            }
        )
        let merged = DeviceCodingCollectionState.merging(
            currentSnapshots: deviceCodingSnapshots,
            currentPendingTools: deviceCodingCloudSyncPendingTools,
            batch: batch,
            activeTools: activeTools,
            latestGenerations: deviceCodingPublishGenerations
        )
        deviceCodingSnapshots = merged.snapshots
        deviceCodingCloudSyncPendingTools = merged.cloudSyncPendingTools
    }

    private func collectDeviceCodingProvider(
        _ tool: ToolKind,
        collector: DeviceCodingQuotaCollector = DeviceCodingQuotaCollector(device: .mac)
    ) async -> DeviceCodingProviderCollectionResult {
        let publishGeneration = beginDeviceCodingPublishRequest(for: tool)
        do {
            guard let credential = try MacCodingCredentialResolver.resolve(
                tool: tool, manualRegion: MacCodingProviderPreferences.region(tool)
            ) else { return .unavailable(tool, generation: publishGeneration) }
            switch await collector.refresh(tool: tool, credential: credential) {
            case .snapshot(let snapshot, let cloudSync):
                return .collected(
                    DeviceCodingCollectedValue(snapshot: snapshot, cloudSync: cloudSync),
                    generation: publishGeneration
                )
            case .superseded:
                return .superseded(tool, generation: publishGeneration)
            }
        } catch {
            switch await collector.credentialReadFailed(tool: tool) {
            case .snapshot(let snapshot, let cloudSync):
                return .collected(
                    DeviceCodingCollectedValue(snapshot: snapshot, cloudSync: cloudSync),
                    generation: publishGeneration
                )
            case .superseded:
                return .superseded(tool, generation: publishGeneration)
            }
        }
    }

    private func beginDeviceCodingPublishRequest(for tool: ToolKind) -> UInt64 {
        deviceCodingPublishGenerations[tool, default: 0] &+= 1
        return deviceCodingPublishGenerations[tool, default: 0]
    }

    private func collectKimiAPI() async {
        let generation = kimiAPIRequestGate.begin()
        let region = ManualProviderPreferences.region(for: .kimiAPI, defaults: defaults)
        let key: String
        do {
            guard let stored = try ProviderCredentialStore.read(kind: .kimiAPI), !stored.isEmpty else {
                guard kimiAPIRequestGate.isCurrent(generation) else { return }
                kimiAPIBalance = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.kimiAPI, credentialExists: true, defaults: defaults) else {
                guard kimiAPIRequestGate.isCurrent(generation) else { return }
                kimiAPIBalance = nil
                return
            }
            key = stored
        } catch {
            guard kimiAPIRequestGate.isCurrent(generation) else { return }
            kimiAPIBalance = .degraded(from: kimiAPIBalance, region: region, reason: .credentialReadFailed)
            return
        }
        do {
            let fetched = try await KimiAPIBalanceAdapter(region: region).fetch(apiKey: key)
            guard kimiAPIRequestGate.isCurrent(generation) else { return }
            kimiAPIBalance = fetched
        } catch {
            guard kimiAPIRequestGate.isCurrent(generation) else { return }
            kimiAPIBalance = .degraded(from: kimiAPIBalance, region: region,
                                       reason: KimiAPIBalanceAdapter.staleReason(for: error))
        }
    }

    private func collectOpenAIAPI() async {
        let generation = openAIAPIRequestGate.begin()
        let key: String
        do {
            guard let stored = try ProviderCredentialStore.read(kind: .openAIAdmin), !stored.isEmpty else {
                guard openAIAPIRequestGate.isCurrent(generation) else { return }
                openAIAPIUsage = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.openAIAPI, credentialExists: true, defaults: defaults) else {
                guard openAIAPIRequestGate.isCurrent(generation) else { return }
                openAIAPIUsage = nil
                return
            }
            key = stored
        } catch {
            guard openAIAPIRequestGate.isCurrent(generation) else { return }
            openAIAPIUsage = .degraded(
                from: openAIAPIUsage,
                source: OpenAIAPICostAdapter.source,
                reason: .credentialReadFailed
            )
            return
        }
        do {
            let fetched = try await OpenAIAPICostAdapter().fetch(adminKey: key)
            guard openAIAPIRequestGate.isCurrent(generation) else { return }
            openAIAPIUsage = fetched
        } catch {
            guard openAIAPIRequestGate.isCurrent(generation) else { return }
            openAIAPIUsage = .degraded(
                from: openAIAPIUsage,
                source: OpenAIAPICostAdapter.source,
                reason: OpenAIAPICostAdapter.staleReason(for: error)
            )
        }
    }

    private func collectAnthropicAPI() async {
        let generation = anthropicAPIRequestGate.begin()
        let key: String
        do {
            guard let stored = try ProviderCredentialStore.read(kind: .anthropicAdmin), !stored.isEmpty else {
                guard anthropicAPIRequestGate.isCurrent(generation) else { return }
                anthropicAPIUsage = nil
                return
            }
            guard ManualProviderPreferences.isEnabled(.anthropicAPI, credentialExists: true, defaults: defaults) else {
                guard anthropicAPIRequestGate.isCurrent(generation) else { return }
                anthropicAPIUsage = nil
                return
            }
            key = stored
        } catch {
            guard anthropicAPIRequestGate.isCurrent(generation) else { return }
            anthropicAPIUsage = .degraded(
                from: anthropicAPIUsage,
                source: AnthropicAPICostAdapter.source,
                reason: .credentialReadFailed
            )
            return
        }
        do {
            let fetched = try await AnthropicAPICostAdapter().fetch(adminKey: key)
            guard anthropicAPIRequestGate.isCurrent(generation) else { return }
            anthropicAPIUsage = fetched
        } catch {
            guard anthropicAPIRequestGate.isCurrent(generation) else { return }
            anthropicAPIUsage = .degraded(
                from: anthropicAPIUsage,
                source: AnthropicAPICostAdapter.source,
                reason: AnthropicAPICostAdapter.staleReason(for: error)
            )
        }
    }

    func manualProviderState(_ provider: ManualProviderKind) -> ProviderConnectionState {
        do {
            let hasCredential = try macProviderCredentialExists(provider)
            let enabled = ManualProviderPreferences.isEnabled(
                provider, credentialExists: hasCredential, defaults: defaults
            )
            let fact: (DataConfidence?, QuotaStaleReason?)
            switch provider {
            case .kimiCode, .glmCoding, .miniMax:
                let snapshot = deviceCodingSnapshots.first { $0.tool == provider.toolKind }
                fact = (snapshot?.confidence, snapshot?.staleReason)
            case .kimiAPI:
                fact = (kimiAPIBalance?.confidence, kimiAPIBalance?.staleReason)
            case .deepSeek:
                fact = (deepSeekBalance?.confidence, deepSeekBalance?.staleReason)
            case .openRouter:
                fact = (openRouterUsage?.confidence, openRouterUsage?.staleReason)
            case .xAI:
                fact = (grokAPIUsage?.confidence, grokAPIUsage?.staleReason)
            case .openAIAPI:
                fact = (openAIAPIUsage?.confidence, openAIAPIUsage?.staleReason)
            case .anthropicAPI:
                fact = (anthropicAPIUsage?.confidence, anthropicAPIUsage?.staleReason)
            }
            return .resolved(
                hasCredential: hasCredential,
                isEnabled: enabled,
                confidence: fact.0,
                staleReason: fact.1
            )
        } catch {
            return .storageFailure
        }
    }

    func automaticPlanProviderState(_ provider: PlanProviderKind) -> ProviderConnectionState {
        guard provider.collectionMode == .macAutomatic else { return .unconfigured }
        if ProcessInfo.processInfo.arguments.contains("--agentmeter-screenshot-provider-settings") {
            return provider == .chatGPT ? .connected : .pendingVerification(.networkFailure)
        }
        guard let result = results.first(where: { $0.tool == provider.toolKind }) else {
            return isCollecting ? .checking : .unconfigured
        }
        if result.outcome == .skipped { return .unconfigured }
        guard let snapshot = result.snapshot else {
            return .pendingVerification(.unknownFailure)
        }
        let confidence: DataConfidence = Date().timeIntervalSince(snapshot.updatedAt) > Self.staleThreshold
            ? .stale
            : snapshot.confidence
        return ProviderConnectionState.resolved(
            hasCredential: true,
            isEnabled: true,
            confidence: confidence,
            staleReason: snapshot.staleReason
        )
    }

    func isVisibleOnMain(_ tool: ToolKind) -> Bool {
        guard let item = MacDisplayItemID.item(for: tool) else { return true }
        return isDisplayItemVisible(item)
    }

    func isDisplayItemVisible(_ item: MacDisplayItemID) -> Bool {
        !hiddenDisplayItems.contains(item)
    }

    func setDisplayItemVisible(_ item: MacDisplayItemID, visible: Bool) {
        if visible { hiddenDisplayItems.remove(item) }
        else { hiddenDisplayItems.insert(item) }
        MacDisplayPreferences.saveHidden(hiddenDisplayItems, defaults: defaults)
        if item == .codex { showsChatGPTOnMain = visible }
        if item == .claudeCode { showsClaudeOnMain = visible }
    }

    func setDisplayOrder(_ items: [MacDisplayItemID]) {
        displayOrder = items
        MacDisplayPreferences.saveOrder(items, defaults: defaults)
        let legacyTools = items.compactMap(\.toolKind).filter { Self.tools.contains($0) }
        setToolOrder(legacyTools)
    }

    @discardableResult
    func refreshManualProvider(_ provider: ManualProviderKind) async -> ProviderConnectionState {
        switch provider {
        case .kimiCode, .glmCoding, .miniMax:
            guard let tool = provider.toolKind else { break }
            await cloudKitDeletionCoordinator.prepareForEnable(tool)
            let result = await collectDeviceCodingProvider(tool)
            guard deviceCodingPublishGenerations[tool] == result.generation else {
                break
            }
            if case .collected(let value, _) = result {
                deviceCodingSnapshots.removeAll { $0.tool == tool }
                deviceCodingSnapshots.append(value.snapshot)
                if value.cloudSync == .pending {
                    deviceCodingCloudSyncPendingTools.insert(tool)
                } else {
                    deviceCodingCloudSyncPendingTools.remove(tool)
                }
            }
        case .kimiAPI:
            await collectKimiAPI()
        case .deepSeek:
            await collectDeepSeek()
        case .openRouter:
            await collectOpenRouter()
        case .xAI:
            await collectGrok()
        case .openAIAPI:
            await collectOpenAIAPI()
        case .anthropicAPI:
            await collectAnthropicAPI()
        }
        return manualProviderState(provider)
    }

    @discardableResult
    func disableManualProvider(_ provider: ManualProviderKind) async -> Bool {
        ManualProviderPreferences.setEnabled(false, for: provider, defaults: defaults)
        switch provider {
        case .kimiCode, .glmCoding, .miniMax:
            guard let tool = provider.toolKind else { return true }
            _ = deviceCodingRequestGate.begin()
            _ = beginDeviceCodingPublishRequest(for: tool)
            deviceCodingSnapshots.removeAll { $0.tool == tool }
            deviceCodingCloudSyncPendingTools.remove(tool)
            return await cloudKitDeletionCoordinator.disable(tool)
        case .kimiAPI:
            _ = kimiAPIRequestGate.begin()
            kimiAPIBalance = nil
        case .deepSeek:
            _ = deepSeekRequestGate.begin()
            deepSeekBalance = nil
        case .openRouter:
            _ = openRouterRequestGate.begin()
            openRouterUsage = nil
        case .xAI:
            _ = grokRequestGate.begin()
            grokAPIUsage = nil
        case .openAIAPI:
            _ = openAIAPIRequestGate.begin()
            openAIAPIUsage = nil
        case .anthropicAPI:
            _ = anthropicAPIRequestGate.begin()
            anthropicAPIUsage = nil
        }
        return true
    }

    private func resumePendingCloudKitDeletions() async {
        for tool in MacPendingCloudKitDeletionPreferences.tools(defaults: defaults) {
            guard let provider = ManualProviderKind(rawValue: tool.rawValue) else {
                MacPendingCloudKitDeletionPreferences.clear(tool, defaults: defaults)
                continue
            }
            if ManualProviderPreferences.isEnabled(
                provider,
                credentialExists: false,
                defaults: defaults
            ) {
                await cloudKitDeletionCoordinator.prepareForEnable(tool)
            } else {
                await cloudKitDeletionCoordinator.resumePendingDeletion(tool)
            }
        }
    }

    func isDeviceCodingCloudSyncPending(_ tool: ToolKind) -> Bool {
        deviceCodingCloudSyncPendingTools.contains(tool)
    }

    private func macProviderCredentialExists(_ provider: ManualProviderKind) throws -> Bool {
        switch provider {
        case .kimiCode, .glmCoding, .miniMax:
            guard let tool = provider.toolKind else { return false }
            return try MacCodingCredentialResolver.resolve(
                tool: tool,
                manualRegion: ManualProviderPreferences.region(for: provider, defaults: defaults)
            ) != nil
        case .kimiAPI:
            return try ProviderCredentialStore.read(kind: .kimiAPI)?.isEmpty == false
        case .deepSeek:
            return try DeepSeekKeyStore.read()?.isEmpty == false
        case .openRouter:
            return try OpenRouterKeyStore.read()?.isEmpty == false
        case .xAI:
            return try GrokManagementKeyStore.read() != nil
        case .openAIAPI:
            return try ProviderCredentialStore.read(kind: .openAIAdmin)?.isEmpty == false
        case .anthropicAPI:
            return try ProviderCredentialStore.read(kind: .anthropicAdmin)?.isEmpty == false
        }
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 失败就回读真实状态,不假装成功
        }
        loginItemEnabled = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - 给 UI / 菜单栏 label

    var snapshots: [QuotaSnapshot] { results.compactMap(\.snapshot) + deviceCodingSnapshots }

    var orderedTools: [ToolKind] {
        let savedTools = displayOrder.compactMap(\.toolKind).filter { Self.tools.contains($0) }
        let missingTools = Self.tools.filter { !savedTools.contains($0) }
        return savedTools + missingTools
    }

    func orderedSnapshots(_ input: [QuotaSnapshot]? = nil) -> [QuotaSnapshot] {
        let order = orderedTools
        let source = input ?? snapshots
        let mainVisible = source.filter { isVisibleOnMain($0.tool) }
        let visible = hidesInactiveTools ? mainVisible.filter { !$0.isInactive() } : mainVisible
        return visible.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.tool) ?? order.count
            let rhsIndex = order.firstIndex(of: rhs.tool) ?? order.count
            if lhsIndex == rhsIndex {
                return displayName(for: lhs.tool) < displayName(for: rhs.tool)
            }
            return lhsIndex < rhsIndex
        }
    }

    var hasMainVisibilityFilteredSnapshots: Bool {
        MacDisplayItemID.allCases.contains { hasData(for: $0) && !isDisplayItemVisible($0) }
    }

    var hasMainVisibleSnapshotsBeforeInactiveFilter: Bool {
        MacDisplayItemID.allCases.contains { hasData(for: $0) && isDisplayItemVisible($0) }
    }

    func orderedVisibleDisplayItems() -> [MacDisplayItemID] {
        displayOrder.filter { item in
            guard isDisplayItemVisible(item), hasData(for: item) else { return false }
            guard hidesInactiveTools, let snapshot = snapshot(for: item) else { return true }
            return !snapshot.isInactive()
        }
    }

    func snapshot(for item: MacDisplayItemID) -> QuotaSnapshot? {
        guard let tool = item.toolKind else { return nil }
        return snapshots.first { $0.tool == tool }
    }

    func hasData(for item: MacDisplayItemID) -> Bool {
        if snapshot(for: item) != nil { return true }
        return switch item {
        case .openAIAPI: openAIAPIUsage != nil
        case .anthropicAPI: anthropicAPIUsage != nil
        case .kimiAPI: kimiAPIBalance != nil
        case .deepSeek: deepSeekBalance != nil
        case .openRouter: openRouterUsage != nil
        case .xAI: grokAPIUsage != nil
        default: false
        }
    }

    func setToolOrder(_ tools: [ToolKind]) {
        toolDisplayOrder = tools.map(\.rawValue).joined(separator: ",")
    }

    func isStale(_ s: QuotaSnapshot) -> Bool {
        s.confidence != .fresh || Date().timeIntervalSince(s.updatedAt) > Self.staleThreshold
    }

    var preferredSnapshot: QuotaSnapshot? {
        let snaps = orderedSnapshots()
        guard !snaps.isEmpty else { return nil }
        return snaps.first { preferredStatusWindow(in: $0) != nil } ?? snaps.first
    }

    var statusText: String {
        guard showsStatusPercentage else { return "" }
        guard let s = preferredSnapshot, let w = preferredStatusWindow(in: s) else { return "—" }
        return "\(Int(w.remainingPercent))%"
    }

    var statusSymbol: String {
        guard let s = preferredSnapshot else { return "gauge" }
        return isStale(s) ? "exclamationmark.triangle" : "gauge"
    }

    /// 菜单栏默认展示 5 小时窗口的剩余额度;缺 5h 时才回落到最紧窗口。
    private func preferredStatusWindow(in snapshot: QuotaSnapshot) -> QuotaWindow? {
        snapshot.window(.fiveHour) ?? snapshot.tightestWindow
    }

    private func handleFiveHourResetNotificationSettingChange(_ enabled: Bool) async {
        if enabled {
            await resetNotificationScheduler.scheduleResetAlerts(for: snapshots)
        } else {
            await resetNotificationScheduler.cancelResetAlerts()
        }
    }

    private func displayName(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .kimiCode: return "Kimi Code"
        case .glmCoding: return "GLM Coding Plan"
        case .miniMax: return "MiniMax Token Plan"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .openCode: return "OpenCode"
        case .grok: return "xAI API"
        }
    }
}
