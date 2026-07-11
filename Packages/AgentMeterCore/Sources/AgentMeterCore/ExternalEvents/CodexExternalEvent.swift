import Foundation

public enum ExternalResetEventKind: String, Codable, Sendable, Equatable {
    case resetAnnouncement = "RESET_ANNOUNCEMENT"
    case limitNotice = "LIMIT_NOTICE"
    case discussion = "DISCUSSION"
    case other = "OTHER"
}

public enum ExternalEventConfidence: String, Codable, Sendable, Equatable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

public enum ExternalEventVerificationStatus: String, Codable, Sendable, Equatable {
    case pendingLocalCollection
    case confirmedByLocalCollection
    case expiredUnverified

    public static func resolve(
        event: ExternalResetEvent,
        snapshots: [QuotaSnapshot],
        now: Date = Date()
    ) -> ExternalEventVerificationStatus {
        guard event.kind == .resetAnnouncement else {
            return .pendingLocalCollection
        }

        guard now.timeIntervalSince(event.detectedAt) <= 24 * 60 * 60 else {
            return .expiredUnverified
        }

        guard let snapshot = snapshots.first(where: { $0.tool == event.tool }),
              snapshot.updatedAt > event.detectedAt,
              snapshot.confidence == .fresh else {
            return .pendingLocalCollection
        }

        let primaryWindows = [snapshot.window(.fiveHour), snapshot.window(.sevenDay)].compactMap { $0 }
        let bestRemaining = primaryWindows.map(\.remainingPercent).max()
            ?? snapshot.tightestWindow?.remainingPercent
            ?? 0
        return bestRemaining >= 80 ? .confirmedByLocalCollection : .pendingLocalCollection
    }
}

public struct ExternalResetEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let tool: ToolKind
    public let source: String
    public let kind: ExternalResetEventKind
    public let confidence: ExternalEventConfidence
    public let postID: String?
    public let postURL: URL?
    public let postText: String?
    public let matchedKeywords: [String]
    public let createdAt: Date?
    public let detectedAt: Date
    public let pushedAt: Date?

    public init(
        id: String,
        tool: ToolKind,
        source: String,
        kind: ExternalResetEventKind,
        confidence: ExternalEventConfidence,
        postID: String?,
        postURL: URL?,
        postText: String?,
        matchedKeywords: [String],
        createdAt: Date?,
        detectedAt: Date,
        pushedAt: Date?
    ) {
        self.id = id
        self.tool = tool
        self.source = source
        self.kind = kind
        self.confidence = confidence
        self.postID = postID
        self.postURL = postURL
        self.postText = postText
        self.matchedKeywords = matchedKeywords
        self.createdAt = createdAt
        self.detectedAt = detectedAt
        self.pushedAt = pushedAt
    }
}

public struct ExternalResetEventsResponse: Codable, Sendable, Equatable {
    public let events: [ExternalResetEvent]
}
