#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PlotterVisionCamera"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
APP_BUILD_ID="${PLOTTER_APP_BUILD_ID:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
APP_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ -d "$BUILD_DIR" ]]; then
  find "$BUILD_DIR" -maxdepth 1 -type d -name 'PlotterVisionCamera*.app' ! -path "$APP_DIR" -exec rm -rf {} +
fi
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c "Delete :PlotterAppBuildID" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterSourceRoot" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterBuiltAt" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterRequiredBridgeAPIVersion" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :PlotterAppBuildID string $APP_BUILD_ID" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterSourceRoot string $REPO_ROOT" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterBuiltAt string $APP_BUILT_AT" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterRequiredBridgeAPIVersion integer 2" "$CONTENTS_DIR/Info.plist"
fi

/Library/Developer/CommandLineTools/usr/bin/swiftc \
  -Onone \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework AVFoundation \
  -framework Combine \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework QuartzCore \
  -framework SwiftUI \
  -framework Vision \
  "$ROOT_DIR"/Sources/PlotterVisionCameraDemo/*.swift \
  -o "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
