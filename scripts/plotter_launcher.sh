#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/plotter_launcher.sh [preview|live|app|stop|help]

Modes:
  preview  Restart the mock dry-run bridge and relaunch the native camera app.
  live     Start the real bridge and app after a controller port and LIVE confirmation.
  app      Rebuild and relaunch only the native camera app.
  stop     Stop the background bridge.

Environment:
  PORT or PLOTTER_CONTROLLER_PORT  Controller serial port for live mode.
  PLOTTER_LIVE_CONFIRM=LIVE        Non-interactive live arming confirmation.
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
      echo "No controller port was supplied."
      echo
      echo "Available ports:"
      run_make ports || true
      echo
      if [[ -t 0 ]]; then
        read -r -p "Controller port (/dev/cu...): " port
      fi
    fi

    if [[ -z "$port" ]]; then
      echo "Refusing live launch without PORT or PLOTTER_CONTROLLER_PORT." >&2
      exit 2
    fi

    echo "Live launch target: $port"
    echo "This will arm homing, motion, pen, and unlock for the bridge."

    confirm="${PLOTTER_LIVE_CONFIRM:-}"
    if [[ "$confirm" != "LIVE" ]]; then
      if [[ -t 0 ]]; then
        read -r -p "Type LIVE to continue: " confirm
      else
        echo "Refusing live launch without PLOTTER_LIVE_CONFIRM=LIVE." >&2
        exit 2
      fi
    fi

    if [[ "$confirm" != "LIVE" ]]; then
      echo "Cancelled."
      exit 2
    fi

    run_make live-app \
      PORT="$port" \
      BAUD="$baud" \
      HTTP_PORT="$http_port" \
      ARM_HOME=1 \
      ARM_MOTION=1 \
      ARM_PEN=1 \
      ARM_UNLOCK=1 \
      NO_DRY_RUN=1 \
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
