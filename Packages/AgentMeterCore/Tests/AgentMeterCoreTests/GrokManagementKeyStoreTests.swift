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
        #expect(grokDeviceOnlyStatus(service: service) == errSecSuccess)
    }

    @Test func saveUpgradesMigratableItemToThisDeviceOnly() throws {
        let service = service()
        defer { wipeGrokCredentials(service: service) }
        let legacy = GrokManagementCredentials(managementKey: "xai-legacy", teamID: "team")
        #expect(addLegacyGrokCredentials(legacy, service: service) == errSecSuccess)

        let upgraded = GrokManagementCredentials(managementKey: "xai-upgraded", teamID: "team")
        try GrokManagementKeyStore.save(credentials: upgraded, service: service)

        #expect(try GrokManagementKeyStore.read(service: service) == upgraded)
        #expect(grokDeviceOnlyStatus(service: service) == errSecSuccess)
    }

    @Test func readUpgradesMigratableItemWithoutReentry() throws {
        let service = service()
        defer { wipeGrokCredentials(service: service) }
        let legacy = GrokManagementCredentials(managementKey: "xai-existing", teamID: "team")
        #expect(addLegacyGrokCredentials(legacy, service: service) == errSecSuccess)

        #expect(try GrokManagementKeyStore.read(service: service) == legacy)
        #expect(grokDeviceOnlyStatus(service: service) == errSecSuccess)
    }
}

private func addLegacyGrokCredentials(
    _ credentials: GrokManagementCredentials,
    service: String
) -> OSStatus {
    guard let data = try? JSONEncoder().encode(credentials) else { return errSecParam }
    return SecItemAdd([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: GrokManagementKeyStore.account,
        kSecAttrSynchronizable as String: kCFBooleanFalse!,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        kSecValueData as String: data,
    ] as CFDictionary, nil)
}

private func grokDeviceOnlyStatus(service: String) -> OSStatus {
    SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: GrokManagementKeyStore.account,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ] as CFDictionary, nil)
}

private func wipeGrokCredentials(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: GrokManagementKeyStore.account,
    ]
    SecItemDelete(query as CFDictionary)
}
