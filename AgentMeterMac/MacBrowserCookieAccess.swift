import Foundation
import Security
import SweetCookieKit

/// Chrome Safe Storage can live in the legacy file Keychain, where SecItem's
/// no-UI query flags are insufficient. Scope the legacy gate as Chromium does:
/// https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc
/// Serialize both browser importers because this gate is process-wide.
enum MacBrowserCookieAccess {
    private static let lock = NSRecursiveLock()
    private enum AccessError: Error { case unavailable }

    static func read<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if allowInteraction { return try operation() }
        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw AccessError.unavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(operation)
    }
}
