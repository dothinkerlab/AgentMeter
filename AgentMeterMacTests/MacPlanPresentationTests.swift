import XCTest
import AppKit
import SwiftUI
import AgentMeterCore
@testable import AgentMeter

@MainActor
final class MacPlanPresentationTests: XCTestCase {
    func testOfflineArkSettingsAndQuotaCardRender() async throws {
        let name = "ArkPresentation.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let deps = MacArkPlanController.Dependencies(read: { _ in nil }, write: { _, _ in }, remove: { _ in },
            fetch: { _, _ in throw ArkPlanAdapter.FetchError.transport }, publish: { _ in }, delete: { _ in })
        let controller = MacArkPlanController(defaults: defaults, dependencies: deps)
        try await render(MacArkPlanSettingsView(product: .agent, controller: controller),
                   size: NSSize(width: 720, height: 840), name: "agentmeter-ark-settings")
        let windows: [QuotaWindow] = [.init(usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), kind: .fiveHour),
            .init(usedPercent: 30, resetsAt: nil, kind: .daily),
            .init(usedPercent: 40, resetsAt: Date().addingTimeInterval(86400), kind: .sevenDay),
            .init(usedPercent: 50, resetsAt: nil, kind: .monthly)]
        let row = ToolRow(name: "Ark Agent Plan", plan: "Large", brand: brand(for: .arkAgent), tool: .arkAgent,
            isStale: true, staleLabel: "Paused", ageText: "10 min ago", warning: nil, windows: windows,
            resetSummary: "", resetCredits: nil, labelFor: { QuotaWindowLabel.string(for: $0, style: .short) })
        try await render(row, size: NSSize(width: 390, height: 310), name: "agentmeter-ark-quota-card")
    }
    private func render<V: View>(_ root: V, size: NSSize, name: String) async throws {
        let host = NSHostingView(rootView: root.padding().frame(width: size.width, height: size.height).background(Color.white).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        window.close()
    }
}
