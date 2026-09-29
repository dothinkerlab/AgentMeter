import Foundation
import Testing
@testable import AgentMeterCore

struct P0ProviderAdapterTests {
    @Test func copilotParsesPremiumChatAndOptionalReset() throws {
        let data = Data(#"""
        {
          "copilot_plan":"individual_pro",
          "quota_reset_date_utc":"2026-10-01T00:00:00Z",
          "quota_snapshots":{
            "premium_interactions":{"entitlement":300,"credits_used":75,"percent_remaining":75,"unlimited":false,"has_quota":true},
            "chat":{"percent_remaining":40,"unlimited":false,"has_quota":true}
          }
        }
        """#.utf8)
        let snapshot = try CopilotUsageAdapter().parse(data: data, now: Date(timeIntervalSince1970: 10))
        #expect(snapshot.tool == .copilot)
        #expect(snapshot.plan == "Individual Pro")
        #expect(snapshot.window(.premiumInteractions)?.usedPercent == 25)
        #expect(snapshot.window(.chat)?.usedPercent == 60)
        #expect(snapshot.window(.chat)?.resetsAt != nil)
    }

    @Test func copilotUnlimitedDoesNotInventAWindow() throws {
        let data = Data(#"{"copilot_plan":"business","quota_snapshots":{"premium_interactions":{"unlimited":true}}}"#.utf8)
        let snapshot = try CopilotUsageAdapter().parse(data: data)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.confidence == .fresh)
        #expect(CopilotUsageAdapter.staleReason(for: CopilotUsageAdapter.FetchError.unauthorized) == .authExpired)
    }

    @Test func windsurfParsesQuotaAndCounterFallbackShapes() throws {
        let now = Date(timeIntervalSince1970: 100)
        let quota = try WindsurfLocalAdapter().parse(data: Data(#"""
        {
          "planName":"Pro", "quotaUsage":{"dailyQuotaUsedPercent":20,"weeklyQuotaUsedPercent":45}
        }
        """#.utf8), updatedAt: now)
        #expect(quota.plan == "Pro")
        #expect(quota.window(.daily)?.usedPercent == 20)
        #expect(quota.window(.weekly)?.usedPercent == 45)

        let counters = try WindsurfLocalAdapter().parse(data: Data(#"""
        {
          "usage":{"usedMessages":20,"messages":80,"usedFlowActions":3,"flowActions":12}
        }
        """#.utf8), updatedAt: now)
        #expect(counters.window(.messages)?.usedPercent == 25)
        #expect(counters.window(.flowActions)?.usedPercent == 25)
        #expect(counters.window(.messages)?.resetsAt == nil)

    }

    @Test func windsurfParsesDoubleEncodedCache() throws {
        let nested = try WindsurfLocalAdapter().parse(
            data: try JSONEncoder().encode(#"{"usedMessages":1,"messages":4}"#),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        #expect(nested.window(.messages)?.usedPercent == 25)
    }

    @Test func jetBrainsParsesEncodedAttributesAndRefill() throws {
        let xml = #"<application><component name="AI"><option quotaInfo="{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:25,&quot;maximum&quot;:100,&quot;tariffQuota&quot;:{&quot;available&quot;:75}}" nextRefill="{&quot;type&quot;:&quot;Known&quot;,&quot;next&quot;:&quot;2026-10-15T00:00:00Z&quot;}" /></component></application>"#
        let snapshot = try JetBrainsAILocalAdapter().parse(
            data: Data(xml.utf8), plan: "IntelliJIdea2026.1", updatedAt: Date(timeIntervalSince1970: 50)
        )
        #expect(snapshot.tool == .jetBrainsAI)
        #expect(snapshot.window(.monthly)?.usedPercent == 25)
        #expect(snapshot.window(.monthly)?.resetsAt != nil)
    }

    @Test func zedParsesEditPredictionUsageAndUnlimitedPlans() throws {
        let metered = try ZedUsageAdapter().parse(data: Data(#"""
        {
          "plan":{"plan_v3":"pro","usage":{"edit_predictions":{"used":40,"limit":100}}},
          "subscription_period":{"ended_at":"2026-11-01T00:00:00Z"}
        }
        """#.utf8))
        #expect(metered.plan == "Pro")
        #expect(metered.window(.editPredictions)?.usedPercent == 40)
        #expect(metered.window(.editPredictions)?.resetsAt != nil)

        let unlimited = try ZedUsageAdapter().parse(data: Data(#"""
        {
          "plan":{"plan_v3":"business","usage":{"edit_predictions":{"unlimited":true}}}
        }
        """#.utf8))
        #expect(unlimited.plan == "Business")
        #expect(unlimited.windows.isEmpty)
    }

    @Test func zedRequiresCredentialAndRequestOriginsToMatch() throws {
        let defaultServers = try ZedUsageAdapter.resolvedServers(serverRaw: nil, credentialsRaw: nil)
        #expect(defaultServers.0.absoluteString == "https://zed.dev")
        #expect(defaultServers.1.absoluteString == "https://zed.dev")

        let custom = try ZedUsageAdapter.resolvedServers(
            serverRaw: "https://zed.example:8443",
            credentialsRaw: "https://zed.example:8443/credentials"
        )
        #expect(custom.0.port == 8443)
        #expect(throws: ZedUsageAdapter.FetchError.invalidServer) {
            try ZedUsageAdapter.resolvedServers(
                serverRaw: "https://zed.example",
                credentialsRaw: "https://attacker.example"
            )
        }
        #expect(throws: ZedUsageAdapter.FetchError.invalidServer) {
            try ZedUsageAdapter.resolvedServers(serverRaw: "http://zed.example", credentialsRaw: nil)
        }
    }

    @Test func optionalResetRoundTripsWithoutInventingADate() throws {
        let window = QuotaWindow(usedPercent: 42, resetsAt: nil, kind: .messages)
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: JSONEncoder().encode(window))
        #expect(decoded == window)
        #expect(decoded.resetsAt == nil)
    }
}
