import Foundation
import AgentMeterCore

/// Mac 上可由设备独立配置的 Coding Plan provider。
/// 偏好 key 继续委托给 Core，保证升级时沿用已有设置。
enum MacCodingProviderPreferences {
    static let tools: [ToolKind] = [.kimiCode, .glmCoding, .miniMax]

    static func provider(_ tool: ToolKind) -> ManualProviderKind? {
        switch tool {
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        default: nil
        }
    }

    static func enabledKey(_ tool: ToolKind) -> String {
        provider(tool).map(ManualProviderPreferences.enabledKey) ?? "codingProvider.\(tool.rawValue).enabled"
    }

    static func regionKey(_ tool: ToolKind) -> String {
        provider(tool).flatMap(ManualProviderPreferences.regionKey) ?? "codingProvider.\(tool.rawValue).region"
    }

    static func isEnabled(_ tool: ToolKind) -> Bool {
        guard let provider = provider(tool) else { return false }
        return ManualProviderPreferences.isEnabled(provider, credentialExists: false)
    }

    static func region(_ tool: ToolKind) -> ProviderRegion {
        guard let provider = provider(tool) else { return .global }
        return ManualProviderPreferences.region(for: provider)
    }
}
