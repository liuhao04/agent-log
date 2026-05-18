#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AgentLog.app"
APP_PROCESS="AgentLog"
OLD_APP_PROCESSES=(
  "AiCliLog"
  "$(printf "%s %s %s" "AI" "CLI" "Log")"
  "$(printf "%s %s %s" "Codex" "CLI" "Log")"
)
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
for proc in "${OLD_APP_PROCESSES[@]}"; do
  quit_if_running "$proc"
done

for _ in {1..30}; do
  running=0
  pgrep -x "$APP_PROCESS" >/dev/null && running=1
  for proc in "${OLD_APP_PROCESSES[@]}"; do
    pgrep -x "$proc" >/dev/null && running=1
  done
  [[ $running -eq 0 ]] && break
  sleep 0.2
done

unregister_app() {
  local path="$1"
  if [[ -x "$LSREGISTER" && -d "$path" ]]; then
    "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
  fi
}

unregister_app "$INSTALL_APP"
for proc in "${OLD_APP_PROCESSES[@]}"; do
  unregister_app "/Applications/$proc.app"
done

rm -rf "$INSTALL_APP"
for proc in "${OLD_APP_PROCESSES[@]}"; do
  rm -rf "/Applications/$proc.app"
done

ditto "$DERIVED_APP" "$INSTALL_APP"
touch "$INSTALL_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
fi

killall Dock >/dev/null 2>&1 || true
open "$INSTALL_APP"

echo "Installed and opened $INSTALL_APP"
