import Foundation
import SQLite3
import AgentMeterCore

struct CodexResumeAccountObservation: Codable, Equatable, Sendable {
    let accountID: String
    let observedAt: Date
    let fileModifiedAt: Date
}

/// Uses the running Desktop's queue CLI and local interruption evidence, not an app-server socket.
/// Local checks are not an atomic server-side idle/submit operation; every send remains single-shot.
@MainActor
final class CodexDesktopAutoResume {
    struct Prepared {
        let target: CodexQueueTarget
        let accountID: String
        let usage: CodexResumeUsage
        let index: CodexResumeThreadIndex
        let executable: URL
        let checkedAt: Date
    }
    enum Check { case blocked(CodexResumeBlock), waiting(Date?), ready(Prepared) }
    struct Blocked: Error { let reason: CodexResumeBlock }
    let home: URL
    private let host: @MainActor () throws -> URL
    private let fetchUsage: (KeychainReader.Credentials) async throws -> CodexResumeUsage

    init(home: URL, host: @escaping @MainActor () throws -> URL = { try CodexRuntimeReadProbe.runningHostExecutable() },
         fetchUsage: @escaping (KeychainReader.Credentials) async throws -> CodexResumeUsage = { credentials in
             guard let account = credentials.accountID, !account.isEmpty else { throw Blocked(reason: .accountUnknown) }
             return try await CodexPlanAdapter().fetchResumeUsage(accessToken: credentials.accessToken, accountID: account)
         }) {
        self.home = home; self.host = host; self.fetchUsage = fetchUsage
    }

    func currentAccount(now: Date = Date()) throws -> CodexResumeAccountObservation {
        let url = home.appendingPathComponent("auth.json")
        let credentials = try KeychainReader.readCodexAuthFile(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let account = credentials.accountID, !account.isEmpty,
              let modified = attributes[.modificationDate] as? Date else { throw Blocked(reason: .accountUnknown) }
        return .init(accountID: account, observedAt: now, fileModifiedAt: modified)
    }

    func prepare(candidate: CodexResumeCandidate, source: URL, accountID: String?) async -> Check {
        guard let accountID, !accountID.isEmpty else { return .blocked(.accountUnknown) }
        do {
            let executable: URL
            do { executable = try host() } catch { return .blocked(.hostUnavailable) }
            let credentials: KeychainReader.Credentials
            do { credentials = try KeychainReader.readCodexAuthFile(url: home.appendingPathComponent("auth.json")) }
            catch { return .blocked(.authenticationRequired) }
            guard credentials.accountID == accountID else { return .blocked(.accountMismatch) }
            let root = home.appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
            guard source.resolvingSymlinksInPath().path.hasPrefix(root) else { return .blocked(.sourceUnavailable) }
            let target = try CodexQueueTarget.read(source, threadID: candidate.threadID)
            guard target.failedTurnID == candidate.failedTurnID else { return .blocked(.sessionChanged) }
            let index = try CodexResumeThreadIndex.read(home: home, target: target)
            // A paginated history may advance without appending to the legacy rollout. The index
            // must not report activity newer than the failure we're about to resume.
            guard index.updatedAt <= candidate.detectedAt.addingTimeInterval(1) else { return .blocked(.sessionChanged) }
            let usage: CodexResumeUsage
            do { usage = try await fetchUsage(credentials) }
            catch CodexResumeUsage.Failure.accountMismatch { return .blocked(.accountMismatch) }
            catch CodexPlanAdapter.FetchError.unauthorized { return .blocked(.authenticationRequired) }
            catch { return .blocked(.quotaUnknown) }
            guard usage.accountID == accountID else { return .blocked(.accountMismatch) }
            guard (0...60).contains(Date().timeIntervalSince(usage.observedAt)) else { return .blocked(.quotaUnknown) }
            let prepared = Prepared(target: target, accountID: accountID, usage: usage,
                index: index, executable: executable, checkedAt: Date())
            try validate(prepared)
            switch usage.decision {
            case .ready: return .ready(prepared)
            case .waiting(let date): return .waiting(date)
            case .restricted: return .blocked(.accountRestricted)
            }
        } catch let error as Blocked { return .blocked(error.reason) }
        catch { return .blocked(.sessionChanged) }
    }

    /// Run again after queue --help and immediately before reservation and enqueue.
    func validate(_ prepared: Prepared) throws {
        guard (0...60).contains(Date().timeIntervalSince(prepared.usage.observedAt)),
              (0...15).contains(Date().timeIntervalSince(prepared.checkedAt)) else { throw Blocked(reason: .quotaUnknown) }
        guard try currentAccount().accountID == prepared.accountID else { throw Blocked(reason: .accountMismatch) }
        guard try host() == prepared.executable else { throw Blocked(reason: .hostUnavailable) }
        try prepared.target.revalidate()
        guard try CodexResumeThreadIndex.read(home: home, target: prepared.target) == prepared.index else {
            throw Blocked(reason: .sessionChanged)
        }
    }
}

/// Read only the thread index, never conversation text or private IPC. Unknown schemas fail closed.
struct CodexResumeThreadIndex: Equatable {
    let updatedAt: Date
    let rolloutPath: String

    static func read(home: URL, target: CodexQueueTarget) throws -> Self {
        let url = home.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw CodexDesktopAutoResume.Blocked(reason: .sessionIndexUnavailable)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        let sql = "SELECT rollout_path, archived, model_provider, COALESCE(updated_at_ms, updated_at * 1000) FROM threads WHERE id = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexDesktopAutoResume.Blocked(reason: .sessionIndexUnavailable)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, target.threadID, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let rawPath = sqlite3_column_text(statement, 0),
              let rawProvider = sqlite3_column_text(statement, 2) else {
            throw CodexDesktopAutoResume.Blocked(reason: .sessionIndexUnavailable)
        }
        guard sqlite3_column_int(statement, 1) == 0 else { throw CodexDesktopAutoResume.Blocked(reason: .sessionArchived) }
        let path = String(cString: rawPath)
        guard String(cString: rawProvider) == "openai",
              URL(fileURLWithPath: path).resolvingSymlinksInPath() == target.source.resolvingSymlinksInPath(),
              sqlite3_column_type(statement, 3) != SQLITE_NULL else {
            throw CodexDesktopAutoResume.Blocked(reason: .sessionChanged)
        }
        return .init(updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000), rolloutPath: path)
    }
}
