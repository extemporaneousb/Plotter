#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${HOME}/Desktop"
APPLICATIONS_DIR="${HOME}/Applications"
SMART_COMMAND="${DESKTOP_DIR}/Plotter Vision.command"
PREVIEW_COMMAND="${DESKTOP_DIR}/Plotter Vision Dry Run Preview.command"
LEGACY_PREVIEW_COMMAND="${DESKTOP_DIR}/Plotter Vision Preview.command"
LIVE_COMMAND="${DESKTOP_DIR}/Plotter Vision Live.command"
STOP_COMMAND="${DESKTOP_DIR}/Plotter Vision Stop Bridge.command"
SMART_APP="${APPLICATIONS_DIR}/Plotter Vision.app"
LEGACY_PREVIEW_APP="${APPLICATIONS_DIR}/Plotter Vision Preview.app"

mkdir -p "$DESKTOP_DIR" "$APPLICATIONS_DIR"

write_command() {
  local path="$1"
  local mode="$2"

  cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$ROOT_DIR"
./scripts/plotter_launcher.sh "$mode"
EOF
  chmod +x "$path"
}

write_command "$SMART_COMMAND" smart
write_command "$PREVIEW_COMMAND" preview
write_command "$LEGACY_PREVIEW_COMMAND" smart
write_command "$LIVE_COMMAND" live
write_command "$STOP_COMMAND" stop

if command -v osacompile >/dev/null 2>&1; then
  write_app() {
    local app_path="$1"
    local mode="$2"
    local escaped_root
    local tmp_script
    tmp_script="$(mktemp "${TMPDIR:-/tmp}/plotter-launcher.XXXXXX.applescript")"
    escaped_root="$(printf '%s' "$ROOT_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    cat > "$tmp_script" <<EOF
set plotterRepo to "$escaped_root"
set launchCommand to "cd " & quoted form of plotterRepo & " && ./scripts/plotter_launcher.sh $mode"
tell application "Terminal"
  activate
  do script launchCommand
end tell
EOF
    rm -rf "$app_path"
    osacompile -o "$app_path" "$tmp_script"
    rm -f "$tmp_script"
  }

  write_app "$SMART_APP" smart
  write_app "$LEGACY_PREVIEW_APP" smart
else
  echo "osacompile not found; skipped ${SMART_APP}" >&2
  echo "osacompile not found; skipped ${LEGACY_PREVIEW_APP}" >&2
fi

echo "Installed launcher shortcuts:"
echo "  $SMART_COMMAND"
echo "  $PREVIEW_COMMAND"
echo "  $LEGACY_PREVIEW_COMMAND"
echo "  $LIVE_COMMAND"
echo "  $STOP_COMMAND"
if [[ -d "$SMART_APP" ]]; then
  echo "  $SMART_APP"
fi
if [[ -d "$LEGACY_PREVIEW_APP" ]]; then
  echo "  $LEGACY_PREVIEW_APP"
fi
