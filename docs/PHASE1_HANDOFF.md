# Phase / worker

- Phase: 1 — reusable controller core
- Worker: Worker 1 — Controller core and transport worker
- Date: 2026-06-02

## Summary

Hardened the controller layer so higher-level code can use one controller API without knowing about
pyserial details. Added fake-transport tests for send/response behavior, errors, alarms, timeouts,
typed status reports, command logging, and explicit realtime hooks.

## Files changed

- `plotter_vision/controller/base.py`: added `MotionController` protocol and extended
  `CommandResult` with optional `error_line`.
- `plotter_vision/controller/grbl.py`: added typed `query_status_report()`, explicit
  `feed_hold()`, `resume()`, and `soft_reset()` realtime methods, plain drain support, and
  non-throwing command results for partial snapshot preservation.
- `tests/test_controller_core.py`: added fake transport tests for Worker 1 acceptance coverage.
- `tests/test_snapshot.py`: covers partial `$#` error preservation.
- `tests/test_parser.py`: covers empty settings such as `$74=`.
- `docs/REPOSITORY_PLAN.md`: updated phase status.

## Commands to run

```bash
# install
make install

# test
make check

# mock/demo
make mock-snapshot

# real hardware, passive only
make snapshot PORT=/dev/cu.usbserial-A10OF67O
```

## Safety gates implemented

- Passive probe commands remain restricted to `$I`, `$G`, `?`, `$$`, and `$#`.
- Settings writes, motion, homing, unlock, reset, startup blocks, jogs, and pen-like commands remain
  rejected by phase-0 validation when using `send_command`.
- Realtime feed hold, resume, and soft reset exist only as explicit controller methods. They are not
  part of the passive probe and are not exposed by the current CLI.
- CLI and tests still access hardware through `GrblHalController` and `ControllerTransport`; no UI or
  calibration code talks directly to serial.

## Tests added

- Fake transport send-response and log event ordering.
- Error propagation for `error:n`.
- Alarm propagation for `ALARM:n`.
- Timeout behavior that includes the command/status context.
- Typed status report parsing through controller API.
- Explicit realtime hook byte writes and logging.

## Real-hardware assumptions

- The known controller port is `/dev/cu.usbserial-A10OF67O`.
- Current real snapshot shows BlackBox X32 / ESP32 / grblHAL with axes reported as `XYZ`.
- Homing is enabled in settings (`$22=1`) but is not trusted yet.
- Limit/status field reported `Pn:Z`; this needs interpretation before any motion or homing.
- Wi-Fi/WebUI support is present, but network transport remains deferred.

## Artifacts produced

- Real controller snapshot: `artifacts/controller_snapshot.json`
- Real controller transcript: `artifacts/controller_snapshot_transcript.jsonl`
- Mock snapshot: `artifacts/mock_snapshot.json`
- Mock transcript: `artifacts/mock_snapshot_transcript.jsonl`

## Known limitations

- Realtime methods are implemented in the core but intentionally not exposed as CLI targets yet.
- No motion, homing, unlock, settings-write, pen, calibration, UI/API, camera, or vector import work
  is implemented.
- The phase-1 controller still uses phase-0 command validation for normal line commands. Motion-safe
  G-code validation belongs to Worker 2.

## Next recommended worker

Worker 2 — Machine model, safety, and G-code worker. Start with dry-run previews and safety
validators only. Do not stream real motion until the human explicitly opts in with motion arming.
