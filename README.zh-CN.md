<div align="center">

# AgentMeter

### AI 额度状态,抬腕即见。

[English](README.md) · **中文**

<img src="screenshots/watch.png" alt="Apple Watch 上的 AgentMeter" width="240">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>

---

你离开键盘时,后台的 coding agent 还在烧额度。**AgentMeter** 把 Claude Code 和 Codex 的额度状态放到你 2 秒就能看到的地方——Apple Watch 表盘。当前 **5 小时窗口**和**每周窗口**还剩多少、各自什么时候重置,一眼看清,不用回去翻终端。

## 下载

**[⬇️ 下载 Mac 版 AgentMeter(.dmg)](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg)**

Mac app 已 Developer ID 签名并通过 Apple 公证——双击即可打开。把 **AgentMeter.app** 拖进「应用程序」,首次启动会请求读取本机 Claude Code 和 Codex 凭据的权限。历史版本见 [Releases 页面](https://github.com/dothinkerlab/AgentMeter/releases)。

> iPhone + Apple Watch app 通过 App Store 发布(*即将上线*)。Mac app 只以这个公证 DMG 分发——因为它需要读取这些工具的 Keychain 凭据,无法在 App Store 沙盒里运行。

## 截图

| Apple Watch | iPhone |
|:---:|:---:|
| <img src="screenshots/watch.png" alt="Watch" width="220"> | <img src="screenshots/iphone.png" alt="iPhone" width="220"> |

负责同步的 Mac 菜单栏伴侣:

<p align="center"><img src="screenshots/mac.png" alt="Mac 上的 AgentMeter 菜单栏 app" width="340"></p>

## 工作原理

1. 一个轻量的 **Mac 菜单栏伴侣 app** 读取你本机已有的 Claude Code 和 Codex 凭据,查询额度。
2. 它把**清洗后的额度快照**经由**你自己的**私有 iCloud 同步——不经过我们的账号或服务器。
3. 你的 **Apple Watch**(和 iPhone)抬腕即可看到剩余百分比和重置时间。

手表从不直连 Anthropic,你的 token 也不会离开 Mac。

## 隐私

- 你的 OAuth token 只留在 **Mac Keychain** 里,绝不上传、绝不发给我们。
- 只有**清洗后的额度快照**(数字 + 重置时间)会同步,且只走**你自己的私有 iCloud**。
- 数据无法刷新时,AgentMeter 会明确标记为**陈旧**,而不是显示一个误导性的数值。

## 系统要求

- **Mac 伴侣 app:** macOS 13 及以上(上方公证 DMG)。
- **iPhone + Apple Watch app:** App Store(*即将上线*)。
- Mac 上已登录的 Claude Code 或 Codex 订阅。

---

<div align="center">

AgentMeter 当前支持 **Claude Code** 和 **Codex**,更多工具在规划中。

© 2026 dothinker lab · [Releases](https://github.com/dothinkerlab/AgentMeter/releases)

</div>
