import Foundation
import Testing
@testable import AgentMeterCore

struct QuotaSnapshotTests {

    private func fresh() -> QuotaSnapshot {
        QuotaSnapshot(
            tool: .claudeCode, plan: "Max 5x",
            windows: [QuotaWindow(usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_750_000_000), kind: .fiveHour)],
            confidence: .fresh, source: "oauth_usage_endpoint",
            updatedAt: Date(timeIntervalSince1970: 1_749_900_000)
        )
    }

    @Test func markedStaleKeepsDataAndAgeButFlipsConfidence() {
        let original = fresh()
        let stale = original.markedStale()
        #expect(stale.confidence == .stale)
        // 窗口和真实数据年龄都保留 —— 不冒充新数,UI 自行据 updatedAt 判旧。
        #expect(stale.windows == original.windows)
        #expect(stale.updatedAt == original.updatedAt)
        #expect(stale.plan == original.plan)
    }

    @Test func unknownPlaceholderHasNoWindows() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let snap = QuotaSnapshot.unknown(tool: .claudeCode, source: "oauth_usage_endpoint", now: now)
        #expect(snap.confidence == .unknown)
        #expect(snap.windows.isEmpty)
        #expect(snap.updatedAt == now)
    }

    @Test func inactiveThresholdStartsAfterFortyEightHours() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let recent = QuotaSnapshot(
            tool: .claudeCode, plan: nil, windows: [],
            confidence: .fresh, source: "test",
            updatedAt: now.addingTimeInterval(-QuotaSnapshot.inactiveHideThreshold)
        )
        let old = QuotaSnapshot(
            tool: .codex, plan: nil, windows: [],
            confidence: .stale, source: "test",
            updatedAt: now.addingTimeInterval(-QuotaSnapshot.inactiveHideThreshold - 1)
        )

        #expect(!recent.isInactive(now: now))
        #expect(old.isInactive(now: now))
    }
}
