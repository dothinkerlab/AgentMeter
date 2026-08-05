# macOS release automation

The `Prepare macOS release` workflow builds the version committed in
`project.yml`, creates signed and notarized DMGs, and uploads them to a Draft
GitHub Release. It never changes the version or build number.

## One-time repository setup

Configure these Actions secrets in `dothinkerlab/AgentMeter`:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`) |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password protecting the `.p12` |
| `DEVELOPER_ID_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `com.dothinker.app.agentmeter.mac` |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect `.p8` key |
| `TAP_DISPATCH_TOKEN` | Fine-grained token limited to `dothinkerlab/homebrew-tap`, with **Contents: read and write** |

The repository-dispatch endpoint requires Contents write permission on the
target repository. The token does not need Administration, Actions, Issues, or
Pull Requests access.

Enable immutable releases in the repository Release settings. Draft releases
remain editable; tags and assets become immutable only after publication.

## Prepare a release

1. Update and commit `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `project.yml`.
2. Copy `docs/releases/TEMPLATE.md` to `docs/releases/v<version>.md`, replace
   both TODO entries, and commit the bilingual notes.
3. Run **Prepare macOS release** on `main`.
4. Download the exact DMG from the Draft Release and complete
   `docs/RELEASE_CHECKLIST.md`.
5. Edit the Draft notes if necessary, then publish the Release manually.
6. Confirm that **Dispatch published release to Homebrew Tap** succeeds and that
   the Tap update workflow commits the new Cask version.

If QA fails, delete only the unpublished Draft Release and its tag, fix the
problem, increment `CURRENT_PROJECT_VERSION`, and prepare a new build. Never
replace an asset after publication.

## Local metadata check

The packaging script can show the release identity without accessing signing
credentials:

```sh
./scripts/package_mac_release.sh --print-metadata
```

Running the complete script locally requires the decoded credential file paths
and passwords listed by `./scripts/package_mac_release.sh --help`.
