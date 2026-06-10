# Phase / worker

- Phase: 0 — passive controller interrogation
- Worker: Worker 0 — Device interrogation and smoke-probe worker
- Date: 2026-06-02

## Summary

Implemented the first no-motion `plotterctl` vertical slice. It can list serial ports, probe a
mock or USB serial grblHAL-compatible controller, parse passive responses, save a raw JSONL
transcript, and write a typed controller snapshot JSON.

## Files changed

- `pyproject.toml`: root package metadata, dependencies, `plotterctl` entrypoint, test config.
- `plotter_vision/cli.py`: `ports`, `probe`, and `snapshot` commands.
- `plotter_vision/controller/base.py`: transport protocol and command log event models.
- `plotter_vision/controller/grbl.py`: grblHAL send/response controller and probe workflow.
- `plotter_vision/controller/mock.py`: mock controller responses for phase-0 commands.
- `plotter_vision/controller/parser.py`: response parsing and phase-0 unsafe-command rejection.
- `plotter_vision/controller/serial_transport.py`: pyserial USB transport and port listing.
- `plotter_vision/controller/snapshot.py`: `ControllerSnapshot` artifact model.
- `plotter_vision/config.py`: initial `SafetyState` and `MachineConfig` defaults.
- `tests/test_parser.py`: parser and phase-0 safety tests.
- `tests/test_snapshot.py`: mock snapshot and transcript tests.
- `docs/REPOSITORY_PLAN.md`: staged project plan.
- `docs/NETWORK_TRANSPORT_DEFERRED.md`: explicit Wi-Fi deferral note.
- `README.md`: safe install/probe workflow.

## Commands to run

```bash
# install
python3 -m venv .venv
source .venv/bin/activate
pip install -e '.[dev]'

# test
pytest
ruff check .

# mock/demo
plotterctl ports
plotterctl probe --mock --transcript artifacts/mock_probe_transcript.jsonl
plotterctl snapshot --mock --out artifacts/mock_snapshot.json \
  --transcript artifacts/mock_snapshot_transcript.jsonl

# real hardware
plotterctl probe --port /dev/cu.usbmodemXXXX \
  --transcript artifacts/controller_transcript.jsonl
plotterctl snapshot --port /dev/cu.usbmodemXXXX \
  --out artifacts/controller_snapshot.json \
  --transcript artifacts/controller_snapshot_transcript.jsonl
```

## Safety gates implemented

- Phase-0 commands are restricted to `$I`, `$G`, `?`, `$$`, and `$#`.
- `$X`, `$H`, `$C`, `$RST`, `$N...`, `$NN=value`, `$J=...`, G-code, M-code, axis words,
  feed/spindle words, feed hold, resume, and Ctrl-X are rejected by `assert_phase0_safe_command`.
- The probe never unlocks alarms, homes axes, writes settings, enters check mode, moves, or actuates
  the pen.
- Serial transport is accessed through `GrblHalController`; CLI code does not call `serial.write`.

## Tests added

- `tests/test_parser.py`: `ok`, `error:n`, status report, settings parsing, passive command
  allow-list, and unsafe command rejection.
- `tests/test_snapshot.py`: mock controller snapshot construction, settings/coordinate parsing,
  transcript creation, and snapshot JSON save.

## Real-hardware assumptions

- The controller presented as `/dev/cu.usbserial-A10OF67O`.
- Baud rate 115200 worked.
- `$I`, `$G`, `?`, `$$`, and `$#` were benign on the installed grblHAL firmware.
- Motors may be unpowered; phase-0 probing should still return controller responses.
- Startup lines and bracket keys may differ from the mock and should be preserved in raw transcript.

Observed from the first real transcript:

- Firmware identified as `grblHAL`.
- Driver identified as `ESP32`.
- Board identified as `BlackBox X32`.
- Axes reported as `XYZ`, even though the physical plotter is expected to use two motion axes.
- Status reported `Idle`, `MPos:0.000,0.000,0.000`, `Pn:Z`, and `H:0`.
- Wi-Fi/WebUI support is present, but reported IP was `0.0.0.0`; network transport remains deferred.
- One early `$#` run returned coordinate parameters through `[G28:...]`, then ended with `error:7`
  instead of `ok`. The snapshot workflow now preserves partial coordinate responses and records a
  parser warning if this recurs.
- The successful saved snapshot includes `$#` coordinates through `PRB` and ended with `ok`.

## Artifacts produced

- Mock transcript: `artifacts/mock_probe_transcript.jsonl`
- Mock snapshot: `artifacts/mock_snapshot.json`
- Mock snapshot transcript: `artifacts/mock_snapshot_transcript.jsonl`
- Real controller snapshot: `artifacts/controller_snapshot.json`
- Real controller snapshot transcript: `artifacts/controller_snapshot_transcript.jsonl`

These are ignored by git so real hardware transcripts can be captured locally without accidental
churn. Preserve any real controller transcript before replacing it.

## Known limitations

- The current real snapshot was created before the empty-setting parser fix, so settings like `$74=`,
  `$75=`, and `$337=` are present in the raw transcript but may require rerunning `make snapshot` to
  appear in parsed JSON.
- Timeout, alarm, and error propagation need broader fake-transport tests in phase 1.
- No motion, homing, unlock, settings-write, pen, calibration, UI/API, camera, or vector import work
  is implemented.
- The mock transcript is plausible, not authoritative.

## Next recommended worker

Worker 1 — Controller core and transport worker. The next useful step is to harden controller
error/timeout behavior against fake transports after collecting a real BlackBox X32 transcript.
