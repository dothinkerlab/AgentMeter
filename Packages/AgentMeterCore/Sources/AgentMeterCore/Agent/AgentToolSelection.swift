import Foundation

/// 后台 agent 一次要采集哪些工具的选择逻辑。纯函数(env/args 注入),便于单测。
public enum AgentToolSelection {

    /// 没有任何配置时的缺省:Claude + Codex 都采。
    public static let defaultTools: [ToolKind] = [.claudeCode, .codex]

    /// 解析这次要采集哪些工具。优先级从高到低:
    /// 1. **单工具覆盖**(probe / 旧行为兼容,只采一个):
    ///    env `AGENTMETER_TOOL` 或 `--tool <x>` / `--tool=<x>`。
    /// 2. **多工具**:env `AGENTMETER_TOOLS=claudeCode,codex`(逗号分隔)。
    /// 3. **缺省**:`[.claudeCode, .codex]`。
    ///
    /// 非法 rawValue 忽略;去重保序;若多工具列表全非法则回落缺省。结果非空。
    public static func parseTools(env: [String: String], args: [String] = []) -> [ToolKind] {
        if let single = singleOverride(env: env, args: args) {
            return [single]
        }
        if let raw = env["AGENTMETER_TOOLS"] {
            let tools = dedupe(raw.split(separator: ",").compactMap {
                ToolKind(rawValue: $0.trimmingCharacters(in: .whitespaces))
            })
            if !tools.isEmpty { return tools }
        }
        return defaultTools
    }

    /// 单工具覆盖:env `AGENTMETER_TOOL` 优先于命令行 `--tool`。
    private static func singleOverride(env: [String: String], args: [String]) -> ToolKind? {
        if let value = env["AGENTMETER_TOOL"], let tool = ToolKind(rawValue: value) {
            return tool
        }
        for (index, arg) in args.enumerated() {
            if arg == "--tool", args.indices.contains(index + 1),
               let tool = ToolKind(rawValue: args[index + 1]) {
                return tool
            }
            if arg.hasPrefix("--tool="),
               let tool = ToolKind(rawValue: String(arg.dropFirst("--tool=".count))) {
                return tool
            }
        }
        return nil
    }

    private static func dedupe(_ tools: [ToolKind]) -> [ToolKind] {
        var seen = Set<ToolKind>()
        return tools.filter { seen.insert($0).inserted }
    }
}
