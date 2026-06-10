# Repository Plan

## Architecture

This repository is moving from a standalone smoke probe toward one core Python package,
`plotter_vision`, with multiple entrypoints. The controller and calibration core stays
independent of any future browser, iPad, or native macOS UI.

Current package shape:

```text
plotter_vision/
  cli.py
  config.py
  controller/
    base.py
    grbl.py
    mock.py
    parser.py
    serial_transport.py
    snapshot.py
tests/
```

The older `smoke_probe/` utility is preserved as reference material, but new work should use
`plotterctl` and the `plotter_vision` package.

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

Status: not started.

- Add manual measurements, scale/sign solving, affine solving, residuals, and calibration artifact JSON.
- Add pen command trial workflow with explicit commands and confirmation.

### Phase 4 — Local UI/API

Status: implemented as a local HTTP bridge plus native macOS camera/control preview.

- Keep the local HTTP server thin until core services are stable enough to justify a heavier API
  framework.
- Route all UI/API calls through core safety validators and controller abstractions.

### Phase 5 — Camera Observation

Status: first vertical slice implemented.

- Add optional camera enumeration/capture and point-picking after human calibration works.

The camera app overlays detected line/shape segments and motion tracks, talks to the local bridge,
renders an alpha-blended plotter bed with app-side alignment controls, and draws the backend's
simulated expected shape path in that plotter plane.

### Phase 5.5 — Command Simulation and Preview Gate

Status: implemented for emitted shape command streams.

- Interpret the same G-code/pen command stream that the bridge would send to hardware.
- Track modal G90/G91, G20/G21, G53 absolute machine moves, feed-only moves, and configured pen
  up/down commands.
- Emit drawn line segments only when the simulated pen is down.
- Verify triangle/square command streams by edge count, side length, continuity, closure, and
  corner angle.
- Include normalized expected path segments in bridge JSON so the macOS video overlay can draw the
  preview path.
- Block shape execution when the simulated geometry fails the gate.

### Phase 6 — Drawing/Vector Ingestion

Status: explicitly deferred.

- Do not implement SVG/vector import until the control and calibration foundation is reliable.
