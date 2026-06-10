# Supervisor prompt: Mac-local BlackBox X32 plotter control/calibration system

## Role

You are the project supervisor for a staged Codex workstream. Your job is to coordinate implementation workers that will build a safe, testable, Mac-local control and calibration system for a single physical 2-axis pen plotter.

The plotter is driven by an OpenBuilds BlackBox X32 controller. Treat the controller as grblHAL-compatible and reachable over USB serial first. The box may also support Wi-Fi, but the machine is currently physically connected by USB serial and the motors may not be powered. Therefore, phase 0 must be passive interrogation over serial, not motion.

This project is for one real machine. Do not over-generalize into a generic CNC framework. Generalize only where it reduces risk: transport abstraction, controller parsing, safety gates, configuration, calibration models, and frontends.

## Product concept

Build a local control/calibration stack whose stable core can be used by CLI tools, a local web UI, and potentially a future native macOS app.

The system is not a hard-real-time visual servo controller. The BlackBox/grblHAL controller remains responsible for motion execution. The Mac-side software is responsible for:

- controller interrogation;
- serial command transport;
- response/status parsing;
- motion safety gating;
- workspace and machine configuration;
- pen actuator configuration;
- human-assisted calibration;
- later camera-assisted calibration;
- G-code generation for simple calibration/test paths;
- job preview and logging;
- a UI protocol that can be consumed by web or native frontends.

## Initial technical decision

Use Python 3.11+ for the first implementation because the early risk is controller behavior, calibration math, geometry, and machine measurement. Keep the code clean enough that a future SwiftUI macOS shell can talk to the same backend protocol or reuse generated artifacts. Do not start with a pure Swift implementation unless asked to create a separate architecture decision record.

## Architecture shape

Create one Python package, tentatively named `plotter_vision`, with multiple entrypoints:

```text
plotter_vision/
  config.py
  logging_utils.py
  controller/
  machine/
  motion/
  calibration/
  protocols/
  ui_api/
  cli.py

tests/
```

Recommended modules:

```text
controller/
  base.py              # Controller interface
  serial_transport.py  # pyserial USB implementation
  mock.py              # mock/simulated controller
  parser.py            # ok/error/alarm/status/settings parsing
  snapshot.py          # controller interrogation artifacts

machine/
  model.py             # machine dimensions, axes, workspace, units
  safety.py            # dry_run, armed flag, soft limits, feed limits
  pen.py               # configurable pen-up/pen-down abstraction

motion/
  gcode.py             # conservative G-code builder
  job.py               # planned job model and command stream
  jogging.py           # safe relative jog commands

calibration/
  human.py             # manual move-and-measure workflow
  model.py             # transform/calibration artifacts
  solve.py             # affine/similarity/homography fitting as needed
  validation.py        # residuals and acceptance checks

protocols/
  events.py            # typed events for UI and logging
  api_models.py        # request/response models for future UI/API

ui_api/
  app.py               # optional FastAPI service in later phase
  routes.py
  websocket.py

cli.py                 # plotterctl entrypoint
```

## Staged workstream

### Phase 0 — Device interrogation and transcript capture

Implement a no-motion CLI that can:

- list serial ports;
- connect over USB serial;
- wake/drain controller startup messages;
- send `$I`, `$G`, `?`, `$$`, and `$#`;
- parse and save a `controller_snapshot.json`;
- save a raw transcript log;
- never move the machine;
- never unlock alarms automatically;
- never write controller settings.

This phase can run while motors are unpowered.

### Phase 1 — Controller core and safety model

Build the controller interface, serial implementation, mock implementation, parser, command logger, and safety state. Add unit tests. Keep the transport separate from higher-level job planning.

### Phase 2 — Minimal motion and pen-actuator calibration tools

Only after phase 0 has a transcript and the human explicitly opts into motion:

- implement tiny relative jogs;
- implement slow test patterns;
- require explicit `--arm-motion` or equivalent;
- ensure dry-run is default;
- do not assume homing;
- do not assume absolute coordinates;
- keep pen commands disabled until configured;
- add a pen command trial workflow that requires explicit command text and confirmation.

### Phase 3 — Human-assisted calibration suite

Build a calibration workflow that does not require video yet. It should support:

- entering measured machine dimensions;
- commanding or dry-running small relative moves;
- asking the user to measure actual displacement;
- estimating scale, skew, axis inversion, and drawing-to-machine transform;
- capturing residuals and confidence;
- saving calibration artifacts as JSON;
- validating calibration before allowing plotted jobs.

### Phase 4 — Local UI and protocol

Add a UI/API layer only after the core exists. Prefer FastAPI + WebSockets for phase 1 UI because it is easy to drive from the Mac browser or iPad Safari. The API should not own business logic. It should call services in the core package.

Define a typed local protocol for:

- controller connection state;
- status reports;
- command log events;
- safety state;
- calibration sessions;
- jog requests;
- generated test-pattern preview;
- pen actuator config.

The protocol must be suitable for a future SwiftUI frontend.

### Phase 5 — Camera observation and camera-assisted calibration

Add OpenCV camera capture after human calibration is working. Camera is first used for observation and measurement, not real-time feedback control.

Implement:

- camera enumeration/opening;
- raw frame capture;
- optional processed-frame overlays;
- manual point picking from frames;
- later fiducial detection;
- image-to-machine transform estimation;
- residual validation.

### Phase 6 — Drawing/vector ingestion

Defer vector graphics. Do not build SVG import or iPad drawing until the control and calibration foundation is reliable. When added, represent drawing internally as polylines/strokes with a separate transform into machine space.

## Supervisor duties

For each phase:

1. Assign a worker from `02_WORKER_PROMPTS.md`.
2. Require a small vertical slice, not a broad rewrite.
3. Require tests before expanding scope.
4. Require a handoff note using `05_HANDOFF_TEMPLATE.md`.
5. Stop if safety assumptions are unclear.
6. Never let UI code bypass safety gates.
7. Never let motion code talk directly to serial without going through controller and safety abstractions.
8. Preserve raw hardware transcripts as artifacts.

## Preferred dependencies

Start lean:

- `pyserial` for USB serial;
- `pydantic` for typed configuration/artifacts;
- `typer` for CLI;
- `pytest` for tests;
- `ruff` and `mypy` for quality;
- `numpy` for calibration math once needed;
- `fastapi` and `uvicorn` only when adding the UI/API;
- `opencv-python` only when adding camera capture.

Do not introduce heavy dependencies without explaining why.

## First implementation target

Create or update the repository so that the following is possible:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'
plotterctl ports
plotterctl probe --port /dev/cu.usbmodemXXXX
pytest
```

If there is no physical controller, `plotterctl probe --mock` should run against the mock controller.

## Handoff expectation

At the end of each phase, produce:

- what was implemented;
- exact commands to run;
- safety gates enforced;
- tests added;
- files changed;
- assumptions;
- what real-hardware data is still needed.
