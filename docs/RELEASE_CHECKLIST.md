# Coordinated Mac + iPhone Release Checklist

This repository publishes the macOS companion and shared core. The iPhone and
Apple Watch source is private, but a public Mac release is not complete until it
has been tested end-to-end with the exact iPhone build distributed through
TestFlight.

## Incident That Established This Gate

On 2026-07-27, AgentMeter's CloudKit Production `QuotaSnapshot` schema was behind
the shared model used by Release builds. Development testing passed, but Production
did not define:

- `staleReason` (`String`)
- `resetCreditsJSON` (`String`)
- `collectedBy` (`String`)

CloudKit rejected saves containing an unknown Production field. The downloaded Mac
app could still show locally collected data while the TestFlight app, iPhone widget,
Watch app, and complication showed an older record or no record.

The fix deployed the three additive fields to Production and verified a successful
write from Mac 1.6 (17) followed by a successful read on the Apple client path. No
client update or data migration was required.

## Lessons Learned

1. The CloudKit Production schema is a release artifact and must version-lock with
   `RecordMapping.Field`.
2. A successful Debug/Development test does not validate Production.
3. Source settings do not prove the exported app entitlement. Inspect the actual
   archive and the app extracted from the downloadable DMG.
4. Test the exact TestFlight iPhone build together with the exact downloadable Mac
   DMG. Testing either side alone does not validate synchronization.
5. Exercise fresh and degraded writes. `staleReason` is used specifically on failure
   paths that a happy-path test may never touch.
6. Any unexpected record type, index, or security-role change in the CloudKit
   deployment preview is a stop condition.
7. Keep evidence for the field list, deployment diff, artifact versions,
   entitlements, write/read timestamps, logs, and Apple-device screenshots.

## CloudKit Production Gate

Before uploading either a Mac or iPhone release:

1. Compare `RecordMapping.Field` with both Development and Production.
2. Confirm `QuotaSnapshot` defines these application fields:
   - `tool` — String
   - `plan` — String
   - `windowsJSON` — String
   - `resetCreditsJSON` — String
   - `confidence` — String
   - `staleReason` — String
   - `collectedBy` — String
   - `source` — String
   - `updatedAt` — Date/Time
3. Review the Development-to-Production deployment preview.
   - Deploy only intentional additive field changes.
   - Cancel and investigate unexpected record types, indexes, or security roles.
4. Deploy the reviewed change before distributing a writer that uses it.
5. Reopen the Production record type and verify every field and type after
   deployment.

Fields may be optional on individual records, but their definitions must exist in
Production before a Release app can write them.

## Final Mac Artifact

Validate the same DMG that users will download, preferably from a draft GitHub
Release or the final staging URL:

1. Record the version, build, URL, checksum, and download time.
2. Verify the DMG, notarization ticket, app signature, Hardened Runtime, and staple.
3. Drag the app from that DMG into `/Applications`; do not substitute an Xcode-run
   build.
4. Inspect the extracted app entitlement and confirm
   `com.apple.developer.icloud-container-environment = Production`.
5. On the release QA iCloud account, launch the app and wait no more than one normal
   collection interval.
6. Confirm the log contains a successful Production write and no
   `Cannot create or modify field`, `Unknown field`, schema rejection, or repeated
   CloudKit save failure.
7. Exercise both:
   - a fresh coding-plan snapshot; and
   - a designated QA degraded snapshot containing `staleReason`.
8. When applicable, verify Codex can publish `resetCreditsJSON`, and device-scoped
   providers publish the expected `collectedBy` record without overwriting the
   other device.

Do not intentionally break a real user's credentials to test the degraded path.
Use the designated release QA account and credential.

## Exact TestFlight iPhone + Paired Watch

1. Inspect the exported iPhone archive/IPA that will be uploaded and confirm its
   CloudKit entitlement is Production.
2. Install the exact uploaded version/build through TestFlight. A local Release
   installation is not a substitute.
3. Record the TestFlight installation time and iPhone version/build.
4. Open the iPhone app or return it to the foreground and confirm it reads the same
   Production snapshot written by the final-DMG Mac app:
   - same provider;
   - same `updatedAt`;
   - same quota values; and
   - same reset time.
5. Confirm the degraded snapshot renders as stale/unknown rather than zero or fresh.
6. Confirm Codex reset-credit data is readable when present.
7. Open the paired Watch app and verify the same selected snapshot.
8. Reload/check the iPhone widget and Watch complication, allowing for WidgetKit's
   refresh scheduling.

## Required Release Evidence

Attach or retain:

- CloudKit deployment preview and final Production field-list screenshots;
- Mac DMG URL and checksum;
- Mac and iPhone version/build values;
- entitlement output from both exported artifacts;
- Mac successful-write and failure-path log lines;
- iPhone successful-read timestamp;
- iPhone, Watch app, widget, and complication screenshots as applicable.

## Release Blockers

Do not publish the DMG or submit the iPhone build when any of the following is true:

- Development and Production field definitions differ unexpectedly;
- the deployment preview contains an unexplained type, index, or role;
- either artifact is not proven to use Production;
- the final-DMG Mac app cannot write a fresh or degraded record;
- the exact TestFlight build cannot read that record;
- the iPhone and Mac timestamps/values do not match;
- logs contain a Production schema rejection; or
- required evidence is missing.
