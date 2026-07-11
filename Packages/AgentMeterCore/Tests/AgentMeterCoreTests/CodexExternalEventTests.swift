import Foundation
import Testing
@testable import AgentMeterCore

struct ExternalResetEventTests {
    @Test func defaultBaseURLUsesDothinkerAPIPrefixAndV2Events() throws {
        let url = try #require(URL(string: ExternalResetEventsClient.defaultBaseURLString))
        #expect(url.absoluteString == "https://dothinker.org/api/agentmeter/codex-reset")
        #expect(url.appendingPathComponent("v2/events").absoluteString == "https://dothinker.org/api/agentmeter/codex-reset/v2/events")
    }

    @Test func decodesMixedWorkerEventResponse() throws {
        let data = Data(#"""
        {
          "events": [
            {
              "id": "post.create:1",
              "tool": "claudeCode",
              "source": "x_timeline_poll",
              "kind": "RESET_ANNOUNCEMENT",
              "confidence": "HIGH",
              "postID": "1",
              "postURL": "https://x.com/ClaudeDevs/status/1",
              "postText": "We've reset all limits.",
              "matchedKeywords": ["reset"],
              "createdAt": "2026-07-09T12:00:00Z",
              "detectedAt": "2026-07-09T12:00:03Z",
              "pushedAt": null
            },
            {
              "id": "post.create:2",
              "tool": "codex",
              "source": "x_activity_api",
              "kind": "RESET_ANNOUNCEMENT",
              "confidence": "HIGH",
              "postID": "2",
              "postURL": "https://x.com/thsottiaux/status/2",
              "postText": "Codex usage reset is complete.",
              "matchedKeywords": ["codex", "reset"],
              "createdAt": "2026-07-09T11:00:00Z",
              "detectedAt": "2026-07-09T11:00:03Z",
              "pushedAt": null
            }
          ]
        }
        """#.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(ExternalResetEventsResponse.self, from: data)
        #expect(response.events.map(\.tool) == [.claudeCode, .codex])
        #expect(response.events.allSatisfy { $0.kind == .resetAnnouncement })
    }

    @Test func pendingUntilFreshLocalClaudeCollectionAfterEvent() {
        let event = resetEvent(tool: .claudeCode, detectedAt: Date(timeIntervalSince1970: 1_000))
        let oldSnapshot = snapshot(
            tool: .claudeCode,
            updatedAt: Date(timeIntervalSince1970: 900),
            remaining: 95,
            confidence: .fresh
        )

        let status = ExternalEventVerificationStatus.resolve(
            event: event,
            snapshots: [oldSnapshot],
            now: Date(timeIntervalSince1970: 1_100)
        )
        #expect(status == .pendingLocalCollection)
    }

    @Test func codexSnapshotCannotConfirmClaudeEvent() {
        let event = resetEvent(tool: .claudeCode, detectedAt: Date(timeIntervalSince1970: 1_000))
        let codex = snapshot(
            tool: .codex,
            updatedAt: Date(timeIntervalSince1970: 1_050),
            remaining: 95,
            confidence: .fresh
        )

        let status = ExternalEventVerificationStatus.resolve(
            event: event,
            snapshots: [codex],
            now: Date(timeIntervalSince1970: 1_100)
        )
        #expect(status == .pendingLocalCollection)
    }

    @Test func confirmsResetWithMatchingFreshSnapshotAfterEvent() {
        let event = resetEvent(tool: .claudeCode, detectedAt: Date(timeIntervalSince1970: 1_000))
        let recovered = snapshot(
            tool: .claudeCode,
            updatedAt: Date(timeIntervalSince1970: 1_050),
            remaining: 92,
            confidence: .fresh
        )

        let status = ExternalEventVerificationStatus.resolve(
            event: event,
            snapshots: [recovered],
            now: Date(timeIntervalSince1970: 1_100)
        )
        #expect(status == .confirmedByLocalCollection)
    }

    @Test func expiresUnverifiedResetAfterOneDay() {
        let event = resetEvent(tool: .codex, detectedAt: Date(timeIntervalSince1970: 1_000))
        let status = ExternalEventVerificationStatus.resolve(
            event: event,
            snapshots: [],
            now: Date(timeIntervalSince1970: 1_000 + 24 * 60 * 60 + 1)
        )
        #expect(status == .expiredUnverified)
    }

    private func resetEvent(tool: ToolKind, detectedAt: Date) -> ExternalResetEvent {
        ExternalResetEvent(
            id: "post.create:1",
            tool: tool,
            source: "x_timeline_poll",
            kind: .resetAnnouncement,
            confidence: .high,
            postID: "1",
            postURL: nil,
            postText: "reset",
            matchedKeywords: ["reset"],
            createdAt: detectedAt,
            detectedAt: detectedAt,
            pushedAt: nil
        )
    }

    private func snapshot(
        tool: ToolKind,
        updatedAt: Date,
        remaining: Double,
        confidence: DataConfidence
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            tool: tool,
            plan: "Plus",
            windows: [
                QuotaWindow(
                    usedPercent: 100 - remaining,
                    resetsAt: updatedAt.addingTimeInterval(5 * 60 * 60),
                    kind: .fiveHour
                )
            ],
            confidence: confidence,
            source: "test",
            updatedAt: updatedAt
        )
    }
}
