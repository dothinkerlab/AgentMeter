import Foundation
import UserNotifications
import AgentMeterCore

protocol FiveHourResetNotificationScheduling {
    func scheduleResetAlerts(for snapshots: [QuotaSnapshot]) async
    func cancelResetAlerts() async
}

struct FiveHourResetNotificationScheduler: FiveHourResetNotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    func scheduleResetAlerts(for snapshots: [QuotaSnapshot]) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let existingIdentifiers = await pendingResetAlertIdentifiers()
        let candidates = FiveHourResetAlertPlanner.candidates(
            from: snapshots,
            existingIdentifiers: existingIdentifiers
        )
        for candidate in candidates {
            await schedule(candidate)
        }
    }

    func cancelResetAlerts() async {
        let identifiers = await pendingResetAlertIdentifiers()
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func pendingResetAlertIdentifiers() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier).filter {
            $0.hasPrefix("agentmeter.reset.fiveHour.")
        })
    }

    private func schedule(_ candidate: FiveHourResetAlertCandidate) async {
        let interval = candidate.resetsAt.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.format("%@ 5 小时额度已重置", displayName(for: candidate.tool))
        content.body = L10n.string("现在可以继续使用 5 小时窗口。")
        content.sound = .default
        content.userInfo = [
            "tool": candidate.tool.rawValue,
            "windowKind": WindowKind.fiveHour.rawValue,
            "resetsAt": candidate.resetsAt.timeIntervalSince1970,
            "snapshotUpdatedAt": candidate.snapshotUpdatedAt.timeIntervalSince1970
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        let request = UNNotificationRequest(
            identifier: candidate.identifier,
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private func displayName(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .openCode: return "OpenCode"
        case .grok: return "xAI API"
        }
    }
}
