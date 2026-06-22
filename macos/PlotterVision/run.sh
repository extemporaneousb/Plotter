#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

log_phase "app build: starting"
APP_DIR="$("$ROOT_DIR/build.sh")"
log_phase "app build: finished app_dir=$APP_DIR"

log_phase "app relaunch: stopping existing PlotterVision instances"
osascript -e 'tell application id "com.plottervision.camera" to quit' >/dev/null 2>&1 || true
pkill -x PlotterVision >/dev/null 2>&1 || true

log_phase "app relaunch: opening $APP_DIR"
open -n "$APP_DIR"
log_phase "app relaunch: open requested"
