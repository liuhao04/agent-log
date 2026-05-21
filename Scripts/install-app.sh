#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentLog.app"
APP_PROCESS="AgentLog"
INSTALL_APP="/Applications/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

cd "$ROOT"

xcodebuild \
  -project AgentLogApp.xcodeproj \
  -scheme "AgentLog" \
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

quit_if_running() {
  local proc="$1"
  if pgrep -x "$proc" >/dev/null; then
    osascript -e "tell application \"$proc\" to quit" >/dev/null 2>&1 || true
  fi
}

quit_if_running "$APP_PROCESS"

for _ in {1..30}; do
  pgrep -x "$APP_PROCESS" >/dev/null || break
  sleep 0.2
done

if [[ -x "$LSREGISTER" && -d "$INSTALL_APP" ]]; then
  "$LSREGISTER" -u "$INSTALL_APP" >/dev/null 2>&1 || true
fi

rm -rf "$INSTALL_APP"

ditto "$DERIVED_APP" "$INSTALL_APP"
touch "$INSTALL_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi

killall Dock >/dev/null 2>&1 || true
open "$INSTALL_APP"

echo "Installed and opened $INSTALL_APP"
