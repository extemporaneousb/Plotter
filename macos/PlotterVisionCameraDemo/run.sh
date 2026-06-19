#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$("$ROOT_DIR/build.sh")"

osascript -e 'tell application id "com.plottervision.camera" to quit' >/dev/null 2>&1 || true
pkill -x PlotterVisionCamera >/dev/null 2>&1 || true

open -n "$APP_DIR"
