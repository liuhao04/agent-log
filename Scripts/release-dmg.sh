#!/usr/bin/env bash
# Build, sign, notarize, staple AgentLog.app and package it into a DMG.
#
# Prereqs (already set up on this machine):
#   - Developer ID Application certificate in login keychain
#   - Notarization credentials: either a keychain profile (default
#     `notarize-profile`) OR App Store Connect API Key env vars
#     (NOTARIZE_API_KEY_ID / NOTARIZE_API_ISSUER_ID / NOTARIZE_API_KEY_PATH).
#     The script also auto-sources `~/Library/Mobile Documents/com~apple~CloudDocs/Projects/apple-certs/notarize.env`
#     if present.
#
# Env overrides:
#   SIGN_IDENTITY      full name of Developer ID Application cert
#                      (defaults: first one found in keychain)
#   NOTARY_PROFILE     keychain profile name (default: notarize-profile)
#   SKIP_NOTARIZE=1    sign + DMG only, skip notarize/staple

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCHEME="AgentLog"
APP_NAME="AgentLog.app"
PROJECT="AgentLogApp.xcodeproj"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarize-profile}"

# Resolve notarize authentication once. Prefer keychain profile; fall back to
# App Store Connect API Key env vars (auto-sourcing the shared notarize.env
# from iCloud apple-certs if present).
NOTARY_AUTH=()
if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    echo "==> Notary auth: keychain profile '$NOTARY_PROFILE'"
  else
    # Try env file fallback
    ENV_FILE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Projects/apple-certs/notarize.env"
    if [[ -z "${NOTARIZE_API_KEY_ID:-}" && -f "$ENV_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$ENV_FILE"
    fi
    if [[ -n "${NOTARIZE_API_KEY_ID:-}" && -n "${NOTARIZE_API_ISSUER_ID:-}" && -n "${NOTARIZE_API_KEY_PATH:-}" ]]; then
      NOTARY_AUTH=(--key "$NOTARIZE_API_KEY_PATH" --key-id "$NOTARIZE_API_KEY_ID" --issuer "$NOTARIZE_API_ISSUER_ID")
      echo "==> Notary auth: App Store Connect API Key (key-id: $NOTARIZE_API_KEY_ID)"
    else
      echo "Notary credentials not found. Set up either:" >&2
      echo "  - keychain profile: xcrun notarytool store-credentials $NOTARY_PROFILE ..." >&2
      echo "  - env vars: NOTARIZE_API_KEY_ID / NOTARIZE_API_ISSUER_ID / NOTARIZE_API_KEY_PATH" >&2
      echo "  - or rerun with SKIP_NOTARIZE=1" >&2
      exit 1
    fi
  fi
fi

# Build outside iCloud — File Provider tags every file with com.apple.FinderInfo
# in real time, which breaks codesign --verify. Final DMG is copied back into the
# repo's build/ dir at the end so it's easy to find.
BUILD_DIR="${BUILD_DIR:-/tmp/agentlog-release}"
ARCHIVE_PATH="$BUILD_DIR/AgentLog.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGING="$BUILD_DIR/dmg-staging"
FINAL_DIR="$ROOT/build/release"

mkdir -p "$BUILD_DIR" "$FINAL_DIR"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Developer ID Application/ { print $2; exit }'
  )"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "Could not find a 'Developer ID Application' identity in keychain." >&2
  echo "Run: security find-identity -v -p codesigning" >&2
  exit 1
fi

TEAM_ID="$(printf "%s" "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
if [[ -z "$TEAM_ID" ]]; then
  echo "Could not parse team id from identity: $SIGN_IDENTITY" >&2
  exit 1
fi

MARKETING_VERSION="$(
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$ROOT/App/Info.plist" 2>/dev/null \
  || true
)"
if [[ -z "$MARKETING_VERSION" || "$MARKETING_VERSION" == *'$('* ]]; then
  MARKETING_VERSION="$(
    awk -F'= *' '/MARKETING_VERSION/ { gsub(/[ ;]/,"",$2); print $2; exit }' \
      "$ROOT/$PROJECT/project.pbxproj"
  )"
fi
: "${MARKETING_VERSION:=0.0.0}"

DMG_NAME="AgentLog-${MARKETING_VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

echo "==> Identity:  $SIGN_IDENTITY"
echo "==> Team:      $TEAM_ID"
echo "==> Version:   $MARKETING_VERSION"
echo "==> Output:    $DMG_PATH"

echo "==> Cleaning previous artifacts"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$DMG_STAGING" "$DMG_PATH"

echo "==> Archiving (Release, manual signing)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  archive

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat >"$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
</dict>
</plist>
EOF

echo "==> Exporting archive"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR"

APP_PATH="$EXPORT_DIR/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvv "$APP_PATH" 2>&1 | grep -E '^(Authority|TeamIdentifier|Identifier|Format)='

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Submitting to notary service (profile: $NOTARY_PROFILE)"
  NOTARIZE_ZIP="$BUILD_DIR/AgentLog-notarize.zip"
  rm -f "$NOTARIZE_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    "${NOTARY_AUTH[@]}" \
    --wait

  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose=2 "$APP_PATH"
else
  echo "==> SKIP_NOTARIZE=1 — skipping notarize/staple"
fi

echo "==> Building DMG"
mkdir -p "$DMG_STAGING"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGING/$APP_NAME"
ln -s /Applications "$DMG_STAGING/Applications"

# Spotlight may briefly hold the just-stapled app open ("hdiutil create failed
# - 资源忙"). Disable Spotlight on the staging dir and retry up to 3 times.
mdutil -i off "$DMG_STAGING" >/dev/null 2>&1 || true
for attempt in 1 2 3; do
  if hdiutil create \
      -volname "AgentLog $MARKETING_VERSION" \
      -srcfolder "$DMG_STAGING" \
      -ov \
      -format UDZO \
      "$DMG_PATH"; then
    break
  fi
  echo "  hdiutil create attempt $attempt failed; retrying after 3s"
  sleep 3
done
[[ -f "$DMG_PATH" ]] || { echo "DMG creation failed after retries" >&2; exit 1; }

echo "==> Signing DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [[ "${SKIP_NOTARIZE:-0}" != "1" ]]; then
  echo "==> Notarizing DMG"
  xcrun notarytool submit "$DMG_PATH" \
    "${NOTARY_AUTH[@]}" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

FINAL_DMG="$FINAL_DIR/$DMG_NAME"
echo "==> Copying DMG into repo build dir"
/bin/cp -f "$DMG_PATH" "$FINAL_DMG"

echo
echo "Done."
echo "  App: $APP_PATH"
echo "  DMG: $FINAL_DMG"
