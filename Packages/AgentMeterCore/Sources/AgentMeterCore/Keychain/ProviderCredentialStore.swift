import Foundation
import Security

/// Manual credentials for device-local provider integrations. Every item is
/// explicitly non-synchronizable and ThisDeviceOnly; Mac and iPhone therefore
/// cannot accidentally reuse one another's keys through iCloud Keychain.
public enum ProviderCredentialStore {
    public enum Kind: String, Sendable, CaseIterable {
        case kimiCode = "KimiCode-credentials"
        case glmCoding = "GLMCoding-credentials"
        case miniMax = "MiniMaxTokenPlan-credentials"
        case kimiAPI = "KimiAPI-credentials"
        case openAIAdmin = "OpenAIAdmin-credentials"
        case anthropicAdmin = "AnthropicAdmin-credentials"
        case cursorAdmin = "CursorAdmin-credentials"
    }

    public enum KeyError: Error, Equatable {
        case osStatus(OSStatus)
        case invalidData
    }

    private static let account = "default"

    public static func save(_ value: String, kind: Kind, service: String? = nil) throws {
        guard let data = value.data(using: .utf8) else { throw KeyError.invalidData }
        let service = service ?? kind.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeyError.osStatus(update) }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
    }

    public static func read(kind: Kind, service: String? = nil) throws -> String? {
        let service = service ?? kind.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            if status != errSecSuccess { throw KeyError.osStatus(status) }
            throw KeyError.invalidData
        }
        try harden(service: service)
        return value
    }

    public static func delete(kind: Kind, service: String? = nil) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? kind.rawValue,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.osStatus(status)
        }
    }

    private static func harden(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        var protected = query
        protected[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        protected[kSecMatchLimit as String] = kSecMatchLimitOne
        let lookup = SecItemCopyMatching(protected as CFDictionary, nil)
        if lookup == errSecSuccess { return }
        guard lookup == errSecItemNotFound else { throw KeyError.osStatus(lookup) }
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        )
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
    }
}
