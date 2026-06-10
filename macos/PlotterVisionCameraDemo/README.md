# Plotter Vision Camera Demo

Native macOS camera scaffold for inspecting a plotter drawing surface. It is intentionally isolated
from the machine-control core: this app does not talk to serial ports, move the plotter, unlock
alarms, home axes, or write settings.

## Build

```bash
./build.sh
```

The script creates:

```text
build/PlotterVisionCameraDemo.app
```

## Run

```bash
./run.sh
```

macOS will ask for camera permission the first time the app opens. If permission is denied, enable it
in System Settings > Privacy & Security > Camera for `Plotter Vision Camera Demo`.

## Controller Bridge Demo

From the repository root, start the local dry-run bridge in the background before pressing the
plotter demo control in the app:

```bash
make bridge-preview-bg
```

The native app calls `http://127.0.0.1:8765/demo/run`, resets the change baseline before the request,
and scans the current frame after the bridge reports completion. Real motion is only available when
the bridge is started separately with `--no-dry-run` and the explicit homing, motion, and pen arms.
Stop the background preview bridge with `make bridge-stop`.

The bridge uses logical plotter coordinates for planning: `X0 Y0` is the corner opposite the X/Y
homing switches. It converts those logical coordinates to the controller's negative `G53` machine
coordinates when sending motion commands.

## What The Demo Does

- Shows a native AVFoundation camera preview.
- Runs a Vision contour pass on live frames.
- Compares averaged frame windows to find what changed roughly once per second.
- Draws translucent contours, boxes, center marks, grid lines, and numeric measurement labels.
- Assigns stable demo labels to changed regions such as `OBJ-03` with normalized coordinates.
- Supports pausing/resuming the stream and scanning the most recent frame.
- Sends a named dry-run or armed demo request to the local controller bridge.
- Exposes segmentation, motion sensitivity, report interval, and minimum-area controls for quickly
  tuning a drawn-surface demo.

The measurements are pixel-space placeholders. Calibration to plotter coordinates belongs in the
Python core once the safety and human-assisted calibration phases are ready.
