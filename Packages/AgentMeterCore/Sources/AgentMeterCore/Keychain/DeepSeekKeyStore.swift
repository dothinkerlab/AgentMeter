import Foundation
import Security

/// DeepSeek API key 的存取器。
///
/// DeepSeek 不像 Claude Code/Codex 有 CLI 把 OAuth 凭据写进 Keychain —— 用户需手动
/// 粘贴 API key。本类负责把 key 跨平台(macOS / iOS)存进 Keychain。
///
/// **铁律 1 的 DeepSeek 例外**(详见 AGENTS.md / TECHNICAL_DESIGN.md):
/// Claude Code/Codex 走 Mac→CloudKit→iOS/Watch 的同步路径,token 只在 Mac;
/// DeepSeek 是旁路 —— Mac 和 iOS 各自持 key、各自 fetch、不入 CloudKit,Watch 不显示。
///
/// **`synchronizable = false` 必须**:DeepSeek key 不允许走 iCloud Keychain 同步出去,
/// 各端独立存储。
///
/// service 名沿用既有 KeychainReader 命名风格:工具名加 `-credentials` 后缀。
public enum DeepSeekKeyStore {

    public static let service = "DeepSeek-credentials"
    public static let account = "default"

    public enum KeyError: Error, CustomStringConvertible {
        case osStatus(OSStatus)
        case notData
        case decode

        public var description: String {
            switch self {
            case .osStatus(let s):
                let msg = (SecCopyErrorMessageString(s, nil) as String?) ?? "未知错误"
                return "DeepSeek key Keychain 操作失败 (OSStatus \(s)): \(msg)"
            case .notData:
                return "DeepSeek key 条目不含数据"
            case .decode:
                return "DeepSeek key UTF-8 解码失败"
            }
        }
    }

    /// 把 API key 写进 Keychain(覆盖已存在条目)。
    /// - Parameter service: 默认 `Self.service`;测试注入独立 service 避免污染真实条目。
    public static func save(apiKey: String, service: String = Self.service) throws {
        guard let data = apiKey.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]

        // 已有条目原地更新,避免 delete 成功但 add 失败时丢掉仍可用的旧 key。
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addAttributes = query
            addAttributes[kSecValueData as String] = data
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeyError.osStatus(addStatus) }
        default:
            throw KeyError.osStatus(updateStatus)
        }
    }

    /// 读出已存的 API key;不存在返回 `nil`(不像 macOS KeychainReader 抛 notFound,
    /// 这里 absence 是常态 —— DeepSeek 可能未配置)。
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

    /// 删除已存的 API key。不存在也视为成功(幂等)。
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
