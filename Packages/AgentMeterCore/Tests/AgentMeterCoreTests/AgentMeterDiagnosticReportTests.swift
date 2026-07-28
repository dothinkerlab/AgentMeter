import XCTest
@testable import AgentMeterCore

final class AgentMeterDiagnosticReportTests: XCTestCase {
    func testReportContainsSyncFactsAndOmitsCredentialConcepts() {
        let updatedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let resetsAt = Date(timeIntervalSince1970: 1_725_018_000)
        let snapshot = QuotaSnapshot(
            tool: .claudeCode,
            plan: "Max",
            windows: [
                QuotaWindow(usedPercent: 42.25, resetsAt: resetsAt, kind: .fiveHour),
            ],
            confidence: .stale,
            staleReason: .networkFailure,
            collectedBy: .mac,
            source: "oauth_usage_endpoint",
            updatedAt: updatedAt
        )
        let report = AgentMeterDiagnosticReport(
            generatedAt: updatedAt,
            appVersion: "1.6",
            appBuild: "17",
            platform: "iPhone",
            operatingSystem: "iOS 26.0",
            snapshots: [snapshot],
            localServices: [
                .init(
                    service: "OpenRouter",
                    confidence: .fresh,
                    staleReason: nil,
                    updatedAt: updatedAt
                ),
            ],
            cloudSyncPendingTools: [.claudeCode]
        )

        XCTAssertTrue(report.text.contains("claudeCode"))
        XCTAssertTrue(report.text.contains("used=42.2%"))
        XCTAssertTrue(report.text.contains("networkFailure"))
        XCTAssertTrue(report.text.contains("CloudKit writes pending: claudeCode"))
        XCTAssertTrue(report.text.contains("OpenRouter"))
        XCTAssertFalse(report.text.contains("Max"))
        XCTAssertFalse(report.text.localizedCaseInsensitiveContains("accessToken"))
        XCTAssertFalse(report.text.localizedCaseInsensitiveContains("apiKey"))
    }

    func testEmptyReportIsStillActionable() {
        let report = AgentMeterDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0",
            appBuild: "1",
            platform: "Mac",
            operatingSystem: "macOS",
            snapshots: []
        )

        XCTAssertTrue(report.text.contains("Coding plan snapshots:\n- none"))
        XCTAssertTrue(report.text.contains("Expected CloudKit environment:"))
        XCTAssertEqual(report.suggestedFilename, "AgentMeter-Diagnostics-19700101-000000.txt")
    }
}
