#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKE_BIN="${PLOTTER_LAUNCHER_MAKE:-/usr/bin/make}"
CURL_BIN="${PLOTTER_LAUNCHER_CURL:-curl}"
LSOF_BIN="${PLOTTER_LAUNCHER_LSOF:-lsof}"
STATUS_PATH="${PLOTTER_LAUNCHER_STATUS_PATH:-${ARTIFACTS:-$ROOT_DIR/artifacts}/launcher_status.json}"

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
  smart    One-click launcher. Open the Swift app; the app owns its bridge process.
  standby  Restart the dry-run serial-capable bridge and relaunch the native camera app.
  preview  Restart the mock dry-run preview bridge and relaunch the native camera app.
  live     Start dry-run hardware standby with an optional port; arm live from inside the app.
  app      Rebuild and relaunch the native camera app and its app-owned bridge.
  stop     Stop the background bridge.

Environment:
  PORT or PLOTTER_CONTROLLER_PORT  Optional controller serial port for live/standby mode.
  BAUD                             Controller baud rate. Default: 115200.
  HTTP_PORT                        Bridge HTTP port. Default: 8765.
  PLOTTER_LAUNCHER_STATUS_PATH     Status artifact path. Default: artifacts/launcher_status.json.
EOF
}

run_make() {
  local status
  log_phase "make -C $ROOT_DIR $*: starting"
  set +e
  "$MAKE_BIN" -C "$ROOT_DIR" "$@"
  status=$?
  set -e
  log_phase "make -C $ROOT_DIR $*: finished status=$status"
  return "$status"
}

health_url() {
  local http_port="$1"
  printf 'http://127.0.0.1:%s/health' "$http_port"
}

bridge_health() {
  local http_port="$1"
  local response
  local status

  log_phase "bridge health: GET $(health_url "$http_port")"
  set +e
  response="$("$CURL_BIN" --max-time 1 -fsS "$(health_url "$http_port")" 2>/dev/null)"
  status=$?
  set -e

  if [[ "$status" -eq 0 && -n "$response" ]]; then
    log_phase "bridge health: response received"
    printf '%s' "$response"
  else
    log_phase "bridge health: no Plotter bridge response (curl status=$status)"
  fi
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
  log_phase "launcher status: wrote $STATUS_PATH action=$action target=$target"
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

stop_dry_run_listener() {
  local http_port="$1"
  local pid

  pid="$("$LSOF_BIN" -tiTCP:"$http_port" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    rm -f "$ROOT_DIR/artifacts/bridge.pid"
    log_phase "external dry-run bridge: stopped pid=$pid on port $http_port"
    sleep 0.2
  fi
}

smart_launch() {
  local http_port="${HTTP_PORT:-8765}"
  local health
  local detected

  log_phase "smart launch: build_id=$PLOTTER_BUILD_ID http_port=$http_port app_owned_bridge=true"
  health="$(bridge_health "$http_port")"

  if [[ -n "$health" ]]; then
    detected="$(bridge_label_from_health "$health")"
    log_phase "bridge health: classified as $detected"
    if [[ "$detected" == "live" ]]; then
      write_launcher_status \
        smart \
        live \
        app \
        preserve_external_live_open_app \
        "$http_port" \
        false \
        "LIVE bridge detected on the legacy port; smart launch leaves it alone and opens the app-owned dev bridge."
      echo "LIVE bridge is already running at $(health_url "$http_port"); leaving it alone. The Swift app will own its development bridge."
      echo "$health"
    elif [[ "$detected" == "preview" || "$detected" == "standby" ]]; then
      stop_dry_run_listener "$http_port"
      write_launcher_status \
        smart \
        "$detected" \
        app \
        stop_external_dry_run_open_app \
        "$http_port" \
        true \
        "Dry-run ${detected} bridge detected on the legacy port; stopped it before opening the app-owned bridge."
      echo "$(printf '%s' "$detected" | tr '[:lower:]' '[:upper:]') dry-run bridge was running at $(health_url "$http_port"); stopped it. The Swift app will own the next bridge."
    else
      write_launcher_status \
        smart \
        unknown \
        app \
        ignore_unclassified_bridge_open_app \
        "$http_port" \
        false \
        "Bridge answered on the legacy port but was unclassified; app launch uses an app-owned ephemeral bridge."
      echo "Bridge answered at $(health_url "$http_port"), but its lifecycle state was not recognized. Leaving it alone and opening the app-owned bridge." >&2
      echo "$health" >&2
    fi
    log_phase "smart launch: opening app with Swift-owned bridge process"
    run_make app "$@"
    return
  fi

  log_phase "smart launch: checking for unknown listener on port $http_port"
  if "$LSOF_BIN" -tiTCP:"$http_port" -sTCP:LISTEN >/dev/null 2>&1; then
    write_launcher_status \
      smart \
      unknown \
      app \
      ignore_unknown_listener_open_app \
      "$http_port" \
      false \
      "Legacy port is in use but did not answer as Plotter; launcher leaves it alone because the app uses an owned ephemeral bridge."
    echo "Port $http_port is in use, but it did not answer as the Plotter bridge." >&2
    echo "Not killing an unknown process. Opening the Swift app with its owned bridge instead." >&2
    log_phase "smart launch: opening app with Swift-owned bridge process"
    run_make app "$@"
    return
  fi

  write_launcher_status \
    smart \
    none \
    app \
    open_app_owned_bridge \
    "$http_port" \
    false \
    "No legacy bridge detected; opening the Swift app, which starts a dry-run hardware-standby bridge child."
  echo "No bridge is running at $(health_url "$http_port"); opening the Swift app with an owned safe bridge."
  log_phase "smart launch: opening app with Swift-owned bridge process"
  run_make app "$@"
}

mode="${1:-smart}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$mode" in
  smart|open|latest)
    log_phase "launcher mode: smart"
    smart_launch "$@"
    ;;
  standby)
    http_port="${HTTP_PORT:-8765}"
    log_phase "launcher mode: standby http_port=$http_port"
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
    log_phase "launcher mode: preview http_port=$http_port"
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
    log_phase "launcher mode: app"
    write_launcher_status \
      app \
      unknown \
      app \
      open_app_owned_bridge \
      "$http_port" \
      false \
      "App launch delegates bridge lifecycle to the Swift app process."
    run_make app "$@"
    ;;
  stop)
    http_port="${HTTP_PORT:-8765}"
    log_phase "launcher mode: stop http_port=$http_port"
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
    log_phase "launcher mode: status-smoke http_port=$http_port"
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
    log_phase "launcher mode: live-standby http_port=$http_port port=${port:-auto}"

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
