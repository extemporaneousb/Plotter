# Plotter Vision Native Operator App

Native macOS camera and operator surface for the fixed-camera Plotter workflow. The app is
intentionally isolated from the machine-control core: it does not talk to serial ports or implement
hardware command semantics itself. Machine actions go through the local Python bridge.

## Build

```bash
./build.sh
```

The script creates:

```text
build/PlotterVision.app
```

The default build path fingerprints Swift sources, `Info.plist`, build metadata, and build settings.
When those inputs are unchanged, `./build.sh` reuses the existing staged app bundle instead of
entering the Swift compiler. Set `PLOTTER_SWIFT_BUILD_SYSTEM=swiftpm` to use the experimental
SwiftPM package path; the default remains direct `swiftc` because it is the faster clean build on
this machine.

## Run Directly

```bash
./run.sh
```

macOS will ask for camera permission the first time the app opens. If permission is denied, enable it
in System Settings > Privacy & Security > Camera for `Plotter Vision`.

For normal operator use from the repository root, prefer:

```bash
make launch
```

`make launch` keeps the app and bridge lifecycle together. Direct `./run.sh` and manual bridge
targets are developer paths for focused debugging.

## Controller Bridge Preview

The normal app launch starts a dry-run hardware-standby bridge as a child of the Swift app process.
The app points its bridge client at that child process on an ephemeral localhost port and stops the
owned child when the app terminates. From the repository root, a direct dry-run hardware-standby
bridge can still be started for focused diagnostics:

```bash
make bridge-standby-bg
```

The native app calls the bridge for typed status, preview, registration, and machine actions,
including:

- `GET /health`
- `GET /machine/status`
- `POST /draw/shape/preview`
- `POST /draw/shape`
- `POST /capabilities/tests/preview`
- `POST /capabilities/tests/run`
- `POST /draw/image/preview`
- `POST /draw/portrait/preview`
- `POST /paper/register`
- `GET /calibration/binding/status`
- `POST /calibration/binding/observe`
- `POST /calibration/binding/solve`
- `POST /calibration/binding/preview`
- `POST /machine/...` actions for arm, reconnect, jog, home, center, pen, stop, resume, and unlock

Real hardware can be connected after the app starts: use the Machine panel's Connect button to
attach a visible USB serial controller and leave dry-run mode. Runtime arming only changes bridge
safety state after `/health` and `/machine/status` show the expected bridge/controller state; it does
not home, unlock, move, or actuate the pen by itself.
If you start a diagnostic bridge manually, stop that manual bridge with `make bridge-stop`.

The bridge uses logical plotter coordinates for planning: `X0 Y0` is the corner opposite the X/Y
homing switches. It converts those logical coordinates to the controller's negative `G53` machine
coordinates when sending motion commands.

## What The App Does

- Shows native AVFoundation plotter and face camera previews.
- Runs Vision passes for line/shape segments, fiducials, carriage markers, and frame-change reports.
- Renders bridge-planned expected paths, visual field state, binding mark preview points, and
  observed marks over the camera image.
- Starts with both camera panes hidden. The Plotter and Face top-bar toggles independently start or
  stop their streams; enabling both shows a split plane, enabling one shows only that pane, and
  enabling neither leaves a black empty workspace.
- Persists plotter-camera viewport controls, including fit/fill, rotation, video filter, and a
  centered FOV zoom. This zoom is an operator display transform only; `CameraModel` still runs
  segmentation and motion analysis against the full camera frame.
- Exposes the Machine panel as the operator surface for bridge/controller state, arm gates, alarms,
  busy state, stop/resume, pen actions, homing, centering, and jogs.
- Exposes Setup as a separate window for manual paper fiducials, cap marker confirmation,
  clearance-aware motion calibration, and watched drawing calibration marks. When the bridge already
  reports a locked visual field after restart and the grid still aligns, Confirm Setup reuses that
  registration without re-clicking fiducials.
- Exposes Plotter Video and Face Video as separate windows. Plotter Video owns viewport, overlay, and
  cap-marker controls. Face Video owns the portrait contour monitor, rendering parameters, capture
  strip, and portrait drawing creation.
- Emits operator UI state into app diagnostics so `/codex/snapshot` includes camera visibility,
  split/empty workspace state, and window visibility.

The current true app flow is:

```text
launch -> Setup -> manual/confirmed fiducials -> cap confirmation
  -> Motion Calibration -> Drawing Calibration
  -> /calibration/binding/observe -> /calibration/binding/solve
  -> validated VisualPositionBinding -> Face Video portrait drawing or future drawing surface
```

If the bridge has a current persisted visual field lock on launch, setup may start at Confirm Setup
instead of manual fiducial capture. This does not create axis trust or a drawing unlock; it only keeps
the Swift workflow aligned with the bridge-owned paper registration that is already locked.

The old Draw/Verify menu and example buttons are removed from the macOS operator UI. Capability and
shape examples remain bridge/backend validation surfaces, not current app controls. Any new drawing
surface should route through the same bridge-owned preview, simulation, execution, and residual gates.

Canonical geometry still belongs in the Python bridge/calibration/drawing layers. Swift overlays are
views over bridge state and local camera observations; they are not motion authority.

Both drawing lanes must preview before machine execution. Preview calls force dry-run behavior,
return simulated geometry for the video overlay, must not move hardware, and must not write
controller transcripts. Preview success is not execution readiness; the bridge's safety and
persisted-binding gates decide whether execution is allowed.
