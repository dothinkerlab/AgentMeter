import Foundation
import Testing
@testable import AgentMeterCore

struct PlanProviderTests {
    @Test func catalogOrderAndMappingsAreStable() {
        #expect(PlanProviderKind.allCases == [
            .chatGPT, .claude, .cursor, .kimiCode, .glmCoding, .miniMax,
        ])
        #expect(PlanProviderKind.chatGPT.toolKind == .codex)
        #expect(PlanProviderKind.claude.toolKind == .claudeCode)
        #expect(PlanProviderKind.cursor.toolKind == .cursor)
        #expect(PlanProviderKind.cursor.collectionMode == .macAutomatic)
        #expect(PlanProviderKind.chatGPT.collectionMode == .macAutomatic)
        #expect(PlanProviderKind.claude.manualProvider == nil)
        #expect(PlanProviderKind.kimiCode.manualProvider == .kimiCode)
        #expect(PlanProviderKind.glmCoding.collectionMode == .deviceConfigured)
    }

    @Test func mainVisibilityDefaultsOnAndPersistsIndependently() throws {
        let suite = "PlanProviderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(MainToolVisibilityPreferences.key(for: .codex) ==
                "mainToolVisibility.codex.enabled")
        #expect(MainToolVisibilityPreferences.key(for: .claudeCode) ==
                "mainToolVisibility.claudeCode.enabled")
        #expect(MainToolVisibilityPreferences.isVisible(.codex, defaults: defaults))
        #expect(MainToolVisibilityPreferences.isVisible(.claudeCode, defaults: defaults))

        MainToolVisibilityPreferences.setVisible(false, for: .codex, defaults: defaults)
        #expect(!MainToolVisibilityPreferences.isVisible(.codex, defaults: defaults))
        #expect(MainToolVisibilityPreferences.isVisible(.claudeCode, defaults: defaults))
        #expect(MainToolVisibilityPreferences.visibleTools(
            in: [.codex, .claudeCode, .kimiCode], defaults: defaults
        ) == [.claudeCode, .kimiCode])

        MainToolVisibilityPreferences.setVisible(false, for: .kimiCode, defaults: defaults)
        #expect(MainToolVisibilityPreferences.isVisible(.kimiCode, defaults: defaults))
    }
}
