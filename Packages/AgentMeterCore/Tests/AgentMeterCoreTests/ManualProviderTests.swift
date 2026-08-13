import Foundation
import Testing
@testable import AgentMeterCore

struct ManualProviderTests {
    @Test func providerMappingsCoverAllServices() {
        #expect(ManualProviderKind.allCases.count == 10)
        #expect(ManualProviderKind.kimiCode.toolKind == .kimiCode)
        #expect(ManualProviderKind.kimiAPI.toolKind == nil)
        #expect(ManualProviderKind.xAI.toolKind == .grok)
        #expect(ManualProviderKind.deepSeek.localBillingService == .deepSeek)
        #expect(ManualProviderKind.glmCoding.localBillingService == nil)
        #expect(ManualProviderKind.xAI.credentialShape == .managementKeyAndTeamID)
        #expect(ManualProviderKind.openAIAPI.toolKind == nil)
        #expect(ManualProviderKind.openAIAPI.localBillingService == .openAIAPI)
        #expect(ManualProviderKind.anthropicAPI.localBillingService == .anthropicAPI)
        #expect(ManualProviderKind.anthropicAPI.credentialShape == .apiKey)
        #expect(ManualProviderKind.cursorTeam.localBillingService == nil)
        #expect(ManualProviderKind.cursorTeam.toolKind == nil)
    }

    @Test func billingProvidersMigrateExistingCredentialsToEnabled() throws {
        let suite = "ManualProviderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ManualProviderPreferences.isEnabled(.deepSeek, credentialExists: true, defaults: defaults))
        #expect(!ManualProviderPreferences.isEnabled(.deepSeek, credentialExists: false, defaults: defaults))
        #expect(ManualProviderPreferences.isEnabled(.openAIAPI, credentialExists: true, defaults: defaults))
        #expect(ManualProviderPreferences.isEnabled(.anthropicAPI, credentialExists: true, defaults: defaults))

        ManualProviderPreferences.setEnabled(false, for: .deepSeek, defaults: defaults)
        #expect(!ManualProviderPreferences.isEnabled(.deepSeek, credentialExists: true, defaults: defaults))
    }

    @Test func codingProviderRetainsLegacyDefaultAndKeys() throws {
        let suite = "ManualProviderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ManualProviderPreferences.enabledKey(.glmCoding) == "codingProvider.glmCoding.enabled")
        #expect(ManualProviderPreferences.regionKey(.miniMax) == "codingProvider.miniMax.region")
        #expect(!ManualProviderPreferences.isEnabled(.glmCoding, credentialExists: true, defaults: defaults))

        ManualProviderPreferences.setEnabled(true, for: .glmCoding, defaults: defaults)
        ManualProviderPreferences.setRegion(.china, for: .glmCoding, defaults: defaults)
        #expect(ManualProviderPreferences.isEnabled(.glmCoding, credentialExists: false, defaults: defaults))
        #expect(ManualProviderPreferences.region(for: .glmCoding, defaults: defaults) == .china)
    }

    @Test func connectionStateDoesNotTreatUnknownAsConnected() {
        #expect(ProviderConnectionState.resolved(
            hasCredential: false, isEnabled: true, confidence: .fresh, staleReason: nil
        ) == .unconfigured)
        #expect(ProviderConnectionState.resolved(
            hasCredential: true, isEnabled: false, confidence: .fresh, staleReason: nil
        ) == .disabled)
        #expect(ProviderConnectionState.resolved(
            hasCredential: true, isEnabled: true, confidence: .fresh, staleReason: nil
        ) == .connected)
        #expect(ProviderConnectionState.resolved(
            hasCredential: true, isEnabled: true, confidence: .unknown, staleReason: .authExpired
        ) == .invalidCredential)
        #expect(ProviderConnectionState.resolved(
            hasCredential: true, isEnabled: true, confidence: .stale, staleReason: .networkFailure
        ) == .pendingVerification(.networkFailure))
    }

    @Test func xAICredentialMergeSupportsPartialUpdates() throws {
        let existing = GrokManagementCredentials(managementKey: "xai-old", teamID: "team-old")

        let teamOnly = try #require(ManualProviderCredentialMerge.xAI(
            existing: existing,
            managementKeyInput: "",
            teamIDInput: " team-new "
        ))
        #expect(teamOnly == .init(managementKey: "xai-old", teamID: "team-new"))

        let keyOnly = try #require(ManualProviderCredentialMerge.xAI(
            existing: existing,
            managementKeyInput: " xai-new ",
            teamIDInput: ""
        ))
        #expect(keyOnly == .init(managementKey: "xai-new", teamID: "team-old"))

        #expect(ManualProviderCredentialMerge.xAI(
            existing: nil,
            managementKeyInput: "",
            teamIDInput: "team-only"
        ) == nil)
    }

    @Test func providerOperationGateRejectsLateAndSupersededVerification() async {
        let gate = ManualProviderOperationGate()
        let first = await gate.begin(.deepSeek)
        let retry = await gate.begin(.deepSeek)
        #expect(!(await gate.isCurrent(first, for: .deepSeek)))
        #expect(await gate.isCurrent(retry, for: .deepSeek))

        await gate.invalidate(.deepSeek)
        #expect(!(await gate.isCurrent(retry, for: .deepSeek)))

        let otherProvider = await gate.begin(.openRouter)
        #expect(await gate.isCurrent(otherProvider, for: .openRouter))
    }
}
