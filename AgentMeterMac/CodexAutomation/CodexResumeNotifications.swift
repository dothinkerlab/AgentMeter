import Foundation
import UserNotifications
import AgentMeterCore
import CryptoKit

struct CodexResumeNotificationLedger: Codable, Equatable {
    struct Event: Codable, Equatable {
        let key: String
        let kind: String
        let createdAt: Date
    }
    var events: [Event] = []
    var delivered: Set<String> = []

    mutating func enqueue(candidateID: String, kind: String, now: Date) {
        guard kind != "attention" else { return }
        let key = candidateID + ":" + kind
        guard !delivered.contains(key), !events.contains(where: { $0.key == key }) else { return }
        events.append(.init(key: key, kind: kind, createdAt: now))
    }

    func due(at now: Date) -> [String: [Event]] {
        Dictionary(grouping: events, by: \.kind).filter { _, group in
            group.map(\.createdAt).min().map { now.timeIntervalSince($0) >= 10 } == true
        }
    }

    mutating func markDelivered(_ batch: [Event]) {
        let keys = Set(batch.map(\.key))
        delivered.formUnion(keys)
        events.removeAll { keys.contains($0.key) }
    }
}

@MainActor
final class CodexResumeNotifications {
    var permissionDenied = false
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        permissionDenied = await center.notificationSettings().authorizationStatus == .denied
    }

    static func title(for kind: String) -> String? {
        switch kind {
        case "detected": return L10n.string("检测到 Codex 额度中断")
        case "resumed": return L10n.string("Codex 恢复已确认")
        case "observed": return L10n.string("已观察到 Codex 继续运行")
        default: return nil
        }
    }

    func deliver(kind: String, events: [CodexResumeNotificationLedger.Event]) async throws {
        // Silently consume legacy attention events so the coordinator can checkpoint them.
        guard let title = Self.title(for: kind) else { return }
        let settings = await center.notificationSettings()
        permissionDenied = settings.authorizationStatus == .denied
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = L10n.format("%d 个会话有更新，点击查看恢复列表。", events.count)
        content.sound = .default
        content.userInfo = ["codexResume": true]
        let digest = SHA256.hash(data: Data(events.map(\.key).sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let identifier = "agentmeter.codex.resume." + digest
        // Stable batch IDs allow a crash between delivery and checkpointing without a second alert.
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == identifier }) { return }
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
