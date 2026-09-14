import Foundation
import AgentMeterCore

/// Observation-only coordinator. No desktop controller is installed until runtime evidence is verified.
@MainActor
final class CodexResumeCoordinator: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var candidates: [CodexResumeCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var scanIncomplete = false
    @Published private(set) var directoryAvailable = false
    @Published private(set) var storageFailed = false

    private let defaults: UserDefaults
    private let store: CodexMonitorCheckpointStore
    private var checkpoint: CodexMonitorCheckpoint
    private var generation: UInt64 = 0
    private var requiresSave = false
    private var worker: Task<CodexMonitorScan, Never>?
    private static let enabledKey = "codexSessionMonitoringEnabled"

    init(defaults: UserDefaults = .standard, home: URL = CodexLocalPaths.home,
         storeURL: URL = CodexLocalPaths.checkpoint, now: Date = Date()) {
        self.defaults = defaults
        store = CodexMonitorCheckpointStore(url: storeURL)
        enabled = defaults.bool(forKey: Self.enabledKey)
        checkpoint = CodexMonitorCheckpoint(homePath: home.standardizedFileURL.path, monitoringSince: now)
        do {
            if var saved = try store.load(), saved.homePath == checkpoint.homePath {
                let original = saved
                saved.queue.recoverAfterRestart()
                if !enabled { saved.queue.cancelPending() }
                requiresSave = saved != original
                checkpoint = saved
                candidates = saved.queue.candidates
            }
        } catch {
            // Corruption is not equivalent to an empty queue: never silently discard dedup state.
            storageFailed = true
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
        }
    }

    func setEnabled(_ value: Bool, now: Date = Date()) {
        guard value != enabled, !(value && storageFailed) else { return }
        generation &+= 1
        worker?.cancel()
        var next = checkpoint
        if value {
            next.monitoringSince = now
            next.baselineComplete = false
            next.cursors = [:]
        } else { next.queue.cancelPending() }
        guard persist(next) else {
            enabled = false
            defaults.set(false, forKey: Self.enabledKey)
            return
        }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { Task { await poll() } }
    }

    func cancel(id: String) {
        generation &+= 1
        worker?.cancel()
        var next = checkpoint
        next.queue.cancel(id: id)
        _ = persist(next)
    }

    func poll(now: Date = Date()) async {
        guard enabled, !storageFailed, !isScanning else { return }
        isScanning = true
        defer { isScanning = false; worker = nil }
        let requestedGeneration = generation
        let input = checkpoint
        let task = Task.detached(priority: .utility) { CodexIncrementalSessionMonitor().scan(input, now: now) }
        worker = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, enabled, generation == requestedGeneration else { return }
        // Publication happens only after both queue and cursor offsets have been committed.
        guard persist(result.checkpoint) else { return }
        lastCheckedAt = now
        scanIncomplete = result.incomplete
        directoryAvailable = result.directoryAvailable
    }

    @discardableResult
    private func persist(_ next: CodexMonitorCheckpoint) -> Bool {
        do {
            if requiresSave || checkpoint != next || !FileManager.default.fileExists(atPath: store.url.path) {
                try store.save(next)
            }
            checkpoint = next
            requiresSave = false
            candidates = next.queue.candidates
            return true
        } catch {
            storageFailed = true
            return false
        }
    }
}
