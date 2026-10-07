import SwiftUI
import AgentMeterCore

extension TypeSafeFailure {
    var typeSafeMessage: String {
        switch self {
        case .missingCookie: L10n.string("未找到 TypeSafe 会话，请在所选 Chrome 配置中登录，或切换到 Manual。")
        case .accessDenied: L10n.string("无法读取登录凭据，请点击重新连接并允许钥匙串访问。")
        case .invalidCookie: L10n.string("Cookie 格式无效，请粘贴完整 Cookie header，且不要包含换行。")
        case .authExpired: L10n.string("TypeSafe 会话已过期，请重新登录 Chrome 或更新手动 Cookie。")
        case .rateLimited: L10n.string("TypeSafe 请求受限，将在下次刷新时重试。")
        case .challenge: L10n.string("TypeSafe 控制台要求浏览器验证，请在 Chrome 中打开控制台后重试。")
        case .unavailable: L10n.string("TypeSafe 控制台暂时不可用。")
        case .network: L10n.string("无法连接 TypeSafe，已保留上次成功的数据。")
        case .responseChanged: L10n.string("TypeSafe 响应格式已变化，暂时无法读取。")
        }
    }
}

struct MacTypeSafeSettingsView: View {
    @ObservedObject var controller: MacTypeSafeController
    @State private var cookieInput = ""
    @State private var inputFailure: TypeSafeFailure?
    @State private var confirmRemoval = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("TypeSafe API (Jev)").font(.title2.weight(.semibold))
                    Spacer()
                    if controller.checking { ProgressView().controlSize(.small) }
                }
                Toggle(L10n.string("启用 TypeSafe 采集"), isOn: Binding(
                    get: { controller.enabled },
                    set: { value in
                        controller.setEnabled(value)
                        if value { Task { await controller.collect(allowInteraction: true) } }
                    }
                ))
            }
            MacTypeSafeSyncSettingsView(sync: controller.cloudSync,
                snapshot: TypeSafeDisplaySnapshot(controller.usage ?? .init(), paused: !controller.enabled))
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
                    Text("Auto").tag(TypeSafeCookieSource.auto)
                    Text("Manual").tag(TypeSafeCookieSource.manual)
                }
                if controller.source == .auto {
                    Text(L10n.string("Auto 只读 Chrome 的 TypeSafe 登录 Cookie；首次连接可能请求钥匙串授权。后台不会弹出授权窗口。"))
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
                    SecureField("Cookie: …", text: $cookieInput)
                        .font(.system(.body, design: .monospaced))
                    if controller.hasManualCookie {
                        Text(L10n.string("已保存 Cookie；留空可继续使用，输入新值可替换。"))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.string("在控制台账单页打开开发者工具 Network，从已登录请求的 Request Headers 复制完整 Cookie。普通 API key 不适用于此查询。"))
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
                    Label(failure.typeSafeMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if controller.storageFailed {
                    Text(L10n.string("无法把凭据安全保存到此 Mac。")).foregroundStyle(.red)
                } else if controller.state == .connected {
                    Label(L10n.string("已连接，数据已更新。"), systemImage: "checkmark.circle")
                }
            }
            if let usage = controller.usage {
                Section(L10n.string("余额与用量")) { MacTypeSafeUsageDetails(usage: usage) }
            }
            Section {
                Link(L10n.string("打开 TypeSafe 官方账单页"), destination: TypeSafeBillingAdapter.billingURL)
                if controller.hasManualCookie {
                    Button(L10n.string("删除手动 Cookie"), role: .destructive) { confirmRemoval = true }
                }
            } footer: {
                Text(L10n.string("Cookie 与账单仅保留在此 Mac，不进入 iCloud。Auto 不使用手动 Cookie，Manual 不读取浏览器。"))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("TypeSafe API (Jev)")
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
            catch { inputFailure = (error as? TypeSafeFailure) ?? .accessDenied; return }
        }
        controller.setEnabled(true)
        Task { await controller.collect(allowInteraction: true) }
    }
}

struct MacTypeSafeUsageRow: View {
    let usage: TypeSafeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TS").font(.caption.bold()).padding(6)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Text("TypeSafe API (Jev)").font(.headline)
                Spacer()
                if let balance = usage.billing.value?.balance {
                    Text(balance.formatted(.currency(code: "USD").precision(.fractionLength(2...6))))
                        .font(.headline.monospacedDigit())
                } else { Text("—").foregroundStyle(.secondary) }
            }
            MacTypeSafeUsageDetails(usage: usage)
        }
        .padding(12)
    }
}

struct MacTypeSafeUsageDetails: View {
    let usage: TypeSafeUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let billing = usage.billing.value {
                LabeledContent(L10n.string("余额"), value: usd(billing.balance))
                LabeledContent(L10n.string("账单页周期消费"), value: usd(billing.spent))
                if let cycle = billing.cycleLabel { Text(cycle).font(.caption).foregroundStyle(.secondary) }
                if let plan = billing.plan {
                    LabeledContent(L10n.string("套餐"), value: plan.replacingOccurrences(of: "_", with: " ").capitalized)
                }
                ForEach(Array(billing.credits.filter { $0.expiresAt > Date() }.prefix(24).enumerated()), id: \.offset) { _, credit in
                    LabeledContent("Credit", value: "\(usd(credit.remaining)) · \(L10n.string("到期")) \(credit.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                }
                if billing.credits.filter({ $0.expiresAt > Date() }).count > 24 {
                    Text(L10n.string("仅显示前 24 笔有效 Credit。")).font(.caption)
                }
            } else {
                LabeledContent(L10n.string("余额"), value: L10n.string("未知"))
            }
            freshness(usage.billing.updatedAt, failure: usage.billing.failure)
            Divider()
            if let tokens = usage.tokens.value {
                LabeledContent(L10n.string("今日 Token"), value: tokens.todayTokens.formatted())
                LabeledContent(L10n.string("最近 7 天 Token"), value: tokens.sevenDayTokens.formatted())
                LabeledContent(L10n.string("本月 Token"), value: tokens.monthTokens.formatted())
                LabeledContent(L10n.string("本月输入 / 输出"), value: "\(tokens.monthInputTokens.formatted()) / \(tokens.monthOutputTokens.formatted())")
                LabeledContent(L10n.string("本月请求数"), value: tokens.monthRequests.formatted())
            } else {
                LabeledContent(L10n.string("用量"), value: L10n.string("未知"))
            }
            freshness(usage.tokens.updatedAt, failure: usage.tokens.failure)
            Text(L10n.string("按控制台返回记录汇总，数据可能延迟，不代表完整历史；账单页消费与 Token 用量口径不同。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func usd(_ value: Decimal) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
    }

    @ViewBuilder
    private func freshness(_ date: Date?, failure: TypeSafeFailure?) -> some View {
        if let date {
            HStack(spacing: 4) {
                Text(failure != nil || Date().timeIntervalSince(date) > AppModel.staleThreshold
                     ? L10n.string("数据陈旧") : L10n.string("更新时间"))
                Text(date, style: .relative)
            }.font(.caption).foregroundStyle(.secondary)
        }
        if let failure {
            Text(failure.typeSafeMessage).font(.caption).foregroundStyle(.secondary)
        }
    }
}


private struct MacTypeSafeSyncSettingsView: View {
    @ObservedObject var sync: MacTypeSafeSyncController
    let snapshot: TypeSafeDisplaySnapshot
    var body: some View {
        Section(L10n.string("Jev iCloud 同步")) {
            Toggle(L10n.string("同步 Jev 到 iCloud"), isOn: Binding(
                get: { sync.enabled }, set: { sync.setEnabled($0, snapshot: snapshot) }))
            Text(L10n.string("仅同步余额与用量显示数据，Cookie 始终保留在 Mac。请只在一台 Mac 开启。"))
                .font(.caption).foregroundStyle(.secondary)
            if sync.uploading { ProgressView() }
            if sync.failed {
                Text(L10n.string(sync.failureMessage ?? "Jev 同步失败，将自动重试。请检查 iCloud 登录和网络。"))
                    .foregroundStyle(.orange)
            } else if let date = sync.lastUploadedAt {
                Text("\(L10n.string("最近同步")): \(date.formatted())").font(.caption)
            }
            Button(L10n.string("重试同步")) { Task { await sync.flush() } }
        }
    }
}
