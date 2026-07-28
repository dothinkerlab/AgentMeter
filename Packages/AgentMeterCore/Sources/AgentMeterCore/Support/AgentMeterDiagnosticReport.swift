import Foundation

/// A shareable, deliberately allow-listed diagnostic report.
///
/// Credentials, Keychain values, device names, raw HTTP payloads, billing amounts,
/// and raw logs are intentionally not accepted by this type.
public struct AgentMeterDiagnosticReport: Sendable, Equatable {
    public struct LocalServiceStatus: Sendable, Equatable {
        public let service: String
        public let confidence: DataConfidence
        public let staleReason: QuotaStaleReason?
        public let updatedAt: Date

        public init(
            service: String,
            confidence: DataConfidence,
            staleReason: QuotaStaleReason?,
            updatedAt: Date
        ) {
            self.service = service
            self.confidence = confidence
            self.staleReason = staleReason
            self.updatedAt = updatedAt
        }
    }

    public let generatedAt: Date
    public let appVersion: String
    public let appBuild: String
    public let platform: String
    public let operatingSystem: String
    public let snapshots: [QuotaSnapshot]
    public let localServices: [LocalServiceStatus]
    public let cloudSyncPendingTools: Set<ToolKind>

    public init(
        generatedAt: Date = Date(),
        appVersion: String,
        appBuild: String,
        platform: String,
        operatingSystem: String,
        snapshots: [QuotaSnapshot],
        localServices: [LocalServiceStatus] = [],
        cloudSyncPendingTools: Set<ToolKind> = []
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.platform = platform
        self.operatingSystem = operatingSystem
        self.snapshots = snapshots
        self.localServices = localServices
        self.cloudSyncPendingTools = cloudSyncPendingTools
    }

    public var suggestedFilename: String {
        "AgentMeter-Diagnostics-\(Self.filenameDate(generatedAt)).txt"
    }

    public var text: String {
        var lines = [
            "AgentMeter diagnostics (sanitized)",
            "Generated: \(Self.date(generatedAt))",
            "App: \(appVersion) (\(appBuild))",
            "Platform: \(platform)",
            "OS: \(operatingSystem)",
            "Build configuration: \(Self.buildConfiguration)",
            "Expected CloudKit environment: \(Self.expectedCloudKitEnvironment)",
            "Privacy: no tokens, API keys, Keychain values, raw logs, device names, or billing amounts are included.",
            "",
            "Coding plan snapshots:",
        ]

        if snapshots.isEmpty {
            lines.append("- none")
        } else {
            for snapshot in snapshots.sorted(by: { $0.tool.rawValue < $1.tool.rawValue }) {
                let reason = snapshot.staleReason?.rawValue ?? "none"
                lines.append(
                    "- \(snapshot.tool.rawValue): confidence=\(snapshot.confidence.rawValue), " +
                    "staleReason=\(reason), collector=\(snapshot.effectiveCollector.rawValue), " +
                    "updatedAt=\(Self.date(snapshot.updatedAt)), source=\(snapshot.source)"
                )
                if snapshot.windows.isEmpty {
                    lines.append("  windows: none")
                } else {
                    for window in snapshot.windows.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
                        lines.append(
                            "  \(window.kind.rawValue): used=\(Self.percent(window.usedPercent))%, " +
                            "resetsAt=\(Self.date(window.resetsAt))"
                        )
                    }
                }
            }
        }

        lines.append("")
        lines.append("Local billing services (status only; amounts omitted):")
        if localServices.isEmpty {
            lines.append("- none")
        } else {
            for status in localServices.sorted(by: { $0.service < $1.service }) {
                lines.append(
                    "- \(status.service): confidence=\(status.confidence.rawValue), " +
                    "staleReason=\(status.staleReason?.rawValue ?? "none"), " +
                    "updatedAt=\(Self.date(status.updatedAt))"
                )
            }
        }

        lines.append("")
        let pending = cloudSyncPendingTools.map(\.rawValue).sorted()
        lines.append("CloudKit writes pending: \(pending.isEmpty ? "none" : pending.joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static var buildConfiguration: String {
#if DEBUG
        "Debug"
#else
        "Release"
#endif
    }

    private static var expectedCloudKitEnvironment: String {
#if DEBUG
        "Development"
#else
        "Production"
#endif
    }

    private static func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func filenameDate(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
