# Cleanup and Refactor Plan

This document records the cleanup queue surfaced by the SwiftUI and Python bridge passes. It is not
a feature roadmap; it is a maintenance path for making the existing goal visible in code:

- SwiftUI is the operator/client surface.
- The Python bridge is the local API and machine-action coordinator.
- Machine safety, motion planning, simulation, drawing, and calibration remain Python-owned
  canonical interfaces.
- Preview is separate from execution, and preview routes must stay dry-run even on a live bridge.

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
- Rename stale "Demo" bridge types and routes toward shape preview/execution while preserving
  compatibility aliases.

## Higher-Risk Refactors

- Introduce a typed `GeometryOverlayModel` that reconciles viewport box, Swift-detected paper quad,
  bridge paper homography, expected path, and dot-test preview geometry.
- Move visual relative motion and center-dot learning out of `ContentView` into a dedicated state
  machine or actor.
- Generate or share bridge DTO contracts from Python/Pydantic instead of manually maintaining Swift
  DTOs.
- Replace `http.server` with FastAPI/ASGI only after preserving the current local binding behavior,
  dry-run/live gate semantics, and Swift client compatibility.
- Unify all preview and execution planning behind one `PlanBuilder -> Simulator -> Executor`
  pipeline.

## Open Goal Questions

- What is the canonical replacement name for `DemoRunRequest`: shape plan, shape command, or draw
  request?
- Should `smoke_probe/` remain runnable reference code, or should it be archived as historical
  evidence?
- Which geometry source should drive the first trusted absolute drawing proof after paper homography:
  homed machine position, a visual position binding, or both?
- Should clean-launch overlay defaults change in the same cleanup line, or remain a separate UX pass
  with screenshot verification?
