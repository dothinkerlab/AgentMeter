import SwiftUI
import AppKit
import Combine
import AgentMeterCore

/// Mac 菜单栏 app:既采集(读 Keychain → 调端点 → 写 CloudKit 给手表)又显示。
/// 非沙盒、Hardened Runtime。"绝不直连端点"等约束都在 Core 的 QuotaCollector 里守。
///
/// 菜单栏用 AppKit 的 `NSStatusItem` + `NSPopover`,不用 SwiftUI 的
/// `MenuBarExtra(.window)`:后者把带文字的 label 栅格化成非 template 图,在深色菜单栏/
/// 深色壁纸上会渲染成黑块;且 `.window` 弹窗会随内容(尤其重复动画)反复重新定位而"飘移"。
/// `NSStatusItem` 的 button image 设 `isTemplate = true` 能正确随外观反色;`NSPopover`
/// 锚定在按钮上,内容尺寸变化就地缩放、不漂移。
@main
struct AgentMeterMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 纯菜单栏 agent(LSUIElement),不需要主窗口。Settings 场景满足 App 协议但不会自动开窗。
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()

        // 模型每次发布(采集完成 / 登录项变化)就刷新菜单栏 label 的 % 和图标。
        // receive(on:) 把回调推到下一轮 runloop,确保读到的是变更后的值(objectWillChange 在变更前触发)。
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshButton() }
            .store(in: &cancellables)

        model.start()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item
        refreshButton()
    }

    private func setUpPopover() {
        popover.behavior = .transient   // 点击别处自动收起
        let hosting = NSHostingController(rootView: MenuBarContentView(model: model))
        hosting.sizingOptions = [.preferredContentSize]   // 弹窗随 SwiftUI 内容高度就地缩放
        popover.contentViewController = hosting
    }

    /// 刷新菜单栏图标 + 文字。两种图标都 `isTemplate = true`,随菜单栏外观自动反色(深色壁纸/深色模式不发黑)。
    /// 正常态用定制的「仪表」模板图;陈旧/无数据回落到 SF Symbol(感叹三角等)。
    private func refreshButton() {
        guard let button = statusItem?.button else { return }
        button.title = " \(model.statusText)"
        button.image = healthy ? meterTemplateImage() : symbolImage(model.statusSymbol)
    }

    /// 有首选快照且未陈旧 = 正常态,用仪表模板图。
    private var healthy: Bool {
        guard let snapshot = model.preferredSnapshot else { return false }
        return !model.isStale(snapshot)
    }

    private func meterTemplateImage() -> NSImage? {
        let image = NSImage(named: "MenuBarMeterTemplate")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AgentMeter")
        image?.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // 激活并把弹窗设为 key,内部的开关/刷新按钮才能立刻接收点击。
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
