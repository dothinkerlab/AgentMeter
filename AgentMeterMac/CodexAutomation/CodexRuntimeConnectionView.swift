import SwiftUI
import AgentMeterCore

struct CodexRuntimeConnectionView: View {
    let threadID: String?
    @State private var task: Task<Void, Never>?
    @State private var result: CodexRuntimeProbeResult?
    @State private var failure: CodexRuntimeProbeError?

    var body: some View {
        Section(L10n.string("Codex 运行连接")) {
            Text(L10n.string("检查已有服务能否返回账号额度和候选会话状态。不会启动新服务或发送消息。"))
                .foregroundStyle(.secondary)
            Button(L10n.string("检查运行连接")) { check() }.disabled(task != nil)
            if task != nil { ProgressView().controlSize(.small) }
            if let result {
                Text(L10n.string("只读连接成功；尚未验证该服务属于当前 Desktop。"))
                Text(L10n.format("返回 %d 个额度类别。", result.quota.bucketCount))
                if result.quota.accountId?.isEmpty != false {
                    Text(L10n.string("服务未返回账号标识，不能用于自动恢复判定。"))
                }
                if let thread = result.thread {
                    Text(L10n.format("候选会话状态：%@", threadStatus(thread.status.type)))
                }
                Text(L10n.string("此检查不读取完整对话，也不能确认最后一个失败轮次；自动恢复仍未开放。"))
                    .foregroundStyle(.secondary)
            }
            if let failure { Text(message(failure)) }
        }
        .onDisappear { task?.cancel(); task = nil }
        .onChange(of: threadID) { _ in
            task?.cancel(); task = nil; result = nil; failure = nil
        }
    }

    private func check() {
        result = nil; failure = nil
        task = Task { @MainActor in
            do {
                let executable = try CodexRuntimeReadProbe.runningHostExecutable()
                let value = try await CodexRuntimeReadProbe.read(executable: executable, home: CodexLocalPaths.home, threadID: threadID)
                guard !Task.isCancelled else { return }
                result = value
            } catch {
                guard !Task.isCancelled else { return }
                failure = error as? CodexRuntimeProbeError ?? .connectionClosed
            }
            task = nil
        }
    }

    private func threadStatus(_ value: String) -> String {
        switch value {
        case "idle": return L10n.string("空闲")
        case "active": return L10n.string("运行中")
        case "notLoaded": return L10n.string("未加载")
        case "systemError": return L10n.string("服务错误")
        default: return L10n.string("未知")
        }
    }
    private func message(_ error: CodexRuntimeProbeError) -> String {
        switch error {
        case .missingSocket: return L10n.string("未找到可连接的本地控制服务。请等待受支持的 Desktop 接口；程序不会另起服务接管会话。")
        case .unsupportedHost: return L10n.string("未检测到唯一的 Codex 宿主，请保持一个宿主运行后重试。")
        case .homeMismatch: return L10n.string("服务的数据目录与监测目录不一致，已停止检查。")
        case .timedOut: return L10n.string("连接检查超时，可稍后重试。")
        case .serverRequest: return L10n.string("服务要求额外操作，已停止只读检查；未批准任何请求。")
        case .outputLimit: return L10n.string("服务响应超过诊断上限，已停止检查。")
        case .cancelled: return L10n.string("已取消")
        default: return L10n.string("服务未返回可验证的响应，请检查版本兼容性后重试。")
        }
    }
}
