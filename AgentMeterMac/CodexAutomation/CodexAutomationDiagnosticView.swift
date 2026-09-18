import AppKit
import SwiftUI
import AgentMeterCore

/// Opt-in P0 diagnostics. No credentials, Accessibility requests, or control operations.
struct CodexAutomationDiagnosticView: View {
    @State private var report: CodexSessionDiagnostics?
    @State private var hostNames: [String] = []
    @State private var controlSocketExists = false
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        Section(L10n.string("Codex 自动恢复 · 实验性检测")) {
            Text(L10n.string("检查本机连接条件和近期会话记录。自动恢复状态请查看待恢复会话。"))
            Button {
                scan()
            } label: {
                Label(L10n.string("检查自动恢复条件"), systemImage: "stethoscope")
            }
            .disabled(scanTask != nil)
            if scanTask != nil { ProgressView().controlSize(.small) }
            if let report {
                Text(L10n.format("运行中的宿主：%@", hostNames.isEmpty ? L10n.string("未检测到") : hostNames.joined(separator: ", ")))
                Text(controlSocketExists
                     ? L10n.string("默认控制 socket 存在，尚未验证可连接原会话。")
                     : L10n.string("未发现默认控制 socket，尚无法确认原会话连接。"))
                if report.sessionDirectoryAvailable {
                    Text(L10n.format("已抽查 %d 个会话文件；结构化限额错误记录：%d", report.filesInspected, report.structuredQuotaErrors))
                    Text(L10n.string("历史错误不代表当前仍受限；未发现错误也不代表没有中断。"))
                    Text(L10n.format("仅抽查最近最多 30 个文件，每个文件末尾最多 512 KB；%d 个文件截取了尾部。", report.filesTruncated))
                    if report.enumerationIncomplete || report.unreadableFiles > 0 || report.malformedLines > 0 || report.incompleteLines > 0 {
                        Text(L10n.format("抽查有缺失：无法读取 %d 个文件、%d 条无效记录、%d 条未写完记录。", report.unreadableFiles, report.malformedLines, report.incompleteLines))
                        if report.enumerationIncomplete {
                            Text(L10n.string("目录枚举未完成，抽查范围可能不包含最新会话。"))
                        }
                    }
                } else {
                    Text(L10n.string("会话目录不存在或无法读取。"))
                }
            }
            Text(L10n.string("检测只在此 Mac 运行，不保存或同步对话内容，不会发送“继续”。"))
                .foregroundStyle(.secondary)
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
    }

    @MainActor
    private func scan() {
        // Inspect host bundle metadata, rather than assuming /Applications/Codex.app exists.
        hostNames = Array(Set(NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let bundle = app.bundleURL,
                  FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/Resources/codex").path)
            else { return nil }
            return app.localizedName ?? bundle.deletingPathExtension().lastPathComponent
        })).sorted()
        let home = CodexLocalPaths.home
        let socket = home.appendingPathComponent("app-server-control/app-server-control.sock")
        let attributes = try? FileManager.default.attributesOfItem(atPath: socket.path)
        controlSocketExists = attributes?[.type] as? FileAttributeType == .typeSocket
        scanTask = Task {
            let worker = Task.detached(priority: .utility) {
                CodexSessionDiagnosticScanner(home: home).scan()
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            report = result
            scanTask = nil
        }
    }
}
