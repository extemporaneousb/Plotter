from __future__ import annotations

import json
import math
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from plotter_vision.bridge.server import (
    BridgeRuntimeConfig,
    LocalThreadingHTTPServer,
    PlotterBridge,
    _make_handler,
)
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


def test_visual_probe_preview_is_dry_run_without_transcript_and_bounded_commands(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)

        status_code, preview = client.post(
            "/calibration/probe/preview",
            {
                "request_id": "probe-preview",
                "max_x_probe_mm": 200.0,
                "max_y_probe_mm": 50.0,
                "feed_mm_min": 300.0,
            },
        )

        assert status_code == 200
        assert preview["status"] == "ready"
        assert preview["dry_run"] is True
        assert preview["preview_only"] is True
        assert preview["controller_transcript"] is None
        assert preview["plan"]["requires_homing"] is False
        assert "$H" not in preview["planned_commands"]
        assert not (tmp_path / "transcripts" / "probe-preview.jsonl").exists()
        assert _max_xy_command_distance(preview["planned_commands"]) <= 50.0


def test_visual_probe_preview_allows_x_min_bootstrap_without_transcript(
    tmp_path: Path,
) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path))

    with _running_bridge(bridge) as client:
        status_code, _ = client.post("/paper/register", _paper_registration_payload())
        assert status_code == 200
        status_code, observed = client.post(
            "/calibration/pen/observe",
            _cap_observation_payload(
                paper_x=0.0,
                paper_y=0.0,
                logical_x=0.0,
                logical_y=-32.0,
            ),
        )
        assert status_code == 200
        assert observed["readiness"]["cap_inside_safe_zone"] is False

        status_code, preview = client.post(
            "/calibration/probe/preview",
            {
                "request_id": "probe-bootstrap-preview",
                "bootstrap_only": True,
                "bootstrap_target_x_mm": 200.0,
                "max_x_probe_mm": 100.0,
                "max_y_probe_mm": 50.0,
                "min_probe_mm": 10.0,
                "feed_mm_min": 300.0,
            },
        )

        assert status_code == 200
        assert preview["status"] == "ready"
        assert preview["dry_run"] is True
        assert preview["preview_only"] is True
        assert preview["controller_transcript"] is None
        assert preview["plan"]["plan_mode"] == "x_min_bootstrap"
        assert preview["plan"]["requires_homing"] is False
        assert len(preview["plan"]["moves"]) == 1
        move = preview["plan"]["moves"][0]
        assert move["axis"] == "X"
        assert move["direction"] == 1
        assert move["relative_x_mm"] > 0
        assert move["relative_y_mm"] == 0.0
        assert "$H" not in preview["planned_commands"]
        assert not (tmp_path / "transcripts" / "probe-bootstrap-preview.jsonl").exists()
        assert _max_xy_command_distance(preview["planned_commands"]) <= 50.0


def test_visual_probe_mock_run_writes_transcript_without_homing(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
    )

    with _running_bridge(bridge) as client:
        _register_and_observe_center_cap(client)
        _, preview = client.post(
            "/calibration/probe/preview",
            {"request_id": "probe-preview", "feed_mm_min": 300.0},
        )

        status_code, response = client.post(
            "/calibration/probe/run",
            {
                "request_id": "probe-run",
                "expected_plan_id": preview["plan"]["plan_id"],
                "feed_mm_min": 300.0,
            },
        )

        assert status_code == 200
        assert response["status"] == "completed"
        assert response["dry_run"] is False
        assert response["controller_transcript"] is not None
        assert "$H" not in response["planned_commands"]
        transcript = Path(response["controller_transcript"])
        assert transcript.exists()
        text = transcript.read_text(encoding="utf-8")
        assert '"payload":"$H"' not in text
        assert '"payload":"G91"' in text


def test_visual_probe_mock_run_executes_x_min_bootstrap_without_homing(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=config_path,
        dry_run=False,
        arm_motion=True,
    )

    with _running_bridge(bridge) as client:
        status_code, _ = client.post("/paper/register", _paper_registration_payload())
        assert status_code == 200
        status_code, _ = client.post(
            "/calibration/pen/observe",
            _cap_observation_payload(
                paper_x=0.0,
                paper_y=0.0,
                logical_x=0.0,
                logical_y=-32.0,
            ),
        )
        assert status_code == 200
        _, preview = client.post(
            "/calibration/probe/preview",
            {
                "request_id": "probe-bootstrap-preview",
                "bootstrap_only": True,
                "bootstrap_target_x_mm": 200.0,
                "max_x_probe_mm": 100.0,
                "feed_mm_min": 300.0,
            },
        )

        status_code, response = client.post(
            "/calibration/probe/run",
            {
                "request_id": "probe-bootstrap-run",
                "expected_plan_id": preview["plan"]["plan_id"],
                "bootstrap_only": True,
                "bootstrap_target_x_mm": 200.0,
                "max_x_probe_mm": 100.0,
                "feed_mm_min": 300.0,
            },
        )

        assert status_code == 200
        assert response["status"] == "completed"
        assert response["dry_run"] is False
        assert response["controller_transcript"] is not None
        assert response["plan"]["plan_mode"] == "x_min_bootstrap"
        assert "$H" not in response["planned_commands"]
        assert all("Y" not in command for command in response["planned_commands"] if "G0" in command)
        transcript = Path(response["controller_transcript"])
        assert transcript.exists()
        text = transcript.read_text(encoding="utf-8")
        assert '"payload":"$H"' not in text
        assert '"payload":"G91"' in text


def test_visual_probe_run_aborts_when_projection_outside_bootstrap_band(tmp_path: Path) -> None:
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=_write_machine_config(tmp_path),
        dry_run=False,
        arm_motion=True,
    )

    with _running_bridge(bridge) as client:
        status_code, _ = client.post("/paper/register", _paper_registration_payload())
        assert status_code == 200
        status_code, observed = client.post(
            "/calibration/pen/observe",
            _cap_observation_payload(
                paper_x=0.0,
                paper_y=0.0,
                logical_x=0.0,
                logical_y=-90.0,
            ),
        )
        assert status_code == 200
        assert observed["status"] == "blocked"
        assert observed["readiness"]["cap_inside_safe_zone"] is False

        status_code, response = client.post(
            "/calibration/probe/run",
            {
                "request_id": "probe-outside",
                "bootstrap_only": True,
                "bootstrap_target_x_mm": 200.0,
                "feed_mm_min": 300.0,
            },
        )

        assert status_code == 400
        assert response["status"] == "failed"
        assert response["controller_transcript"] is None
        assert response["error"] is not None
        assert "bootstrap band" in response["error"]
        assert not (tmp_path / "transcripts" / "probe-outside.jsonl").exists()


def test_visual_ready_allows_controlled_calibration_drawing_without_homing(
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

        status_code, drawing = client.post(
            "/calibration/run",
            {
                "request_id": "visual-draw",
                "include_homing": False,
                "mark_size_mm": 4.0,
            },
        )

        assert status_code == 200
        assert drawing["status"] == "completed"
        assert drawing["controller_transcript"] is not None
        assert "$H" not in drawing["planned_commands"]
        text = Path(drawing["controller_transcript"]).read_text(encoding="utf-8")
        assert '"payload":"$H"' not in text
        assert '"payload":"M3 S720"' in text
        machine = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
        assert machine.homing_trusted is False
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
