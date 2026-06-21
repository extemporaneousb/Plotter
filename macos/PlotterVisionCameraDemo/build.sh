#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PlotterVisionCamera"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_BUILD_ID="${PLOTTER_APP_BUILD_ID:-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf unknown)}"
APP_BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PLOTTER_LAUNCH_STARTED_AT="${PLOTTER_LAUNCH_STARTED_AT:-$(date +%s)}"
PLOTTER_LAUNCH_LOG_PREFIX="${PLOTTER_LAUNCH_LOG_PREFIX:-plotter-launch}"
export PLOTTER_LAUNCH_STARTED_AT
export PLOTTER_LAUNCH_LOG_PREFIX

elapsed_s() {
  local now
  now="$(date +%s)"
  printf '%s' "$((now - PLOTTER_LAUNCH_STARTED_AT))"
}

log_phase() {
  printf '[%s +%ss] %s\n' "$PLOTTER_LAUNCH_LOG_PREFIX" "$(elapsed_s)" "$*" >&2
}

log_phase "build: resolving macOS SDK"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=("$ROOT_DIR"/Sources/PlotterVisionCameraDemo/*.swift)

log_phase "build: preparing app bundle $APP_DIR"
if [[ -d "$BUILD_DIR" ]]; then
  find "$BUILD_DIR" -maxdepth 1 -type d -name 'PlotterVisionCamera*.app' ! -path "$APP_DIR" -exec rm -rf {} +
fi
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -x /usr/libexec/PlistBuddy ]]; then
  log_phase "build: writing Info.plist identity build_id=$APP_BUILD_ID"
  /usr/libexec/PlistBuddy -c "Delete :PlotterAppBuildID" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterSourceRoot" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterBuiltAt" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Delete :PlotterRequiredBridgeAPIVersion" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :PlotterAppBuildID string $APP_BUILD_ID" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterSourceRoot string $REPO_ROOT" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterBuiltAt string $APP_BUILT_AT" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PlotterRequiredBridgeAPIVersion integer 2" "$CONTENTS_DIR/Info.plist"
fi

log_phase "build: compiling ${#SOURCES[@]} Swift files"
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
  "${SOURCES[@]}" \
  -o "$MACOS_DIR/$APP_NAME"
log_phase "build: Swift compile finished"

if command -v codesign >/dev/null 2>&1; then
  log_phase "build: codesigning app bundle"
  codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
  log_phase "build: codesign finished"
fi

log_phase "build: finished $APP_DIR"
echo "$APP_DIR"
