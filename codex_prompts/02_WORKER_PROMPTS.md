# Worker prompts

Use these worker prompts under the supervisor. If Codex does not support concurrent workers, run them sequentially. Each worker must preserve module boundaries, add tests, and write a handoff note.

---

## Worker 0 — Device interrogation and smoke-probe worker

You are the device-interrogation worker. Your task is to build the phase-0 no-motion toolchain for communicating with the BlackBox X32 over USB serial.

### Goal

Prove that the Mac can see the controller, open the serial connection, send benign queries, receive responses, parse them, and save a transcript. This must work even if motors are unpowered. It must not move the machine.

### Implement

1. CLI commands:

```bash
plotterctl ports
plotterctl probe --port /dev/cu.usbmodemXXXX
plotterctl probe --mock
plotterctl snapshot --port /dev/cu.usbmodemXXXX --out artifacts/controller_snapshot.json
```

2. Serial behavior:

- use `/dev/cu.*` port names on macOS when available;
- open serial with configurable baud, default 115200;
- send wake sequence `\r\n\r\n`;
- drain startup lines;
- send `$I`, `$G`, `?`, `$$`, and `$#`;
- parse `ok`, `error:`, `ALARM:`, bracketed info lines, settings lines, coordinate parameter lines, and status reports;
- save raw transcript with timestamps and TX/RX direction.

3. Mock behavior:

- implement a mock controller that returns plausible responses for `$I`, `$G`, `?`, `$$`, `$#`;
- use the same parser and snapshot path as the real transport.

4. Safety:

- no motion commands;
- no `$X` unlock;
- no `$H` homing;
- no `$NN=value` writes;
- no pen commands;
- no implicit reset unless explicitly requested in a separate future command.

### Tests

Add unit tests for:

- parser of `ok` and `error:n`;
- parser of status reports like `<Idle|MPos:0.000,0.000,0.000|FS:0,0>`;
- parser of settings lines like `$100=250.000`;
- rejection of unsafe commands in phase 0;
- snapshot object construction from mock responses.

### Acceptance

The following must work:

```bash
plotterctl ports
plotterctl probe --mock
plotterctl snapshot --mock --out artifacts/mock_snapshot.json
pytest
```

The real-hardware path must be documented but not required for tests.

### Handoff

Use `05_HANDOFF_TEMPLATE.md`. Include the expected transcript from `--mock` and exact command for real hardware.

---

## Worker 1 — Controller core and transport worker

You are the controller-core worker. Your task is to turn the smoke-probe code into a clean reusable controller layer.

### Goal

Create a stable controller API that higher-level motion, calibration, and UI code can use without knowing about pyserial details.

### Implement

1. Interfaces:

```python
class ControllerTransport(Protocol):
    def connect(self) -> None: ...
    def disconnect(self) -> None: ...
    def write_line(self, line: str) -> None: ...
    def write_realtime(self, data: bytes) -> None: ...
    def read_line(self, timeout_s: float) -> str | None: ...

class MotionController(Protocol):
    def probe(self) -> ControllerSnapshot: ...
    def send_command(self, command: str) -> CommandResult: ...
    def query_status(self) -> StatusReport: ...
```

2. Implementations:

- `SerialTransport` using pyserial;
- `MockTransport` or `MockController`;
- `GrblHalController` using send-response semantics.

3. Realtime hooks:

- feed hold: `!`;
- cycle start / resume: `~`;
- status query: `?`;
- soft reset: Ctrl-X, but only exposed as an explicit dangerous operation.

4. Command logging:

- every TX/RX line should be represented as a typed log event;
- logs should be printable and serializable.

5. Do not implement Wi-Fi yet. Add only an interface placeholder and a TODO/ADR note explaining what needs to be discovered before network transport can be implemented.

### Tests

Add tests with fake transport. Do not require serial hardware.

### Acceptance

Higher-level code can call `controller.probe()` and receive a typed `ControllerSnapshot` from both mock and fake transports.

---

## Worker 2 — Machine model, safety, and G-code worker

You are the machine-model and safety worker. Your task is to model the physical machine, safety gates, conservative G-code generation, and tiny motion tests.

### Goal

Create enough machine-control code to support safe dimension measurement and pen calibration later, without assuming homing or known coordinates.

### Implement

1. Machine configuration:

- units: millimeters;
- axis names and signs;
- nominal workspace width/height;
- safe feed rates;
- max jog distance per command;
- whether homing is known/trusted;
- dry-run default true.

2. Safety state:

- `dry_run: bool = True`;
- `armed_motion: bool = False`;
- `allow_settings_write: bool = False`;
- `allow_homing: bool = False`;
- `allow_unlock: bool = False`;
- `allow_pen_actuation: bool = False`.

3. Safety validator:

- reject motion unless armed and not dry-run;
- reject G-code outside allowed phase;
- reject settings writes by default;
- reject homing/unlock unless explicitly allowed;
- enforce max feed and max relative jog distance.

4. G-code builder:

- `G21` units mm;
- `G90`/`G91` mode handling;
- `G94` feed per minute;
- conservative `G1` moves;
- `G4 P0.01` sync/dwell command;
- comments;
- no vector import.

5. CLI commands:

```bash
plotterctl no-motion --mock
plotterctl no-motion --port /dev/cu.usbmodemXXXX
plotterctl jog --axis X --distance 1.0 --feed 60 --arm-motion --port /dev/cu.usbmodemXXXX
plotterctl test-square --size-mm 5 --feed 120 --arm-motion --port /dev/cu.usbmodemXXXX
```

For real hardware, motion commands require explicit arming flags. Dry-run preview should be available without arming.

### Tests

Test safety rejection first. Tests should prove that motion is blocked unless the correct gates are open.

### Acceptance

A user can generate and preview tiny relative-motion G-code without moving the machine. Real streaming is gated.

---

## Worker 3 — Human-assisted calibration worker

You are the human-assisted calibration worker. Your task is to build a calibration suite that works before camera automation exists.

### Goal

Enable machine dimension measurement, axis direction confirmation, motion scale estimation, and pen servo calibration through a guided workflow. Human measurements and observations are first-class inputs. Later, camera observations can replace or augment them.

### Implement

1. Calibration session model:

- session id;
- machine config version;
- controller snapshot id;
- operator notes;
- measurement records;
- solved calibration artifact;
- validation status.

2. Measurement protocol:

- ask the user to physically measure nominal bed/workspace dimensions;
- optionally command/dry-run a relative move;
- record commanded displacement and measured displacement;
- record axis direction observations;
- record whether axes are orthogonal or visibly skewed;
- support repeated measurements and residuals.

3. Calibration solvers:

Start simple:

- 1D scale estimate per axis from commanded vs measured moves;
- sign/inversion detection from user observation;
- affine 2D transform from at least 3 point correspondences if provided;
- residual reporting.

4. Calibration artifact:

Save JSON containing:

- machine coordinate convention;
- input coordinate convention;
- scale factors;
- offsets;
- affine matrix if solved;
- residuals;
- validation status;
- timestamp and controller snapshot reference.

5. CLI workflow:

```bash
plotterctl calibrate start
plotterctl calibrate add-measurement ...
plotterctl calibrate solve ...
plotterctl calibrate validate ...
plotterctl calibrate show ...
```

A simple interactive mode is acceptable if it is cleanly separated from core logic.

6. Pen servo calibration:

Do not guess servo commands. Implement a configuration/trial workflow:

- show current configured `pen_up_command` and `pen_down_command`;
- allow user to enter candidate commands;
- require explicit confirmation before sending;
- record observations: up/down/too high/too low/no movement;
- save selected commands only after confirmation;
- do not actuate pen by default.

### Tests

- solve scale from measurements;
- solve affine transform from known correspondences;
- residual computation;
- calibration artifact serialization;
- pen command workflow rejects empty/dangerous commands unless explicitly allowed.

### Acceptance

The user can perform a no-camera calibration workflow using manual observations and measurements, producing a JSON artifact that later stages can consume.

---

## Worker 4 — Local UI/API and protocol worker

You are the UI/API worker. Your task is to expose the core control/calibration services through a local protocol suitable for browser UI now and native macOS UI later.

### Goal

Create a local backend API without moving business logic into route handlers.

### Implement

Use FastAPI only after core services exist. Create typed request/response models for:

- controller connection;
- controller snapshot/probe;
- status polling;
- command log events;
- safety state;
- dry-run toggle;
- arming/disarming;
- no-motion command;
- jog request;
- test pattern generation;
- binding preview, observation, and solve flow;
- calibration measurement entry;
- calibration solve/validate;
- pen actuator configuration/trial.

Recommended endpoints:

```text
GET  /api/health
GET  /api/ports
POST /api/controller/connect
POST /api/controller/probe
GET  /api/controller/status
GET  /api/controller/snapshot
GET  /api/safety
POST /api/safety/arm
POST /api/safety/disarm
POST /api/realtime/feed-hold
POST /api/realtime/resume
POST /api/realtime/soft-reset
POST /api/motion/jog
POST /api/motion/test-pattern
POST /api/calibration/session
POST /api/calibration/measurement
POST /api/calibration/solve
POST /api/pen/trial
WS   /ws/events
```

Rules:

- UI routes must call core services.
- UI cannot bypass safety.
- WebSocket events must include command log, controller status, and safety-state changes.
- Default to mock controller unless a real port is selected.

A minimal browser UI is acceptable:

- connect/probe panel;
- transcript/log panel;
- safety state panel;
- calibration workflow form;
- jog/test-pattern preview;
- emergency feed-hold button.

### Tests

Use FastAPI TestClient where possible. Do not require real hardware.

### Acceptance

`plotterctl serve --mock` starts a local UI/API, probes mock hardware, and runs the calibration workflow against mock/no-motion services.

---

## Worker 5 — Camera observation worker

You are the camera-observation worker. Your task is to add camera capture after the human calibration workflow is working.

### Goal

Use the Mac camera for observation and later calibration evidence. Do not attempt closed-loop real-time visual servoing.

### Implement

1. Camera service:

- enumerate/open camera index;
- capture frames with OpenCV;
- handle no-camera gracefully;
- provide raw frame snapshots;
- optionally provide JPEG frames to UI.

2. Observation model:

- allow manual point picking in an image/frame;
- associate image points with machine points;
- save observations into the same calibration-session model used by human calibration.

3. Solver extension:

- fit image-to-machine affine or homography transform from point correspondences;
- report residuals;
- save transform artifact;
- validate before use.

4. UI extension:

- show camera frame;
- overlay selected points;
- allow entering corresponding machine coordinates;
- show residuals.

### Tests

Use synthetic points/images. Do not require camera hardware in tests.

### Acceptance

The camera feature can be disabled without breaking the app. Synthetic calibration tests pass.

---

## Worker 6 — Integration, docs, and release worker

You are the integration worker. Your task is to keep the project coherent and runnable.

### Goal

Ensure the staged system is testable, documented, and safe to operate.

### Implement

- `README.md` with setup and safe hardware procedure;
- `docs/safety.md`;
- `docs/controller_interrogation.md`;
- `docs/calibration_protocol.md`;
- `docs/development_workflow.md`;
- `Makefile` targets for install, test, lint, typecheck, serve, probe-mock;
- example config files;
- artifact directory conventions;
- sample mock transcripts and snapshots.

### Acceptance

A new developer can run:

```bash
make install
make test
make probe-mock
make serve-mock
```

without hardware. Hardware commands are documented and visibly gated.
