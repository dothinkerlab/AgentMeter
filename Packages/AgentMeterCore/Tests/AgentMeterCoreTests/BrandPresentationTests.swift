import Testing
@testable import AgentMeterCore

struct BrandPresentationTests {
    @Test func mainlandNamesUseRequestedAliases() {
        let mode = BrandPresentationMode.mainlandChina
        #expect(BrandPresentation.text("Codex", mode: mode) == "CX")
        #expect(BrandPresentation.text("Claude Code / Claude", mode: mode) == "CC / CC")
        #expect(BrandPresentation.text("OpenAI and ChatGPT", mode: mode) == "O记 and O记")
        #expect(BrandPresentation.text("Anthropic API", mode: mode) == "A➗ API")
        #expect(BrandPresentation.text("ClaudeDevs", mode: mode) == "CCDevs")
    }

    @Test func matchingIsCaseInsensitiveAndHandlesDynamicText() {
        let masked = BrandPresentation.text(
            "CODEX reset for chatgpt; claude code by ANTHROPIC and OPENAI.",
            mode: .mainlandChina
        )
        #expect(masked == "CX reset for O记; CC by A➗ and O记.")
    }

    @Test func standardPresentationIsUnchanged() {
        let original = "Claude Code, Codex, OpenAI, Anthropic, ChatGPT"
        #expect(BrandPresentation.text(original, mode: .standard) == original)
    }

    @Test func toolDisplayNamesDoNotChangeToolIdentifiers() {
        #expect(BrandPresentation.displayName(for: .claudeCode, mode: .mainlandChina) == "CC")
        #expect(BrandPresentation.displayName(for: .codex, mode: .mainlandChina) == "CX")
        #expect(ToolKind.claudeCode.rawValue == "claudeCode")
        #expect(ToolKind.codex.rawValue == "codex")
    }

    @Test func internalIdentifiersCredentialsAndURLsAreProtected() {
        let mode = BrandPresentationMode.mainlandChina
        #expect(BrandPresentation.text("claudeCode", mode: mode) == "claudeCode")
        #expect(BrandPresentation.text("Claude Code-credentials", mode: mode) == "Claude Code-credentials")
        #expect(BrandPresentation.text("https://api.openai.com/v1", mode: mode) == "https://api.openai.com/v1")
    }

    @Test func storefrontCountryCodeMappingIsAuthoritativeAndFailClosed() {
        #expect(BrandPresentationMode.storefront(countryCode: "CHN") == .mainlandChina)
        #expect(BrandPresentationMode.storefront(countryCode: "chn") == .mainlandChina)
        #expect(BrandPresentationMode.storefront(countryCode: "USA") == .standard)
        #expect(BrandPresentationMode.storefront(countryCode: nil) == .mainlandChina)
    }

    @Test func injectedStorefrontProviderCoversCurrentFailureAndUpdates() async {
        let provider = MockStorefrontProvider(current: nil, updates: ["CHN", "USA"])
        let resolver = BrandStorefrontResolver(provider: provider)

        #expect(await resolver.refresh() == .mainlandChina)

        var received: [BrandPresentationMode] = []
        for await mode in resolver.updates {
            received.append(mode)
        }
        #expect(received == [.mainlandChina, .standard])
    }
}

private struct MockStorefrontProvider: BrandStorefrontCountryCodeProviding {
    let current: String?
    let updateValues: [String?]

    init(current: String?, updates: [String?] = []) {
        self.current = current
        self.updateValues = updates
    }

    func currentCountryCode() async -> String? { current }

    var countryCodeUpdates: AsyncStream<String?> {
        AsyncStream { continuation in
            for value in updateValues {
                continuation.yield(value)
            }
            continuation.finish()
        }
    }
}
