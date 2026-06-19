#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/plotter_launcher.sh [smart|preview|live|app|stop|help]

Modes:
  smart    Rebuild/open the latest app. Reuse a live bridge, restart dry-run bridge, or start standby.
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

health_url() {
  local http_port="$1"
  printf 'http://127.0.0.1:%s/health' "$http_port"
}

bridge_health() {
  local http_port="$1"
  curl --max-time 1 -fsS "$(health_url "$http_port")" 2>/dev/null || true
}

smart_launch() {
  local http_port="${HTTP_PORT:-8765}"
  local health
  health="$(bridge_health "$http_port")"

  if [[ -n "$health" ]]; then
    if printf "%s" "$health" | grep -Eq '"dry_run"[[:space:]]*:[[:space:]]*false'; then
      echo "Live bridge is already running at $(health_url "$http_port"); leaving it alone."
      echo "$health"
      run_make app "$@"
    else
      echo "Dry-run bridge is already running at $(health_url "$http_port"); restarting it from current code."
      run_make standby-app HTTP_PORT="$http_port" "$@"
    fi
    return
  fi

  if lsof -tiTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $http_port is in use, but it did not answer as the Plotter bridge." >&2
    echo "Not killing an unknown process. Stop it or choose HTTP_PORT=..." >&2
    exit 2
  fi

  echo "No bridge is running at $(health_url "$http_port"); starting safe hardware standby."
  run_make standby-app HTTP_PORT="$http_port" "$@"
}

mode="${1:-smart}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$mode" in
  smart|open|latest)
    smart_launch "$@"
    ;;
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
