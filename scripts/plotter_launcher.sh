#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE_BIN="${PLOTTER_LAUNCHER_MAKE:-/usr/bin/make}"
CURL_BIN="${PLOTTER_LAUNCHER_CURL:-curl}"
LSOF_BIN="${PLOTTER_LAUNCHER_LSOF:-lsof}"
STATUS_PATH="${PLOTTER_LAUNCHER_STATUS_PATH:-${ARTIFACTS:-$ROOT_DIR/artifacts}/launcher_status.json}"

current_build_id() {
  git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

PLOTTER_BUILD_ID="${PLOTTER_BUILD_ID:-$(current_build_id)}"
export PLOTTER_BUILD_ID
export PLOTTER_APP_BUILD_ID="${PLOTTER_APP_BUILD_ID:-$PLOTTER_BUILD_ID}"
export PLOTTER_BRIDGE_BUILD_ID="${PLOTTER_BRIDGE_BUILD_ID:-$PLOTTER_BUILD_ID}"

usage() {
  cat <<'EOF'
Usage: scripts/plotter_launcher.sh [smart|standby|preview|live|app|stop|help]

Modes:
  smart    One-click launcher. Preserve live, restart dry-run, or start standby.
  standby  Restart the dry-run serial-capable bridge and relaunch the native camera app.
  preview  Restart the mock dry-run preview bridge and relaunch the native camera app.
  live     Start dry-run hardware standby with an optional port; arm live from inside the app.
  app      Rebuild and relaunch only the native camera app.
  stop     Stop the background bridge.

Environment:
  PORT or PLOTTER_CONTROLLER_PORT  Optional controller serial port for live/standby mode.
  BAUD                             Controller baud rate. Default: 115200.
  HTTP_PORT                        Bridge HTTP port. Default: 8765.
  PLOTTER_LAUNCHER_STATUS_PATH     Status artifact path. Default: artifacts/launcher_status.json.
EOF
}

run_make() {
  "$MAKE_BIN" -C "$ROOT_DIR" "$@"
}

health_url() {
  local http_port="$1"
  printf 'http://127.0.0.1:%s/health' "$http_port"
}

bridge_health() {
  local http_port="$1"
  "$CURL_BIN" --max-time 1 -fsS "$(health_url "$http_port")" 2>/dev/null || true
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

write_launcher_status() {
  local mode="$1"
  local detected="$2"
  local target="$3"
  local action="$4"
  local http_port="$5"
  local safe_restart="$6"
  local detail="${7:-}"
  local status_dir
  local tmp_path

  status_dir="${STATUS_PATH%/*}"
  if [[ "$status_dir" != "$STATUS_PATH" ]]; then
    mkdir -p "$status_dir"
  fi
  tmp_path="${STATUS_PATH}.$$"

  cat > "$tmp_path" <<EOF
{
  "schema_version": 1,
  "updated_at": "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")",
  "mode": "$(json_escape "$mode")",
  "detected": "$(json_escape "$detected")",
  "target": "$(json_escape "$target")",
  "action": "$(json_escape "$action")",
  "http_port": "$(json_escape "$http_port")",
  "bridge_url": "$(json_escape "$(health_url "$http_port")")",
  "build_id": "$(json_escape "$PLOTTER_BUILD_ID")",
  "safe_restart": $safe_restart,
  "detail": "$(json_escape "$detail")"
}
EOF
  mv "$tmp_path" "$STATUS_PATH"
}

health_is_live() {
  local health="$1"
  printf "%s" "$health" | grep -Eq '"dry_run"[[:space:]]*:[[:space:]]*false'
}

health_is_dry_run() {
  local health="$1"
  printf "%s" "$health" | grep -Eq '"dry_run"[[:space:]]*:[[:space:]]*true'
}

health_is_mock_preview() {
  local health="$1"
  printf "%s" "$health" | grep -Eq '"controller"[[:space:]]*:[[:space:]]*"mock"'
}

bridge_label_from_health() {
  local health="$1"
  if health_is_live "$health"; then
    printf 'live'
  elif health_is_dry_run "$health" && health_is_mock_preview "$health"; then
    printf 'preview'
  elif health_is_dry_run "$health"; then
    printf 'standby'
  else
    printf 'unknown'
  fi
}

smart_launch() {
  local http_port="${HTTP_PORT:-8765}"
  local health
  local detected
  health="$(bridge_health "$http_port")"

  if [[ -n "$health" ]]; then
    detected="$(bridge_label_from_health "$health")"
    if [[ "$detected" == "live" ]]; then
      write_launcher_status \
        smart \
        live \
        live \
        reuse_live_bridge_open_app \
        "$http_port" \
        false \
        "LIVE bridge detected; smart launch will not restart or stop it."
      echo "LIVE bridge is already running at $(health_url "$http_port"); leaving it alone."
      echo "$health"
      run_make app "$@"
    elif [[ "$detected" == "preview" || "$detected" == "standby" ]]; then
      write_launcher_status \
        smart \
        "$detected" \
        standby \
        restart_dry_run_bridge_open_app \
        "$http_port" \
        true \
        "Dry-run ${detected} bridge detected; safe restart targets STANDBY."
      echo "$(printf '%s' "$detected" | tr '[:lower:]' '[:upper:]') dry-run bridge is running at $(health_url "$http_port"); restarting as STANDBY from current code."
      run_make standby-app HTTP_PORT="$http_port" "$@"
    else
      write_launcher_status \
        smart \
        unknown \
        none \
        blocked_unrecognized_bridge_health \
        "$http_port" \
        false \
        "Bridge answered health but did not expose a recognized dry_run lifecycle state."
      echo "Bridge answered at $(health_url "$http_port"), but its lifecycle state was not recognized." >&2
      echo "$health" >&2
      echo "Not restarting an unclassified bridge." >&2
      exit 2
    fi
    return
  fi

  if "$LSOF_BIN" -tiTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1; then
    write_launcher_status \
      smart \
      unknown \
      none \
      blocked_unknown_listener \
      "$http_port" \
      false \
      "Port is in use but did not answer as the Plotter bridge; launcher refused to kill it."
    echo "Port $http_port is in use, but it did not answer as the Plotter bridge." >&2
    echo "Not killing an unknown process. Stop it or choose HTTP_PORT=..." >&2
    exit 2
  fi

  write_launcher_status \
    smart \
    none \
    standby \
    start_standby_bridge_open_app \
    "$http_port" \
    false \
    "No bridge detected; starting STANDBY dry-run bridge."
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
  standby)
    http_port="${HTTP_PORT:-8765}"
    write_launcher_status \
      standby \
      unknown \
      standby \
      restart_standby_bridge_open_app \
      "$http_port" \
      true \
      "Explicit STANDBY launch uses the dry-run serial-capable restart path."
    run_make standby-app HTTP_PORT="$http_port" "$@"
    ;;
  preview)
    http_port="${HTTP_PORT:-8765}"
    write_launcher_status \
      preview \
      unknown \
      preview \
      restart_preview_bridge_open_app \
      "$http_port" \
      true \
      "Explicit PREVIEW launch uses the mock dry-run restart path."
    run_make bridge-preview-restart app HTTP_PORT="$http_port" "$@"
    ;;
  app)
    http_port="${HTTP_PORT:-8765}"
    write_launcher_status \
      app \
      unknown \
      app \
      open_app_only \
      "$http_port" \
      false \
      "App-only launch does not touch bridge lifecycle."
    run_make app "$@"
    ;;
  stop)
    http_port="${HTTP_PORT:-8765}"
    write_launcher_status \
      stop \
      unknown \
      stopped \
      stop_bridge \
      "$http_port" \
      false \
      "Explicit stop requested by launcher mode."
    run_make bridge-stop "$@"
    ;;
  status-smoke)
    http_port="${HTTP_PORT:-8765}"
    write_launcher_status \
      status-smoke \
      none \
      none \
      write_status_smoke \
      "$http_port" \
      false \
      "Internal launcher status smoke test."
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

    write_launcher_status \
      live \
      unknown \
      standby \
      start_standby_for_live_arm_in_app \
      "$http_port" \
      true \
      "LIVE mode starts dry-run hardware standby; the app must arm live explicitly."
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
