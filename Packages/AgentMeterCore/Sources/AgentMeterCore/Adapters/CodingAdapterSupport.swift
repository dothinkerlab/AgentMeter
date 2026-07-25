import Foundation
import CoreFoundation

enum CodingAdapterSupport {
    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func number(_ dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = number(dictionary[key]), value.isFinite { return value }
        }
        return nil
    }

    static func date(_ dictionary: [String: Any], keys: [String], now: Date) -> Date? {
        for key in keys {
            guard let raw = dictionary[key] else { continue }
            if let seconds = number(raw), seconds > 0 {
                if key.lowercased().contains("resetin") || key.lowercased().contains("reset_in") || key == "ttl" {
                    return now.addingTimeInterval(seconds)
                }
                let unix = seconds > 10_000_000_000 ? seconds / 1_000 : seconds
                return Date(timeIntervalSince1970: unix)
            }
            if let value = raw as? String {
                if let numeric = Double(value), numeric > 0 {
                    let unix = numeric > 10_000_000_000 ? numeric / 1_000 : numeric
                    return Date(timeIntervalSince1970: unix)
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let parsed = formatter.date(from: value) { return parsed }
                formatter.formatOptions = [.withInternetDateTime]
                if let parsed = formatter.date(from: value) { return parsed }
            }
        }
        return nil
    }

    static func usedPercent(used: Double?, remaining: Double?, limit: Double?) -> Double? {
        guard let limit, limit > 0 else { return nil }
        let usedValue = used ?? remaining.map { limit - $0 }
        guard let usedValue else { return nil }
        let percent = usedValue / limit * 100
        guard percent.isFinite, (0...100).contains(percent) else { return nil }
        return percent
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return root
    }
}
