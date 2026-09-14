import SwiftUI
import AgentMeterCore

struct CodexResumeMonitorView: View {
    @ObservedObject var coordinator: CodexResumeCoordinator

    var body: some View {
        CodexRuntimeConnectionView(threadID: coordinator.candidates.first(where: { $0.state == .pending })?.threadID)
        Section(L10n.string("Codex 会话监测")) {
            Toggle(L10n.string("记录新的额度中断"), isOn: Binding(
                get: { coordinator.enabled }, set: { coordinator.setEnabled($0) }
            ))
            .disabled(coordinator.storageFailed)
            Text(L10n.string("首次检查建立基线；后续事件仅保存在此 Mac。当前不会自动发送“继续”。"))
                .foregroundStyle(.secondary)
            if coordinator.storageFailed {
                Text(L10n.string("本地监测记录无法读取或保存，监测已暂停。请检查磁盘与文件权限后重启 AgentMeter。"))
            } else if coordinator.enabled {
                if coordinator.isScanning { ProgressView().controlSize(.small) }
                if let checked = coordinator.lastCheckedAt {
                    Text(L10n.format("上次检查：%@", checked.formatted(date: .omitted, time: .standard)))
                    if !coordinator.directoryAvailable {
                        Text(L10n.string("会话目录不存在或无法读取。"))
                    } else if coordinator.scanIncomplete {
                        Text(L10n.string("部分记录尚未读取或无法识别，将在后续刷新时继续检查。"))
                    }
                }
                Button(L10n.string("立即检查会话")) { Task { await coordinator.poll() } }
                    .disabled(coordinator.isScanning)
            }
            if coordinator.candidates.isEmpty {
                Text(L10n.string("尚未记录到符合条件的额度中断；这不代表所有会话均未中断。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(coordinator.candidates.sorted { $0.detectedAt > $1.detectedAt }.prefix(5))) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.projectName ?? L10n.string("未命名项目"))
                    Text(status(candidate.state)).foregroundStyle(.secondary)
                    Text(candidate.detectedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    if candidate.state == .pending {
                        Button(L10n.string("取消此候选")) { coordinator.cancel(id: candidate.id) }
                    }
                }
            }
            if coordinator.candidates.count > 5 {
                Text(L10n.string("仅显示最近 5 条记录。"))
            }
            if coordinator.candidates.count >= 500 {
                Text(L10n.string("已达到 500 条本地记录上限，暂不记录新的候选。"))
            }
        }
    }

    private func status(_ state: CodexResumeCandidate.State) -> String {
        switch state {
        case .pending: return L10n.string("待核验账号、额度与原会话，尚未恢复")
        case .cancelled: return L10n.string("已取消")
        case .superseded: return L10n.string("已失效：会话已有后续活动或有更新的候选")
        case .attempting: return L10n.string("正在提交")
        case .submitted: return L10n.string("已提交，等待执行验证")
        case .resumed: return L10n.string("已恢复")
        case .failed: return L10n.string("恢复失败，需要手动检查")
        case .uncertain: return L10n.string("执行结果不明，需要手动检查")
        }
    }
}
