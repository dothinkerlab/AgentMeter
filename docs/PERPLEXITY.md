# Perplexity account credits

This integration reads **web account credits**, not developer API dollar balances or token-cost history. It follows [CodexBar's provider](https://github.com/steipete/CodexBar/blob/03a51bdcfc6f6804e005d7e5007de67bac82b494/Sources/CodexBarCore/Resources/Plugins/perplexity.js) at the referenced revision. The web endpoint is private and may change or require browser verification.

## Setup

Enable Perplexity account credits in Mac Settings. Collection is off by default; the source defaults to Auto. Auto reads only relevant Perplexity session cookies from the selected Chrome profile using the existing SweetCookieKit 0.5.5 dependency. Default is selected first, otherwise the first sorted profile; it stays fixed even if the session expires or the profile disappears. Explicit reconnect can request Keychain access. Background collection cannot prompt. Before enabling, settings and background collection do not read browser credentials.

Manual accepts a full Cookie header (optional `Cookie:` prefix) or a bare session token. Four Auth.js/NextAuth cookie names and contiguous numbered chunks are supported. Newlines, control characters, duplicate names, missing chunks and malformed input are rejected. Only the selected session cookie is retained. A bare token tries the four names only after 401/403 rejection. Auto and Manual never fall back to each other or environment variables. Imported cookies remain in memory; manual credentials use the device-local, non-synchronizable, ThisDeviceOnly Keychain.

The fixed GET endpoint is `https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default`; requests carry Cookie, Origin and the account-usage Referer. The transport uses an ephemeral session without Cookie storage or URL caching, and refuses all redirects. No inference, credit purchase, or account mutation is performed.

## Display semantics

All amounts are Decimal **credits**, never dollars. Both snake_case and camelCase payload fields are accepted. Recurring grants are summed; purchased grants and `current_period_purchased_cents` use the larger value, avoiding double counting; expired promotional grants are excluded. Total consumption is attributed in recurring → purchased → bonus order and capped per pool. This attribution is inferred locally, rather than supplied per pool by Perplexity. UI shows each pool's remaining/total and remaining percentage. Renewal and bonus expiry are shown only when actually returned; purchased credits have no invented reset.

Unknown initial failures show no values. Later failures retain the last successful facts and timestamp. Login expiry, invalid input, storage/access denial, rate limits, Cloudflare challenges, network failures, endpoint failures and changed responses have separate states. The compact metric prefers recurring credits when that pool exists, otherwise purchased, then bonus.

## Optional display sync

Enable **Sync Perplexity to iCloud** on one Mac using the same Apple ID as the phone. Sync is off by default. Only `PerplexityDisplaySnapshot` enters the private CloudKit database; sessions, profile IDs and raw payloads cannot be represented by the DTO. Record type: `PerplexityDisplaySnapshot`; record name: `credits-perplexity-mac`; fields: `payloadJSON` String and `revision` Timestamp; envelope schema version: 1.

The serialized latest-state outbox persists only display facts and retries every two minutes, including tombstones while collection is disabled. Pausing retains facts with `paused = true`. Source/profile/credential changes clear the old facts and invalidate outstanding requests. A replaced session within the same Chrome profile or an externally changed Manual credential also clears old facts when detected on the next read, using an in-memory fingerprint that never enters disk or CloudKit. Disabling sync sends a tombstone. Revision comparisons prevent delayed writes and phone reads from reviving older data. iCloud account changes clear the old outbox/receiving cache and require re-enabling Mac sync. An unbound restored outbox is discarded rather than attached to a new account.

iPhone only reads CloudKit on foreground/manual/BGAppRefresh refresh, caches the optional `perplexity` field in the existing schema-v3 display bundle, and forwards it via App Group/WatchConnectivity. Watch never receives cookies or queries Perplexity. Data older than 15 minutes is stale. Old v3 clients ignore the additive field; v1/v2 migration remains unchanged. Existing Jev and local billing facts are preserved. iPhone widgets retain the existing Pro gate; Watch app and complications remain free.

## Validation and release gate

Core fixtures cover precision, field aliases, credit attribution, purchase deduplication, expiry, empty pools, invalid responses, cookies, transport failures, DTO validation, record revision checks and bundle compatibility. Mac fake-dependency tests cover profile selection, source isolation, permission flags, storage, obsolete requests, diagnostics, outbox retries and tombstones. Phone tests cover cache preservation, stale/pause/disable/account changes and all three home layouts.

Ordinary tests skip `MacPerplexityLiveTests`. The requested live read can be run only in an authorized session with `TEST_RUNNER_AGENTMETER_PERPLEXITY_LIVE=1` before `xcodebuild ... -only-testing:AgentMeterMacTests/MacPerplexityLiveTests test`. The first explicit Auto connection may request Chrome Safe Storage authorization; the later background read cannot prompt. It compares Auto and isolated Manual Keychain round-trip privately and checks noninteractive collection. It never prints credentials or credit amounts. Compare fresh results with the visible account usage page before claiming real-account acceptance. If the page redirects to settings or exposes no credit pools, it is not evidence of a zero balance; keep live comparison pending and retain unknown/stale status when the request fails.

**Production schema is not deployed by implementation.** Additive schema source lives in the private iOS repository's `CloudKitSchema/agentmeter.ckdb`. Follow the existing [release checklist](RELEASE_CHECKLIST.md): review Development-to-Production changes, deploy only the intended record and fields, then verify the final downloaded Mac DMG with the exact TestFlight iPhone build and paired Watch. Confirm fresh/stale, paused/tombstone and account-change behavior, and matching values/timestamps. Existing quota records must remain unchanged.

Chrome Safe Storage uses a scoped legacy no-UI gate in addition to SweetCookieKit’s task-local gate. Browser imports are serialized and the prior process setting is restored after success or failure. This addresses the file-Keychain limitation documented in [Chromium’s implementation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc).
