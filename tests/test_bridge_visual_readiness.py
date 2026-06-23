from __future__ import annotations

import json
import math
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
from plotter_vision.config import MachineConfig


def test_visual_workflow_routes_register_paper_observe_cap_and_report_blockers(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["status"] == "blocked"
        assert any("Paper registration" in blocker for blocker in status["readiness"]["blockers"])

        status_code, registration = client.post("/paper/register", _paper_registration_payload())
        assert status_code == 200
        assert registration["status"] == "locked"

        status_code, observed = client.post(
            "/calibration/pen/observe",
            _cap_observation_payload(paper_x=0.5, paper_y=0.5),
        )

        assert status_code == 200
        readiness = observed["readiness"]
        assert observed["status"] == "blocked"
        assert readiness["paper_registered"] is True
        assert readiness["cap_localized"] is True
        assert readiness["cap_inside_safe_zone"] is True
        assert readiness["visual_ready_to_plot"] is False
        assert any("at least 2 observations" in blocker for blocker in readiness["blockers"])

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["readiness"]["latest_cap_observation"]["paper_norm"] == {"x": 0.5, "y": 0.5}


def test_visual_probe_preview_and_run_routes_are_removed(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        status_code, preview = client.post(
            "/calibration/probe/preview",
            {"request_id": "probe-preview"},
        )
        assert status_code == 404
        assert preview["error"] == "not found"

        status_code, run = client.post(
            "/calibration/probe/run",
            {"request_id": "probe-run"},
        )
        assert status_code == 404
        assert run["error"] == "not found"
        assert not (tmp_path / "transcripts" / "probe-run.jsonl").exists()


def test_visual_probe_observe_persists_samples_and_updates_readiness(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-durable"):
            status_code, response = client.post("/calibration/probe/observe", payload)
            assert status_code == 200
            assert response["status"] == "accepted"

        run_path = tmp_path / "calibration" / "visual_probe_runs" / "probe-run-durable.json"
        latest_path = tmp_path / "calibration" / "latest_visual_probe_run.json"
        assert run_path.exists()
        assert latest_path.exists()
        run = VisualProbeRun.load_json(run_path)
        assert len(run.samples) == 4
        assert run.summary.accepted_sample_count == 4
        assert run.summary.axes_represented == ["X", "Y"]
        assert run.summary.rms_residual_mm == pytest.approx(0.0)

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        readiness = status["readiness"]
        assert readiness["probe_raw_sample_count"] == 4
        assert readiness["probe_observation_count"] == 4
        assert readiness["probe_axes_represented"] == ["X", "Y"]
        assert readiness["latest_visual_probe_run_id"] == "probe-run-durable"
        assert readiness["visual_ready_to_plot"] is True


def test_persisted_visual_probe_samples_survive_bridge_reload(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-reload"):
            status_code, _ = client.post("/calibration/probe/observe", payload)
            assert status_code == 200

    reloaded = _bridge(tmp_path=tmp_path, config_path=config_path)
    with _running_bridge(reloaded) as client:
        status_code, status = client.get("/calibration/workflow/status")

    assert status_code == 200
    readiness = status["readiness"]
    assert readiness["latest_visual_probe_run_id"] == "probe-run-reload"
    assert readiness["probe_observation_count"] == 4
    assert readiness["probe_rms_residual_mm"] == pytest.approx(0.0)


def test_legacy_bootstrap_sample_decodes_without_bootstrap_readiness_path(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        status_code, response = client.post(
            "/calibration/probe/observe",
            _probe_sample_payload(
                run_id="probe-run-bootstrap",
                sample_id="boot-1",
                source="x_min_bootstrap",
                axis="X",
                command_x=80.0,
                command_y=0.0,
                before=(20.0, 100.0),
                after=(100.0, 100.0),
            ),
        )

        assert status_code == 200
        assert response["status"] == "accepted"
        readiness = response["readiness"]
        assert "probe_bootstrap_sample_count" not in readiness
        assert readiness["probe_observation_count"] == 1
        assert readiness["visual_ready_to_plot"] is False
        assert any("at least 2 observations" in blocker for blocker in readiness["blockers"])


def test_rejected_visual_probe_sample_persists_without_counting_as_readiness(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        status_code, response = client.post(
            "/calibration/probe/observe",
            _probe_sample_payload(
                run_id="probe-run-rejected",
                sample_id="reject-1",
                source="center_target_residual",
                axis=None,
                command_x=6.0,
                command_y=0.0,
                before=(250.0, 100.0),
                after=(251.0, 100.0),
                predicted_dx=6.0,
                predicted_dy=0.0,
                residual=5.0,
                residual_limit=3.5,
                status="rejected",
                rejection_reason="residual exceeded limit",
            ),
        )

        assert status_code == 200
        assert response["status"] == "rejected"
        run = VisualProbeRun.load_json(
            tmp_path / "calibration" / "visual_probe_runs" / "probe-run-rejected.json"
        )
        assert run.summary.raw_sample_count == 1
        assert run.summary.accepted_sample_count == 0
        assert run.summary.rejected_sample_count == 1
        readiness = response["readiness"]
        assert readiness["probe_raw_sample_count"] == 1
        assert readiness["probe_observation_count"] == 0
        assert readiness["probe_rejected_sample_count"] == 1
        assert readiness["visual_ready_to_plot"] is False


def test_durable_cap_probe_evidence_does_not_unlock_absolute_drawing(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
        arm_pen=True,
        arm_homing=False,
    )

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        for payload in _probe_sample_payloads(run_id="probe-run-no-unlock"):
            status_code, _ = client.post("/calibration/probe/observe", payload)
            assert status_code == 200

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["readiness"]["visual_ready_to_plot"] is True

        status_code, drawing = client.post(
            "/draw/program",
            _draw_program_payload(request_id="probe-evidence-draw"),
        )

        assert status_code == 400
        assert drawing["status"] == "failed"
        assert drawing["controller_transcript"] is None
        assert "VisualPositionBinding" in drawing["error"]
        machine = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
        assert machine.homing_trusted is False
        assert machine.axis_model_trusted is False


def test_cap_only_visual_readiness_does_not_unlock_absolute_drawing(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
        arm_pen=True,
        arm_homing=False,
    )

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        status_code, trust = client.post(
            "/machine/axis-model/trust",
            {
                "request_id": "visual-ready",
                "sample_count": 4,
                "command_distance_mm": 200.0,
                "min_observed_distance_mm": 45.0,
                "rms_residual_mm": 1.0,
                "max_residual_mm": 2.0,
                "samples": [
                    _trust_sample("X", 200.0, 198.0, 1.0, 198.0),
                    _trust_sample("X", -200.0, -197.0, -1.0, 197.0),
                    _trust_sample("Y", 50.0, 1.0, 49.0, 49.0),
                    _trust_sample("Y", -50.0, -1.0, -48.0, 48.0),
                ],
            },
        )
        assert status_code == 200
        assert trust["status"] == "completed"

        status_code, status = client.get("/calibration/workflow/status")
        assert status_code == 200
        assert status["status"] == "ready"
        assert status["readiness"]["visual_ready_to_plot"] is True

        status_code, binding_status = client.get("/calibration/binding/status")
        assert status_code == 200
        assert binding_status["status"] == "missing"

        status_code, drawing = client.post(
            "/draw/program",
            _draw_program_payload(request_id="visual-draw"),
        )

        assert status_code == 400
        assert drawing["status"] == "failed"
        assert drawing["controller_transcript"] is None
        assert "VisualPositionBinding" in drawing["error"]
        machine = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
        assert machine.homing_trusted is False
        assert machine.axis_model_trusted is False


def test_validated_visual_binding_allows_controlled_drawing_without_axis_trust(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
        arm_pen=True,
        arm_homing=False,
    )

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        status_code, preview = client.post(
            "/calibration/binding/preview",
            {
                "request_id": "binding-preview",
                "mark_size_mm": 4.0,
                "margin_mm": 25.0,
            },
        )
        assert status_code == 200
        assert preview["status"] == "ready"
        assert preview["point_set"] == "five"
        samples = preview["points"]
        assert len(samples) == 5

        for sample in samples:
            status_code, observed = client.post(
                "/calibration/binding/observe",
                {
                    "command_id": "binding-preview",
                    "point_id": sample["point_id"],
                    "kind": "ink",
                    "observed_paper_mm": sample["paper_mm"],
                },
            )
            assert status_code == 200
            assert observed["status"] in {"collecting", "blocked", "ready"}

        status_code, binding_status = client.get("/calibration/binding/status")
        assert status_code == 200
        assert binding_status["status"] == "ready"
        binding = binding_status["binding"]
        assert binding["validation_status"] == "validated"
        assert binding["residuals"]["observation_count"] >= 5
        assert binding["residuals"]["rms_residual_mm"] <= 3.0

        status_code, drawing = client.post(
            "/draw/program",
            _draw_program_payload(request_id="visual-binding-draw"),
        )

        assert status_code == 200
        assert drawing["status"] == "completed"
        assert drawing["controller_transcript"] is not None
        assert "$H" not in drawing["planned_commands"]
        text = Path(drawing["controller_transcript"]).read_text(encoding="utf-8")
        assert '"payload":"$H"' not in text
        assert '"payload":"M3 S720"' in text
        machine = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
        assert machine.axis_model_trusted is False


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


def _register_and_observe_center_cap(client: _BridgeClient) -> None:
    status_code, _ = client.post("/paper/register", _paper_registration_payload())
    assert status_code == 200
    status_code, _ = client.post(
        "/calibration/pen/observe",
        _cap_observation_payload(paper_x=0.5, paper_y=0.5),
    )
    assert status_code == 200


def _paper_registration_payload() -> dict[str, Any]:
    return {
        "paper_width_mm": 533.4,
        "paper_height_mm": 215.9,
        "corners": [
            {"corner": "bottom_left", "observed_norm": {"x": 0.10, "y": 0.12}},
            {"corner": "bottom_right", "observed_norm": {"x": 0.88, "y": 0.10}},
            {"corner": "top_right", "observed_norm": {"x": 0.90, "y": 0.86}},
            {"corner": "top_left", "observed_norm": {"x": 0.12, "y": 0.88}},
        ],
    }


def _cap_observation_payload(
    *,
    paper_x: float,
    paper_y: float,
    logical_x: float | None = None,
    logical_y: float | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "observed_norm": {"x": paper_x, "y": paper_y},
        "observed_paper_norm": {"x": paper_x, "y": paper_y},
        "source": "operator_confirmed",
        "confidence": 0.95,
        "safe_zone_inset_x_mm": 10.0,
        "safe_zone_inset_y_mm": 10.0,
    }
    if logical_x is not None and logical_y is not None:
        payload["observed_logical_mm"] = {"x": logical_x, "y": logical_y}
    return payload


def _probe_sample_payloads(*, run_id: str) -> list[dict[str, Any]]:
    return [
        _probe_sample_payload(
            run_id=run_id,
            sample_id="probe-x-pos",
            source="motion_probe",
            axis="X",
            command_x=25.0,
            command_y=0.0,
            before=(250.0, 100.0),
            after=(275.0, 100.0),
        ),
        _probe_sample_payload(
            run_id=run_id,
            sample_id="probe-x-neg",
            source="motion_probe",
            axis="X",
            command_x=-25.0,
            command_y=0.0,
            before=(275.0, 100.0),
            after=(250.0, 100.0),
        ),
        _probe_sample_payload(
            run_id=run_id,
            sample_id="probe-y-pos",
            source="motion_probe",
            axis="Y",
            command_x=0.0,
            command_y=25.0,
            before=(250.0, 100.0),
            after=(250.0, 125.0),
        ),
        _probe_sample_payload(
            run_id=run_id,
            sample_id="probe-y-neg",
            source="motion_probe",
            axis="Y",
            command_x=0.0,
            command_y=-25.0,
            before=(250.0, 125.0),
            after=(250.0, 100.0),
        ),
    ]


def _probe_sample_payload(
    *,
    run_id: str,
    sample_id: str,
    source: str,
    axis: str | None,
    command_x: float,
    command_y: float,
    before: tuple[float, float],
    after: tuple[float, float],
    predicted_dx: float | None = None,
    predicted_dy: float | None = None,
    residual: float | None = None,
    residual_limit: float | None = None,
    status: str = "accepted",
    rejection_reason: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "run_id": run_id,
        "sample_id": sample_id,
        "source": source,
        "axis": axis,
        "commanded_dx_mm": command_x,
        "commanded_dy_mm": command_y,
        "before": _probe_cap_snapshot(*before, frame=1),
        "after": _probe_cap_snapshot(*after, frame=2),
        "status": status,
        "camera_id": "plotter-camera",
        "camera_name": "Plotter Camera",
    }
    if predicted_dx is not None:
        payload["predicted_dx_mm"] = predicted_dx
    if predicted_dy is not None:
        payload["predicted_dy_mm"] = predicted_dy
    if residual is not None:
        payload["residual_mm"] = residual
    if residual_limit is not None:
        payload["residual_limit_mm"] = residual_limit
    if rejection_reason is not None:
        payload["rejection_reason"] = rejection_reason
    return payload


def _probe_cap_snapshot(x_mm: float, y_mm: float, *, frame: int) -> dict[str, Any]:
    return {
        "camera_norm": {"x": x_mm / 533.4, "y": y_mm / 215.9},
        "paper_norm": {"x": x_mm / 533.4, "y": y_mm / 215.9},
        "logical_mm": {"x": x_mm, "y": y_mm},
        "frame_id": frame,
        "confidence": 0.95,
    }


def _trust_sample(
    axis: str,
    commanded_distance_mm: float,
    observed_dx_mm: float,
    observed_dy_mm: float,
    observed_distance_mm: float,
) -> dict[str, Any]:
    return {
        "axis": axis,
        "commanded_distance_mm": commanded_distance_mm,
        "observed_dx_mm": observed_dx_mm,
        "observed_dy_mm": observed_dy_mm,
        "observed_distance_mm": observed_distance_mm,
    }


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


def _max_xy_command_distance(commands: list[str]) -> float:
    return max((_xy_command_distance(command) for command in commands), default=0.0)


def _xy_command_distance(command: str) -> float:
    words = command.strip().split()
    if not any(word in {"G0", "G00", "G1", "G01"} for word in words):
        return 0.0
    x = 0.0
    y = 0.0
    for word in words:
        if word.startswith("X"):
            x = float(word[1:])
        elif word.startswith("Y"):
            y = float(word[1:])
    return math.hypot(x, y)
