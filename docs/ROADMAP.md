# Roadmap

This document owns planning, current package shape, architectural debt, and
maintenance backlog. It should not restate the canonical workflow; that belongs
in `docs/ARCHITECTURE.md`.

## Current Package Shape

```text
plotter_vision/
  cli.py
  config.py
  bridge/
    planner.py
    server.py
  calibration/
    binding.py
    drawing_model.py
    drawing_session.py
    paper.py
    probe_evidence.py
    readiness.py
    scale.py
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
    capabilities.py
    pipeline.py
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

## Current Implementation Status

- Passive controller interrogation and transcript capture are implemented.
- Guarded machine actions, explicit arming, and dry-run defaults are
  implemented.
- The native macOS operator app is the primary operator surface.
- The app-owned bridge lifecycle is implemented for normal launch.
- The unified **Calibrate Vision-Machine Interface** workflow is implemented.
- Field Registration Probe, Drawing Border registration, motion validation,
  drawing sessions, preview/run/observe/retry/fit/validate/finish routes, and
  residual-grid model artifacts are implemented.
- Capability-test programs and portrait/image-derived drawing remain backend or
  focused operator surfaces, not the primary setup path.
- Broad SVG/vector ingestion remains deferred until the current calibration,
  simulation, observation, and correction stack is reliable.

## Architecture Debt

- `plotter_vision.bridge.server` is too large and owns too many responsibilities:
  route table, service orchestration, session flow, machine status building,
  artifact adaptation, and execution glue. Split it by behavior while preserving
  typed route contracts and current JSON output.
- `PlotterBridgeClient.swift`, `PlotterBridgeModel.swift`, and
  `ContentView.swift` remain large. Split by DTOs, HTTP client operations,
  observable model state, workflow coordination, and window/panel boundaries
  without changing public behavior.
- Replace string-parsed Swift status gates with typed visual-field, cap,
  motion-model, drawing-session, and machine status state.
- Centralize camera/viewport coordinate mapping so click layers and overlays use
  one transform.
- Consolidate duplicate paper point models across calibration, drawing, and
  bridge code only after persisted schema compatibility is explicitly handled.

## Maintenance Backlog

Treat each item as a focused patch with current call-site scans and tests:

- Extract a machine-status base builder in `plotter_vision.bridge.server` only
  after proving live, dry-run, hold, lock, and error status payloads remain
  compatible where tests assert them.
- Move repeated JSON artifact write/read helpers into a neutral artifact utility
  while preserving current JSON output.
- Split `PlotterBridgeClient.swift` into DTOs, HTTP client, observable bridge
  model, and operation extensions.
- Split `ContentView.swift` along the current window boundaries and
  visual-motion coordinator responsibilities.
- Keep old-looking compatibility paths only when they have active call-site or
  artifact compatibility evidence. Otherwise remove them rather than preserving
  them as ballast.

## Drawing Calibration Guardrails

Before docs call a model or program path active, classify claims by runtime hits
outside tests. `DrawingProgram` and `multi_shape_coordinate_sheet` must appear
in `plotter_vision.drawing` and bridge planning routes, not only tests.
`residual_grid_v1` must have non-test bridge/model/planner hits before docs call
it active; those hits now live in the drawing model, drawing observation routes,
and optional model-aware drawing planner stage.

Python owns persistence, trust, retry policy, promotion, and planner authority
for drawing calibration sessions and models. Swift can display session/model
state and submit observations, but it does not decide promotion.

Useful scan:

```bash
rg -n "DrawingProgram|multi_shape_coordinate_sheet|build_polygon_draw_plan|residual_grid_v1|model_family|latest_drawing_calibration" plotter_vision macos tests README.md docs
```

## Staging Policy

Cleanup work should be reviewable and landable in phases:

1. Update the owning document first.
2. Remove or move stale documentation from non-owning files.
3. Update tests that intentionally encode the contract.
4. Make code changes only when the new contract requires them.
5. Run the narrowest validation that proves the changed surface.

Do not create standalone cleanup-plan documents for indefinite debt. Put
surviving backlog here.
