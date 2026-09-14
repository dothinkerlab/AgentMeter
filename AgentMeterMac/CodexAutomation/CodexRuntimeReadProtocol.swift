import Foundation
import AgentMeterCore

enum CodexRuntimeProbeError: Error, Equatable {
    case invalidResponse, unexpectedResponse, serverRequest, serverError
    case homeMismatch, missingSocket, unsupportedHost, connectionClosed, timedOut, cancelled, outputLimit
}

struct CodexRuntimeQuotaSnapshot: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let usedPercent: Double
        let resetsAt: Double?
        let windowDurationMins: Int?
        func evidence(id: String) -> CodexResumeQuota.Window? {
            guard usedPercent.isFinite, (0...100).contains(usedPercent),
                  let resetsAt, resetsAt.isFinite, resetsAt > 0,
                  let duration = windowDurationMins, duration > 0 else { return nil }
            return .init(id: id, usedPercent: usedPercent, resetsAt: Date(timeIntervalSince1970: resetsAt))
        }
    }
    struct Bucket: Decodable, Sendable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
        let rateLimitReachedType: String?
        let spendControlReached: Bool?

        var blockingState: CodexResumeQuota.BlockingState {
            if spendControlReached == true { return .accountRestriction }
            switch rateLimitReachedType {
            case "rate_limit_reached": return .windowLimit
            case "workspace_owner_credits_depleted", "workspace_member_credits_depleted",
                 "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached": return .accountRestriction
            case nil: return spendControlReached == false ? .clear : .unknown
            default: return .unknown
            }
        }
    }
    let accountId: String?
    let rateLimits: Bucket
    let rateLimitsByLimitId: [String: Bucket]?

    var bucketCount: Int { rateLimitsByLimitId?.count ?? (rateLimits.limitId == nil ? 0 : 1) }

    /// Missing account/bucket/window evidence is never filled in from the display snapshot.
    func evidence(for limitID: String, at: Date) -> CodexResumeQuota? {
        guard let accountId, !accountId.isEmpty, !limitID.isEmpty else { return nil }
        let bucket: Bucket
        if let buckets = rateLimitsByLimitId {
            guard let selected = buckets[limitID], selected.limitId == nil || selected.limitId == limitID else { return nil }
            bucket = selected
        } else {
            guard rateLimits.limitId == limitID else { return nil }
            bucket = rateLimits
        }
        var windows: [CodexResumeQuota.Window] = []
        for (id, raw) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
            if let raw {
                guard let window = raw.evidence(id: id) else { return nil }
                windows.append(window)
            }
        }
        guard !windows.isEmpty else { return nil }
        return .init(accountID: accountId, limitID: limitID, observedAt: at, windows: windows, blockingState: bucket.blockingState)
    }
}

struct CodexRuntimeThreadSummary: Decodable, Sendable {
    struct Status: Decodable, Sendable { let type: String }
    let id: String
    let status: Status
    // Deliberately omit title/preview/items/transcript and avoid full-history hydration.
}

struct CodexRuntimeProbeResult: Sendable {
    let quota: CodexRuntimeQuotaSnapshot
    let thread: CodexRuntimeThreadSummary?
    /// This probe cannot attest ownership by the running Desktop or the last failed turn.
    var canAutomaticallyResume: Bool { false }
}

/// Finite read-only handshake. No general-purpose RPC sender or mutating methods are exposed.
struct CodexRuntimeReadProtocol {
    struct Update { var outgoing: [Data] = []; var result: CodexRuntimeProbeResult? }
    private struct Envelope: Decodable { let id: Int?; let method: String?; let error: RPCError? }
    private struct RPCError: Decodable { let code: Int }
    private struct Response<Value: Decodable>: Decodable { let result: Value }
    private struct Initialized: Decodable { let codexHome: String; let platformOs: String; let userAgent: String }
    private struct ThreadResponse: Decodable { let thread: CodexRuntimeThreadSummary }
    private let expectedHome: URL
    private let threadID: String?
    private var expectedID = 1
    private var quota: CodexRuntimeQuotaSnapshot?
    private var completed = false

    init(home: URL, threadID: String?) {
        expectedHome = home.standardizedFileURL.resolvingSymlinksInPath()
        self.threadID = threadID
    }

    func initialRequest() throws -> Data {
        try frame(["id": 1, "method": "initialize", "params": ["clientInfo": [
            "name": "agentmeter_read_probe", "title": "AgentMeter Read-only Probe", "version": "1"
        ]]])
    }

    mutating func receive(_ line: Data) throws -> Update {
        guard !completed else { throw CodexRuntimeProbeError.unexpectedResponse }
        let decoder = JSONDecoder()
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: line) }
        catch { throw CodexRuntimeProbeError.invalidResponse }
        if envelope.method != nil {
            guard envelope.id == nil, envelope.error == nil else { throw CodexRuntimeProbeError.serverRequest }
            return Update() // Ignore notifications; never answer approval or credential requests.
        }
        guard envelope.id == expectedID else { throw CodexRuntimeProbeError.unexpectedResponse }
        guard envelope.error == nil else { throw CodexRuntimeProbeError.serverError }
        do {
            switch expectedID {
            case 1:
                let hello = try decoder.decode(Response<Initialized>.self, from: line).result
                guard hello.codexHome.hasPrefix("/"), hello.platformOs == "macos",
                      URL(fileURLWithPath: hello.codexHome).standardizedFileURL.resolvingSymlinksInPath() == expectedHome else {
                    throw CodexRuntimeProbeError.homeMismatch
                }
                expectedID = 2
                return Update(outgoing: [try frame(["method": "initialized"]),
                    try frame(["id": 2, "method": "account/rateLimits/read"])])
            case 2:
                let snapshot = try decoder.decode(Response<CodexRuntimeQuotaSnapshot>.self, from: line).result
                quota = snapshot
                if let threadID, !threadID.isEmpty {
                    expectedID = 3
                    return Update(outgoing: [try frame(["id": 3, "method": "thread/read", "params": [
                        "threadId": threadID, "includeTurns": false
                    ]])])
                }
                completed = true
                return Update(result: .init(quota: snapshot, thread: nil))
            case 3:
                let thread = try decoder.decode(Response<ThreadResponse>.self, from: line).result.thread
                guard thread.id == threadID, let quota else { throw CodexRuntimeProbeError.unexpectedResponse }
                completed = true
                return Update(result: .init(quota: quota, thread: thread))
            default: throw CodexRuntimeProbeError.unexpectedResponse
            }
        } catch let error as CodexRuntimeProbeError { throw error }
        catch { throw CodexRuntimeProbeError.invalidResponse }
    }

    private func frame(_ value: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        data.append(10)
        return data
    }
}
