import Foundation
import Combine
import CloudKit
import AgentMeterCore

/// Serial latest-state outbox. Only the display whitelist is persisted for retry.
@MainActor
final class MacTypeSafeSyncController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var uploading = false
    @Published private(set) var failed = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var lastUploadedAt: Date?
    private let defaults: UserDefaults
    private let store: any TypeSafeSyncStore
    private var pending: TypeSafeSyncEnvelope?
    private var account: String?
    private var accountGeneration = 0
    private var retryTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private static let enabledKey = "typesafe.cloudSync.enabled"
    private static let pendingKey = "typesafe.cloudSync.pending"
    private static let accountKey = "typesafe.cloudSync.account"

    init(defaults: UserDefaults = .standard, store: any TypeSafeSyncStore = CloudKitTypeSafeSyncStore()) {
        self.defaults = defaults
        self.store = store
        enabled = defaults.bool(forKey: Self.enabledKey)
        account = defaults.string(forKey: Self.accountKey)
        if let data = defaults.data(forKey: Self.pendingKey) {
            do { pending = try JSONDecoder().decode(TypeSafeSyncEnvelope.self, from: data) }
            catch { failed = true; defaults.removeObject(forKey: Self.pendingKey) }
        }
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Never send facts belonging to the former iCloud account to a newly signed-in account.
                self.accountGeneration += 1
                self.enabled = false
                self.pending = nil
                self.account = nil
                self.defaults.set(false, forKey: Self.enabledKey)
                self.defaults.removeObject(forKey: Self.pendingKey)
                self.defaults.removeObject(forKey: Self.accountKey)
            }
        }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flush()
                do { try await Task.sleep(nanoseconds: 120_000_000_000) }
                catch { return }
            }
        }
    }
    deinit {
        retryTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    func setEnabled(_ value: Bool, snapshot: TypeSafeDisplaySnapshot) {
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        enqueue(value ? snapshot : nil)
    }
    func update(_ snapshot: TypeSafeDisplaySnapshot) {
        guard enabled else { return }
        enqueue(snapshot)
    }
    private func enqueue(_ snapshot: TypeSafeDisplaySnapshot?) {
        let revision = Date(timeIntervalSince1970: max(Date().timeIntervalSince1970,
            defaults.double(forKey: "typesafe.cloudSync.lastRevision") + 0.001))
        defaults.set(revision.timeIntervalSince1970, forKey: "typesafe.cloudSync.lastRevision")
        pending = TypeSafeSyncEnvelope(snapshot: snapshot, revision: revision)
        persist()
        Task { await flush() }
    }
    private func persist() {
        do {
            if let pending { defaults.set(try JSONEncoder().encode(pending), forKey: Self.pendingKey) }
            else { defaults.removeObject(forKey: Self.pendingKey) }
        } catch { failed = true }
    }
    func flush() async {
        guard !uploading, pending != nil else { return }
        uploading = true
        defer { uploading = false }
        let generation = accountGeneration
        do {
            let identifier = try await store.accountIdentifier()
            guard generation == accountGeneration else { return }
            if let account, account != identifier {
                enabled = false; pending = nil; failed = true
                defaults.set(false, forKey: Self.enabledKey)
                defaults.removeObject(forKey: Self.pendingKey)
                defaults.removeObject(forKey: Self.accountKey)
                self.account = nil
                return
            }
            account = identifier
            defaults.set(identifier, forKey: Self.accountKey)
            while let next = pending {
                try await store.save(next)
                guard generation == accountGeneration else { return }
                if pending == next { pending = nil; persist() }
                failed = false
                failureMessage = nil
                lastUploadedAt = Date()
            }
        } catch {
            failed = true
            if (error as? TypeSafeSyncError) == .accountUnavailable
                || (error as? CKError)?.code == .notAuthenticated {
                failureMessage = "iCloud 不可用，请登录相同 Apple ID"
            } else if let code = (error as? CKError)?.code,
                      [.serverRejectedRequest, .invalidArguments, .permissionFailure].contains(code) {
                failureMessage = "CloudKit 未准备好 Jev 同步，请检查 schema"
            } else {
                failureMessage = "Jev 同步失败，将自动重试。请检查 iCloud 登录和网络。"
            }
        }
    }
}
