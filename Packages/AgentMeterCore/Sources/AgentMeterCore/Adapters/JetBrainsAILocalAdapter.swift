#if os(macOS)
import Foundation

public struct JetBrainsAILocalAdapter: Sendable {
    public static let source = "jetbrains_ai_local_xml"
    public enum FetchError: Error, Equatable { case notFound, unreadable, decode }

    public init() {}

    public func fetch(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> QuotaSnapshot {
        guard let candidate = Self.candidates(home: home).max(by: { $0.modified < $1.modified }) else {
            throw FetchError.notFound
        }
        guard let data = try? Data(contentsOf: candidate.url) else { throw FetchError.unreadable }
        return try parse(data: data, plan: candidate.name, updatedAt: candidate.modified)
    }

    public func parse(data: Data, plan: String?, updatedAt: Date) throws -> QuotaSnapshot {
        let delegate = AttributeCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw FetchError.decode }
        guard let quotaRaw = delegate.values["quotaInfo"],
              let quotaData = Self.decodeEntities(quotaRaw).data(using: .utf8),
              let quota = try? JSONSerialization.jsonObject(with: quotaData) as? [String: Any] else {
            throw FetchError.decode
        }
        let maximum = Self.number(quota, path: ["maximum"])
        let current = Self.number(quota, path: ["current"])
        let available = Self.number(quota, path: ["tariffQuota", "available"])
        let used: Double?
        if let maximum, maximum > 0, let current, current >= 0, current <= maximum {
            used = current / maximum * 100
        } else if let maximum, maximum > 0, let available, available >= 0 {
            used = 100 - available / maximum * 100
        } else {
            used = nil
        }
        guard let used, used.isFinite else { throw FetchError.decode }
        var reset: Date?
        if let refillRaw = delegate.values["nextRefill"],
           let refillData = Self.decodeEntities(refillRaw).data(using: .utf8),
           let refill = try? JSONSerialization.jsonObject(with: refillData) as? [String: Any],
           let next = Self.value(refill, path: ["next"]) as? String {
            reset = ISO8601DateFormatter().date(from: next)
        }
        return QuotaSnapshot(tool: .jetBrainsAI, plan: plan, windows: [
            .init(usedPercent: used, resetsAt: reset, kind: .monthly),
        ], confidence: .fresh, source: Self.source, updatedAt: updatedAt)
    }

    private struct Candidate { let url: URL; let modified: Date; let name: String }

    private static func candidates(home: URL) -> [Candidate] {
        let roots = [
            home.appendingPathComponent("Library/Application Support/JetBrains"),
            home.appendingPathComponent("Library/Application Support/Google"),
        ]
        var result: [Candidate] = []
        let manager = FileManager.default
        for root in roots {
            guard let directories = try? manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for directory in directories {
                let file = directory.appendingPathComponent("options/AIAssistantQuotaManager2.xml")
                guard manager.fileExists(atPath: file.path) else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                result.append(Candidate(url: file, modified: modified, name: directory.lastPathComponent))
            }
        }
        return result
    }

    private final class AttributeCollector: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            for key in ["quotaInfo", "nextRefill"] where values[key] == nil {
                if let value = attributeDict[key] { values[key] = value }
                if attributeDict["name"] == key, let value = attributeDict["value"] { values[key] = value }
            }
        }
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
    private static func value(_ root: [String: Any], path: [String]) -> Any? {
        var current: Any = root
        for part in path {
            guard let dict = current as? [String: Any], let next = dict[part] else { return nil }
            current = next
        }
        return current
    }
    private static func number(_ root: [String: Any], path: [String]) -> Double? {
        if let number = value(root, path: path) as? NSNumber { return number.doubleValue }
        if let text = value(root, path: path) as? String { return Double(text) }
        return nil
    }
}
#endif
