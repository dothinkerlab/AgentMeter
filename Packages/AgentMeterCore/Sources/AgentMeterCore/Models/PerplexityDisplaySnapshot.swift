import Foundation

/// Only display facts are serializable; sessions, profile IDs and raw payloads cannot be represented.
public struct PerplexityDisplaySnapshot: Codable, Sendable, Equatable {
    public let credits: PerplexityCredits?
    public let updatedAt: Date?
    public let failure: PerplexityFailure?
    public var paused: Bool
    public var syncFailure: QuotaStaleReason?
    public var confidence: DataConfidence { credits == nil ? .unknown : (failure == nil ? .fresh : .stale) }
    public init(_ usage: PerplexityUsage = .init(), paused: Bool = false) {
        credits = usage.credits; updatedAt = usage.updatedAt; failure = usage.failure; self.paused = paused
    }
    private enum CodingKeys: String, CodingKey { case credits, updatedAt, failure, paused, syncFailure }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        credits = try values.decodeIfPresent(PerplexityCredits.self, forKey: .credits)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        failure = try values.decodeIfPresent(PerplexityFailure.self, forKey: .failure)
        paused = try values.decode(Bool.self, forKey: .paused)
        syncFailure = try values.decodeIfPresent(QuotaStaleReason.self, forKey: .syncFailure)
        try validate()
    }
    public func validate() throws {
        try credits?.validate()
        guard credits == nil || updatedAt != nil,
              updatedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw PerplexityFailure.responseChanged }
    }
    public func isStale(now: Date = Date()) -> Bool {
        paused || syncFailure != nil || confidence != .fresh || updatedAt.map { now.timeIntervalSince($0) > 900 } != false
    }
    public var needsMacLogin: Bool { [.missingCookie, .invalidCookie, .authExpired].contains(failure) }
    public var statusKey: String {
        if paused { return "Mac 已暂停 Perplexity 采集" }
        if failure == .challenge { return "请在 Mac 完成浏览器验证" }
        if needsMacLogin { return "请在 Mac 重新登录 Perplexity" }
        if syncFailure != nil { return "Perplexity 同步失败，保留上次数据" }
        if isStale() { return "Perplexity 数据陈旧，请检查 Mac 采集状态" }
        return "来自 Mac"
    }
    public func markedSyncFailed(_ reason: QuotaStaleReason) -> Self {
        var value = self; value.syncFailure = reason; return value
    }
}

public struct PerplexitySyncEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let revision: Date
    public let snapshot: PerplexityDisplaySnapshot?
    public init(snapshot: PerplexityDisplaySnapshot?, revision: Date = Date()) {
        schemaVersion = 1; self.revision = revision; self.snapshot = snapshot
    }
}
