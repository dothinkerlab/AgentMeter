import Foundation

/// iPhone App ↔ iPhone Widget、Watch App ↔ Watch Widget 的设备内 App Group 缓存。
/// iPhone 与 Watch 的文件系统彼此独立，跨设备传输由 WatchConnectivity 完成。
public struct LocalBillingCache: Sendable {
    public static let appGroupIdentifier = "group.com.dothinker.app.agentmeter.localmetrics"
    public static let storageKey = "localBillingSnapshot.v1"

    public enum CacheError: Error, Equatable {
        case suiteUnavailable
        case encodeFailed
        case decodeFailed
        case unsupportedSchema(Int)
    }

    private let suiteName: String
    private let storageKey: String

    public init(
        suiteName: String = Self.appGroupIdentifier,
        storageKey: String = Self.storageKey
    ) {
        self.suiteName = suiteName
        self.storageKey = storageKey
    }

    public func load() throws -> LocalBillingSnapshotBundle {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CacheError.suiteUnavailable
        }
        guard let data = defaults.data(forKey: storageKey) else {
            return LocalBillingSnapshotBundle()
        }
        let bundle: LocalBillingSnapshotBundle
        do {
            bundle = try JSONDecoder().decode(LocalBillingSnapshotBundle.self, from: data)
        } catch {
            throw CacheError.decodeFailed
        }
        switch bundle.schemaVersion {
        case LocalBillingSnapshotBundle.currentSchemaVersion:
            return bundle
        case 1, 2:
            // v1 had the original three fields; v2 added Kimi API. Return an
            // in-memory v3 value; the next publish persists the migration.
            return LocalBillingSnapshotBundle(
                deepSeek: bundle.deepSeek,
                openRouter: bundle.openRouter,
                xAI: bundle.xAI,
                kimiAPI: bundle.schemaVersion >= 2 ? bundle.kimiAPI : nil,
                openAIAPI: nil,
                anthropicAPI: nil
            )
        default:
            throw CacheError.unsupportedSchema(bundle.schemaVersion)
        }
    }

    public func save(_ bundle: LocalBillingSnapshotBundle) throws {
        guard bundle.schemaVersion == LocalBillingSnapshotBundle.currentSchemaVersion else {
            throw CacheError.unsupportedSchema(bundle.schemaVersion)
        }
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CacheError.suiteUnavailable
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(bundle)
        } catch {
            throw CacheError.encodeFailed
        }
        defaults.set(data, forKey: storageKey)
    }

    public func removeAll() throws {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CacheError.suiteUnavailable
        }
        defaults.removeObject(forKey: storageKey)
    }

    public static func encodeForTransfer(_ bundle: LocalBillingSnapshotBundle) throws -> Data {
        do {
            return try JSONEncoder().encode(bundle)
        } catch {
            throw CacheError.encodeFailed
        }
    }

    public static func decodeTransferred(_ data: Data) throws -> LocalBillingSnapshotBundle {
        let bundle: LocalBillingSnapshotBundle
        do {
            bundle = try JSONDecoder().decode(LocalBillingSnapshotBundle.self, from: data)
        } catch {
            throw CacheError.decodeFailed
        }
        switch bundle.schemaVersion {
        case LocalBillingSnapshotBundle.currentSchemaVersion:
            return bundle
        case 1, 2:
            return LocalBillingSnapshotBundle(
                deepSeek: bundle.deepSeek, openRouter: bundle.openRouter,
                xAI: bundle.xAI,
                kimiAPI: bundle.schemaVersion >= 2 ? bundle.kimiAPI : nil,
                openAIAPI: nil,
                anthropicAPI: nil
            )
        default:
            throw CacheError.unsupportedSchema(bundle.schemaVersion)
        }
    }
}
