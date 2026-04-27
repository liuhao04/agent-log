#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Codex CLI Log.app"
DERIVED_APP="$HOME/Library/Developer/Xcode/DerivedData/CodexLogApp-fcurhrthqupbkccuqftekrevpalz/Build/Products/Debug/$APP_NAME"
INSTALL_APP="/Applications/$APP_NAME"

cd "$ROOT"

xcodebuild \
  -project CodexLogApp.xcodeproj \
  -scheme "Codex CLI Log" \
  -configuration Debug \
  -destination "platform=macOS" \
  build

if [[ ! -d "$DERIVED_APP" ]]; then
  DERIVED_APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/$APP_NAME" -type d | sort | tail -1)"
fi

if [[ -z "${DERIVED_APP:-}" || ! -d "$DERIVED_APP" ]]; then
  echo "Could not find built app: $APP_NAME" >&2
  exit 1
fi

rm -rf "$INSTALL_APP"
ditto "$DERIVED_APP" "$INSTALL_APP"
open "$INSTALL_APP"

echo "Installed $INSTALL_APP"
