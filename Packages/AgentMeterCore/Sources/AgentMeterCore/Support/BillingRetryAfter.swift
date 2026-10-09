import Foundation

public enum BillingRetryAfter {
    public static func parse(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.allSatisfy({ $0.isASCII && $0.isNumber }),
           let seconds = Double(value), seconds.isFinite,
           seconds <= Date.distantFuture.timeIntervalSince(now) {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(now, date)
    }
}
