import Foundation
import AgentMeterCore

/// Transient preflight state; durable execution states remain in CodexResumeQueue.
enum CodexResumeBlock: String, Codable {
    case hostUnavailable, connectionUnavailable, accountUnknown, accountMismatch
    case quotaUnknown, runtimeUnverified, sessionChanged, sourceUnavailable, previousAttempt

    static func reason(for candidate: CodexResumeCandidate, evidence: CodexResumePreflight) -> Self {
        guard evidence.originalDesktopVerified, candidate.runtimeEvidenceVerified else { return .runtimeUnverified }
        guard let account = candidate.accountID, !account.isEmpty else { return .accountUnknown }
        guard let quota = evidence.quota else { return .quotaUnknown }
        guard quota.accountID == account else { return .accountMismatch }
        guard let session = evidence.session, session.threadID == candidate.threadID,
              session.latestTurnID == candidate.failedTurnID, session.isIdle, !session.isArchived,
              (0...15).contains(Date().timeIntervalSince(session.observedAt)) else { return .sessionChanged }
        guard session.accountID == account else { return .accountMismatch }
        return .quotaUnknown
    }

    var message: String {
        switch self {
        case .hostUnavailable: return L10n.string("请保持一个 Codex 宿主运行，然后重新检查。")
        case .connectionUnavailable: return L10n.string("无法连接 Codex 的核验服务。可重新检查，或确认条件后手动恢复。")
        case .accountUnknown: return L10n.string("无法确认中断会话的账号，已阻止自动发送。")
        case .accountMismatch: return L10n.string("当前账号与中断会话不一致，请切回原账号后重新检查。")
        case .quotaUnknown: return L10n.string("尚未取得有效的实时额度，请稍后重新检查。")
        case .runtimeUnverified: return L10n.string("当前接口无法核验原 Desktop 归属和最后失败轮次，请确认条件后手动恢复。")
        case .sessionChanged: return L10n.string("会话状态已变化或无法确认空闲，请查看 Codex 原会话。")
        case .sourceUnavailable: return L10n.string("无法定位唯一的中断记录，请重新检查或使用高级诊断。")
        case .previousAttempt: return L10n.string("此会话已有待确认的发送记录，请查看 Codex，不要重复发送。")
        }
    }
}

enum CodexResumeCheck: Equatable {
    case checking
    case blocked(CodexResumeBlock)
    case waiting(Date?)
}
