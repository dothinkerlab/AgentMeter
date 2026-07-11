import Foundation

public enum SampleExternalResetEvents {
    public static func releaseScreenshots(now: Date = Date()) -> [ExternalResetEvent] {
        [
            ExternalResetEvent(
                id: "post.create:2075279141352706215",
                tool: .claudeCode,
                source: "x_timeline_poll",
                kind: .resetAnnouncement,
                confidence: .high,
                postID: "2075279141352706215",
                postURL: URL(string: "https://x.com/ClaudeDevs/status/2075279141352706215"),
                postText: "We've reset 5-hour and weekly rate limits for all users.",
                matchedKeywords: ["reset"],
                createdAt: now.addingTimeInterval(-8 * 60),
                detectedAt: now.addingTimeInterval(-7 * 60),
                pushedAt: now.addingTimeInterval(-7 * 60)
            ),
            ExternalResetEvent(
                id: "post.create:2075330198887940337",
                tool: .codex,
                source: "x_timeline_poll",
                kind: .resetAnnouncement,
                confidence: .high,
                postID: "2075330198887940337",
                postURL: URL(string: "https://x.com/thsottiaux/status/2075330198887940337"),
                postText: "Enjoy a full reset of your usage limits for ChatGPT Work and Codex.",
                matchedKeywords: ["codex", "reset"],
                createdAt: now.addingTimeInterval(-18 * 60),
                detectedAt: now.addingTimeInterval(-17 * 60),
                pushedAt: now.addingTimeInterval(-17 * 60)
            )
        ]
    }
}
