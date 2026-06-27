# Project contract

## Machine and controller assumptions

- One physical 2-axis pen plotter.
- Motion controller: OpenBuilds BlackBox X32 or close equivalent.
- Firmware: grblHAL-compatible.
- Initial transport: USB serial from macOS.
- Possible future transport: Wi-Fi, protocol unknown until observed/documented.
- Pen: servo-controlled, but command mapping is not assumed.
- Motors may be unpowered during initial interrogation.
- Homing and limits may not be configured or trustworthy at project start.

## Non-goals for initial phases

- No SVG import.
- No full CAM pipeline.
- No iPad-native app.
- No closed-loop real-time vision control.
- No automatic firmware settings writes.
- No automatic homing/unlocking.
- No auto-detected servo commands.

## Current architecture boundary

- `plotter_vision.bridge` is the local machine-action boundary. It owns routing, safety validation,
  planning, simulation, controller access, transcripts, and persisted calibration artifacts.
- The macOS app is the operator and visual surface. It can select cameras, collect observations,
  render overlays, and call typed bridge endpoints. It must not own serial transport, raw G-code
  semantics, trust promotion, or persisted model authority.
- Python owns visual-field registration, cap localization, relative motion-model calibration, shape
  planning, simulation, residual solving, and trust flags.
- Preview is separate from execution. Preview endpoints must force dry-run behavior, return simulated
  geometry only, never move hardware, and never write controller transcripts.
- Obsolete compatibility paths should be removed when no external caller exists. Keep setup surfaces
  named for their current bridge contract: visual field registration, green-cap observation, relative
  motion calibration, and validation.
- Manual Machine-panel jogs may expose an explicit operator Boundary Override for stale projected
  workspace bounds. That override is not calibration trust: it is limited to operator-requested jog
  arrows and must not bypass bridge connectivity, live arming, max jog/feed limits, busy/alarm
  guards, pen/drawing gates, or setup validation.

## Canonical fixed-camera flow

The app-first drawing flow is:

1. Start the app against a preview or hardware-standby bridge.
2. Open Visual Field Setup.
3. Confirm the visible green cap detection or click the green cap marker if detection is not usable.
4. Run a machine-video agreement probe before locking or drawing the Drawing Border. The probe
   first measures cap jitter, then runs a cardinal `+X`, `+Y`, `-X`, `-Y` minibatch to get the first
   empirical 2x2 machine-to-video estimate. There is no identity matrix as calibration evidence; before that first
   minibatch the prior is simply no model. Every subsequent solved estimate becomes the current online
   transform, and later relative vectors are chosen from that latest estimate, which may prioritize the
   weaker learned basis and keep refining the matrix. The loop reports update magnitude as the
   convergence signal. Swapped, rotated, skewed, or sign-reversed axes are normal outcomes of the
   learned matrix.
5. Set Drawing Border from the current 2x2 transform. The seeded border uses the Setup panel's
   physical field width and height, defaulting to 200 mm x 150 mm, as operator-assigned dimensions
   on the current video rectangle. The operator can type explicit X and Y millimeter values; changing
   either dimension sets only that dimension and does not infer the other from video aspect.
   Residuals and field-corner precision remain quality diagnostics, but setup must not discard the
   current transform behind a second accepted-estimate gate. Every later solved estimate updates the
   provisional Drawing Border until the operator locks it. The seeded video border is
   operator-adjustable as a rectangle: drag the border to move it, drag the top-right handle to
   resize it while it remains rectangular, and release to re-lock border registration using the
   adjusted corners. Changing field dimensions re-locks the current Drawing Border instead of
   forcing reset and reseed.
6. Validate Motion by moving the cap to visual-field targets through the learned inverse model.
   These validation moves are setup relative jogs and must not be blocked by absolute `MPos`
   workspace projection. Success for this milestone means predictable green-cap motion in the
   user-defined visual drawing field.
7. Treat field registration, cap localization, and a valid relative motion model as the active setup
   authority. During setup, the cap and tip are colocated until explicit binding evidence proves
   otherwise. Cap-to-tip offset, ink observations, and actual drawing are future work.
   The separate setup `Draw Frame` diagnostic may draw an inset border after validation. It must
   compare the expected frame to observed green stroke geometry when the plotter camera can see it,
   and log edge/corner ink residuals as evaluation data rather than a trust-promotion gate.
8. Future drawing surfaces must preview capability checks, shape programs, or portrait/image-derived
   programs through:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

Cap-only motion is relative session evidence. For this milestone, the bridge is ready when the
visual field is registered, the cap is localized in that field, and the learned 2x2 relative motion
model is stable, invertible, and validated by observed cap movement. Machine axes may be swapped,
rotated, skewed, or sign-reversed relative to the video field. Swift observations are evidence;
Python decides whether the border, cap, and motion model are valid. During setup, no bridge-locked
Drawing Border should be drawn until Machine-Video Agreement has produced a current 2x2 estimate and
seeds border registration from that matrix and the operator-selected physical dimensions. The
provisional Drawing Border may update from each current estimate before the lock, but it is not
movement authority until registered. There is no separate plotter-video grid overlay. The UI should
show update magnitude, residuals, and field-corner precision as diagnostics, with update magnitude
approaching zero as the convergence signal.

Swift plotter-camera FOV zoom is persisted operator viewport state only. It may change what the
operator sees on screen, but it must not crop bridge geometry, promote trust, or alter Python-owned
calibration and execution authority. Current segmentation and motion detection occur in
`CameraModel` on the full camera frame when explicitly enabled for visual inspection. They are off
by default, while green-cap tracking stays active for Visual Field Setup. Processing ROI is a
separate Swift observation feature if it is added later.

## Core entities

### ControllerSnapshot

A saved, parsed view of passive controller interrogation. It should include:

- timestamp;
- port/transport;
- firmware identity lines from `$I`;
- parser modal state from `$G`;
- status report from `?`;
- settings from `$$`;
- coordinate parameters from `$#`;
- raw transcript file path;
- parser warnings.

### SafetyState

A serializable state object:

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

### MachineConfig

A serializable config object:

```json
{
  "units": "mm",
  "workspace": {"x_min": 0, "x_max": 300, "y_min": 0, "y_max": 300},
  "max_feed_mm_min": 1200,
  "max_jog_mm": 5,
  "homing_trusted": false,
  "axis_model_trusted": false,
  "pen": {
    "up_command": null,
    "down_command": null
  }
}
```

Use conservative defaults. Make it obvious when config is only a placeholder.

### CalibrationArtifact

A saved JSON artifact from manual or camera-assisted calibration:

```json
{
  "schema_version": 1,
  "created_at": "...",
  "controller_snapshot_id": "...",
  "machine_config_id": "...",
  "method": "human_affine",
  "input_space": "calibration_board_or_image_or_canvas",
  "machine_space": "mm",
  "transform": {
    "type": "affine_2d",
    "matrix": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  },
  "residuals": {
    "rmse_mm": null,
    "max_error_mm": null
  },
  "validated": false,
  "notes": []
}
```

### CommandLogEvent

Every command and response should be represented as data:

```json
{
  "timestamp": "...",
  "direction": "TX",
  "payload": "$I",
  "source": "controller_probe"
}
```

## Local protocol design

Use core service methods and typed request/response models. The HTTP bridge is a frontend boundary,
not the owner of hardware logic.

Preferred pattern:

```text
HTTP route -> service method -> safety validator -> planner/simulator -> controller -> transport
```

Forbidden pattern:

```text
HTTP route -> serial.write(...)
```

## Transport design

Transport should be replaceable:

- `SerialTransport`: implemented first.
- `MockTransport`: implemented for tests and preview workflows.
- `NetworkTransport`: placeholder only until the BlackBox Wi-Fi protocol is verified.

Do not guess network protocol behavior. Add an ADR/TODO after observing official docs or device behavior.

## Error handling

- Treat `error:` as command failure.
- Treat `ALARM:` as safety-critical.
- Timeouts should include the command being waited on.
- Save transcript even on failure.
- Do not hide raw controller lines.

## Style

- Python 3.11+.
- Type hints everywhere reasonable.
- Pydantic models for persisted artifacts and API models.
- Small modules.
- Tests before broad feature expansion.
- Boring code over clever code.
