# Perplexity implementation validation — 2026-10-08

## Completed

| Check | Result |
| --- | --- |
| Public Mac repository Core suite | 287 Swift Testing tests + 2 XCTest tests passed |
| Private iPhone repository Core suite | 221 Swift Testing tests + 2 XCTest tests passed |
| Mac targeted regression | 44 tests passed, including Perplexity, Jev, health, both Keychain no-UI gates and replaced-session isolation; real-account fresh-value acceptance is blocked by the challenge described below |
| iPhone Perplexity and existing Jev sync regression | 11 XCTest tests passed |
| Mac Debug build | Passed |
| iPhone simulator, embedded Widget, Watch App and complication build | Passed |
| New Core source, fixture and test copies | Identical across repositories |
| iPhone cards/rings/dense list rendering | Inspected; dense facts use two columns to retain full pool percentages |
| Whitelist, schema-v3 compatibility, retries, tombstone and account changes | Fixture / injected-dependency tests passed |

The live Chrome attempt exposed the legacy file-Keychain limitation in SecItem's no-UI flags. Both browser importers now use a serialized, scoped legacy interaction gate plus SweetCookieKit's task-local gate. Tests verify that both gates are disabled and that the previous setting is restored on success, nesting and failure. Device-local Manual reads use the same scope.

## Remaining acceptance

The resumed explicit native read successfully imported the Chrome session on 2026-10-08, so initial Chrome Safe Storage access is now verified. The fixed credits request returned a browser challenge (`PerplexityFailure.challenge`); the live test skipped and **did not pass acceptance**. Direct browser navigation to the fixed endpoint was also blocked by Chrome (`ERR_BLOCKED_BY_CLIENT`); no browser protections were disabled.

The signed-in browser redirects `/account/usage` to account settings. On 2026-10-08 the user confirmed that the current account has no visible credits page. The absence of that page does not establish a zero credit balance or prove which subscription tier is required. A fresh result compared with a visible credit page, Auto/Manual parity and a real-session noninteractive follow-up remain **not yet accepted**. Resume that release QA gate only when an existing QA account exposes a visible credits page and the native request can return fresh data. No further login/verification loop is requested from the current user account. The implementation does not purchase a subscription or bypass a browser challenge.

Production CloudKit schema is **not deployed**. Final notarized DMG, exact TestFlight iPhone and paired physical Watch acceptance is **not performed**. Review/deploy the additive schema and run [the existing release gate](RELEASE_CHECKLIST.md) before publication. Local Debug/simulator success does not replace that gate.

Existing private-repository screenshot, Watch and release-tool changes were retained. No release, issue closure or production deployment is part of this implementation.
