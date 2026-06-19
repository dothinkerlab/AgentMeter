<div align="center">

# AgentMeter

### AI quota status under your watch.

**English** · [中文](README.zh-CN.md)

<img src="logo.png" alt="AgentMeter" width="120">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>

---

Coding agents keep burning quota while you're away from the keyboard. **AgentMeter** puts your Claude Code and Codex quota where you can check it in two seconds — your Apple Watch face. See how much is left in the current **5‑hour window** and the **weekly window**, plus when each one resets — without digging through a terminal.

## Download

**[⬇️ Download AgentMeter for Mac (.dmg)](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg)**

The Mac app is Developer ID–signed and notarized by Apple — just open it. Drag **AgentMeter.app** into your Applications folder; on first launch it asks permission to read your local Claude Code and Codex credentials. See all versions on the [Releases page](https://github.com/dothinkerlab/AgentMeter/releases).

> The iPhone + Apple Watch app ships through the App Store *(coming soon)*. The Mac app is distributed only as this notarized DMG, because it needs to read those tools' Keychain items and therefore can't run in the App Store sandbox.

## Screenshots

| Apple Watch | iPhone |
|:---:|:---:|
| <img src="screenshots/watch.png" alt="Watch" width="300"> | <img src="screenshots/iphone.png" alt="iPhone" width="220"> |

The Mac menu‑bar companion that does the syncing:

<p align="center"><img src="screenshots/mac.png" alt="AgentMeter menu-bar app on Mac" width="340"></p>

## How it works

1. A small **Mac menu‑bar companion** reads the Claude Code and Codex credentials already on your machine and fetches your quota.
2. It syncs **cleaned quota snapshots** through *your own* private iCloud database — no account or server of ours involved.
3. Your **Apple Watch** (and iPhone) show the remaining percentage and reset time at a glance.

The watch never connects to Anthropic directly, and your token never leaves your Mac.

## Privacy

- Your OAuth token stays in your **Mac Keychain**. It is never uploaded and never sent to us.
- Only **cleaned quota snapshots** (numbers + reset times) sync, and only through **your private iCloud**.
- When data can't be refreshed, AgentMeter clearly marks it **stale** instead of showing a misleading value.

## Requirements

- **Mac companion app:** macOS 13 or later (notarized DMG above).
- **iPhone + Apple Watch app:** App Store *(coming soon)*.
- A Claude Code or Codex subscription signed in on your Mac.

---

<div align="center">

AgentMeter tracks **Claude Code** and **Codex** today; more tools are planned.

© 2026 dothinker lab · [Releases](https://github.com/dothinkerlab/AgentMeter/releases)

</div>
