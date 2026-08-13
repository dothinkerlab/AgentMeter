import Foundation

/// Every provider whose credential can be entered manually in AgentMeter.
/// This identity is intentionally separate from `ToolKind`: Kimi API is a
/// billing balance rather than a quota tool, while xAI is represented by
/// `ToolKind.grok` in existing display code.
public enum ManualProviderKind: String, Codable, CaseIterable, Sendable, Hashable {
    case kimiCode
    case glmCoding
    case miniMax
    case kimiAPI
    case deepSeek
    case openRouter
    case xAI
    case openAIAPI
    case anthropicAPI
    case cursorTeam

    public enum Category: Sendable {
        case codingPlan
        case billing
    }

    public enum CredentialShape: Sendable {
        case apiKey
        case managementKeyAndTeamID
    }

    public var category: Category {
        switch self {
        case .kimiCode, .glmCoding, .miniMax: .codingPlan
        case .kimiAPI, .deepSeek, .openRouter, .xAI, .openAIAPI, .anthropicAPI, .cursorTeam: .billing
        }
    }

    public var credentialShape: CredentialShape {
        self == .xAI ? .managementKeyAndTeamID : .apiKey
    }

    public var supportsRegion: Bool {
        switch self {
        case .glmCoding, .miniMax, .kimiAPI: true
        default: false
        }
    }

    public var toolKind: ToolKind? {
        switch self {
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        case .deepSeek: .deepSeek
        case .openRouter: .openRouter
        case .xAI: .grok
        case .kimiAPI, .openAIAPI, .anthropicAPI, .cursorTeam: nil
        }
    }

    public var localBillingService: LocalBillingService? {
        switch self {
        case .kimiAPI: .kimiAPI
        case .deepSeek: .deepSeek
        case .openRouter: .openRouter
        case .xAI: .xAI
        case .openAIAPI: .openAIAPI
        case .anthropicAPI: .anthropicAPI
        case .cursorTeam: nil
        default: nil
        }
    }
}

/// Shared, user-facing connection state. It never contains credential data.
public enum ProviderConnectionState: Sendable, Equatable {
    case unconfigured
    case disabled
    case checking
    case connected
    case pendingVerification(QuotaStaleReason)
    case invalidCredential
    case storageFailure

    public static func resolved(
        hasCredential: Bool,
        isEnabled: Bool,
        confidence: DataConfidence?,
        staleReason: QuotaStaleReason?
    ) -> Self {
        guard hasCredential else { return .unconfigured }
        guard isEnabled else { return .disabled }
        guard let confidence else {
            return .pendingVerification(staleReason ?? .unknownFailure)
        }
        if confidence == .fresh { return .connected }
        if staleReason == .authExpired { return .invalidCredential }
        return .pendingVerification(staleReason ?? .unknownFailure)
    }
}

/// Invalidates an in-flight settings verification when the same provider is
/// retried, disabled, or removed. The generation contains no credential data.
public actor ManualProviderOperationGate {
    public static let shared = ManualProviderOperationGate()

    private var generations: [ManualProviderKind: UInt64] = [:]

    public init() {}

    public func begin(_ provider: ManualProviderKind) -> UInt64 {
        generations[provider, default: 0] &+= 1
        return generations[provider, default: 0]
    }

    public func invalidate(_ provider: ManualProviderKind) {
        generations[provider, default: 0] &+= 1
    }

    public func isCurrent(_ generation: UInt64, for provider: ManualProviderKind) -> Bool {
        generations[provider] == generation
    }
}

/// Non-secret settings shared by the Mac and iPhone configuration UIs.
/// Existing keys are deliberately retained so upgrades preserve user intent.
public enum ManualProviderPreferences {
    public static func enabledKey(_ provider: ManualProviderKind) -> String {
        switch provider {
        case .kimiCode, .glmCoding, .miniMax:
            return "codingProvider.\(provider.rawValue).enabled"
        case .kimiAPI, .deepSeek, .openRouter, .xAI, .openAIAPI, .anthropicAPI, .cursorTeam:
            return "manualProvider.\(provider.rawValue).enabled"
        }
    }

    public static func regionKey(_ provider: ManualProviderKind) -> String? {
        switch provider {
        case .glmCoding, .miniMax:
            return "codingProvider.\(provider.rawValue).region"
        case .kimiAPI:
            return "kimiAPI.region"
        default:
            return nil
        }
    }

    /// Billing providers historically had no enable switch. For those rows,
    /// an existing credential means enabled until the user makes an explicit
    /// choice. Coding providers keep their existing default-off behavior.
    public static func isEnabled(
        _ provider: ManualProviderKind,
        credentialExists: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = enabledKey(provider)
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return provider.category == .billing && credentialExists
    }

    public static func setEnabled(
        _ enabled: Bool,
        for provider: ManualProviderKind,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: enabledKey(provider))
    }

    public static func region(
        for provider: ManualProviderKind,
        defaults: UserDefaults = .standard
    ) -> ProviderRegion {
        guard let key = regionKey(provider) else { return .global }
        return ProviderRegion(rawValue: defaults.string(forKey: key) ?? "") ?? .global
    }

    public static func setRegion(
        _ region: ProviderRegion,
        for provider: ManualProviderKind,
        defaults: UserDefaults = .standard
    ) {
        guard let key = regionKey(provider) else { return }
        defaults.set(region.rawValue, forKey: key)
    }
}

/// Merges the two xAI fields without ever exposing a stored Management Key to UI.
/// Empty input keeps the corresponding stored value, which allows Team ID-only
/// and Management Key-only updates.
public enum ManualProviderCredentialMerge {
    public static func xAI(
        existing: GrokManagementCredentials?,
        managementKeyInput: String,
        teamIDInput: String
    ) -> GrokManagementCredentials? {
        let newKey = managementKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTeamID = teamIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let managementKey = newKey.isEmpty ? existing?.managementKey ?? "" : newKey
        let teamID = newTeamID.isEmpty ? existing?.teamID ?? "" : newTeamID
        guard !managementKey.isEmpty, !teamID.isEmpty else { return nil }
        return GrokManagementCredentials(managementKey: managementKey, teamID: teamID)
    }
}
