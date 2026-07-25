#if os(macOS)
import Foundation

/// Read-only discovery of official CLI configuration. AgentMeter never refreshes
/// or writes these files; a manual device-local key is the fallback.
public enum MacCodingCredentialResolver {
    public enum ResolveError: Error { case credentialReadFailed }

    public static func resolve(tool: ToolKind, manualRegion: ProviderRegion,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> CodingProviderCredential? {
        if let automatic = try? automatic(tool: tool, home: home) { return automatic }
        do {
            let kind: ProviderCredentialStore.Kind
            switch tool {
            case .kimiCode: kind = .kimiCode
            case .glmCoding: kind = .glmCoding
            case .miniMax: kind = .miniMax
            default: return nil
            }
            guard let key = try ProviderCredentialStore.read(kind: kind), !key.isEmpty else { return nil }
            return CodingProviderCredential(secret: key, region: manualRegion, source: .manualKeychain)
        } catch {
            throw ResolveError.credentialReadFailed
        }
    }

    private static func automatic(tool: ToolKind, home: URL) throws -> CodingProviderCredential? {
        switch tool {
        case .kimiCode:
            let url = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
            guard let root = try json(at: url) else { return nil }
            guard let token = recursiveString(root, keys: ["accessToken", "access_token", "token"]), !token.isEmpty else { return nil }
            return CodingProviderCredential(secret: token, source: .kimiCLI)
        case .glmCoding:
            let url = home.appendingPathComponent(".claude/settings.json")
            guard let root = try json(at: url) else { return nil }
            let env = root["env"] as? [String: Any] ?? root
            guard let base = env["ANTHROPIC_BASE_URL"] as? String,
                  let token = env["ANTHROPIC_AUTH_TOKEN"] as? String, !token.isEmpty else { return nil }
            let region: ProviderRegion
            if base.contains("api.z.ai") { region = .global }
            else if base.contains("open.bigmodel.cn") || base.contains("dev.bigmodel.cn") { region = .china }
            else { return nil }
            return CodingProviderCredential(secret: token, region: region, source: .claudeSettings)
        case .miniMax:
            let url = home.appendingPathComponent(".mmx/config.json")
            guard let root = try json(at: url),
                  let key = recursiveString(root, keys: ["api_key", "apiKey", "token", "access_token"]),
                  !key.isEmpty else { return nil }
            let regionRaw = recursiveString(root, keys: ["region"])?.lowercased()
            let region: ProviderRegion = regionRaw == "cn" || regionRaw == "china" ? .china : .global
            return CodingProviderCredential(secret: key, region: region, source: .miniMaxCLI)
        default:
            return nil
        }
    }

    private static func json(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func recursiveString(_ object: [String: Any], keys: Set<String>) -> String? {
        for (key, value) in object {
            if keys.contains(key), let string = value as? String { return string }
            if let nested = value as? [String: Any], let found = recursiveString(nested, keys: keys) { return found }
        }
        return nil
    }
}
#endif
