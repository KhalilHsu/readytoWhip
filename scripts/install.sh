#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ReadyToWhip"
BUILT_APP="$ROOT_DIR/.build/app/$APP_NAME.app"
TARGET_APP="/Applications/$APP_NAME.app"

"$ROOT_DIR/scripts/build-app.sh"

pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$TARGET_APP"
cp -R "$BUILT_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "$TARGET_APP"
