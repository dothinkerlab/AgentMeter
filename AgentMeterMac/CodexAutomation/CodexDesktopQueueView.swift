import SwiftUI
import AgentMeterCore
import UniformTypeIdentifiers

@MainActor
final class CodexDesktopQueueController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""

    func send(source: URL, threadID: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let home = CodexLocalPaths.home
            let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
            guard source.resolvingSymlinksInPath().path.hasPrefix(root) else { throw CodexDesktopQueueError.invalidSource }
            let executable = try CodexRuntimeReadProbe.runningHostExecutable()
            let target = try CodexQueueTarget.read(source, threadID: threadID)
            var verification = try CodexManualResumeVerification(url: source, expectedThreadID: threadID)
            defer { verification.close() }
            message = L10n.string("正在检查命令支持并保存发送记录…")
            let messageID = try await Task.detached(priority: .userInitiated) {
                let help = try CodexDesktopQueueSender.run(executable: executable, arguments: ["queue", "--help"], home: home)
                guard let text = String(data: help, encoding: .utf8), text.contains("--thread"), text.contains("--message") else {
                    throw CodexDesktopQueueError.process
                }
                try target.revalidate()
                let store = CodexQueueAttemptStore.standard
                let attempt = try store.reserve(target)
                defer { try? attempt.close() }
                do {
                    try target.revalidate()
                    let output = try CodexDesktopQueueSender.run(executable: executable,
                        arguments: CodexDesktopQueueSender.arguments(threadID: threadID), home: home)
                    let id = try CodexDesktopQueueSender.receipt(output, threadID: threadID)
                    try store.record(attempt, target: target, state: "queued", messageID: id)
                    return id
                } catch {
                    try? store.record(attempt, target: target, state: "uncertain", messageID: nil)
                    throw error
                }
            }.value
            message = L10n.format("已入队，消息 ID：%@。正在观察原会话。", messageID)
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try verification.poll()
                if verification.status == .running {
                    message = L10n.format("已入队（%@），并观察到原会话新增“继续”、轮次与助手活动；尚不能通过消息 ID 严格关联。", messageID)
                    return
                }
                if verification.status == .uncertain { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            message = L10n.format("已入队（%@），执行结果待确认。请查看 Codex，不要重复发送。", messageID)
        } catch CodexDesktopQueueError.duplicate {
            message = L10n.string("此失败轮次已有发送记录，已阻止再次提交。请查看 Codex 原会话。")
        } catch CodexDesktopQueueError.invalidSource {
            message = L10n.string("文件不匹配或末尾已不是该会话的额度失败，未提交新消息。")
        } catch {
            message = L10n.string("无法确认提交结果。请查看原会话；已有尝试记录会阻止重复发送。")
        }
    }
}

struct CodexDesktopQueueView: View {
    @StateObject private var controller = CodexDesktopQueueController()
    @State private var threadID = ""
    @State private var source: URL?
    @State private var selecting = false

    var body: some View {
        Section(L10n.string("通过 Desktop 队列恢复一次")) {
            Text(L10n.string("手动发送“继续”到指定原会话。请先确认额度已恢复、会话空闲且未归档；当前不自动检查实时额度。选择末尾仍是额度中断的 JSONL 文件，并保持 Codex 运行。"))
                .foregroundStyle(.secondary)
            TextField(L10n.string("测试会话 ID"), text: $threadID).disabled(controller.busy)
            Button(L10n.string("选择额度中断会话文件")) { selecting = true }.disabled(controller.busy)
            if let source { Text(source.lastPathComponent).font(.caption).textSelection(.enabled) }
            Button(L10n.string("向此会话入队一次“继续”")) {
                guard let source else { return }
                Task { await controller.send(source: source, threadID: threadID) }
            }
            .disabled(controller.busy || source == nil || UUID(uuidString: threadID) == nil)
            if controller.busy { ProgressView().controlSize(.small) }
            if !controller.message.isEmpty { Text(controller.message).textSelection(.enabled) }
        }
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { source = url }
        }
    }
}
