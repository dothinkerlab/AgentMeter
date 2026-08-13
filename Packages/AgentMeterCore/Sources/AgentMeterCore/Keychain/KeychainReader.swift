import Foundation

#if os(macOS)
import Security
import SQLite3

/// 读取 AI 编程工具在 macOS Keychain 存的 OAuth 凭据。
///
/// Claude Code 服务名 `Claude Code-credentials`; Codex 服务名 `Codex-credentials`。
/// 值是 JSON。实测可能外层包一层工具专属 key,但为容错也支持顶层直接是凭据
/// (铁律 2)。**只读不写,token 绝不离开 Mac**(铁律 1)。
/// Cursor 则只读其本机 SQLite 状态库中的 access token。仅 macOS 可用 ——
/// 手表/手机永远不碰 token。
public enum KeychainReader {

    public static let claudeService = "Claude Code-credentials"
    public static let codexService = "Codex-credentials"
    public static let service = claudeService

    public struct Credentials: Decodable, Sendable, Equatable {
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
        case localDatabase(Int32)

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
            case .localDatabase(let code):
                return "本机登录数据库只读访问失败 (SQLite \(code))"
            }
        }
    }

    public static func serviceName(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode:
            return claudeService
        case .codex:
            return codexService
        case .cursor:
            return "Cursor-local-state"
        case .kimiCode:
            return ProviderCredentialStore.Kind.kimiCode.rawValue
        case .glmCoding:
            return ProviderCredentialStore.Kind.glmCoding.rawValue
        case .miniMax:
            return ProviderCredentialStore.Kind.miniMax.rawValue
        case .openCode:
            return "OpenCode-credentials"
        case .deepSeek:
            return DeepSeekKeyStore.service
        case .openRouter:
            return OpenRouterKeyStore.service
        case .grok:
            return GrokManagementKeyStore.service
        }
    }

    public static func readCredentials(tool: ToolKind = .claudeCode) throws -> Credentials {
        if tool == .cursor { return try readCursorState().credentials }
        switch tool {
        case .kimiCode, .glmCoding, .miniMax, .deepSeek, .openRouter, .grok:
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
            case .cursor:
                return nil
            case .kimiCode, .glmCoding, .miniMax:
                return nil
            case .openCode:
                return nil
            case .deepSeek:
                return nil
            case .openRouter:
                return nil
            case .grok:
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

    public struct CursorLocalState: Sendable, Equatable {
        public let credentials: Credentials
        public let plan: String?

        public init(credentials: Credentials, plan: String?) {
            self.credentials = credentials
            self.plan = plan
        }
    }

    /// Reads only Cursor's access token and cached plan from its VS Code state
    /// database. The database is opened SQLITE_OPEN_READONLY; refresh tokens are
    /// deliberately neither selected nor used.
    public static func readCursorState(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    ) throws -> CursorLocalState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.notFound(url.path)
        }
        var database: OpaquePointer?
        let open = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard open == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            throw ReadError.localDatabase(open)
        }
        defer { sqlite3_close(database) }

        let accessToken = try cursorValue(
            key: "cursorAuth/accessToken",
            database: database
        )
        guard let accessToken, !accessToken.isEmpty else {
            throw ReadError.notFound("cursorAuth/accessToken")
        }
        let plan = try cursorValue(
            key: "cursorAuth/stripeMembershipType",
            database: database
        )
        return CursorLocalState(
            credentials: Credentials(accessToken: accessToken, subscriptionType: plan),
            plan: plan
        )
    }

    private static func cursorValue(
        key: String,
        database: OpaquePointer
    ) throws -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw ReadError.localDatabase(prepared)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK else {
            throw ReadError.localDatabase(sqlite3_errcode(database))
        }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw ReadError.localDatabase(step)
        }
        let value = String(cString: raw)
        if let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return value
    }
}
#endif
