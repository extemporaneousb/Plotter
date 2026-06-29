# Runbook

This document owns operational procedures: setup commands, launch behavior,
observability, debug evidence, and hardware-specific notes. Architecture and
workflow authority live in `docs/ARCHITECTURE.md`.

## Install And Check

```bash
make install
make check
```

Focused development commands:

```bash
pytest
ruff check .
```

## App Launch

The normal operator path is app-owned:

```bash
make launch
```

`make launch` builds/opens the native app. The Swift app starts a dry-run
hardware-standby Python bridge child on an ephemeral localhost port, writes a
session record, and terminates that child when the app exits.

The launcher writes its last decision to:

```text
artifacts/launcher_status.json
```

The app-owned bridge session manifest is:

```text
artifacts/dev_session/current.json
```

Use that manifest to discover the current bridge URL:

```bash
jq -r .base_url artifacts/dev_session/current.json
```

Finder launchers can be installed with:

```bash
make install-shortcuts
```

That installs:

- `~/Desktop/Plotter Vision.command`
- `~/Applications/Plotter Vision.app`

Both launchers run `scripts/plotter_launcher.sh smart`. The smart launcher no
longer starts a detached bridge for normal app launch. If a dry-run bridge is
still sitting on the legacy `8765` port, it stops that bridge before opening
the app. If a live or unknown process is on that port, it leaves it alone
because the app uses its own ephemeral bridge.

## Manual Bridge Diagnostics

For focused diagnostics, explicit bridge targets still exist:

```bash
make bridge-standby-bg
make bridge-preview-bg
make bridge-stop
```

A port-specific hardware-standby launch through the launcher starts dry-run
standby. Live arming still happens from the running UI:

```bash
PORT=/dev/cu.usbserial-XXXX scripts/plotter_launcher.sh live
```

Real motion is deliberately gated:

```bash
make bridge-server PORT=/dev/cu.usbserial-A10OF67O \
  ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 NO_DRY_RUN=1
```

If the controller reports `ALARM:...`, leave it alarmed until the operator
chooses a deliberate recovery action. Do not send `$H` unless homing setup has
been verified and the homing gate is explicitly armed.

## Observability

The first read for debugging current live state is the app-owned bridge URL
from `artifacts/dev_session/current.json`, then `/codex/snapshot`:

```bash
BASE_URL=$(jq -r .base_url artifacts/dev_session/current.json)
curl -fsS "$BASE_URL/codex/snapshot" \
  | jq '{summary: .state_summary, blockers: .exact_blockers, traces: .recent_traces}'
```

Core read-only surfaces:

- `GET /health`: bridge lifecycle, build id, source root, dry-run/live state,
  arming flags, event log path, and workspace dimensions.
- `GET /machine/status`: controller connection, alarm/busy state, pins, mode,
  arming state, and latest known machine position.
- `GET /paper/status`: visual-field registration state. The route name is
  historical; active setup treats the artifact as the user-defined drawing
  field.
- `GET /calibration/workflow/status`: composed calibration workflow authority.
- `GET /calibration/drawing/status`: drawing-calibration model visibility.
- `GET /calibration/drawing/session/status`: drawing-calibration session
  visibility.
- `GET /codex/events`: recent normalized app, bridge, and controller-adjacent
  events.
- `GET /codex/snapshot`: merged app/bridge/machine/workflow state.
- `artifacts/bridge_events.jsonl`: append-only bridge event history.
- `artifacts/bridge_transcripts/*.jsonl`: controller command transcripts.
- `artifacts/app_state.json`: latest app-observed state.
- `artifacts/app_events.jsonl`: bounded append-only app lifecycle, UI action,
  bridge polling, preview/draw, visual-probe, and visible error events.

Capture a timestamped debug bundle with:

```bash
make debug-snapshot
```

Interpretation rules:

- `dry_run: false` only means the bridge can send real commands; it does not
  imply setup readiness.
- A stale or mismatched app/bridge build id means relaunch the dry-run
  bridge/app from the current checkout before debugging UI behavior.
- `/codex/events` is the canonical recent event stream; JSONL event logs and
  transcript files are durable evidence.
- Preview routes and diagnostics must remain transcript-free and non-moving.
  If a diagnostic action emits controller commands, it belongs behind an
  existing typed bridge action with explicit safety gates.

## Passive Probe

Run the mock probe first:

```bash
plotterctl probe --mock --transcript artifacts/mock_probe_transcript.jsonl
plotterctl snapshot --mock --out artifacts/mock_snapshot.json \
  --transcript artifacts/mock_snapshot_transcript.jsonl
```

Makefile equivalents:

```bash
make mock-probe
make mock-snapshot
```

List ports:

```bash
plotterctl ports
```

On macOS, prefer `/dev/cu.*` device names for initiating serial connections.
Then run the passive probe with the actual controller port:

```bash
plotterctl probe --port /dev/cu.usbmodemXXXX \
  --transcript artifacts/controller_transcript.jsonl
```

Save the parsed snapshot:

```bash
plotterctl snapshot --port /dev/cu.usbmodemXXXX \
  --out artifacts/controller_snapshot.json \
  --transcript artifacts/controller_snapshot_transcript.jsonl
```

Makefile equivalents:

```bash
make ports
make probe PORT=/dev/cu.usbmodemXXXX
make snapshot PORT=/dev/cu.usbmodemXXXX
```

## Observed Limit Switch Setup

On the current BlackBox X32 setup, the physical X-max switch reports `Pn=XZ`,
the physical Y-max switch reports `Pn=YZ`, and the idle baseline has reported
`Pn=Z`. There is no Z axis on this machine, so the safe workflow is to plan and
apply only the observed XY homing/limit setting fix, then re-check pin reports
before any homing command exists in this project.

Create the plan without contacting the controller:

```bash
make xy-homing-plan
```

The plan writes only:

```text
$5=7
$44=3
$45=0
```

Apply it only while all real switches are released and the controller is either
`Idle` or reporting `Alarm` with only `Pn=Z`:

```bash
make apply-xy-homing-settings PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
```

Then verify that the idle pin report no longer shows `Z`:

```bash
make status PORT=/dev/cu.usbserial-A10OF67O
```

Finally, re-run the no-motion switch watcher and press one limit switch at a
time:

```bash
make watch-status PORT=/dev/cu.usbserial-A10OF67O STATUS_COUNT=80 STATUS_INTERVAL=0.25
```

Expected observations after the fix:

- idle baseline: no `Pn` field, or `Pn=-` in CLI output
- X-max pressed: `Pn=X`
- Y-max pressed: `Pn=Y`

Do not run `$H` until those observations are captured in transcripts.

If hard limits are enabled, pressing a limit switch may trigger `ALARM:1`
before the watcher can capture the pin. For switch observation only, use the
gated hard-limit toggle:

```bash
make hard-limits-off PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
make watch-status PORT=/dev/cu.usbserial-A10OF67O STATUS_COUNT=100 STATUS_INTERVAL=0.20
make hard-limits-on PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
```

Observed after the XY/Z fix:

- idle baseline: `Pn=-`
- X-max pressed: `Pn=X`
- Y-max pressed: `Pn=Y`
- hard limits restored afterward: `$21=1`

Once the controller is `Idle` and `Pn=-`, the configured XY homing command can
be previewed:

```bash
make home-preview
```

Actual homing is machine motion and requires a separate gate:

```bash
make home-xy PORT=/dev/cu.usbserial-A10OF67O ARM_HOME=1 NO_DRY_RUN=1
```

First homing attempt reached the Y switch but did not complete because X needed
more search travel and the switch pull-off was too small. The observed
successful tuning was:

```bash
make homing-tune-plan HOMING_PULL_OFF=10 X_MAX_TRAVEL=400
make apply-homing-tune PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
make hard-limits-on PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
make home-xy PORT=/dev/cu.usbserial-A10OF67O ARM_HOME=1 NO_DRY_RUN=1
```

Successful homing should end with `Idle`, `Pn=-`, `H:1`, and machine position
pulled clear of the switches. With `HOMING_PULL_OFF=10`, expect machine
position near `MPos:-10,-10,0.000`.

Measured physical axis lengths:

- X axis: `21 in` = `533.4 mm`
- Y axis: `8.5 in` = `215.9 mm`

Applied workspace travel settings:

```text
$130=533.400
$131=215.900
```

After writing `$130/$131`, re-run homing because the controller may clear its
homed state.

## Safety Defaults

The initial safety state is:

```json
{
  "dry_run": true,
  "armed_motion": false,
  "allow_settings_write": false,
  "allow_homing": false,
  "allow_unlock": false,
  "allow_pen_actuation": false
}
```

Phase-0 command validation rejects `$X`, `$H`, `$C`, `$RST`, `$N...`,
`$NN=value`, `$J=...`, G-code, M-code, feed/spindle words, axis words, feed
hold, resume, and Ctrl-X.
