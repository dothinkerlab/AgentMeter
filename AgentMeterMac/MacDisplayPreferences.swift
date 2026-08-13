import Foundation
import AgentMeterCore

/// Mac 主界面的本地展示身份。它只控制菜单栏 popover 的显隐与顺序，
/// 不参与采集、CloudKit、Widget 或 Watch 同步。
enum MacDisplayItemID: String, CaseIterable, Codable, Hashable, Identifiable {
    case codex
    case claudeCode
    case cursor
    case kimiCode
    case glmCoding
    case miniMax
    case openAIAPI
    case anthropicAPI
    case kimiAPI
    case deepSeek
    case openRouter
    case xAI
    case cursorTeam

    var id: String { rawValue }

    var toolKind: ToolKind? {
        switch self {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        case .deepSeek: .deepSeek
        case .openRouter: .openRouter
        case .xAI: .grok
        case .openAIAPI, .anthropicAPI, .kimiAPI, .cursorTeam: nil
        }
    }

    var manualProvider: ManualProviderKind? {
        switch self {
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        case .openAIAPI: .openAIAPI
        case .anthropicAPI: .anthropicAPI
        case .kimiAPI: .kimiAPI
        case .deepSeek: .deepSeek
        case .openRouter: .openRouter
        case .xAI: .xAI
        case .cursorTeam: .cursorTeam
        case .codex, .claudeCode, .cursor: nil
        }
    }

    static func item(for tool: ToolKind) -> MacDisplayItemID? {
        switch tool {
        case .codex: .codex
        case .claudeCode: .claudeCode
        case .cursor: .cursor
        case .kimiCode: .kimiCode
        case .glmCoding: .glmCoding
        case .miniMax: .miniMax
        case .deepSeek: .deepSeek
        case .openRouter: .openRouter
        case .grok: .xAI
        default: nil
        }
    }
}

enum MacDisplayPreferences {
    static let orderKey = "macDisplayOrder.v2"
    static let hiddenKey = "macHiddenDisplayItems.v1"

    static func order(defaults: UserDefaults, legacyToolOrder: String) -> [MacDisplayItemID] {
        let saved = defaults.string(forKey: orderKey)?
            .split(separator: ",")
            .compactMap { MacDisplayItemID(rawValue: String($0)) } ?? []
        if !saved.isEmpty { return deduplicated(saved) + missing(from: saved) }

        let legacy = legacyToolOrder
            .split(separator: ",")
            .compactMap { ToolKind(rawValue: String($0)) }
            .compactMap(MacDisplayItemID.item)
        return deduplicated(legacy) + missing(from: legacy)
    }

    static func saveOrder(_ order: [MacDisplayItemID], defaults: UserDefaults) {
        defaults.set(deduplicated(order).map(\.rawValue).joined(separator: ","), forKey: orderKey)
    }

    static func hidden(defaults: UserDefaults) -> Set<MacDisplayItemID> {
        let raw = defaults.string(forKey: hiddenKey) ?? ""
        return Set(raw.split(separator: ",").compactMap { MacDisplayItemID(rawValue: String($0)) })
    }

    static func saveHidden(_ hidden: Set<MacDisplayItemID>, defaults: UserDefaults) {
        let raw = MacDisplayItemID.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
        defaults.set(raw, forKey: hiddenKey)
    }

    private static func deduplicated(_ input: [MacDisplayItemID]) -> [MacDisplayItemID] {
        var seen = Set<MacDisplayItemID>()
        return input.filter { seen.insert($0).inserted }
    }

    private static func missing(from input: [MacDisplayItemID]) -> [MacDisplayItemID] {
        MacDisplayItemID.allCases.filter { !input.contains($0) }
    }
}

enum MacPendingCloudKitDeletionPreferences {
    static let key = "macPendingCloudKitDeletionTools.v1"

    static func tools(defaults: UserDefaults) -> Set<ToolKind> {
        let rawValues = defaults.stringArray(forKey: key) ?? []
        return Set(rawValues.compactMap(ToolKind.init(rawValue:)))
    }

    static func mark(_ tool: ToolKind, defaults: UserDefaults) {
        var pending = tools(defaults: defaults)
        pending.insert(tool)
        save(pending, defaults: defaults)
    }

    static func clear(_ tool: ToolKind, defaults: UserDefaults) {
        var pending = tools(defaults: defaults)
        pending.remove(tool)
        save(pending, defaults: defaults)
    }

    private static func save(_ tools: Set<ToolKind>, defaults: UserDefaults) {
        defaults.set(tools.map(\.rawValue).sorted(), forKey: key)
    }
}

actor MacPendingCloudKitDeletionCoordinator {
    typealias DeleteOperation = @Sendable (ToolKind) async throws -> Void
    typealias SleepOperation = @Sendable (UInt64) async throws -> Void

    private struct InFlight: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private struct ScheduledRetry: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let defaults: UserDefaults
    private let deleteOperation: DeleteOperation
    private let sleepOperation: SleepOperation
    private var desiredDisabledTools: Set<ToolKind> = []
    private var inFlight: [ToolKind: InFlight] = [:]
    private var retries: [ToolKind: ScheduledRetry] = [:]

    init(
        defaults: UserDefaults,
        deleteOperation: @escaping DeleteOperation = { tool in
            try await DeviceCodingQuotaCollector(device: .mac).disable(tool: tool)
        },
        sleepOperation: @escaping SleepOperation = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.defaults = defaults
        self.deleteOperation = deleteOperation
        self.sleepOperation = sleepOperation
    }

    func resumePendingDeletion(_ tool: ToolKind) {
        desiredDisabledTools.insert(tool)
        scheduleRetry(for: tool, attempt: 0)
    }

    func disable(_ tool: ToolKind) async -> Bool {
        desiredDisabledTools.insert(tool)
        cancelScheduledRetry(for: tool)
        MacPendingCloudKitDeletionPreferences.mark(tool, defaults: defaults)
        let succeeded = await performDeletion(for: tool)
        finishDeletionAttempt(for: tool, succeeded: succeeded, nextAttempt: 0)
        return succeeded
    }

    /// Cancels future retries. If a CloudKit deletion already crossed the
    /// cancellation boundary, wait for it so the caller can perform exactly one
    /// fresh save after the delete finishes.
    func prepareForEnable(_ tool: ToolKind) async {
        desiredDisabledTools.remove(tool)
        cancelScheduledRetry(for: tool)
        if let active = inFlight[tool] {
            _ = await active.task.value
        }
        desiredDisabledTools.remove(tool)
        cancelScheduledRetry(for: tool)
        MacPendingCloudKitDeletionPreferences.clear(tool, defaults: defaults)
    }

    func hasScheduledRetry(for tool: ToolKind) -> Bool {
        retries[tool] != nil
    }

    static func retryDelayNanoseconds(attempt: Int) -> UInt64 {
        let cappedAttempt = max(0, min(attempt, 6))
        let seconds = min(30 * (1 << cappedAttempt), 30 * 60)
        return UInt64(seconds) * 1_000_000_000
    }

    private func performDeletion(for tool: ToolKind) async -> Bool {
        if let active = inFlight[tool] {
            return await active.task.value
        }
        let id = UUID()
        let operation = deleteOperation
        let task = Task {
            do {
                try await operation(tool)
                return true
            } catch {
                return false
            }
        }
        inFlight[tool] = InFlight(id: id, task: task)
        let succeeded = await task.value
        if inFlight[tool]?.id == id {
            inFlight[tool] = nil
        }
        return succeeded
    }

    private func finishDeletionAttempt(
        for tool: ToolKind,
        succeeded: Bool,
        nextAttempt: Int
    ) {
        guard desiredDisabledTools.contains(tool) else {
            MacPendingCloudKitDeletionPreferences.clear(tool, defaults: defaults)
            return
        }
        if succeeded {
            MacPendingCloudKitDeletionPreferences.clear(tool, defaults: defaults)
            cancelScheduledRetry(for: tool)
        } else {
            MacPendingCloudKitDeletionPreferences.mark(tool, defaults: defaults)
            scheduleRetry(for: tool, attempt: nextAttempt)
        }
    }

    private func scheduleRetry(for tool: ToolKind, attempt: Int) {
        guard desiredDisabledTools.contains(tool), retries[tool] == nil else { return }
        let id = UUID()
        let delay = Self.retryDelayNanoseconds(attempt: attempt)
        let sleep = sleepOperation
        let task = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                await self?.discardRetry(for: tool, id: id)
                return
            }
            guard !Task.isCancelled else {
                await self?.discardRetry(for: tool, id: id)
                return
            }
            await self?.runScheduledRetry(for: tool, id: id, attempt: attempt)
        }
        retries[tool] = ScheduledRetry(id: id, task: task)
    }

    private func runScheduledRetry(for tool: ToolKind, id: UUID, attempt: Int) async {
        guard retries[tool]?.id == id else { return }
        retries[tool] = nil
        guard desiredDisabledTools.contains(tool) else { return }
        let succeeded = await performDeletion(for: tool)
        finishDeletionAttempt(for: tool, succeeded: succeeded, nextAttempt: attempt + 1)
    }

    private func discardRetry(for tool: ToolKind, id: UUID) {
        guard retries[tool]?.id == id else { return }
        retries[tool] = nil
    }

    private func cancelScheduledRetry(for tool: ToolKind) {
        retries.removeValue(forKey: tool)?.task.cancel()
    }
}
