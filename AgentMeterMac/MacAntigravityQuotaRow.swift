import AgentMeterCore
import SwiftUI

extension MacAntigravityFailure {
    var message: String {
        switch self {
        case .missingCLI:
            L10n.string("未找到独立 Antigravity CLI。请先安装 agy。")
        case .unsupportedCLI:
            L10n.string("请安装或更新独立 Antigravity CLI（v1.1.11 或更新版本）。")
        case .signInRequired:
            L10n.string("请在终端运行 agy 并登录个人 Google 账号，然后重新检测。")
        case .slashCommandsDisabled:
            L10n.string("Antigravity CLI 已禁用斜杠命令。请将 disableSlashCommands 设为 false 后重试。")
        case .unverifiedSettings:
            L10n.string("无法确认 Antigravity CLI 的设置。请检查 ~/.gemini/antigravity-cli/settings.json 后重试。")
        case .timedOut:
            L10n.string("Antigravity 额度查询超时。请检查网络后重试。")
        case .commandFailed:
            L10n.string("Antigravity 额度查询失败。请在 agy 中确认 /usage 可用后重试。")
        case .invalidReport:
            L10n.string("Antigravity CLI 未返回可用额度。请检查登录账号及 CLI 版本。")
        }
    }
}

struct MacAntigravityQuotaRow: View {
    let quota: MacAntigravityQuota?
    let failure: MacAntigravityFailure?
    let checking: Bool
    let ageText: String?

    private var isStale: Bool {
        guard let quota else { return false }
        return failure != nil || Date().timeIntervalSince(quota.updatedAt) > AppModel.staleThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("G")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(width: 23, height: 23)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(MacDisplayItemID.antigravity.healthDisplayName).font(.system(size: 14, weight: .bold))
                Spacer(minLength: 4)
                if isStale {
                    Text(L10n.string("数据陈旧"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                if let ageText {
                    Text(ageText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let failure {
                Text(failure.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if quota == nil {
                Text(checking ? L10n.string("检测中") : L10n.string("等待首次额度刷新"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let quota {
                ForEach(Array(quota.groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.system(size: 11, weight: .semibold))
                        ForEach(group.buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 11, leading: 16, bottom: 13, trailing: 16))
    }

    private func bucketRow(_ bucket: MacAntigravityQuota.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bucket.name)
                Spacer(minLength: 0)
                Text(bucket.remainingFraction, format: .percent.precision(.fractionLength(0...1)))
                    .monospacedDigit()
            }
            .font(.system(size: 11))

            ProgressView(value: bucket.remainingFraction)
                .progressViewStyle(.linear)
                .tint(bucket.remainingFraction == 0 ? .red : .blue)
                .accessibilityHidden(true)

            Text(bucket.resetsAt.map { L10n.format("重置时间：%@", $0.formatted(date: .abbreviated, time: .shortened)) }
                 ?? L10n.string("重置时间未知"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
