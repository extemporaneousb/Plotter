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

When UI/API is introduced, use core service methods and typed request/response models. The API is a frontend boundary, not the owner of hardware logic.

Preferred pattern:

```text
FastAPI route -> service method -> safety validator -> controller -> transport
```

Forbidden pattern:

```text
FastAPI route -> serial.write(...)
```

## Transport design

Transport should be replaceable:

- `SerialTransport`: implemented first.
- `MockTransport`: implemented for tests and demos.
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
