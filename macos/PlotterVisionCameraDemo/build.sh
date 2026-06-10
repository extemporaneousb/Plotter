#!/usr/bin/env bash
set -euo pipefail

APP_NAME="PlotterVisionCamera"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
OLD_APP_DIR="$BUILD_DIR/PlotterVisionCameraDemo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP_DIR"
rm -rf "$OLD_APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

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
