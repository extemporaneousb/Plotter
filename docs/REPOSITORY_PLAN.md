# Repository Plan

## Architecture

This repository is moving from a standalone smoke probe toward one core Python package,
`plotter_vision`, with multiple entrypoints. The controller, safety, calibration, drawing, and
simulation core stays independent of any future browser, iPad, or native macOS UI.

Current package shape:

```text
plotter_vision/
  cli.py
  config.py
  bridge/
    planner.py
    server.py
  calibration/
    paper.py
    session.py
    synthetic.py
    vision_model.py
  controller/
    base.py
    grbl.py
    mock.py
    parser.py
    serial_transport.py
    snapshot.py
  drawing/
    polygons.py
    raster.py
  machine/
    homing.py
    pen.py
    safety.py
    settings.py
  motion/
    gcode.py
    simulator.py
macos/
  PlotterVision/
tests/
```

The older `smoke_probe/` utility is preserved as reference material, but new work should use
`plotterctl` and the `plotter_vision` package.

## Canonical Interfaces

- SwiftUI is the operator surface and bridge client. It may render camera observations, visual-field
  locks, expected paths, durable probe evidence, and controller status, but it must not own serial
  transport or hardware command semantics. Plotter-camera FOV zoom is Swift display state for
  operator inspection; it is not calibration authority.
- `plotter_vision.bridge` is the local process boundary. It accepts typed request/response models,
  publishes current controller/runtime state, and routes every machine action through the Python
  safety and controller layers.
- `plotter_vision.machine` owns safety validation, machine configuration, homing/pen/settings
  guards, and trust flags such as `homing_trusted` and `axis_model_trusted`.
- `plotter_vision.motion` and `plotter_vision.bridge.planner` own G-code planning and simulation.
  Preview routes must stay dry-run even when the bridge is connected to live hardware.
- `plotter_vision.calibration` and `plotter_vision.drawing` own geometry artifacts and paper-space
  drawing contracts. Camera-space overlays should be treated as views over these artifacts, not as
  independent motion authority.
- Codex and other agents observe the running system through read-only diagnostics: bridge endpoints,
  append-only JSONL logs, controller transcripts, app state artifacts, and the merged
  `/codex/snapshot`. Agents must not get a hidden command channel inside the app.

## Canonical Drawing Flow

The fixed-camera workflow is:

1. Start the app.
2. Open Setup. The Setup button opens or closes a separate setup window.
3. Click or confirm paper fiducials, then confirm the visual field. If the bridge already has a
   locked visual field after restart and the visible grid still aligns, use Confirm Setup to reuse
   that registration without re-clicking fiducials.
4. Confirm the visible green cap detection or click the green cap marker if detection is not usable.
5. Run or rerun Motion Calibration from the current cap location. Calibration samples bounded
   X/Y cap motion using current machine clearance rather than a fixed positive-X bootstrap.
6. Run Drawing Calibration. The app previews expected binding marks inside the safe drawable region,
   draws the watched visual-relative marks, collects ink observations, posts them through
   `/calibration/binding/observe`, solves `/calibration/binding/solve`, learns the cap-to-tip offset
   from mark residuals, and draws the ready frame around the same region.
7. Use the validated `VisualPositionBinding` as the drawing unlock.
8. Use Face Video for portrait/image-derived drawing after bridge preview. Capability-check examples
   are currently backend tests only and are not exposed in the operator UI.

Both post-calibration drawing lanes use the same pipeline:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

- Capability checks are first-class drawing programs. They should start with simple shapes and move
  toward more complex shape sets, including coordinate markup when useful for residual inspection.
  The canonical order is `center_crosshair`, `line_length`, `square_closure`, `triangle`, then
  `multi_shape_coordinate_sheet`.
- Portrait drawing is camera capture plus contour or polygon extraction, then translation into the
  same `DrawingProgram` contract.
- The simulator is the source for expected pen motion. The video projector maps that expected motion
  into the plotter camera view before execution, and the residual solver compares video-observed ink
  marks against the projected expectation.

## Coordinate Spaces And Authority

The app should not maintain competing geometry sources. It should render views over explicit spaces
and transforms:

| Space | Owner | Purpose |
| --- | --- | --- |
| Camera image space | Swift observes; Python persists evidence | Raw points, contours, cap detections, and ink marks. |
| Paper space | Python bridge/calibration | The registered paper plane from bridge-owned homography. |
| Observed logical millimeters | Python calibration/readiness | Observations in the logical drawing frame. |
| Drawing/logical millimeters | Python drawing/planning | Shape-language coordinates used by `plotter_vision.drawing`. |
| Machine coordinates | Python bridge/machine/motion | Controller coordinates behind planning and safety gates. |
| Display space | Swift | Fit/fill/rotation/FOV zoom and overlay rendering only; it is not motion authority. |

The bridge still has shape and capability-test routes for backend validation, but the current macOS
operator UI does not expose the old Draw/Verify examples. New operator drawing surfaces should route
through `DrawingProgram` preview and execution rather than reintroducing ad hoc example buttons.

Current plotter segmentation and motion detection run in `CameraModel` against the full camera frame.
Restricting processing to a region of interest would be an explicit Swift observation change, not a
side effect of operator zoom.

Cap-marker evidence is session evidence. Motion Calibration measures relative carriage
motion in the registered paper plane; cap-only motion is not enough to set durable
`axis_model_trusted` or unlock absolute drawing. Drawing unlocks should use a persisted visual
position binding backed by field registration, cap localization, a learned cap-to-tip offset, ink
observations, residuals, camera identity, and freshness.

Motion-probe evidence must not remain only in Swift state. The canonical persistence path is
`/calibration/probe/observe`, which stores each commanded move, before/after cap observation,
observed delta, residual, camera identity, paper registration id, transcript pointer, and timestamp.
The bridge does not expose a separate adaptive-probe preview/run motion route; Motion Calibration
chooses bounded motion in the app from live machine clearance and submits the evidence.

Only Python may promote persisted bindings or trust flags. Swift can collect and display evidence,
but it does not decide that `axis_model_trusted`, `homing_trusted`, or
`VisualPositionBinding.validation_status` is valid.

## Staged Task List

### Phase 0 — Passive Controller Interrogation

Status: accepted with real BlackBox X32 transcript.

- List serial ports.
- Probe a mock or USB serial controller with only `$I`, `$G`, `?`, `$$`, and `$#`.
- Save a raw command transcript as JSONL.
- Save a parsed `controller_snapshot.json`.
- Block motion, homing, unlock, check mode, reset, startup-block edits, settings writes, and pen commands.
- Add parser, safety, and mock snapshot tests.

### Phase 1 — Reusable Controller Core

Status: implemented as the second vertical slice.

- Fake transport tests cover timeout, error, alarm, status, realtime hooks, and logging.
- Explicit controller methods exist for feed hold, resume, and soft reset.
- Serial access is kept behind `ControllerTransport`.
- Typed command-result and event surfaces are in place for later UI/API use.
- Wi-Fi/network transport remains deferred pending official docs or real protocol observation.

### Phase 2 — Minimal Motion and Machine Safety

Status: implemented for guarded bridge/manual actions; real streaming remains gated by explicit
human opt-in flags.

- Implement machine config, safety validator, G-code builder, dry-run jog preview, and tiny test patterns.
- Require `--arm-motion` and `--no-dry-run` for any real motion.
- Do not assume homing, coordinate trust, or pen commands.

### Phase 3 — Human-Assisted Calibration

Status: implemented around the Setup window plus Motion and Drawing Calibration. Field
registration, cap/probe evidence, binding observations, and binding solving are owned by the bridge;
the Swift app is the operator surface.

- Continue manual measurements, scale/sign solving, affine solving, residuals, and calibration
  artifact JSON.
- Keep paper registration, visual position binding, and durable machine-axis trust separate.
- Keep pen command trial workflow behind explicit commands and confirmation.

### Phase 4 — Local UI/API

Status: implemented as a local HTTP bridge plus native macOS camera/control preview.

- Keep the local HTTP server thin until core services are stable enough to justify a heavier API
  framework.
- Route all UI/API calls through core safety validators and controller abstractions.
- Preserve the existing observability spine behind the canonical agent surfaces: `/health`,
  `/machine/status`, `/paper/status`, `/codex/events`, `/codex/snapshot`,
  `artifacts/bridge_events.jsonl`, and `artifacts/bridge_transcripts/*.jsonl`.

### Phase 4.5 — Agent-Readable Observability

Status: implemented as a v2 bridge/app diagnostics contract plus native app JSON/OSLog diagnostics.

- Keep `artifacts/app_state.json` as the latest app-observed state. It includes app build identity,
  bridge lifecycle, machine summary, paper registration state, preview state, visible errors, and
  safety gate labels.
- Keep `artifacts/app_events.jsonl` as bounded append-only app evidence for app lifecycle, bridge
  polling, lifecycle mismatches, UI commands, preview/draw requests, visual-probe paths, visible
  errors, and camera-derived state changes. Do not store raw frames.
- Keep `GET /codex/events` as the canonical normalized event stream. It merges app, bridge, and
  controller-adjacent diagnostics using the shared event envelope with source, sequence, timestamp,
  monotonic time, session id, trace id, span ids, command/request ids, status, reason, blockers, and
  payload.
- Keep `GET /codex/snapshot` read-only and first-class. It merges `/health`, cached machine status,
  `/paper/status`, latest app diagnostics, normalized events, computed blockers, active workflow,
  latest visible error, recent traces, and debug-bundle hints. `POST /codex/app/state` and
  `POST /codex/app/events` are append-only diagnostics ingestion routes, not command routes or read
  surfaces.
- Keep `plotterctl doctor --json` and `make debug-snapshot` as the canonical debug-bundle interface.
- Do not route machine commands through `/codex/snapshot` or app artifacts. Any action remains an
  explicit typed bridge route with existing safety gates.
- Keep preview and diagnostic reads non-moving. `/codex/snapshot` must not create controller
  transcripts or poll hardware status.

Validation after integration:

```bash
make check
make bridge-preview-bg
curl -fsS http://127.0.0.1:8765/health | jq '{status, lifecycle_label, dry_run, bridge_build_id, event_log}'
curl -fsS http://127.0.0.1:8765/machine/status | jq '{status, state, is_alarm, is_busy, dry_run}'
curl -fsS http://127.0.0.1:8765/paper/status | jq '{status, dry_run, has_registration: (.registration != null)}'
curl -fsS http://127.0.0.1:8765/codex/events | jq '.events | length'
test -s artifacts/bridge_events.jsonl
test -s artifacts/app_state.json
jq '{reason, app, bridge, machine, paper, previews, gates, updated_at}' artifacts/app_state.json
test -s artifacts/app_events.jsonl
curl -fsS http://127.0.0.1:8765/codex/snapshot \
  | jq '{summary: .state_summary, blockers: .exact_blockers, traces: .recent_traces}'
make debug-snapshot
make bridge-stop
```

### Phase 5 — Camera Observation

Status: first vertical slice implemented.

- Add optional camera enumeration/capture and point-picking after human calibration works.

The camera app overlays detected line/shape segments and motion tracks, talks to the local bridge,
renders paper and expected-path overlays as views over bridge geometry, and keeps display transforms
separate from motion authority.

### Phase 5.5 — Command Simulation and Preview Gate

Status: implemented for shape execution, polygon drawing, capability-check programs, calibration
mark programs, and image-derived contour previews.

- Interpret the same G-code/pen command stream that the bridge would send to hardware.
- Track modal G90/G91, G20/G21, G53 absolute machine moves, feed-only moves, and configured pen
  up/down commands.
- Emit drawn line segments only when the simulated pen is down.
- Verify capability-check command streams by simulation, projected overlay geometry, execution
  gates, and residual observations.
- Include normalized expected path segments in bridge JSON so the macOS video overlay can draw the
  preview path in the registered paper plane.
- Block shape execution when the simulated geometry fails the gate.

### Phase 6 — Drawing/Vector Ingestion

Status: started for image/contour previews, capability checks, and face raster drawing; broad
vector import remains deferred.

- Capability checks and portrait/image-to-shape should use `DrawingProgram` before any broad SVG or
  CAM import.
- Do not implement SVG/vector import until the control, calibration, simulation, and residual
  foundation is reliable.
