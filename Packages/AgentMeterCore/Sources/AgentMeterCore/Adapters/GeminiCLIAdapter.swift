import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// In-memory cache for refreshed Gemini CLI OAuth access tokens.
/// Never writes tokens to disk or external tool files.
public actor GeminiTokenMemoryCache {
    public static let shared = GeminiTokenMemoryCache()

    public struct Entry: Sendable, Equatable {
        public let accessToken: String
        public let idToken: String?
        public let expiresAt: Date?

        public init(accessToken: String, idToken: String?, expiresAt: Date?) {
            self.accessToken = accessToken
            self.idToken = idToken
            self.expiresAt = expiresAt
        }
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func cachedToken(for refreshToken: String, now: Date = Date()) -> Entry? {
        guard let entry = entries[refreshToken] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt.timeIntervalSince(now) <= 60 {
            entries.removeValue(forKey: refreshToken)
            return nil
        }
        return entry
    }

    public func store(
        refreshToken: String,
        accessToken: String,
        idToken: String?,
        expiresAt: Date?
    ) {
        entries[refreshToken] = Entry(
            accessToken: accessToken,
            idToken: idToken,
            expiresAt: expiresAt
        )
    }

    public func clear() {
        entries.removeAll()
    }
}

/// Google Gemini CLI subscription quota adapter.
///
/// Reads local Gemini CLI OAuth credentials read-only and queries Google's Cloud Code
/// internal quota endpoint (`v1internal:retrieveUserQuota`). Refreshed access tokens
/// are kept strictly in memory and never written back to `~/.gemini/oauth_creds.json`.
public struct GeminiCLIAdapter: Sendable {
    public static let source = "gemini_cli_cloudcode_quota"
    public static let defaultQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    public static let defaultLoadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let defaultProjectsURL = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!
    public static let defaultTokenRefreshURL = URL(string: "https://oauth2.googleapis.com/token")!

    public let quotaURL: URL
    public let loadCodeAssistURL: URL
    public let projectsURL: URL
    public let tokenRefreshURL: URL

    public struct OAuthClientCredentials: Sendable, Equatable {
        public let clientID: String
        public let clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    public struct CodeAssistStatus: Sendable, Equatable {
        public let tierID: String?
        public let projectID: String?
        public let paidTierName: String?
        public let isConsumerClientUnsupported: Bool

        public static let empty = CodeAssistStatus(
            tierID: nil,
            projectID: nil,
            paidTierName: nil,
            isConsumerClientUnsupported: false
        )

        public init(
            tierID: String?,
            projectID: String?,
            paidTierName: String?,
            isConsumerClientUnsupported: Bool
        ) {
            self.tierID = tierID
            self.projectID = projectID
            self.paidTierName = paidTierName
            self.isConsumerClientUnsupported = isConsumerClientUnsupported
        }
    }

    public enum FetchError: Error, Sendable, Equatable {
        case unauthorized
        case consumerTierDeprecated
        case httpStatus(Int)
        case transport(String)
        case decode(String)
    }

    public init(
        quotaURL: URL = GeminiCLIAdapter.defaultQuotaURL,
        loadCodeAssistURL: URL = GeminiCLIAdapter.defaultLoadCodeAssistURL,
        projectsURL: URL = GeminiCLIAdapter.defaultProjectsURL,
        tokenRefreshURL: URL = GeminiCLIAdapter.defaultTokenRefreshURL
    ) {
        self.quotaURL = quotaURL
        self.loadCodeAssistURL = loadCodeAssistURL
        self.projectsURL = projectsURL
        self.tokenRefreshURL = tokenRefreshURL
    }

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized, FetchError.consumerTierDeprecated:
            .authExpired
        case FetchError.transport:
            .networkFailure
        case FetchError.httpStatus:
            .endpointFailure
        case FetchError.decode:
            .responseChanged
        default:
            .unknownFailure
        }
    }

    // MARK: - Pure Parsing

    private struct QuotaBucketResponse: Decodable {
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
        let tokenType: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucketResponse]?
    }

    private enum ModelTier {
        case pro
        case flash
        case flashLite
        case other
    }

    private struct ParsedBucket {
        let modelID: String
        let remainingFraction: Double
        let resetTime: Date?
    }

    public func parseQuota(
        data: Data,
        plan: String? = nil,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        let response: QuotaResponse
        do {
            response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        } catch {
            throw FetchError.decode(String(describing: error))
        }

        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw FetchError.decode("missing quota buckets")
        }

        var perModel: [String: ParsedBucket] = [:]
        for bucket in buckets {
            guard let rawModel = bucket.modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawModel.isEmpty,
                  let fraction = bucket.remainingFraction,
                  fraction.isFinite else {
                continue
            }
            let clampedRemaining = max(0, min(1, fraction))
            let key = rawModel.lowercased()
            let resetDate = bucket.resetTime.flatMap(Self.parseISODate)

            if let existing = perModel[key] {
                if clampedRemaining < existing.remainingFraction {
                    perModel[key] = ParsedBucket(
                        modelID: key,
                        remainingFraction: clampedRemaining,
                        resetTime: resetDate
                    )
                }
            } else {
                perModel[key] = ParsedBucket(
                    modelID: key,
                    remainingFraction: clampedRemaining,
                    resetTime: resetDate
                )
            }
        }

        guard !perModel.isEmpty else {
            throw FetchError.decode("no valid quota buckets")
        }

        var proLowest: ParsedBucket?
        var flashLowest: ParsedBucket?
        var flashLiteLowest: ParsedBucket?
        var overallLowest: ParsedBucket?

        for bucket in perModel.values.sorted(by: { $0.modelID < $1.modelID }) {
            overallLowest = Self.tighter(overallLowest, bucket)
            switch Self.classifyTier(modelID: bucket.modelID) {
            case .pro:
                proLowest = Self.tighter(proLowest, bucket)
            case .flash:
                flashLowest = Self.tighter(flashLowest, bucket)
            case .flashLite:
                flashLiteLowest = Self.tighter(flashLiteLowest, bucket)
            case .other:
                break
            }
        }

        var windows: [QuotaWindow] = []
        if let proLowest {
            windows.append(Self.quotaWindow(from: proLowest, kind: .geminiPro))
        }
        if let flashLowest {
            windows.append(Self.quotaWindow(from: flashLowest, kind: .geminiFlash))
        }
        if let flashLiteLowest {
            windows.append(Self.quotaWindow(from: flashLiteLowest, kind: .geminiFlashLite))
        }
        if windows.isEmpty, let overallLowest {
            windows.append(Self.quotaWindow(from: overallLowest, kind: .daily))
        }

        guard !windows.isEmpty else {
            throw FetchError.decode("no mappable quota windows")
        }

        return QuotaSnapshot(
            tool: .geminiCLI,
            plan: plan,
            windows: windows,
            confidence: .fresh,
            source: Self.source,
            updatedAt: now
        )
    }

    public static func parseCodeAssistStatus(
        data: Data,
        hostedDomain: String? = nil
    ) throws -> CodeAssistStatus {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decode("invalid loadCodeAssist JSON")
        }

        let rawProjectID: String? = {
            if let project = json["cloudaicompanionProject"] as? String {
                return project
            }
            if let project = json["cloudaicompanionProject"] as? [String: Any] {
                if let id = project["id"] as? String { return id }
                if let projectID = project["projectId"] as? String { return projectID }
            }
            return nil
        }()
        let trimmedProject = rawProjectID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = trimmedProject?.isEmpty == true ? nil : trimmedProject

        let rawTierID = (json["currentTier"] as? [String: Any])?["id"] as? String
        let trimmedTierID = rawTierID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tierID = trimmedTierID?.isEmpty == true ? nil : trimmedTierID

        let rawPaidTierName = (json["paidTier"] as? [String: Any])?["name"] as? String
        let trimmedPaidName = rawPaidTierName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paidTierName = trimmedPaidName?.isEmpty == true ? nil : trimmedPaidName

        let normalizedHostedDomain = hostedDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHostedDomain = normalizedHostedDomain?.isEmpty == true ? nil : normalizedHostedDomain

        let unsupported = paidTierName == nil
            && effectiveHostedDomain == nil
            && hasUnsupportedClientIneligibleTier(in: json)

        if tierID == nil, unsupported {
            throw FetchError.consumerTierDeprecated
        }

        return CodeAssistStatus(
            tierID: tierID,
            projectID: projectID,
            paidTierName: paidTierName,
            isConsumerClientUnsupported: unsupported
        )
    }

    public static func resolvePlan(
        status: CodeAssistStatus,
        hostedDomain: String?
    ) -> String? {
        if let paidTierName = status.paidTierName, !paidTierName.isEmpty {
            return paidTierName
        }
        let hasHostedDomain = hostedDomain?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        switch status.tierID {
        case "standard-tier":
            return "Paid"
        case "free-tier":
            return hasHostedDomain ? "Workspace" : "Free"
        case "legacy-tier":
            return "Legacy"
        default:
            return nil
        }
    }

    public static func extractHostedDomain(fromIDToken idToken: String?) -> String? {
        guard let idToken, !idToken.isEmpty else { return nil }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let payloadData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let domain = (json["hd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !domain.isEmpty else {
            return nil
        }
        return domain
    }

    public static func isConsumerTierDeprecationSignal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("unsupported_client") || lower.contains("ineligibletiererror") {
            return true
        }
        if lower.contains("antigravity"),
           lower.contains("migration") || lower.contains("unsupported") || lower.contains("deprecated") {
            return true
        }
        return false
    }

    public static func parseOAuthClientCredentials(from content: String) -> OAuthClientCredentials? {
        let clientIDPattern = #"(?:const|let|var)?\s*OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]"#
        let secretPattern = #"(?:const|let|var)?\s*OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]"#

        guard let clientIDRegex = try? NSRegularExpression(pattern: clientIDPattern),
              let secretRegex = try? NSRegularExpression(pattern: secretPattern) else {
            return nil
        }

        let range = NSRange(content.startIndex..., in: content)
        guard let idMatch = clientIDRegex.firstMatch(in: content, range: range),
              let idRange = Range(idMatch.range(at: 1), in: content),
              let secretMatch = secretRegex.firstMatch(in: content, range: range),
              let secretRange = Range(secretMatch.range(at: 1), in: content) else {
            return nil
        }

        let clientID = String(content[idRange])
        let clientSecret = String(content[secretRange])
        guard !clientID.isEmpty, !clientSecret.isEmpty else { return nil }
        return OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
    }

    // MARK: - Read-Only OAuth Client Discovery

    public static func discoverOAuthClientCredentials(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> OAuthClientCredentials? {
        if let clientID = environment["GEMINI_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let clientSecret = environment["GEMINI_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clientID.isEmpty, !clientSecret.isEmpty {
            return OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret)
        }

        if let explicitPath = environment["GEMINI_OAUTH2_JS_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty,
           let creds = parseOAuthClientCredentials(fromFile: explicitPath) {
            return creds
        }

        for filePath in candidateOAuthFiles(home: home, environment: environment, fileManager: fileManager) {
            if let creds = parseOAuthClientCredentials(fromFile: filePath) {
                return creds
            }
        }

        for packageRoot in candidateGeminiPackageRoots(home: home, environment: environment, fileManager: fileManager) {
            if let creds = extractOAuthClientCredentials(fromPackageRoot: packageRoot, fileManager: fileManager) {
                return creds
            }
        }

        return nil
    }

    // MARK: - Network Fetch

    public func fetch(
        accessToken: String?,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        idToken: String? = nil,
        transport: (any APICostHTTPTransport)? = nil,
        oauthClientResolver: (@Sendable () -> OAuthClientCredentials?)? = nil,
        tokenCache: GeminiTokenMemoryCache = .shared,
        now: Date = Date()
    ) async throws -> QuotaSnapshot {
        var resolvedAccessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedAccessToken?.isEmpty == true {
            resolvedAccessToken = nil
        }
        var resolvedIDToken = idToken

        let needsRefresh = resolvedAccessToken == nil
            || expiresAt.map { $0.timeIntervalSince(now) <= 60 } == true

        if needsRefresh {
            guard let refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !refreshToken.isEmpty else {
                throw FetchError.unauthorized
            }
            if let cached = await tokenCache.cachedToken(for: refreshToken, now: now) {
                resolvedAccessToken = cached.accessToken
                resolvedIDToken = cached.idToken ?? resolvedIDToken
            } else {
                let resolver = oauthClientResolver ?? { Self.discoverOAuthClientCredentials() }
                guard let client = resolver() else {
                    throw FetchError.unauthorized
                }
                let refreshed = try await refreshAccessToken(
                    refreshToken: refreshToken,
                    client: client,
                    transport: transport,
                    now: now
                )
                await tokenCache.store(
                    refreshToken: refreshToken,
                    accessToken: refreshed.accessToken,
                    idToken: refreshed.idToken ?? resolvedIDToken,
                    expiresAt: refreshed.expiresAt
                )
                resolvedAccessToken = refreshed.accessToken
                resolvedIDToken = refreshed.idToken ?? resolvedIDToken
            }
        }

        guard let bearerToken = resolvedAccessToken, !bearerToken.isEmpty else {
            throw FetchError.unauthorized
        }

        let cloudCodeTransport = transport ?? SameOriginAPICostHTTPTransport(originURL: quotaURL)
        let hostedDomain = Self.extractHostedDomain(fromIDToken: resolvedIDToken)
        let codeAssistStatus = try await fetchCodeAssistStatus(
            accessToken: bearerToken,
            hostedDomain: hostedDomain,
            transport: cloudCodeTransport
        )

        var projectID = codeAssistStatus.projectID
        if projectID == nil {
            let projectsTransport = transport ?? SameOriginAPICostHTTPTransport(originURL: projectsURL)
            projectID = await discoverProjectID(
                accessToken: bearerToken,
                transport: projectsTransport
            )
        }

        let quotaBody: Data
        if let projectID {
            quotaBody = try JSONSerialization.data(withJSONObject: ["project": projectID])
        } else {
            quotaBody = Data("{}".utf8)
        }

        var quotaRequest = URLRequest(url: quotaURL)
        quotaRequest.httpMethod = "POST"
        quotaRequest.timeoutInterval = 15
        quotaRequest.httpBody = quotaBody
        quotaRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await perform(request: quotaRequest, on: cloudCodeTransport)
        switch response.statusCode {
        case 200...299:
            let plan = Self.resolvePlan(status: codeAssistStatus, hostedDomain: hostedDomain)
            return try parseQuota(data: data, plan: plan, now: now)
        case 401:
            if Self.containsConsumerDeprecationSignal(in: data) {
                throw FetchError.consumerTierDeprecated
            }
            throw FetchError.unauthorized
        case 403:
            if Self.containsConsumerDeprecationSignal(in: data)
                || (codeAssistStatus.isConsumerClientUnsupported && codeAssistStatus.tierID != "standard-tier") {
                throw FetchError.consumerTierDeprecated
            }
            throw FetchError.unauthorized
        default:
            if Self.containsConsumerDeprecationSignal(in: data) {
                throw FetchError.consumerTierDeprecated
            }
            throw FetchError.httpStatus(response.statusCode)
        }
    }

    // MARK: - Private Network Helpers

    private func refreshAccessToken(
        refreshToken: String,
        client: OAuthClientCredentials,
        transport: (any APICostHTTPTransport)?,
        now: Date
    ) async throws -> GeminiTokenMemoryCache.Entry {
        let effectiveTransport = transport ?? SameOriginAPICostHTTPTransport(originURL: tokenRefreshURL)
        var request = URLRequest(url: tokenRefreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedBody([
            ("client_id", client.clientID),
            ("client_secret", client.clientSecret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ])

        let (data, response) = try await perform(request: request, on: effectiveTransport)
        switch response.statusCode {
        case 200...299:
            break
        case 400, 401, 403:
            if Self.containsConsumerDeprecationSignal(in: data) {
                throw FetchError.consumerTierDeprecated
            }
            throw FetchError.unauthorized
        default:
            throw FetchError.httpStatus(response.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = (json["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !newAccessToken.isEmpty else {
            throw FetchError.decode("missing access_token in OAuth refresh response")
        }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let expiresAt = expiresIn.flatMap { $0.isFinite && $0 > 0 ? now.addingTimeInterval($0) : nil }
        let newIDToken = (json["id_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        return GeminiTokenMemoryCache.Entry(
            accessToken: newAccessToken,
            idToken: newIDToken?.isEmpty == true ? nil : newIDToken,
            expiresAt: expiresAt
        )
    }

    private func fetchCodeAssistStatus(
        accessToken: String,
        hostedDomain: String?,
        transport: any APICostHTTPTransport
    ) async throws -> CodeAssistStatus {
        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await perform(request: request, on: transport)
        } catch {
            // Non-fatal: quota endpoint can still work without project/tier metadata.
            return .empty
        }

        if response.statusCode == 401 {
            if Self.containsConsumerDeprecationSignal(in: data) {
                throw FetchError.consumerTierDeprecated
            }
            throw FetchError.unauthorized
        }

        guard (200...299).contains(response.statusCode) else {
            if Self.containsConsumerDeprecationSignal(in: data) {
                throw FetchError.consumerTierDeprecated
            }
            return .empty
        }

        do {
            return try Self.parseCodeAssistStatus(data: data, hostedDomain: hostedDomain)
        } catch FetchError.consumerTierDeprecated {
            throw FetchError.consumerTierDeprecated
        } catch {
            return .empty
        }
    }

    private func discoverProjectID(
        accessToken: String,
        transport: any APICostHTTPTransport
    ) async -> String? {
        var request = URLRequest(url: projectsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await perform(request: request, on: transport),
              (200...299).contains(response.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]] else {
            return nil
        }

        for project in projects {
            guard let projectID = (project["projectId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectID.isEmpty else {
                continue
            }
            if projectID.hasPrefix("gen-lang-client") {
                return projectID
            }
            if let labels = project["labels"] as? [String: String],
               labels["generative-language"] != nil {
                return projectID
            }
        }
        return nil
    }

    private func perform(
        request: URLRequest,
        on transport: any APICostHTTPTransport
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP response")
        }
        return (data, http)
    }

    // MARK: - Helpers

    private static func classifyTier(modelID: String) -> ModelTier {
        if modelID.contains("flash-lite") {
            return .flashLite
        }
        if modelID.contains("flash") {
            return .flash
        }
        if modelID.contains("pro") {
            return .pro
        }
        return .other
    }

    private static func tighter(_ lhs: ParsedBucket?, _ rhs: ParsedBucket) -> ParsedBucket {
        guard let lhs else { return rhs }
        if rhs.remainingFraction != lhs.remainingFraction {
            return rhs.remainingFraction < lhs.remainingFraction ? rhs : lhs
        }
        switch (lhs.resetTime, rhs.resetTime) {
        case let (.some(lDate), .some(rDate)):
            return rDate < lDate ? rhs : lhs
        case (.none, .some):
            return rhs
        default:
            return lhs
        }
    }

    private static func quotaWindow(from bucket: ParsedBucket, kind: WindowKind) -> QuotaWindow {
        let usedPercent = max(0, min(100, (1 - bucket.remainingFraction) * 100))
        return QuotaWindow(usedPercent: usedPercent, resetsAt: bucket.resetTime, kind: kind)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    private static func hasUnsupportedClientIneligibleTier(in json: [String: Any]) -> Bool {
        guard let ineligibleTiers = json["ineligibleTiers"] as? [[String: Any]] else {
            return false
        }
        return ineligibleTiers.contains { entry in
            [entry["reasonCode"], entry["reasonMessage"]]
                .compactMap { $0 as? String }
                .contains(where: isConsumerTierDeprecationSignal)
        }
    }

    private static func containsConsumerDeprecationSignal(in data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return false
        }
        return isConsumerTierDeprecationSignal(text)
    }

    private static func formURLEncodedBody(_ parameters: [(String, String)]) -> Data {
        let encoded = parameters.map { key, value in
            "\(formEncode(key))=\(formEncode(value))"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func formEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private static func parseOAuthClientCredentials(fromFile path: String) -> OAuthClientCredentials? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return parseOAuthClientCredentials(from: content)
    }

    private static func candidateOAuthFiles(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [String] {
        let oauthSubpath = "dist/src/code_assist/oauth2.js"
        let nestedCoreSubpath = "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthSubpath)"
        let directCoreSubpath = "node_modules/@google/gemini-cli-core/\(oauthSubpath)"
        var candidates = [
            "/opt/homebrew/lib/\(directCoreSubpath)",
            "/opt/homebrew/lib/\(nestedCoreSubpath)",
            "/usr/local/lib/\(directCoreSubpath)",
            "/usr/local/lib/\(nestedCoreSubpath)",
            home.appendingPathComponent(".npm-global/lib/\(directCoreSubpath)").path,
            home.appendingPathComponent(".npm-global/lib/\(nestedCoreSubpath)").path,
        ]

        if let binaryPath = resolveGeminiBinary(environment: environment, fileManager: fileManager) {
            let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
            let binDir = (resolved as NSString).deletingLastPathComponent
            let baseDir = (binDir as NSString).deletingLastPathComponent
            candidates.append(contentsOf: [
                "\(baseDir)/libexec/lib/\(nestedCoreSubpath)",
                "\(baseDir)/lib/\(nestedCoreSubpath)",
                "\(baseDir)/lib/\(directCoreSubpath)",
                "\(baseDir)/share/gemini-cli/\(directCoreSubpath)",
                "\(baseDir)/\(oauthSubpath)",
            ])
        }

        return candidates
    }

    private static func candidateGeminiPackageRoots(
        home: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> [String] {
        var roots: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard fileManager.fileExists(atPath: path), seen.insert(path).inserted else { return }
            roots.append(path)
        }

        for prefix in ["/opt/homebrew", "/usr/local"] {
            append("\(prefix)/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli")
            let cellarRoot = "\(prefix)/Cellar/gemini-cli"
            if let versions = try? fileManager.contentsOfDirectory(atPath: cellarRoot) {
                for version in versions.sorted().reversed() {
                    append("\(cellarRoot)/\(version)/libexec/lib/node_modules/@google/gemini-cli")
                }
            }
        }

        append(home.appendingPathComponent(".npm-global/lib/node_modules/@google/gemini-cli").path)

        if let binaryPath = resolveGeminiBinary(environment: environment, fileManager: fileManager) {
            let resolved = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath()
            var cursor = resolved.deletingLastPathComponent()
            for _ in 0..<6 {
                let packageJSON = cursor.appendingPathComponent("package.json").path
                let bundleEntry = cursor.appendingPathComponent("bundle/gemini.js").path
                let oauthFile = cursor.appendingPathComponent("dist/src/code_assist/oauth2.js").path
                if fileManager.fileExists(atPath: packageJSON)
                    || fileManager.fileExists(atPath: bundleEntry)
                    || fileManager.fileExists(atPath: oauthFile) {
                    append(cursor.path)
                }
                let nestedPackage = cursor.appendingPathComponent("libexec/lib/node_modules/@google/gemini-cli").path
                append(nestedPackage)
                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }

        return roots
    }

    private static func resolveGeminiBinary(
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        var searchDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        searchDirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        for dir in searchDirs where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("gemini")
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func extractOAuthClientCredentials(
        fromPackageRoot packageRoot: String,
        fileManager: FileManager
    ) -> OAuthClientCredentials? {
        let oauthFile = "dist/src/code_assist/oauth2.js"
        for path in [
            "\(packageRoot)/\(oauthFile)",
            "\(packageRoot)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ] {
            if let creds = parseOAuthClientCredentials(fromFile: path) {
                return creds
            }
        }

        let bundleRoot = URL(fileURLWithPath: packageRoot).appendingPathComponent("bundle", isDirectory: true)
        let entryURL = bundleRoot.appendingPathComponent("gemini.js")
        guard fileManager.fileExists(atPath: entryURL.path) else { return nil }

        var pending = [entryURL]
        var visited = Set<String>()
        while !pending.isEmpty {
            let current = pending.removeFirst()
            let canonical = current.standardizedFileURL.path
            guard visited.insert(canonical).inserted,
                  let content = try? String(contentsOf: current, encoding: .utf8) else {
                continue
            }
            if let creds = parseOAuthClientCredentials(from: content) {
                return creds
            }
            for relImport in extractRelativeJSImports(from: content) {
                let next = URL(fileURLWithPath: relImport, relativeTo: current.deletingLastPathComponent())
                    .standardizedFileURL
                if next.path.hasPrefix(bundleRoot.path) {
                    pending.append(next)
                }
            }
        }

        if let files = try? fileManager.contentsOfDirectory(
            at: bundleRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for fileURL in files where fileURL.pathExtension == "js" && !visited.contains(fileURL.standardizedFileURL.path) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8),
                   let creds = parseOAuthClientCredentials(from: content) {
                    return creds
                }
            }
        }
        return nil
    }

    private static func extractRelativeJSImports(from content: String) -> [String] {
        let patterns = [
            #"(?:import|export)\s+(?:[^;]*?\s+from\s+)?['"](\./[^'"]+\.js)['"]"#,
            #"import\(\s*['"](\./[^'"]+\.js)['"]\s*\)"#,
        ]
        var paths: [String] = []
        var seen = Set<String>()
        let range = NSRange(content.startIndex..., in: content)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: content, range: range) {
                guard let r = Range(match.range(at: 1), in: content) else { continue }
                let value = String(content[r])
                if seen.insert(value).inserted {
                    paths.append(value)
                }
            }
        }
        return paths
    }
}

#if os(macOS)
public extension GeminiCLIAdapter {
    func fetch(
        credentials: KeychainReader.Credentials,
        transport: (any APICostHTTPTransport)? = nil,
        oauthClientResolver: (@Sendable () -> OAuthClientCredentials?)? = nil,
        tokenCache: GeminiTokenMemoryCache = .shared,
        now: Date = Date()
    ) async throws -> QuotaSnapshot {
        try await fetch(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            expiresAt: credentials.expiresAt,
            idToken: credentials.idToken,
            transport: transport,
            oauthClientResolver: oauthClientResolver,
            tokenCache: tokenCache,
            now: now
        )
    }
}
#endif
