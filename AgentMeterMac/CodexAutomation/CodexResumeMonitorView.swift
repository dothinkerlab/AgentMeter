import SwiftUI
import AppKit
import AgentMeterCore

struct CodexResumeMonitorView: View {
    @ObservedObject var coordinator: CodexResumeCoordinator
    @State private var showingIntroduction = false
    @State private var manualCandidate: CodexResumeCandidate?

    var body: some View {
        Section(L10n.string("Codex 自动恢复")) {
            Toggle(L10n.string("自动恢复"), isOn: Binding(
                get: { coordinator.enabled },
                set: { value in
                    if value && !coordinator.hasSeenIntroduction { showingIntroduction = true }
                    else { coordinator.setEnabled(value) }
                }
            ))
            .disabled(coordinator.storageFailed)
            Label(coordinator.overallStatus, systemImage: coordinator.enabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.headline)
            Text(L10n.string("额度恢复且核验通过后，逐个向中断会话发送“继续”。不会使用额度重置次数。"))
                .foregroundStyle(.secondary)
            if !coordinator.automaticConnectionAvailable {
                Text(L10n.string("当前 Codex 连接尚不能完成自动核验。可监测中断，并从列表手动恢复。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !coordinator.enabled {
                Text(L10n.string("等待列表已保留。重新开启后会再次核验；已入队消息不能撤回。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if coordinator.storageFailed {
                Text(L10n.string("本地监测记录无法读取或保存，监测已暂停。请检查磁盘与文件权限后重启 AgentMeter。"))
                    .foregroundStyle(.red)
            }
            HStack {
                Button(L10n.string("重新检查")) { Task { await coordinator.recheck() } }
                    .disabled(coordinator.isBusy || !coordinator.enabled || coordinator.storageFailed)
                if coordinator.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if let checked = coordinator.lastCheckedAt {
                    Text(L10n.format("上次检查：%@", checked.formatted(date: .omitted, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if coordinator.enabled, coordinator.lastCheckedAt != nil, !coordinator.directoryAvailable {
                Text(L10n.string("会话目录不存在或无法读取。"))
            }
            if coordinator.scanIncomplete {
                Text(L10n.string("部分记录尚未读取或无法识别，将在后续刷新时继续检查。"))
                    .font(.caption)
            }
            if coordinator.notificationPermissionDenied {
                Text(L10n.string("系统通知未开启，恢复结果仍会保留在此列表。"))
            }
            Button(L10n.string("系统通知设置")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }.font(.caption)
        }
        .alert(L10n.string("开启 Codex 自动恢复？"), isPresented: $showingIntroduction) {
            Button(L10n.string("开启自动恢复")) { coordinator.setEnabled(true) }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("仅处理开启后新检测到的额度中断。请保持 AgentMeter 和 Codex 运行；检测到中断、恢复结果及需要操作时通知，多会话合并提示。核验不足时不会自动发送。"))
        }

        Section(L10n.string("待恢复会话")) {
            if coordinator.pending.isEmpty {
                Text(L10n.string("暂无待恢复会话。开启后会在此显示新检测到的额度中断。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(coordinator.pending) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    identity(candidate)
                    if !coordinator.enabled {
                        Text(L10n.string("已暂停")).foregroundStyle(.secondary)
                    } else {
                        switch coordinator.checks[candidate.id] {
                        case .blocked(let reason):
                            Label(L10n.string("需要处理"), systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text(reason.message).font(.callout).foregroundStyle(.secondary)
                        case .waiting:
                            Label(L10n.string("等待额度"), systemImage: "clock")
                        default:
                            Text(L10n.string("等待核验")).foregroundStyle(.secondary)
                        }
                        if let date = coordinator.nextChecks[candidate.id] {
                            Text(L10n.format("预计重新检查：%@", date.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(L10n.string("手动恢复…")) { manualCandidate = candidate }
                            .disabled(coordinator.isBusy || coordinator.sourceForManualResume(candidateID: candidate.id) == nil)
                        Button(L10n.string("取消恢复")) { coordinator.cancel(id: candidate.id) }
                            .disabled(coordinator.isSending)
                        Spacer()
                        openThread(candidate)
                    }
                }.padding(.vertical, 4)
            }
            if coordinator.candidates.count >= 500 {
                Text(L10n.string("已达到 500 条本地记录上限，暂不记录新的候选。"))
            }
            if let error = coordinator.manualError { Text(error).foregroundStyle(.orange) }
        }
        .alert(L10n.string("向原会话发送“继续”？"), isPresented: Binding(
            get: { manualCandidate != nil }, set: { if !$0 { manualCandidate = nil } }
        ), presenting: manualCandidate) { candidate in
            Button(L10n.string("确认并发送")) { Task { await coordinator.sendManually(candidate: candidate) } }
            Button(L10n.string("取消"), role: .cancel) {}
        } message: { _ in
            Text(L10n.string("请确认额度已恢复、原会话空闲且未归档。此操作会发送一次“继续”；入队后不能撤回，结果不明时不会重复发送。"))
        }

        // Active submissions remain visible even while completed history is collapsed.
        ForEach(coordinator.history.filter { [.attempting, .submitted].contains($0.state) }) { candidate in
            Section {
                identity(candidate)
                Label(status(candidate.state), systemImage: "paperplane")
                Text(L10n.string("已入队消息不能撤回；关闭设置不会中断观察。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            DisclosureGroup(L10n.string("已处理记录")) {
                ForEach(coordinator.history.filter { ![.attempting, .submitted].contains($0.state) }) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        identity(candidate)
                        Text(status(candidate.state))
                        if candidate.state == .observed {
                            Text(L10n.string("已观察到原会话的新轮次与助手活动，尚未严格关联到本次消息。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        openThread(candidate)
                    }.padding(.vertical, 4)
                }
                ForEach(coordinator.legacyAttempts) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.threadID).font(.caption.monospaced()).textSelection(.enabled)
                        Text(record.state == "queued" ? L10n.string("已入队；执行状态请查看原会话") : L10n.string("尝试结果待确认；不会自动重发"))
                        Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }.padding(.vertical, 4)
                }
                if coordinator.history.isEmpty && coordinator.legacyAttempts.isEmpty { Text(L10n.string("暂无记录")) }
                if coordinator.historyWarning {
                    Text(L10n.string("部分尝试记录不可读或超出读取上限；原记录仍保留以阻止重复发送。"))
                }
            }
        }
        Section {
            DisclosureGroup(L10n.string("高级诊断")) {
                CodexDesktopQueueView(coordinator: coordinator)
                CodexRuntimeConnectionView(threadID: coordinator.pending.first?.threadID)
                CodexManualResumeVerificationView()
                CodexAutomationDiagnosticView()
            }
        }
        .task { await coordinator.refreshHistory() }
    }

    private func identity(_ candidate: CodexResumeCandidate) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(candidate.projectName ?? L10n.string("未命名项目")).font(.headline)
            Text(candidate.threadID).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(candidate.detectedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openThread(_ candidate: CodexResumeCandidate) -> some View {
        Button(L10n.string("查看原会话")) {
            guard UUID(uuidString: candidate.threadID) != nil,
                  let url = URL(string: "codex://threads/" + candidate.threadID) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func status(_ state: CodexResumeCandidate.State) -> String {
        switch state {
        case .pending: return L10n.string("等待核验")
        case .cancelled: return L10n.string("已取消")
        case .superseded: return L10n.string("已失效：会话已有后续活动或有更新的候选")
        case .attempting: return L10n.string("正在发送")
        case .submitted: return L10n.string("已入队待确认")
        case .observed: return L10n.string("已观察到继续运行")
        case .resumed: return L10n.string("恢复已确认")
        case .failed: return L10n.string("恢复失败，需要手动检查")
        case .uncertain: return L10n.string("结果待确认，请查看原会话；不会重复发送。")
        }
    }
}
