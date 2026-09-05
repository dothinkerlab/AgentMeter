import XCTest
import AgentMeterCore
@testable import AgentMeter

final class MacHealthIssueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_725_000_000)

    func testCloudKitAndCollectionFailuresAreBothReported() {
        let snapshot = makeSnapshot(confidence: .stale, reason: .networkFailure)
        let issues = MacHealthIssueBuilder.codingIssues(
            item: .codex,
            outcome: .writeFailed,
            snapshot: snapshot
        )

        XCTAssertEqual(Set(issues.map(\.kind)), [.cloudKit, .collection])
    }

    func testDeviceCloudSyncPendingIsReportedAndDeduplicated() {
        let first = MacHealthIssueBuilder.codingIssues(
            item: .kimiCode,
            outcome: .writeFailed,
            snapshot: makeSnapshot(tool: .kimiCode),
            cloudSyncPending: true
        )
        let normalized = MacHealthIssueBuilder.normalized(first, displayOrder: [.kimiCode])

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized.first?.kind, .cloudKit)
    }

    func testEveryActionableCollectionReasonIsReported() {
        let reasons: [QuotaStaleReason] = [
            .authExpired, .credentialReadFailed, .networkFailure,
            .endpointFailure, .responseChanged, .unknownFailure,
        ]

        for reason in reasons {
            let issue = MacHealthIssueBuilder.localIssue(
                item: .openRouter,
                confidence: .unknown,
                staleReason: reason
            )
            XCTAssertEqual(issue?.reason, reason)
        }
    }

    func testCodexResetCreditsFailureIsReportedWhenMainQuotaIsFresh() {
        let resetCredits = RateLimitResetCredits.unknown(now: now, reason: .endpointFailure)
        let snapshot = makeSnapshot(resetCredits: resetCredits)
        let issues = MacHealthIssueBuilder.codingIssues(
            item: .codex,
            outcome: .ok,
            snapshot: snapshot
        )

        XCTAssertEqual(issues, [
            MacHealthIssue(item: .codex, kind: .resetCredits, reason: .endpointFailure),
        ])
    }

    func testSkippedFreshAndAgeOnlyStatesDoNotAlert() {
        XCTAssertTrue(MacHealthIssueBuilder.codingIssues(
            item: .claudeCode,
            outcome: .skipped,
            snapshot: makeSnapshot(tool: .claudeCode, confidence: .unknown, reason: .authExpired)
        ).isEmpty)
        XCTAssertNil(MacHealthIssueBuilder.localIssue(
            item: .deepSeek,
            confidence: .fresh,
            staleReason: nil
        ))
        XCTAssertNil(MacHealthIssueBuilder.localIssue(
            item: .deepSeek,
            confidence: .stale,
            staleReason: nil
        ))
        XCTAssertNil(MacHealthIssueBuilder.localIssue(
            item: .deepSeek,
            isEnabled: false,
            confidence: .unknown,
            staleReason: .credentialReadFailed
        ))
    }

    func testSuccessfulRefreshClearsPreviousIssue() {
        let failed = MacHealthIssueBuilder.codingIssues(
            item: .cursor,
            outcome: .degraded,
            snapshot: makeSnapshot(tool: .cursor, confidence: .unknown, reason: .unknownFailure)
        )
        let recovered = MacHealthIssueBuilder.codingIssues(
            item: .cursor,
            outcome: .ok,
            snapshot: makeSnapshot(tool: .cursor)
        )

        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(recovered.isEmpty)
    }

    func testCloudKitIssuesSortFirstAndDisplayOrderIsStable() {
        let issues = [
            MacHealthIssue(item: .codex, kind: .collection, reason: .networkFailure),
            MacHealthIssue(item: .openRouter, kind: .cloudKit, reason: nil),
            MacHealthIssue(item: .claudeCode, kind: .cloudKit, reason: nil),
            MacHealthIssue(item: .codex, kind: .collection, reason: .networkFailure),
        ]
        let normalized = MacHealthIssueBuilder.normalized(
            issues,
            displayOrder: [.codex, .claudeCode, .openRouter]
        )

        XCTAssertEqual(normalized.map(\.item), [.claudeCode, .openRouter, .codex])
        XCTAssertEqual(normalized.map(\.kind), [.cloudKit, .cloudKit, .collection])
    }

    func testIssueOutsideVisibleDisplayOrderIsStillRetained() {
        let hiddenProviderIssue = MacHealthIssue(
            item: .openRouter,
            kind: .collection,
            reason: .networkFailure
        )

        XCTAssertEqual(
            MacHealthIssueBuilder.normalized([hiddenProviderIssue], displayOrder: [.codex]),
            [hiddenProviderIssue]
        )
    }

    func testDebugHostReportsDevelopmentEnvironment() {
        XCTAssertEqual(MacBuildMetadata.buildConfiguration, "Debug")
        XCTAssertEqual(MacBuildMetadata.cloudKitEnvironment, "Development")
    }

    private func makeSnapshot(
        tool: ToolKind = .codex,
        resetCredits: RateLimitResetCredits? = nil,
        confidence: DataConfidence = .fresh,
        reason: QuotaStaleReason? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            plan: nil,
            windows: [],
            resetCredits: resetCredits,
            confidence: confidence,
            staleReason: reason,
            source: "test",
            updatedAt: now
        )
    }
}
