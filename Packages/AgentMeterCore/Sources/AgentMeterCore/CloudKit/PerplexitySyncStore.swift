import Foundation
import CloudKit

public protocol PerplexitySyncStore: Sendable {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> PerplexitySyncEnvelope?
    func save(_ envelope: PerplexitySyncEnvelope) async throws
    func disable(revision: Date) async throws
}

public extension PerplexitySyncStore {
    func disable(revision: Date = Date()) async throws {
        try await save(PerplexitySyncEnvelope(snapshot: nil, revision: revision))
    }
}

public enum PerplexitySyncError: Error, Equatable, Sendable { case accountUnavailable, responseChanged, network }

public enum PerplexityRecordMapping {
    public static let recordType = "PerplexityDisplaySnapshot"
    public static let recordID = CKRecord.ID(recordName: "credits-perplexity-mac")
    public static func apply(_ value: PerplexitySyncEnvelope, to record: CKRecord) throws {
        guard value.schemaVersion == 1 else { throw PerplexitySyncError.responseChanged }
        guard value.revision.timeIntervalSince1970.isFinite else { throw PerplexitySyncError.responseChanged }
        try value.snapshot?.validate()
        record["payloadJSON"] = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) as CKRecordValue
        record["revision"] = value.revision as CKRecordValue
    }
    public static func shouldReplace(_ existing: PerplexitySyncEnvelope, with next: PerplexitySyncEnvelope) -> Bool {
        next.revision >= existing.revision
    }
    public static func decode(_ record: CKRecord) throws -> PerplexitySyncEnvelope {
        guard record.recordType == recordType, let text = record["payloadJSON"] as? String, text.utf8.count <= 1_048_576,
              let value = try? JSONDecoder().decode(PerplexitySyncEnvelope.self, from: Data(text.utf8)),
              value.schemaVersion == 1, value.revision.timeIntervalSince1970.isFinite,
              (record["revision"] as? Date).map({ abs($0.timeIntervalSince(value.revision)) < 0.001 }) == true else { throw PerplexitySyncError.responseChanged }
        return value
    }
}

public struct CloudKitPerplexitySyncStore: PerplexitySyncStore {
    public let containerIdentifier: String
    public init(containerIdentifier: String = CloudKitSync.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }
    private var container: CKContainer { CKContainer(identifier: containerIdentifier) }
    public func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw PerplexitySyncError.accountUnavailable }
        return try await container.userRecordID().recordName
    }
    public func fetch() async throws -> PerplexitySyncEnvelope? {
        do {
            return try PerplexityRecordMapping.decode(await container.privateCloudDatabase.record(for: PerplexityRecordMapping.recordID))
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }
    public func save(_ envelope: PerplexitySyncEnvelope) async throws {
        let database = container.privateCloudDatabase
        var record: CKRecord
        do { record = try await database.record(for: PerplexityRecordMapping.recordID) }
        catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: PerplexityRecordMapping.recordType, recordID: PerplexityRecordMapping.recordID)
        }
        // Compare revisions on each conflict. A delayed upload can never resurrect a newer tombstone.
        for _ in 0..<4 {
            if record["payloadJSON"] != nil {
                let existing = try PerplexityRecordMapping.decode(record)
                if !PerplexityRecordMapping.shouldReplace(existing, with: envelope) { return }
            }
            try PerplexityRecordMapping.apply(envelope, to: record)
            do { _ = try await database.save(record); return }
            catch let error as CKError where error.code == .serverRecordChanged {
                record = try await database.record(for: PerplexityRecordMapping.recordID)
            }
        }
        throw PerplexitySyncError.network
    }
}
