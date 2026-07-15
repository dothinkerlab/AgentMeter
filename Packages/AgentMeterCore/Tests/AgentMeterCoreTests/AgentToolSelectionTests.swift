import Foundation
import Testing
@testable import AgentMeterCore

struct AgentToolSelectionTests {

    @Test func defaultsToClaudeAndCodex() {
        #expect(AgentToolSelection.parseTools(env: [:], args: []) == [.claudeCode, .codex])
        #expect(!AgentToolSelection.defaultTools.contains(.grok))
    }

    @Test func multiToolEnvParsedAndTrimmed() {
        let env = ["AGENTMETER_TOOLS": "codex, claudeCode"]
        #expect(AgentToolSelection.parseTools(env: env, args: []) == [.codex, .claudeCode])
    }

    @Test func singleToolEnvOverridesPlural() {
        let env = ["AGENTMETER_TOOL": "codex", "AGENTMETER_TOOLS": "claudeCode,codex"]
        #expect(AgentToolSelection.parseTools(env: env, args: []) == [.codex])
    }

    @Test func toolArgOverrides() {
        #expect(AgentToolSelection.parseTools(env: [:], args: ["--tool", "codex"]) == [.codex])
        #expect(AgentToolSelection.parseTools(env: [:], args: ["--tool=claudeCode"]) == [.claudeCode])
    }

    @Test func invalidPluralFallsBackToDefault() {
        let env = ["AGENTMETER_TOOLS": "nope,bad"]
        #expect(AgentToolSelection.parseTools(env: env, args: []) == [.claudeCode, .codex])
    }

    @Test func dedupePreservesOrder() {
        let env = ["AGENTMETER_TOOLS": "codex,codex,claudeCode"]
        #expect(AgentToolSelection.parseTools(env: env, args: []) == [.codex, .claudeCode])
    }
}
