<div align="center">

# AgentMeter

### Keep your Claude Code and Codex quota on your wrist.

**English** · [中文](README.zh-CN.md)

<img src="logo.png" alt="AgentMeter" width="120">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>

---

Coding agents can keep spending quota after you leave the keyboard. **AgentMeter** puts your Claude Code and Codex usage where you can check it in seconds: your Apple Watch, iPhone, and Mac menu bar.

It shows the remaining percentage in the current **5-hour window** and **weekly window**, plus each reset time, without opening a terminal.

## Download AgentMeter

| Platform | Get it |
| --- | --- |
| macOS companion | [Download the notarized DMG](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg) |
| iPhone + Apple Watch | [Download on the App Store](https://apps.apple.com/app/id6781480047) |

The Mac app is Developer ID-signed and notarized by Apple. Drag **AgentMeter.app** into your Applications folder; on first launch, it asks for permission to read the local Claude Code and Codex credentials already stored on your Mac. Previous builds are available on the [Releases page](https://github.com/dothinkerlab/AgentMeter/releases).

The iPhone and Apple Watch app ships through the App Store:

<img src="app-store-qr.png" alt="App Store QR code" width="160">

> The Mac companion is distributed outside the App Store because it needs Keychain access to your local Claude Code and Codex credentials, which is not compatible with the App Store sandbox.

## What You Get

- **Watch complications and app views** for at-a-glance quota status.
- **iPhone status view** when you want a larger quota snapshot.
- **Mac menu-bar companion** that collects quota data and can show status locally.
- **Multi-window tracking** for both short rolling windows and weekly limits.
- **Stale-data warnings** when a quota refresh fails, instead of silently showing old values.

## Screenshots

<table>
  <tr>
    <td align="center" valign="center"><img src="screenshots/watch.png" alt="Apple Watch" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/iphone.png" alt="iPhone" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/mac.png" alt="Mac menu bar" height="300"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Apple Watch</b></sub></td>
    <td align="center"><sub><b>iPhone</b></sub></td>
    <td align="center"><sub><b>Mac menu bar</b></sub></td>
  </tr>
</table>

## How it works

1. The **Mac menu-bar companion** reads your existing Claude Code and Codex credentials from the local Keychain.
2. It uses those credentials on your Mac to query each tool's quota endpoint.
3. It writes only **cleaned quota snapshots** - percentages, windows, reset times, and update timestamps - to your private iCloud database.
4. Your **Apple Watch** and **iPhone** read those snapshots from iCloud and display them at a glance.

Your watch and iPhone never receive provider tokens and never connect directly to Anthropic or OpenAI.

## Privacy

AgentMeter is designed around a local-token, private-iCloud sync model:

- OAuth tokens stay in your **Mac Keychain**.
- Tokens are used only by the Mac companion, on your Mac, to refresh quota data.
- Tokens are **never sent to us** and **never written to iCloud**.
- Synced records contain only cleaned quota snapshots such as percentages and reset times.
- If data cannot be refreshed, AgentMeter marks it as **stale**.

## Requirements

- macOS 13 or later for the Mac companion.
- iOS/watchOS app installed from the [App Store](https://apps.apple.com/app/id6781480047).
- iCloud enabled with the same Apple ID across your Mac, iPhone, and Apple Watch.
- Claude Code or Codex signed in on your Mac.

---

<div align="center">

AgentMeter tracks **Claude Code** and **Codex** today; more tools are planned.

© 2026 dothinker lab · [Releases](https://github.com/dothinkerlab/AgentMeter/releases)

</div>

---

## Building from source

This repository contains the source for the macOS companion (`AgentMeterMac`) and shared core package (`AgentMeterCore`). The iPhone and Apple Watch app is distributed through the App Store and is not included in this repository.

Run the core test suite:

```sh
cd Packages/AgentMeterCore
swift test
```

Generate and open the Xcode project:

```sh
xcodegen generate
open AgentMeter.xcodeproj
```

The checked-in `DEVELOPMENT_TEAM` and iCloud container ID belong to the maintainer. If you fork the project, replace them with your own Apple Developer Team and CloudKit container in [`project.yml`](project.yml) and [`AgentMeterMac/AgentMeterMac.entitlements`](AgentMeterMac/AgentMeterMac.entitlements).

## License

[MIT](LICENSE.md) © 2026 dothinker lab.

---

## Disclaimer

AgentMeter reads quota data from **unofficial, undocumented** Claude Code and Codex endpoints. These endpoints may change or stop working at any time, and using them may be subject to each provider's terms of service. Use AgentMeter at your own risk.

AgentMeter is an independent project and is **not affiliated with, endorsed by, or sponsored by** Anthropic or OpenAI. "Claude" and "Claude Code" are trademarks of Anthropic; "Codex" and "ChatGPT" are trademarks of OpenAI; "Apple Watch" is a trademark of Apple Inc. All trademarks belong to their respective owners.
