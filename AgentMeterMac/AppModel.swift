import Foundation
import AppKit
import ServiceManagement
import AgentMeterCore

/// 菜单栏 app 的运行时大脑:启动即采、每 5 分钟采、唤醒补采;登录项开关;状态供 UI/菜单栏 label 用。
@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var results: [QuotaCollector.Result] = []
    @Published private(set) var lastCollectedAt: Date?
    @Published private(set) var isCollecting = false
    @Published private(set) var loginItemEnabled = false
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

    static let interval: TimeInterval = 5 * 60
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
                // `try?` 是有意为之:取消时 sleep 抛 CancellationError 被吞掉,
                // 下一轮 `while` 读到 isCancelled==true 干净退出。别改成 `try`。
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func collectNow() async {
        guard !isCollecting else { return }
        isCollecting = true
        results = await collector.collectAll(tools: Self.tools)
        lastCollectedAt = Date()
        isCollecting = false
        if fiveHourResetNotificationsEnabled {
            await resetNotificationScheduler.scheduleResetAlerts(for: snapshots)
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
        case .openCode: return "OpenCode"
        }
    }
}
