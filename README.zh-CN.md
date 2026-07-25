<div align="center">

# AgentMeter

### 把 AI 编程额度放到手腕上。

[English](README.md) · **中文**

<img src="logo.png" alt="AgentMeter" width="120">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>

---

你离开键盘后，后台的 coding agent 可能还在消耗额度。**AgentMeter** 把 Claude Code、Codex、Kimi Code、GLM Coding Plan 和 MiniMax Token Plan 的额度状态放到你几秒内就能看到的地方：Apple Watch、iPhone 和 Mac 菜单栏。Mac 伴侣 app 还可以显示 DeepSeek、OpenRouter、xAI API、Kimi API、OpenAI API 与 Anthropic API 的设备本地账单数据。

它会显示当前 **5 小时窗口**和**每周窗口**的剩余额度百分比，以及各自的重置时间。不用回到终端里翻状态。

## 下载 AgentMeter

| 平台 | 下载 |
| --- | --- |
| macOS 伴侣 app | [下载已公证的 DMG](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg) |
| iPhone + Apple Watch | [在 App Store 下载](https://apps.apple.com/app/id6781480047) |

Mac app 已使用 Developer ID 签名，并通过 Apple 公证。把 **AgentMeter.app** 拖进「应用程序」即可；首次启动时，它会请求读取本机已保存的 Claude Code 和 Codex 凭据。历史版本见 [Releases 页面](https://github.com/dothinkerlab/AgentMeter/releases)。

iPhone 和 Apple Watch app 通过 App Store 发布：

<img src="app-store-qr.png" alt="App Store 二维码" width="160">

> Mac 伴侣 app 需要读取本机 Keychain 中的 Claude Code 和 Codex 凭据，这与 App Store 沙盒限制不兼容，因此仅通过已公证的 DMG 分发。

## 功能概览

- **Apple Watch 表盘组件与 app 视图**：抬腕查看额度状态。
- **iPhone 状态页**：需要更大视图时查看完整快照。
- **Mac 菜单栏伴侣**：负责采集额度，也能在本机显示状态。
- **独立服务商设置窗口**：可在 Mac 本机调整主界面服务的显示与顺序，不会停止采集或同步。
- **更多编程套餐**：支持各设备单独配置 Kimi Code、GLM Coding Plan 和 MiniMax Token Plan。
- **DeepSeek 本地余额**：在 Mac 查看总余额以及赠金、充值余额拆分。
- **OpenRouter 本地用量**：查看今日、本周、本月消费和可选的 API key 限额。
- **xAI API 本地账单**：查看日、周、月消费、预付余额与月度后付限额。
- **更多本地账单**：查看 Kimi API 余额，以及 OpenAI API、Anthropic API 组织级今日、本周和本月成本。
- **多窗口追踪**：同时关注短周期窗口和每周额度。
- **5 小时重置提醒**：fresh 数据显示额度用尽时，由 Mac 伴侣 app 在预计重置时间提醒。
- **Codex reset credits 与到期提醒**：临时 credits 可用时展示余额和到期时间。
- **陈旧数据提醒**：刷新失败时明确标记数据陈旧，而不是悄悄显示旧值。

## 截图

<table>
  <tr>
    <td align="center" valign="center"><img src="screenshots/watch.png" alt="Apple Watch" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/iphone.png" alt="iPhone" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/mac.png" alt="Mac 菜单栏" height="300"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Apple Watch</b></sub></td>
    <td align="center"><sub><b>iPhone</b></sub></td>
    <td align="center"><sub><b>Mac 菜单栏</b></sub></td>
  </tr>
</table>

## 工作原理

1. **Mac 菜单栏伴侣 app** 从本机 Keychain 读取你已有的 Claude Code 和 Codex 凭据；Kimi Code、GLM Coding Plan 和 MiniMax Token Plan 可分别在 Mac 与 iPhone 配置。
2. 每台设备只使用本机凭据查询对应服务商。
3. 编程套餐采集器只把**清洗后的额度快照**写入你的私有 iCloud 数据库，包括工具和订阅档位、百分比窗口及类型、重置时间、Codex reset credit 的可用数量和授予/到期时间，以及 confidence、stale reason、采集设备、source 和更新时间。
4. 你的 **Apple Watch** 和 **iPhone** 从 iCloud 读取这些快照，并展示给你。

DeepSeek、OpenRouter、xAI API、Kimi API、OpenAI API 与 Anthropic API 账单刻意采用独立本地旁路，各设备需要单独配置凭据。凭据与账单记录不会写入 CloudKit；iPhone 只会把清洗后的显示快照发送给本机 Widget 和配对 Apple Watch，服务商凭据绝不离开 iPhone Keychain。xAI API 账单需要 Management Key + Team ID；OpenAI API 和 Anthropic API 展示的是组织级开发者 API 成本，不是 ChatGPT 或 Claude 网页/App 订阅用量。

Apple Watch 不会拿到服务商 token，也不会直连任何服务商。iPhone 只会连接你在该设备上明确配置的服务商，并使用始终留在本机 Keychain 中的凭据。

## 隐私

AgentMeter 采用“本机 token + 私有 iCloud 同步”的设计：

- OAuth token 只保存在你的 **Mac Keychain**。
- token 只由 Mac 伴侣 app 在你的 Mac 本机用于刷新额度。
- token **绝不发送给我们**，也**绝不写入 iCloud**。
- 手动输入的编程套餐与账单凭据只存在本机 Keychain，并明确关闭 iCloud Keychain 同步和加密备份迁移。
- DeepSeek、OpenRouter、xAI API、Kimi API、OpenAI API 与 Anthropic API 的账单记录只留在本机，不会进入 CloudKit 额度快照。
- CloudKit 同步记录只包含清洗后的编程套餐状态：工具和订阅档位；百分比窗口、类型与重置时间；Codex reset credit 的可用数量和授予/到期时间；confidence、stale reason、采集设备、source 与更新时间。绝不包含服务商凭据或上游 reset credit ID。
- 如果数据无法刷新，AgentMeter 会明确标记为**陈旧**。

## 系统要求

- Mac 伴侣 app 需要 macOS 13 或更高版本。
- iPhone / Apple Watch app 需从 [App Store](https://apps.apple.com/app/id6781480047) 安装。
- Mac、iPhone 和 Apple Watch 需使用同一个 Apple ID 开启 iCloud。
- Mac 上已登录 Claude Code 或 Codex；其他编程套餐和账单来源需在各设备单独输入凭据。xAI API 账单使用 Management Key + Team ID，OpenAI API 与 Anthropic API 成本使用组织级 Admin API key。

---

<div align="center">

AgentMeter 当前支持 **Claude Code**、**Codex**、**Kimi Code**、**GLM Coding Plan** 与 **MiniMax Token Plan**，并提供设备本地 **DeepSeek**、**OpenRouter**、**xAI API**、**Kimi API**、**OpenAI API** 与 **Anthropic API** 账单视图。全部功能免费。

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

## 许可证

[MIT](LICENSE.md) © 2026 dothinker lab。

---

## 免责声明

AgentMeter 从 Claude Code 与 Codex 的**非官方、未公开**端点读取额度数据，这些端点可能随时变动或失效；其他集成使用各服务商 API，也可能发生变化。使用这些服务可能受各自服务商的服务条款约束，请自行承担风险。

AgentMeter 为独立项目，**与文中列出的任何服务商均无隶属、背书或赞助关系**。所有服务商与产品名称均为各自权利人的商标。
