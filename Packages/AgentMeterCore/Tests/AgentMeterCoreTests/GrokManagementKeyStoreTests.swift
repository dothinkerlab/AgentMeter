import Foundation
import Security
import Testing
@testable import AgentMeterCore

struct GrokManagementKeyStoreTests {
    private func service() -> String {
        "xAI-Management-credentials-test-\(UUID().uuidString.prefix(8))"
    }

    @Test func savesUpdatesReadsAndDeletesCredentials() throws {
        let service = service()
        defer { wipeGrokCredentials(service: service) }
        #expect(try GrokManagementKeyStore.read(service: service) == nil)

        let old = GrokManagementCredentials(managementKey: "xai-old", teamID: "team-old")
        try GrokManagementKeyStore.save(credentials: old, service: service)
        #expect(try GrokManagementKeyStore.read(service: service) == old)

        let new = GrokManagementCredentials(managementKey: "xai-new", teamID: "team-new")
        try GrokManagementKeyStore.save(credentials: new, service: service)
        #expect(try GrokManagementKeyStore.read(service: service) == new)

        try GrokManagementKeyStore.delete(service: service)
        try GrokManagementKeyStore.delete(service: service)
        #expect(try GrokManagementKeyStore.read(service: service) == nil)
    }

    @Test func keychainItemDisablesSynchronizationAndDoesNotMigrate() throws {
        let service = service()
        defer { wipeGrokCredentials(service: service) }
        try GrokManagementKeyStore.save(
            credentials: GrokManagementCredentials(managementKey: "xai-local", teamID: "team"),
            service: service
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: GrokManagementKeyStore.account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        if let value = attributes[kSecAttrSynchronizable as String] as? Bool {
            #expect(value == false)
        }

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: GrokManagementKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }

    @Test func saveUpgradesMigratableItemToThisDeviceOnly() throws {
        let service = service()
        defer { wipeGrokCredentials(service: service) }
        let legacyCredentials = GrokManagementCredentials(managementKey: "xai-legacy", teamID: "team")
        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: GrokManagementKeyStore.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: try JSONEncoder().encode(legacyCredentials),
        ]
        #expect(SecItemAdd(legacyItem as CFDictionary, nil) == errSecSuccess)

        try GrokManagementKeyStore.save(
            credentials: GrokManagementCredentials(managementKey: "xai-upgraded", teamID: "team"),
            service: service
        )

        let localOnlyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: GrokManagementKeyStore.account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(localOnlyQuery as CFDictionary, nil) == errSecSuccess)
    }
}

private func wipeGrokCredentials(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: GrokManagementKeyStore.account,
    ]
    SecItemDelete(query as CFDictionary)
}
