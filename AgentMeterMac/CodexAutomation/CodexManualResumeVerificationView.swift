import SwiftUI
import AgentMeterCore
import UniformTypeIdentifiers

struct CodexManualResumeVerificationView: View {
    @State private var threadID = ""
    @State private var selecting = false
    @State private var source: URL?
    @State private var message = ""

    var body: some View {
        Section(L10n.string("手动恢复验证")) {
            Text(L10n.string("填写测试会话 ID 并选择其 JSONL 文件。开始观察后，请自行在 Codex 原会话发送一次“继续”。这里只验证新增记录，不会操作 Codex。"))
                .foregroundStyle(.secondary)
            TextField(L10n.string("测试会话 ID"), text: $threadID).disabled(source != nil)
            Button(L10n.string("选择会话文件并开始观察")) { selecting = true }
                .disabled(source != nil || UUID(uuidString: threadID) == nil)
            if source != nil {
                Button(L10n.string("停止观察")) { source = nil }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .fileImporter(isPresented: $selecting, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { source = url }
        }
        .task(id: source) {
            guard let url = source else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var verification = try CodexManualResumeVerification(url: url, expectedThreadID: threadID)
                defer { verification.close() }
                message = L10n.string("已开始观察。请在原会话手动发送一次“继续”，观察窗口为 60 秒。")
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    try Task.checkCancellation()
                    try verification.poll()
                    switch verification.status {
                    case .waiting: break
                    case .submitted: message = L10n.string("已观察到“继续”，等待新的助手活动。")
                    case .running:
                        message = L10n.string("已验证原会话收到“继续”并产生新轮次及助手活动。")
                        return
                    case .uncertain:
                        message = L10n.string("记录存在中断或其他活动，结果待确认；请检查原会话，不要重复发送。")
                        return
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
                message = L10n.string("观察超时，结果待确认；请检查原会话，不要重复发送。")
            } catch is CancellationError {
                message = L10n.string("已停止观察。")
            } catch {
                message = L10n.string("文件不匹配、发生变化或无法读取，已停止验证。")
            }
        }
    }
}
