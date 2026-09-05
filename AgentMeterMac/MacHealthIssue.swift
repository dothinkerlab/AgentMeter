import Foundation
import AgentMeterCore

struct MacHealthIssue: Hashable, Identifiable {
    enum Kind: Int, Hashable {
        case cloudKit = 0
        case collection = 1
        case resetCredits = 2
    }

    let item: MacDisplayItemID
    let kind: Kind
    let reason: QuotaStaleReason?

    var id: String {
        [item.rawValue, String(kind.rawValue), reason?.rawValue ?? "none"]
            .joined(separator: ":")
    }
}

enum MacHealthIssueBuilder {
    static func codingIssues(
        item: MacDisplayItemID,
        outcome: QuotaCollector.Outcome,
        snapshot: QuotaSnapshot?,
        cloudSyncPending: Bool = false
    ) -> [MacHealthIssue] {
        guard outcome != .skipped else { return [] }
        var issues: [MacHealthIssue] = []

        if outcome == .writeFailed || cloudSyncPending {
            issues.append(MacHealthIssue(item: item, kind: .cloudKit, reason: nil))
        }

        if let snapshot,
           snapshot.confidence != .fresh,
           let reason = snapshot.staleReason {
            issues.append(MacHealthIssue(item: item, kind: .collection, reason: reason))
        } else if let resetCredits = snapshot?.resetCredits,
                  resetCredits.confidence != .fresh,
                  let reason = resetCredits.staleReason {
            // Codex reset credits fail independently from the main quota request.
            issues.append(MacHealthIssue(item: item, kind: .resetCredits, reason: reason))
        }

        return issues
    }

    static func localIssue(
        item: MacDisplayItemID,
        isEnabled: Bool = true,
        confidence: DataConfidence,
        staleReason: QuotaStaleReason?
    ) -> MacHealthIssue? {
        guard isEnabled, confidence != .fresh, let staleReason else { return nil }
        return MacHealthIssue(item: item, kind: .collection, reason: staleReason)
    }

    static func normalized(
        _ issues: [MacHealthIssue],
        displayOrder: [MacDisplayItemID]
    ) -> [MacHealthIssue] {
        let unique = Array(Set(issues))
        return unique.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            let lhsIndex = displayOrder.firstIndex(of: lhs.item) ?? displayOrder.count
            let rhsIndex = displayOrder.firstIndex(of: rhs.item) ?? displayOrder.count
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            if lhs.item.rawValue != rhs.item.rawValue { return lhs.item.rawValue < rhs.item.rawValue }
            return (lhs.reason?.rawValue ?? "") < (rhs.reason?.rawValue ?? "")
        }
    }
}

extension MacDisplayItemID {
    var healthDisplayName: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .kimiCode: "Kimi Code"
        case .glmCoding: "GLM Coding Plan"
        case .miniMax: "MiniMax Token Plan"
        case .openAIAPI: "OpenAI API"
        case .anthropicAPI: "Anthropic API"
        case .kimiAPI: "Kimi API"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .xAI: "xAI API"
        case .cursorTeam: "Cursor Team"
        }
    }
}
