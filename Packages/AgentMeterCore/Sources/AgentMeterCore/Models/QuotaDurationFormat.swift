import Foundation

public enum QuotaDurationFormat {
    public static func short(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        if days > 0 {
            let hours = (total % 86_400) / 3_600
            return "\(days)d\(hours)h"
        }

        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    public static func short(until date: Date, now: Date = Date()) -> String {
        short(seconds: date.timeIntervalSince(now))
    }
}
