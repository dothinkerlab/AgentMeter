import SwiftUI
import AgentMeterCore

struct MacArkPlanSettingsView: View {
    let product: ArkPlanAdapter.Product
    @ObservedObject var controller: MacArkPlanController
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var busy = false
    @State private var message: String?
    @State private var confirmRemoval = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Form {
                Section {
                    Text(BrandPresentation.displayName(for: product.tool)).font(.title2.bold())
                    Text(!controller.isEnabled(product) && controller.status(product).credentialAvailable
                         ? L10n.string("已暂停") : controller.state(product).settingsLabel)
                    if let issue = controller.status(product).message { Text(issue).foregroundStyle(.orange) }
                    if let retry = controller.status(product).retryAt {
                        Text(L10n.format("可于 %@ 后重试", retry.formatted(date: .omitted, time: .standard)))
                    }
                    if let updated = controller.status(product).lastSuccess {
                        Text(L10n.format("上次成功：%@", updated.formatted(date: .abbreviated, time: .standard)))
                    }
                    Text(L10n.string("Access Key 仅保存在此 Mac，跨设备只同步额度快照。个人套餐仅由一台 Mac 发布。"))
                        .foregroundStyle(.secondary)
                    if product == .agent { Text(L10n.string("AFP 是套餐统一额度，不代表 Token 数或人民币金额。")) }
                }
                Section(L10n.string("凭据")) {
                    TextField("Access Key ID", text: $accessKeyID)
                    SecureField("Secret Access Key", text: $secretAccessKey)
                    if controller.status(product).credentialAvailable {
                        Text(L10n.string("凭据已保存在 Keychain；输入新凭据以替换，不回显原值。"))
                    }
                    Text(L10n.string("使用具有套餐查询权限的 Access Key，不是模型调用 API key。建议使用最小只读权限。"))
                        .foregroundStyle(.secondary)
                    Button(L10n.string("连接并验证")) {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                try await controller.save(product, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
                                accessKeyID = ""; secretAccessKey = ""; message = nil
                            } catch { message = L10n.string("无法验证或安全保存凭据，请检查后重试。") }
                        }
                    }.disabled(busy || accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretAccessKey.isEmpty)
                    if let message { Text(message) }
                }
                Section {
                    Button(L10n.string("重新验证")) { Task { busy = true; await controller.refresh(product); busy = false } }
                        .disabled(busy || !controller.isEnabled(product) || !controller.canQuery(product))
                    Button(controller.isEnabled(product) ? L10n.string("暂停采集") : L10n.string("恢复采集")) {
                        Task { busy = true; await controller.setEnabled(!controller.isEnabled(product), product: product); busy = false }
                    }.disabled(busy || (!controller.isEnabled(product) && !controller.canQuery(product)))
                    Text(L10n.string("暂停保留上次额度并停止云端更新；移除凭据才清理本机和云端数据。"))
                        .foregroundStyle(.secondary)
                    switch controller.syncState(product) {
                    case .idle: EmptyView()
                    case .uploadPending:
                        Text(L10n.string("额度已获取，等待上传到 iCloud。"))
                        Button(L10n.string("重试同步")) { Task { busy = true; await controller.retrySync(product); busy = false } }
                            .disabled(busy || !controller.isEnabled(product))
                    case .deletePending:
                        Text(L10n.string("等待从 iCloud 清理旧账号额度。"))
                        Button(L10n.string("重试清理")) { Task { busy = true; await controller.retrySync(product); busy = false } }.disabled(busy)
                    }
                    Link(L10n.string("打开官方凭据控制台"), destination: URL(string: "https://console.volcengine.com/iam/keymanage/")!)
                    Button(L10n.string("移除凭据"), role: .destructive) { confirmRemoval = true }
                        .disabled(busy || !controller.status(product).credentialAvailable)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(BrandPresentation.displayName(for: product.tool))
        .task { controller.loadSettings(product) }
        .confirmationDialog(L10n.string("移除凭据？"), isPresented: $confirmRemoval) {
            Button(L10n.string("移除凭据"), role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await controller.remove(product); message = nil }
                    catch { message = L10n.string("无法移除凭据，请重试。") }
                }
            }
            Button(L10n.string("取消"), role: .cancel) {}
        }
    }
}
