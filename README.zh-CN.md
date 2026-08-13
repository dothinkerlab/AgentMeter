<div align="center">

# AgentMeter

### 把 AI 编程额度放到手腕上。

[English](README.md) · **中文**

<img src="logo.png" alt="AgentMeter" width="120">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>

---

你离开键盘后，后台的 coding agent 可能还在消耗额度。**AgentMeter** 把编程套餐额度窗口、重置时间和 API 账单状态放到 Apple Watch、iPhone 与 Mac 菜单栏，让你不用回到终端也能随时查看。

它支持 Claude Code、Codex、Cursor、Kimi Code、GLM Coding Plan 和 MiniMax Token Plan 额度，并提供 Cursor Team、DeepSeek、OpenRouter、xAI API、Kimi API、OpenAI API 与 Anthropic API 的设备本地账单数据。AgentMeter 会展示短时滚动窗口、每周限额、月度账期及其他特定周期。

## 下载 AgentMeter

| 平台 | 下载 |
| --- | --- |
| macOS 伴侣 app | [下载已公证的 DMG](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg) |
| 通过 Homebrew 安装 macOS 版 | `brew install --cask dothinkerlab/tap/agentmeter` |
| iPhone + Apple Watch | [在 App Store 下载](https://apps.apple.com/app/id6781480047) |

Mac app 已使用 Developer ID 签名，并通过 Apple 公证。把 **AgentMeter.app** 拖进「应用程序」即可；它会读取本机已有的 Claude Code 与 Codex 凭据，并以只读方式检测 Cursor 登录。历史版本见 [Releases 页面](https://github.com/dothinkerlab/AgentMeter/releases)。

Homebrew 用户可以安装或升级同一份已公证构建：

```sh
brew install --cask dothinkerlab/tap/agentmeter
```

iPhone 和 Apple Watch app 通过 App Store 发布：

<img src="app-store-qr.png" alt="App Store 二维码" width="160">

> Mac 伴侣 app 需要读取本机 Keychain 中的 Claude Code 和 Codex 凭据，这与 App Store 沙盒限制不兼容，因此仅通过已公证的 DMG 分发。

全部功能免费。

## 功能概览

- **随时查看额度**：支持 Apple Watch 表盘组件与 app 视图、iPhone 状态页和 Mac 菜单栏伴侣。
- **适配不同服务商周期**：按各编程套餐实际返回的周期展示剩余额度、重置时间、Codex reset credits 及到期提醒。
- **本地 API 账单**：在服务商 API 支持时展示余额、限额或日/周/月成本。
- **完整的 Mac 管理能力**：可搜索服务商，管理凭据与地区、暂停或恢复采集，并在本机调整服务显示与顺序。
- **可信的数据状态**：刷新失败时明确标记陈旧数据；fresh 数据显示 5 小时窗口耗尽时可选择接收重置提醒。
- **保护隐私的问题反馈**：导出脱敏诊断并提交结构化 Bug Report，无需分享凭据或原始日志。

## 支持的服务

| 数据类型 | 服务商 | 配置与采集 | 展示与同步 |
| --- | --- | --- | --- |
| 编程套餐额度 | Claude Code、Codex、Cursor、Kimi Code、GLM Coding Plan、MiniMax Token Plan | Claude Code、Codex 与 Cursor 使用 Mac 上已有的登录；其他套餐可分别在 Mac 或 iPhone 配置。 | 清洗后的额度快照可通过你的私有 CloudKit 数据库同步到 iPhone 与 Apple Watch。 |
| 本地 API 余额与账单 | Cursor Team、DeepSeek、OpenRouter、xAI API、Kimi API、OpenAI API、Anthropic API | 凭据留在本机 Keychain；Cursor Team 需要 Admin API key。 | 账单记录不会进入 CloudKit；Cursor Team 成员身份与金额仅留在 Mac。 |

OpenAI API 和 Anthropic API 展示的是组织级开发者 API 成本，不是 ChatGPT 或 Claude 网页/App 订阅用量。xAI API 账单需要 Management Key 与 Team ID。

## 截图

<table>
  <tr>
    <td align="center" valign="center"><img src="screenshots/iphone.png" alt="iPhone" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/mac.png" alt="Mac 菜单栏" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/watch.png" alt="Apple Watch" height="300"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>iPhone</b></sub></td>
    <td align="center"><sub><b>Mac 菜单栏</b></sub></td>
    <td align="center"><sub><b>Apple Watch</b></sub></td>
  </tr>
</table>

## 工作原理

1. **Mac 菜单栏伴侣 app** 在本机读取已有的 Claude Code、Codex 与 Cursor 登录；Cursor 数据库以只读方式打开，AgentMeter 不刷新 token、也不修改 Cursor 数据。Kimi Code、GLM Coding Plan 和 MiniMax Token Plan 可分别在 Mac 与 iPhone 配置。
2. 每台设备只使用本机凭据查询对应服务商。
3. 编程套餐采集器只把**清洗后的额度快照**写入你的私有 iCloud 数据库，包括工具和订阅档位、百分比窗口及类型、重置时间、Codex reset credit 的可用数量和授予/到期时间，以及 confidence、stale reason、采集设备、source 和更新时间。
4. 你的 **Apple Watch** 和 **iPhone** 从 iCloud 读取这些快照，并展示给你。

本地 API 账单采用独立的数据路径：凭据与账单记录不会写入 CloudKit。Apple Watch 不会拿到服务商 token，也不会直连任何服务商。iPhone 只会连接你在该设备上明确配置的服务商，并使用始终留在本机 Keychain 中的凭据。

## 隐私

AgentMeter 采用“本机 token + 私有 iCloud 同步”的设计：

- OAuth token 只保存在你的 **Mac Keychain**。
- token 只由 Mac 伴侣 app 在你的 Mac 本机用于刷新额度。
- token **绝不发送给我们**，也**绝不写入 iCloud**。
- 手动输入的编程套餐与账单凭据只存在本机 Keychain，并明确关闭 iCloud Keychain 同步和加密备份迁移。
- Cursor Team 的成员身份与金额只留在持有 Admin API key 的 Mac；其他账单记录只留在本机，不会进入 CloudKit 额度快照。
- CloudKit 同步记录只包含清洗后的编程套餐状态：工具和订阅档位；百分比窗口、类型与重置时间；Codex reset credit 的可用数量和授予/到期时间；confidence、stale reason、采集设备、source 与更新时间。绝不包含服务商凭据或上游 reset credit ID。
- 如果数据无法刷新，AgentMeter 会明确标记为**陈旧**。
- 脱敏诊断只会在你主动导出时生成，采用明确的字段白名单，不包含 Token、API Key、Keychain 内容、设备名称、原始日志、服务商原始响应或账单金额。

## 故障排查与问题反馈

如果 Mac、iPhone 与 Apple Watch 显示不一致，请先比较各受影响设备上的**更新时间**。

1. 在 Mac 打开**设置 → 关于 AgentMeter → 导出脱敏诊断**，或在 iPhone 打开**设置 → App 信息**导出脱敏诊断。
2. 打开结构化 [Bug Report 表单](https://github.com/dothinkerlab/AgentMeter/issues/new?template=bug_report.yml)。
3. 填写复现步骤和各设备的更新时间，并附上导出的诊断文件。

诊断报告包含 app 版本与构建号、系统版本、编程套餐窗口与重置状态、更新时间、本地账单服务状态和待写入 CloudKit 的项目；**不包含**凭据、Keychain 内容、设备名称、原始日志、服务商原始响应或账单金额。提交前仍请检查你添加的截图和文字。

## 系统要求

- Mac 伴侣 app 需要 macOS 13 或更高版本。
- iPhone / Apple Watch app 需从 [App Store](https://apps.apple.com/app/id6781480047) 安装。
- Mac、iPhone 和 Apple Watch 需使用同一个 Apple ID 开启 iCloud。
- Mac 上已登录 Claude Code、Codex 或 Cursor；Cursor Team 需要 Team/Enterprise 管理员创建的 Admin API key，其他账单来源需在各设备单独输入凭据。

---

<div align="center">

让 AI 编程额度在 Mac、iPhone 与 Apple Watch 上始终可见。

© 2026 dothinker lab · [Releases](https://github.com/dothinkerlab/AgentMeter/releases)

</div>

---

## 从源码构建

本仓库包含 macOS 伴侣 app（`AgentMeterMac`）和共享核心包（`AgentMeterCore`）的源码。iPhone 和 Apple Watch app 通过 App Store 分发，不包含在本仓库中。

运行核心测试：

```sh
cd Packages/AgentMeterCore
swift test
```

生成并打开 Xcode 工程：

```sh
xcodegen generate
open AgentMeter.xcodeproj
```

仓库里的 `DEVELOPMENT_TEAM` 和 iCloud 容器 ID 是维护者本人的。如果你 fork，请在 [`project.yml`](project.yml) 和 [`AgentMeterMac/AgentMeterMac.entitlements`](AgentMeterMac/AgentMeterMac.entitlements) 里改成你自己的 Apple Developer Team 和 CloudKit 容器。

## 维护者发布验收

每次公开发布 Mac 新版，都必须与通过 TestFlight 安装的实际 iPhone 构建完成端到端
验收。请执行强制的 [Mac + iPhone 联合发布检查清单](docs/RELEASE_CHECKLIST.zh-CN.md)，
其中包括 CloudKit Production Schema 检查，以及从最终下载 DMG 安装后的真包测试。

## 许可证

[MIT](LICENSE.md) © 2026 dothinker lab。

---

## 免责声明

AgentMeter 从 Claude Code、Codex 与 [Cursor Dashboard](https://github.com/Noisemaker111/openusage-opencode/blob/main/docs/providers/cursor.md) 的**非官方、未公开**端点读取额度数据，这些端点可能随时变动或失效；Cursor Team 使用 Cursor [官方 Admin API](https://docs.cursor.com/en/account/teams/admin-api)，并要求管理员创建 key。其他集成使用各服务商 API，也可能发生变化。使用这些服务可能受各自服务商的服务条款约束，请自行承担风险。

AgentMeter 为独立项目，**与文中列出的任何服务商均无隶属、背书或赞助关系**。所有服务商与产品名称均为各自权利人的商标。
