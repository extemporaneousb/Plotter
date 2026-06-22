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
  planning, simulation, controller access, transcripts, and persisted calibration/binding artifacts.
- The macOS app is the operator and visual surface. It can select cameras, collect observations,
  render overlays, and call typed bridge endpoints. It must not own serial transport, raw G-code
  semantics, trust promotion, or persisted model authority.
- Python owns calibration, paper registration, shape planning, simulation, residual solving,
  persisted bindings, and trust flags.
- Preview is separate from execution. Preview endpoints must force dry-run behavior, return simulated
  geometry only, never move hardware, and never write controller transcripts.
- Obsolete compatibility paths should be removed when no external caller exists. Keep drawing and
  verification surfaces named for their current bridge contract: capability checks, shape execution,
  binding observations, and image-derived drawing.

## Canonical fixed-camera flow

The app-first drawing flow is:

1. Start the app against a preview or hardware-standby bridge.
2. Open the calibration wizard.
3. Click paper fiducials, solve paper homography, and confirm or localize the cap marker. If a
   restart leaves the bridge with a locked paper homography and the rendered grid still aligns, the
   wizard may Confirm Setup and reuse that registration without re-clicking fiducials.
4. Run visual probe or BOOT-X only when needed to bring relative cap motion into a measured state.
5. Preview binding marks, run watched binding marks, post observations to
   `/calibration/binding/observe`, and solve `/calibration/binding/solve`.
6. Treat the validated `VisualPositionBinding` as the current drawing unlock.
7. Use Draw/Verify to preview capability checks, shape programs, or portrait/image-derived programs
   through:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

Cap-only motion is relative session evidence. Absolute drawing in the paper plane requires a visual
position binding backed by paper homography, cap localization, ink or pen-tip observations,
residuals, camera identity, and freshness. Swift observations are evidence; Python decides whether a
binding or trust flag is valid.

Swift plotter-camera FOV zoom is persisted operator viewport state only. It may change what the
operator sees on screen, but it must not crop bridge geometry, promote trust, or alter Python-owned
calibration and execution authority. Current segmentation and motion detection occur in
`CameraModel` on the full camera frame; processing ROI is a separate Swift observation feature if it
is added later.

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
  "max_feed_mm_min": 600,
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
