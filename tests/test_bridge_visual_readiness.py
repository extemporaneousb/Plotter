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


def test_drawing_frame_observation_persists_drawing_calibration(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        registration = _register_field(client)
        registration_id = registration["registration"]["registration_id"]

        status_code, missing = client.get("/calibration/drawing/status")
        assert status_code == 200
        assert missing["status"] == "missing"

        status_code, response = client.post(
            "/calibration/drawing/frame-observation",
            _drawing_frame_observation_payload(registration_id=registration_id),
        )
        assert status_code == 200
        assert response["status"] == "ready"
        assert response["observation_id"].startswith("drawing-frame-")
        calibration = response["calibration"]
        assert calibration["artifact_type"] == "drawing_calibration_model"
        assert calibration["paper_registration_id"] == registration_id
        assert calibration["model_version"] == "residual_grid_v1"
        assert calibration["solver_kind"] == "residual_grid_v1"
        assert calibration["usable_observation_count"] == 1
        assert calibration["expected_to_observed"] is not None
        assert calibration["residual_grid"] is not None
        assert calibration["sample_count"] >= 4
        assert calibration["blockers"] == []
        assert (tmp_path / "calibration" / "latest_drawing_calibration.json").exists()

        status_code, status = client.get("/calibration/drawing/status")
        assert status_code == 200
        assert status["status"] == "ready"
        assert status["calibration"]["latest_observation_id"] == response["observation_id"]


def test_setup_reset_clears_latest_drawing_calibration_pointer(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        registration = _register_field(client)
        registration_id = registration["registration"]["registration_id"]
        status_code, response = client.post(
            "/calibration/drawing/frame-observation",
            _drawing_frame_observation_payload(registration_id=registration_id),
        )
        assert status_code == 200
        historical_model = (
            tmp_path
            / "calibration"
            / "drawing_calibrations"
            / f"{response['calibration']['model_id']}.json"
        )
        assert historical_model.exists()

        status_code, reset = client.post("/calibration/setup/reset", {})
        assert status_code == 200
        assert reset["status"] == "reset"
        assert not (tmp_path / "calibration" / "latest_drawing_calibration.json").exists()
        assert historical_model.exists()


def test_drawing_calibration_program_pipeline_persists_residual_grid_model(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        registration = _register_field(client)
        registration_id = registration["registration"]["registration_id"]

        status_code, preview = client.post(
            "/calibration/drawing/program/preview",
            {"request_id": "rich-sheet-preview"},
        )
        assert status_code == 200
        assert preview["status"] == "ready"
        assert preview["program_kind"] == "rich_drawing_calibration_sheet"
        assert preview["plan_hash"]
        assert preview["preview_overlay"]["projected"] is True
        assert preview["preview_overlay"]["paper_registration_id"] == registration_id
        assert len(preview["planned_trace"]) > 0
        assert {step["action"] for step in preview["planned_trace"]} == {"travel", "draw"}
        assert any(
            segment["primitive_id"] == "cal.circle.left"
            for segment in preview["simulation"]["drawn_segments"]
        )
        assert any(
            primitive["primitive_id"] == "cal.arc.clockwise"
            for primitive in preview["preview_overlay"]["primitives"]
        )

        status_code, observed = client.post(
            "/calibration/drawing/program-observation",
            _drawing_program_observation_payload(
                registration_id=registration_id,
                command_id=preview["command_id"],
                preview_overlay=preview["preview_overlay"],
            ),
        )
        assert status_code == 200
        assert observed["status"] == "ready"
        calibration = observed["calibration"]
        assert calibration["model_family"] == "residual_grid_v1"
        assert calibration["solver_kind"] == "residual_grid_v1"
        assert calibration["sample_count"] >= 20
        assert calibration["residual_grid"]["columns"] == 5
        assert calibration["coverage"]["coverage_fraction"] >= 0.2
        assert calibration["blockers"] == []
        assert (tmp_path / "calibration" / "latest_drawing_calibration.json").exists()
        assert (
            tmp_path
            / "calibration"
            / "drawing_calibrations"
            / f"{calibration['model_id']}.json"
        ).exists()

        status_code, status = client.get("/calibration/drawing/status")
        assert status_code == 200
        assert status["status"] == "ready"
        assert status["calibration"]["latest_observation_id"] == observed["observation_id"]


def test_valid_drawing_model_applies_to_sheet_run_and_refuses_stale_registration(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        registration = _register_field(client)
        registration_id = registration["registration"]["registration_id"]
        status_code, preview = client.post(
            "/calibration/drawing/program/preview",
            {"request_id": "uncorrected-sheet-preview"},
        )
        assert status_code == 200
        status_code, observed = client.post(
            "/calibration/drawing/program-observation",
            _drawing_program_observation_payload(
                registration_id=registration_id,
                command_id=preview["command_id"],
                preview_overlay=preview["preview_overlay"],
            ),
        )
        assert status_code == 200
        assert observed["status"] == "ready"

        status_code, corrected_preview = client.post(
            "/calibration/drawing/program/preview",
            {
                "request_id": "corrected-sheet-preview",
                "apply_drawing_calibration_model": True,
            },
        )
        assert status_code == 200
        assert corrected_preview["status"] == "ready"
        assert corrected_preview["drawing_correction"]["status"] == "applied"
        assert corrected_preview["drawing_correction"]["corrected_point_count"] > 0
        assert corrected_preview["drawing_correction"]["max_correction_mm"] > 0.1

        status_code, corrected_run = client.post(
            "/calibration/drawing/program/run",
            {
                "request_id": "corrected-sheet-run",
                "apply_drawing_calibration_model": True,
                "expected_plan_hash": corrected_preview["plan_hash"],
            },
        )
        assert status_code == 200
        assert corrected_run["status"] == "completed"
        assert corrected_run["dry_run"] is True
        assert corrected_run["drawing_correction"]["status"] == "applied"

        _register_shifted_field(client)
        status_code, stale_status = client.get("/calibration/drawing/status")
        assert status_code == 200
        assert stale_status["status"] == "blocked"
        assert stale_status["calibration"]["freshness_status"] == "stale"
        assert stale_status["calibration"]["stale_reasons"]

        status_code, stale_preview = client.post(
            "/calibration/drawing/program/preview",
            {
                "request_id": "stale-corrected-sheet-preview",
                "apply_drawing_calibration_model": True,
            },
        )
        assert status_code == 400
        assert stale_preview["status"] == "failed"
        assert "stale" in stale_preview["error"]


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


def _register_shifted_field(client: _BridgeClient) -> dict[str, Any]:
    payload = _field_registration_payload()
    for corner in payload["corners"]:
        corner["observed_norm"]["x"] += 0.015
        corner["observed_norm"]["y"] += 0.010
    status_code, registration = client.post("/paper/register", payload)
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


def _drawing_frame_observation_payload(*, registration_id: str) -> dict[str, Any]:
    expected = [
        {"x": 8.0, "y": 8.0},
        {"x": 192.0, "y": 8.0},
        {"x": 192.0, "y": 142.0},
        {"x": 8.0, "y": 142.0},
    ]
    observed = [
        {"x": 10.0, "y": 9.0},
        {"x": 194.0, "y": 9.0},
        {"x": 193.0, "y": 143.0},
        {"x": 9.0, "y": 143.0},
    ]
    closed_expected = [*expected, expected[0]]
    closed_observed = [*observed, observed[0]]
    return {
        "command_id": "field-frame-test",
        "paper_registration_id": registration_id,
        "camera_id": "plotter-camera",
        "camera_name": "Plotter Camera",
        "expected_corners_mm": expected,
        "edges": [
            {
                "edge_index": index + 1,
                "expected_start_mm": closed_expected[index],
                "expected_end_mm": closed_expected[index + 1],
                "observed_start_mm": closed_observed[index],
                "observed_end_mm": closed_observed[index + 1],
                "sample_count": 80,
                "detected_sample_count": 70,
                "green_pixel_count": 400,
                "coverage_fraction": 0.88,
                "rms_expected_residual_mm": 1.2,
                "max_expected_residual_mm": 2.4,
                "fit_rms_residual_mm": 0.5,
                "angle_error_deg": 0.8,
            }
            for index in range(4)
        ],
        "corners": [
            {
                "corner_index": index + 1,
                "expected_mm": expected[index],
                "observed_mm": observed[index],
                "residual_mm": 2.2,
            }
            for index in range(4)
        ],
        "total_green_pixels": 1600,
        "detected_edge_count": 4,
        "rms_residual_mm": 1.4,
        "max_residual_mm": 2.8,
        "corner_rms_residual_mm": 2.2,
        "corner_max_residual_mm": 2.4,
        "usable": True,
    }


def _drawing_program_observation_payload(
    *,
    registration_id: str,
    command_id: str,
    preview_overlay: dict[str, Any],
) -> dict[str, Any]:
    primitive_rows: dict[str, dict[str, Any]] = {}
    samples: list[dict[str, Any]] = []
    for primitive in preview_overlay["primitives"]:
        primitive_id = primitive["primitive_id"]
        primitive_kind = _primitive_kind(primitive_id)
        row = primitive_rows.setdefault(
            primitive_id,
            {
                "primitive_id": primitive_id,
                "primitive_kind": primitive_kind,
                "sample_count": 0,
                "detected_sample_count": 0,
                "green_pixel_count": 0,
                "coverage_fraction": 1.0,
                "rms_residual_mm": 1.8,
                "p95_residual_mm": 2.4,
                "max_residual_mm": 2.8,
            },
        )
        for suffix, point in [
            ("start", primitive["start_paper_mm"]),
            ("end", primitive["end_paper_mm"]),
        ]:
            sample_index = row["sample_count"]
            observed = _synthetic_observed_drawing_point(point)
            samples.append(
                {
                    "primitive_id": primitive_id,
                    "sample_index": sample_index,
                    "expected_mm": point,
                    "expected_camera_norm": primitive.get(f"{suffix}_camera_norm"),
                    "observed_mm": observed,
                    "observed_camera_norm": primitive.get(f"{suffix}_camera_norm"),
                    "residual_mm": _distance_mm(point, observed),
                    "detected": True,
                    "green_pixel_count": 12,
                }
            )
            row["sample_count"] += 1
            row["detected_sample_count"] += 1
            row["green_pixel_count"] += 12

    return {
        "command_id": command_id,
        "paper_registration_id": registration_id,
        "camera_id": "plotter-camera",
        "camera_name": "Plotter Camera",
        "program_id": "rich-sheet-test",
        "program_kind": "rich_drawing_calibration_sheet",
        "primitives": list(primitive_rows.values()),
        "samples": samples,
        "sample_count": len(samples),
        "detected_sample_count": len(samples),
        "total_green_pixels": 12 * len(samples),
        "coverage_fraction": 1.0,
        "rms_residual_mm": 1.8,
        "p95_residual_mm": 2.4,
        "max_residual_mm": 2.8,
        "usable": True,
    }


def _primitive_kind(primitive_id: str) -> str:
    if ".circle." in primitive_id:
        return "circle"
    if ".arc." in primitive_id:
        return "arc"
    if ".mark." in primitive_id:
        return "mark"
    return "line"


def _synthetic_observed_drawing_point(point: dict[str, float]) -> dict[str, float]:
    return {
        "x": point["x"] + 2.4 + 0.004 * point["x"] - 0.003 * point["y"],
        "y": point["y"] - 1.7 + 0.002 * point["x"] + 0.003 * point["y"],
    }


def _distance_mm(left: dict[str, float], right: dict[str, float]) -> float:
    return ((left["x"] - right["x"]) ** 2 + (left["y"] - right["y"]) ** 2) ** 0.5


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
