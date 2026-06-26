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
  visual-field registration, cap observations, relative motion calibration, and guarded movement.
- the native operator app in `macos/PlotterVision`: the bridge client and visual surface,
  not a serial controller owner.

Authority stays deliberately narrow: Python owns calibration, bridge routing, safety gates, model
persistence, shape planning, simulation, residual solving, and execution routing. Swift owns
operator interaction, camera observation display, overlay rendering, and typed bridge calls.

Implemented vertical slices now include:

- passive controller interrogation and parsed snapshots;
- guarded machine actions through typed bridge requests and responses;
- Visual Field Setup from Machine-Video Agreement seeded Drawing Border corners, with a draggable
  and resizable video border that re-locks bridge-owned registration artifacts;
- non-homed relative motion calibration that maps machine-relative X/Y moves into visual-field
  millimeters;
- preview-safe shape, raster, capability-check, and image-derived drawing with command-stream simulation;
- live-gated motion controls in the macOS app, with controller state and safety gates visible;
- a windowed operator UI with independent plotter/face camera toggles, Setup, Plotter Video, and
  Face Video panels, plus UI state surfaced in `/codex/snapshot`.

The Machine panel also has an explicit Boundary Override for manual jog arrows. It bypasses the
live projected-workspace guard when stale or untrusted `MPos`/workspace bounds would otherwise block
operator-owned jogs, but it does not bypass bridge connectivity, live arming, feed/step limits,
active-command locks, alarms, pen/drawing gates, or Visual Field Setup validation.

## Canonical Operator Flow

The normal development target is the fixed-camera drawing loop:

1. Start the app against a preview or hardware-standby bridge.
2. Open Setup. The Setup button opens or closes a separate setup window.
3. Confirm the visible green cap detection or click the green cap marker if detection is not usable.
4. Run the machine-video agreement probe before locking or drawing the Drawing Border. The app
   first measures cap jitter, then sends adaptive relative machine vectors on X, Y, and diagonals
   without requiring homing, axis-model trust, absolute machine-position clearance, or a preexisting
   visual field. The loop publishes each solved 2x2 estimate as the current online state, uses the
   latest estimate to prioritize later minibatches, and tracks the relative update magnitude as the
   convergence signal.
   Swapped, rotated, skewed, or sign-reversed axes are normal outcomes of the learned matrix.
5. Set Drawing Border from the current 2x2 machine-video transform. The app places a provisional
   border by projecting the learned machine `+X` and `+Y` basis vectors using the Setup panel's
   physical field width and height, defaulting to 200 mm x 150 mm. Residuals and field-corner
   precision remain visible diagnostics, and every later solved estimate updates the provisional
   Drawing Border until the operator locks it. They do not create a second accepted-estimate gate.
   The seeded video border is operator-adjustable as a rectangle: drag the border to move it, drag
   the top-right handle to resize it while it remains rectangular, and release to re-lock Drawing
   Border registration using the adjusted corners. Changing the declared width/height also re-locks
   the current Drawing Border.
6. Validate Motion by commanding cap motion to visual-field targets using the learned inverse
   relative model through setup relative jogs, not absolute workspace-projected drawing moves.
   Success for this milestone means the green cap can be moved predictably inside the user-defined
   field.
7. Persist the field registration, cap observation, and relative motion model as the current setup
   authority. During setup the cap and tip are treated as colocated until explicit binding evidence
   proves otherwise. Cap-to-tip offset, ink observations, and actual drawing execution are future work.
8. Use Face Video for portrait capture and portrait drawing controls. Capability-check examples are
   currently removed from the operator UI until the next real drawing surface is defined.

Future drawing lanes must run through the same bridge-owned pipeline before real ink motion:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

Simulation is not a decorative UI preview. It is the expected pen motion projected onto the plotter
video stream, and the residual loop compares that expected geometry with video observations of the
actual pen marks.

The plotter-camera FOV zoom in the macOS app is a persisted Swift viewport transform for operator
inspection. It does not crop bridge geometry, promote trust, or change machine authority. Current
segmentation and motion detection run in `CameraModel` on the full camera frame when the operator
enables those visual overlays. They are off by default; green-cap tracking stays active because
Visual Field Setup uses that observation stream. Adding a processing ROI would be a separate
app-side observation change and must keep Python-owned safety and calibration authority intact.

## Calibration Evidence

The operator sequence should stay explicit:

| Step | Action | Evidence recorded | Does not prove |
| --- | --- | --- | --- |
| 1 | Confirm Green Cap | Camera-space cap point | Relative motion model or drawing authority. |
| 2 | Machine-Video Agreement Probe | Cap jitter, commanded relative machine vectors, before/after camera-space cap observations, residuals, condition number, online estimate state, corner precision, learned 2x2 machine-to-video basis | Cap-to-tip offset, ink binding, or drawing authority. |
| 3 | Set Drawing Border | Drawing Border corners, field registration id, border size in millimeters, reprojection error | Pen position or drawing authority. |
| 4 | Validate Motion | Target field coordinate, inverse machine-relative move, observed cap result, residual or blocker | Actual drawing readiness. |
| 5 | Future drawing work | Preview, simulation, execution transcript, ink observations, residuals | A future run if camera, field, controller, or tool state is stale. |

Swift may collect and display probe samples, residuals, and operator events, but Python owns durable
setup readiness, motion-model validation, planning, persistence, and execution routing. Motion
Calibration persists raw before/after cap observations and commanded moves through
`/calibration/probe/observe`; the bridge does not require homing, `homing_trusted`,
`axis_model_trusted`, or absolute `MPos` workspace bounds for Visual Field Setup.

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

The normal operator loop is app-owned. `make launch` incrementally builds the native app bundle and
opens the Swift app. The Swift app process starts a dry-run hardware-standby Python bridge child on
an ephemeral localhost port, writes its session record under `artifacts/dev_session/`, and terminates
that exact child when the app exits:

```bash
make launch
```

The launcher writes its last decision to:

```text
artifacts/launcher_status.json
```

The owned bridge still exposes lifecycle identity through `/health`. The app displays the bridge as
`Preview Bridge`, `Hardware Standby`, `Live Bridge`, `Offline`, `STALE`, or `API` when a bridge/app
mismatch is detected. When launched through `make launch` or `Plotter Vision.app`, the app passes its
current build id to the child bridge so stale app/bridge mismatches are visible.

To install Finder launchers:

```bash
make install-shortcuts
```

That installs:

- `~/Desktop/Plotter Vision.command`
- `~/Applications/Plotter Vision.app`

Both Finder launchers run `scripts/plotter_launcher.sh smart`. The lifecycle labels are:

- `preview`: mock dry-run bridge.
- `standby`: serial-capable dry-run bridge.
- `live`: bridge reports `dry_run: false`.

The smart launcher no longer starts a detached bridge for normal app launch. If a dry-run bridge is
still sitting on the legacy `8765` port, it stops that bridge before opening the app. If a live or
unknown process is on that port, it leaves it alone because the app uses its own ephemeral bridge.
The standby bridge can start before the controller is connected. In the app, use the Machine panel's
Connect button to attach a visible USB serial controller, then Arm Live to enable the runtime homing,
motion, pen, and unlock gates. Arm Live does not home, unlock, move, or actuate the pen by itself.

From Codex, use the same root target:

```bash
make launch
```

For focused diagnostics, the explicit bridge targets still exist. A port-specific hardware-standby
launch through the legacy launcher still starts dry-run standby; live arming happens from the running
UI:

```bash
PORT=/dev/cu.usbserial-XXXX scripts/plotter_launcher.sh live
```

The older fully armed bridge targets still exist for deliberate diagnostics, but the normal app path
is app-owned dry-run standby and runtime arming from the UI.

## Codex Observability

Codex observability is a read-only diagnostics contract. Codex may inspect exported bridge and app
state, event logs, and controller transcripts, but it must not become an in-app command path. Machine
actions still flow through typed bridge routes and the Python safety gates.

The canonical bridge surfaces for agents are:

- `GET /health`: bridge lifecycle, build id, source root, dry-run/live state, arming flags, event log
  path, and workspace dimensions.
- `GET /machine/status`: controller connection, alarm/busy state, pins, mode, arming state, and
  latest known machine position.
- `GET /paper/status`: visual-field registration state. The route name is historical; active setup
  treats the artifact as the user-defined drawing field.
- `GET /calibration/workflow/status`: Visual Field Setup state, including field registration, cap
  localization, relative motion-model validity, and current blockers.
- `GET /codex/events`: recent normalized app, bridge, and controller-adjacent events using the shared
  agent event envelope.
- `GET /codex/snapshot`: the first read for debugging current state. It includes app/bridge build
  identity, bridge online state, machine alarm/busy state, field registration, motion-calibration
  state, active workflow, latest visible error, exact blockers, recent trace summaries, and
  debug-bundle hints.
- `artifacts/bridge_events.jsonl`: append-only bridge event history.
- `artifacts/bridge_transcripts/*.jsonl`: controller command transcripts for status and action
  requests.
- `plotterctl doctor --json` or `make debug-snapshot`: write a timestamped debug bundle under
  `artifacts/debug_snapshots/`.

The app-side diagnostics surfaces are:

- `artifacts/app_state.json`: latest app-observed state, including app/bridge identity, lifecycle
  label, machine summary, visual field lock status, preview state, and safety gate labels.
- `artifacts/app_events.jsonl`: bounded append-only app lifecycle, UI action, bridge polling,
  preview/draw, visual-probe, and visible error events.
- `POST /codex/app/state` and `POST /codex/app/events`: append-only bridge ingestion routes for app
  diagnostics. They are not command routes, and they are not read surfaces.
- `GET /codex/snapshot` and `GET /codex/events`: the only app/bridge observability reads agents
  should use.

Use the live endpoints to understand state before acting:

```bash
curl -fsS http://127.0.0.1:8765/health \
  | jq '{status, lifecycle_label, dry_run, bridge_build_id, arm_motion, arm_pen, event_log}'
curl -fsS http://127.0.0.1:8765/machine/status \
  | jq '{status, state, is_alarm, is_busy, pins, dry_run, arm_motion, arm_pen, homing_trusted, axis_model_trusted}'
curl -fsS http://127.0.0.1:8765/paper/status \
  | jq '{status, dry_run, registration_file, has_field: (.registration != null)}'
curl -fsS http://127.0.0.1:8765/calibration/workflow/status \
  | jq '{field_registered, cap_localized, motion_model_valid, blockers}'
curl -fsS http://127.0.0.1:8765/codex/events | jq '.events[-10:]'
tail -n 20 artifacts/bridge_events.jsonl | jq -c .
```

Include the merged snapshot and debug bundle in the same check:

```bash
jq '{reason, app, bridge, machine, paper, previews, gates, updated_at}' artifacts/app_state.json
tail -n 20 artifacts/app_events.jsonl | jq -c .
curl -fsS http://127.0.0.1:8765/codex/snapshot \
  | jq '{summary: .state_summary, blockers: .exact_blockers, traces: .recent_traces}'
make debug-snapshot
```

Interpretation rules:

- `dry_run: false` only means the bridge can send real commands; it does not imply setup readiness.
  For Visual Field Setup, check arming flags, alarm/busy state, field registration, cap visibility,
  and relative motion-model validity before any movement.
- A stale or mismatched app/bridge build id means relaunch the dry-run bridge/app from the current
  checkout before debugging UI behavior.
- `/codex/events` is the canonical recent event stream; JSONL event logs and transcript files are
  the durable evidence.
- Preview routes and diagnostics must remain transcript-free and non-moving. If a diagnostic action
  emits controller commands, it belongs behind an existing typed bridge action with explicit safety
  gates.

In the app, use Setup as the only setup path: green cap confirmation starts Machine-Video Agreement,
Machine-Video Agreement updates the provisional operator-selected Drawing Border as each solved
estimate improves, and Validate Motion proves that the cap can be sent to visual-field targets by
applying the inverse relative motion model. The active setup UI keeps the bridge-locked Drawing
Border editable and re-locks adjusted corners through field registration. Bridge previews for future
drawing work still simulate command streams before execution.
Capability-check examples remain
available as backend bridge tests, but the current operator setup flow stops at predictable cap motion.
Stop the background preview bridge with:

```bash
make bridge-stop
```

The Visual Field Setup model treats the drawing field as operator-defined visual coordinates with a
known physical width and height, defaulting to 200 mm by 150 mm unless configuration provides a
better editable value. The Setup panel exposes compact width/height controls for this value before
field registration. The controller's `G53` machine coordinates may still be displayed as
diagnostics, but homing state, `axis_model_trusted`, and absolute machine workspace bounds are not
Visual Field Setup authority. The learned 2x2 relative model may swap axes, reverse signs, rotate, or
skew machine motion relative to the video field as long as it is stable, invertible, and validated by
observed cap motion. The setup UI must not draw a bridge-locked Drawing Border until
Machine-Video Agreement has produced a current estimate and seeded border registration; the
provisional Drawing Border may update from each current estimate before the lock, but it is not
movement authority until registered. There is no separate plotter-video grid overlay. Strict 2 mm
field-corner precision remains visible as a refinement metric rather than the
only way to use the estimate. Restart the bridge after model changes so the running process picks up
the current transform.

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
