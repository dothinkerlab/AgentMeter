import SwiftUI
import UniformTypeIdentifiers
import AgentMeterCore

enum MacSettingsRoute: Hashable {
    case general
    case automatic(PlanProviderKind)
    case manual(ManualProviderKind)
    case about
}

struct MacSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: MacSettingsRoute?
    @State private var searchText = ""

    init(model: AppModel) {
        self.model = model
        let isProviderScreenshot = ProcessInfo.processInfo.arguments.contains(
            "--agentmeter-screenshot-provider-settings"
        )
        _selection = State(initialValue: isProviderScreenshot ? .manual(.openRouter) : .general)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(L10n.string("通用"), systemImage: "gearshape")
                    .tag(MacSettingsRoute.general)

                Section("Plan") {
                    ForEach(filteredPlanProviders, id: \.self) { provider in
                        if let manualProvider = provider.manualProvider {
                            ProviderSidebarRow(
                                name: provider.settingsDisplayName,
                                mark: provider.settingsMonogram,
                                tint: provider.settingsTint,
                                state: model.manualProviderState(manualProvider)
                            )
                            .tag(MacSettingsRoute.manual(manualProvider))
                        } else {
                            ProviderSidebarRow(
                                name: provider.settingsDisplayName,
                                mark: provider.settingsMonogram,
                                tint: provider.settingsTint,
                                state: model.automaticPlanProviderState(provider)
                            )
                            .tag(MacSettingsRoute.automatic(provider))
                        }
                    }
                }

                Section(L10n.string("API 余额与账单")) {
                    ForEach(filteredBillingProviders, id: \.self) { provider in
                        ProviderSidebarRow(
                            name: provider.settingsDisplayName,
                            mark: provider.settingsMonogram,
                            tint: provider.settingsTint,
                            state: model.manualProviderState(provider)
                        )
                        .tag(MacSettingsRoute.manual(provider))
                    }
                }

                Label(L10n.string("关于 AgentMeter"), systemImage: "info.circle")
                    .tag(MacSettingsRoute.about)
            }
            .navigationTitle(L10n.string("设置"))
            .searchable(text: $searchText, prompt: L10n.string("搜索服务商"))
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general:
            MacGeneralSettingsView(model: model)
        case let .automatic(provider):
            MacAutomaticProviderDetail(provider: provider, model: model)
        case let .manual(provider):
            MacManualProviderDetail(provider: provider, model: model)
                .id(provider)
        case .about:
            MacAboutSettingsView(model: model)
        }
    }

    private var filteredPlanProviders: [PlanProviderKind] {
        PlanProviderKind.allCases.filter { provider in
            provider.settingsDisplayName.localizedCaseInsensitiveContains(searchText) || searchText.isEmpty
        }
    }

    private var filteredBillingProviders: [ManualProviderKind] {
        ManualProviderKind.allCases.filter { $0.category == .billing }.filter { provider in
            provider.settingsDisplayName.localizedCaseInsensitiveContains(searchText) || searchText.isEmpty
        }
    }
}

private struct MacGeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section(L10n.string("菜单栏")) {
                Toggle(L10n.string("菜单栏显示百分比"), isOn: $model.showsStatusPercentage)
                Toggle(L10n.string("隐藏 48 小时未更新服务"), isOn: $model.hidesInactiveTools)
            }

            Section(L10n.string("通知与启动")) {
                Toggle(L10n.string("5 小时重置提醒"), isOn: $model.fiveHourResetNotificationsEnabled)
                Toggle(
                    L10n.string("开机自启"),
                    isOn: Binding(
                        get: { model.loginItemEnabled },
                        set: { model.setLoginItem($0) }
                    )
                )
            }

            Section {
                ForEach(Array(model.displayOrder.enumerated()), id: \.element) { index, item in
                    HStack(spacing: 10) {
                        ProviderMark(mark: item.settingsMonogram, tint: item.settingsTint)
                        Text(item.settingsDisplayName)
                        Spacer()
                        Toggle(
                            L10n.string("在主界面显示"),
                            isOn: Binding(
                                get: { model.isDisplayItemVisible(item) },
                                set: { model.setDisplayItemVisible(item, visible: $0) }
                            )
                        )
                        .labelsHidden()
                        .help(L10n.string("在主界面显示"))

                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help(L10n.string("上移"))
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(index == model.displayOrder.count - 1)
                            .help(L10n.string("下移"))
                    }
                    .padding(.vertical, 3)
                }
                .onMove { source, destination in
                    var order = model.displayOrder
                    order.move(fromOffsets: source, toOffset: destination)
                    model.setDisplayOrder(order)
                }
            } header: {
                Text(L10n.string("主界面服务与顺序"))
            } footer: {
                Text(L10n.string("这里只控制此 Mac 的展示，不会停止采集、同步或通知。"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("通用"))
    }

    private func move(_ index: Int, _ offset: Int) {
        let destination = index + offset
        guard model.displayOrder.indices.contains(index), model.displayOrder.indices.contains(destination) else { return }
        var order = model.displayOrder
        order.swapAt(index, destination)
        model.setDisplayOrder(order)
    }
}

private struct MacAutomaticProviderDetail: View {
    let provider: PlanProviderKind
    @ObservedObject var model: AppModel

    private var state: ProviderConnectionState { model.automaticPlanProviderState(provider) }

    var body: some View {
        Form {
            Section {
                ProviderDetailHeader(
                    name: provider.settingsDisplayName,
                    mark: provider.settingsMonogram,
                    tint: provider.settingsTint,
                    state: state
                )
            }

            Section(L10n.string("数据来源")) {
                Text(provider == .chatGPT
                     ? L10n.string("用量由此 Mac 的 Codex CLI 登录自动采集。")
                     : L10n.string("用量由此 Mac 的 Claude Code 登录自动采集。"))
                Text(L10n.string("AgentMeter 不保存或接管登录流程；请先在对应 CLI 中完成登录。"))
                    .foregroundStyle(.secondary)
            }

            if state != .connected {
                Section(L10n.string("下一步")) {
                    Text(provider == .chatGPT
                         ? L10n.string("在终端打开 Codex 并完成登录，然后回到这里重新检测。")
                         : L10n.string("在终端运行 Claude Code 并使用 /login 完成登录，然后回到这里重新检测。"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    Task { await model.collectNow() }
                } label: {
                    Label(L10n.string("重新检测"), systemImage: "arrow.clockwise")
                }
                .disabled(model.isCollecting)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(provider.settingsDisplayName)
    }
}

private struct MacManualProviderDetail: View {
    let provider: ManualProviderKind
    @ObservedObject var model: AppModel

    @State private var state: ProviderConnectionState = .unconfigured
    @State private var enabled = false
    @State private var hasAnyCredential = false
    @State private var hasManualCredential = false
    @State private var region = ProviderRegion.global
    @State private var savedRegion = ProviderRegion.global
    @State private var keyInput = ""
    @State private var teamIDInput = ""
    @State private var message: String?
    @State private var busy = false
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section {
                ProviderDetailHeader(
                    name: provider.settingsDisplayName,
                    mark: provider.settingsMonogram,
                    tint: provider.settingsTint,
                    state: state
                )

                if enabled && hasAnyCredential {
                    Button(L10n.string("暂停采集")) { Task { await setEnabled(false) } }
                        .disabled(busy)
                } else if hasAnyCredential {
                    Button(L10n.string("恢复采集")) { Task { await setEnabled(true) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }

            if provider.category == .codingPlan {
                Section(L10n.string("数据来源")) {
                    Text(L10n.string("优先读取官方 CLI 或 Claude 配置；这里保存的 key 仅作回退。"))
                        .foregroundStyle(.secondary)
                }
            }

            if provider == .openAIAPI || provider == .anthropicAPI {
                Section(L10n.string("权限要求")) {
                    Text(provider == .openAIAPI
                         ? L10n.string("需要组织所有者创建的 OpenAI Admin API key；不显示 ChatGPT 订阅额度。")
                         : L10n.string("需要 Anthropic Admin API key；普通 API key 不可读取组织成本，也不显示 Claude 订阅额度。"))
                }
            }

            Section {
                if provider.supportsRegion {
                    Picker(L10n.string("区域"), selection: $region) {
                        Text(L10n.string("中国大陆")).tag(ProviderRegion.china)
                        Text(L10n.string("国际")).tag(ProviderRegion.global)
                    }
                }

                if provider == .xAI {
                    credentialField("Management Key", placeholder: hasManualCredential ? "已保存，输入新 key 以替换" : "xai-…", text: $keyInput, secure: true)
                    credentialField("Team ID", placeholder: "输入 Team ID", text: $teamIDInput, secure: false)
                } else {
                    credentialField(
                        provider.category == .codingPlan
                            ? "手动回退 API key"
                            : (provider == .openAIAPI || provider == .anthropicAPI ? "Admin API key" : "API key"),
                        placeholder: hasManualCredential ? "已保存，输入新 key 以替换" : provider.settingsPlaceholder,
                        text: $keyInput,
                        secure: true
                    )
                }

                Button {
                    Task { await saveAndVerify() }
                } label: {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(L10n.string("连接并验证"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || busy)

                if state.needsRetry, hasAnyCredential {
                    Button(L10n.string("重新验证")) { Task { await verify() } }
                        .disabled(busy)
                }

                if let message {
                    Label(message, systemImage: state.settingsIcon)
                        .foregroundStyle(state.settingsColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(L10n.string("凭据"))
            } footer: {
                Text(L10n.string("凭据仅保存在此 Mac。跨设备只分发清洗后的用量数据，绝不传输 API key。"))
            }

            if let url = provider.settingsConsoleURL(region: region) {
                Section {
                    Link(destination: url) {
                        Label(L10n.string("打开官方凭据控制台"), systemImage: "arrow.up.right.square")
                    }
                }
            }

            if hasManualCredential {
                Section {
                    Button(role: .destructive) { confirmRemoval = true } label: {
                        Label(
                            provider.category == .codingPlan ? L10n.string("删除回退 key") : L10n.string("移除凭据"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(busy)
                } footer: {
                    Text(L10n.string("只会停止此 Mac 使用这份凭据，不会影响服务商账号或其他设备。"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(provider.settingsDisplayName)
        .task(id: provider) { load() }
        .confirmationDialog(
            provider.category == .codingPlan ? L10n.string("删除手动回退 key？") : L10n.string("移除凭据？"),
            isPresented: $confirmRemoval
        ) {
            Button(provider.category == .codingPlan ? L10n.string("删除回退 key") : L10n.string("移除凭据"), role: .destructive) {
                Task { await removeCredential() }
            }
            Button(L10n.string("取消"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func credentialField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        secure: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(label)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(L10n.string(placeholder), text: text) }
                else { TextField(L10n.string(placeholder), text: text) }
            }
            .font(.system(.body, design: .monospaced))
            .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.vertical, 3)
    }

    private var canSave: Bool {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let regionChanged = provider.supportsRegion && region != savedRegion
        if provider == .xAI {
            return !teamIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (!key.isEmpty || hasManualCredential)
        }
        return !key.isEmpty || (hasManualCredential && regionChanged)
    }

    private func load() {
        resetTransientState()
        if let screenshotState {
            state = screenshotState
            hasAnyCredential = screenshotState != .unconfigured
            hasManualCredential = hasAnyCredential
            enabled = screenshotState != .unconfigured && screenshotState != .disabled
            return
        }
        do {
            hasManualCredential = try manualCredentialExists()
            hasAnyCredential = try anyCredentialExists()
            region = ManualProviderPreferences.region(for: provider)
            savedRegion = region
            enabled = ManualProviderPreferences.isEnabled(provider, credentialExists: hasAnyCredential)
            if provider == .xAI { teamIDInput = try GrokManagementKeyStore.read()?.teamID ?? "" }
            state = !hasAnyCredential ? .unconfigured : (enabled ? model.manualProviderState(provider) : .disabled)
        } catch {
            state = .storageFailure
            message = L10n.string("无法读取此 Mac 保存的凭据。")
        }
    }

    private func resetTransientState() {
        state = .unconfigured
        enabled = false
        hasAnyCredential = false
        hasManualCredential = false
        region = .global
        savedRegion = .global
        keyInput = ""
        teamIDInput = ""
        message = nil
        busy = false
        confirmRemoval = false
    }

    private var screenshotState: ProviderConnectionState? {
        guard ProcessInfo.processInfo.arguments.contains("--agentmeter-screenshot-provider-settings") else { return nil }
        return switch provider {
        case .kimiCode: .unconfigured
        case .glmCoding: .connected
        case .miniMax: .disabled
        case .kimiAPI: .checking
        case .deepSeek: .invalidCredential
        case .openRouter: .pendingVerification(.networkFailure)
        case .xAI: .storageFailure
        case .openAIAPI: .connected
        case .anthropicAPI: .disabled
        }
    }

    private func saveAndVerify() async {
        busy = true
        defer { busy = false }
        do {
            try saveManualCredential()
            hasManualCredential = true
            hasAnyCredential = true
            ManualProviderPreferences.setRegion(region, for: provider)
            savedRegion = region
            ManualProviderPreferences.setEnabled(true, for: provider)
            enabled = true
            await verify(clearInputOnSuccess: true)
        } catch {
            state = .storageFailure
            message = L10n.string("无法把凭据安全保存到此 Mac。")
        }
    }

    private func verify(clearInputOnSuccess: Bool = false) async {
        busy = true
        state = .checking
        message = L10n.string("正在验证并读取数据…")
        defer { busy = false }
        let generation = await ManualProviderOperationGate.shared.begin(provider)
        let result = await model.refreshManualProvider(provider)
        guard await ManualProviderOperationGate.shared.isCurrent(generation, for: provider),
              ManualProviderPreferences.isEnabled(provider, credentialExists: true) else { return }
        state = result
        switch result {
        case .connected:
            if let tool = provider.toolKind,
               model.isDeviceCodingCloudSyncPending(tool) {
                message = L10n.string("已连接，本机数据已更新；正在等待 iCloud 同步。")
            } else {
                message = L10n.string("已连接，数据已更新。")
            }
            if clearInputOnSuccess { keyInput = "" }
        case .invalidCredential: message = L10n.string("凭据无效，请检查后重试。")
        case .pendingVerification: message = L10n.string("凭据已保存，暂时无法验证。")
        case .unconfigured: message = L10n.string("没有找到可用凭据。")
        default: message = result.settingsLabel
        }
    }

    private func setEnabled(_ value: Bool) async {
        busy = true
        defer { busy = false }
        if !value { await ManualProviderOperationGate.shared.invalidate(provider) }
        ManualProviderPreferences.setEnabled(value, for: provider)
        enabled = value
        if value { await verify() }
        else {
            let cloudCleanupComplete = await model.disableManualProvider(provider)
            state = .disabled
            message = cloudCleanupComplete
                ? L10n.string("已停用，凭据仍安全保存在此 Mac。")
                : L10n.string("已停止此 Mac 采集；iCloud 旧快照将在联网后重试清理。")
        }
    }

    private func removeCredential() async {
        busy = true
        defer { busy = false }
        await ManualProviderOperationGate.shared.invalidate(provider)
        do {
            try deleteManualCredential()
            hasManualCredential = false
            keyInput = ""
            teamIDInput = ""
            hasAnyCredential = try anyCredentialExists()
            if provider.category == .codingPlan, hasAnyCredential {
                state = enabled ? await model.refreshManualProvider(provider) : .disabled
                message = L10n.string("已删除手动回退 key；自动配置仍可继续采集。")
            } else {
                ManualProviderPreferences.setEnabled(false, for: provider)
                enabled = false
                let cloudCleanupComplete = await model.disableManualProvider(provider)
                state = .unconfigured
                message = cloudCleanupComplete
                    ? L10n.string("已从此 Mac 移除凭据。")
                    : L10n.string("已移除此 Mac 凭据；iCloud 旧快照将在联网后重试清理。")
            }
        } catch {
            state = .storageFailure
            message = L10n.string("无法移除此 Mac 的凭据。")
        }
    }

    private func anyCredentialExists() throws -> Bool {
        if provider.category == .codingPlan, let tool = provider.toolKind {
            return try MacCodingCredentialResolver.resolve(tool: tool, manualRegion: region) != nil
        }
        return try manualCredentialExists()
    }

    private func manualCredentialExists() throws -> Bool {
        switch provider {
        case .kimiCode: try ProviderCredentialStore.read(kind: .kimiCode)?.isEmpty == false
        case .glmCoding: try ProviderCredentialStore.read(kind: .glmCoding)?.isEmpty == false
        case .miniMax: try ProviderCredentialStore.read(kind: .miniMax)?.isEmpty == false
        case .kimiAPI: try ProviderCredentialStore.read(kind: .kimiAPI)?.isEmpty == false
        case .deepSeek: try DeepSeekKeyStore.read()?.isEmpty == false
        case .openRouter: try OpenRouterKeyStore.read()?.isEmpty == false
        case .xAI: try GrokManagementKeyStore.read() != nil
        case .openAIAPI: try ProviderCredentialStore.read(kind: .openAIAdmin)?.isEmpty == false
        case .anthropicAPI: try ProviderCredentialStore.read(kind: .anthropicAdmin)?.isEmpty == false
        }
    }

    private func saveManualCredential() throws {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .kimiCode: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .kimiCode) }
        case .glmCoding: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .glmCoding) }
        case .miniMax: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .miniMax) }
        case .kimiAPI: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .kimiAPI) }
        case .deepSeek: if !key.isEmpty { try DeepSeekKeyStore.save(apiKey: key) }
        case .openRouter: if !key.isEmpty { try OpenRouterKeyStore.save(apiKey: key) }
        case .xAI:
            guard let merged = ManualProviderCredentialMerge.xAI(
                existing: try GrokManagementKeyStore.read(),
                managementKeyInput: key,
                teamIDInput: teamIDInput
            ) else { throw CredentialError.missing }
            try GrokManagementKeyStore.save(credentials: merged)
        case .openAIAPI: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .openAIAdmin) }
        case .anthropicAPI: if !key.isEmpty { try ProviderCredentialStore.save(key, kind: .anthropicAdmin) }
        }
    }

    private func deleteManualCredential() throws {
        switch provider {
        case .kimiCode: try ProviderCredentialStore.delete(kind: .kimiCode)
        case .glmCoding: try ProviderCredentialStore.delete(kind: .glmCoding)
        case .miniMax: try ProviderCredentialStore.delete(kind: .miniMax)
        case .kimiAPI: try ProviderCredentialStore.delete(kind: .kimiAPI)
        case .deepSeek: try DeepSeekKeyStore.delete()
        case .openRouter: try OpenRouterKeyStore.delete()
        case .xAI: try GrokManagementKeyStore.delete()
        case .openAIAPI: try ProviderCredentialStore.delete(kind: .openAIAdmin)
        case .anthropicAPI: try ProviderCredentialStore.delete(kind: .anthropicAdmin)
        }
    }

    private enum CredentialError: Error { case missing }
}

private struct ProviderSidebarRow: View {
    let name: String
    let mark: String
    let tint: Color
    let state: ProviderConnectionState

    var body: some View {
        HStack(spacing: 9) {
            ProviderMark(mark: mark, tint: tint)
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: state.settingsIcon)
                .foregroundStyle(state.settingsColor)
                .help(state.settingsLabel)
                .accessibilityLabel(state.settingsLabel)
        }
    }
}

private struct ProviderDetailHeader: View {
    let name: String
    let mark: String
    let tint: Color
    let state: ProviderConnectionState

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(mark: mark, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.title2.weight(.semibold))
                Label(state.settingsLabel, systemImage: state.settingsIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(state.settingsColor)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderMark: View {
    let mark: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Text(mark)
            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct MacAboutSettingsView: View {
    private static let githubURL = URL(string: "https://github.com/dothinkerlab/AgentMeter")!
    private static let releasesURL = URL(string: "https://github.com/dothinkerlab/AgentMeter/releases")!
    private static let bugReportURL = URL(
        string: "https://github.com/dothinkerlab/AgentMeter/issues/new?template=bug_report.yml"
    )!
    @ObservedObject var model: AppModel
    @State private var diagnosticDocument = MacDiagnosticDocument(text: "")
    @State private var diagnosticFilename = "AgentMeter-Diagnostics.txt"
    @State private var isExportingDiagnostics = false
    @State private var diagnosticExportError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.string("版本"), value: version)
                Link("GitHub", destination: Self.githubURL)
                Link(L10n.string("手动升级"), destination: Self.releasesURL)
                Link(L10n.string("反馈问题"), destination: Self.bugReportURL)
                Button(action: exportDiagnostics) {
                    Label(L10n.string("导出脱敏诊断"), systemImage: "square.and.arrow.up")
                }
                Text(L10n.string("仅包含同步状态和更新时间，不包含 Token、API Key、Keychain、原始日志或账单金额。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("关于 AgentMeter"))
        .fileExporter(
            isPresented: $isExportingDiagnostics,
            document: diagnosticDocument,
            contentType: .plainText,
            defaultFilename: diagnosticFilename
        ) { result in
            if case .failure(let error) = result {
                diagnosticExportError = error.localizedDescription
            }
        }
        .alert(
            L10n.string("诊断导出失败"),
            isPresented: Binding(
                get: { diagnosticExportError != nil },
                set: { if !$0 { diagnosticExportError = nil } }
            )
        ) {
            Button(L10n.string("好"), role: .cancel) {}
        } message: {
            Text(diagnosticExportError ?? "")
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    private func exportDiagnostics() {
        let report = makeDiagnosticReport()
        diagnosticDocument = MacDiagnosticDocument(text: report.text)
        diagnosticFilename = report.suggestedFilename
        isExportingDiagnostics = true
    }

    private func makeDiagnosticReport() -> AgentMeterDiagnosticReport {
        let localServices = [
            status("DeepSeek", model.deepSeekBalance),
            status("OpenRouter", model.openRouterUsage),
            status("xAI API", model.grokAPIUsage),
            status("Kimi API", model.kimiAPIBalance),
            status("OpenAI API", model.openAIAPIUsage),
            status("Anthropic API", model.anthropicAPIUsage),
        ].compactMap { $0 }

        return AgentMeterDiagnosticReport(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—",
            platform: "Mac",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            snapshots: model.snapshots,
            localServices: localServices,
            cloudSyncPendingTools: model.deviceCodingCloudSyncPendingTools
        )
    }

    private func status(
        _ service: String,
        _ value: DeepSeekBalance?
    ) -> AgentMeterDiagnosticReport.LocalServiceStatus? {
        value.map { .init(service: service, confidence: $0.confidence, staleReason: $0.staleReason, updatedAt: $0.updatedAt) }
    }

    private func status(
        _ service: String,
        _ value: OpenRouterUsage?
    ) -> AgentMeterDiagnosticReport.LocalServiceStatus? {
        value.map { .init(service: service, confidence: $0.confidence, staleReason: $0.staleReason, updatedAt: $0.updatedAt) }
    }

    private func status(
        _ service: String,
        _ value: GrokAPIUsage?
    ) -> AgentMeterDiagnosticReport.LocalServiceStatus? {
        value.map { .init(service: service, confidence: $0.confidence, staleReason: $0.staleReason, updatedAt: $0.updatedAt) }
    }

    private func status(
        _ service: String,
        _ value: KimiAPIBalance?
    ) -> AgentMeterDiagnosticReport.LocalServiceStatus? {
        value.map { .init(service: service, confidence: $0.confidence, staleReason: $0.staleReason, updatedAt: $0.updatedAt) }
    }

    private func status(
        _ service: String,
        _ value: APICostUsage?
    ) -> AgentMeterDiagnosticReport.LocalServiceStatus? {
        value.map { .init(service: service, confidence: $0.confidence, staleReason: $0.staleReason, updatedAt: $0.updatedAt) }
    }
}

private struct MacDiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

private extension PlanProviderKind {
    var settingsDisplayName: String { self == .chatGPT ? "ChatGPT" : self == .claude ? "Claude" : manualProvider!.settingsDisplayName }
    var settingsMonogram: String { self == .chatGPT ? ">_" : self == .claude ? "✱" : manualProvider!.settingsMonogram }
    var settingsTint: Color { self == .chatGPT ? Color(red: 0.06, green: 0.62, blue: 0.45) : self == .claude ? Color(red: 0.82, green: 0.38, blue: 0.23) : manualProvider!.settingsTint }
}

private extension ManualProviderKind {
    var settingsDisplayName: String {
        switch self {
        case .kimiCode: "Kimi Code"
        case .glmCoding: "GLM Coding Plan"
        case .miniMax: "MiniMax Token Plan"
        case .kimiAPI: "Kimi API"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .xAI: L10n.string("xAI API 账单")
        case .openAIAPI: L10n.string("OpenAI API 账单")
        case .anthropicAPI: L10n.string("Anthropic API 账单")
        }
    }
    var settingsPlaceholder: String {
        switch self {
        case .openRouter: "sk-or-v1-…"
        case .xAI: "xai-…"
        case .openAIAPI: "sk-admin-…"
        case .anthropicAPI: "sk-ant-admin-…"
        default: "sk-…"
        }
    }
    var settingsMonogram: String {
        switch self {
        case .kimiCode, .kimiAPI: "K"
        case .glmCoding: "GLM"
        case .miniMax: "MM"
        case .deepSeek: "DS"
        case .openRouter: "OR"
        case .xAI: "xAI"
        case .openAIAPI: "OA"
        case .anthropicAPI: "A"
        }
    }
    var settingsTint: Color {
        switch self {
        case .kimiCode, .kimiAPI: Color(red: 0.12, green: 0.15, blue: 0.20)
        case .glmCoding: Color(red: 0.12, green: 0.38, blue: 0.85)
        case .miniMax: Color(red: 0.43, green: 0.20, blue: 0.82)
        case .deepSeek: Color(red: 0.25, green: 0.36, blue: 0.88)
        case .openRouter: Color(red: 0.36, green: 0.23, blue: 0.82)
        case .xAI: Color(red: 0.12, green: 0.12, blue: 0.13)
        case .openAIAPI: Color(red: 0.04, green: 0.55, blue: 0.42)
        case .anthropicAPI: Color(red: 0.76, green: 0.32, blue: 0.21)
        }
    }
    func settingsConsoleURL(region: ProviderRegion) -> URL? {
        switch (self, region) {
        case (.kimiCode, _): URL(string: "https://www.kimi.com/code/console")
        case (.kimiAPI, _): URL(string: "https://platform.kimi.com/console/api-keys")
        case (.glmCoding, .china): URL(string: "https://open.bigmodel.cn/usercenter/proj-mgmt/apikeys")
        case (.glmCoding, .global): URL(string: "https://z.ai/manage-apikey/apikey-list")
        case (.miniMax, .china): URL(string: "https://platform.minimaxi.com/console/access?tab=api-keys")
        case (.miniMax, .global): URL(string: "https://platform.minimax.io/console/access")
        case (.deepSeek, _): URL(string: "https://platform.deepseek.com/api_keys")
        case (.openRouter, _): URL(string: "https://openrouter.ai/keys")
        case (.xAI, _): URL(string: "https://console.x.ai/home")
        case (.openAIAPI, _): URL(string: "https://platform.openai.com/settings/organization/admin-keys")
        case (.anthropicAPI, _): URL(string: "https://console.anthropic.com/settings/admin-keys")
        }
    }
}

private extension MacDisplayItemID {
    var settingsDisplayName: String {
        switch self {
        case .codex: "ChatGPT"
        case .claudeCode: "Claude"
        case .kimiCode: ManualProviderKind.kimiCode.settingsDisplayName
        case .glmCoding: ManualProviderKind.glmCoding.settingsDisplayName
        case .miniMax: ManualProviderKind.miniMax.settingsDisplayName
        case .openAIAPI: ManualProviderKind.openAIAPI.settingsDisplayName
        case .anthropicAPI: ManualProviderKind.anthropicAPI.settingsDisplayName
        case .kimiAPI: ManualProviderKind.kimiAPI.settingsDisplayName
        case .deepSeek: ManualProviderKind.deepSeek.settingsDisplayName
        case .openRouter: ManualProviderKind.openRouter.settingsDisplayName
        case .xAI: ManualProviderKind.xAI.settingsDisplayName
        }
    }
    var settingsMonogram: String {
        switch self {
        case .codex: ">_"
        case .claudeCode: "✱"
        default: manualProvider!.settingsMonogram
        }
    }
    var settingsTint: Color {
        switch self {
        case .codex: Color(red: 0.06, green: 0.62, blue: 0.45)
        case .claudeCode: Color(red: 0.82, green: 0.38, blue: 0.23)
        default: manualProvider!.settingsTint
        }
    }
}

private extension ProviderConnectionState {
    var settingsLabel: String {
        switch self {
        case .unconfigured: L10n.string("未配置")
        case .disabled: L10n.string("已停用")
        case .checking: L10n.string("验证中")
        case .connected: L10n.string("已连接")
        case .pendingVerification: L10n.string("待验证")
        case .invalidCredential: L10n.string("凭据无效")
        case .storageFailure: L10n.string("读取失败")
        }
    }
    var settingsIcon: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .invalidCredential, .storageFailure: "exclamationmark.triangle.fill"
        case .pendingVerification: "wifi.exclamationmark"
        case .disabled: "pause.circle.fill"
        case .unconfigured: "circle.dashed"
        case .checking: "arrow.triangle.2.circlepath"
        }
    }
    var settingsColor: Color {
        switch self {
        case .connected: .green
        case .invalidCredential, .storageFailure: .red
        case .pendingVerification: .orange
        default: .secondary
        }
    }
    var needsRetry: Bool {
        switch self { case .pendingVerification, .invalidCredential: true; default: false }
    }
}
