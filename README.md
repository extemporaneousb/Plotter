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
- the native operator app in `macos/PlotterVisionCameraDemo`: the bridge client and visual surface,
  not a serial controller owner.

Authority stays deliberately narrow: Python owns calibration, bridge routing, safety gates, model
persistence, shape planning, simulation, residual solving, persisted bindings, and execution
routing. Swift owns operator interaction, camera observation display, overlay rendering, and typed
bridge calls.

Implemented vertical slices now include:

- passive controller interrogation and parsed snapshots;
- guarded machine actions through typed bridge requests and responses;
- paper homography registration from wizard-clicked manual fiducials;
- preview-safe shape, raster, and dot-test planning with command-stream simulation;
- live-gated motion controls in the macOS app, with controller state and safety gates visible.

## Canonical Operator Flow

The normal development target is the fixed-camera drawing loop:

1. Start the app against a preview or hardware-standby bridge.
2. Open the calibration wizard.
3. Click the paper fiducials, solve the paper homography, and confirm or localize the visible cap
   marker.
4. If power-off gravity has parked X outside the camera field, use the motion-probe startup recovery
   action to move +X into view. This is a live-gated visibility jog only; it is not homing and does
   not promote axis trust.
5. Run or rerun the motion probe from the current cap location. When the cap is visible near the
   X-min side, the probe may run a +X-only BOOT-X bootstrap before sampling X/Y motion.
6. Preview the expected binding marks on the video stream, draw the watched visual-relative marks,
   collect ink observations, post them to `/calibration/binding/observe`, and solve
   `/calibration/binding/solve`.
7. Treat the validated `VisualPositionBinding` status as the drawing unlock. Capability tests and
   drawing programs still require bridge preview before execution.
7. Persist the learned parameters as future initialization values for the coordinate system and
   shape-language parametrization.
8. Draw through one of two lanes:
   - capabilities tests: simple-to-more-complex shape programs that can include coordinate markup;
   - portrait drawing: camera capture, contour or polygon extraction, and translation into the
     drawing program.

Both drawing lanes must run through the same bridge-owned pipeline before real motion:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

Simulation is not a decorative UI preview. It is the expected pen motion projected onto the plotter
video stream, and the residual loop compares that expected geometry with video observations of the
actual pen marks.

## Calibration And Drawing Tests

The operator sequence should stay explicit:

| Step | Action | Evidence recorded | Does not prove |
| --- | --- | --- | --- |
| 1 | Paper homography | Fiducial corners, paper registration id, reprojection error | Machine axes or pen position. |
| 2 | Cap localization | Camera-space cap point mapped into paper/logical mm | Drawing authority. |
| 3 | Move X into camera field when needed | App event with commanded +X recovery and post-move cap observation if visible | Homing, absolute X zero, or axis trust. |
| 4 | Motion probe / BOOT-X | Probe events, cap observations, Swift motion samples, readiness summaries | Durable absolute drawing trust by itself. |
| 5 | Center mark | Projected center target, watched relative moves, residual checks, ink visibility | Full-field geometry. |
| 6 | Five-point marks | Multiple projected targets and residual/ink observations across the paper | Arbitrary shape correctness. |
| 7 | Capabilities suite | `center_crosshair`, `line_length`, `square_closure`, `triangle`, then `multi_shape_coordinate_sheet` through the shared drawing pipeline | Portrait or image ingestion quality. |
| 8 | Shape or portrait drawing | `DrawingProgram` preview, simulation, projected overlay, execution transcript, residual observations | A future run if camera/paper/controller state is stale. |

Swift may collect and display probe samples, center-mark residuals, and operator events, but Python
must own durable readiness, `VisualPositionBinding`, trust promotion, planning, persistence, and
execution routing. The remaining persistence hardening is to add a Python-owned probe-sample artifact
or route that stores raw before/after cap observations and commanded moves instead of relying only on
Swift-local motion samples plus summary readiness fields.

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

For the normal operator loop, use one command. It is status-aware: it opens against an existing live
bridge without stopping it, restarts a dry-run bridge from the current checkout, or starts a dry-run
hardware-standby bridge when no bridge is running:

```bash
make launch
```

The launcher writes its last lifecycle decision to:

```text
artifacts/launcher_status.json
```

The native app and bridge also exchange lifecycle identity through `/health`. The app displays the
bridge as `Preview Bridge`, `Hardware Standby`, `Live Bridge`, `Offline`, `STALE`, or `API` when a
bridge/app mismatch is detected. When launched through `make launch` or `Plotter Vision.app`, both
the rebuilt app bundle and restarted bridge receive the same build id from the current checkout.

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

The smart launcher never replaces a live bridge. If a live bridge is already running, it leaves the
bridge alone and only relaunches the app. The standby bridge can start before the controller is
connected. In the app, use the Machine panel's Connect button to attach a visible USB serial
controller, then Arm Live to enable the runtime homing, motion, pen, and unlock gates. Arm Live does
not home, unlock, move, or actuate the pen by itself.

From Codex, use the same root target:

```bash
make launch
```

For a port-specific hardware-standby launch, use the launcher directly. This still starts dry-run
standby; live arming happens from the running UI:

```bash
PORT=/dev/cu.usbserial-XXXX scripts/plotter_launcher.sh live
```

The older fully armed bridge targets still exist for deliberate diagnostics, but the normal app path
is to start dry-run and arm hardware from the running UI.

## Codex Observability

Codex observability is a read-only diagnostics contract. Codex may inspect exported bridge and app
state, event logs, and controller transcripts, but it must not become an in-app command path. Machine
actions still flow through typed bridge routes and the Python safety gates.

The bridge surfaces that exist today are:

- `GET /health`: bridge lifecycle, build id, source root, dry-run/live state, arming flags, event log
  path, and workspace dimensions.
- `GET /machine/status`: controller connection, alarm/busy state, pins, mode, arming state, and
  latest known machine position.
- `GET /paper/status`: paper registration and homography state.
- `GET /events`: recent in-memory bridge events.
- `artifacts/bridge_events.jsonl`: append-only bridge event history.
- `artifacts/bridge_transcripts/*.jsonl`: controller command transcripts for status and action
  requests.

The app-side diagnostics surfaces are:

- `artifacts/app_state.json`: latest app-observed state, including app/bridge identity, lifecycle
  label, machine summary, paper lock status, preview state, and safety gate labels.
- `artifacts/app_events.jsonl`: bounded append-only app lifecycle, UI action, bridge polling,
  preview/draw, visual-probe, and visible error events.
- `POST /codex/app/state` and `POST /codex/app/events`: append-only bridge ingestion routes for app
  diagnostics. They are not command routes.
- `GET /codex/app/state`, `GET /codex/app/events`, and `GET /codex/snapshot`: read-only diagnostics
  routes. The merged snapshot combines `/health`, cached machine status, `/paper/status`, recent
  `/events`, and latest app diagnostics when present.

Use the live endpoints to understand state before acting:

```bash
curl -fsS http://127.0.0.1:8765/health \
  | jq '{status, lifecycle_label, dry_run, bridge_build_id, arm_motion, arm_pen, event_log}'
curl -fsS http://127.0.0.1:8765/machine/status \
  | jq '{status, state, is_alarm, is_busy, pins, dry_run, arm_motion, arm_pen, homing_trusted, axis_model_trusted}'
curl -fsS http://127.0.0.1:8765/paper/status \
  | jq '{status, dry_run, registration_file, has_registration: (.registration != null)}'
curl -fsS http://127.0.0.1:8765/calibration/binding/status \
  | jq '{status, binding_file, validation: .binding.validation_status, blockers: .binding.blockers}'
curl -fsS http://127.0.0.1:8765/events | jq '.events[-10:]'
tail -n 20 artifacts/bridge_events.jsonl | jq -c .
```

Include the app artifacts and merged snapshot in the same check:

```bash
jq '{reason, app, bridge, machine, paper, previews, gates, updated_at}' artifacts/app_state.json
tail -n 20 artifacts/app_events.jsonl | jq -c .
curl -fsS http://127.0.0.1:8765/codex/snapshot \
  | jq '{health, machine, paper, app: .app_diagnostics.latest_state.payload, recent_events}'
```

Interpretation rules:

- `dry_run: false` only means the bridge can send real commands; it does not imply drawing readiness.
  Check arming flags, alarm state, `axis_model_trusted`, paper registration, visual binding status,
  and preview simulation before any live operation.
- A stale or mismatched app/bridge build id means relaunch the dry-run bridge/app from the current
  checkout before debugging UI behavior.
- `/events` is recent memory; `bridge_events.jsonl` and transcript files are the durable evidence.
- Preview routes and diagnostics must remain transcript-free and non-moving. If a diagnostic action
  emits controller commands, it belongs behind an existing typed bridge action with explicit safety
  gates.

In the app, use the calibration wizard as the only calibration path: manually clicked paper fiducials
establish the paper plane, the cap marker provides live carriage observations, and binding ink marks
validate the durable `VisualPositionBinding`. Bridge previews simulate the exact command stream and
project the expected path into the camera view before any real drawing action is enabled. If simulated
or observed geometry fails its gate, the bridge returns a failed response and does not send the command
stream.
Stop the background preview bridge with:

```bash
make bridge-stop
```

The machine model treats the drawing workspace as logical plotter coordinates: `X0 Y0` is the
corner opposite the homing switches, while the controller's `G53` machine coordinates are negative
because this machine homes X/Y at the max-switch corner. The fixed-camera workflow adds a
session-local visual position binding on top of that model. A cap-only visual probe is relative
motion evidence; it does not make `axis_model_trusted=true` by itself. Absolute drawing in the paper
plane requires durable `axis_model_trusted=true` or a current validated visual position binding from
ink or pen-tip observations with residuals. Restart the bridge after model changes so the running
process picks up the current transform.

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
