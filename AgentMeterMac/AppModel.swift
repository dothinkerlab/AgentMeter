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

    static let interval: TimeInterval = 5 * 60
    static let staleThreshold: TimeInterval = 15 * 60
    static let tools: [ToolKind] = AgentToolSelection.defaultTools   // [.claudeCode, .codex]

    private let collector: QuotaCollector
    private var loopTask: Task<Void, Never>?
    private var started = false

    init() {
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

    func isStale(_ s: QuotaSnapshot) -> Bool {
        s.confidence != .fresh || Date().timeIntervalSince(s.updatedAt) > Self.staleThreshold
    }

    var preferredSnapshot: QuotaSnapshot? {
        let snaps = snapshots
        guard !snaps.isEmpty else { return nil }
        return snaps.first { $0.tool == preferredTool(snaps) } ?? snaps.first
    }

    var statusText: String {
        guard let s = preferredSnapshot, let w = s.tightestWindow else { return "—" }
        return "\(Int(w.remainingPercent))%"
    }

    var statusSymbol: String {
        guard let s = preferredSnapshot else { return "gauge" }
        return isStale(s) ? "exclamationmark.triangle" : "gauge"
    }

    /// 与 iOS 一致:优先 fresh 的 Codex,再 fresh 的任意,再 Codex,最后第一个。
    private func preferredTool(_ snaps: [QuotaSnapshot]) -> ToolKind {
        if let c = snaps.first(where: { $0.tool == .codex && $0.confidence == .fresh }) { return c.tool }
        if let f = snaps.first(where: { $0.confidence == .fresh }) { return f.tool }
        if let c = snaps.first(where: { $0.tool == .codex }) { return c.tool }
        return snaps[0].tool
    }
}
