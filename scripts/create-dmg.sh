#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BACKGROUND_IMAGE="$REPO_ROOT/Resources/DMG/background.png"
readonly VOLUME_NAME="Pass"
readonly WINDOW_WIDTH=520
readonly WINDOW_HEIGHT=520

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/Pass.app /path/to/Pass-version.dmg" >&2
  exit 64
fi

readonly APP_PATH="$1"
readonly OUTPUT_DMG="$2"

if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "Pass.app" ]]; then
  echo "Expected a Pass.app bundle: $APP_PATH" >&2
  exit 66
fi

if [[ ! -f "$BACKGROUND_IMAGE" ]]; then
  echo "Missing DMG background: $BACKGROUND_IMAGE" >&2
  exit 66
fi

if [[ -e "$OUTPUT_DMG" ]]; then
  echo "Refusing to overwrite existing output: $OUTPUT_DMG" >&2
  exit 73
fi

readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pass-dmg.XXXXXX")"
readonly SOURCE_DIR="$WORK_DIR/source"
readonly RW_DMG="$WORK_DIR/Pass-rw.dmg"
readonly MOUNT_DIR="/Volumes/$VOLUME_NAME"

cleanup() {
  if [[ -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -e "$MOUNT_DIR" ]]; then
  echo "Volume is already mounted: $MOUNT_DIR" >&2
  exit 73
fi

mkdir -p "$SOURCE_DIR/.background"
ditto "$APP_PATH" "$SOURCE_DIR/Pass.app"
ditto "$BACKGROUND_IMAGE" "$SOURCE_DIR/.background/background.png"
ln -s /Applications "$SOURCE_DIR/Applications"
chflags hidden "$SOURCE_DIR/.background"
if xcrun -f SetFile >/dev/null 2>&1; then
  xcrun SetFile -a E "$SOURCE_DIR/Pass.app"
fi

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$SOURCE_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -nobrowse \
  "$RW_DMG" >/dev/null

sleep 2

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, $((120 + WINDOW_WIDTH)), $((120 + WINDOW_HEIGHT + 28))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set text size of theViewOptions to 12
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Pass.app" of container window to {145, 375}
    set position of item "Applications" of container window to {375, 145}
    set extension hidden of item "Pass.app" of container window to true
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG" >/dev/null

echo "Created $OUTPUT_DMG"
