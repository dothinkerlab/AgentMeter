# TypeSafe API (Jev) — Mac integration

TypeSafe is disabled by default. Its source defaults to **Auto**. Enable it under Settings → API balances and billing → TypeSafe API (Jev).

## Connection

Before enabling, the settings screen does not inspect Chrome, including profile metadata. Auto imports only cookies applicable to `console.typesafe.ai` from the selected Chrome profile. A single profile is selected automatically; with multiple profiles, Default wins, otherwise the first name in sorted order. The selection is stored locally and remains fixed when login expires or a profile disappears. Sign into that profile and reconnect explicitly. First connection and reconnect permit a macOS Chrome Safe Storage Keychain prompt. Background refresh forbids Keychain interaction and retains previous values on permission failure.

Manual accepts a full Cookie request header, with an optional `Cookie:` prefix. Newlines, control characters, invalid names and malformed pairs are rejected before saving. An inference API key does not authenticate the console. Manual cookies use a non-synchronizable, ThisDeviceOnly Keychain item; Auto cookies remain in memory. Sources never fall back to one another. Disabling, source changes and profile changes clear displayed values and invalidate outstanding requests.

## Data and transport

`TypeSafeBillingAdapter` discovers `getBillingOverviewResult` in same-origin JavaScript referenced by the billing page. Action IDs are cached in memory for 12 hours. An explicit `404` with `x-nextjs-action-not-found: 1` triggers discovery and a single retry. Discovery is bounded by script count, response size and timeouts. Static scripts receive no Cookie.

The billing action supplies Decimal USD balance, cycle spend, plan and unexpired credits with positive remaining balances. `/api/usage?granularity=hour` supplies hourly input/output tokens and requests. Today, seven calendar days including today, and this month use the device's local calendar. Future buckets are ignored. Historical coverage is unknown: totals summarize returned records, with no all-time claim, cost estimate, quota percentage or reset countdown.

Billing and tokens retain separate successful timestamps and failures. An error keeps that stream's previous values; an initial error is unknown. Login expiry, access denial, rate limiting, Cloudflare challenges, unavailable endpoints, network errors and changed formats have distinct settings messages.

Production uses an isolated ephemeral URLSession with no Cookie storage or URL cache. Every request is restricted to `https://console.typesafe.ai`; all redirects, including same-origin login redirects, are refused. There are no inference calls. The local billing model is never written directly to CloudKit. An explicit, default-off sync switch exports only `TypeSafeDisplaySnapshot` via a separate private `TypeSafeDisplaySnapshot` record. Cookies and browser profiles are excluded. Diagnostic exports include only service names, confidence, sanitized failure categories and successful timestamps; no Cookie, Chrome path, raw error, plan, amount or token count is exported.

SweetCookieKit **0.5.5** is an exact Mac-target-only dependency. macOS 13 remains the minimum; building requires Swift 6.2 or newer. The shared core has no browser dependency.

## Verification

Shared fixtures cover action discovery, origin restrictions, cache expiry, bounded invalid-action retry, Decimal money, zero balances, active-credit expiry, local-calendar month boundaries, invalid counts/overflow, independent partial failures, login redirects, challenge pages, 429, server errors, malformed formats and sanitized transport errors.

Mac tests cover default Auto/off without secret reads, deterministic profile selection, fixed-profile failure, explicit/background authorization flags, Manual normalization/storage/deletion, no fallback, and late results after disabling or source/profile changes. English and Simplified Chinese settings are rendered with fake dependencies; diagnostic export tests exclude private data. Existing device-only Keychain tests include the new credential kind.

**Real-account empty-data acceptance passed on 2026-10-07.** With the user's authorized Chrome session, Auto and the Manual header path (round-tripped through an isolated local, device-only Keychain item) both returned fresh billing and usage and matched each other. Empty balance/credits and today's, seven-day and monthly tokens plus monthly requests matched the visible billing and last-30-days usage pages. The noninteractive Chrome import and query also succeeded. The temporary Keychain item was deleted; no credential was printed or persisted in test artifacts. No recharge, payment, API key creation or inference was performed.

Nonzero spend, active Credit expiry and populated usage still have fixture coverage only; this account had no records to compare. An expired-session or denied-permission scenario was not deliberately induced on the user's account. The initial run waited while macOS was locked and completed after the user unlocked it; the noninteractive background read then completed without requiring interaction.

`MacTypeSafeLiveTests` is skipped by ordinary test runs. Only after explicit user authorization, opt in with `TEST_RUNNER_AGENTMETER_TYPESAFE_LIVE=1` before `xcodebuild ... -only-testing:AgentMeterMacTests/MacTypeSafeLiveTests test`. Optionally add `TEST_RUNNER_AGENTMETER_TYPESAFE_EXPECT_EMPTY=1` when the visible console has been verified to contain no balance, credits or usage. Never enable the live test in unattended CI. Do not record cookies or billing values in acceptance logs.

## References

- [CodexBar TypeSafe plugin](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Resources/Plugins/typesafe.ts): billing action discovery and response fields.
- [SweetCookieKit 0.5.5](https://github.com/steipete/SweetCookieKit/tree/v0.5.5): Chrome import and noninteractive Keychain gate.
- [TypeSafe billing](https://console.typesafe.ai/settings/billing): account login and manual comparison.

The console endpoints are private and may change or require browser verification.


## Jev display sync

Enable **Sync Jev to iCloud** on one collecting Mac. iPhone reads the latest private record `billing-typesafe-mac`, caches the display DTO in its App Group, and distributes it to WatchConnectivity. Watch never queries Jev. Independent billing/token success times are preserved; received data older than 15 minutes is stale. Pause preserves last facts; disabling sync sends a tombstone. A serialized, persisted latest-state outbox retries failures every two minutes, including while collection is disabled. Changing iCloud accounts discards the old outbox and requires enabling sync again.

Before release, deploy the additive schema in the iOS repository's `CloudKitSchema/agentmeter.ckdb`. Production must accept `TypeSafeDisplaySnapshot.payloadJSON` (String) and `revision` (Timestamp). Follow the existing Production deployment review gate. Never deploy a quota record change as part of Jev.
