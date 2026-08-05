#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$REPO_ROOT/project.yml"
TEAM_ID="${APPLE_TEAM_ID:-KCBS4SALKB}"
BUNDLE_ID="com.dothinker.app.agentmeter.mac"

read_project_value() {
  local key="$1"
  ruby -ryaml -e '
    project = YAML.safe_load(File.read(ARGV.fetch(0)))
    value = project.dig("settings", "base", ARGV.fetch(1))
    abort("missing #{ARGV[1]} in #{ARGV[0]}") if value.nil?
    puts value
  ' "$PROJECT_FILE" "$key"
}

VERSION="$(read_project_value MARKETING_VERSION)"
BUILD_NUMBER="$(read_project_value CURRENT_PROJECT_VERSION)"
TAG="v$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "Invalid MARKETING_VERSION: $VERSION" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid CURRENT_PROJECT_VERSION: $BUILD_NUMBER" >&2
  exit 1
fi

if [[ "${1:-}" == "--print-metadata" ]]; then
  printf 'version=%s\nbuild=%s\ntag=%s\n' "$VERSION" "$BUILD_NUMBER" "$TAG"
  exit 0
fi

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: scripts/package_mac_release.sh [OUTPUT_DIRECTORY]

The version and build number are always read from project.yml. The following
environment variables are required:

  DEVELOPER_ID_P12_PATH
  DEVELOPER_ID_P12_PASSWORD
  DEVELOPER_ID_PROVISIONING_PROFILE_PATH
  APP_STORE_CONNECT_KEY_PATH
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
  RELEASE_KEYCHAIN_PASSWORD

APPLE_TEAM_ID is optional and defaults to the AgentMeter team ID.
EOF
  exit 0
fi

required_commands=(
  codesign ditto file hdiutil lipo plutil ruby security shasum
  spctl xcodebuild xcodegen xcrun
)
for command_name in "${required_commands[@]}"; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

required_variables=(
  DEVELOPER_ID_P12_PATH
  DEVELOPER_ID_P12_PASSWORD
  DEVELOPER_ID_PROVISIONING_PROFILE_PATH
  APP_STORE_CONNECT_KEY_PATH
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
  RELEASE_KEYCHAIN_PASSWORD
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Required environment variable is empty: $variable_name" >&2
    exit 1
  fi
done

required_files=(
  "$DEVELOPER_ID_P12_PATH"
  "$DEVELOPER_ID_PROVISIONING_PROFILE_PATH"
  "$APP_STORE_CONNECT_KEY_PATH"
)
for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required file not found: $required_file" >&2
    exit 1
  fi
done

OUTPUT_DIR="${1:-$REPO_ROOT/.build/release-$TAG}"
ARTIFACT_DIR="$OUTPUT_DIR/artifacts"
WORK_DIR="$OUTPUT_DIR/work"
ARCHIVE_PATH="$WORK_DIR/AgentMeterMac.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
APP_PATH="$EXPORT_DIR/AgentMeter.app"
VERSIONED_DMG="$ARTIFACT_DIR/AgentMeter-$VERSION-$BUILD_NUMBER.dmg"
LATEST_DMG="$ARTIFACT_DIR/AgentMeter.dmg"

if [[ -e "$WORK_DIR" || -e "$ARTIFACT_DIR" ]]; then
  echo "Refusing to overwrite an existing release directory: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$ARTIFACT_DIR"

TASK_TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/private/tmp}}"
if [[ ! -d "$TASK_TEMP_ROOT" ]]; then
  echo "Temporary directory does not exist: $TASK_TEMP_ROOT" >&2
  exit 1
fi

KEYCHAIN_PATH="$TASK_TEMP_ROOT/agentmeter-release-$BUILD_NUMBER.keychain-db"
PROFILE_PLIST="$WORK_DIR/provisioning-profile.plist"
ENTITLEMENTS_PLIST="$WORK_DIR/exported-entitlements.plist"
EXPORT_OPTIONS="$WORK_DIR/ExportOptions.plist"
DMG_ROOT="$WORK_DIR/dmg-root"
MOUNT_POINT="$TASK_TEMP_ROOT/agentmeter-dmg-$BUILD_NUMBER"
INSTALLED_PROFILE=""
DMG_ATTACHED=0

cleanup() {
  if [[ "$DMG_ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "$INSTALLED_PROFILE" && -f "$INSTALLED_PROFILE" ]]; then
    rm -f "$INSTALLED_PROFILE"
  fi
  if [[ -f "$KEYCHAIN_PATH" ]]; then
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

security create-keychain -p "$RELEASE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$RELEASE_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$DEVELOPER_ID_P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$RELEASE_KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"

security cms -D -i "$DEVELOPER_ID_PROVISIONING_PROFILE_PATH" > "$PROFILE_PLIST"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")"
PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")"
PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"

if [[ "$PROFILE_TEAM_ID" != "$TEAM_ID" ]]; then
  echo "Provisioning profile team mismatch: $PROFILE_TEAM_ID" >&2
  exit 1
fi
if [[ "$PROFILE_APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
  echo "Provisioning profile app identifier mismatch: $PROFILE_APP_ID" >&2
  exit 1
fi

PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
INSTALLED_PROFILE="$PROFILE_DIR/$PROFILE_UUID.provisionprofile"
ditto "$DEVELOPER_ID_PROVISIONING_PROFILE_PATH" "$INSTALLED_PROFILE"

cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>iCloudContainerEnvironment</key>
  <string>Production</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$BUNDLE_ID</key>
    <string>$PROFILE_NAME</string>
  </dict>
</dict>
</plist>
EOF

cd "$REPO_ROOT"
xcodegen generate

xcodebuild archive \
  -project AgentMeter.xcodeproj \
  -scheme AgentMeterMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  clean archive

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found: $APP_PATH" >&2
  exit 1
fi

APP_INFO="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AgentMeter"
EXPORTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")"
EXPORTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")"
EXPORTED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")"

if [[ "$EXPORTED_VERSION" != "$VERSION" || "$EXPORTED_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "Exported version mismatch: $EXPORTED_VERSION ($EXPORTED_BUILD)" >&2
  exit 1
fi
if [[ "$EXPORTED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Exported bundle identifier mismatch: $EXPORTED_BUNDLE_ID" >&2
  exit 1
fi

ARCHITECTURES="$(lipo -archs "$APP_EXECUTABLE")"
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
  echo "Exported executable is not universal: $ARCHITECTURES" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST"
CLOUDKIT_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$ENTITLEMENTS_PLIST")"
if [[ "$CLOUDKIT_ENVIRONMENT" != "Production" ]]; then
  echo "Exported app does not use Production CloudKit: $CLOUDKIT_ENVIRONMENT" >&2
  exit 1
fi

codesign -dvvv "$APP_PATH" 2> "$WORK_DIR/codesign-details.txt"
if ! grep -q 'Authority=Developer ID Application:' "$WORK_DIR/codesign-details.txt"; then
  echo "Exported app is not signed with Developer ID Application" >&2
  exit 1
fi
if ! grep -Eq '^flags=.*\(runtime\)' "$WORK_DIR/codesign-details.txt"; then
  echo "Exported app does not have Hardened Runtime enabled" >&2
  exit 1
fi

APP_ZIP="$WORK_DIR/AgentMeter.app.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
  --key "$APP_STORE_CONNECT_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait \
  --output-format json | tee "$WORK_DIR/app-notarization.json"
ruby -rjson -e '
  result = JSON.parse(File.read(ARGV.fetch(0)))
  abort("app notarization was not accepted: #{result["status"]}") unless result["status"] == "Accepted"
' "$WORK_DIR/app-notarization.json"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

mkdir -p "$DMG_ROOT"
ditto "$APP_PATH" "$DMG_ROOT/AgentMeter.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname AgentMeter \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$VERSIONED_DMG"

codesign --force --timestamp --sign 'Developer ID Application' "$VERSIONED_DMG"
xcrun notarytool submit "$VERSIONED_DMG" \
  --key "$APP_STORE_CONNECT_KEY_PATH" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait \
  --output-format json | tee "$WORK_DIR/dmg-notarization.json"
ruby -rjson -e '
  result = JSON.parse(File.read(ARGV.fetch(0)))
  abort("DMG notarization was not accepted: #{result["status"]}") unless result["status"] == "Accepted"
' "$WORK_DIR/dmg-notarization.json"
xcrun stapler staple "$VERSIONED_DMG"
xcrun stapler validate "$VERSIONED_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$VERSIONED_DMG"

mkdir -p "$MOUNT_POINT"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$VERSIONED_DMG" -quiet
DMG_ATTACHED=1
if [[ ! -d "$MOUNT_POINT/AgentMeter.app" || ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "DMG does not contain the expected app and Applications link" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/AgentMeter.app"
MOUNTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT_POINT/AgentMeter.app/Contents/Info.plist")"
MOUNTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNT_POINT/AgentMeter.app/Contents/Info.plist")"
if [[ "$MOUNTED_VERSION" != "$VERSION" || "$MOUNTED_BUILD" != "$BUILD_NUMBER" ]]; then
  echo "Mounted app version mismatch: $MOUNTED_VERSION ($MOUNTED_BUILD)" >&2
  exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet
DMG_ATTACHED=0

cp -p "$VERSIONED_DMG" "$LATEST_DMG"
if ! cmp -s "$VERSIONED_DMG" "$LATEST_DMG"; then
  echo "Versioned and latest DMG files are not byte-identical" >&2
  exit 1
fi

(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "$(basename "$VERSIONED_DMG")" "$(basename "$LATEST_DMG")" > SHA256SUMS.txt
)

DMG_SHA256="$(shasum -a 256 "$VERSIONED_DMG" | awk '{print $1}')"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "version=$VERSION"
    echo "build=$BUILD_NUMBER"
    echo "tag=$TAG"
    echo "sha256=$DMG_SHA256"
    echo "artifact_dir=$ARTIFACT_DIR"
    echo "dsym_dir=$ARCHIVE_PATH/dSYMs"
  } >> "$GITHUB_OUTPUT"
fi

cat <<EOF
AgentMeter release package is ready.
Version: $VERSION
Build: $BUILD_NUMBER
Tag: $TAG
Architectures: $ARCHITECTURES
SHA-256: $DMG_SHA256
Artifacts: $ARTIFACT_DIR
EOF
