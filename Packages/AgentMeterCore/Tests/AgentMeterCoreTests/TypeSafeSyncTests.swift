import Foundation
import CloudKit
import Testing
@testable import AgentMeterCore

private let jevDate = Date(timeIntervalSince1970: 1_800_000_000)
private func jevFixture() -> TypeSafeDisplaySnapshot {
    TypeSafeDisplaySnapshot(.init(billing: .init(value: .init(
        balance: Decimal(string: "987.654321")!, spent: Decimal(string: "0.123456")!,
        cycleLabel: "cycle", plan: "plan", credits: [
            .init(amount: 20, remaining: 12, expiresAt: jevDate.addingTimeInterval(100)),
            .init(amount: 10, remaining: 5, expiresAt: jevDate.addingTimeInterval(-1))
        ]), updatedAt: jevDate), tokens: .init(failure: .challenge)))
}

@Test func jevDisplayRoundTripPreservesPrecisionAndIndependentStatus() throws {
    let value = jevFixture()
    let envelope = TypeSafeSyncEnvelope(snapshot: value, revision: jevDate)
    let record = CKRecord(recordType: TypeSafeRecordMapping.recordType, recordID: TypeSafeRecordMapping.recordID)
    try TypeSafeRecordMapping.apply(envelope, to: record)
    #expect(try TypeSafeRecordMapping.decode(record) == envelope)
    #expect(value.billing.value?.balance == Decimal(string: "987.654321"))
    #expect(!value.billingIsStale(now: jevDate))
    #expect(value.tokensAreStale(now: jevDate))
    #expect(value.needsMacVerification)
    #expect(value.activeCredits(now: jevDate).count == 1)
    #expect(value.billingIsStale(now: jevDate.addingTimeInterval(901)))
    let failed = value.markedSyncFailed(.networkFailure)
    #expect(failed.billing.updatedAt == jevDate)
    #expect(failed.billing.value == value.billing.value)
    #expect(failed.billingIsStale(now: jevDate))
}

@Test func jevDisplayBundleIsAdditiveAndDoesNotContainSessionMaterial() throws {
    let value = jevFixture()
    let bundle = LocalBillingSnapshotBundle(typesafe: value)
    #expect(!bundle.isEmpty)
    #expect(bundle.contains(.typesafe))
    let data = try LocalBillingCache.encodeForTransfer(bundle)
    #expect(try LocalBillingCache.decodeTransferred(data) == bundle)
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in ["cookie", "Cookie", "profileID", "chrome", "rawResponse", "accessToken"] {
        #expect(!text.contains(forbidden))
    }
    struct OldV3: Decodable { let schemaVersion: Int; let deepSeek: DeepSeekDisplaySnapshot? }
    #expect(try JSONDecoder().decode(OldV3.self, from: data).schemaVersion == 3)
    let old = Data(#"{"schemaVersion":3}"#.utf8)
    #expect(try LocalBillingCache.decodeTransferred(old).typesafe == nil)
}

@Test func jevTombstoneUnknownAndPauseRemainDistinct() throws {
    let unknown = TypeSafeDisplaySnapshot()
    #expect(unknown.billing.value == nil)
    #expect(unknown.billingIsStale(now: jevDate))
    var paused = jevFixture(); paused.paused = true
    #expect(paused.billingIsStale(now: jevDate))
    let disabled = TypeSafeSyncEnvelope(snapshot: nil, revision: jevDate)
    let record = CKRecord(recordType: TypeSafeRecordMapping.recordType, recordID: TypeSafeRecordMapping.recordID)
    try TypeSafeRecordMapping.apply(disabled, to: record)
    #expect(try TypeSafeRecordMapping.decode(record).snapshot == nil)
    record["payloadJSON"] = #"{"schemaVersion":99,"revision":0}"# as CKRecordValue
    #expect(throws: TypeSafeSyncError.self) { try TypeSafeRecordMapping.decode(record) }
}


@Test func jevDelayedUploadCannotReplaceNewerTombstone() {
    let active = TypeSafeSyncEnvelope(snapshot: jevFixture(), revision: jevDate)
    let disabled = TypeSafeSyncEnvelope(snapshot: nil, revision: jevDate.addingTimeInterval(1))
    #expect(!TypeSafeRecordMapping.shouldReplace(disabled, with: active))
    #expect(TypeSafeRecordMapping.shouldReplace(active, with: disabled))
}

@Test func jevCorruptCountsAreRejectedBeforeDisplayAggregation() throws {
    let invalid = TypeSafeDisplaySnapshot(.init(tokens: .init(value: .init(todayTokens: 1, sevenDayTokens: 1,
        monthInputTokens: Int64.max, monthOutputTokens: 1, monthRequests: 1, earliestBucketAt: nil), updatedAt: jevDate)))
    let data = try JSONEncoder().encode(invalid)
    #expect(throws: TypeSafeSyncError.self) { try JSONDecoder().decode(TypeSafeDisplaySnapshot.self, from: data) }
}
