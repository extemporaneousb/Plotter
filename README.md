# Plotter Vision

Mac-local control and calibration foundation for one physical machine: a 2-axis servo pen plotter
driven by an OpenBuilds BlackBox X32 controller running grblHAL-compatible firmware.

The project is still safety-first: interrogate the controller over USB serial, capture real
transcripts, and route motion, calibration, and UI work through a cautious core. The current goal is
to make the fixed-camera operator workflow real enough to prove geometry before expanding into
larger drawing ingestion.

## Current Status

The active system has three canonical surfaces:

- `plotterctl`: the root CLI for passive probes, guarded setup operations, and launching the bridge.
- `plotter_vision.bridge`: the local HTTP bridge that owns machine actions, dry-run/live gates,
  paper registration, dot-test previews, and drawing execution.
- `macos/PlotterVisionCameraDemo`: the native operator surface. It is a bridge client, not a serial
  controller owner.

Implemented vertical slices now include:

- passive controller interrogation and parsed snapshots;
- guarded machine actions through typed bridge requests and responses;
- paper homography registration from manual or detected fiducials;
- preview-safe shape, raster, and dot-test planning with command-stream simulation;
- live-gated motion controls in the macOS app, with controller state and safety gates visible.

The original passive probe remains the safest first hardware contact:

The probe sends only:

```text
$I
$G
?
$$
$#
```

It does not move the machine, unlock alarms, home axes, write settings, enter check mode, reset the
controller, or actuate the pen.

## Install

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
```

Or use the top-level Makefile:

```bash
make install
```

## Safe Mock Probe

Run this first. It uses the same parser and snapshot path as the real serial workflow.

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

## Safe Hardware Probe

List ports:

```bash
plotterctl ports
```

On macOS, prefer `/dev/cu.*` device names for initiating serial connections. Then run the passive
probe with the actual controller port:

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

## Native Camera Plotter Preview

The camera app can now talk to a local controller bridge. Start with the mock dry-run bridge in the
background:

```bash
make bridge-preview-bg
```

Then build and run the native app:

```bash
make app
```

For the normal edit/test loop, use one command. It restarts a dry-run hardware-standby bridge from
the current checkout and relaunches the app:

```bash
make preview-app
```

The shortcut-friendly alias is:

```bash
make launch
```

To install Finder launchers:

```bash
make install-shortcuts
```

That installs:

- `~/Desktop/Plotter Vision Preview.command`
- `~/Desktop/Plotter Vision Live.command`
- `~/Desktop/Plotter Vision Stop Bridge.command`
- `~/Applications/Plotter Vision Preview.app`

The preview shortcut is safe by default: it runs a dry-run bridge and relaunches the app. The bridge
can start before the controller is connected. In the app, use the Machine panel's Connect button to
attach a visible USB serial controller, then Arm Live to enable the runtime homing, motion, pen, and
unlock gates. Arm Live does not home, unlock, move, or actuate the pen by itself.

From Codex, use the same root targets. For preview launch, ask Codex to run:

```bash
make launch
```

For a hardware launch from Codex, use the same safe standby launch. Supplying a port is optional;
without one, the app can connect later when exactly one USB serial controller is visible:

```bash
make launch-live PORT=/dev/cu.usbserial-XXXX
```

The older fully armed bridge targets still exist for deliberate diagnostics, but the normal app path
is to start dry-run and arm hardware from the running UI.

In the app, use the plotter alignment panel to line up the translucent virtual bed with the physical
plotter in the camera frame. The virtual bed uses the machine workspace dimensions from the bridge,
then applies local opacity, scale, offset, and rotation controls in the app. The `Draw` shape action
plans a triangle, simulates the exact emitted command stream, and draws the expected path inside the
aligned plotter plane. For triangle/square shape plans it verifies edge count, side length,
continuity, closure, and corner angle. If the simulated pen path does not produce the requested
shape, the bridge returns a failed response and does not send the command stream.
Stop the background preview bridge with:

```bash
make bridge-stop
```

The machine model treats the drawing workspace as logical plotter coordinates: `X0 Y0` is the
corner opposite the homing switches, while the controller's `G53` machine coordinates are negative
because this machine homes X/Y at the max-switch corner. Restart the bridge after model changes so
the running process picks up the current transform.

Real motion is still gated:

```bash
make bridge-server PORT=/dev/cu.usbserial-A10OF67O \
  ARM_HOME=1 ARM_MOTION=1 ARM_PEN=1 NO_DRY_RUN=1
```

If the controller reports `ALARM:...`, leave it alarmed. Phase 0 intentionally does not send `$X`.
If homing is not configured or trustworthy, do not send `$H`.

## Observed Limit Switch Setup

On the current BlackBox X32 setup, the physical X-max switch reports `Pn=XZ`, the physical Y-max
switch reports `Pn=YZ`, and the idle baseline has reported `Pn=Z`. There is no Z axis on this
machine, so the current safe workflow is to plan and apply only the observed XY homing/limit setting
fix, then re-check pin reports before any homing command exists in this project.

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

Apply it only while all real switches are released and the controller is either `Idle` or reporting
`Alarm` with only `Pn=Z`:

```bash
make apply-xy-homing-settings PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
```

Then verify that the idle pin report no longer shows `Z`:

```bash
make status PORT=/dev/cu.usbserial-A10OF67O
```

Finally, re-run the no-motion switch watcher and press one limit switch at a time:

```bash
make watch-status PORT=/dev/cu.usbserial-A10OF67O STATUS_COUNT=80 STATUS_INTERVAL=0.25
```

Expected observations after the fix:

- idle baseline: no `Pn` field, or `Pn=-` in CLI output
- X-max pressed: `Pn=X`
- Y-max pressed: `Pn=Y`

Do not run `$H` until those observations are captured in transcripts.

If hard limits are enabled, pressing a limit switch may trigger `ALARM:1` before the watcher can
capture the pin. For switch observation only, use the gated hard-limit toggle:

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

Once the controller is `Idle` and `Pn=-`, the configured XY homing command can be previewed:

```bash
make home-preview
```

Actual homing is machine motion and requires a separate gate:

```bash
make home-xy PORT=/dev/cu.usbserial-A10OF67O ARM_HOME=1 NO_DRY_RUN=1
```

First homing attempt reached the Y switch but did not complete because X needed more search travel
and the switch pull-off was too small. The observed successful tuning was:

```bash
make homing-tune-plan HOMING_PULL_OFF=10 X_MAX_TRAVEL=400
make apply-homing-tune PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
make hard-limits-on PORT=/dev/cu.usbserial-A10OF67O ARM_SETTINGS=1
make home-xy PORT=/dev/cu.usbserial-A10OF67O ARM_HOME=1 NO_DRY_RUN=1
```

Successful homing should end with `Idle`, `Pn=-`, `H:1`, and machine position pulled clear
of the switches. With `HOMING_PULL_OFF=10`, expect machine position near
`MPos:-10,-10,0.000`.

Measured physical axis lengths:

- X axis: `21 in` = `533.4 mm`
- Y axis: `8.5 in` = `215.9 mm`

Applied workspace travel settings:

```text
$130=533.400
$131=215.900
```

After writing `$130/$131`, re-run homing because the controller may clear its homed state.

## Tests

```bash
pytest
ruff check .
```

Makefile equivalent:

```bash
make check
```

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

Phase-0 command validation rejects `$X`, `$H`, `$C`, `$RST`, `$N...`, `$NN=value`, `$J=...`,
G-code, M-code, feed/spindle words, axis words, feed hold, resume, and Ctrl-X.

## Plans And Handoffs

- Staged repository plan: `docs/REPOSITORY_PLAN.md`
- Phase-0 handoff: `docs/PHASE0_HANDOFF.md`
- Wi-Fi deferral note: `docs/NETWORK_TRANSPORT_DEFERRED.md`
- Original Codex workstream prompts: `codex_prompts/`

The older `smoke_probe/` directory is preserved as reference material. New implementation work should
use `plotter_vision/` and `plotterctl`.
