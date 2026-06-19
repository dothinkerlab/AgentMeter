import Foundation
import AgentMeterCore

// 开发顺序第 1 步的验证工具:读 Keychain → 调 /api/oauth/usage → 打印 QuotaSnapshot。
// 这是 go/no-go 关卡。端点不通或 token 取不到,直接暴露问题,不静默吞掉。

func formatSnapshot(_ s: QuotaSnapshot) -> String {
    var lines: [String] = []
    let plan = s.plan.map { " (\($0))" } ?? ""
    lines.append("Tool: \(s.tool.rawValue)\(plan)")
    lines.append("Confidence: \(s.confidence.rawValue)   Source: \(s.source)")

    let rel = RelativeDateTimeFormatter()
    lines.append("Updated: \(rel.localizedString(for: s.updatedAt, relativeTo: Date()))")

    if s.windows.isEmpty {
        lines.append("  (无窗口数据)")
    }
    for w in s.windows {
        let resetIn = w.resetsAt.timeIntervalSinceNow
        let resetStr = resetIn > 0 ? "resets in \(formatDuration(resetIn))" : "reset overdue"
        let bar = progressBar(remaining: w.remainingPercent)
        lines.append(String(
            format: "  %-15@ %@ %5.1f%% left   %@",
            w.kind.rawValue as NSString, bar as NSString, w.remainingPercent, resetStr as NSString
        ))
    }
    if let t = s.tightestWindow {
        lines.append("→ 最紧: \(t.kind.rawValue) — 剩 \(String(format: "%.0f", t.remainingPercent))%")
    }
    return lines.joined(separator: "\n")
}

func progressBar(remaining: Double, width: Int = 10) -> String {
    let filled = Int((remaining / 100 * Double(width)).rounded())
    return String(repeating: "█", count: max(0, filled))
        + String(repeating: "░", count: max(0, width - filled))
}

func formatDuration(_ seconds: TimeInterval) -> String {
    QuotaDurationFormat.short(seconds: seconds)
}

func selectedTool(from arguments: [String] = CommandLine.arguments) -> ToolKind? {
    for (index, arg) in arguments.enumerated() {
        if arg == "--tool", arguments.indices.contains(index + 1) {
            return ToolKind(rawValue: arguments[index + 1])
        }
        if arg.hasPrefix("--tool=") {
            return ToolKind(rawValue: String(arg.dropFirst("--tool=".count)))
        }
    }
    return .claudeCode
}

func usageAndExit() -> Never {
    FileHandle.standardError.write(Data("Usage: agentmeter-probe [--tool claudeCode|codex]\n".utf8))
    exit(64)
}

func fetchSnapshot(tool: ToolKind, credentials: KeychainReader.Credentials) async throws -> QuotaSnapshot {
    switch tool {
    case .claudeCode:
        return try await ClaudeCodeAdapter().fetch(
            accessToken: credentials.accessToken,
            plan: credentials.subscriptionType
        )
    case .codex:
        return try await CodexPlanAdapter().fetch(
            accessToken: credentials.accessToken,
            accountID: credentials.accountID,
            plan: credentials.subscriptionType
        )
    case .openCode:
        throw ProbeError.unsupportedTool(tool.rawValue)
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case unsupportedTool(String)

    var description: String {
        switch self {
        case .unsupportedTool(let tool):
            return "暂不支持 \(tool)"
        }
    }
}

func describeFetchError(_ error: Error) -> String {
    switch error {
    case let e as ClaudeCodeAdapter.FetchError:
        switch e {
        case .unauthorized: return "端点返回 401/403 —— token 可能过期,需重激活"
        case .httpStatus(let code): return "端点返回 HTTP \(code) —— 非官方端点可能已变"
        case .transport(let msg): return "网络失败: \(msg)"
        case .decode(let msg): return "响应解析失败(字段可能变了): \(msg)"
        }
    case let e as CodexPlanAdapter.FetchError:
        switch e {
        case .unauthorized: return "端点返回 401/403 —— token 可能过期,需重激活"
        case .httpStatus(let code): return "端点返回 HTTP \(code) —— 非官方端点可能已变"
        case .transport(let msg): return "网络失败: \(msg)"
        case .decode(let msg): return "响应解析失败(字段可能变了): \(msg)"
        }
    default:
        return "\(error)"
    }
}

// --- 执行 ---

guard let tool = selectedTool() else {
    usageAndExit()
}

let creds: KeychainReader.Credentials
do {
    creds = try KeychainReader.readCredentials(tool: tool)
} catch {
    FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
    exit(1)
}

if let exp = creds.expiresAt {
    let expired = exp < Date()
    let mark = expired ? "⚠️ 已过期" : "有效"
    print("Token: \(mark),expiresAt \(exp)")
    if expired {
        print("  → token 过期,请在对应工具里重新登录/激活后再试。")
    }
}
if let scopes = creds.scopes {
    print("Scopes: \(scopes.joined(separator: ", "))")
}

do {
    let snapshot = try await fetchSnapshot(tool: tool, credentials: creds)
    print("\n========== QuotaSnapshot ==========")
    print(formatSnapshot(snapshot))
    print("===================================")
} catch {
    FileHandle.standardError.write(Data("✗ \(describeFetchError(error))\n".utf8))
    exit(2)
}
