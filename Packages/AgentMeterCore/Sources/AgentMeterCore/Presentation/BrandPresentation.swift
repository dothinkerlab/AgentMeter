import Foundation

public enum BrandPresentationMode: String, Codable, Sendable, Equatable {
    case standard
    case mainlandChina

    public static func storefront(countryCode: String?) -> Self {
        guard let countryCode else { return .mainlandChina }
        return countryCode.uppercased() == "CHN" ? .mainlandChina : .standard
    }
}

public protocol BrandStorefrontCountryCodeProviding: Sendable {
    func currentCountryCode() async -> String?
    var countryCodeUpdates: AsyncStream<String?> { get }
}

/// StoreKit-independent storefront resolution so launch failure and update behavior can
/// be tested without accessing the App Store.
public struct BrandStorefrontResolver: Sendable {
    private let provider: any BrandStorefrontCountryCodeProviding

    public init(provider: any BrandStorefrontCountryCodeProviding) {
        self.provider = provider
    }

    public func refresh() async -> BrandPresentationMode {
        .storefront(countryCode: await provider.currentCountryCode())
    }

    public var updates: AsyncStream<BrandPresentationMode> {
        AsyncStream { continuation in
            let task = Task {
                for await countryCode in provider.countryCodeUpdates {
                    guard !Task.isCancelled else { break }
                    continuation.yield(.storefront(countryCode: countryCode))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// User-facing provider naming only. Wire values, URLs, Keychain service names,
/// CloudKit records, and adapter/source identifiers must never pass through here.
public enum BrandPresentation {
    public static let storageKey = "brandPresentationMode.v1"

    public static var cachedMode: BrandPresentationMode {
        #if os(iOS) || os(watchOS)
        guard let defaults = UserDefaults(suiteName: LocalBillingCache.appGroupIdentifier),
              let raw = defaults.string(forKey: storageKey),
              let mode = BrandPresentationMode(rawValue: raw) else {
            // Fail closed until StoreKit provides an authoritative storefront.
            return .mainlandChina
        }
        return mode
        #else
        // The separately distributed Mac collector is intentionally unaffected.
        return .standard
        #endif
    }

    public static func cache(_ mode: BrandPresentationMode) {
        #if os(iOS) || os(watchOS)
        UserDefaults(suiteName: LocalBillingCache.appGroupIdentifier)?
            .set(mode.rawValue, forKey: storageKey)
        #endif
    }

    public static func text(
        _ value: String,
        mode: BrandPresentationMode = cachedMode
    ) -> String {
        guard mode == .mainlandChina else { return value }
        guard !isProtectedInternalValue(value) else { return value }

        // Longest/specific forms first. Replacements are deliberately limited
        // to strings that are about to be presented to the user.
        return replacements.reduce(value) { result, replacement in
            result.replacingOccurrences(
                of: replacement.source,
                with: replacement.destination,
                options: [.caseInsensitive, .literal]
            )
        }
    }

    public static func displayName(
        for tool: ToolKind,
        short: Bool = false,
        mode: BrandPresentationMode = cachedMode
    ) -> String {
        let standard: String
        switch tool {
        case .claudeCode: standard = short ? "Claude" : "Claude Code"
        case .codex: standard = "Codex"
        case .cursor: standard = "Cursor"
        case .kimiCode: standard = short ? "Kimi" : "Kimi Code"
        case .glmCoding: standard = short ? "GLM" : "GLM Coding Plan"
        case .miniMax: standard = short ? "MiniMax" : "MiniMax Token Plan"
        case .openCode: standard = "OpenCode"
        case .deepSeek: standard = "DeepSeek"
        case .openRouter: standard = "OpenRouter"
        case .grok: standard = "xAI API"
        }
        return text(standard, mode: mode)
    }

    private static let replacements: [(source: String, destination: String)] = [
        ("Claude Code", "CC"),
        ("ClaudeDevs", "CCDevs"),
        ("ChatGPT", "O记"),
        ("Anthropic", "A➗"),
        ("OpenAI", "O记"),
        ("Codex", "CX"),
        ("Claude", "CC")
    ]

    private static func isProtectedInternalValue(_ value: String) -> Bool {
        if ToolKind.allCases.contains(where: { $0.rawValue == value }) {
            return true
        }
        if value.localizedCaseInsensitiveContains("-credentials") {
            return true
        }
        if value.contains("://"),
           let components = URLComponents(string: value), components.scheme != nil {
            return true
        }
        return false
    }
}
