<div align="center">

# AgentMeter

### Keep your AI coding quota on your wrist.

**English** · [中文](README.zh-CN.md)

<img src="logo.png" alt="AgentMeter" width="120">

[![Latest Release](https://img.shields.io/github/v/release/dothinkerlab/AgentMeter?label=download&sort=semver)](https://github.com/dothinkerlab/AgentMeter/releases/latest)

</div>


**AgentMeter** keeps AI coding quota, reset times, and API billing visible on your Mac menu bar, iPhone, and Apple Watch—even when you are away from the keyboard. All features are free.

## Screenshots

<table>
  <tr>
    <td align="center" valign="center"><img src="screenshots/iphone.png" alt="iPhone" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/mac.png" alt="Mac menu bar" height="300"></td>
    <td align="center" valign="center"><img src="screenshots/watch.png" alt="Apple Watch" height="300"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>iPhone</b></sub></td>
    <td align="center"><sub><b>Mac menu bar</b></sub></td>
    <td align="center"><sub><b>Apple Watch</b></sub></td>
  </tr>
</table>

## Install and get started

### 1. Install AgentMeter

The Mac app requires **macOS 13 or later**. It is Developer ID-signed and notarized by Apple.

| Platform | Download |
| --- | --- |
| Mac | [Download the notarized DMG](https://github.com/dothinkerlab/AgentMeter/releases/latest/download/AgentMeter.dmg), then drag **AgentMeter.app** into Applications |
| iPhone and Apple Watch | [Download on the App Store](https://apps.apple.com/app/id6781480047) |

Or install the Mac app with Homebrew:

```sh
brew install --cask dothinkerlab/tap/agentmeter
```

To upgrade an existing Homebrew installation:

```sh
brew upgrade --cask dothinkerlab/tap/agentmeter
```

[Previous Mac releases](https://github.com/dothinkerlab/AgentMeter/releases) are also available. The Mac companion is distributed outside the App Store so it can access existing local coding-tool credentials.

<img src="app-store-qr.png" alt="Download AgentMeter on the App Store" width="160">

#### 🎁 Agent Meter Special Offer

Get a special App Store offer for **AgentMeter**.

**Offer Code:** `AGENTMETER202609`

[👉 Redeem on the App Store](https://apps.apple.com/redeem?ctx=offercodes&id=6781480047&code=AGENTMETER202609)

The offer is redeemed securely through the official Apple App Store.

> Availability and eligibility are subject to Apple’s App Store rules and the terms of this offer.

### 2. Configure your providers

Open AgentMeter from the Mac menu bar. For **Claude Code, Codex, Cursor, Windsurf, JetBrains AI, and Zed**, sign in to or use the corresponding tool on your Mac; AgentMeter reads its existing local credentials or quota cache only after you enable that provider. GitHub Copilot uses a GitHub token that you paste into Settings. Other coding plans and API billing services are also configured in Settings. You only need to enable the services you use.

Manually entered credentials are device-local. If you configure a provider on both Mac and iPhone, enter its credentials separately on each device. See [Supported services](#supported-services) for special credential requirements.

### 3. Check your quota

View remaining quota and reset times in the Mac menu bar. To see coding-plan quota on iPhone and Apple Watch, enable iCloud with the **same Apple ID** across those devices. iCloud is used for cross-device quota sync; API billing stays on the device that collects it, with an opt-in exception for Jev display sync.

## Features

- **Quota at a glance:** Mac menu-bar views, iPhone status views, and Apple Watch complications.
- **Provider-specific periods:** rolling windows, weekly limits, and monthly cycles, plus Codex reset-credit availability and expiry reminders.
- **Local API billing:** balances, limits, and daily, weekly, or monthly costs where supported by the provider.
- **Mac controls:** search providers, manage credentials and regions, pause collection, and customize service visibility and ordering.
- **Clear freshness:** stale-data indicators when refresh fails, with optional reset reminders when fresh data shows an exhausted 5-hour window.

## Supported services

| Data | Providers | Setup |
| --- | --- | --- |
| Coding-plan quota | Claude Code, Codex, Cursor | Existing sign-in on your Mac |
| Coding-plan quota | GitHub Copilot | GitHub token stored in the local Keychain |
| Coding-plan quota | Windsurf, JetBrains AI, Zed | Opt-in detection of an existing Mac sign-in or local quota cache |
| Coding-plan quota | Kimi Code, GLM Coding Plan, MiniMax Token Plan | Provider settings on Mac or iPhone |
| Local API balance and billing | DeepSeek, OpenRouter, Kimi API | Provider credentials on each device |
| Local API costs | OpenAI API, Anthropic API | Credentials with access to organization-level costs |
| Local API billing | xAI API | Management Key and Team ID |
| Mac-only team billing | Cursor Team | Team/Enterprise Admin API key |
| API balance and usage with opt-in Mac → iPhone sync | TypeSafe API (Jev) | Chrome console session (Auto, default) or manually pasted Cookie header |

Available metrics depend on the provider. OpenAI API and Anthropic API costs refer to developer API usage, not ChatGPT or Claude web/app subscriptions. Coding-plan quota can sync through private iCloud; **API billing remains local except for explicitly enabled Jev display sync**, and Cursor Team member identities and amounts stay on Mac.

### TypeSafe API (Jev) on Mac

TypeSafe is disabled until you enable it in Settings. Auto reads the selected Chrome profile's TypeSafe console cookies; the first connection may ask for Chrome Safe Storage Keychain access. Background collection never opens permission prompts. With multiple profiles, choose the profile containing your TypeSafe login. The app does not switch profiles when a session expires.

Manual accepts the full Cookie header from an authenticated request on [TypeSafe Billing](https://console.typesafe.ai/settings/billing). Store it using the secure field in Settings; an inference API key cannot replace a console session. You can pause collection, reconnect, or delete the manual Cookie. Auto and Manual are separate sources and do not fall back to each other.

Balance, billing-page cycle spend, active credit grants, and token/request summaries stay on Mac by default. Enable **Sync Jev to iCloud** on one Mac to share cleaned display facts with iPhone, widgets, and Apple Watch using the same Apple ID. Phone refresh checks the cloud; it does not query Jev. Billing-page spend and token totals use different accounting scopes; summaries may be delayed and history coverage is not guaranteed. Credit expiry is not a quota reset. Console interfaces are undocumented and may change or be blocked by a browser challenge. Collection does not call Jev inference.

## Privacy and sync

Each collecting device queries providers using its own local credentials. AgentMeter does not send those credentials to us or write them to iCloud.

- **Existing Mac sign-ins:** Claude Code credentials are read from Keychain. For Codex, AgentMeter checks Keychain and falls back to `~/.codex/auth.json` when no entry exists. Cursor and Windsurf databases and JetBrains AI quota files are opened read-only. Zed credentials are read from the matching local Keychain item and are never refreshed or modified by AgentMeter.
- **TypeSafe console sessions:** automatic cookies stay in memory; manual Cookie headers use the device-local Keychain. Only the fixed TypeSafe console origin receives them, and redirects are refused. TypeSafe credentials never enter CloudKit. Opt-in Jev sync stores only display facts in a separate private record.
- **Manually entered credentials:** stored in the local Keychain, with iCloud Keychain synchronization and backup migration to another device disabled.
- **Private quota sync:** only cleaned coding-plan status—such as quota windows, reset times, subscription tier, reset-credit availability, and freshness information—is written to your private CloudKit database. Provider credentials and upstream reset-credit IDs are excluded.
- **Local billing:** billing records remain on the collecting device except for opt-in Jev display sync. Cursor Team member identities and amounts remain on the Mac holding the Admin API key.
- **Device boundaries:** Apple Watch reads synced quota and never receives provider tokens or connects directly to providers. iPhone queries only providers you explicitly configure on that device.

If a refresh fails, the app marks the data as stale. Sanitized diagnostics are generated only when you request an export.

## Troubleshooting and feedback

If devices show different quota values, first compare their **updated times** and check that they use the same Apple ID with iCloud enabled.

1. Export sanitized diagnostics from **Settings → About AgentMeter → Export Sanitized Diagnostics** on Mac, or **Settings → App Info** on iPhone.
2. Open the [Bug Report form](https://github.com/dothinkerlab/AgentMeter/issues/new?template=bug_report.yml).
3. Include reproduction steps, each affected device's updated time, and the diagnostic file.

Diagnostics include app and OS versions, quota and reset status, update times, local billing service status, and pending CloudKit writes. They exclude credentials, Keychain values, device names, raw logs, raw provider responses, and billing amounts. Review any screenshots or text you add before submitting.

## Building from source

This repository contains the **macOS companion** (`AgentMeterMac`) and **shared core package** (`AgentMeterCore`). The iPhone and Apple Watch apps are distributed through the App Store; their source is not included here.

Prerequisites: Xcode with a **Swift 6.2 or newer toolchain**, and **XcodeGen** to generate the Xcode project. Run all commands below from the repository root.

Run the core tests:

```sh
swift test --package-path Packages/AgentMeterCore
```

Generate and open the Xcode project:

```sh
xcodegen generate
open AgentMeter.xcodeproj
```

Select the **AgentMeterMac** scheme to build and run the Mac app.

The checked-in signing team and iCloud container belong to the maintainer. For your own build, set your Apple Developer Team in [`project.yml`](project.yml) and your CloudKit container in [`AgentMeterMac/AgentMeterMac.entitlements`](AgentMeterMac/AgentMeterMac.entitlements) before generating the project. Your own container is separate from the App Store app's container.

## Maintainer release validation

Every public Mac release must pass the [Mac + iPhone release checklist](docs/RELEASE_CHECKLIST.md) with the exact iPhone build installed from TestFlight. This includes CloudKit Production schema review and testing the app installed from the final downloadable DMG.

## License

[MIT](LICENSE.md) © 2026 dothinker lab.

## Disclaimer

AgentMeter reads quota data from **unofficial, undocumented** Claude Code, Codex, GitHub Copilot, and [Cursor dashboard endpoints](https://github.com/Noisemaker111/openusage-opencode/blob/main/docs/providers/cursor.md), as well as Windsurf and JetBrains AI local cache formats and Zed's client API. These interfaces may change or stop working at any time. Copilot currently requires a manually supplied token and does not support GitHub Enterprise. Cursor Team uses Cursor's [official Admin API](https://docs.cursor.com/en/account/teams/admin-api) and requires an administrator-created key. Other integrations use their providers' APIs, which may also change. Using these services may be subject to each provider's terms of service. Use AgentMeter at your own risk.

AgentMeter is an independent project and is **not affiliated with, endorsed by, or sponsored by** any listed provider. Provider and product names are trademarks of their respective owners.
