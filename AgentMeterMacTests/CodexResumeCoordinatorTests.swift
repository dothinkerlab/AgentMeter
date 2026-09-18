import Foundation
import XCTest
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class CodexResumeCoordinatorTests: XCTestCase {
    private func fixture(transport: (any CodexResumeTransport)? = nil, legacy: Bool = false) throws
        -> (CodexResumeCoordinator, CodexMonitorCheckpointStore, UserDefaults) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: legacy ? "codexSessionMonitoringEnabled" : CodexResumeCoordinator.enabledKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        let now = Date()
        var state = CodexMonitorCheckpoint(homePath: home.path, monitoringSince: now.addingTimeInterval(-20))
        for index in 0..<2 {
            let thread = UUID().uuidString, turn = UUID().uuidString
            let source = sessions.appendingPathComponent("\(index).jsonl")
            let lines: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": thread, "originator": "Codex Desktop"]],
                ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": turn,
                    "error": ["codex_error_info": "usage_limit_exceeded"]]]
            ]
            var data = Data()
            for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10) }
            try data.write(to: source)
            state.queue.insert(.init(threadID: thread, failedTurnID: turn,
                detectedAt: now.addingTimeInterval(Double(index - 10)), projectName: "Project \(index)",
                accountID: "account", limitID: "codex", requiredWindowIDs: ["primary"], runtimeEvidenceVerified: true))
        }
        state = CodexIncrementalSessionMonitor().scan(state, now: now).checkpoint
        let store = CodexMonitorCheckpointStore(url: home.appendingPathComponent("checkpoint.json"))
        try store.save(state)
        return (CodexResumeCoordinator(defaults: defaults, home: home, storeURL: store.url,
            transport: transport, notificationsEnabled: false), store, defaults)
    }

    func testLegacyMonitoringDoesNotAuthorizeAutomationOrCancelCandidates() throws {
        let (coordinator, _, _) = try fixture(legacy: true)
        XCTAssertFalse(coordinator.enabled)
        XCTAssertEqual(coordinator.pending.count, 2)
    }

    func testPausePersistsCandidatesAndReenableRebaselines() async throws {
        let transport = ResumeTestTransport()
        transport.used = 100
        let (coordinator, store, _) = try fixture(transport: transport)
        let ids = coordinator.pending.map(\.id)
        coordinator.setEnabled(false)
        XCTAssertEqual(try store.load()?.queue.pendingInOrder.map(\.id), ids)
        // Append another failure during pause. Re-enabling must establish EOF, not enqueue it.
        let saved = try XCTUnwrap(store.load())
        let source = URL(fileURLWithPath: try XCTUnwrap(saved.cursors.keys.first))
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        let line: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": "event_msg", "payload": ["type": "task_complete", "turn_id": UUID().uuidString,
                "error": ["codex_error_info": "usage_limit_exceeded"]]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: line))
        try handle.write(contentsOf: Data([10])); try handle.close()
        coordinator.setEnabled(true)
        await coordinator.poll()
        XCTAssertEqual(coordinator.pending.map(\.id), ids)
        XCTAssertTrue(transport.submitted.isEmpty)
    }

    func testAllThreadsExecuteOldestFirstAndPersistSeparateReceipt() async throws {
        let transport = ResumeTestTransport()
        let (coordinator, store, _) = try fixture(transport: transport)
        let order = coordinator.pending.map(\.threadID)
        await coordinator.checkPending()
        XCTAssertEqual(transport.submitted, order)
        XCTAssertTrue(coordinator.pending.isEmpty)
        let saved = try XCTUnwrap(store.load())
        XCTAssertTrue(saved.queue.candidates.allSatisfy { $0.state == .resumed })
        XCTAssertTrue(saved.queue.candidates.allSatisfy { $0.queuedMessageID != nil && $0.submittedTurnID != $0.queuedMessageID })
        await coordinator.checkPending()
        XCTAssertEqual(transport.submitted.count, 2)
    }

    func testWaitingDoesNotSendAndForcedRecheckUsesFreshQuota() async throws {
        let transport = ResumeTestTransport()
        transport.used = 100
        let (coordinator, _, _) = try fixture(transport: transport)
        await coordinator.checkPending()
        XCTAssertTrue(transport.submitted.isEmpty)
        XCTAssertTrue(coordinator.nextChecks.values.allSatisfy { $0 > Date().addingTimeInterval(3500) })
        transport.used = 0
        await coordinator.recheck()
        XCTAssertEqual(transport.submitted.count, 2)
    }

    func testPauseDuringPreflightNeverSubmits() async throws {
        let transport = ResumeTestTransport()
        let (coordinator, _, _) = try fixture(transport: transport)
        transport.onPreflight = { coordinator.setEnabled(false) }
        await coordinator.checkPending()
        XCTAssertTrue(transport.submitted.isEmpty)
        XCTAssertEqual(coordinator.pending.count, 2)
    }

    func testPauseAfterSubmissionKeepsObservationAndStopsNextThread() async throws {
        let transport = ResumeTestTransport()
        let (coordinator, _, _) = try fixture(transport: transport)
        transport.onSubmit = { coordinator.setEnabled(false) }
        await coordinator.checkPending()
        XCTAssertEqual(transport.submitted.count, 1)
        XCTAssertEqual(coordinator.candidates.filter { $0.state == .resumed }.count, 1)
        XCTAssertEqual(coordinator.pending.count, 1)
    }

    func testLegacyManualReservationBlocksAutomaticSend() async throws {
        let transport = ResumeTestTransport()
        let (coordinator, store, _) = try fixture(transport: transport)
        let candidate = try XCTUnwrap(coordinator.pending.first)
        let source = try XCTUnwrap(coordinator.sourceForManualResume(candidateID: candidate.id))
        let target = try CodexQueueTarget.read(source, threadID: candidate.threadID)
        let attempts = CodexQueueAttemptStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("queue-attempts"))
        try attempts.reserve(target).close()
        await coordinator.checkPending()
        XCTAssertFalse(transport.submitted.contains(candidate.threadID))
        XCTAssertEqual(coordinator.candidates.first(where: { $0.id == candidate.id })?.state, .uncertain)
        XCTAssertEqual(transport.submitted.count, 1) // Another thread is still eligible.
    }

    func testAttentionNotificationsAreNotEnqueued() {
        var ledger = CodexResumeNotificationLedger()
        let now = Date()
        ledger.enqueue(candidateID: "one", kind: "detected", now: now)
        ledger.enqueue(candidateID: "one", kind: "attention", now: now)
        XCTAssertEqual(ledger.events.map(\.kind), ["detected"])
    }

    func testLegacyAttentionNotificationsAreSuppressedAndConsumed() throws {
        let now = Date()
        var ledger = CodexResumeNotificationLedger()
        ledger.events = [.init(key: "one:attention", kind: "attention", createdAt: now)]
        var restored = try JSONDecoder().decode(CodexResumeNotificationLedger.self, from: JSONEncoder().encode(ledger))
        let batch = try XCTUnwrap(restored.due(at: now.addingTimeInterval(10))["attention"])
        XCTAssertNil(CodexResumeNotifications.title(for: "attention"))
        restored.markDelivered(batch)
        XCTAssertTrue(restored.events.isEmpty)
        XCTAssertTrue(restored.due(at: now.addingTimeInterval(20)).isEmpty)
    }

    func testSupportedNotificationsRetainTitlesAndBatching() throws {
        var ledger = CodexResumeNotificationLedger()
        let now = Date()
        for kind in ["detected", "resumed", "observed"] {
            XCTAssertNotNil(CodexResumeNotifications.title(for: kind))
            ledger.enqueue(candidateID: "one", kind: kind, now: now)
            ledger.enqueue(candidateID: "one", kind: kind, now: now)
            ledger.enqueue(candidateID: "two", kind: kind, now: now)
        }
        XCTAssertTrue(ledger.due(at: now.addingTimeInterval(9)).isEmpty)
        let batches = ledger.due(at: now.addingTimeInterval(10))
        XCTAssertEqual(batches.count, 3)
        for batch in batches.values { XCTAssertEqual(batch.count, 2) }
    }

    func testNotificationsBatchAfterTenSecondsAndSurviveRestartWithoutReplay() throws {
        var ledger = CodexResumeNotificationLedger()
        let now = Date()
        ledger.enqueue(candidateID: "one", kind: "detected", now: now)
        ledger.enqueue(candidateID: "two", kind: "detected", now: now.addingTimeInterval(5))
        ledger.enqueue(candidateID: "one", kind: "detected", now: now)
        XCTAssertTrue(ledger.due(at: now.addingTimeInterval(9)).isEmpty)
        let batch = try XCTUnwrap(ledger.due(at: now.addingTimeInterval(10))["detected"])
        XCTAssertEqual(batch.count, 2)
        ledger.markDelivered(batch)
        var restored = try JSONDecoder().decode(CodexResumeNotificationLedger.self, from: JSONEncoder().encode(ledger))
        restored.enqueue(candidateID: "one", kind: "detected", now: now.addingTimeInterval(20))
        XCTAssertTrue(restored.events.isEmpty)
    }
}

@MainActor
private final class ResumeTestTransport: CodexResumeTransport {
    var used: Double = 0
    var submitted: [String] = []
    var onPreflight: () -> Void = {}
    var onSubmit: () -> Void = {}
    func preflight(candidate: CodexResumeCandidate) async throws -> CodexResumePreflight {
        onPreflight()
        return .init(originalDesktopVerified: true,
            quota: .init(accountID: "account", limitID: "codex", observedAt: Date(),
                windows: [.init(id: "primary", usedPercent: used, resetsAt: Date().addingTimeInterval(3600))], blockingState: .clear),
            session: .init(threadID: candidate.threadID, latestTurnID: candidate.failedTurnID, accountID: "account",
                isIdle: true, isArchived: false, observedAt: Date()))
    }
    func submitContinue(candidate: CodexResumeCandidate, operationID: String) async throws -> CodexResumeSubmission {
        submitted.append(candidate.threadID)
        onSubmit()
        return .queued(threadID: candidate.threadID, messageID: UUID().uuidString)
    }
    func observeQueuedMessage(threadID: String, messageID: String) async throws -> CodexResumeExecution? {
        .init(threadID: threadID, turnID: UUID().uuidString, status: .ran)
    }
    func observeExecution(threadID: String, turnID: String) async throws -> CodexResumeExecution {
        .init(threadID: threadID, turnID: turnID, status: .unknown)
    }
}
