import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
/// In-memory TTL cache for `agy -p /usage --output-format json` fallback results.
public actor AntigravityCLICache {
    public static let shared = AntigravityCLICache()
    public static let defaultTTL: TimeInterval = 4 * 60

    private let ttl: TimeInterval
    private var entry: (snapshot: QuotaSnapshot, cachedAt: Date)?

    public init(ttl: TimeInterval = AntigravityCLICache.defaultTTL) {
        self.ttl = ttl
    }

    public func cachedSnapshot(now: Date = Date()) -> QuotaSnapshot? {
        guard let entry else { return nil }
        guard now.timeIntervalSince(entry.cachedAt) < ttl else {
            self.entry = nil
            return nil
        }
        return entry.snapshot
    }

    public func store(_ snapshot: QuotaSnapshot, now: Date = Date()) {
        entry = (snapshot: snapshot, cachedAt: now)
    }

    public func invalidate() {
        entry = nil
    }
}
#endif

/// Google Antigravity subscription quota adapter.
///
/// Preferred path queries the running local Antigravity language server over loopback
/// Connect-RPC (`RetrieveUserQuotaSummary`, falling back to `GetUserStatus` and
/// `GetCommandModelConfigs`). When the desktop app/IDE is closed, falls back to
/// `agy -p /usage --output-format json` in an isolated temporary directory with browser
/// launch suppressed.
public struct AntigravityQuotaAdapter: Sendable {
    public static let source = "antigravity_local_quota"
    public static let cliSource = "antigravity_cli_usage"

    private static let quotaSummaryPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let getUserStatusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let commandModelConfigPath = "/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs"

    public enum FetchError: Error, Sendable, Equatable {
        case notRunning
        case unauthorized
        case transport(String)
        case httpStatus(Int)
        case decode(String)
    }

    public struct LocalProcess: Sendable, Equatable {
        public let pid: Int
        public let commandLine: String
        public let csrfToken: String
        public let extensionPort: Int?
        public let extensionServerCSRFToken: String?

        public init(
            pid: Int,
            commandLine: String,
            csrfToken: String,
            extensionPort: Int? = nil,
            extensionServerCSRFToken: String? = nil
        ) {
            self.pid = pid
            self.commandLine = commandLine
            self.csrfToken = csrfToken
            self.extensionPort = extensionPort
            self.extensionServerCSRFToken = extensionServerCSRFToken
        }
    }

    public init() {
        #if os(macOS)
        self.runtime = .live
        self.cliCache = .shared
        #endif
    }

    #if os(macOS)
    public struct Runtime: Sendable {
        public var listProcesses: @Sendable () async throws -> [LocalProcess]
        public var listeningPorts: @Sendable (Int) async throws -> [Int]
        public var sendLocalRequest: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
        public var resolveAgyBinary: @Sendable () -> URL?
        public var runCLIUsage: @Sendable (URL) async throws -> (exitCode: Int32, stdout: Data, stderr: Data)
        public var now: @Sendable () -> Date

        public init(
            listProcesses: @escaping @Sendable () async throws -> [LocalProcess],
            listeningPorts: @escaping @Sendable (Int) async throws -> [Int],
            sendLocalRequest: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
            resolveAgyBinary: @escaping @Sendable () -> URL?,
            runCLIUsage: @escaping @Sendable (URL) async throws -> (exitCode: Int32, stdout: Data, stderr: Data),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.listProcesses = listProcesses
            self.listeningPorts = listeningPorts
            self.sendLocalRequest = sendLocalRequest
            self.resolveAgyBinary = resolveAgyBinary
            self.runCLIUsage = runCLIUsage
            self.now = now
        }

        public static let live = Runtime(
            listProcesses: { try await AntigravityQuotaAdapter.liveListProcesses() },
            listeningPorts: { pid in try await AntigravityQuotaAdapter.liveListeningPorts(pid: pid) },
            sendLocalRequest: { request in try await AntigravityQuotaAdapter.liveSendLocalRequest(request) },
            resolveAgyBinary: { AntigravityQuotaAdapter.resolveAgyBinary() },
            runCLIUsage: { binaryURL in try await AntigravityQuotaAdapter.liveRunCLIUsage(binaryURL: binaryURL) },
            now: { Date() }
        )
    }

    private let runtime: Runtime
    private let cliCache: AntigravityCLICache

    public init(
        runtime: Runtime = .live,
        cliCache: AntigravityCLICache = .shared
    ) {
        self.runtime = runtime
        self.cliCache = cliCache
    }

    public static func invalidateCLICache(_ cache: AntigravityCLICache = .shared) async {
        await cache.invalidate()
    }
    #endif

    public static func staleReason(for error: Error) -> QuotaStaleReason {
        switch error {
        case FetchError.unauthorized:
            .authExpired
        case FetchError.transport:
            .networkFailure
        case FetchError.httpStatus:
            .endpointFailure
        case FetchError.decode:
            .responseChanged
        case FetchError.notRunning:
            .credentialReadFailed
        default:
            .unknownFailure
        }
    }

    // MARK: - Pure Parsing

    private enum QuotaGroupPool {
        case gemini
        case claudeGPT
        case other
    }

    private enum BucketCadence {
        case session
        case weekly
        case other
    }

    private struct ParsedBucket {
        let kind: WindowKind
        let usedPercent: Double
        let resetsAt: Date?
    }

    public func parseQuotaSummary(
        data: Data,
        plan: String? = nil,
        source: String = AntigravityQuotaAdapter.source,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decode("invalid quota summary JSON")
        }
        try Self.validateResponseCode(in: root)

        let payload = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root

        let resolvedPlan = plan ?? Self.extractPlanName(from: root) ?? Self.extractPlanName(from: payload)
        return try Self.parseQuotaSummaryPayload(
            payload,
            plan: resolvedPlan,
            source: source,
            now: now
        )
    }

    public func parseCLIUsageReport(
        data: Data,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        let jsonObject: [String: Any]
        if let direct = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            jsonObject = direct
        } else if let sliced = Self.sliceTopLevelJSONObject(from: data),
                  let parsed = try? JSONSerialization.jsonObject(with: sliced) as? [String: Any] {
            jsonObject = parsed
        } else {
            if let text = String(data: data, encoding: .utf8), Self.looksLikeAuthFailure(text) {
                throw FetchError.unauthorized
            }
            throw FetchError.decode("invalid CLI usage JSON")
        }

        let status = Self.string(jsonObject, keys: ["status"])?.uppercased()
        if status != "SUCCESS",
           let errorText = Self.extractErrorText(from: jsonObject),
           Self.looksLikeAuthFailure(errorText) {
            throw FetchError.unauthorized
        }

        guard status == "SUCCESS",
              let command = jsonObject["command"] as? [String: Any],
              Self.string(command, keys: ["name"])?.lowercased() == "usage",
              let commandData = command["data"] as? [String: Any] else {
            throw FetchError.decode("unsuccessful CLI usage report")
        }

        let plan = Self.extractPlanName(from: commandData) ?? Self.extractPlanName(from: jsonObject)
        return try Self.parseQuotaSummaryPayload(
            commandData,
            plan: plan,
            source: Self.cliSource,
            now: now
        )
    }

    public func parseUserStatus(
        data: Data,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decode("invalid GetUserStatus JSON")
        }
        try Self.validateResponseCode(in: root)
        guard let userStatus = Self.dictionary(root, keys: ["userStatus", "user_status"]) else {
            throw FetchError.decode("missing userStatus")
        }

        let plan = Self.extractPlanName(fromUserStatus: userStatus)
        let modelData = Self.dictionary(userStatus, keys: ["cascadeModelConfigData", "cascade_model_config_data"])
        let configs = Self.arrayOfDictionaries(modelData, keys: ["clientModelConfigs", "client_model_configs"]) ?? []
        return try Self.parseModelConfigs(configs, plan: plan, source: Self.source, now: now)
    }

    public static func parsePlanFromUserStatus(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (try? validateResponseCode(in: root)) != nil,
              let userStatus = dictionary(root, keys: ["userStatus", "user_status"]) else {
            return nil
        }
        return extractPlanName(fromUserStatus: userStatus)
    }

    public func parseCommandModelConfigs(
        data: Data,
        plan: String? = nil,
        now: Date = Date()
    ) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.decode("invalid GetCommandModelConfigs JSON")
        }
        try Self.validateResponseCode(in: root)
        let configs = Self.arrayOfDictionaries(root, keys: ["clientModelConfigs", "client_model_configs"]) ?? []
        return try Self.parseModelConfigs(configs, plan: plan, source: Self.source, now: now)
    }

    // MARK: - Process & Port Parsing (Pure)

    public static func parseProcessList(_ output: String) -> [LocalProcess] {
        var results: [LocalProcess] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = String(parts[1])
            guard isAntigravityLanguageServerCommand(command) else { continue }
            guard let csrfToken = extractFlag("--csrf_token", from: command), !csrfToken.isEmpty else {
                continue
            }
            let extensionPort = extractFlag("--extension_server_port", from: command).flatMap(Int.init)
            let extensionCSRF = extractFlag("--extension_server_csrf_token", from: command)
            results.append(
                LocalProcess(
                    pid: pid,
                    commandLine: command,
                    csrfToken: csrfToken,
                    extensionPort: extensionPort,
                    extensionServerCSRFToken: extensionCSRF
                )
            )
        }
        return results
    }

    public static func parseListeningPorts(_ output: String) -> [Int] {
        var ports: [Int] = []
        var seen = Set<Int>()
        guard let regex = try? NSRegularExpression(pattern: #":(\d{1,5})\s+\(LISTEN\)"#) else {
            return []
        }

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let portRange = Range(match.range(at: 1), in: line),
                  let port = Int(line[portRange]),
                  (1...65535).contains(port) else {
                continue
            }
            if seen.insert(port).inserted {
                ports.append(port)
            }
        }
        return ports
    }

    // MARK: - Private Pure Helpers

    private static func parseQuotaSummaryPayload(
        _ payload: [String: Any],
        plan: String?,
        source: String,
        now: Date
    ) throws -> QuotaSnapshot {
        guard let groups = arrayOfDictionaries(payload, keys: ["groups"]), !groups.isEmpty else {
            throw FetchError.decode("missing quota groups")
        }

        var byKind: [WindowKind: ParsedBucket] = [:]

        for group in groups {
            let groupName = string(group, keys: ["displayName", "display_name", "name"]) ?? ""
            let groupPool = classifyPool(groupName)
            guard let buckets = arrayOfDictionaries(group, keys: ["buckets"]) else { continue }

            for bucket in buckets {
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let remaining = extractRemainingFraction(from: bucket),
                      remaining.isFinite else {
                    continue
                }

                let clampedRemaining = max(0, min(1, remaining))
                let usedPercent = max(0, min(100, (1 - clampedRemaining) * 100))
                let resetAt = dateValue(bucket["resetTime"] ?? bucket["reset_time"])
                let bucketID = string(bucket, keys: ["bucketId", "bucket_id", "id"]) ?? ""
                let bucketName = string(bucket, keys: ["displayName", "display_name", "name"]) ?? ""
                let windowHint = string(bucket, keys: ["window"])

                let effectivePool = groupPool == .other
                    ? classifyPool("\(bucketID) \(bucketName)")
                    : groupPool
                if effectivePool == .claudeGPT { continue }
                let cadence = classifyCadence(
                    windowHint: windowHint,
                    bucketID: bucketID,
                    displayName: bucketName
                )
                let kind = windowKind(for: effectivePool, cadence: cadence)
                let parsed = ParsedBucket(kind: kind, usedPercent: usedPercent, resetsAt: resetAt)

                if let existing = byKind[kind] {
                    byKind[kind] = tighterBucket(existing, parsed)
                } else {
                    byKind[kind] = parsed
                }
            }
        }

        let windows = orderedWindows(from: byKind)
        guard !windows.isEmpty else {
            throw FetchError.decode("no usable quota buckets")
        }

        return QuotaSnapshot(
            tool: .antigravity,
            plan: plan,
            windows: windows,
            confidence: .fresh,
            source: source,
            updatedAt: now
        )
    }

    private static func parseModelConfigs(
        _ configs: [[String: Any]],
        plan: String?,
        source: String,
        now: Date
    ) throws -> QuotaSnapshot {
        struct ModelEntry {
            let pool: QuotaGroupPool
            let usedPercent: Double
            let resetsAt: Date?
            let isSelectable: Bool
        }

        var entries: [ModelEntry] = []
        for config in configs {
            guard let quotaInfo = dictionary(config, keys: ["quotaInfo", "quota_info"]),
                  let remaining = number(quotaInfo["remainingFraction"] ?? quotaInfo["remaining_fraction"]),
                  remaining.isFinite else {
                continue
            }

            let label = string(config, keys: ["label"]) ?? ""
            let alias = dictionary(config, keys: ["modelOrAlias", "model_or_alias"])
            let modelID = alias.flatMap { string($0, keys: ["model"]) } ?? ""
            let resetAt = dateValue(quotaInfo["resetTime"] ?? quotaInfo["reset_time"])

            let lowerID = modelID.lowercased()
            let lowerLabel = label.lowercased()
            let pool = classifyModelPool(modelID: lowerID, label: lowerLabel)
            let isLite = lowerID.contains("lite") || lowerLabel.contains("lite")
            let isAutocomplete = lowerID.contains("autocomplete")
                || lowerLabel.contains("autocomplete")
                || lowerID.hasPrefix("tab_")
            let isImage = lowerID.contains("image") || lowerLabel.contains("image")
            let isSelectable = !isLite && !isAutocomplete && !isImage

            let clampedRemaining = max(0, min(1, remaining))
            let usedPercent = max(0, min(100, (1 - clampedRemaining) * 100))
            entries.append(
                ModelEntry(
                    pool: pool,
                    usedPercent: usedPercent,
                    resetsAt: resetAt,
                    isSelectable: isSelectable
                )
            )
        }

        guard !entries.isEmpty else {
            throw FetchError.decode("no usable model quota configs")
        }

        var byKind: [WindowKind: ParsedBucket] = [:]

        func bestInPool(_ pool: QuotaGroupPool, kind: WindowKind) {
            let poolSelectable = entries.filter { $0.pool == pool && $0.isSelectable }
            guard !poolSelectable.isEmpty else { return }
            for entry in poolSelectable {
                let candidate = ParsedBucket(kind: kind, usedPercent: entry.usedPercent, resetsAt: entry.resetsAt)
                if let existing = byKind[kind] {
                    byKind[kind] = tighterBucket(existing, candidate)
                } else {
                    byKind[kind] = candidate
                }
            }
        }

        bestInPool(.gemini, kind: .antigravityGemini)

        if byKind.isEmpty {
            let otherEntries = entries.filter { $0.pool == .other }
            let selectableUnknown = otherEntries.filter { $0.isSelectable }
            let fallbackPool = selectableUnknown.isEmpty ? otherEntries : selectableUnknown
            for entry in fallbackPool {
                let candidate = ParsedBucket(kind: .daily, usedPercent: entry.usedPercent, resetsAt: entry.resetsAt)
                if let existing = byKind[.daily] {
                    byKind[.daily] = tighterBucket(existing, candidate)
                } else {
                    byKind[.daily] = candidate
                }
            }
        }

        let windows = orderedWindows(from: byKind)
        guard !windows.isEmpty else {
            throw FetchError.decode("no mappable model quota windows")
        }

        return QuotaSnapshot(
            tool: .antigravity,
            plan: plan,
            windows: windows,
            confidence: .fresh,
            source: source,
            updatedAt: now
        )
    }

    private static let windowSortOrder: [WindowKind] = [
        .fiveHour,
        .sevenDay,
        .geminiFiveHour,
        .geminiWeekly,
        .antigravityGemini,
        .claudeGPTFiveHour,
        .claudeGPTWeekly,
        .antigravityClaudeGPT,
        .weekly,
        .daily,
    ]

    private static func orderedWindows(from byKind: [WindowKind: ParsedBucket]) -> [QuotaWindow] {
        windowSortOrder.compactMap { kind in
            guard let bucket = byKind[kind] else { return nil }
            return QuotaWindow(usedPercent: bucket.usedPercent, resetsAt: bucket.resetsAt, kind: kind)
        }
    }

    private static func tighterBucket(_ lhs: ParsedBucket, _ rhs: ParsedBucket) -> ParsedBucket {
        if rhs.usedPercent != lhs.usedPercent {
            return rhs.usedPercent > lhs.usedPercent ? rhs : lhs
        }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (.some(lDate), .some(rDate)):
            return rDate < lDate ? rhs : lhs
        case (.none, .some):
            return rhs
        default:
            return lhs
        }
    }

    private static func classifyPool(_ text: String) -> QuotaGroupPool {
        let lower = text.lowercased()
        if lower.contains("claude") || lower.contains("gpt") || lower.contains("openai") || lower.contains("3p") {
            return .claudeGPT
        }
        if lower.contains("gemini") {
            return .gemini
        }
        return .other
    }

    private static func classifyModelPool(modelID: String, label: String) -> QuotaGroupPool {
        let fromID = classifyPool(modelID)
        if fromID != .other { return fromID }
        return classifyPool(label)
    }

    private static func classifyCadence(
        windowHint: String?,
        bucketID: String,
        displayName: String
    ) -> BucketCadence {
        let sessionAliases: Set<String> = [
            "session", "5h", "5-hour", "five hour", "five-hour",
        ]
        let weeklyAliases: Set<String> = [
            "weekly", "1w", "7d", "7-day", "seven day", "seven-day",
        ]

        let rawValues: [String]
        if let hint = windowHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            rawValues = [hint]
        } else {
            rawValues = [bucketID, displayName]
        }

        var candidates = Set<String>()
        for raw in rawValues {
            var normalized = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !normalized.isEmpty else { continue }
            candidates.insert(normalized)
            if normalized.hasSuffix(" limit") {
                normalized = String(normalized.dropLast(" limit".count))
                candidates.insert(normalized)
            }
            for alias in sessionAliases.union(weeklyAliases) where normalized.hasSuffix("-\(alias)") || normalized.hasSuffix(" \(alias)") {
                candidates.insert(alias)
            }
        }

        if !candidates.isDisjoint(with: sessionAliases) {
            return .session
        }
        if !candidates.isDisjoint(with: weeklyAliases) {
            return .weekly
        }
        return .other
    }

    private static func windowKind(for pool: QuotaGroupPool, cadence: BucketCadence) -> WindowKind {
        switch (pool, cadence) {
        case (.gemini, .session): .fiveHour
        case (.gemini, .weekly): .sevenDay
        case (.gemini, .other): .antigravityGemini
        case (.claudeGPT, .session): .claudeGPTFiveHour
        case (.claudeGPT, .weekly): .claudeGPTWeekly
        case (.claudeGPT, .other): .antigravityClaudeGPT
        case (.other, .session): .fiveHour
        case (.other, .weekly): .sevenDay
        case (.other, .other): .daily
        }
    }

    private static func extractRemainingFraction(from bucket: [String: Any]) -> Double? {
        if let direct = number(bucket["remainingFraction"] ?? bucket["remaining_fraction"]) {
            return direct
        }
        if let nested = bucket["remaining"] as? [String: Any] {
            if let value = number(nested["remainingFraction"] ?? nested["remaining_fraction"]) {
                return value
            }
            if (nested["case"] as? String) == "remainingFraction",
               let value = number(nested["value"]) {
                return value
            }
        }
        return nil
    }

    private static func validateResponseCode(in root: [String: Any]) throws {
        guard let code = root["code"] else { return }
        if let intCode = code as? NSNumber, CFGetTypeID(intCode) != CFBooleanGetTypeID() {
            if intCode.intValue == 0 { return }
            if intCode.intValue == 16 || intCode.intValue == 7 {
                throw FetchError.unauthorized
            }
            throw FetchError.decode("API error code \(intCode.intValue)")
        }
        if let strCode = code as? String {
            let lower = strCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower == "0" || lower == "ok" || lower == "success" { return }
            if lower.contains("unauth") || lower.contains("permission_denied") {
                throw FetchError.unauthorized
            }
            throw FetchError.decode("API error code \(strCode)")
        }
        throw FetchError.decode("unsupported API code type")
    }

    private static func extractPlanName(from dictionary: [String: Any]) -> String? {
        if let userTier = self.dictionary(dictionary, keys: ["userTier", "user_tier"]),
           let name = string(userTier, keys: ["name"]) {
            return name
        }
        if let plan = string(dictionary, keys: ["accountPlan", "account_plan", "planName", "plan_name"]) {
            return plan
        }
        return nil
    }

    private static func extractPlanName(fromUserStatus userStatus: [String: Any]) -> String? {
        if let userTier = dictionary(userStatus, keys: ["userTier", "user_tier"]),
           let name = string(userTier, keys: ["name"]) {
            return name
        }
        if let planStatus = dictionary(userStatus, keys: ["planStatus", "plan_status"]),
           let planInfo = dictionary(planStatus, keys: ["planInfo", "plan_info"]) {
            return string(planInfo, keys: [
                "planDisplayName", "plan_display_name",
                "displayName", "display_name",
                "productName", "product_name",
                "planName", "plan_name",
                "planShortName", "plan_short_name",
            ])
        }
        return nil
    }

    private static func extractErrorText(from root: [String: Any]) -> String? {
        var parts: [String] = []
        if let error = root["error"] as? String { parts.append(error) }
        if let errorDict = root["error"] as? [String: Any] {
            if let message = errorDict["message"] as? String { parts.append(message) }
            if let code = errorDict["code"] as? String { parts.append(code) }
        }
        if let message = root["message"] as? String { parts.append(message) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("signed out")
            || lower.contains("sign in")
            || lower.contains("authentication required")
            || lower.contains("unauthenticated")
            || lower.contains("unauthorized")
            || lower.contains("login required")
            || lower.contains("http 401")
            || lower.contains("http 403")
    }

    private static func sliceTopLevelJSONObject(from data: Data) -> Data? {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start < end else {
            return nil
        }
        return data[start...end]
    }

    private static func isAntigravityLanguageServerCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        let pattern = #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        guard regex.firstMatch(in: lower, range: range) != nil else { return false }
        return lower.contains("antigravity")
            || lower.contains("--app_data_dir antigravity")
            || lower.contains("--app_data_dir=antigravity")
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == flag, tokens.indices.contains(index + 1) {
                let next = tokens[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return next.isEmpty ? nil : next
            }
            if token.hasPrefix("\(flag)=") {
                let value = String(token.dropFirst(flag.count + 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let raw = dictionary[key] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func dictionary(_ dictionary: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dictionary[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func arrayOfDictionaries(_ dictionary: [String: Any]?, keys: [String]) -> [[String: Any]]? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? [[String: Any]] { return value }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue
        }
        if let text = raw as? String {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let seconds = number(raw), seconds > 0 {
            let unix = seconds > 10_000_000_000 ? seconds / 1_000 : seconds
            return Date(timeIntervalSince1970: unix)
        }
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: trimmed) { return parsed }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let parsed = plain.date(from: trimmed) { return parsed }
            if let numeric = Double(trimmed), numeric > 0 {
                let unix = numeric > 10_000_000_000 ? numeric / 1_000 : numeric
                return Date(timeIntervalSince1970: unix)
            }
        }
        return nil
    }
}

#if os(macOS)
// MARK: - macOS Discovery & Runtime

public extension AntigravityQuotaAdapter {
    private struct CandidateEndpoint: Equatable {
        let scheme: String
        let port: Int
        let csrfToken: String
    }

    static func hasLocalEnvironment(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        if resolveAgyBinary(environment: environment, home: home, fileManager: fileManager) != nil {
            return true
        }
        let paths = [
            "/Applications/Antigravity.app",
            "/Applications/Antigravity IDE.app",
            home.appendingPathComponent("Applications/Antigravity.app").path,
            home.appendingPathComponent(".gemini/antigravity").path,
            home.appendingPathComponent(".gemini/antigravity-cli").path,
        ]
        return paths.contains { fileManager.fileExists(atPath: $0) }
    }

    static func resolveAgyBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["ANTIGRAVITY_CLI_PATH"] {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, fileManager.isExecutableFile(atPath: trimmed) else {
                return nil
            }
            return URL(fileURLWithPath: trimmed)
        }

        var searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("agy").path }

        searchPaths.append(contentsOf: [
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            home.appendingPathComponent(".local/bin/agy").path,
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
        ])

        for candidate in searchPaths where !candidate.isEmpty {
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    func fetch(
        forceRefresh: Bool = false,
        allowCachedCLI: Bool = true
    ) async throws -> QuotaSnapshot {
        let processes = (try? await runtime.listProcesses()) ?? []
        var sawUnauthorized = false
        var lastLocalError: Error?

        for process in processes {
            let ports = (try? await runtime.listeningPorts(process.pid)) ?? []
            let endpoints = Self.candidateEndpoints(for: process, listeningPorts: ports)
            guard !endpoints.isEmpty else { continue }

            switch await fetchFromEndpoints(endpoints) {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                if case FetchError.unauthorized = error {
                    sawUnauthorized = true
                }
                lastLocalError = error
            }
        }

        if let agyURL = runtime.resolveAgyBinary() {
            let now = runtime.now()
            if allowCachedCLI, !forceRefresh, let cached = await cliCache.cachedSnapshot(now: now) {
                return cached
            }
            let result = try await runtime.runCLIUsage(agyURL)
            if !result.stdout.isEmpty {
                do {
                    let snapshot = try parseCLIUsageReport(data: result.stdout, now: runtime.now())
                    await cliCache.store(snapshot, now: runtime.now())
                    return snapshot
                } catch FetchError.unauthorized {
                    throw FetchError.unauthorized
                } catch {
                    let combined = [
                        String(data: result.stderr, encoding: .utf8) ?? "",
                        String(data: result.stdout, encoding: .utf8) ?? "",
                    ].joined(separator: "\n")
                    if Self.looksLikeAuthFailure(combined) {
                        throw FetchError.unauthorized
                    }
                    if result.exitCode != 0 {
                        throw FetchError.transport("agy exit \(result.exitCode)")
                    }
                    throw error
                }
            } else {
                let stderrText = String(data: result.stderr, encoding: .utf8) ?? ""
                if Self.looksLikeAuthFailure(stderrText) {
                    throw FetchError.unauthorized
                }
                throw FetchError.transport("agy exit \(result.exitCode) with empty output")
            }
        }

        if sawUnauthorized {
            throw FetchError.unauthorized
        }
        if !processes.isEmpty, let lastLocalError {
            throw lastLocalError
        }
        throw FetchError.notRunning
    }

    // MARK: - Path A Loopback Probing

    private enum EndpointAttemptResult {
        case success(QuotaSnapshot)
        case failure(Error)
    }

    private func fetchFromEndpoints(_ endpoints: [CandidateEndpoint]) async -> EndpointAttemptResult {
        let now = runtime.now()
        var sawUnauthorized = false
        var lastError: Error?

        // 1. Preferred: RetrieveUserQuotaSummary (+ best-effort GetUserStatus plan lookup)
        for endpoint in endpoints {
            do {
                let data = try await postLocalJSON(
                    path: Self.quotaSummaryPath,
                    body: Data(#"{"forceRefresh":true}"#.utf8),
                    endpoint: endpoint,
                    timeout: 5
                )
                let plan = await fetchBestEffortPlan(endpoint: endpoint)
                let snapshot = try parseQuotaSummary(data: data, plan: plan, now: now)
                return .success(snapshot)
            } catch {
                if case FetchError.unauthorized = error { sawUnauthorized = true }
                lastError = error
            }
        }

        // 2. Fallback: GetUserStatus
        for endpoint in endpoints {
            do {
                let data = try await postLocalJSON(
                    path: Self.getUserStatusPath,
                    body: Self.defaultLocalMetadataBody,
                    endpoint: endpoint,
                    timeout: 5
                )
                return .success(try parseUserStatus(data: data, now: now))
            } catch {
                if case FetchError.unauthorized = error { sawUnauthorized = true }
                lastError = error
            }
        }

        // 3. Fallback: GetCommandModelConfigs
        for endpoint in endpoints {
            do {
                let data = try await postLocalJSON(
                    path: Self.commandModelConfigPath,
                    body: Self.defaultLocalMetadataBody,
                    endpoint: endpoint,
                    timeout: 5
                )
                return .success(try parseCommandModelConfigs(data: data, now: now))
            } catch {
                if case FetchError.unauthorized = error { sawUnauthorized = true }
                lastError = error
            }
        }

        if sawUnauthorized {
            return .failure(FetchError.unauthorized)
        }
        return .failure(lastError ?? FetchError.notRunning)
    }

    private func fetchBestEffortPlan(endpoint: CandidateEndpoint) async -> String? {
        guard let data = try? await postLocalJSON(
            path: Self.getUserStatusPath,
            body: Self.defaultLocalMetadataBody,
            endpoint: endpoint,
            timeout: 2
        ) else {
            return nil
        }
        return Self.parsePlanFromUserStatus(data: data)
    }

    private func postLocalJSON(
        path: String,
        body: Data,
        endpoint: CandidateEndpoint,
        timeout: TimeInterval
    ) async throws -> Data {
        guard let url = URL(string: "\(endpoint.scheme)://127.0.0.1:\(endpoint.port)\(path)") else {
            throw FetchError.transport("invalid localhost URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !endpoint.csrfToken.isEmpty {
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await runtime.sendLocalRequest(request)
        } catch let error as FetchError {
            throw error
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.httpStatus(response.statusCode)
        }
    }

    private static func candidateEndpoints(
        for process: LocalProcess,
        listeningPorts: [Int]
    ) -> [CandidateEndpoint] {
        var endpoints: [CandidateEndpoint] = []

        func appendUnique(_ endpoint: CandidateEndpoint) {
            if !endpoints.contains(endpoint) {
                endpoints.append(endpoint)
            }
        }

        let orderedPorts = listeningPorts.filter { $0 != process.extensionPort }
            + listeningPorts.filter { $0 == process.extensionPort }

        for port in orderedPorts {
            appendUnique(CandidateEndpoint(scheme: "https", port: port, csrfToken: process.csrfToken))
        }

        if let extensionPort = process.extensionPort {
            if let extCSRF = process.extensionServerCSRFToken, !extCSRF.isEmpty {
                appendUnique(CandidateEndpoint(scheme: "http", port: extensionPort, csrfToken: extCSRF))
            }
            if process.extensionServerCSRFToken != process.csrfToken {
                appendUnique(CandidateEndpoint(scheme: "http", port: extensionPort, csrfToken: process.csrfToken))
            }
        }

        return endpoints
    }

    private static let defaultLocalMetadataBody = Data(
        #"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8
    )

    // MARK: - Live Process / Localhost Execution

    private static let localhostDelegate = AntigravityLocalhostSessionDelegate()
    private static let localhostSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: localhostDelegate, delegateQueue: nil)
    }()

    private static func liveSendLocalRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await localhostSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("non-HTTP localhost response")
        }
        return (data, http)
    }

    private static func liveListProcesses() async throws -> [LocalProcess] {
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-ax", "-o", "pid=,command="],
            environment: ["PATH": "/bin:/usr/bin"],
            timeout: 3
        )
        guard result.exitCode == 0,
              let text = String(data: result.stdout, encoding: .utf8) else {
            return []
        }
        return parseProcessList(text)
    }

    private static func liveListeningPorts(pid: Int) async throws -> [Int] {
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)],
            environment: ["PATH": "/bin:/usr/bin:/usr/sbin"],
            timeout: 3
        )
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            return []
        }
        return parseListeningPorts(text)
    }

    private static func liveRunCLIUsage(
        binaryURL: URL
    ) async throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("agentmeter-agy-\(UUID().uuidString)", isDirectory: true)
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: binDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: tempRoot) }

        let stubScript = Data("#!/bin/sh\nexit 1\n".utf8)
        let openStub = binDir.appendingPathComponent("open")
        let xdgOpenStub = binDir.appendingPathComponent("xdg-open")
        try stubScript.write(to: openStub, options: .atomic)
        try stubScript.write(to: xdgOpenStub, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: openStub.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: xdgOpenStub.path)

        let parentEnv = ProcessInfo.processInfo.environment
        var childEnv: [String: String] = [:]
        for key in [
            "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "SSH_TTY",
        ] {
            if let value = parentEnv[key], !value.isEmpty {
                childEnv[key] = value
            }
        }
        let existingPath = parentEnv["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        childEnv["PATH"] = "\(binDir.path):\(existingPath)"
        childEnv["BROWSER"] = openStub.path
        childEnv["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"

        return try await runProcess(
            executableURL: binaryURL,
            arguments: ["-p", "/usage", "--output-format", "json"],
            environment: childEnv,
            currentDirectoryURL: tempRoot,
            timeout: 25
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        maxBytes: Int = 1_048_576
    ) async throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        final class CaptureState: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutData = Data()
            private var stderrData = Data()
            private var stdoutEOF = false
            private var stderrEOF = false
            private var exitCode: Int32?
            private var finished = false
            private let maxBytes: Int
            private var continuation: CheckedContinuation<(exitCode: Int32, stdout: Data, stderr: Data), Error>?
            private var timeoutWorkItem: DispatchWorkItem?
            private var postExitTimer: DispatchWorkItem?

            init(maxBytes: Int) {
                self.maxBytes = maxBytes
            }

            func attach(
                continuation: CheckedContinuation<(exitCode: Int32, stdout: Data, stderr: Data), Error>,
                timeoutWorkItem: DispatchWorkItem
            ) {
                lock.lock()
                self.continuation = continuation
                self.timeoutWorkItem = timeoutWorkItem
                lock.unlock()
                tryCompleteIfReady()
            }

            func appendStdout(_ chunk: Data) -> Bool {
                lock.lock()
                if chunk.isEmpty {
                    stdoutEOF = true
                } else if stdoutData.count < maxBytes {
                    let remaining = maxBytes - stdoutData.count
                    stdoutData.append(chunk.prefix(remaining))
                }
                let isEOF = stdoutEOF
                lock.unlock()
                if isEOF { tryCompleteIfReady() }
                return isEOF
            }

            func appendStderr(_ chunk: Data) -> Bool {
                lock.lock()
                if chunk.isEmpty {
                    stderrEOF = true
                } else if stderrData.count < maxBytes {
                    let remaining = maxBytes - stderrData.count
                    stderrData.append(chunk.prefix(remaining))
                }
                let isEOF = stderrEOF
                lock.unlock()
                if isEOF { tryCompleteIfReady() }
                return isEOF
            }

            func markTerminated(exitCode: Int32, onGraceDeadline: @escaping @Sendable () -> Void) {
                lock.lock()
                self.exitCode = exitCode
                let needsGrace = !finished && (!stdoutEOF || !stderrEOF)
                if needsGrace && postExitTimer == nil {
                    let item = DispatchWorkItem(block: onGraceDeadline)
                    postExitTimer = item
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25, execute: item)
                }
                lock.unlock()
                tryCompleteIfReady()
            }

            func forceEOFAndComplete() {
                lock.lock()
                stdoutEOF = true
                stderrEOF = true
                lock.unlock()
                tryCompleteIfReady()
            }

            func fail(_ error: Error) {
                lock.lock()
                guard !finished else {
                    lock.unlock()
                    return
                }
                finished = true
                timeoutWorkItem?.cancel()
                postExitTimer?.cancel()
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(throwing: error)
            }

            private func tryCompleteIfReady() {
                lock.lock()
                guard !finished,
                      let exitCode,
                      stdoutEOF,
                      stderrEOF,
                      let cont = continuation else {
                    lock.unlock()
                    return
                }
                finished = true
                timeoutWorkItem?.cancel()
                postExitTimer?.cancel()
                let out = stdoutData
                let err = stderrData
                continuation = nil
                lock.unlock()
                cont.resume(returning: (exitCode: exitCode, stdout: out, stderr: err))
            }
        }

        let state = CaptureState(maxBytes: maxBytes)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if state.appendStdout(chunk) {
                handle.readabilityHandler = nil
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if state.appendStderr(chunk) {
                handle.readabilityHandler = nil
            }
        }

        process.terminationHandler = { proc in
            state.markTerminated(exitCode: proc.terminationStatus) {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                state.forceEOFAndComplete()
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutWorkItem = DispatchWorkItem {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    if process.isRunning {
                        process.terminate()
                    }
                    state.fail(FetchError.transport("subprocess timed out"))
                }
                state.attach(continuation: continuation, timeoutWorkItem: timeoutWorkItem)

                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + timeout,
                        execute: timeoutWorkItem
                    )
                } catch {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    state.fail(FetchError.transport(error.localizedDescription))
                }
            }
        } onCancel: {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            state.fail(CancellationError())
        }
    }
}

private final class AntigravityLocalhostSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
