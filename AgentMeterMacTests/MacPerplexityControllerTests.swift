import XCTest
import SwiftUI
import SweetCookieKit
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class MacPerplexityControllerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "PerplexityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultAutoDisabledDoesNotReadSecrets() async {
        let browser = FakePerplexityBrowser()
        let store = FakePerplexityStore()
        let controller = MacPerplexityController(defaults: defaults(), importer: browser, credentials: store)
        XCTAssertEqual(controller.source, .auto)
        XCTAssertFalse(controller.enabled)
        await controller.collect(allowInteraction: true)
        await controller.loadSettings()
        XCTAssertEqual(browser.profileReads, 0)
        XCTAssertEqual(browser.calls.count, 0)
        XCTAssertTrue(store.reads.isEmpty)
        XCTAssertNil(controller.usage)
    }

    func testProfileSelectionAndFixedProfileOnFailure() async {
        let candidates = [MacPerplexityProfile(id: "z", name: "Zed"), .init(id: "a", name: "Alpha")]
        XCTAssertEqual(MacPerplexityController.defaultProfile(candidates)?.id, "a")
        XCTAssertEqual(MacPerplexityController.defaultProfile(candidates + [.init(id: "d", name: "Default")])?.id, "d")
        XCTAssertEqual(MacPerplexityController.defaultProfile([candidates[0]])?.id, "z")
        let browser = FakePerplexityBrowser()
        browser.discovered = candidates
        let controller = MacPerplexityController(defaults: defaults(), importer: browser, credentials: FakePerplexityStore())
        controller.setEnabled(true)
        await controller.loadSettings()
        XCTAssertEqual(controller.profileID, "a")
        controller.setProfile("removed-profile")
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertEqual(controller.profileID, "removed-profile")
        XCTAssertEqual(browser.calls.last?.0, "removed-profile")
        XCTAssertEqual(controller.usage?.failure, .accessDenied)
    }

    func testManualValidationStorageAndNoBrowserFallback() async throws {
        let browser = FakePerplexityBrowser()
        let store = FakePerplexityStore()
        let controller = MacPerplexityController(defaults: defaults(), importer: browser, credentials: store)
        controller.setSource(.manual)
        XCTAssertThrowsError(try controller.saveManualCookie("Cookie: authjs.session-token=x\nInjected=y"))
        XCTAssertNil(store.cookie)
        try controller.saveManualCookie(" Cookie: authjs.session-token=test; other=x=y ")
        XCTAssertEqual(store.cookie, "authjs.session-token=test")
        XCTAssertTrue(controller.hasManualCookie)
        store.failRead = true
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertEqual(store.reads.last, false)
        XCTAssertEqual(browser.calls.count, 0)
        XCTAssertEqual(controller.usage?.failure, .accessDenied)
        await controller.collect(allowInteraction: true)
        XCTAssertEqual(store.reads.last, true)
        try controller.deleteManualCookie()
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(controller.hasManualCookie)
        XCTAssertNil(controller.usage)
        XCTAssertNil(store.cookie)
    }

    func testAutoPermissionsAndNoManualFallback() async {
        let browser = FakePerplexityBrowser()
        let store = FakePerplexityStore()
        store.cookie = "authjs.session-token=manual"
        let controller = MacPerplexityController(defaults: defaults(), importer: browser, credentials: store)
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertEqual(browser.calls.last?.1, false)
        await controller.collect(allowInteraction: true)
        XCTAssertEqual(browser.calls.last?.1, true)
        XCTAssertEqual(store.reads.count, 0)
        XCTAssertNil(controller.usage?.credits)
    }

    func testDisableSourceAndProfileChangesRejectOldRequests() async throws {
        for change in 0..<3 {
            let transport = GatedPerplexityTransport()
            let store = FakePerplexityStore()
            store.cookie = "authjs.session-token=test"
            let controller = MacPerplexityController(defaults: defaults(), importer: FakePerplexityBrowser(),
                credentials: store, adapter: PerplexityCreditsAdapter(transport: transport))
            controller.setSource(.manual)
            controller.setEnabled(true)
            let task = Task { await controller.collect() }
            // Wait until the usage request has entered the injected transport.
            await transport.waitUntilStarted()
            switch change {
            case 0: controller.setEnabled(false)
            case 1: controller.setSource(.auto)
            default: controller.setProfile("another-account")
            }
            XCTAssertNil(controller.usage)
            await transport.release()
            await task.value
            XCTAssertNil(controller.usage, "An obsolete request must never restore old account data")
            XCTAssertFalse(controller.checking)
        }
    }

    func testChangedChromeSessionClearsFactsBeforeRequestAndAfterImportFailure() async throws {
        let browser = FakePerplexityBrowser()
        browser.cookie = "authjs.session-token=account-A"
        let transport = SessionChangePerplexityTransport(statuses: [200, 503])
        let controller = MacPerplexityController(defaults: defaults(), importer: browser,
            credentials: FakePerplexityStore(), adapter: PerplexityCreditsAdapter(transport: transport))
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertNotNil(controller.usage?.credits)
        let profile = controller.profileID
        browser.cookie = nil
        await controller.collect()
        XCTAssertEqual(controller.usage?.confidence, .stale)
        browser.cookie = "authjs.session-token=account-B"
        await transport.holdNextRequest()
        let request = Task { await controller.collect() }
        await transport.waitUntilStarted()
        XCTAssertNil(controller.usage, "Old facts must be cleared before a new session's HTTP response")
        await transport.release()
        await request.value
        XCTAssertNil(controller.usage?.credits)
        XCTAssertNil(controller.usage?.updatedAt)
        XCTAssertEqual(controller.usage?.failure, .unavailable)
        XCTAssertEqual(controller.usage?.confidence, .unknown)
        XCTAssertEqual(controller.profileID, profile)
    }

    func testChangedSessionAfterAuthenticationFailureCannotRetainOldAccount() async {
        let browser = FakePerplexityBrowser()
        browser.cookie = "authjs.session-token=account-A"
        let transport = SessionChangePerplexityTransport(statuses: [200, 401, 503])
        let controller = MacPerplexityController(defaults: defaults(), importer: browser,
            credentials: FakePerplexityStore(), adapter: PerplexityCreditsAdapter(transport: transport))
        controller.setEnabled(true)
        await controller.collect()
        await controller.collect()
        XCTAssertEqual(controller.usage?.failure, .authExpired)
        XCTAssertNotNil(controller.usage?.credits)
        browser.cookie = "authjs.session-token=account-B"
        await controller.collect()
        XCTAssertNil(controller.usage?.credits)
        XCTAssertEqual(controller.usage?.confidence, .unknown)
    }

    func testUnchangedSessionKeepsSuccessfulFactsAndExternalManualReplacementClearsThem() async {
        let store = FakePerplexityStore()
        store.cookie = "authjs.session-token=account-A"
        let transport = SessionChangePerplexityTransport(statuses: [200, 503, 503])
        let controller = MacPerplexityController(defaults: defaults(), importer: FakePerplexityBrowser(),
            credentials: store, adapter: PerplexityCreditsAdapter(transport: transport))
        controller.setSource(.manual)
        controller.setEnabled(true)
        await controller.collect()
        let successful = controller.usage
        await controller.collect()
        XCTAssertEqual(controller.usage?.credits, successful?.credits)
        XCTAssertEqual(controller.usage?.updatedAt, successful?.updatedAt)
        XCTAssertEqual(controller.usage?.confidence, .stale)
        store.cookie = "authjs.session-token=account-B"
        await controller.collect()
        XCTAssertNil(controller.usage?.credits)
        XCTAssertNil(controller.usage?.updatedAt)
        XCTAssertEqual(controller.usage?.confidence, .unknown)
    }

    func testCookieScopesExpiryAndPaths() {
        let now = Date()
        func cookie(_ name: String, domain: String = "www.perplexity.ai", path: String = "/",
                    expires: Date? = nil, scope: BrowserCookieScope = .hostOnly) -> BrowserCookieRecord {
            .init(domain: domain, name: name, path: path, value: "v", expires: expires,
                  isSecure: true, isHTTPOnly: true, scope: scope)
        }
        let records = [cookie("authjs.session-token.0"), cookie("authjs.session-token.1", domain: "perplexity.ai", scope: .domain),
                       cookie("unrelated"), cookie("next-auth.session-token", path: "/account"),
                       cookie("__Secure-authjs.session-token", domain: "evilperplexity.ai", scope: .domain),
                       cookie("next-auth.session-token", expires: now.addingTimeInterval(-1))]
        XCTAssertEqual(MacPerplexityChromeImporter.header(records, path: "/rest/billing/credits", now: now),
                       "authjs.session-token.0=v; authjs.session-token.1=v")
    }

    func testDiagnosticsExcludeCreditAmountsAndCredentials() throws {
        let usage = PerplexityUsage(credits: .init(recurring: .init(total: 987654, used: 123456),
            purchased: .init(total: 0, used: 0), bonus: .init(total: 0, used: 0)), updatedAt: Date(), failure: .accessDenied)
        let statuses = MacPerplexityDiagnostics.statuses(for: usage)
        let json = AgentMeterDiagnosticReport(appVersion: "test", appBuild: "test", platform: "Mac",
            operatingSystem: "test", snapshots: [], localServices: statuses).text
        XCTAssertEqual(statuses.count, 1)
        for sensitive in ["987654", "123456", "Cookie", "session="] { XCTAssertFalse(json.contains(sensitive)) }
        XCTAssertTrue(json.contains("Perplexity account credits"))
        XCTAssertTrue(json.contains("credentialReadFailed"))
    }

    func testBothLocalizationsCoverSettingsAndErrors() throws {
        let keys = ["启用 Perplexity 采集", "周期积分", "购买积分", "奖励积分", "更新时间", "账户积分", "登录来源",
                    "打开 Perplexity 账户用量页", "删除手动 Cookie", "同步 Perplexity 到 iCloud"]
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), "MISSING")
            }
        }
    }

    func testSettingsRender() async throws {
        // Fake dependencies keep rendering independent from the user's Chrome and Keychain.
        let controller = MacPerplexityController(defaults: defaults(), importer: FakePerplexityBrowser(),
                                                credentials: FakePerplexityStore())
        await controller.loadSettings()
        for language in [Bundle.main.preferredLocalizations.first ?? "en"] {
            for source in PerplexityCookieSource.allCases {
                controller.setSource(source)
                let view = NSHostingView(rootView: MacPerplexitySettingsView(controller: controller)
                    .environment(\.locale, Locale(identifier: language)))
                view.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/perplexity-\(language)-\(source.rawValue).png"))
            }
        }
    }
}

private final class FakePerplexityBrowser: MacPerplexityCookieImporting, @unchecked Sendable {
    private let lock = NSLock()
    var discovered = [MacPerplexityProfile(id: "default", name: "Default")]
    private var recorded: [(String, Bool)] = []
    private var recordedProfiles = 0
    private var imported: String?
    var cookie: String? {
        get { lock.withLock { imported } }
        set { lock.withLock { imported = newValue } }
    }
    var profileReads: Int { lock.withLock { recordedProfiles } }
    var calls: [(String, Bool)] { lock.withLock { recorded } }
    func profiles() -> [MacPerplexityProfile] {
        lock.withLock { recordedProfiles += 1 }
        return discovered
    }
    func cookies(profileID: String, allowInteraction: Bool) throws -> MacPerplexityCookies {
        let header = lock.withLock { recorded.append((profileID, allowInteraction)); return imported }
        if let header { return MacPerplexityCookies(header: header) }
        throw PerplexityFailure.accessDenied
    }
}

private final class FakePerplexityStore: MacPerplexityCredentialStoring, @unchecked Sendable {
    var cookie: String?
    var failRead = false
    var reads: [Bool] = []
    func read(allowInteraction: Bool) throws -> String? {
        reads.append(allowInteraction)
        if failRead { throw PerplexityFailure.accessDenied }
        return cookie
    }
    func save(_ value: String) throws { cookie = value }
    func delete() throws { cookie = nil }
}

private actor GatedPerplexityTransport: APICostHTTPTransport {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path == "/rest/billing/credits" {
            await withCheckedContinuation { continuation in
                gate = continuation
                started = true
                waiter?.resume(); waiter = nil
            }
            return (Data(#"{"balance_cents":0,"current_period_purchased_cents":0,"credit_grants":[],"total_usage_cents":0}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!)
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SessionChangePerplexityTransport: APICostHTTPTransport {
    private var statuses: [Int]
    private var holdNext = false
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(statuses: [Int]) { self.statuses = statuses }
    func holdNextRequest() { holdNext = true; started = false }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                gate = continuation; started = true; waiter?.resume(); waiter = nil
            }
        }
        let status = statuses.removeFirst()
        let body = Data(#"{"balance_cents":100,"current_period_purchased_cents":0,"credit_grants":[{"type":"recurring","amount_cents":100}],"total_usage_cents":0}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
