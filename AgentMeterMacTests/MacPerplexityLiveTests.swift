import XCTest
import AgentMeterCore
@testable import AgentMeter

/// Explicit opt-in only; never prints sessions, raw responses or credit amounts.
@MainActor
final class MacPerplexityLiveTests: XCTestCase {
    func testAuthorizedChromeAutoManualAndBackground() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_PERPLEXITY_LIVE"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized, signed-in Chrome Perplexity session")
        }
        let importer = MacPerplexityChromeImporter()
        let profile = try XCTUnwrap(MacPerplexityController.defaultProfile(importer.profiles()), "No Chrome profile")
        let cookies: MacPerplexityCookies
        print("Perplexity live: initial Chrome Safe Storage read requested")
        do {
            cookies = try await Task.detached { try importer.cookies(profileID: profile.id, allowInteraction: true) }.value
        } catch {
            throw XCTSkip("A signed-in Perplexity session with authorized Chrome Safe Storage access is required")
        }
        print("Perplexity live: session imported; requesting credits")
        let adapter = PerplexityCreditsAdapter()
        let auto = await adapter.fetch(cookie: cookies.header)
        if auto.failure == .challenge || auto.failure == .authExpired {
            throw XCTSkip("Perplexity live read blocked: \(auto.failure?.rawValue ?? "unknown")")
        }
        guard auto.confidence == .fresh else {
            XCTFail("Auto collection failed: \(auto.failure?.rawValue ?? "unknown")")
            return
        }
        let service = "AgentMeter-Perplexity-Live-Test-\(UUID().uuidString)"
        defer { try? ProviderCredentialStore.delete(kind: .perplexityCookie, service: service) }
        try ProviderCredentialStore.save(PerplexityCookieHeader.normalize("Cookie: " + cookies.header),
                                         kind: .perplexityCookie, service: service)
        let manualCookie = try XCTUnwrap(MacBrowserCookieAccess.read(allowInteraction: false) {
            try ProviderCredentialStore.read(kind: .perplexityCookie, service: service, allowInteraction: false)
        })
        let manual = await adapter.fetch(cookie: manualCookie)
        XCTAssertTrue(manual.confidence == .fresh, "Manual collection did not return fresh data")
        XCTAssertTrue(auto.credits == manual.credits, "Auto and Manual credit facts differ")
        print("Perplexity live: Auto and Manual compared; checking background read")
        let backgroundCookie = try await Task.detached { try importer.cookies(profileID: profile.id, allowInteraction: false) }.value
        let background = await adapter.fetch(cookie: backgroundCookie.header)
        XCTAssertTrue(background.confidence == .fresh, "Background collection did not succeed without interaction")
        print("Perplexity live: completed")
    }
}
