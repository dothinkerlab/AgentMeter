#if os(macOS)
import Foundation
import Testing
@testable import AgentMeterCore

struct MacCodingCredentialResolverTests {
    @Test func readsKimiCLIWithoutChangingItsFile() throws {
        try withTemporaryHome { home in
            let url = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
            let data = Data(#"{"oauth":{"accessToken":"kimi-oauth-token"}}"#.utf8)
            try writeFixture(data, to: url)

            let credential = try MacCodingCredentialResolver.resolve(
                tool: .kimiCode, manualRegion: .china, home: home
            )

            #expect(credential?.secret == "kimi-oauth-token")
            #expect(credential?.source == .kimiCLI)
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func recognizesZAIClaudeSettingsAndPreservesRegion() throws {
        try withTemporaryHome { home in
            let url = home.appendingPathComponent(".claude/settings.json")
            let data = Data(#"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_AUTH_TOKEN":"glm-token"}}"#.utf8)
            try writeFixture(data, to: url)

            let credential = try MacCodingCredentialResolver.resolve(
                tool: .glmCoding, manualRegion: .china, home: home
            )

            #expect(credential?.secret == "glm-token")
            #expect(credential?.region == .global)
            #expect(credential?.source == .claudeSettings)
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func readsMiniMaxCLIRegionWithoutChangingItsFile() throws {
        try withTemporaryHome { home in
            let url = home.appendingPathComponent(".mmx/config.json")
            let data = Data(#"{"api_key":"minimax-token","region":"cn"}"#.utf8)
            try writeFixture(data, to: url)

            let credential = try MacCodingCredentialResolver.resolve(
                tool: .miniMax, manualRegion: .global, home: home
            )

            #expect(credential?.secret == "minimax-token")
            #expect(credential?.region == .china)
            #expect(credential?.source == .miniMaxCLI)
            #expect(try Data(contentsOf: url) == data)
        }
    }
}

private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentMeterMacResolverTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try body(home)
}

private func writeFixture(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}
#endif
