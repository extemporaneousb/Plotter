from __future__ import annotations

import json
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

from plotter_vision.bridge.server import (
    BridgeRuntimeConfig,
    LocalThreadingHTTPServer,
    PlotterBridge,
    _make_handler,
)
from plotter_vision.calibration.probe_evidence import VisualProbeRun
from plotter_vision.calibration.readiness import (
    DrawingSafeZone,
    SafeZoneMarginsMM,
    VisualReadinessState,
)
from plotter_vision.config import MachineConfig
from plotter_vision.drawing import DrawingFrameMM


def test_field_and_cap_without_motion_model_are_not_motion_calibrated(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["status"] == "blocked"
        assert any("Visual field registration" in blocker for blocker in status["readiness"]["blockers"])

        registration = _register_field(client)
        assert registration["registration"]["paper_size_mm"] == {"width": 200.0, "height": 150.0}
        observed = _observe_cap(client, x=100.0, y=75.0)

        readiness = observed["readiness"]
        assert observed["status"] == "blocked"
        assert readiness["paper_registered"] is True
        assert readiness["cap_localized"] is True
        assert readiness["cap_inside_safe_zone"] is True
        assert readiness["motion_model_valid"] is False
        assert readiness["relative_motion_model"] is None
        assert readiness["visual_ready_to_plot"] is False
        assert any("Motion calibration" in blocker for blocker in readiness["blockers"])


def test_setup_safe_zone_uses_current_visual_field_not_stale_tool_offset(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_field(client)
        stale_zone = DrawingSafeZone.from_frame(
            drawing_frame=DrawingFrameMM(
                origin_x_mm=0.0,
                origin_y_mm=0.0,
                width_mm=200.0,
                height_mm=150.0,
            ),
            margins_mm=SafeZoneMarginsMM(left=80.0, right=80.0, bottom=60.0, top=60.0),
            extra_padding_mm=40.0,
            cap_to_tip_offset_x_mm=25.0,
            cap_to_tip_offset_y_mm=-20.0,
        )
        readiness_path = tmp_path / "calibration" / "latest_visual_readiness.json"
        readiness_path.parent.mkdir(parents=True, exist_ok=True)
        readiness_path.write_text(
            VisualReadinessState(safe_zone=stale_zone).model_dump_json(indent=2),
            encoding="utf-8",
        )

        observed = _observe_cap(client, x=10.0, y=10.0)

    readiness = observed["readiness"]
    zone = readiness["safe_zone"]
    assert readiness["cap_inside_safe_zone"] is True
    assert zone["extra_padding_mm"] == pytest.approx(5.0)
    assert zone["cap_to_tip_offset_x_mm"] == pytest.approx(0.0)
    assert zone["cap_to_tip_offset_y_mm"] == pytest.approx(0.0)
    assert zone["paper_min_x_norm"] == pytest.approx(5.0 / 200.0)
    assert zone["paper_min_y_norm"] == pytest.approx(5.0 / 150.0)


@pytest.mark.parametrize(
    ("name", "matrix", "expected_inverse"),
    [
        ("aligned", ((1.0, 0.0), (0.0, 1.0)), ((1.0, 0.0), (0.0, 1.0))),
        ("swapped", ((0.0, 1.0), (1.0, 0.0)), ((0.0, 1.0), (1.0, 0.0))),
        ("sign_reversed", ((-1.0, 0.0), (0.0, -1.0)), ((-1.0, 0.0), (0.0, -1.0))),
        ("rotated_skewed", ((0.8, -0.3), (0.4, 1.1)), ((1.1, 0.3), (-0.4, 0.8))),
    ],
)
def test_probe_samples_solve_valid_relative_motion_models(
    tmp_path: Path,
    name: str,
    matrix: tuple[tuple[float, float], tuple[float, float]],
    expected_inverse: tuple[tuple[float, float], tuple[float, float]],
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_field_and_observe_cap(client)
        for payload in _probe_sample_payloads(run_id=f"probe-run-{name}", matrix=matrix):
            status_code, response = client.post("/calibration/probe/observe", payload)
            assert status_code == 200
            assert response["status"] == "accepted"

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200

    readiness = status["readiness"]
    model = readiness["relative_motion_model"]
    assert status["status"] == "ready"
    assert readiness["motion_model_valid"] is True
    assert readiness["visual_ready_to_plot"] is True
    assert readiness["probe_observation_count"] == 4
    assert readiness["probe_axes_represented"] == ["X", "Y"]
    assert readiness["motion_model_blockers"] == []
    assert model["sample_count"] == 4
    assert model["rms_residual_mm"] == pytest.approx(0.0, abs=1e-9)
    _assert_matrix_close(model["machine_to_field_matrix"], matrix)
    _assert_matrix_close(model["field_to_machine_matrix"], expected_inverse)

    run_path = tmp_path / "calibration" / "visual_probe_runs" / f"probe-run-{name}.json"
    run = VisualProbeRun.load_json(run_path)
    assert run.summary.motion_model_valid is True
    assert run.summary.relative_motion_model is not None


def test_singular_relative_motion_model_is_rejected(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_field_and_observe_cap(client)
        singular = ((1.0, 2.0), (0.0, 0.0))
        for payload in _probe_sample_payloads(run_id="probe-run-singular", matrix=singular):
            status_code, response = client.post("/calibration/probe/observe", payload)
            assert status_code == 200
            assert response["status"] == "accepted"

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200

    readiness = status["readiness"]
    assert status["status"] == "blocked"
    assert readiness["motion_model_valid"] is False
    assert readiness["relative_motion_model"] is None
    assert any("singular" in blocker for blocker in readiness["motion_model_blockers"])
    assert any("singular" in blocker for blocker in readiness["blockers"])


def test_binding_observations_are_not_required_for_motion_model_valid(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_field_and_observe_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-no-binding"):
            status_code, _ = client.post("/calibration/probe/observe", payload)
            assert status_code == 200

        status_code, binding = client.get("/calibration/binding/status")
        assert status_code == 200
        assert binding["status"] == "missing"

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200

    readiness = status["readiness"]
    assert readiness["motion_model_valid"] is True
    assert readiness["visual_ready_to_plot"] is True
    assert all("binding" not in blocker.lower() for blocker in readiness["blockers"])


def test_setup_reset_clears_latest_field_cap_and_motion_authority(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        registration = _register_field_and_observe_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-reset"):
            status_code, _ = client.post("/calibration/probe/observe", payload)
            assert status_code == 200

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["readiness"]["motion_model_valid"] is True

        registration_id = registration["registration"]["registration_id"]
        historical_field = tmp_path / "calibration" / "paper" / f"{registration_id}.json"
        historical_probe = tmp_path / "calibration" / "visual_probe_runs" / "probe-run-reset.json"
        assert historical_field.exists()
        assert historical_probe.exists()

        status_code, reset = client.post("/calibration/setup/reset", {})
        assert status_code == 200
        assert reset["status"] == "reset"

        assert not (tmp_path / "calibration" / "latest_paper_registration.json").exists()
        assert not (tmp_path / "calibration" / "latest_visual_readiness.json").exists()
        assert not (tmp_path / "calibration" / "latest_visual_probe_run.json").exists()
        assert historical_field.exists()
        assert historical_probe.exists()

        status_code, paper_status = client.get("/paper/status")
        assert status_code == 200
        assert paper_status["status"] == "missing"
        status_code, workflow = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert workflow["readiness"]["paper_registered"] is False
        assert workflow["readiness"]["motion_model_valid"] is False


def test_motion_model_valid_does_not_unlock_real_drawing(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
        arm_pen=True,
    )

    with _running_bridge(bridge) as client:
        _register_field_and_observe_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-no-drawing"):
            status_code, _ = client.post("/calibration/probe/observe", payload)
            assert status_code == 200

        status_code, workflow = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert workflow["readiness"]["motion_model_valid"] is True

        status_code, drawing = client.post(
            "/draw/program",
            _draw_program_payload(request_id="motion-model-is-not-drawing-authority"),
        )

    assert status_code == 400
    assert drawing["status"] == "failed"
    assert drawing["controller_transcript"] is None
    assert "absolute drawing" in drawing["error"]


def test_visual_probe_preview_and_run_routes_are_removed(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        status_code, preview = client.post("/calibration/probe/preview", {"request_id": "p"})
        assert status_code == 404
        assert preview["error"] == "not found"

        status_code, run = client.post("/calibration/probe/run", {"request_id": "r"})
        assert status_code == 404
        assert run["error"] == "not found"


class _BridgeClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")

    def get(self, path: str) -> tuple[int, dict[str, Any]]:
        return self._request("GET", path, None)

    def post(self, path: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return self._request("POST", path, payload)

    def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None,
    ) -> tuple[int, dict[str, Any]]:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(
            f"{self.base_url}{path}",
            data=data,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=5.0) as response:
                return (response.status, json.loads(response.read().decode("utf-8")))
        except HTTPError as error:
            return (error.code, json.loads(error.read().decode("utf-8")))


@contextmanager
def _running_bridge(bridge: PlotterBridge) -> Iterator[_BridgeClient]:
    server = LocalThreadingHTTPServer(("127.0.0.1", 0), _make_handler(bridge))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield _BridgeClient(f"http://{host}:{port}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2.0)


def _bridge(
    *,
    tmp_path: Path,
    config_path: Path,
    dry_run: bool = True,
    arm_motion: bool = False,
    arm_pen: bool = False,
    arm_homing: bool = False,
) -> PlotterBridge:
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=dry_run,
            mock=True,
            arm_motion=arm_motion,
            arm_pen=arm_pen,
            arm_homing=arm_homing,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )


def _register_field_and_observe_cap(client: _BridgeClient) -> dict[str, Any]:
    registration = _register_field(client)
    _observe_cap(client, x=100.0, y=75.0)
    return registration


def _register_field(client: _BridgeClient) -> dict[str, Any]:
    status_code, registration = client.post("/paper/register", _field_registration_payload())
    assert status_code == 200
    assert registration["status"] == "locked"
    return registration


def _observe_cap(client: _BridgeClient, *, x: float, y: float) -> dict[str, Any]:
    status_code, observed = client.post(
        "/calibration/pen/observe",
        _cap_observation_payload(field_x=x, field_y=y),
    )
    assert status_code == 200
    return observed


def _field_registration_payload() -> dict[str, Any]:
    return {
        "corners": [
            {"corner": "bottom_left", "observed_norm": {"x": 0.10, "y": 0.12}},
            {"corner": "bottom_right", "observed_norm": {"x": 0.88, "y": 0.10}},
            {"corner": "top_right", "observed_norm": {"x": 0.90, "y": 0.86}},
            {"corner": "top_left", "observed_norm": {"x": 0.12, "y": 0.88}},
        ],
    }


def _cap_observation_payload(*, field_x: float, field_y: float) -> dict[str, Any]:
    return {
        "observed_norm": {"x": field_x / 200.0, "y": field_y / 150.0},
        "observed_paper_norm": {"x": field_x / 200.0, "y": field_y / 150.0},
        "observed_logical_mm": {"x": field_x, "y": field_y},
        "source": "operator_confirmed",
        "confidence": 0.95,
    }


def _probe_sample_payloads(
    *,
    run_id: str,
    matrix: tuple[tuple[float, float], tuple[float, float]] = ((1.0, 0.0), (0.0, 1.0)),
) -> list[dict[str, Any]]:
    commands = [
        ("probe-x-pos", "X", 20.0, 0.0),
        ("probe-x-neg", "X", -20.0, 0.0),
        ("probe-y-pos", "Y", 0.0, 20.0),
        ("probe-y-neg", "Y", 0.0, -20.0),
    ]
    return [
        _probe_sample_payload(
            run_id=run_id,
            sample_id=sample_id,
            axis=axis,
            command_x=command_x,
            command_y=command_y,
            matrix=matrix,
        )
        for sample_id, axis, command_x, command_y in commands
    ]


def _probe_sample_payload(
    *,
    run_id: str,
    sample_id: str,
    axis: str,
    command_x: float,
    command_y: float,
    matrix: tuple[tuple[float, float], tuple[float, float]],
) -> dict[str, Any]:
    before = (100.0, 75.0)
    observed_dx = matrix[0][0] * command_x + matrix[0][1] * command_y
    observed_dy = matrix[1][0] * command_x + matrix[1][1] * command_y
    after = (before[0] + observed_dx, before[1] + observed_dy)
    return {
        "run_id": run_id,
        "sample_id": sample_id,
        "source": "motion_probe",
        "axis": axis,
        "commanded_dx_mm": command_x,
        "commanded_dy_mm": command_y,
        "before": _probe_cap_snapshot(*before, frame=1),
        "after": _probe_cap_snapshot(*after, frame=2),
        "status": "accepted",
        "camera_id": "plotter-camera",
        "camera_name": "Plotter Camera",
    }


def _probe_cap_snapshot(x_mm: float, y_mm: float, *, frame: int) -> dict[str, Any]:
    return {
        "camera_norm": {"x": x_mm / 200.0, "y": y_mm / 150.0},
        "paper_norm": {"x": x_mm / 200.0, "y": y_mm / 150.0},
        "logical_mm": {"x": x_mm, "y": y_mm},
        "frame_id": frame,
        "confidence": 0.95,
    }


def _assert_matrix_close(
    actual: list[list[float]],
    expected: tuple[tuple[float, float], tuple[float, float]],
) -> None:
    assert len(actual) == 2
    for actual_row, expected_row in zip(actual, expected):
        assert actual_row == pytest.approx(expected_row, abs=1e-6)


def _draw_program_payload(*, request_id: str) -> dict[str, Any]:
    return {
        "request_id": request_id,
        "include_homing": False,
        "program": {
            "polylines": [
                {
                    "role": "contour",
                    "closed": False,
                    "points": [
                        {"x": 0.10, "y": 0.10},
                        {"x": 0.20, "y": 0.10},
                        {"x": 0.20, "y": 0.20},
                    ],
                }
            ]
        },
        "frame": {
            "origin_x_mm": 20.0,
            "origin_y_mm": 20.0,
            "width_mm": 100.0,
            "height_mm": 80.0,
            "flip_y": False,
        },
        "draw_feed_mm_min": 180.0,
        "travel_feed_mm_min": 500.0,
        "max_segment_mm": 25.0,
    }


def _write_machine_config(tmp_path: Path) -> Path:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    machine.save_json(config_path)
    return config_path
