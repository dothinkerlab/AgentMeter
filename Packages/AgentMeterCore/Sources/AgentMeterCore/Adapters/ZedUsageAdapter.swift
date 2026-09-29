#if os(macOS)
import Foundation
import LocalAuthentication
import Security

public struct ZedUsageAdapter: Sendable {
    public static let source = "zed_keychain_cloud_api"
    public enum FetchError: Error, Equatable {
        case notFound, invalidServer, credentialDenied, credentialReadFailed
        case unauthorized, transport, httpStatus(Int), decode
    }
    public struct Credentials: Sendable, Equatable {
        public let userID: String
        public let accessToken: String
        public let serverURL: URL
    }

    public init() {}

    public func resolveCredentials(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Credentials {
        let settingsURL = home.appendingPathComponent(".config/zed/settings.json")
        var serverRaw: String?
        var credentialsRaw: String?
        if let data = try? Data(contentsOf: settingsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            serverRaw = root["server_url"] as? String
            credentialsRaw = root["credentials_url"] as? String
        }
        let (server, credentialServer) = try Self.resolvedServers(
            serverRaw: serverRaw,
            credentialsRaw: credentialsRaw
        )
        if let found = try Self.internetCredential(server: credentialServer) {
            return Credentials(userID: found.userID, accessToken: found.accessToken, serverURL: server)
        }
        if let found = try Self.genericCredential(server: credentialServer) {
            return Credentials(userID: found.userID, accessToken: found.accessToken, serverURL: server)
        }
        throw FetchError.notFound
    }

    public func fetch(credentials: Credentials, session: URLSession = .shared, now: Date = Date()) async throws -> QuotaSnapshot {
        let apiBase = credentials.serverURL
        guard apiBase.scheme == "https", let url = URL(string: "/client/users/me", relativeTo: apiBase)?.absoluteURL,
              Self.sameOrigin(url, apiBase) else { throw FetchError.invalidServer }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("\(credentials.userID) \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.transport }
        guard let http = response as? HTTPURLResponse else { throw FetchError.transport }
        if http.statusCode == 401 || http.statusCode == 403 { throw FetchError.unauthorized }
        guard http.statusCode == 200 else { throw FetchError.httpStatus(http.statusCode) }
        return try parse(data: data, now: now)
    }

    public func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.decode }
        let plan = Self.firstString(root, keys: ["plan_v3", "plan_name", "name", "tier"])
        let usage = Self.firstDictionary(root, key: "edit_predictions")
        let unlimited = (usage?["unlimited"] as? Bool) == true
        var windows: [QuotaWindow] = []
        if !unlimited, let usage {
            let used = Self.number(usage, keys: ["used", "usage", "consumed"])
            let limit = Self.number(usage, keys: ["limit", "maximum", "total"])
            let remaining = Self.number(usage, keys: ["remaining", "available"])
            let percent: Double?
            if let used, let limit, limit > 0 { percent = used / limit * 100 }
            else if let remaining, let limit, limit > 0 { percent = 100 - remaining / limit * 100 }
            else { percent = Self.number(usage, keys: ["used_percent", "usage_percent"]) }
            if let percent, percent.isFinite {
                let reset = Self.firstDate(root, keys: ["ended_at", "ends_at", "reset_at"])
                windows.append(.init(usedPercent: percent, resetsAt: reset, kind: .editPredictions))
            }
        }
        guard !windows.isEmpty || unlimited || plan != nil else { throw FetchError.decode }
        return QuotaSnapshot(tool: .zed, plan: plan, windows: windows, confidence: .fresh,
                             source: Self.source, updatedAt: now)
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized: .authExpired
        case FetchError.transport: .networkFailure
        case FetchError.httpStatus: .endpointFailure
        case FetchError.decode: .responseChanged
        case FetchError.notFound, FetchError.invalidServer, FetchError.credentialDenied, FetchError.credentialReadFailed: .credentialReadFailed
        default: .unknownFailure
        }
    }

    private static func validatedServer(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.host != nil else { return nil }
        return url
    }
    static func resolvedServers(serverRaw: String?, credentialsRaw: String?) throws -> (URL, URL) {
        let requestRaw = serverRaw ?? credentialsRaw ?? "https://zed.dev"
        let credentialRaw = credentialsRaw ?? requestRaw
        guard let server = validatedServer(requestRaw),
              let credentialServer = validatedServer(credentialRaw),
              sameOrigin(server, credentialServer) else { throw FetchError.invalidServer }
        return (server, credentialServer)
    }
    private static func internetCredential(server: URL) throws -> Credentials? {
        guard let host = server.host else { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let port = server.port { query[kSecAttrPort as String] = port }
        return try credential(query: query, server: server)
    }
    private static func genericCredential(server: URL) throws -> Credentials? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: server.absoluteString,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        return try credential(query: query, server: server)
    }
    private static func credential(query: [String: Any], server: URL) throws -> Credentials? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw FetchError.credentialDenied }
        guard status == errSecSuccess, let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String,
              let data = dict[kSecValueData as String] as? Data,
              let token = String(data: data, encoding: .utf8), !account.isEmpty, !token.isEmpty else {
            throw FetchError.credentialReadFailed
        }
        return Credentials(userID: account, accessToken: token, serverURL: server)
    }
    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }
    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }
    private static func firstDictionary(_ root: [String: Any], key: String) -> [String: Any]? {
        if let value = root[key] as? [String: Any] { return value }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstDictionary(dict, key: key) { return found }
        }
        return nil
    }
    private static func firstString(_ root: [String: Any], keys: Set<String>) -> String? {
        for (key, value) in root where keys.contains(key) {
            if let text = value as? String, !text.isEmpty { return text.replacingOccurrences(of: "_", with: " ").capitalized }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstString(dict, keys: keys) { return found }
        }
        return nil
    }
    private static func number(_ root: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = root[key] as? NSNumber { return value.doubleValue }
            if let text = root[key] as? String, let value = Double(text) { return value }
        }
        return nil
    }
    private static func firstDate(_ root: [String: Any], keys: Set<String>) -> Date? {
        for (key, value) in root where keys.contains(key) {
            if let seconds = value as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
            if let text = value as? String, let date = ISO8601DateFormatter().date(from: text) { return date }
        }
        for value in root.values {
            if let dict = value as? [String: Any], let found = firstDate(dict, keys: keys) { return found }
        }
        return nil
    }
}
#endif
