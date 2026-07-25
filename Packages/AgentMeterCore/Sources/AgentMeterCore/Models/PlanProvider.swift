import Foundation

/// Provider catalog used by the settings UI. This is presentation-only: it is
/// never encoded into CloudKit records or used as a credential identity.
public enum PlanProviderKind: String, CaseIterable, Sendable, Hashable {
    case chatGPT
    case claude
    case kimiCode
    case glmCoding
    case miniMax

    public enum CollectionMode: Sendable, Equatable {
        /// The Mac collector reads an existing CLI login. iPhone only consumes
        /// the sanitized CloudKit snapshot.
        case macAutomatic
        /// Mac and iPhone can each configure and collect this provider.
        case deviceConfigured
    }

    public var toolKind: ToolKind {
        switch self {
        case .chatGPT: .codex
        case .claude: .claudeCode
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        }
    }

    public var manualProvider: ManualProviderKind? {
        switch self {
        case .chatGPT, .claude: nil
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        }
    }

    public var collectionMode: CollectionMode {
        manualProvider == nil ? .macAutomatic : .deviceConfigured
    }
}

/// Local-only display preferences. They deliberately do not affect collection,
/// CloudKit, WidgetKit, WatchConnectivity, or notification scheduling.
public enum MainToolVisibilityPreferences {
    public static let managedTools: [ToolKind] = [.codex, .claudeCode]
    public static let codexKey = "mainToolVisibility.codex.enabled"
    public static let claudeCodeKey = "mainToolVisibility.claudeCode.enabled"

    public static func key(for tool: ToolKind) -> String {
        switch tool {
        case .codex: codexKey
        case .claudeCode: claudeCodeKey
        default: "mainToolVisibility.\(tool.rawValue).enabled"
        }
    }

    public static func isVisible(
        _ tool: ToolKind,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard managedTools.contains(tool) else { return true }
        let storageKey = key(for: tool)
        guard defaults.object(forKey: storageKey) != nil else { return true }
        return defaults.bool(forKey: storageKey)
    }

    public static func setVisible(
        _ visible: Bool,
        for tool: ToolKind,
        defaults: UserDefaults = .standard
    ) {
        guard managedTools.contains(tool) else { return }
        defaults.set(visible, forKey: key(for: tool))
    }

    public static func visibleTools(
        in tools: [ToolKind],
        defaults: UserDefaults = .standard
    ) -> [ToolKind] {
        tools.filter { isVisible($0, defaults: defaults) }
    }
}
