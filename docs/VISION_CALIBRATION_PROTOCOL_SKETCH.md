# Vision Calibration Protocol Sketch

This is a first sketch for connecting the native camera operator app to the plotter controller without
letting UI or vision code bypass the safety core.

## Boundary

The controller service remains the only process that can talk to the plotter. The native camera app
does not send G-code, unlock alarms, home axes, write settings, or actuate the pen. It publishes
observations: frame reports, changed regions, tracked object coordinates, and candidate calibration
measurements.

## Transport

Use a local append-only event stream first:

- JSONL transcript for replay and tests.
- Local WebSocket for live UI once the service exists.
- Every event carries a monotonic timestamp, a sequence number, and a schema version.

## Core Events

```json
{
  "type": "machine.position_sample",
  "schema": 1,
  "sequence": 42,
  "t_monotonic": 12518.284,
  "command_id": "cmd-000123",
  "status": "Idle",
  "mpos_mm": {"x": 12.5, "y": 30.0, "z": 0.0},
  "wpos_mm": {"x": 12.5, "y": 30.0, "z": 0.0}
}
```

```json
{
  "type": "vision.change_report",
  "schema": 1,
  "sequence": 117,
  "t_monotonic": 12518.307,
  "camera_id": "built-in-wide",
  "frame": 8820,
  "objects": [
    {
      "track_id": "OBJ-03",
      "bbox_norm": {"x": 0.432, "y": 0.517, "w": 0.041, "h": 0.018},
      "center_norm": {"x": 0.452, "y": 0.526},
      "changed_cells": 18,
      "strength": 0.62
    }
  ]
}
```

```json
{
  "type": "calibration.observation",
  "schema": 1,
  "sequence": 12,
  "command_id": "cmd-000123",
  "before_report": 116,
  "after_report": 117,
  "expected_mm": {"x": 12.5, "y": 30.0},
  "observed_norm": {"x": 0.452, "y": 0.526},
  "role": "drawn_mark"
}
```

## Calibration Loop

1. Controller draws a known mark, line, or fiducial under explicit motion safety.
2. Vision reports what changed between averaged frame windows.
3. A calibrator pairs the command ID and expected plotter coordinate with the observed camera
   coordinate.
4. After enough pairs, solve an affine transform or homography from plotter millimeters to camera
   normalized coordinates.
5. Store residuals and reject the solve if the error is too high.

## Later Classifier

A later capabilities test can ask the plotter to draw a randomly selected recognizable figure, then crop the
changed/drawn region and classify it. That should be a presentation layer on top of the geometry
loop, not the foundation. The foundation is still: command IDs, timestamps, observed coordinates,
and calibration residuals.
