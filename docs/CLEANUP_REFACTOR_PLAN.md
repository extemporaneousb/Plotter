# Cleanup and Refactor Plan

This document records the cleanup queue surfaced by the SwiftUI and Python bridge passes. It is not
a feature roadmap; it is a maintenance path for making the existing goal visible in code:

- SwiftUI is the operator/client surface.
- The Python bridge is the local API and machine-action coordinator.
- Machine safety, motion planning, simulation, drawing, and calibration remain Python-owned
  canonical interfaces.
- Preview is separate from execution, and preview routes must stay dry-run even on a live bridge.
- No external caller currently depends on the old demo API. Obsolete compatibility routes, DTOs, UI
  actions, and event names should be removed or renamed into canonical drawing concepts instead of
  preserved for their own sake.
- Simple shapes belong to the capabilities-test lane, not to a separate "demo" product path.

## Completed In This Pass

- Consolidated Python bridge POST dispatch into a route table plus one request validation/write
  helper in `plotter_vision.bridge.server`.
- Consolidated Swift bridge HTTP `GET`/`POST` request construction and response decoding in
  `PlotterBridgeClient`.
- Introduced a shared Python `MachineActionRequest` base for machine command request models that
  carry `request_id`.
- Removed unused SwiftUI helper views from `ContentView`.
- Aligned homing safety with bridge guard semantics by treating `Pn=-` as clear.
- Updated README and repository plan docs to describe the current bridge, app, calibration, paper,
  drawing, and preview-safe execution surfaces.

## Low-Risk Next

- Extract a machine-status base builder in `PlotterBridge` so offline, busy, locked, hold, and error
  statuses share runtime arm/trust fields consistently.
- Move repeated JSON artifact write/read helpers into a neutral artifact utility, preserving current
  JSON output.
- Collapse duplicate CLI plan loaders that do the same existence check and `model_validate_json`
  call.
- Mark `smoke_probe/` as archived/unmaintained reference material before deciding whether to move it
  under docs/archive.
- Remove dormant overlay draw helpers only after a visual verification pass confirms they are not
  part of the current geometry display.

## Medium-Risk Next

- Split `PlotterBridgeClient.swift` into DTOs, HTTP client, observable bridge model, and operation
  extensions without changing public behavior.
- Split `ContentView.swift` into camera panes, menu groups, calibration wizard, image preview, and
  visual-motion coordinator.
- Replace string-parsed Swift status gates with typed paper, dot-test, and machine status state.
- Centralize camera/viewport coordinate mapping so click layers and overlays use one transform.
- Consolidate duplicate paper point models across calibration, drawing, and bridge code with
  compatibility aliases for persisted schemas.
- Remove or rename stale `Demo*` bridge types, `/demo/run`, Swift DTOs, event names, and UI actions
  into shape execution or capabilities-test concepts. Keep compatibility decoding only for persisted
  artifacts that actually exist.

## Higher-Risk Refactors

- Introduce a typed overlay/projection model that treats camera image, paper plane, drawing/logical
  millimeters, machine coordinates, and display transform as explicit spaces. Expected paths,
  dot-test previews, and observed ink marks should be overlay primitives projected through these
  transforms, not independent geometry sources.
- Move visual relative motion and center-dot learning out of `ContentView` into a dedicated state
  machine or actor.
- Generate or share bridge DTO contracts from Python/Pydantic instead of manually maintaining Swift
  DTOs.
- Replace `http.server` with FastAPI/ASGI only after preserving the current local binding behavior,
  dry-run/live gate semantics, and Swift client compatibility.
- Unify all preview and execution planning behind:

```text
DrawingProgram -> Planner -> Simulator -> VideoProjector -> Preview Overlay
  -> Executor -> Vision Observer -> Residual Solver -> Persisted Binding
```

## Acceptance Criteria For The Next Architecture Pass

- The main operator path is app launch, calibration wizard, paper fiducials, paper homography, cap
  localization, draw/measure/adjust calibration, persisted binding, then drawing.
- Python remains the only authority that can promote a persisted binding or trust flag. Swift may
  send observations and render overlays, but it does not own trust decisions.
- Preview routes force dry-run behavior, return simulated geometry only, never move hardware, and do
  not write controller transcripts. Preview success is evidence, not execution readiness.
- Cap-only motion is relative session evidence. Absolute paper-plane drawing requires visual
  position binding from cap localization plus ink or pen-tip observations and residual thresholds.
- Capabilities tests and portrait/image-to-shape both produce `DrawingProgram` data and use the same
  planner, simulator, video projection, execution, observation, and residual path.
- Generic SVG/vector import remains deferred until the control, calibration, simulation, and residual
  foundation is reliable.
- `smoke_probe/` should stay reference-only unless a separate cleanup archives it under docs.
