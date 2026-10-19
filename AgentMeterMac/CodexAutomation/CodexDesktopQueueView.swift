import SwiftUI
import AgentMeterCore
import UniformTypeIdentifiers

@MainActor
final class CodexDesktopQueueController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""

    enum Outcome { case observed, uncertain, notSent, deferred }
    private enum PreReservationFailure: Error { case sourceChanged }
    private let resolveExecutable: @MainActor () throws -> URL
    private let runProcess: @Sendable (URL, [String], URL) throws -> Data
    private let wakeSession: @MainActor (URL, String) async throws -> Void
    private let wakeAfter: TimeInterval
    private let observationDuration: TimeInterval

    init(resolveExecutable: @escaping @MainActor () throws -> URL = { try CodexRuntimeReadProbe.runningHostExecutable() },
         runProcess: @escaping @Sendable (URL, [String], URL) throws -> Data = {
             try CodexDesktopQueueSender.run(executable: $0, arguments: $1, home: $2)
         },
         wakeSession: @escaping @MainActor (URL, String) async throws -> Void = {
             try await CodexDesktopSessionWake.wake(executable: $0, threadID: $1)
         }, wakeAfter: TimeInterval = 2, observationDuration: TimeInterval = 60) {
        self.resolveExecutable = resolveExecutable; self.runProcess = runProcess
        self.wakeSession = wakeSession
        self.wakeAfter = max(0, wakeAfter)
        self.observationDuration = max(0.05, observationDuration)
    }

    func send(source: URL, threadID: String, home: URL = CodexLocalPaths.home, store: CodexQueueAttemptStore = .standard,
              expectedTarget: CodexQueueTarget? = nil,
              authorize: @escaping @MainActor () throws -> Void = {},
              onQueued: @MainActor (String) -> Void) async -> Outcome {
        guard !busy else { return .notSent }
        var attempted = false
        busy = true
        defer { busy = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
            guard source.resolvingSymlinksInPath().path.hasPrefix(root) else { throw CodexDesktopQueueError.invalidSource }
            let executable = try resolveExecutable()
            let target = try expectedTarget ?? CodexQueueTarget.read(source, threadID: threadID)
            guard target.threadID == threadID, target.source == source else { throw CodexDesktopQueueError.invalidSource }
            try target.revalidate()
            var verification = try CodexManualResumeVerification(url: source, expectedThreadID: threadID)
            defer { verification.close() }
            message = L10n.string("正在检查命令支持并保存发送记录…")
            let run = runProcess
            let help = try await Task.detached(priority: .userInitiated) {
                try run(executable, ["queue", "--help"], home)
            }.value
            guard let text = String(data: help, encoding: .utf8), text.contains("--thread"), text.contains("--message") else {
                throw CodexDesktopQueueError.process
            }
            // Recheck after the asynchronous help process; cancellation here has not reserved or sent anything.
            do { try authorize() }
            catch {
                message = (error as? CodexDesktopAutoResume.Blocked)?.reason.message
                    ?? L10n.string("发送前条件已变化，已保留等待会话，未发送消息。")
                return .deferred
            }
            attempted = true
            let messageID = try await Task.detached(priority: .userInitiated) {
                do { try target.revalidate() }
                catch { throw PreReservationFailure.sourceChanged }
                let attempt = try store.reserve(target)
                defer { try? attempt.close() }
                do {
                    try target.revalidate()
                    let output = try run(executable, CodexDesktopQueueSender.arguments(threadID: threadID), home)
                    let id = try CodexDesktopQueueSender.receipt(output, threadID: threadID)
                    try store.record(attempt, target: target, state: "queued", messageID: id)
                    return id
                } catch {
                    try? store.record(attempt, target: target, state: "uncertain", messageID: nil)
                    throw error
                }
            }.value
            onQueued(messageID)
            message = L10n.format("已入队，消息 ID：%@。正在观察原会话。", messageID)
            // A cold Desktop session can retain the message indefinitely until loaded.
            // Give ordinary queue dispatch a short grace period, then load that same
            // session once. URL delivery is not execution evidence and never resends input.
            let started = ProcessInfo.processInfo.systemUptime
            let deadline = started + observationDuration
            var wakeAttempted = false, wakeFailed = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                try verification.poll()
                if verification.status == .running {
                    message = L10n.format("已入队（%@），并观察到原会话新增“继续”、轮次与助手活动；尚不能通过消息 ID 严格关联。", messageID)
                    return .observed
                }
                if verification.status == .uncertain { break }
                if !wakeAttempted, verification.status == .waiting, !verification.hasStartedTurn,
                   ProcessInfo.processInfo.systemUptime >= started + wakeAfter {
                    try Task.checkCancellation()
                    wakeAttempted = true
                    message = L10n.string("已入队，正在载入原会话以启动已有队列…")
                    do {
                        guard try resolveExecutable() == executable else { throw CodexRuntimeProbeError.unsupportedHost }
                        try await wakeSession(executable, threadID)
                    } catch { wakeFailed = true }
                    // Poll immediately: the host may have started or completed while
                    // delivering the URL. A successful open alone never marks resumed.
                    continue
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            message = wakeFailed
                ? L10n.format("已入队（%@），无法载入原会话。请在 Codex 打开该会话，不要重复发送。", messageID)
                : L10n.format("已入队（%@），执行结果待确认。请查看 Codex，不要重复发送。", messageID)
            return .uncertain
        } catch PreReservationFailure.sourceChanged {
            message = L10n.string("发送前条件已变化，已保留等待会话，未发送消息。")
            return .deferred
        } catch CodexDesktopQueueError.duplicate {
            message = L10n.string("此失败轮次已有发送记录，已阻止再次提交。请查看 Codex 原会话。")
            return .uncertain
        } catch CodexDesktopQueueError.invalidSource {
            message = L10n.string("文件不匹配或末尾已不是该会话的额度失败，未提交新消息。")
            return attempted ? .uncertain : (expectedTarget == nil ? .notSent : .deferred)
        } catch CodexRuntimeProbeError.unsupportedHost {
            message = CodexResumeBlock.hostUnavailable.message
            return .notSent
        } catch {
            message = L10n.string("无法确认提交结果。请查看原会话；已有尝试记录会阻止重复发送。")
            return attempted ? .uncertain : .notSent
        }
    }
}

struct CodexDesktopQueueView: View {
    @ObservedObject var coordinator: CodexResumeCoordinator
    private var controller: CodexDesktopQueueController { coordinator.sender }
    @State private var threadID = ""
    @State private var source: URL?
    @State private var selecting = false
    private var history: [CodexQueueAttemptStore.Summary] { coordinator.recentAttempts }
    private var historyWarning: Bool { coordinator.historyWarning }

    var body: some View {
        Section(L10n.string("通过 Desktop 队列恢复一次")) {
            Text(L10n.string("手动发送“继续”到指定原会话。请先确认额度已恢复、会话空闲且未归档；当前不自动检查实时额度。选择末尾仍是额度中断的 JSONL 文件，并保持 Codex 运行。"))
                .foregroundStyle(.secondary)
            TextField(L10n.string("测试会话 ID"), text: $threadID).disabled(coordinator.isBusy)
            if let candidate = coordinator.pending.last,
               let source = coordinator.sourceForManualResume(candidateID: candidate.id) {
                Button(L10n.string("填入最新监测候选")) {
                    threadID = candidate.threadID
                    self.source = source
                }.disabled(coordinator.isBusy)
                Text(candidate.projectName ?? L10n.string("未命名项目")).font(.caption)
            }
            Button(L10n.string("选择额度中断会话文件")) { selecting = true }.disabled(coordinator.isBusy)
            if let source { Text(source.lastPathComponent).font(.caption).textSelection(.enabled) }
            Button(L10n.string("向此会话入队一次“继续”")) {
                guard let source else { return }
                Task { await coordinator.sendManually(source: source, threadID: threadID) }
            }
            .disabled(coordinator.isBusy || source == nil || UUID(uuidString: threadID) == nil)
            if controller.busy { ProgressView().controlSize(.small) }
            if !controller.message.isEmpty { Text(controller.message).textSelection(.enabled) }
            if !history.isEmpty {
                Text(L10n.string("最近入队记录（不代表已执行）"))
                ForEach(history) { record in
                    VStack(alignment: .leading) {
                        Text(record.threadID).font(.caption).textSelection(.enabled)
                        Text(record.state == "queued" ? L10n.string("已入队；执行状态请查看原会话") : L10n.string("尝试结果待确认；不会自动重发"))
                        if let id = record.messageID { Text(id).font(.caption).textSelection(.enabled) }
                        Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                }
            }
            if historyWarning { Text(L10n.string("部分尝试记录不可读或超出读取上限；原记录仍保留以阻止重复发送。")) }
            Button(L10n.string("刷新入队记录")) { Task { await refreshHistory() } }.disabled(coordinator.isBusy)
        }
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { source = url }
        }
        .task(id: coordinator.isBusy) { if !controller.busy { await refreshHistory() } }
    }

    private func refreshHistory() async {
        await coordinator.refreshHistory()
    }
}
