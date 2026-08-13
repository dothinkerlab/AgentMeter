import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import SQLite3
#endif
import Testing
@testable import AgentMeterCore

@Test func cursorPlanPrefersExplicitPercentageAndClampsOverage() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let data = Data(#"{"billingCycleEnd":"2000000000000","planUsage":{"totalPercentUsed":135,"limit":1000,"remaining":900}}"#.utf8)
    let snapshot = try CursorPlanAdapter().parseUsage(data: data, plan: "Pro", now: now)
    #expect(snapshot.tool == .cursor)
    #expect(snapshot.plan == "Pro")
    #expect(snapshot.window(.monthly)?.usedPercent == 100)
    #expect(snapshot.window(.monthly)?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
}

@Test func cursorPlanFallsBackToLimitFactsAndRejectsInvalidUsage() throws {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let valid = Data(#"{"billingCycleEnd":"2000000000000","planUsage":{"limit":40000,"remaining":16778}}"#.utf8)
    let snapshot = try CursorPlanAdapter().parseUsage(data: valid, now: now)
    #expect(abs((snapshot.window(.monthly)?.usedPercent ?? 0) - 58.055) < 0.0001)

    for body in [
        #"{"billingCycleEnd":"2000000000000","planUsage":{"totalPercentUsed":-1}}"#,
        #"{"billingCycleEnd":"1800000000000","planUsage":{"totalPercentUsed":10}}"#,
        #"{"billingCycleEnd":"2000000000000","planUsage":{}}"#,
    ] {
        #expect(throws: CursorPlanAdapter.FetchError.self) {
            try CursorPlanAdapter().parseUsage(data: Data(body.utf8), now: now)
        }
    }
}

@Test func cursorPlanKeepsUsageFreshWhenOptionalPlanInfoFails() async throws {
    let usage = Data(#"{"billingCycleEnd":"2000000000000","planUsage":{"totalPercentUsed":25}}"#.utf8)
    let transport = CursorTestTransport([
        .init(status: 200, data: usage),
        .init(status: 500, data: Data()),
    ])
    let value = try await CursorPlanAdapter().fetch(
        accessToken: "cursor-token",
        fallbackPlan: "cached-pro",
        transport: transport,
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )
    #expect(value.confidence == .fresh)
    #expect(value.plan == "cached-pro")
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer cursor-token")
    #expect(requests[0].value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
}

@Test func cursorPlanMapsHTTPAndNetworkFailures() async {
    let unauthorized = CursorTestTransport([.init(status: 401, data: Data())])
    await #expect(throws: CursorPlanAdapter.FetchError.unauthorized) {
        try await CursorPlanAdapter().fetch(accessToken: "bad", transport: unauthorized)
    }
    await #expect(throws: CursorPlanAdapter.FetchError.self) {
        try await CursorPlanAdapter().fetch(accessToken: "token", transport: FailingCursorTransport())
    }
    #expect(CursorPlanAdapter.staleReason(for: CursorPlanAdapter.FetchError.httpStatus(500)) == .endpointFailure)
    #expect(CursorPlanAdapter.staleReason(for: CursorPlanAdapter.FetchError.decode("x")) == .responseChanged)
}

@Test func cursorTeamPaginatesSortsAndPreservesDecimalCents() async throws {
    let first = Data(#"{"teamMemberSpend":[{"spendCents":10.125,"includedSpendCents":20.375,"name":"Zed","email":"zed@example.com","role":"member","totalPercentUsed":25}],"subscriptionCycleStart":1800000000000,"totalMembers":2,"totalPages":2}"#.utf8)
    let second = Data(#"{"teamMemberSpend":[{"spendCents":"5.005","includedSpendCents":"100.995","name":"Ada","email":"ada@example.com","role":"owner"}],"subscriptionCycleStart":"1800000000000","totalMembers":2,"totalPages":2}"#.utf8)
    let transport = CursorTestTransport([
        .init(status: 200, data: first),
        .init(status: 200, data: second),
    ])
    let value = try await CursorTeamUsageAdapter().fetch(
        adminKey: "key_admin",
        transport: transport,
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )
    #expect(value.members.map(\.email) == ["ada@example.com", "zed@example.com"])
    #expect(value.includedSpendCents == Decimal(string: "121.370"))
    #expect(value.onDemandSpendCents == Decimal(string: "15.130"))
    let requests = await transport.requests
    #expect(requests.count == 2)
    let expected = "Basic " + Data("key_admin:".utf8).base64EncodedString()
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == expected)
    let body = try #require(requests[1].httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["page"] as? Int == 2)
    #expect(json["pageSize"] as? Int == 100)
}

@Test func cursorTeamRejectsDuplicateMembersAndChangingPagination() async {
    let duplicate = Data(#"{"teamMemberSpend":[{"spendCents":1,"name":"A","email":"a@example.com","role":"member"},{"spendCents":2,"name":"A","email":"A@example.com","role":"member"}],"subscriptionCycleStart":1800000000000,"totalMembers":2,"totalPages":1}"#.utf8)
    let transport = CursorTestTransport([.init(status: 200, data: duplicate)])
    await #expect(throws: CursorTeamUsageAdapter.FetchError.self) {
        try await CursorTeamUsageAdapter().fetch(
            adminKey: "key", transport: transport,
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }

    let excessivePages = Data(#"{"teamMemberSpend":[],"subscriptionCycleStart":1800000000000,"totalMembers":0,"totalPages":101}"#.utf8)
    await #expect(throws: CursorTeamUsageAdapter.FetchError.self) {
        try await CursorTeamUsageAdapter().fetch(
            adminKey: "key",
            transport: CursorTestTransport([.init(status: 200, data: excessivePages)]),
            now: Date(timeIntervalSince1970: 1_900_000_000)
        )
    }

    await #expect(throws: CursorTeamUsageAdapter.FetchError.unauthorized) {
        try await CursorTeamUsageAdapter().fetch(
            adminKey: "bad",
            transport: CursorTestTransport([.init(status: 403, data: Data())])
        )
    }
}

@Test func cursorTeamOldSchemaFallsBackToOnDemandSortingAndNoIncludedTotal() async throws {
    let data = Data(#"{"teamMemberSpend":[{"spendCents":50,"includedSpendCents":1000,"name":"Ada","email":"ada@example.com","role":"owner"},{"spendCents":100,"name":"Zed","email":"zed@example.com","role":"member"}],"subscriptionCycleStart":1800000000000,"totalMembers":2,"totalPages":1}"#.utf8)
    let value = try await CursorTeamUsageAdapter().fetch(
        adminKey: "key",
        transport: CursorTestTransport([.init(status: 200, data: data)]),
        now: Date(timeIntervalSince1970: 1_900_000_000)
    )
    #expect(value.members.map(\.email) == ["zed@example.com", "ada@example.com"])
    #expect(value.includedSpendCents == nil)
    #expect(value.onDemandSpendCents == 150)
}

@Test func cursorTeamRequestGateRejectsSupersededResults() {
    var gate = CursorTeamRequestGate()
    let first = gate.begin()
    let second = gate.begin()
    #expect(!gate.isCurrent(first))
    #expect(gate.isCurrent(second))
}

@Test func cursorTeamDegradationNeverInventsKnownZero() {
    let unknown = CursorTeamUsage.degraded(from: nil, reason: .networkFailure)
    #expect(unknown.confidence == .unknown)
    #expect(!unknown.hasKnownUsage)
    #expect(unknown.members.isEmpty)

    let fresh = CursorTeamUsage(
        members: [], totalMembers: 3,
        subscriptionCycleStart: Date(timeIntervalSince1970: 1_800_000_000),
        includedSpendCents: 20, onDemandSpendCents: 5,
        confidence: .fresh, source: "test", updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
    )
    let stale = CursorTeamUsage.degraded(from: fresh, reason: .networkFailure)
    #expect(stale.confidence == .stale)
    #expect(stale.totalMembers == 3)
    #expect(stale.updatedAt == fresh.updatedAt)
}

#if os(macOS)
@Test func cursorStateReaderReadsJSONStringsWithoutModifyingDatabase() throws {
    try withCursorDatabase { url, database in
        try execute(#"INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','"jwt-token"');"#, on: database)
        try execute(#"INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType','"pro"');"#, on: database)
        let before = try Data(contentsOf: url)
        let modifiedBefore = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        let state = try KeychainReader.readCursorState(url: url)
        let after = try Data(contentsOf: url)
        let modifiedAfter = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        #expect(state.credentials.accessToken == "jwt-token")
        #expect(state.plan == "pro")
        #expect(before == after)
        #expect(modifiedBefore == modifiedAfter)
    }
}

@Test func cursorStateReaderReadsPlainValuesAndRejectsMissingToken() throws {
    try withCursorDatabase { url, database in
        try execute("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','plain-token')", on: database)
        let state = try KeychainReader.readCursorState(url: url)
        #expect(state.credentials.accessToken == "plain-token")
        #expect(state.plan == nil)
    }
    try withCursorDatabase { url, _ in
        #expect(throws: KeychainReader.ReadError.self) {
            try KeychainReader.readCursorState(url: url)
        }
    }
}

@Test func cursorStateReaderHandlesMissingAndCorruptDatabases() throws {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-cursor-\(UUID().uuidString).db")
    #expect(throws: KeychainReader.ReadError.self) {
        try KeychainReader.readCursorState(url: missing)
    }

    let corrupt = FileManager.default.temporaryDirectory
        .appendingPathComponent("corrupt-cursor-\(UUID().uuidString).db")
    try Data("not sqlite".utf8).write(to: corrupt)
    defer { try? FileManager.default.removeItem(at: corrupt) }
    #expect(throws: KeychainReader.ReadError.self) {
        try KeychainReader.readCursorState(url: corrupt)
    }
}

@Test func cursorStateReaderFailsCleanlyWhenDatabaseIsExclusivelyLocked() throws {
    try withCursorDatabase { url, database in
        try execute("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','token')", on: database)
        try execute("BEGIN EXCLUSIVE", on: database)
        defer { try? execute("ROLLBACK", on: database) }
        #expect(throws: KeychainReader.ReadError.self) {
            try KeychainReader.readCursorState(url: url)
        }
    }
}

private func withCursorDatabase(
    _ body: (URL, OpaquePointer) throws -> Void
) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cursor-state-\(UUID().uuidString).db")
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw CocoaError(.fileWriteUnknown)
    }
    do {
        try execute("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", on: database)
        try body(url, database)
        sqlite3_close(database)
    } catch {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: url)
        throw error
    }
    try? FileManager.default.removeItem(at: url)
}

private func execute(_ sql: String, on database: OpaquePointer) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteUnknown)
    }
}
#endif

private actor CursorTestTransport: APICostHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let data: Data
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let response = responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: nil, headerFields: nil
        )!
        return (response.data, http)
    }
}

private actor FailingCursorTransport: APICostHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
