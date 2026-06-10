#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/plotter_launcher.sh [preview|live|app|stop|help]

Modes:
  preview  Restart the dry-run hardware-standby bridge and relaunch the native camera app.
  live     Start the dry-run hardware-standby bridge and app; arm from inside the app.
  app      Rebuild and relaunch only the native camera app.
  stop     Stop the background bridge.

Environment:
  PORT or PLOTTER_CONTROLLER_PORT  Optional controller serial port for live/standby mode.
  BAUD                             Controller baud rate. Default: 115200.
  HTTP_PORT                        Bridge HTTP port. Default: 8765.
EOF
}

run_make() {
  /usr/bin/make -C "$ROOT_DIR" "$@"
}

mode="${1:-preview}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$mode" in
  preview)
    run_make preview-app "$@"
    ;;
  app)
    run_make app "$@"
    ;;
  stop)
    run_make bridge-stop "$@"
    ;;
  live)
    port="${PORT:-${PLOTTER_CONTROLLER_PORT:-}}"
    baud="${BAUD:-115200}"
    http_port="${HTTP_PORT:-8765}"

    if [[ -z "$port" ]]; then
      echo "Starting hardware standby without a fixed controller port."
      echo "Use Connect or Arm Live in the app after the controller is plugged in."
    else
      echo "Starting hardware standby for $port."
    fi

    run_make standby-app \
      PORT="$port" \
      BAUD="$baud" \
      HTTP_PORT="$http_port" \
      "$@"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo "Unknown launch mode: $mode" >&2
    usage >&2
    exit 2
    ;;
esac
