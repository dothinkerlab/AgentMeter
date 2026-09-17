import Foundation
import Combine
import AgentMeterCore

/// Single owner of monitoring, scheduling, durable transitions and both sending entry points.
@MainActor
final class CodexResumeCoordinator: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var candidates: [CodexResumeCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isSending = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var scanIncomplete = false
    @Published private(set) var directoryAvailable = false
    @Published private(set) var storageFailed = false
    @Published private(set) var checks: [String: CodexResumeCheck] = [:]
    @Published private(set) var nextChecks: [String: Date] = [:]
    @Published private(set) var notificationPermissionDenied = false
    @Published private(set) var manualError: String?
    @Published private(set) var recentAttempts: [CodexQueueAttemptStore.Summary] = []
    @Published private(set) var historyWarning = false
    var legacyAttempts: [CodexQueueAttemptStore.Summary] {
        let known = Set(candidates.map { attemptStore.file(for: $0.threadID + ":" + $0.failedTurnID).lastPathComponent })
        return recentAttempts.filter { !known.contains($0.id) }
    }

    let sender = CodexDesktopQueueController()
    private let defaults: UserDefaults
    private let store: CodexMonitorCheckpointStore
    private var checkpoint: CodexMonitorCheckpoint
    private var generation: UInt64 = 0
    private var requiresSave = false
    private var worker: Task<CodexMonitorScan, Never>?
    private var timer: Task<Void, Never>?
    private var notificationTimer: Task<Void, Never>?
    private var senderChanges: AnyCancellable?
    private var executor: CodexResumeExecutor?
    private var flushingNotifications = false
    private let notifications = CodexResumeNotifications()
    private let notificationsEnabled: Bool
    // Intentionally absent in production until the host offers verifiable original-runtime evidence.
    private let transport: (any CodexResumeTransport)?
    private let attemptStore: CodexQueueAttemptStore
    var automaticConnectionAvailable: Bool { transport != nil }
    static let enabledKey = "codexAutomaticResumeEnabled"

    var isBusy: Bool { isScanning || isSending }
    var pending: [CodexResumeCandidate] { checkpoint.queue.pendingInOrder }
    var history: [CodexResumeCandidate] {
        candidates.filter { $0.state != .pending }.sorted { $0.detectedAt > $1.detectedAt }
    }
    var hasSeenIntroduction: Bool { defaults.bool(forKey: "codexResumeIntroductionSeen") }
    var overallStatus: String {
        if storageFailed { return L10n.string("需要处理") }
        if !enabled { return L10n.string("已暂停") }
        if candidates.contains(where: { [.uncertain, .failed].contains($0.state) }) {
            return L10n.string("需要处理")
        }
        if checks.values.contains(where: { if case .blocked = $0 { return true }; return false }) {
            return L10n.string("需要处理")
        }
        if checks.values.contains(where: { if case .waiting = $0 { return true }; return false }) {
            return L10n.string("等待额度")
        }
        return L10n.string("正在监测")
    }

    init(defaults: UserDefaults = .standard, home: URL = CodexLocalPaths.home,
         storeURL: URL = CodexLocalPaths.checkpoint, now: Date = Date(),
         transport: (any CodexResumeTransport)? = nil, notificationsEnabled: Bool = true) {
        self.defaults = defaults
        self.notificationsEnabled = notificationsEnabled
        self.transport = transport
        attemptStore = CodexQueueAttemptStore(directory: storeURL.deletingLastPathComponent().appendingPathComponent("queue-attempts"))
        store = CodexMonitorCheckpointStore(url: storeURL)
        enabled = defaults.bool(forKey: Self.enabledKey)
        checkpoint = CodexMonitorCheckpoint(homePath: home.standardizedFileURL.path, monitoringSince: now)
        do {
            if var saved = try store.load(), saved.homePath == checkpoint.homePath {
                let original = saved
                saved.queue.recoverAfterRestart()
                requiresSave = saved != original
                checkpoint = saved
                candidates = saved.queue.candidates
            }
        } catch {
            storageFailed = true
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
        }
        senderChanges = sender.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// App lifecycle owns the timer, so closing Settings never cancels an enqueued message.
    func start() {
        guard timer == nil else { return }
        notificationTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flushNotifications()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    deinit {
        timer?.cancel()
        notificationTimer?.cancel()
        worker?.cancel()
    }

    private func tick() async {
        let now = Date()
        if requiresSave {
            guard persist(checkpoint) else { return }
            for candidate in candidates where candidate.state == .uncertain {
                enqueue(candidate.id, kind: "attention", now: now)
            }
        }
        if enabled, !isBusy, lastCheckedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            await poll()
        } else if enabled, !isBusy, nextChecks.values.contains(where: { $0 <= now }) {
            await checkPending()
        }
        await flushNotifications()
    }

    func setEnabled(_ value: Bool, now: Date = Date()) {
        guard value != enabled, !(value && storageFailed) else { return }
        generation &+= 1
        worker?.cancel()
        // Pause before submission, but continue observing messages already handed to the sender.
        if !checkpoint.queue.candidates.contains(where: { [.attempting, .submitted].contains($0.state) }) {
            executor?.cancel()
        }
        var next = checkpoint
        if value {
            next.monitoringSince = now
            next.baselineComplete = false
            next.cursors = [:]
        }
        guard persist(next) else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        checks = [:]; nextChecks = [:]
        lastCheckedAt = nil
        if value {
            defaults.set(true, forKey: "codexResumeIntroductionSeen")
            Task {
                if notificationsEnabled {
                    await notifications.requestPermission()
                    notificationPermissionDenied = notifications.permissionDenied
                }
                await poll()
            }
        }
    }

    func cancel(id: String) {
        guard !isSending else { return }
        generation &+= 1
        worker?.cancel()
        var next = checkpoint
        next.queue.cancel(id: id)
        if persist(next) { checks[id] = nil; nextChecks[id] = nil }
    }

    func sourceForManualResume(candidateID: String) -> URL? {
        guard !storageFailed,
              let candidate = candidates.first(where: { $0.id == candidateID && $0.state == .pending }) else { return nil }
        let paths = checkpoint.cursors.filter { $0.value.threadID == candidate.threadID }.map(\.key)
        guard paths.count == 1, let path = paths.first else { return nil }
        let root = URL(fileURLWithPath: checkpoint.homePath).appendingPathComponent("sessions")
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let source = URL(fileURLWithPath: path).standardizedFileURL
        guard source.resolvingSymlinksInPath().path.hasPrefix(root) else { return nil }
        return source
    }

    func recheck() async {
        nextChecks = [:]
        await poll()
    }

    func poll(now: Date = Date()) async {
        guard enabled, !storageFailed, !isBusy else { return }
        isScanning = true
        let requestedGeneration = generation
        let input = checkpoint
        let task = Task.detached(priority: .utility) { CodexIncrementalSessionMonitor().scan(input, now: now) }
        worker = task
        var result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        isScanning = false; worker = nil
        guard !Task.isCancelled, enabled, generation == requestedGeneration else { return }
        // A notification flush may have committed while the detached scan was reading.
        result.checkpoint.notifications = checkpoint.notifications
        guard persist(result.checkpoint) else { return }
        lastCheckedAt = now
        scanIncomplete = result.incomplete
        directoryAvailable = result.directoryAvailable
        let liveIDs = Set(pending.map(\.id))
        checks = checks.filter { liveIDs.contains($0.key) }
        nextChecks = nextChecks.filter { liveIDs.contains($0.key) }
        for candidate in pending { enqueue(candidate.id, kind: "detected", now: now) }
        await checkPending(now: now)
    }

    func checkPending(now: Date = Date()) async {
        guard enabled, !storageFailed, !isBusy else { return }
        isScanning = true
        defer { isScanning = false }
        let requestedGeneration = generation
        for candidate in pending {
            guard enabled, generation == requestedGeneration, !storageFailed, !Task.isCancelled else { break }
            if let next = nextChecks[candidate.id], next > now { continue }
            checks[candidate.id] = .checking
            let check: CodexResumeCheck
            if candidates.contains(where: {
                $0.threadID == candidate.threadID && $0.state == .uncertain
            }) {
                check = .blocked(.previousAttempt)
            } else if let source = sourceForManualResume(candidateID: candidate.id) {
                do {
                    let target = try CodexQueueTarget.read(source, threadID: candidate.threadID)
                    guard target.failedTurnID == candidate.failedTurnID else {
                        checks[candidate.id] = .blocked(.sessionChanged)
                        nextChecks[candidate.id] = now.addingTimeInterval(60)
                        continue
                    }
                    if let transport {
                        let preflight = try await transport.preflight(candidate: candidate)
                        guard enabled, generation == requestedGeneration else { break }
                        if !preflight.originalDesktopVerified { check = .blocked(.runtimeUnverified) }
                        else {
                            switch CodexResumePolicy.evaluate(candidate, quota: preflight.quota, session: preflight.session, now: Date()) {
                            case .needsVerification:
                                check = .blocked(CodexResumeBlock.reason(for: candidate, evidence: preflight))
                            case .waiting(let date): check = .waiting(date)
                            case .ready:
                                // Recheck inside the executor immediately before durable reservation/submission.
                                isSending = true
                                let running = CodexResumeExecutor(queue: checkpoint.queue, save: { [unowned self] queue in
                                    var next = checkpoint; next.queue = queue
                                    guard persist(next) else { throw CodexMonitorCheckpointStore.StoreError.writeFailed }
                                })
                                executor = running
                                let recorded = CodexRecordedResumeTransport(base: transport, target: target, store: attemptStore)
                                let outcome = await running.execute(candidateID: candidate.id, using: recorded)
                                executor = nil; isSending = false
                                checks[candidate.id] = nil; nextChecks[candidate.id] = nil
                                if outcome == .resumed { enqueue(candidate.id, kind: "resumed") }
                                else if [.failed, .uncertain, .storageFailed].contains(outcome) { enqueue(candidate.id, kind: "attention") }
                                else { nextChecks[candidate.id] = now.addingTimeInterval(60) }
                                continue
                            }
                        }
                    } else {
                        check = await productionCheck(candidate)
                    }
                } catch { check = .blocked(.sessionChanged) }
            } else { check = .blocked(.sourceUnavailable) }
            guard enabled, generation == requestedGeneration else { break }
            checks[candidate.id] = check
            if case .waiting(let date) = check { nextChecks[candidate.id] = date ?? now.addingTimeInterval(60) }
            else { nextChecks[candidate.id] = now.addingTimeInterval(60) }
            if case .blocked = check { enqueue(candidate.id, kind: "attention", now: now) }
        }
    }

    private func productionCheck(_ candidate: CodexResumeCandidate) async -> CodexResumeCheck {
        do {
            let executable = try CodexRuntimeReadProbe.runningHostExecutable()
            let result = try await CodexRuntimeReadProbe.read(executable: executable,
                home: URL(fileURLWithPath: checkpoint.homePath), threadID: candidate.threadID)
            guard let account = result.quota.accountId, !account.isEmpty, candidate.accountID != nil else {
                return .blocked(.accountUnknown)
            }
            guard account == candidate.accountID else { return .blocked(.accountMismatch) }
            // The current protocol cannot attest ownership/failed turn/archival. No unsafe fallback.
            return .blocked(.runtimeUnverified)
        } catch CodexRuntimeProbeError.unsupportedHost { return .blocked(.hostUnavailable) }
        catch { return .blocked(.connectionUnavailable) }
    }

    func sendManually(candidate: CodexResumeCandidate) async {
        guard let source = sourceForManualResume(candidateID: candidate.id) else {
            manualError = CodexResumeBlock.sourceUnavailable.message; return
        }
        await sendManually(source: source, threadID: candidate.threadID, expectedTurnID: candidate.failedTurnID)
    }

    func sendManually(source: URL, threadID: String, expectedTurnID: String? = nil) async {
        guard !isBusy, !storageFailed else { return }
        manualError = nil
        let target: CodexQueueTarget
        do {
            let root = URL(fileURLWithPath: checkpoint.homePath).appendingPathComponent("sessions").resolvingSymlinksInPath().path + "/"
            guard source.resolvingSymlinksInPath().path.hasPrefix(root) else { throw CodexDesktopQueueError.invalidSource }
            target = try CodexQueueTarget.read(source, threadID: threadID)
            guard expectedTurnID == nil || target.failedTurnID == expectedTurnID else { throw CodexDesktopQueueError.invalidSource }
        } catch { manualError = CodexResumeBlock.sessionChanged.message; return }
        var next = checkpoint
        let existing = candidates.first { $0.threadID == threadID && $0.failedTurnID == target.failedTurnID }
        let candidate = existing ?? CodexResumeCandidate(threadID: threadID, failedTurnID: target.failedTurnID, detectedAt: Date())
        if existing == nil {
            guard candidates.count < 500 else { manualError = L10n.string("已达到 500 条本地记录上限，暂不记录新的候选。"); return }
            next.queue.insert(candidate)
        }
        guard next.queue.beginManualAttempt(id: candidate.id) else {
            manualError = CodexResumeBlock.previousAttempt.message; return
        }
        guard persist(next) else { return }
        isSending = true
        defer { isSending = false }
        let outcome = await sender.send(source: source, threadID: threadID,
            home: URL(fileURLWithPath: checkpoint.homePath), store: attemptStore) { [self] messageID in
                var next = checkpoint
                next.queue.recordQueued(id: candidate.id, messageID: messageID)
                _ = persist(next)
            }
        if outcome != .observed { manualError = sender.message }
        next = checkpoint
        switch outcome {
        case .observed: next.queue.recordObserved(id: candidate.id)
        case .uncertain: next.queue.recordUncertain(id: candidate.id)
        case .notSent: next.queue.recordNotSent(id: candidate.id)
        }
        guard persist(next) else { return }
        checks[candidate.id] = nil; nextChecks[candidate.id] = nil
        enqueue(candidate.id, kind: outcome == .observed ? "observed" : "attention")
        await refreshHistory()
    }

    func refreshHistory() async {
        let store = attemptStore
        let result = await Task.detached(priority: .utility) { store.recent() }.value
        recentAttempts = result.records
        historyWarning = result.unreadable || result.truncated
    }

    private func enqueue(_ candidateID: String, kind: String, now: Date = Date()) {
        guard !storageFailed else { return }
        var next = checkpoint
        var ledger = next.notifications ?? CodexResumeNotificationLedger()
        ledger.enqueue(candidateID: candidateID, kind: kind, now: now)
        next.notifications = ledger
        _ = persist(next)
    }

    private func flushNotifications() async {
        guard notificationsEnabled, !storageFailed, !flushingNotifications else { return }
        flushingNotifications = true
        defer { flushingNotifications = false }
        for (kind, events) in (checkpoint.notifications ?? .init()).due(at: Date()) {
            do { try await notifications.deliver(kind: kind, events: events) }
            catch { continue }
            notificationPermissionDenied = notifications.permissionDenied
            var next = checkpoint
            next.notifications?.markDelivered(events)
            guard persist(next) else { return }
        }
    }

    @discardableResult
    private func persist(_ next: CodexMonitorCheckpoint) -> Bool {
        do {
            if requiresSave || checkpoint != next || !FileManager.default.fileExists(atPath: store.url.path) {
                try store.save(next)
            }
            checkpoint = next; requiresSave = false; candidates = next.queue.candidates
            return true
        } catch {
            storageFailed = true
            executor?.cancel()
            return false
        }
    }
}
