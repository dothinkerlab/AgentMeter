import XCTest
import Security
import SweetCookieKit
@testable import AgentMeter

final class MacBrowserCookieAccessTests: XCTestCase {
    private enum ExpectedError: Error { case test }
    private func interactionAllowed() throws -> Bool {
        var allowed = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        return allowed.boolValue
    }
    func testBackgroundDisablesBothGatesAndRestoresAfterSuccessAndFailure() throws {
        let previous = try interactionAllowed()
        try MacBrowserCookieAccess.read(allowInteraction: false) {
            XCTAssertFalse(try interactionAllowed())
            XCTAssertTrue(BrowserCookieKeychainAccessGate.isUserInteractionDisallowed)
            try MacBrowserCookieAccess.read(allowInteraction: false) { XCTAssertFalse(try interactionAllowed()) }
            XCTAssertFalse(try interactionAllowed())
        }
        XCTAssertEqual(try interactionAllowed(), previous)
        XCTAssertThrowsError(try MacBrowserCookieAccess.read(allowInteraction: false) { throw ExpectedError.test })
        XCTAssertEqual(try interactionAllowed(), previous)
        XCTAssertFalse(BrowserCookieKeychainAccessGate.isUserInteractionDisallowed)
    }
    func testExplicitConnectionPreservesExistingGate() throws {
        let previous = try interactionAllowed()
        try MacBrowserCookieAccess.read(allowInteraction: true) { XCTAssertEqual(try interactionAllowed(), previous) }
        XCTAssertEqual(try interactionAllowed(), previous)
    }
}
