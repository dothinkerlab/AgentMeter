#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "Usage: scripts/verify_mac_release.sh DMG_PATH EXPECTED_VERSION EXPECTED_BUILD" >&2
  exit 64
fi

DMG_PATH="$1"
EXPECTED_VERSION="$2"
EXPECTED_BUILD="$3"
TEAM_ID="${APPLE_TEAM_ID:-KCBS4SALKB}"
BUNDLE_ID="com.dothinker.app.agentmeter.mac"
CLOUDKIT_CONTAINER_ID="iCloud.com.dothinker.app.agentmeter"

read_plist_value() {
  local plist_path="$1"
  local key_path="$2"
  /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null || true
}

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

TASK_TEMP_ROOT="${RUNNER_TEMP:-${TMPDIR:-/private/tmp}}"
MOUNT_POINT="$(mktemp -d "$TASK_TEMP_ROOT/agentmeter-verify-mount.XXXXXX")"
ENTITLEMENTS_PLIST="$(mktemp "$TASK_TEMP_ROOT/agentmeter-entitlements.XXXXXX")"
CODESIGN_DETAILS="$(mktemp "$TASK_TEMP_ROOT/agentmeter-codesign.XXXXXX")"
DMG_ATTACHED=0

cleanup() {
  if [[ "$DMG_ATTACHED" -eq 1 ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -f "$ENTITLEMENTS_PLIST" "$CODESIGN_DETAILS"
  rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

codesign --verify --strict --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DMG_PATH" -quiet
DMG_ATTACHED=1

APP_PATH="$MOUNT_POINT/AgentMeter.app"
if [[ ! -d "$APP_PATH" || ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "DMG does not contain AgentMeter.app and the Applications link" >&2
  exit 1
fi

APP_INFO="$APP_PATH/Contents/Info.plist"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/AgentMeter"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_INFO")"
SIGNED_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_INFO")"
INFO_BUILD_CONFIGURATION="$(read_plist_value "$APP_INFO" 'AgentMeterBuildConfiguration')"
INFO_CLOUDKIT_ENVIRONMENT="$(read_plist_value "$APP_INFO" 'AgentMeterCloudKitEnvironment')"
ARCHITECTURES="$(lipo -archs "$APP_EXECUTABLE")"

if [[ "$VERSION" != "$EXPECTED_VERSION" || "$BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "DMG app version mismatch: $VERSION ($BUILD)" >&2
  exit 1
fi
if [[ "$SIGNED_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "DMG app bundle identifier mismatch: $SIGNED_BUNDLE_ID" >&2
  exit 1
fi
if [[ "$INFO_BUILD_CONFIGURATION" != "Release" ]]; then
  echo "DMG app build configuration mismatch: $INFO_BUILD_CONFIGURATION" >&2
  exit 1
fi
if [[ "$INFO_CLOUDKIT_ENVIRONMENT" != "Production" ]]; then
  echo "DMG app Info.plist does not report Production CloudKit: $INFO_CLOUDKIT_ENVIRONMENT" >&2
  exit 1
fi
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
  echo "DMG app is not universal: $ARCHITECTURES" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - --xml "$APP_PATH" > "$ENTITLEMENTS_PLIST"
plutil -lint "$ENTITLEMENTS_PLIST" >/dev/null

APPLICATION_ID="$(read_plist_value "$ENTITLEMENTS_PLIST" 'com.apple.application-identifier')"
SIGNED_TEAM_ID="$(read_plist_value "$ENTITLEMENTS_PLIST" 'com.apple.developer.team-identifier')"
CLOUDKIT_ENVIRONMENT="$(read_plist_value "$ENTITLEMENTS_PLIST" 'com.apple.developer.icloud-container-environment')"
SIGNED_CLOUDKIT_CONTAINER_ID="$(read_plist_value "$ENTITLEMENTS_PLIST" 'com.apple.developer.icloud-container-identifiers:0')"
CLOUDKIT_SERVICE="$(read_plist_value "$ENTITLEMENTS_PLIST" 'com.apple.developer.icloud-services:0')"

if [[ "$APPLICATION_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
  echo "DMG app application identifier mismatch: $APPLICATION_ID" >&2
  exit 1
fi
if [[ "$SIGNED_TEAM_ID" != "$TEAM_ID" ]]; then
  echo "DMG app team identifier mismatch: $SIGNED_TEAM_ID" >&2
  exit 1
fi
if [[ "$CLOUDKIT_ENVIRONMENT" != "Production" ]]; then
  echo "DMG app does not use Production CloudKit: $CLOUDKIT_ENVIRONMENT" >&2
  exit 1
fi
if [[ "$INFO_CLOUDKIT_ENVIRONMENT" != "$CLOUDKIT_ENVIRONMENT" ]]; then
  echo "DMG app CloudKit environment metadata does not match its entitlement: Info.plist=$INFO_CLOUDKIT_ENVIRONMENT entitlement=$CLOUDKIT_ENVIRONMENT" >&2
  exit 1
fi
if [[ "$SIGNED_CLOUDKIT_CONTAINER_ID" != "$CLOUDKIT_CONTAINER_ID" ]]; then
  echo "DMG app CloudKit container mismatch: $SIGNED_CLOUDKIT_CONTAINER_ID" >&2
  exit 1
fi
if [[ "$CLOUDKIT_SERVICE" != "CloudKit" ]]; then
  echo "DMG app does not enable the CloudKit service: $CLOUDKIT_SERVICE" >&2
  exit 1
fi

codesign -dvvv "$APP_PATH" 2> "$CODESIGN_DETAILS"
if ! grep -q 'Authority=Developer ID Application:' "$CODESIGN_DETAILS"; then
  echo "DMG app is not signed with Developer ID Application" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*\(runtime\)' "$CODESIGN_DETAILS"; then
  echo "DMG app does not have Hardened Runtime enabled" >&2
  exit 1
fi

xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Verified AgentMeter $VERSION ($BUILD): signed, notarized, universal, and Production CloudKit-enabled."
