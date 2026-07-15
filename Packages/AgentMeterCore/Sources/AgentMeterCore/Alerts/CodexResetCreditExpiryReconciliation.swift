import Foundation

public struct CodexResetCreditExpiryLedgerEntry: Codable, Sendable, Equatable {
    public let fireAt: Date
    public let expiresAt: Date

    public init(fireAt: Date, expiresAt: Date) {
        self.fireAt = fireAt
        self.expiresAt = expiresAt
    }
}

public struct CodexResetCreditExpiryReconciliationPlan: Sendable, Equatable {
    public let identifiersToCancel: Set<String>
    public let candidatesToSchedule: [CodexResetCreditExpiryAlertCandidate]
    public let retainedLedger: [String: CodexResetCreditExpiryLedgerEntry]
}

/// 只计算通知对账差异，不接触 UserNotifications，便于覆盖去重与开关语义。
public enum CodexResetCreditExpiryReconciler {
    public static func plan(
        candidates: [CodexResetCreditExpiryAlertCandidate],
        pendingIdentifiers: Set<String>,
        ledger: [String: CodexResetCreditExpiryLedgerEntry],
        now: Date
    ) -> CodexResetCreditExpiryReconciliationPlan {
        let currentIdentifiers = Set(candidates.map(\.identifier))
        let retainedLedger = ledger.filter { identifier, entry in
            entry.expiresAt > now && currentIdentifiers.contains(identifier)
        }
        let candidatesToSchedule = candidates.filter { candidate in
            guard let entry = retainedLedger[candidate.identifier] else { return true }
            // 未来请求被系统移除时恢复；已到触发时刻的 ledger 记录不再重复发送。
            return entry.fireAt > now && !pendingIdentifiers.contains(candidate.identifier)
        }

        return CodexResetCreditExpiryReconciliationPlan(
            identifiersToCancel: pendingIdentifiers.subtracting(currentIdentifiers),
            candidatesToSchedule: candidatesToSchedule,
            retainedLedger: retainedLedger
        )
    }

    /// 关闭开关时只保留已经到达触发时刻、但尚未过期的记录，避免重开后重复即时提醒。
    public static func ledgerWhenDisabled(
        _ ledger: [String: CodexResetCreditExpiryLedgerEntry],
        now: Date
    ) -> [String: CodexResetCreditExpiryLedgerEntry] {
        ledger.filter { _, entry in
            entry.expiresAt > now && entry.fireAt <= now
        }
    }
}
