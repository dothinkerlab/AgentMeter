import Foundation
import Security

/// OpenRouter 普通 API key 的本机存储。Mac/iPhone 各自保存，不通过 iCloud Keychain 同步。
public enum OpenRouterKeyStore {
    public static let service = "OpenRouter-credentials"
    public static let account = "default"

    public enum KeyError: Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case notData
        case decode

        public var description: String {
            switch self {
            case .osStatus(let status):
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误"
                return "OpenRouter key Keychain 操作失败 (OSStatus \(status)): \(message)"
            case .notData: return "OpenRouter key 条目不含数据"
            case .decode: return "OpenRouter key UTF-8 解码失败"
            }
        }
    }

    public static func save(apiKey: String, service: String = Self.service) throws {
        guard let data = apiKey.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound:
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeyError.osStatus(addStatus) }
        default: throw KeyError.osStatus(status)
        }
    }

    public static func read(service: String = Self.service) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return nil
        default: throw KeyError.osStatus(status)
        }
        guard let data = item as? Data else { throw KeyError.notData }
        guard let key = String(data: data, encoding: .utf8) else { throw KeyError.decode }
        return key
    }

    public static func delete(service: String = Self.service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        default: throw KeyError.osStatus(status)
        }
    }
}
