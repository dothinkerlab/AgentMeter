import Foundation
import CloudKit

public protocol TypeSafeSyncStore: Sendable {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> TypeSafeSyncEnvelope?
    func save(_ envelope: TypeSafeSyncEnvelope) async throws
    func disable(revision: Date) async throws
}

public extension TypeSafeSyncStore {
    func disable(revision: Date = Date()) async throws {
        try await save(TypeSafeSyncEnvelope(snapshot: nil, revision: revision))
    }
}

public enum TypeSafeSyncError: Error, Equatable, Sendable { case accountUnavailable, responseChanged, network }

public enum TypeSafeRecordMapping {
    public static let recordType = "TypeSafeDisplaySnapshot"
    public static let recordID = CKRecord.ID(recordName: "billing-typesafe-mac")
    public static func apply(_ value: TypeSafeSyncEnvelope, to record: CKRecord) throws {
        guard value.schemaVersion == 1 else { throw TypeSafeSyncError.responseChanged }
        try value.snapshot?.validate()
        record["payloadJSON"] = String(decoding: try JSONEncoder().encode(value), as: UTF8.self) as CKRecordValue
        record["revision"] = value.revision as CKRecordValue
    }
    public static func shouldReplace(_ existing: TypeSafeSyncEnvelope, with next: TypeSafeSyncEnvelope) -> Bool {
        next.revision >= existing.revision
    }
    public static func decode(_ record: CKRecord) throws -> TypeSafeSyncEnvelope {
        guard record.recordType == recordType, let text = record["payloadJSON"] as? String, text.utf8.count <= 1_048_576,
              let value = try? JSONDecoder().decode(TypeSafeSyncEnvelope.self, from: Data(text.utf8)),
              value.schemaVersion == 1 else { throw TypeSafeSyncError.responseChanged }
        return value
    }
}

public struct CloudKitTypeSafeSyncStore: TypeSafeSyncStore {
    public let containerIdentifier: String
    public init(containerIdentifier: String = CloudKitSync.defaultContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }
    private var container: CKContainer { CKContainer(identifier: containerIdentifier) }
    public func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw TypeSafeSyncError.accountUnavailable }
        return try await container.userRecordID().recordName
    }
    public func fetch() async throws -> TypeSafeSyncEnvelope? {
        do {
            return try TypeSafeRecordMapping.decode(await container.privateCloudDatabase.record(for: TypeSafeRecordMapping.recordID))
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }
    public func save(_ envelope: TypeSafeSyncEnvelope) async throws {
        let database = container.privateCloudDatabase
        var record = CKRecord(recordType: TypeSafeRecordMapping.recordType, recordID: TypeSafeRecordMapping.recordID)
        // Compare revisions on each conflict. A delayed upload can never resurrect a newer tombstone.
        for _ in 0..<4 {
            if let existing = try? TypeSafeRecordMapping.decode(record), !TypeSafeRecordMapping.shouldReplace(existing, with: envelope) { return }
            try TypeSafeRecordMapping.apply(envelope, to: record)
            do { _ = try await database.save(record); return }
            catch let error as CKError where error.code == .serverRecordChanged {
                record = try await database.record(for: TypeSafeRecordMapping.recordID)
            }
        }
        throw TypeSafeSyncError.network
    }
}
