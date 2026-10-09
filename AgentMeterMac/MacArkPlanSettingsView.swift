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
        Form {
            Section {
                Text(BrandPresentation.displayName(for: product.tool)).font(.title2.bold())
                Text(controller.state(product).settingsLabel)
                Text(L10n.string("查询个人版套餐额度。Access Key 仅保存在此 Mac；iPhone 和 Watch 通过 iCloud 查看清洗后的额度。"))
                    .foregroundStyle(.secondary)
            }
            Section(L10n.string("凭据")) {
                TextField("Access Key ID", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                Text(L10n.string("使用具有套餐查询权限的 Access Key，不是模型调用 API key。建议使用最小只读权限。"))
                    .foregroundStyle(.secondary)
                Button(L10n.string("连接并验证")) {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await controller.save(product, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
                            accessKeyID = ""; secretAccessKey = ""
                            message = controller.state(product).settingsLabel
                        } catch { message = L10n.string("无法验证或安全保存凭据，请检查后重试。") }
                    }
                }.disabled(busy || accessKeyID.isEmpty || secretAccessKey.isEmpty)
                if let message { Text(message) }
            }
            Section {
                Button(L10n.string("重新验证")) { Task { busy = true; await controller.refresh(product); busy = false } }
                    .disabled(busy || !controller.isEnabled(product))
                Button(controller.isEnabled(product) ? L10n.string("暂停采集") : L10n.string("恢复采集")) {
                    Task { busy = true; await controller.setEnabled(!controller.isEnabled(product), product: product); busy = false }
                }.disabled(busy)
                if controller.pending.contains(product.tool) {
                    Text(L10n.string("正在等待 iCloud 同步或清理旧快照。"))
                }
                Link(L10n.string("打开官方凭据控制台"), destination: URL(string: "https://console.volcengine.com/iam/keymanage/")!)
                Button(L10n.string("移除凭据"), role: .destructive) { confirmRemoval = true }.disabled(busy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(BrandPresentation.displayName(for: product.tool))
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
