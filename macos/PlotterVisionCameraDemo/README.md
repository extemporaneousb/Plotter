# Plotter Vision

Native macOS camera and operator surface for the fixed-camera Plotter workflow. The app is
intentionally isolated from the machine-control core: it does not talk to serial ports or implement
hardware command semantics itself. Machine actions go through the local Python bridge.

## Build

```bash
./build.sh
```

The script creates:

```text
build/PlotterVisionCamera.app
```

## Run

```bash
./run.sh
```

macOS will ask for camera permission the first time the app opens. If permission is denied, enable it
in System Settings > Privacy & Security > Camera for `Plotter Vision`.

## Controller Bridge Preview

From the repository root, start the local dry-run hardware-standby bridge in the background before
using machine controls in the app:

```bash
make bridge-standby-bg
```

The native app calls the bridge for typed status, preview, registration, and machine actions,
including:

- `GET /health`
- `GET /machine/status`
- `POST /draw/shape/preview`
- `POST /draw/shape`
- `POST /draw/face`
- `POST /paper/register`
- `POST /dot-test/preview`
- `POST /dot-test/run`
- `POST /machine/...` actions for arm, reconnect, jog, home, center, pen, stop, resume, and unlock

Real hardware can be connected after the app starts: use the Machine panel's Connect button to
attach a visible USB serial controller and leave dry-run mode. Runtime arming only changes bridge
safety state after a status query; it does not home, unlock, move, or actuate the pen by itself.
Stop the background bridge with `make bridge-stop`.

The bridge uses logical plotter coordinates for planning: `X0 Y0` is the corner opposite the X/Y
homing switches. It converts those logical coordinates to the controller's negative `G53` machine
coordinates when sending motion commands.

## What The App Does

- Shows native AVFoundation plotter and face camera previews.
- Runs Vision passes for line/shape segments, fiducials, carriage markers, and frame-change reports.
- Renders bridge-planned expected paths, paper homography state, and dot-test preview points over
  the camera image.
- Exposes the Machine panel as the operator surface for bridge/controller state, arm gates, alarms,
  busy state, stop/resume, pen actions, homing, centering, and jogs.
- Supports manual paper fiducials, paper registration, visual cap-marker probing, center-dot preview,
  and preview-safe drawing tests.

Canonical geometry still belongs in the Python bridge/calibration/drawing layers. Swift overlays are
views over bridge state and local camera observations; they are not motion authority.
