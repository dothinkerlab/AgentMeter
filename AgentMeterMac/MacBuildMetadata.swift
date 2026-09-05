import Foundation

enum MacBuildMetadata {
    private static let buildConfigurationKey = "AgentMeterBuildConfiguration"
    private static let cloudKitEnvironmentKey = "AgentMeterCloudKitEnvironment"

    static var buildConfiguration: String {
        infoValue(for: buildConfigurationKey)
    }

    static var cloudKitEnvironment: String {
        infoValue(for: cloudKitEnvironmentKey)
    }

    private static func infoValue(for key: String, bundle: Bundle = .main) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return "—" }
        return value
    }
}
