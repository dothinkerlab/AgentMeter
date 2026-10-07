import XCTest
import AgentMeterCore
@testable import AgentMeter

/// Explicit opt-in only. Never records cookies, amounts or raw console responses.
@MainActor
final class MacTypeSafeLiveTests: XCTestCase {
    func testAuthorizedChromeSessionAutoAndManual() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_TYPESAFE_LIVE"] == "1" else {
            throw XCTSkip("Requires explicit authorization and a signed-in Chrome TypeSafe session")
        }
        let importer = MacTypeSafeChromeImporter()
        let profiles = importer.profiles()
        let profile = try XCTUnwrap(MacTypeSafeController.defaultProfile(profiles), "No Chrome profile")
        let cookies = try await Task.detached {
            try importer.cookies(profileID: profile.id, allowInteraction: true)
        }.value
        let adapter = TypeSafeBillingAdapter()
        let auto = await adapter.fetch(cookieHeader: cookies.billing, usageCookieHeader: cookies.usage)
        guard auto.billing.confidence == .fresh, auto.tokens.confidence == .fresh else {
            XCTFail("Auto result: billing=\(auto.billing.failure?.rawValue ?? "ok"), usage=\(auto.tokens.failure?.rawValue ?? "ok")")
            return
        }
        // Isolated local Keychain item exercises the Manual persistence path without replacing the user's saved cookie.
        let service = "AgentMeter-TypeSafe-Live-Test-\(UUID().uuidString)"
        defer { try? ProviderCredentialStore.delete(kind: .typesafeCookie, service: service) }
        try ProviderCredentialStore.save(TypeSafeCookieHeader.normalize("Cookie: " + cookies.billing),
                                         kind: .typesafeCookie, service: service)
        let manualHeader = try XCTUnwrap(ProviderCredentialStore.read(kind: .typesafeCookie,
                                         service: service, allowInteraction: false))
        let manual = await adapter.fetch(cookieHeader: manualHeader)
        guard manual.billing.confidence == .fresh, manual.tokens.confidence == .fresh else {
            XCTFail("Manual result: billing=\(manual.billing.failure?.rawValue ?? "ok"), usage=\(manual.tokens.failure?.rawValue ?? "ok")")
            return
        }
        // Compare privately without XCTest printing either operand on failure.
        XCTAssertTrue(auto.billing.value == manual.billing.value, "Auto and Manual billing differ")
        XCTAssertTrue(auto.tokens.value == manual.tokens.value, "Auto and Manual usage differ")
        if ProcessInfo.processInfo.environment["AGENTMETER_TYPESAFE_EXPECT_EMPTY"] == "1" {
            XCTAssertTrue(auto.billing.value?.balance == .zero, "Balance differs from the observed console")
            XCTAssertTrue(auto.billing.value?.credits.isEmpty == true, "Credits differ from the observed console")
            XCTAssertTrue(auto.tokens.value?.todayTokens == 0 && auto.tokens.value?.sevenDayTokens == 0
                && auto.tokens.value?.monthTokens == 0 && auto.tokens.value?.monthRequests == 0,
                "Usage differs from the observed empty console")
        }
        let backgroundCookies = try await Task.detached {
            try importer.cookies(profileID: profile.id, allowInteraction: false)
        }.value
        let background = await adapter.fetch(cookieHeader: backgroundCookies.billing,
                                               usageCookieHeader: backgroundCookies.usage)
        XCTAssertTrue(background.confidence == .fresh, "Background refresh did not succeed without interaction")
    }
}
