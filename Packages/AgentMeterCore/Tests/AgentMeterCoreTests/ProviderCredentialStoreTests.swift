import Foundation
import Security
import Testing
@testable import AgentMeterCore

@Suite(.serialized)
struct ProviderCredentialStoreTests {
    @Test func eachCredentialKindUsesIndependentThisDeviceOnlyItem() throws {
        for kind in ProviderCredentialStore.Kind.allCases {
            let service = "AgentMeterTests.\(kind.rawValue).\(UUID().uuidString)"
            defer { try? ProviderCredentialStore.delete(kind: kind, service: service) }
            try ProviderCredentialStore.save("secret-\(kind.rawValue)", kind: kind, service: service)
            #expect(try ProviderCredentialStore.read(kind: kind, service: service) == "secret-\(kind.rawValue)")
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "default",
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
            let attributes = item as? [String: Any]
            #expect((attributes?[kSecAttrSynchronizable as String] as? Bool) != true)
            let deviceOnlyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "default",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            #expect(SecItemCopyMatching(deviceOnlyQuery as CFDictionary, nil) == errSecSuccess)
        }
    }
}
