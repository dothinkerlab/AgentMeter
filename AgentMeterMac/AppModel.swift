import Foundation
import AppKit
import ServiceManagement
import AgentMeterCore

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
    @Published var toolDisplayOrder: String {
        didSet { defaults.set(toolDisplayOrder, forKey: Self.toolDisplayOrderKey) }
    }
    @Published var showsStatusPercentage: Bool {
        didSet { defaults.set(showsStatusPercentage, forKey: Self.showsStatusPercentageKey) }
    }
    @Published var hidesInactiveTools: Bool {
        didSet { defaults.set(hidesInactiveTools, forKey: Self.hidesInactiveToolsKey) }
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
    static let tools: [ToolKind] = AgentToolSelection.defaultTools   // [.claudeCode, .codex]
    private static let toolDisplayOrderKey = "toolDisplayOrder"
    private static let showsStatusPercentageKey = "macShowsStatusPercentage"
    private static let hidesInactiveToolsKey = "hideInactiveTools"
    private static let fiveHourResetNotificationsKey = "fiveHourResetNotificationsEnabled"

    private let collector: QuotaCollector
    private let defaults: UserDefaults
    private let resetNotificationScheduler: FiveHourResetNotificationScheduling
    private var loopTask: Task<Void, Never>?
    private var started = false
    private var deepSeekRequestGate = DeepSeekRequestGate()
    private var openRouterRequestGate = OpenRouterRequestGate()
    private var grokRequestGate = GrokRequestGate()

    init(
        defaults: UserDefaults = .standard,
        resetNotificationScheduler: FiveHourResetNotificationScheduling = FiveHourResetNotificationScheduler()
    ) {
        self.defaults = defaults
        self.resetNotificationScheduler = resetNotificationScheduler
        toolDisplayOrder = defaults.string(forKey: Self.toolDisplayOrderKey) ?? ""
        showsStatusPercentage = defaults.object(forKey: Self.showsStatusPercentageKey) as? Bool ?? true
        hidesInactiveTools = defaults.object(forKey: Self.hidesInactiveToolsKey) as? Bool ?? true
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.collectNow() }
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.collectNow()
                let interval = await self?.nextCollectionInterval() ?? Self.defaultInterval
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
            async let deepSeek: Void = collectDeepSeek()
            async let openRouter: Void = collectOpenRouter()
            async let grok: Void = collectGrok()
            _ = await (deepSeek, openRouter, grok)
            return
        }
        isCollecting = true
        results = await collector.collectAll(tools: Self.tools)
        lastCollectedAt = Date()
        // DeepSeek 旁路采集 —— 不走 QuotaCollector,缺 key 跳过,失败降级 stale/unknown。
        async let deepSeek: Void = collectDeepSeek()
        async let openRouter: Void = collectOpenRouter()
        async let grok: Void = collectGrok()
        _ = await (deepSeek, openRouter, grok)
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

    var snapshots: [QuotaSnapshot] { results.compactMap(\.snapshot) }

    var orderedTools: [ToolKind] {
        let savedTools = toolDisplayOrder
            .split(separator: ",")
            .compactMap { ToolKind(rawValue: String($0)) }
            .filter { Self.tools.contains($0) }
        let missingTools = Self.tools.filter { !savedTools.contains($0) }
        return savedTools + missingTools
    }

    func orderedSnapshots(_ input: [QuotaSnapshot]? = nil) -> [QuotaSnapshot] {
        let order = orderedTools
        let source = input ?? snapshots
        let visible = hidesInactiveTools ? source.filter { !$0.isInactive() } : source
        return visible.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.tool) ?? order.count
            let rhsIndex = order.firstIndex(of: rhs.tool) ?? order.count
            if lhsIndex == rhsIndex {
                return displayName(for: lhs.tool) < displayName(for: rhs.tool)
            }
            return lhsIndex < rhsIndex
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
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .openCode: return "OpenCode"
        case .grok: return "xAI API"
        }
    }
}
