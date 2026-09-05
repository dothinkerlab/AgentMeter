import Foundation

enum MacBuildMetadata {
    private static let shortVersionKey = "CFBundleShortVersionString"
    private static let buildNumberKey = "CFBundleVersion"
    private static let buildConfigurationKey = "AgentMeterBuildConfiguration"
    private static let cloudKitEnvironmentKey = "AgentMeterCloudKitEnvironment"

    static var buildConfiguration: String {
        infoValue(for: buildConfigurationKey, in: Bundle.main.infoDictionary)
    }

    static var cloudKitEnvironment: String {
        infoValue(for: cloudKitEnvironmentKey, in: Bundle.main.infoDictionary)
    }

    static var aboutVersion: String {
        aboutVersion(infoDictionary: Bundle.main.infoDictionary)
    }

    static func aboutVersion(infoDictionary: [String: Any]?) -> String {
        let shortVersion = infoValue(for: shortVersionKey, in: infoDictionary)
        let buildNumber = infoValue(for: buildNumberKey, in: infoDictionary)
        let buildConfiguration = infoValue(for: buildConfigurationKey, in: infoDictionary)
        let cloudKitEnvironment = infoValue(for: cloudKitEnvironmentKey, in: infoDictionary)
        return "\(shortVersion) (\(buildNumber) · \(buildConfiguration) · \(cloudKitEnvironment))"
    }

    private static func infoValue(for key: String, in infoDictionary: [String: Any]?) -> String {
        guard let value = infoDictionary?[key] as? String,
              !value.isEmpty else { return "—" }
        return value
    }
}
