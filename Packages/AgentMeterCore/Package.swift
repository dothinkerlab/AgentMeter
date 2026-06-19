// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMeterCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "AgentMeterCore", targets: ["AgentMeterCore"]),
        .executable(name: "agentmeter-probe", targets: ["agentmeter-probe"]),
    ],
    targets: [
        // 共享核心:模型 + 取数解析。Mac/iPhone/Watch 共用,不含平台特定代码。
        .target(
            name: "AgentMeterCore"
        ),
        // 命令行验证工具(开发顺序第 1 步):读 Keychain → 调端点 → 打印 snapshot。
        // 含 macOS 专属的 KeychainReader,不属于跨平台的 Core。
        .executableTarget(
            name: "agentmeter-probe",
            dependencies: ["AgentMeterCore"]
        ),
        .testTarget(
            name: "AgentMeterCoreTests",
            dependencies: ["AgentMeterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
