import SwiftUI
import AgentMeterCore

extension PerplexityFailure {
    var perplexityMessage: String {
        switch self {
        case .missingCookie: L10n.string("未找到 Perplexity 会话，请在所选 Chrome 配置中登录，或切换到 Manual。")
        case .accessDenied: L10n.string("无法读取登录凭据，请点击重新连接并允许钥匙串访问。")
        case .invalidCookie: L10n.string("Cookie 格式无效，请粘贴 Cookie header 或 session token，且不要包含换行。")
        case .authExpired: L10n.string("Perplexity 会话已过期，请重新登录 Chrome 或更新手动 Cookie。")
        case .rateLimited: L10n.string("Perplexity 请求受限，将在下次刷新时重试。")
        case .challenge: L10n.string("Perplexity 网页要求浏览器验证，请在 Chrome 中打开账户用量页后重试。")
        case .unavailable: L10n.string("Perplexity 网页暂时不可用。")
        case .network: L10n.string("无法连接 Perplexity，已保留上次成功的数据。")
        case .responseChanged: L10n.string("Perplexity 响应格式已变化，暂时无法读取。")
        }
    }
}

struct MacPerplexitySettingsView: View {
    @ObservedObject var controller: MacPerplexityController
    @State private var cookieInput = ""
    @State private var inputFailure: PerplexityFailure?
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.string("Perplexity 账户积分")).font(.title2.weight(.semibold))
                    Spacer()
                    if controller.checking { ProgressView().controlSize(.small) }
                }
                Toggle(L10n.string("启用 Perplexity 采集"), isOn: Binding(
                    get: { controller.enabled },
                    set: { value in
                        controller.setEnabled(value)
                        if value { Task { await controller.collect(allowInteraction: true) } }
                    }
                ))
            }
            MacPerplexitySyncSettingsView(sync: controller.cloudSync,
                snapshot: PerplexityDisplaySnapshot(controller.usage ?? .init(), paused: !controller.enabled))
            Section(L10n.string("登录来源")) {
                Picker(L10n.string("来源"), selection: Binding(
                    get: { controller.source },
                    set: { value in
                        inputFailure = nil
                        cookieInput = ""
                        controller.setSource(value)
                        Task { await controller.loadSettings(); await controller.collect() }
                    }
                )) {
                    Text("Auto").tag(PerplexityCookieSource.auto)
                    Text("Manual").tag(PerplexityCookieSource.manual)
                }
                if controller.source == .auto {
                    Text(L10n.string("Auto 只读 Chrome 的 Perplexity 登录 Cookie；首次连接可能请求钥匙串授权。后台不会弹出授权窗口。"))
                        .foregroundStyle(.secondary)
                    if controller.profiles.count > 1 || !controller.profileID.isEmpty {
                        Picker(L10n.string("Chrome 配置"), selection: Binding(
                            get: { controller.profileID },
                            set: { value in
                                controller.setProfile(value)
                                Task { await controller.collect() }
                            }
                        )) {
                            if !controller.profiles.contains(where: { $0.id == controller.profileID }) {
                                Text(L10n.string("原 Chrome 配置不可用")).tag(controller.profileID)
                            }
                            ForEach(controller.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                    }
                    Button(L10n.string("重新检测 Chrome 配置")) {
                        Task { await controller.loadSettings() }
                    }
                    .disabled(!controller.enabled)
                } else {
                    SecureField("Cookie / session token", text: $cookieInput)
                        .font(.system(.body, design: .monospaced))
                    if controller.hasManualCookie {
                        Text(L10n.string("已保存 Cookie；留空可继续使用，输入新值可替换。"))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.string("在账户用量页打开开发者工具 Network，从已登录请求的 Request Headers 复制完整 Cookie。普通 API key 不适用于此查询。"))
                        .foregroundStyle(.secondary)
                }
                Button(controller.source == .manual && !cookieInput.isEmpty
                       ? L10n.string("保存并连接") : L10n.string("重新连接")) {
                    connect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.checking || (controller.source == .manual
                    && cookieInput.isEmpty && !controller.hasManualCookie))
                if let failure = inputFailure ?? controller.usage?.failure {
                    Label(failure.perplexityMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if controller.storageFailed {
                    Text(L10n.string("无法把凭据安全保存到此 Mac。")).foregroundStyle(.red)
                } else if controller.state == .connected {
                    Label(L10n.string("已连接，数据已更新。"), systemImage: "checkmark.circle")
                }
            }
            if let usage = controller.usage {
                Section(L10n.string("账户积分")) { MacPerplexityUsageDetails(snapshot: .init(usage, paused: !controller.enabled)) }
            }
            Section {
                Link(L10n.string("打开 Perplexity 账户用量页"), destination: PerplexityCreditsAdapter.usageURL)
                if controller.hasManualCookie {
                    Button(L10n.string("删除手动 Cookie"), role: .destructive) { confirmRemoval = true }
                }
            } footer: {
                Text(L10n.string("Cookie 仅保留在此 Mac；开启同步后，积分显示数据进入 iCloud。Auto 不使用手动 Cookie，Manual 不读取浏览器。"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Perplexity 账户积分"))
        .task { await controller.loadSettings() }
        .confirmationDialog(L10n.string("删除手动 Cookie？"), isPresented: $confirmRemoval) {
            Button(L10n.string("删除手动 Cookie"), role: .destructive) {
                do { try controller.deleteManualCookie(); inputFailure = nil; cookieInput = "" }
                catch { inputFailure = .accessDenied }
            }
        }
    }

    private func connect() {
        inputFailure = nil
        if controller.source == .manual, !cookieInput.isEmpty {
            do { try controller.saveManualCookie(cookieInput); cookieInput = "" }
            catch { inputFailure = (error as? PerplexityFailure) ?? .accessDenied; return }
        }
        controller.setEnabled(true)
        Task { await controller.collect(allowInteraction: true) }
    }
}

struct MacPerplexityUsageRow: View {
    let snapshot: PerplexityDisplaySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("P").font(.caption.bold()).padding(6)
                    .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text(L10n.string("Perplexity 账户积分")).font(.headline)
                Spacer()
                if snapshot.isStale() { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            MacPerplexityUsageDetails(snapshot: snapshot)
        }.padding(12)
    }
}

struct MacPerplexityUsageDetails: View {
    let snapshot: PerplexityDisplaySnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let credits = snapshot.credits {
                pool("周期积分", credits.recurring, dateLabel: "续期")
                pool("购买积分", credits.purchased, dateLabel: "到期")
                pool("奖励积分", credits.bonus, dateLabel: "到期")
            } else { Text(L10n.string("暂无数据")).foregroundStyle(.secondary) }
            Text(L10n.string("分池消耗按总消耗推算，顺序为周期、购买、奖励；积分不是 API 美元余额。"))
                .font(.caption).foregroundStyle(.secondary)
            if let date = snapshot.updatedAt {
                HStack {
                    Text(L10n.string(snapshot.isStale() ? "数据陈旧" : "更新时间"))
                    Text(date, style: .relative)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.paused { Text(L10n.string("Mac 已暂停 Perplexity 采集")).font(.caption) }
            if let failure = snapshot.failure { Text(failure.perplexityMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func pool(_ name: String, _ value: PerplexityCreditPool, dateLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(L10n.string(name)).font(.caption)
                Spacer()
                Text("\(value.remaining.formatted()) / \(value.total.formatted()) · \(Int((100 - value.usedPercent).rounded()))%")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: 100 - value.usedPercent, total: 100).tint(.teal)
            if let date = value.date {
                Text("\(L10n.string(dateLabel)): \(date.formatted())").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MacPerplexitySyncSettingsView: View {
    @ObservedObject var sync: MacPerplexitySyncController
    let snapshot: PerplexityDisplaySnapshot
    var body: some View {
        Section(L10n.string("Perplexity iCloud 同步")) {
            Toggle(L10n.string("同步 Perplexity 到 iCloud"), isOn: Binding(
                get: { sync.enabled }, set: { sync.setEnabled($0, snapshot: snapshot) }))
            Text(L10n.string("仅同步积分显示数据，Cookie 始终保留在 Mac。请只在一台 Mac 开启。"))
                .font(.caption).foregroundStyle(.secondary)
            if sync.uploading { ProgressView() }
            if sync.failed {
                Text(L10n.string(sync.failureMessage ?? "Perplexity 同步失败，将自动重试。请检查 iCloud 登录和网络。"))
                    .foregroundStyle(.orange)
            } else if let date = sync.lastUploadedAt {
                Text("\(L10n.string("最近同步")): \(date.formatted())").font(.caption)
            }
            Button(L10n.string("重试同步")) { Task { await sync.flush() } }
        }
    }
}
