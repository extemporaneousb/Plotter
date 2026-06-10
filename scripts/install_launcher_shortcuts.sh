#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="${HOME}/Desktop"
APPLICATIONS_DIR="${HOME}/Applications"
PREVIEW_COMMAND="${DESKTOP_DIR}/Plotter Vision Preview.command"
LIVE_COMMAND="${DESKTOP_DIR}/Plotter Vision Live.command"
STOP_COMMAND="${DESKTOP_DIR}/Plotter Vision Stop Bridge.command"
PREVIEW_APP="${APPLICATIONS_DIR}/Plotter Vision Preview.app"

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

write_command "$PREVIEW_COMMAND" preview
write_command "$LIVE_COMMAND" live
write_command "$STOP_COMMAND" stop

if command -v osacompile >/dev/null 2>&1; then
  tmp_script="$(mktemp "${TMPDIR:-/tmp}/plotter-launcher.XXXXXX.applescript")"
  escaped_root="$(printf '%s' "$ROOT_DIR" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  cat > "$tmp_script" <<EOF
set plotterRepo to "$escaped_root"
set launchCommand to "cd " & quoted form of plotterRepo & " && ./scripts/plotter_launcher.sh preview"
tell application "Terminal"
  activate
  do script launchCommand
end tell
EOF
  rm -rf "$PREVIEW_APP"
  osacompile -o "$PREVIEW_APP" "$tmp_script"
  rm -f "$tmp_script"
else
  echo "osacompile not found; skipped ${PREVIEW_APP}" >&2
fi

echo "Installed launcher shortcuts:"
echo "  $PREVIEW_COMMAND"
echo "  $LIVE_COMMAND"
echo "  $STOP_COMMAND"
if [[ -d "$PREVIEW_APP" ]]; then
  echo "  $PREVIEW_APP"
fi
