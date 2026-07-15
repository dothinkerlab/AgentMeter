import Foundation
import Security
import Testing
@testable import AgentMeterCore

struct OpenRouterKeyStoreTests {
    private func scopedService() -> String {
        "OpenRouter-credentials-test-\(UUID().uuidString.prefix(8))"
    }

    @Test func saveReadOverwriteAndDelete() throws {
        let service = scopedService()
        defer { wipeOpenRouterKey(service: service) }

        #expect(try OpenRouterKeyStore.read(service: service) == nil)
        try OpenRouterKeyStore.save(apiKey: "sk-or-v1-old", service: service)
        #expect(try OpenRouterKeyStore.read(service: service) == "sk-or-v1-old")
        try OpenRouterKeyStore.save(apiKey: "sk-or-v1-new", service: service)
        #expect(try OpenRouterKeyStore.read(service: service) == "sk-or-v1-new")
        try OpenRouterKeyStore.delete(service: service)
        try OpenRouterKeyStore.delete(service: service)
        #expect(try OpenRouterKeyStore.read(service: service) == nil)
    }

    @Test func savedItemIsNotSynchronizableAndDoesNotMigrate() throws {
        let service = scopedService()
        defer { wipeOpenRouterKey(service: service) }
        try OpenRouterKeyStore.save(apiKey: "sk-or-v1-local", service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: OpenRouterKeyStore.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        if let value = (item as? [String: Any])?[kSecAttrSynchronizable as String] as? Bool {
            #expect(value == false)
        }

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: OpenRouterKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }

    @Test func saveUpgradesMigratableItemToThisDeviceOnly() throws {
        let service = scopedService()
        defer { wipeOpenRouterKey(service: service) }
        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: OpenRouterKeyStore.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data("sk-or-v1-legacy".utf8),
        ]
        #expect(SecItemAdd(legacyItem as CFDictionary, nil) == errSecSuccess)

        try OpenRouterKeyStore.save(apiKey: "sk-or-v1-upgraded", service: service)

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: OpenRouterKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }
}

private func wipeOpenRouterKey(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ] as CFDictionary)
}
