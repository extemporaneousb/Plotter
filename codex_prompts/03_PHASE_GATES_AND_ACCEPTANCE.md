# Phase gates and acceptance criteria

This file defines non-negotiable phase gates. Do not advance to the next phase until the current phase has passing tests, a handoff note, and no unresolved safety regression.

## Global safety invariants

These invariants apply to all phases:

1. No real motion by default.
2. Dry-run is default true.
3. Motion requires explicit arming.
4. Homing is not assumed safe.
5. Alarm unlock is not automatic.
6. Settings writes are blocked unless a separate explicit settings-write gate is implemented.
7. Pen actuation is disabled until explicit commands are configured and the user confirms a trial.
8. UI/API routes cannot bypass the core safety validator.
9. Serial/network transports cannot be called directly by calibration or UI code for motion.
10. All hardware communication should be transcriptable.

## Phase 0 acceptance — passive controller interrogation

Required commands:

```bash
plotterctl ports
plotterctl probe --mock
plotterctl snapshot --mock --out artifacts/mock_snapshot.json
pytest
```

Real hardware command, documented but not required in CI:

```bash
plotterctl probe --port /dev/cu.usbmodemXXXX
plotterctl snapshot --port /dev/cu.usbmodemXXXX --out artifacts/controller_snapshot.json
```

Required behavior:

- sends only benign query commands;
- saves raw transcript;
- saves parsed snapshot;
- tests parser and unsafe-command rejection;
- does not send `$X`, `$H`, `$C`, `$N`, `$RST`, `$NN=value`, motion commands, or pen commands.

## Phase 1 acceptance — reusable controller core

Required behavior:

- serial transport is isolated behind an interface;
- mock/fake transport exercises same parser path;
- status query works as a real-time command;
- feed hold/resume/soft reset exist only as explicit calls;
- every TX/RX line is logged;
- controller probe produces typed snapshot.

Required tests:

- fake transport send-response;
- error propagation;
- alarm propagation;
- timeout behavior;
- snapshot parsing.

## Phase 2 acceptance — minimal motion and machine safety

Required commands:

```bash
plotterctl no-motion --mock
plotterctl jog --mock --axis X --distance 1.0 --feed 60 --dry-run
plotterctl test-square --mock --size-mm 5 --feed 120 --dry-run
```

Real motion command must require an explicit flag:

```bash
plotterctl jog --port /dev/cu.usbmodemXXXX --axis X --distance 1.0 --feed 60 --arm-motion --no-dry-run
```

Required tests:

- motion rejected when dry-run false but not armed;
- motion rejected when armed but dry-run true unless preview-only;
- feed limits enforced;
- max jog distance enforced;
- settings writes rejected;
- homing/unlock rejected unless explicitly allowed.

## Phase 3 acceptance — human-assisted calibration

Required behavior:

- calibration session can be created without hardware;
- measured displacement records can be entered manually;
- scale and affine solvers work on synthetic data;
- calibration artifact is saved as JSON;
- residuals are reported;
- artifact has validation status;
- pen trial workflow never guesses commands.

Required tests:

- 1D scale solve;
- sign/inversion solve or representation;
- affine solve from known points;
- residual computation;
- serialization round-trip;
- rejected pen trial without explicit confirmation.

## Phase 4 acceptance — UI/API

Required behavior:

- `plotterctl serve --mock` starts a UI/API;
- controller probe through API works against mock;
- safety state is visible;
- command log is visible;
- calibration session can be run through API;
- WebSocket emits status/log/safety events;
- API cannot bypass safety gates.

Required tests:

- health endpoint;
- mock probe endpoint;
- safety arm/disarm endpoint;
- jog request rejected unless gates satisfied;
- calibration session endpoint.

## Phase 5 acceptance — camera observation

Required behavior:

- camera absence is not fatal;
- synthetic point calibration tests pass without a camera;
- frame capture is optional;
- image point to machine point observations save into calibration sessions;
- transform residuals are reported.

Required tests:

- camera service no-camera fallback;
- synthetic affine/homography solve;
- observation artifact serialization.

## Phase 6 acceptance — drawing/vector ingestion

This phase is explicitly out of scope for the first implementation. Do not implement until phases 0–3 are stable and the UI/API exists.
