#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PlotterVision"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BUILD_FINGERPRINT_PATH="$BUILD_DIR/.PlotterVision.build.sha256"
SWIFT_BUILD_SYSTEM="${PLOTTER_SWIFT_BUILD_SYSTEM:-swiftc}"
SWIFT_BUILD_CONFIGURATION="${PLOTTER_SWIFT_BUILD_CONFIGURATION:-debug}"
SWIFT_BIN="${PLOTTER_SWIFT_BIN:-$(xcrun -f swift)}"
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

build_fingerprint() {
  {
    printf 'app_build_id=%s\n' "$APP_BUILD_ID"
    printf 'repo_root=%s\n' "$REPO_ROOT"
    printf 'swift_build_system=%s\n' "$SWIFT_BUILD_SYSTEM"
    printf 'swift_build_configuration=%s\n' "$SWIFT_BUILD_CONFIGURATION"
    printf 'required_bridge_api_version=3\n'
    if [[ -f "$ROOT_DIR/Package.swift" ]]; then
      shasum -a 256 "$ROOT_DIR/Package.swift"
    fi
    shasum -a 256 "$ROOT_DIR/Info.plist" "$ROOT_DIR/build.sh"
    find "$ROOT_DIR/Sources/PlotterVision" -type f -name '*.swift' -print \
      | sort \
      | while IFS= read -r source_path; do
          shasum -a 256 "$source_path"
        done
  } | shasum -a 256 | awk '{print $1}'
}

SOURCES=("$ROOT_DIR"/Sources/PlotterVision/*.swift)
BUILD_FINGERPRINT="$(build_fingerprint)"

if [[ -x "$MACOS_DIR/$APP_NAME" && -f "$BUILD_FINGERPRINT_PATH" ]]; then
  EXISTING_FINGERPRINT="$(cat "$BUILD_FINGERPRINT_PATH")"
  if [[ "$EXISTING_FINGERPRINT" == "$BUILD_FINGERPRINT" ]]; then
    log_phase "build: inputs unchanged; reusing $APP_DIR"
    echo "$APP_DIR"
    exit 0
  fi
fi

log_phase "build: preparing app bundle $APP_DIR"
if [[ -d "$BUILD_DIR" ]]; then
  find "$BUILD_DIR" -maxdepth 1 -type d -name 'PlotterVision*.app' ! -path "$APP_DIR" -exec rm -rf {} +
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
  /usr/libexec/PlistBuddy -c "Add :PlotterRequiredBridgeAPIVersion integer 3" "$CONTENTS_DIR/Info.plist"
fi

if [[ "$SWIFT_BUILD_SYSTEM" == "swiftpm" ]]; then
  log_phase "build: SwiftPM incremental build ${#SOURCES[@]} Swift files configuration=$SWIFT_BUILD_CONFIGURATION"
  "$SWIFT_BIN" build \
    --package-path "$ROOT_DIR" \
    --configuration "$SWIFT_BUILD_CONFIGURATION" \
    --product "$APP_NAME" \
    --disable-index-store \
    >/dev/null
  SWIFT_BIN_DIR="$("$SWIFT_BIN" build \
    --package-path "$ROOT_DIR" \
    --configuration "$SWIFT_BUILD_CONFIGURATION" \
    --show-bin-path)"
  SWIFT_EXECUTABLE="$SWIFT_BIN_DIR/$APP_NAME"
  if [[ ! -x "$SWIFT_EXECUTABLE" ]]; then
    echo "Swift build did not produce executable: $SWIFT_EXECUTABLE" >&2
    exit 1
  fi
  log_phase "build: SwiftPM build finished executable=$SWIFT_EXECUTABLE"
  log_phase "build: staging executable into app bundle"
  cp "$SWIFT_EXECUTABLE" "$MACOS_DIR/$APP_NAME"
elif [[ "$SWIFT_BUILD_SYSTEM" == "swiftc" ]]; then
  log_phase "build: resolving macOS SDK"
  SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
  log_phase "build: compiling ${#SOURCES[@]} Swift files with direct swiftc"
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
else
  echo "Unknown PLOTTER_SWIFT_BUILD_SYSTEM=$SWIFT_BUILD_SYSTEM (expected swiftc or swiftpm)" >&2
  exit 2
fi

if command -v codesign >/dev/null 2>&1; then
  log_phase "build: codesigning app bundle"
  codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
  log_phase "build: codesign finished"
fi

printf '%s\n' "$BUILD_FINGERPRINT" > "$BUILD_FINGERPRINT_PATH"
log_phase "build: finished $APP_DIR"
echo "$APP_DIR"
