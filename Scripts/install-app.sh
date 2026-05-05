#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AiCliLog.app"
APP_PROCESS="AiCliLog"
PREVIOUS_APP_PROCESS="$(printf "%s %s %s" "AI" "CLI" "Log")"
PREVIOUS_APP_NAME="$PREVIOUS_APP_PROCESS.app"
LEGACY_APP_PROCESS="$(printf "%s %s %s" "Codex" "CLI" "Log")"
LEGACY_APP_NAME="$LEGACY_APP_PROCESS.app"
INSTALL_APP="/Applications/$APP_NAME"
PREVIOUS_INSTALL_APP="/Applications/$PREVIOUS_APP_NAME"
LEGACY_INSTALL_APP="/Applications/$LEGACY_APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"

xcodebuild \
  -project AiCliLogApp.xcodeproj \
  -scheme "AiCliLog" \
  -configuration Debug \
  -destination "platform=macOS" \
  build

DERIVED_APP="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/$APP_NAME" -type d -print0 \
    | xargs -0 ls -td 2>/dev/null \
    | head -1
)"

if [[ -z "${DERIVED_APP:-}" || ! -d "$DERIVED_APP" ]]; then
  echo "Could not find built app: $APP_NAME" >&2
  exit 1
fi

if pgrep -x "$APP_PROCESS" >/dev/null || pgrep -x "$PREVIOUS_APP_PROCESS" >/dev/null || pgrep -x "$LEGACY_APP_PROCESS" >/dev/null; then
  osascript -e 'tell application "AiCliLog" to quit' >/dev/null 2>&1 || true
  osascript -e "tell application \"$PREVIOUS_APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  osascript -e "tell application \"$LEGACY_APP_PROCESS\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    if ! pgrep -x "$APP_PROCESS" >/dev/null && ! pgrep -x "$PREVIOUS_APP_PROCESS" >/dev/null && ! pgrep -x "$LEGACY_APP_PROCESS" >/dev/null; then
      break
    fi
    sleep 0.2
  done
fi

if [[ -x "$LSREGISTER" && -d "$INSTALL_APP" ]]; then
  "$LSREGISTER" -u "$INSTALL_APP" >/dev/null 2>&1 || true
fi
if [[ -x "$LSREGISTER" && -d "$PREVIOUS_INSTALL_APP" ]]; then
  "$LSREGISTER" -u "$PREVIOUS_INSTALL_APP" >/dev/null 2>&1 || true
fi
if [[ -x "$LSREGISTER" && -d "$LEGACY_INSTALL_APP" ]]; then
  "$LSREGISTER" -u "$LEGACY_INSTALL_APP" >/dev/null 2>&1 || true
fi

rm -rf "$INSTALL_APP"
rm -rf "$PREVIOUS_INSTALL_APP"
rm -rf "$LEGACY_INSTALL_APP"
ditto "$DERIVED_APP" "$INSTALL_APP"
touch "$INSTALL_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi

killall Dock >/dev/null 2>&1 || true
open "$INSTALL_APP"

echo "Installed and opened $INSTALL_APP"
