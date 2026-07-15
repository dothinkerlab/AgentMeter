import Foundation
import Security

public struct GrokManagementCredentials: Codable, Sendable, Equatable {
    public let managementKey: String
    public let teamID: String

    public init(managementKey: String, teamID: String) {
        self.managementKey = managementKey
        self.teamID = teamID
    }
}

/// xAI Management API 凭据的本机存储。Management Key 与 Team ID 一起保存，
/// 且明确禁止经 iCloud Keychain 同步。
public enum GrokManagementKeyStore {
    public static let service = "xAI-Management-credentials"
    public static let account = "default"

    public enum KeyError: Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case notData
        case encode(String)
        case decode(String)

        public var description: String {
            switch self {
            case .osStatus(let status):
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误"
                return "xAI Management 凭据 Keychain 操作失败 (OSStatus \(status)): \(message)"
            case .notData: return "xAI Management 凭据条目不含数据"
            case .encode(let detail): return "xAI Management 凭据编码失败: \(detail)"
            case .decode(let detail): return "xAI Management 凭据解析失败: \(detail)"
            }
        }
    }

    public static func save(
        credentials: GrokManagementCredentials,
        service: String = Self.service
    ) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw KeyError.encode(String(describing: error))
        }
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

    public static func read(service: String = Self.service) throws -> GrokManagementCredentials? {
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
        do {
            return try JSONDecoder().decode(GrokManagementCredentials.self, from: data)
        } catch {
            throw KeyError.decode(String(describing: error))
        }
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
