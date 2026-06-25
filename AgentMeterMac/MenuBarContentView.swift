import SwiftUI
import AppKit
import AgentMeterCore

/// 菜单栏弹出面板。视觉按 Claude Design 交付的「方向 C · 极简统一列表」实现:
/// 品牌色左轨 + 细行进度,弹窗高度最小、最贴菜单栏轻量气质。沿用 iOS 设计语言
/// (Codex 墨绿 / Claude 陶土橙)。并按交付的异常状态规范处理:加载骨架、未登录空态、
/// 登录失效(数据陈旧)、接近上限 / 额度耗尽的语义配色。
struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.black.opacity(0.07))
            if showsSettings {
                settingsContent
            } else {
                content
                Divider().overlay(Color.black.opacity(0.07))
                footer
            }
        }
        .frame(width: 320)
    }

    // MARK: - 页眉 / 页脚

    private var header: some View {
        HStack(spacing: 8) {
            if showsSettings {
                Button { showsSettings = false } label: {
                    ZStack {
                        Circle().fill(Color(hex: 0x787880, alpha: 0.1)).frame(width: 24, height: 24)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Color(hex: 0x6C6C70))
                    }
                }
                .buttonStyle(.borderless)
                .help(L10n.string("返回"))

                Text("设置")
                    .font(.system(size: 16, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundColor(Color(hex: 0x1C1C1E))
            } else {
                Text("AgentMeter")
                    .font(.system(size: 16, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundColor(Color(hex: 0x1C1C1E))

                // 同步状态胶囊:脉冲点 + 文案,反映真实的 lastCollectedAt(非伪造)。
                // 近期采集为绿色「刚刚更新」,超过陈旧阈值转琥珀,从未采集则不显示(由加载骨架接管)。
                if let last = model.lastCollectedAt {
                    syncPill(last: last)
                }
            }

            Spacer(minLength: 6)

            if !showsSettings {
                Button { Task { await model.collectNow() } } label: {
                    ZStack {
                        Circle().fill(Color(hex: 0x787880, alpha: 0.1)).frame(width: 24, height: 24)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(hex: 0x6C6C70))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isCollecting)
                .help(L10n.string("立即刷新"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private func syncPill(last: Date) -> some View {
        let fresh = Date().timeIntervalSince(last) <= AppModel.staleThreshold
        let tint = fresh ? Color(hex: 0x34C759) : Color(hex: 0xD98C28)
        HStack(spacing: 4) {
            PulseDot(color: tint, animating: fresh && !model.isCollecting)
            Text(model.isCollecting ? L10n.string("更新中…") : freshnessText(last))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(hex: 0x8E8E93))
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.1)))
    }

    private func freshnessText(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return L10n.string("刚刚更新") }
        return relativeAge(date)
    }

    private var footer: some View {
        HStack {
            Button { showsSettings = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Text(L10n.string("设置"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(hex: 0x3A3A3C))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                    Text("退出")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundColor(Color(hex: 0xC0392B))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - 主体(正常 / 加载 / 空态)

    @ViewBuilder
    private var content: some View {
        let snaps = model.orderedSnapshots()
        if snaps.isEmpty {
            if model.lastCollectedAt == nil {
                LoadingView()
            } else {
                emptyState
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(snaps.enumerated()), id: \.element.tool) { index, snapshot in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.black.opacity(0.07))
                            .frame(height: 0.5)
                            .padding(.leading, 19)
                    }
                    ToolRow(
                        name: displayName(for: snapshot.tool),
                        plan: snapshot.plan,
                        brand: brand(for: snapshot.tool),
                        tool: snapshot.tool,
                        isStale: model.isStale(snapshot),
                        ageText: relativeAge(snapshot.updatedAt),
                        warning: model.isStale(snapshot) ? confidenceHint(snapshot.confidence, tool: snapshot.tool) : nil,
                        windows: orderedWindows(snapshot.windows),
                        resetSummary: resetSummary(snapshot.windows),
                        labelFor: shortLabel
                    )
                }
            }
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: L10n.string("菜单栏显示百分比"),
                detail: L10n.string("关闭后菜单栏只保留状态图标。"),
                isOn: Binding(
                    get: { model.showsStatusPercentage },
                    set: { model.showsStatusPercentage = $0 }
                )
            )

            settingsDivider

            SettingsToggleRow(
                title: L10n.string("开机自启"),
                detail: L10n.string("登录 macOS 后自动启动 AgentMeter。"),
                isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { model.setLoginItem($0) }
                )
            )

            settingsDivider

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("显示顺序"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(hex: 0x6C6C70))
                    Text(L10n.string("排序第一项会作为菜单栏 5 小时剩余额度来源。"))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: 0x8E8E93))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    ForEach(Array(model.orderedTools.enumerated()), id: \.element) { index, tool in
                        ToolOrderRow(
                            name: displayName(for: tool),
                            brand: brand(for: tool),
                            tool: tool,
                            canMoveUp: index > 0,
                            canMoveDown: index < model.orderedTools.count - 1,
                            moveUp: { moveTool(at: index, by: -1) },
                            moveDown: { moveTool(at: index, by: 1) }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var settingsDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func moveTool(at index: Int, by offset: Int) {
        var tools = model.orderedTools
        let target = index + offset
        guard tools.indices.contains(index), tools.indices.contains(target) else { return }
        let tool = tools.remove(at: index)
        tools.insert(tool, at: target)
        model.setToolOrder(tools)
    }

    /// 未登录 / 空状态(规范第 5 种)。无 in-app 登录入口——登录在 Claude Code / Codex CLI 里做,
    /// 这里只给引导文字,不放无动作的假按钮。
    private var emptyState: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Color(hex: 0xECEEF2)).frame(width: 46, height: 46)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(Color(hex: 0x8E8E93))
            }
            .padding(.bottom, 14)

            Text("未连接任何账户")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(Color(hex: 0x1C1C1E))
            Text("在 Claude Code / Codex 登录后即可追踪用量,且本机需登录同一 iCloud 账号。")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: 0x8E8E93))
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 5)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
        .padding(.vertical, 28)
    }

    // MARK: - 窗口排序 / 文案

    private func orderedWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        windows.sorted { rank($0.kind) < rank($1.kind) }
    }

    private func rank(_ kind: WindowKind) -> Int {
        switch kind {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .sevenDayOpus: return 2
        case .sevenDaySonnet: return 3
        case .monthly: return 4
        }
    }

    /// 行底部合并的重置说明:「5 小时 4h59m · 每周 2d0h 后重置」。全部已重置则「均已重置」。
    private func resetSummary(_ windows: [QuotaWindow]) -> String {
        let ordered = orderedWindows(windows)
        let future = ordered.filter { $0.resetsAt.timeIntervalSinceNow > 0 }
        if future.isEmpty { return L10n.string("两个窗口均已重置") }
        let parts = future.map { "\(shortLabel($0.kind)) \(shortDuration($0.resetsAt))" }
        return L10n.format("%@ 后重置", parts.joined(separator: " · "))
    }

    private func displayName(for tool: ToolKind) -> String {
        switch tool {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        }
    }

    private func shortLabel(_ kind: WindowKind) -> String {
        switch kind {
        case .fiveHour: return L10n.string("5 小时")
        case .sevenDay: return L10n.string("每周")
        case .sevenDayOpus: return L10n.string("周Opus")
        case .sevenDaySonnet: return L10n.string("周Sonnet")
        case .monthly: return L10n.string("每月")
        }
    }

    private func confidenceHint(_ c: DataConfidence, tool: ToolKind) -> String {
        switch c {
        case .fresh: return ""
        case .stale: return L10n.format("登录凭证可能已过期,无法刷新用量。请在 %@ 重新登录。", displayName(for: tool))
        case .unknown: return L10n.format("从未成功取到数据。检查是否已登录 %@。", displayName(for: tool))
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func shortDuration(_ date: Date) -> String {
        QuotaDurationFormat.short(until: date)
    }
}

// MARK: - 设置行

private struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1C1C1E))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: 0x8E8E93))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct ToolOrderRow: View {
    let name: String
    let brand: Brand
    let tool: ToolKind
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            BrandMark(tool: tool, brand: brand)

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: 0x1C1C1E))

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                reorderButton(systemName: "chevron.up", enabled: canMoveUp, action: moveUp)
                reorderButton(systemName: "chevron.down", enabled: canMoveDown, action: moveDown)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(hex: 0xF6F7F8))
        )
    }

    private func reorderButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(enabled ? Color(hex: 0x3A3A3C) : Color(hex: 0xC7C7CC))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(enabled ? 1 : 0.55)))
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

// MARK: - 工具行(方向 C)

private struct ToolRow: View {
    let name: String
    let plan: String?
    let brand: Brand
    let tool: ToolKind
    let isStale: Bool
    let ageText: String
    let warning: String?
    let windows: [QuotaWindow]
    let resetSummary: String
    let labelFor: (WindowKind) -> String

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(railColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 0) {
                headerLine

                if let warning {
                    warningBox(warning)
                        .padding(.top, 11)
                }

                VStack(spacing: 7) {
                    ForEach(windows, id: \.kind) { w in
                        WindowLine(label: labelFor(w.kind), remaining: w.remainingPercent, brand: brand)
                    }
                }
                .padding(.top, 11)

                Text(resetSummary)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: 0x9A9AA0))
                    .padding(.top, 8)
            }
            .padding(.init(top: 11, leading: 16, bottom: 13, trailing: 16))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 行左轨颜色反映该工具最紧的状态:陈旧→琥珀,有窗口耗尽→红,接近上限→琥珀,否则品牌色。
    private var railColor: Color {
        if isStale { return Color(hex: 0xD98C28) }
        if windows.contains(where: { $0.remainingPercent <= 0 }) { return Color(hex: 0xC0392B) }
        if windows.contains(where: { $0.remainingPercent <= 10 }) { return Color(hex: 0xD98C28) }
        return brand.solid
    }

    private var headerLine: some View {
        HStack(spacing: 9) {
            BrandMark(tool: tool, brand: brand)

            Text(name)
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.3)
                .foregroundColor(Color(hex: 0x1C1C1E))

            if let plan, !plan.isEmpty {
                Text(plan)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(brand.planColor)
            }

            Spacer(minLength: 6)

            if isStale {
                Text("需重新登录")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: 0xB5731C))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: 0xFBF1DF)))
            } else {
                Circle().fill(Color(hex: 0x34C759)).frame(width: 7, height: 7)
                Text(ageText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0x9A9AA0))
            }
        }
    }

    private func warningBox(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: 0xB5731C))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: 0x8A5A12))
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0xFBF1DF)))
    }
}

/// 一条细行进度:label(定宽) + 进度条 + 百分比(定宽)。按剩余量做语义配色。
private struct WindowLine: View {
    let label: String
    let remaining: Double   // 剩余 %, 0–100
    let brand: Brand

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: 0x6C6C70))
                .frame(width: 44, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * max(0, min(1, remaining / 100)))
                }
            }
            .frame(height: 6)

            Text("\(Int(remaining.rounded()))%")
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundColor(pctColor)
                .frame(width: 32, alignment: .trailing)
        }
    }

    private var severity: Int {
        if remaining <= 0 { return 2 }       // 耗尽
        if remaining <= 10 { return 1 }      // 接近上限
        return 0
    }

    private var fill: Color {
        switch severity {
        case 2: return Color(hex: 0xC0392B)
        case 1: return Color(hex: 0xD98C28)
        default: return brand.solid
        }
    }

    private var track: Color {
        switch severity {
        case 2: return Color(hex: 0xF6E0DA)
        case 1: return Color(hex: 0xF8EAD3)
        default: return brand.track
        }
    }

    private var pctColor: Color {
        switch severity {
        case 2: return Color(hex: 0xC0392B)
        case 1: return Color(hex: 0xB5731C)
        default: return Color(hex: 0x1C1C1E)
        }
    }
}

// MARK: - 同步脉冲点

/// 标题旁的「实时同步」绿点。新鲜时柔和呼吸,陈旧/采集中则静止,带一圈淡光晕。
private struct PulseDot: View {
    let color: Color
    let animating: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay(Circle().stroke(color.opacity(0.18), lineWidth: 2).frame(width: 9, height: 9))
            .opacity(animating && pulse ? 0.4 : 1)
            .onAppear {
                guard animating else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - 加载骨架(规范第 1 种)

private struct LoadingView: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                bar(width: 22, height: 22, radius: 6)
                bar(width: 74, height: 11)
                Spacer()
            }
            bar(height: 6)
            bar(width: 200, height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .opacity(pulse ? 0.45 : 0.9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func bar(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = 999) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(hex: 0xECEDF0))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

// MARK: - 品牌图标 / 色板

private struct BrandMark: View {
    let tool: ToolKind
    let brand: Brand

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: brand.iconGradient,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 22, height: 22)
            mark
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch tool {
        case .codex:
            Text(">_")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        case .claudeCode:
            Sunburst()
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
        case .openCode:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

/// Claude 标记:过中心的四条线(八角星芒)。
private struct Sunburst: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for deg in stride(from: 0.0, to: 180.0, by: 45.0) {
            let rad = deg * .pi / 180
            let dx = cos(rad) * r, dy = sin(rad) * r
            path.move(to: CGPoint(x: c.x - dx, y: c.y - dy))
            path.addLine(to: CGPoint(x: c.x + dx, y: c.y + dy))
        }
        return path
    }
}

/// 每个服务一个品牌色。Codex 墨绿、Claude 陶土橙。
private struct Brand {
    let solid: Color        // 进度条 / 左轨颜色(方向 C 用平涂)
    let iconGradient: [Color]
    let track: Color
    let planColor: Color
}

private func brand(for tool: ToolKind) -> Brand {
    switch tool {
    case .codex:
        return Brand(
            solid: Color(hex: 0x0E9E76),
            iconGradient: [Color(hex: 0x16B083), Color(hex: 0x0C8C68)],
            track: Color(hex: 0xE2F3EC),
            planColor: Color(hex: 0x0A7D5C)
        )
    case .claudeCode:
        return Brand(
            solid: Color(hex: 0xCB6A45),
            iconGradient: [Color(hex: 0xDA7B57), Color(hex: 0xC05F3C)],
            track: Color(hex: 0xF6E9E1),
            planColor: Color(hex: 0xA8482B)
        )
    case .openCode:
        return Brand(
            solid: Color(hex: 0x5B6AD8),
            iconGradient: [Color(hex: 0x6C7BE0), Color(hex: 0x4F5BD0)],
            track: Color(hex: 0xE8EAFB),
            planColor: Color(hex: 0x3A47A8)
        )
    }
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
