import Foundation

/// A local notification candidate for the moment a low-quota 5h window resets.
///
/// The candidate is derived only from fresh quota snapshots. Platform targets turn it
/// into a local notification; Core deliberately stays independent of notification APIs.
public struct FiveHourResetAlertCandidate: Sendable, Equatable {
    public let tool: ToolKind
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetsAt: Date
    public let snapshotUpdatedAt: Date

    public init(
        tool: ToolKind,
        usedPercent: Double,
        remainingPercent: Double,
        resetsAt: Date,
        snapshotUpdatedAt: Date
    ) {
        self.tool = tool
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.snapshotUpdatedAt = snapshotUpdatedAt
    }

    public var identifier: String {
        Self.identifier(tool: tool, resetsAt: resetsAt)
    }

    public static func identifier(tool: ToolKind, resetsAt: Date) -> String {
        let seconds = Int(resetsAt.timeIntervalSince1970.rounded())
        return "agentmeter.reset.fiveHour.\(tool.rawValue).\(seconds)"
    }
}

public struct FiveHourResetAlertReconciliationPlan: Sendable, Equatable {
    public let identifiersToCancel: Set<String>
    public let candidatesToSchedule: [FiveHourResetAlertCandidate]

    public init(
        identifiersToCancel: Set<String>,
        candidatesToSchedule: [FiveHourResetAlertCandidate]
    ) {
        self.identifiersToCancel = identifiersToCancel
        self.candidatesToSchedule = candidatesToSchedule
    }
}

public enum FiveHourResetAlertReconciler {
    public static func plan(
        candidates: [FiveHourResetAlertCandidate],
        pendingIdentifiers: Set<String>
    ) -> FiveHourResetAlertReconciliationPlan {
        let desiredIdentifiers = Set(candidates.map(\.identifier))
        return FiveHourResetAlertReconciliationPlan(
            identifiersToCancel: pendingIdentifiers.subtracting(desiredIdentifiers),
            candidatesToSchedule: candidates.filter {
                !pendingIdentifiers.contains($0.identifier)
            }
        )
    }
}

public enum FiveHourResetAlertPlanner {
    private static let remainingPercentThreshold = 10.0

    /// Returns reset-time alert candidates for fresh snapshots whose 5h window has
    /// strictly less than 10% remaining.
    ///
    /// A candidate fires at `resetsAt`, not at depletion time. Existing identifiers are
    /// accepted so callers can avoid work for notifications they already scheduled.
    public static func candidates(
        from snapshots: [QuotaSnapshot],
        now: Date = Date(),
        existingIdentifiers: Set<String> = []
    ) -> [FiveHourResetAlertCandidate] {
        snapshots.compactMap {
            candidate(from: $0, now: now, existingIdentifiers: existingIdentifiers)
        }
    }

    public static func candidate(
        from snapshot: QuotaSnapshot,
        now: Date = Date(),
        existingIdentifiers: Set<String> = []
    ) -> FiveHourResetAlertCandidate? {
        guard snapshot.confidence == .fresh else { return nil }
        guard let window = snapshot.window(.fiveHour) else { return nil }
        guard window.remainingPercent < remainingPercentThreshold else { return nil }
        guard window.resetsAt > now else { return nil }

        let candidate = FiveHourResetAlertCandidate(
            tool: snapshot.tool,
            usedPercent: window.usedPercent,
            remainingPercent: window.remainingPercent,
            resetsAt: window.resetsAt,
            snapshotUpdatedAt: snapshot.updatedAt
        )
        return existingIdentifiers.contains(candidate.identifier) ? nil : candidate
    }
}
