import Foundation
import Testing
@testable import AgentMeterCore

@Test func localBillingDisplaySnapshotsExcludeProviderMetadata() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let usage = OpenRouterUsage(
        keyLabel: "secret-ish-label", usage: 12, usageDaily: 1, usageWeekly: 4, usageMonthly: 9,
        byokUsage: 3, byokUsageDaily: 0.1, byokUsageWeekly: 0.5, byokUsageMonthly: 2,
        limit: 100, limitRemaining: 91, limitReset: "monthly", includeBYOKInLimit: false,
        expiresAt: nil, confidence: .fresh, source: "provider-source", updatedAt: now
    )
    let bundle = LocalBillingSnapshotBundle(openRouter: OpenRouterDisplaySnapshot(usage))
    let data = try LocalBillingCache.encodeForTransfer(bundle)
    let json = String(decoding: data, as: UTF8.self)

    #expect(!json.contains("secret-ish-label"))
    #expect(!json.contains("provider-source"))
    #expect(try LocalBillingCache.decodeTransferred(data) == bundle)
}

@Test func localBillingCacheRoundTripsAndRejectsUnknownSchema() throws {
    let suite = "AgentMeterCoreTests.LocalBilling.\(UUID().uuidString)"
    let cache = LocalBillingCache(suiteName: suite)
    defer { try? cache.removeAll() }

    let balance = DeepSeekBalance(
        isAvailable: true, currency: "CNY", totalBalance: "10.0000000000001",
        grantedBalance: "1.25", toppedUpBalance: "8.7500000000001",
        confidence: .fresh, source: "test", updatedAt: Date(timeIntervalSince1970: 100)
    )
    let bundle = LocalBillingSnapshotBundle(deepSeek: DeepSeekDisplaySnapshot(balance))
    try cache.save(bundle)
    #expect(try cache.load() == bundle)
    #expect(try cache.load().deepSeek?.totalBalance == "10.0000000000001")

    let unsupported = LocalBillingSnapshotBundle(schemaVersion: 99)
    #expect(throws: LocalBillingCache.CacheError.unsupportedSchema(99)) {
        try cache.save(unsupported)
    }
}

@Test func transferredLocalBillingRejectsUnknownSchema() throws {
    let data = try JSONEncoder().encode(LocalBillingSnapshotBundle(schemaVersion: 99))
    #expect(throws: LocalBillingCache.CacheError.unsupportedSchema(99)) {
        try LocalBillingCache.decodeTransferred(data)
    }
}

@Test func localBillingMigratesV1AndV2ToV3() throws {
    let legacy = LocalBillingSnapshotBundle(schemaVersion: 1)
    let migrated = try LocalBillingCache.decodeTransferred(JSONEncoder().encode(legacy))
    #expect(migrated.schemaVersion == 3)
    #expect(migrated.kimiAPI == nil)
    #expect(migrated.openAIAPI == nil)
    #expect(migrated.anthropicAPI == nil)

    let v2 = LocalBillingSnapshotBundle(schemaVersion: 2)
    let migratedV2 = try LocalBillingCache.decodeTransferred(JSONEncoder().encode(v2))
    #expect(migratedV2.schemaVersion == 3)
}

@Test func apiCostDisplayBundleContainsFactsButNoCredentialOrSource() throws {
    let usage = APICostUsage(
        usageDaily: 1.25, usageWeekly: 4.5, usageMonthly: 8.75,
        confidence: .fresh, source: "secret-provider-source", updatedAt: Date(timeIntervalSince1970: 100)
    )
    let bundle = LocalBillingSnapshotBundle(
        openAIAPI: APICostDisplaySnapshot(usage),
        anthropicAPI: APICostDisplaySnapshot(usage)
    )
    let json = String(decoding: try LocalBillingCache.encodeForTransfer(bundle), as: UTF8.self)
    #expect(!json.contains("secret-provider-source"))
    #expect(!json.lowercased().contains("admin-key"))
    #expect(bundle.contains(.openAIAPI))
    #expect(bundle.contains(.anthropicAPI))
}

@Test func unknownKimiAPIBalanceNeverClaimsAZeroValueIsKnown() {
    let firstFailure = KimiAPIBalance.degraded(
        from: nil, region: .global, reason: .networkFailure
    )
    let secondFailure = KimiAPIBalance.degraded(
        from: firstFailure, region: .global, reason: .endpointFailure
    )
    #expect(firstFailure.confidence == .unknown)
    #expect(secondFailure.confidence == .unknown)
    #expect(!secondFailure.hasKnownValue)
    #expect(secondFailure.availableBalance == 0)
    #expect(secondFailure.updatedAt == firstFailure.updatedAt)

    let display = KimiAPIDisplaySnapshot(secondFailure)
    #expect(display.confidence == .unknown)
    #expect(!display.hasKnownValue)
}
