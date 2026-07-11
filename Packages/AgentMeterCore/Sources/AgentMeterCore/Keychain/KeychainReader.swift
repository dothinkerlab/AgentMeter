import Foundation

#if os(macOS)
import Security

/// 读取 AI 编程工具在 macOS Keychain 存的 OAuth 凭据。
///
/// Claude Code 服务名 `Claude Code-credentials`;Codex 服务名 `Codex-credentials`。
/// 值是 JSON。实测可能外层包一层工具专属 key,但为容错也支持顶层直接是凭据
/// (铁律 2)。**只读不写,token 绝不离开 Mac**(铁律 1)。
/// 仅 macOS 可用 —— 手表/手机永远不碰 token。
public enum KeychainReader {

    public static let claudeService = "Claude Code-credentials"
    public static let codexService = "Codex-credentials"
    public static let service = claudeService

    public struct Credentials: Decodable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
        public let scopes: [String]?
        public let subscriptionType: String?
        public let accountID: String?

        public init(
            accessToken: String,
            refreshToken: String? = nil,
            expiresAt: Date? = nil,
            scopes: [String]? = nil,
            subscriptionType: String? = nil,
            accountID: String? = nil
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.scopes = scopes
            self.subscriptionType = subscriptionType
            self.accountID = accountID
        }

        enum CodingKeys: String, CodingKey {
            case accessToken, refreshToken, expiresAt, scopes, subscriptionType
            case accountID
            case accountId
            case accountIdSnake = "account_id"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try c.decode(String.self, forKey: .accessToken)
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            scopes = try c.decodeIfPresent([String].self, forKey: .scopes)
            subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
            accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
                ?? c.decodeIfPresent(String.self, forKey: .accountId)
                ?? c.decodeIfPresent(String.self, forKey: .accountIdSnake)
            // expiresAt 实测是 epoch 毫秒。
            if let ms = try c.decodeIfPresent(Double.self, forKey: .expiresAt) {
                expiresAt = Date(timeIntervalSince1970: ms / 1000)
            } else {
                expiresAt = nil
            }
        }

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt < Date()
        }
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notFound(String)
        case osStatus(OSStatus)
        case notData
        case decode(String)

        public var description: String {
            switch self {
            case .notFound(let service):
                return "Keychain 里找不到 \"\(service)\" —— 对应工具没登录?"
            case .osStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "未知错误"
                return "Keychain 读取失败 (OSStatus \(s)): \(msg)"
            case .notData:
                return "Keychain 条目不含数据"
            case .decode(let d):
                return "凭据 JSON 解析失败: \(d)"
            }
        }
    }

    public static func serviceName(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode:
            return claudeService
        case .codex:
            return codexService
        case .openCode:
            return "OpenCode-credentials"
        case .deepSeek:
            return DeepSeekKeyStore.service
        }
    }

    public static func readCredentials(tool: ToolKind = .claudeCode) throws -> Credentials {
        switch tool {
        case .deepSeek:
            throw ReadError.notFound(serviceName(for: tool))
        default:
            break
        }
        do {
            return try readCredentials(service: serviceName(for: tool), tool: tool)
        } catch ReadError.notFound where tool == .codex {
            return try readCodexAuthFile()
        }
    }

    public static func readCredentials(service: String, tool: ToolKind = .claudeCode) throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw ReadError.notFound(service)
        default: throw ReadError.osStatus(status)
        }
        guard let data = item as? Data else { throw ReadError.notData }
        return try decodeCredentials(data, tool: tool)
    }

    private struct Wrapper: Decodable {
        let claudeAiOauth: Credentials?
        let codexOauth: Credentials?
        let codex: Credentials?

        func credentials(for tool: ToolKind) -> Credentials? {
            switch tool {
            case .claudeCode:
                return claudeAiOauth
            case .codex:
                return codexOauth ?? codex
            case .openCode:
                return nil
            case .deepSeek:
                return nil
            }
        }
    }

    /// 从凭据 JSON 解出 Credentials。抽出来便于单测。
    /// 先试外层包工具专属 key(忽略 `trustedDeviceToken` 等同级键),再试顶层直接是凭据。
    public static func decodeCredentials(_ data: Data, tool: ToolKind = .claudeCode) throws -> Credentials {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Wrapper.self, from: data),
           let credentials = wrapped.credentials(for: tool) {
            return credentials
        }
        do {
            return try decoder.decode(Credentials.self, from: data)
        } catch {
            throw ReadError.decode(String(describing: error))
        }
    }

    private struct CodexAuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let refreshToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case accountID = "account_id"
            }
        }

        let tokens: Tokens
    }

    /// Codex CLI 当前把登录态存在 `~/.codex/auth.json`,不是 Keychain。只取 access token,
    /// 不把 token 写入 CloudKit 或任何共享端。
    public static func readCodexAuthFile(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) throws -> Credentials {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.notFound(url.path)
        }
        return try decodeCodexAuthFile(data)
    }

    public static func decodeCodexAuthFile(_ data: Data) throws -> Credentials {
        do {
            let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
            return Credentials(accessToken: auth.tokens.accessToken,
                               refreshToken: auth.tokens.refreshToken,
                               accountID: auth.tokens.accountID)
        } catch {
            throw ReadError.decode(String(describing: error))
        }
    }
}
#endif
