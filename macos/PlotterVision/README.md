# Plotter Vision Native Operator App

Native macOS camera and operator surface for Plotter Vision. This README is
app-local: build, run, permissions, and direct debugging notes only. Canonical
architecture and workflow authority live in `../../docs/ARCHITECTURE.md`.

## Build

```bash
./build.sh
```

The script creates:

```text
build/PlotterVision.app
```

The default build path fingerprints Swift sources, `Info.plist`, build
metadata, and build settings. When those inputs are unchanged, `./build.sh`
reuses the existing staged app bundle instead of entering the Swift compiler.
Set `PLOTTER_SWIFT_BUILD_SYSTEM=swiftpm` to use the experimental SwiftPM package
path; the default remains direct `swiftc` because it is the faster clean build
on this machine.

## Run

For normal operator use from the repository root, prefer:

```bash
make launch
```

`make launch` keeps the app and bridge lifecycle together. The app starts a
dry-run hardware-standby bridge child on an ephemeral localhost port and stops
that owned child when the app terminates.

Direct app relaunch is a developer path:

```bash
./run.sh
```

macOS asks for camera permission the first time the app opens. If permission is
denied, enable it in System Settings > Privacy & Security > Camera for
`Plotter Vision`.

## Direct Bridge Debugging

From the repository root, a direct dry-run hardware-standby bridge can still be
started for focused diagnostics:

```bash
make bridge-standby-bg
```

If you start a diagnostic bridge manually, stop it with:

```bash
make bridge-stop
```

Normal bridge discovery and observability procedures live in
`../../docs/RUNBOOK.md`.

## App Responsibilities

- Shows native AVFoundation plotter and face camera previews.
- Owns operator windows, camera visibility, viewport state, and overlays.
- Renders bridge-planned expected paths, visual field state, cap-marker state,
  binding previews, drawing-session batches, and observed marks.
- Exposes the Machine panel for bridge/controller state, arm gates, alarms,
  busy state, stop/resume, pen actions, homing, centering, and jogs.
- Exposes the **Calibrate Vision-Machine Interface** workflow as the operator
  setup surface.
- Exposes Plotter Video and Face Video as focused operator panels.
- Emits operator UI state into app diagnostics so `/codex/snapshot` includes
  camera visibility, split/empty workspace state, and window visibility.

The app does not talk to serial ports or implement hardware command semantics.
Machine actions go through the local Python bridge.
