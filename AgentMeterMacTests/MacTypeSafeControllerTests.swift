import XCTest
import SwiftUI
import SweetCookieKit
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class MacTypeSafeControllerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "TypeSafeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDefaultAutoDisabledDoesNotReadSecrets() async {
        let browser = FakeTypeSafeBrowser()
        let store = FakeTypeSafeStore()
        let controller = MacTypeSafeController(defaults: defaults(), importer: browser, credentials: store)
        XCTAssertEqual(controller.source, .auto)
        XCTAssertFalse(controller.enabled)
        await controller.collect(allowInteraction: true)
        await controller.loadSettings()
        XCTAssertEqual(browser.profileReads, 0)
        XCTAssertEqual(browser.calls.count, 0)
        XCTAssertEqual(store.reads, [false]) // Settings may check local storage without prompting.
        XCTAssertNil(controller.usage)
    }

    func testProfileSelectionAndFixedProfileOnFailure() async {
        let candidates = [MacTypeSafeProfile(id: "z", name: "Zed"), .init(id: "a", name: "Alpha")]
        XCTAssertEqual(MacTypeSafeController.defaultProfile(candidates)?.id, "a")
        XCTAssertEqual(MacTypeSafeController.defaultProfile(candidates + [.init(id: "d", name: "Default")])?.id, "d")
        XCTAssertEqual(MacTypeSafeController.defaultProfile([candidates[0]])?.id, "z")
        let browser = FakeTypeSafeBrowser()
        browser.discovered = candidates
        let controller = MacTypeSafeController(defaults: defaults(), importer: browser, credentials: FakeTypeSafeStore())
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
        let browser = FakeTypeSafeBrowser()
        let store = FakeTypeSafeStore()
        let controller = MacTypeSafeController(defaults: defaults(), importer: browser, credentials: store)
        controller.setSource(.manual)
        XCTAssertThrowsError(try controller.saveManualCookie("Cookie: session=x\nInjected=y"))
        XCTAssertNil(store.cookie)
        try controller.saveManualCookie(" Cookie: session=test; other=x=y ")
        XCTAssertEqual(store.cookie, "session=test; other=x=y")
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
        let browser = FakeTypeSafeBrowser()
        let store = FakeTypeSafeStore()
        store.cookie = "session=manual"
        let controller = MacTypeSafeController(defaults: defaults(), importer: browser, credentials: store)
        controller.setEnabled(true)
        await controller.collect()
        XCTAssertEqual(browser.calls.last?.1, false)
        await controller.collect(allowInteraction: true)
        XCTAssertEqual(browser.calls.last?.1, true)
        XCTAssertEqual(store.reads.count, 0)
        XCTAssertNil(controller.usage?.billing.value)
    }

    func testDisableSourceAndProfileChangesRejectOldRequests() async throws {
        for change in 0..<3 {
            let transport = GatedTypeSafeTransport()
            let store = FakeTypeSafeStore()
            store.cookie = "session=test"
            let controller = MacTypeSafeController(defaults: defaults(), importer: FakeTypeSafeBrowser(),
                credentials: store, adapter: TypeSafeBillingAdapter(transport: transport))
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

    func testCookieScopesExpiryAndPaths() {
        let now = Date()
        func cookie(_ name: String, domain: String = "console.typesafe.ai", path: String = "/",
                    expires: Date? = nil, scope: BrowserCookieScope = .hostOnly) -> BrowserCookieRecord {
            .init(domain: domain, name: name, path: path, value: "v", expires: expires,
                  isSecure: true, isHTTPOnly: true, scope: scope)
        }
        let records = [cookie("root"), cookie("billing", path: "/settings"),
                       cookie("wrongPath", path: "/settings/bill"), cookie("parentHost", domain: "typesafe.ai"),
                       cookie("parentDomain", domain: "typesafe.ai", scope: .domain),
                       cookie("evil", domain: "eviltypesafe.ai", scope: .domain),
                       cookie("expired", expires: now.addingTimeInterval(-1))]
        XCTAssertEqual(MacTypeSafeChromeImporter.header(records, path: "/settings/billing", now: now),
                       "billing=v; root=v; parentDomain=v")
        XCTAssertEqual(MacTypeSafeChromeImporter.header(records, path: "/api/usage", now: now),
                       "root=v; parentDomain=v")
    }

    func testDiagnosticsExcludeAmountsCredentialsAndPlan() throws {
        let usage = TypeSafeUsage(billing: .init(value: .init(balance: Decimal(string: "987.654321")!,
            spent: Decimal(string: "123.456789")!, plan: "private-plan"), updatedAt: Date()),
            tokens: .init(failure: .accessDenied))
        let statuses = MacTypeSafeDiagnostics.statuses(for: usage)
        let json = AgentMeterDiagnosticReport(appVersion: "test", appBuild: "test", platform: "Mac",
            operatingSystem: "test", snapshots: [], localServices: statuses).text
        XCTAssertEqual(statuses.count, 2)
        for sensitive in ["987.654321", "123.456789", "private-plan", "Cookie", "session="] {
            XCTAssertFalse(json.contains(sensitive))
        }
        XCTAssertTrue(json.contains("TypeSafe Billing"))
        XCTAssertTrue(json.contains("credentialReadFailed"))
    }

    func testBothLocalizationsCoverSettingsAndErrors() throws {
        let keys = ["启用 TypeSafe 采集", "余额", "套餐", "到期", "更新时间", "用量", "登录来源",
                    "打开 TypeSafe 官方账单页", "删除手动 Cookie", "本月请求数", "今日 Token"]
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
        let controller = MacTypeSafeController(defaults: defaults(), importer: FakeTypeSafeBrowser(),
                                                credentials: FakeTypeSafeStore())
        await controller.loadSettings()
        for language in [Bundle.main.preferredLocalizations.first ?? "en"] {
            for source in TypeSafeCookieSource.allCases {
                controller.setSource(source)
                let view = NSHostingView(rootView: MacTypeSafeSettingsView(controller: controller)
                    .environment(\.locale, Locale(identifier: language)))
                view.frame = NSRect(x: 0, y: 0, width: 720, height: 700)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 1000)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/typesafe-\(language)-\(source.rawValue).png"))
            }
        }
    }
}

private final class FakeTypeSafeBrowser: MacTypeSafeCookieImporting, @unchecked Sendable {
    private let lock = NSLock()
    var discovered = [MacTypeSafeProfile(id: "default", name: "Default")]
    private var recorded: [(String, Bool)] = []
    private var recordedProfiles = 0
    var profileReads: Int { lock.withLock { recordedProfiles } }
    var calls: [(String, Bool)] { lock.withLock { recorded } }
    func profiles() -> [MacTypeSafeProfile] {
        lock.withLock { recordedProfiles += 1 }
        return discovered
    }
    func cookies(profileID: String, allowInteraction: Bool) throws -> MacTypeSafeCookies {
        lock.withLock { recorded.append((profileID, allowInteraction)) }
        throw TypeSafeFailure.accessDenied
    }
}

private final class FakeTypeSafeStore: MacTypeSafeCredentialStoring, @unchecked Sendable {
    var cookie: String?
    var failRead = false
    var reads: [Bool] = []
    func read(allowInteraction: Bool) throws -> String? {
        reads.append(allowInteraction)
        if failRead { throw TypeSafeFailure.accessDenied }
        return cookie
    }
    func save(_ value: String) throws { cookie = value }
    func delete() throws { cookie = nil }
}

private actor GatedTypeSafeTransport: APICostHTTPTransport {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path == "/api/usage" {
            await withCheckedContinuation { continuation in
                gate = continuation
                started = true
                waiter?.resume(); waiter = nil
            }
            return (Data(#"{"buckets":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!)
        }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
    }
}
