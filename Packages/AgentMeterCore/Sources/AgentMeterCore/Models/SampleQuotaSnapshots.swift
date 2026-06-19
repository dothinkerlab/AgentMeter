import Foundation

/// Deterministic sample data for previews and release screenshots.
///
/// Production collection still flows through the Mac agent and CloudKit. Apps only
/// use these values when explicitly launched in screenshot mode.
public enum SampleQuotaSnapshots {
    public static func releaseScreenshots(now: Date = Date()) -> [QuotaSnapshot] {
        [
            QuotaSnapshot(
                tool: .claudeCode,
                plan: "Max 5x",
                windows: [
                    QuotaWindow(
                        usedPercent: 62,
                        resetsAt: now.addingTimeInterval(1 * 3600 + 20 * 60),
                        kind: .fiveHour
                    ),
                    QuotaWindow(
                        usedPercent: 41,
                        resetsAt: now.addingTimeInterval(3 * 24 * 3600 + 5 * 3600),
                        kind: .sevenDay
                    )
                ],
                confidence: .fresh,
                source: "screenshot_sample",
                updatedAt: now.addingTimeInterval(-4 * 60)
            ),
            QuotaSnapshot(
                tool: .codex,
                plan: "Pro",
                windows: [
                    QuotaWindow(
                        usedPercent: 27,
                        resetsAt: now.addingTimeInterval(2 * 3600 + 45 * 60),
                        kind: .fiveHour
                    ),
                    QuotaWindow(
                        usedPercent: 68,
                        resetsAt: now.addingTimeInterval(5 * 24 * 3600 + 7 * 3600),
                        kind: .sevenDay
                    )
                ],
                confidence: .fresh,
                source: "screenshot_sample",
                updatedAt: now.addingTimeInterval(-6 * 60)
            )
        ]
    }
}
