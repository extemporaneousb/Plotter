from __future__ import annotations

from pathlib import Path

import pytest

from plotter_vision.bridge import server as bridge_server_module
from plotter_vision.bridge.planner import ShapeExecutionRequest, build_shape_execution_plan
from plotter_vision.bridge.server import (
    AxisModelTrustRequest,
    AxisModelTrustSample,
    BridgeRuntimeConfig,
    CalibrationMarkPlanRequest,
    ImageShapePreviewRequest,
    MachineArmRequest,
    DotTestPreviewRequest,
    DotTestRunRequest,
    MachineCenterRequest,
    MachineHomeRequest,
    MachineJogRequest,
    MachineDotMarkRequest,
    MachinePenRequest,
    MachineReconnectRequest,
    MachineRelativeMarkRequest,
    MachineRelativeMoveRequest,
    MachineStatusResponse,
    MachineStopRequest,
    MachineUnlockRequest,
    PaperRegistrationCornerRequest,
    PaperRegistrationRequest,
    PlotterBridge,
    _motion_idle_timeout_s,
)
from plotter_vision.calibration.vision_model import CameraPointNorm
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.mock import MockTransport
from plotter_vision.controller.serial_transport import SerialPortInfo
from plotter_vision.drawing import LuminanceRaster


def test_shape_plan_builds_homing_center_triangle_and_park() -> None:
    machine = _machine_with_pen()
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(request_id="cmd-test"),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="cmd-test",
    )

    commands = plan.command_strings

    assert commands[0] == "$H"
    assert "G53 G1 X-266.7 Y-107.95" in commands
    assert "M3 S720" in commands
    assert "G91" in commands
    assert "G1 X20" in commands
    assert "G90" in commands
    assert commands[-1] == "G53 G1 X-221.7 Y-107.95"


def test_shape_plan_omits_pen_commands_when_missing_in_dry_run() -> None:
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(pattern="square", request_id="cmd-test"),
        machine=MachineConfig(),
        safety=SafetyState(dry_run=True),
        command_id="cmd-test",
    )

    assert all(not command.startswith("M") for command in plan.command_strings)
    assert "G1 X20" in plan.command_strings
    assert "G1 Y20" in plan.command_strings


def test_bridge_dry_run_returns_completed_plan(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.draw_shape(ShapeExecutionRequest(request_id="cmd-dry"))

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.controller_transcript is None
    assert response.planned_commands[0] == "$H"
    assert response.simulation is not None
    assert len(response.simulation.drawn_segments) == 3
    assert response.evaluation is not None
    assert response.evaluation.status == "passed"
    assert (tmp_path / "events.jsonl").exists()


def test_bridge_dry_run_blocks_shape_execution_when_preview_draws_nothing(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.save_json(config_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.draw_shape(ShapeExecutionRequest(pattern="square", request_id="cmd-no-preview"))

    assert response.status == "failed"
    assert response.controller_transcript is None
    assert response.simulation is not None
    assert response.simulation.drawn_segments == []
    assert response.evaluation is not None
    assert response.evaluation.status == "failed"
    assert response.error is not None
    assert "Shape preview failed geometry gate" in response.error


def test_bridge_live_shape_preview_does_not_move_or_require_axis_trust(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.preview_shape(
        ShapeExecutionRequest(
            pattern="square",
            include_homing=False,
            request_id="preview-square",
        )
    )

    assert response.status == "ready"
    assert response.dry_run is True
    assert response.controller_transcript is None
    assert response.simulation is not None
    assert len(response.simulation.drawn_segments) == 4
    assert response.evaluation is not None
    assert response.evaluation.status == "passed"
    assert not (tmp_path / "transcripts" / "preview-square.jsonl").exists()


def test_shape_preview_returns_projected_overlay_and_binding_expected_geometry(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)
    registration = bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )

    response = bridge.preview_shape(
        ShapeExecutionRequest(
            pattern="square",
            include_homing=False,
            request_id="shape-overlay",
        )
    )

    assert response.status == "ready"
    assert response.preview_overlay is not None
    assert response.preview_overlay.projected is True
    assert response.preview_overlay.paper_registration_id == registration.registration["registration_id"]
    assert len(response.preview_overlay.primitives) == 4

    first = response.preview_overlay.primitives[0]
    expected_start = _project_paper_to_camera(
        first.start_paper_mm.x / 533.4,
        first.start_paper_mm.y / 215.9,
    )
    assert first.start_camera_norm is not None
    assert first.start_camera_norm.x == pytest.approx(expected_start[0], abs=1e-9)
    assert first.start_camera_norm.y == pytest.approx(expected_start[1], abs=1e-9)

    binding = bridge.visual_position_binding_status()
    assert binding.status == "collecting"
    assert binding.binding is not None
    assert len(binding.binding.expected_simulated_geometry) == 8


def test_bridge_mock_live_run_writes_transcript(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.axis_model_trusted = True
    machine.save_json(config_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.draw_shape(ShapeExecutionRequest(request_id="cmd-live"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.controller_transcript is not None
    transcript = Path(response.controller_transcript)
    assert transcript.exists()
    text = transcript.read_text(encoding="utf-8")
    assert '"payload":"$H"' in text
    assert '"payload":"M3 S720"' in text


def test_bridge_calibration_mark_preview_is_preview_only(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.preview_calibration_marks(
        CalibrationMarkPlanRequest(request_id="cal-preview")
    )

    assert response.status == "ready"
    assert response.dry_run is True
    assert response.preview_only is True
    assert response.controller_transcript is None
    assert "$H" not in response.planned_commands
    assert response.summary is not None
    assert response.summary.mark_polyline_count == 10
    assert not (tmp_path / "transcripts" / "cal-preview.jsonl").exists()


def test_bridge_image_contour_preview_is_preview_only_without_hatching(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.preview_image_contours(
        ImageShapePreviewRequest(
            raster=LuminanceRaster(
                samples=[
                    [1.0, 1.0, 1.0],
                    [1.0, 0.0, 1.0],
                    [1.0, 1.0, 1.0],
                ]
            ),
            request_id="image-preview",
        )
    )

    assert response.status == "ready"
    assert response.preview_only is True
    assert response.dry_run is True
    assert response.controller_transcript is None
    assert response.raster_summary is not None
    assert response.raster_summary.contour_count == 1
    assert response.summary is not None
    assert response.summary.contour_polyline_count == 1
    assert response.summary.hatch_polyline_count == 0
    assert not (tmp_path / "transcripts" / "image-preview.jsonl").exists()


def test_bridge_mock_live_calibration_marks_write_transcript_without_homing(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.axis_model_trusted = True
    machine.homing_trusted = True
    machine.save_json(config_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.run_calibration_marks(
        CalibrationMarkPlanRequest(request_id="cal-run", include_homing=False)
    )

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.controller_transcript is not None
    text = Path(response.controller_transcript).read_text(encoding="utf-8")
    assert '"payload":"$H"' not in text
    assert '"payload":"M3 S720"' in text


def test_bridge_paper_registration_solves_and_persists_homography(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)
    corners = [
        ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
        ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
        ("top_right", _project_paper_to_camera(1.0, 1.0)),
        ("top_left", _project_paper_to_camera(0.0, 1.0)),
    ]

    response = bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=210.0,
            paper_height_mm=297.0,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in corners
            ],
        )
    )

    assert response.status == "locked"
    assert response.registration is not None
    assert response.registration["rms_error_norm"] == pytest.approx(0.0, abs=1e-12)
    assert response.registration["paper_size_mm"] == {"width": 210.0, "height": 297.0}
    assert Path(response.registration_file).exists()
    assert (tmp_path / "calibration" / "latest_paper_registration.json").exists()

    status = bridge.paper_registration_status()
    assert status.status == "locked"
    assert status.registration is not None
    assert status.registration["camera_to_paper"]["coefficients"]


def test_bridge_dot_test_preview_requires_paper_registration(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.preview_dot_test(DotTestPreviewRequest(pattern="center"))

    assert response.status == "failed"
    assert response.preview_only is True
    assert response.error is not None
    assert "No paper registration has been saved" in response.error


def test_bridge_dot_test_preview_projects_marks_to_camera(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)
    bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )

    response = bridge.preview_dot_test(
        DotTestPreviewRequest(pattern="five", mark_size_mm=4.0, margin_mm=25.0)
    )

    assert response.status == "ready"
    assert response.preview_only is True
    assert response.point_count == 5
    assert response.simulation is not None
    assert response.simulation.status == "ok"
    assert len(response.points) == 5
    assert len(response.camera_segments) == 10
    assert response.planned_commands
    assert response.plan_hash

    expected_center = _project_paper_to_camera(0.5, 0.5)
    assert response.points[0].point_id == "P01"
    assert response.points[0].camera_norm.x == pytest.approx(expected_center[0], abs=1e-9)
    assert response.points[0].camera_norm.y == pytest.approx(expected_center[1], abs=1e-9)
    assert response.camera_segments[0].point_id == "P01"
    assert response.camera_segments[0].start_norm.x < response.camera_segments[0].end_norm.x


def test_bridge_dot_test_run_rejects_non_center_pattern(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.run_dot_test(DotTestRunRequest(pattern="five"))

    assert response.status == "failed"
    assert response.error is not None
    assert "supports only center pattern" in response.error


def test_bridge_dot_test_run_executes_previewed_center_mark_and_parks(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.homing_trusted = True
    machine.axis_model_trusted = True
    machine.save_json(config_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)
    bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )
    preview = bridge.preview_dot_test(DotTestPreviewRequest(pattern="center"))

    response = bridge.run_dot_test(
        DotTestRunRequest(
            pattern="center",
            expected_plan_hash=preview.plan_hash,
        )
    )

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.controller_transcript is not None
    assert "M3 S720" in response.planned_commands
    assert "M3 S40" in response.planned_commands
    assert response.planned_commands[-1] == "G53 G1 X-216.7 Y-107.95"
    transcript = Path(response.controller_transcript)
    assert transcript.exists()
    text = transcript.read_text(encoding="utf-8")
    assert '"payload":"M3 S720"' in text
    assert '"payload":"G53 G1 X-216.7 Y-107.95"' in text


def test_bridge_dot_test_run_rejects_stale_preview_hash(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.homing_trusted = True
    machine.axis_model_trusted = True
    machine.save_json(config_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)
    bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )

    response = bridge.run_dot_test(
        DotTestRunRequest(pattern="center", expected_plan_hash="stale")
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "plan changed after preview" in response.error


def test_bridge_dot_test_run_requires_trusted_axis_model(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.homing_trusted = True
    machine.axis_model_trusted = False
    machine.save_json(config_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)
    bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )
    preview = bridge.preview_dot_test(DotTestPreviewRequest(pattern="center"))

    response = bridge.run_dot_test(
        DotTestRunRequest(pattern="center", expected_plan_hash=preview.plan_hash)
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "axis_model_trusted=true" in response.error


def test_bridge_dot_test_run_allows_axis_model_without_homed_position(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.homing_trusted = False
    machine.axis_model_trusted = True
    machine.save_json(config_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)
    bridge.register_paper(
        PaperRegistrationRequest(
            paper_width_mm=533.4,
            paper_height_mm=215.9,
            corners=[
                PaperRegistrationCornerRequest(
                    corner=corner,  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=observed[0], y=observed[1]),
                )
                for corner, observed in [
                    ("bottom_left", _project_paper_to_camera(0.0, 0.0)),
                    ("bottom_right", _project_paper_to_camera(1.0, 0.0)),
                    ("top_right", _project_paper_to_camera(1.0, 1.0)),
                    ("top_left", _project_paper_to_camera(0.0, 1.0)),
                ]
            ],
        )
    )
    preview = bridge.preview_dot_test(DotTestPreviewRequest(pattern="center"))

    response = bridge.run_dot_test(
        DotTestRunRequest(pattern="center", expected_plan_hash=preview.plan_hash)
    )

    assert response.status == "completed"
    assert response.error is None
    assert response.controller_transcript is not None


def test_bridge_machine_status_reports_dry_run_without_controller(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
        )
    )

    response = bridge.machine_status()

    assert response.status == "dry_run"
    assert response.state == "DryRun"
    assert response.is_busy is False


def test_bridge_status_lock_contention_does_not_fabricate_run(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)
    bridge._remember_machine_status(  # noqa: SLF001
        MachineStatusResponse(
            status="ready",
            dry_run=True,
            controller="mock",
            state="Idle",
            is_busy=False,
            is_alarm=False,
        )
    )

    assert bridge._machine_lock.acquire(blocking=False)  # noqa: SLF001
    try:
        status = bridge.machine_status()
    finally:
        bridge._machine_lock.release()  # noqa: SLF001

    assert status.state == "Idle"
    assert status.is_busy is False
    assert status.active_command_id is None


def test_motion_idle_timeout_scales_with_slow_feed() -> None:
    assert _motion_idle_timeout_s("G1 X20", feed_mm_min=60.0) == pytest.approx(48.0)
    assert _motion_idle_timeout_s("G1 X20", feed_mm_min=600.0) == pytest.approx(15.0)


def test_bridge_resolves_replacement_usb_serial_port(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=False,
            controller_port="/dev/cu.usbserial-missing",
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
        )
    )
    monkeypatch.setattr(
        bridge_server_module,
        "list_serial_ports",
        lambda: [
            SerialPortInfo(
                device="/dev/cu.usbserial-new",
                description="USB Serial",
                hwid="USB VID:PID=0403:6001",
            )
        ],
    )

    assert bridge._resolve_controller_port() == "/dev/cu.usbserial-new"  # noqa: SLF001
    assert bridge.config.controller_port == "/dev/cu.usbserial-new"


def test_bridge_rejects_ambiguous_replacement_usb_serial_ports(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=False,
            controller_port="/dev/cu.usbserial-missing",
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
        )
    )
    monkeypatch.setattr(
        bridge_server_module,
        "list_serial_ports",
        lambda: [
            SerialPortInfo(
                device="/dev/cu.usbserial-a",
                description="USB Serial A",
                hwid="USB VID:PID=0403:6001",
            ),
            SerialPortInfo(
                device="/dev/cu.usbserial-b",
                description="USB Serial B",
                hwid="USB VID:PID=0403:6001",
            ),
        ],
    )

    with pytest.raises(ValueError, match="Multiple USB serial controllers"):
        bridge._resolve_controller_port()  # noqa: SLF001


def test_bridge_mock_reconnect_returns_status(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.reconnect_machine(MachineReconnectRequest(request_id="reconnect"))

    assert response.status == "completed"
    assert response.action == "reconnect"
    assert response.machine_status is not None
    assert response.machine_status.state == "Idle"
    assert response.controller_transcript is not None
    assert Path(response.controller_transcript).exists()


def test_bridge_runtime_arm_auto_connects_single_visible_controller(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
        )
    )
    monkeypatch.setattr(
        bridge_server_module,
        "list_serial_ports",
        lambda: [
            SerialPortInfo(
                device="/dev/cu.usbserial-live",
                description="USB Serial",
                hwid="USB VID:PID=0403:6001",
            )
        ],
    )

    def make_mock_controller(self: PlotterBridge, *, transcript_path: Path) -> GrblHalController:
        return GrblHalController(
            MockTransport(),
            source="controller_bridge",
            transcript_path=transcript_path,
        )

    monkeypatch.setattr(PlotterBridge, "_make_controller", make_mock_controller)

    response = bridge.arm_machine(MachineArmRequest(request_id="arm-live"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert bridge.config.controller_port == "/dev/cu.usbserial-live"
    assert bridge.config.arm_motion is True
    assert bridge.config.arm_pen is True
    assert bridge.config.arm_homing is True
    assert bridge.config.arm_unlock is True
    assert response.machine_status is not None
    assert response.machine_status.dry_run is False
    assert response.machine_status.arm_motion is True
    assert response.machine_status.controller == "serial:/dev/cu.usbserial-live@115200 (missing)"


def test_bridge_runtime_disarm_returns_to_dry_run_without_forgetting_controller(
    tmp_path: Path,
) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            arm_unlock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
        )
    )

    response = bridge.arm_machine(MachineArmRequest(live=False, request_id="disarm"))

    assert response.status == "completed"
    assert response.dry_run is True
    assert bridge.config.arm_motion is False
    assert bridge.config.arm_pen is False
    assert bridge.config.arm_homing is False
    assert bridge.config.arm_unlock is False
    assert response.machine_status is not None
    assert response.machine_status.dry_run is True
    assert response.machine_status.arm_motion is False


def test_bridge_runtime_arm_rejects_mock_bridge(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.arm_machine(MachineArmRequest(request_id="arm-mock"))

    assert response.status == "failed"
    assert response.error is not None
    assert "serial controller bridge" in response.error
    assert bridge.config.dry_run is True


def test_bridge_dry_run_jog_validates_and_plans_commands(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.jog_machine(
        MachineJogRequest(axis="x", distance_mm=2.5, feed_mm_min=500.0, request_id="jog-test")
    )

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.planned_commands == ["G21", "G91", "G94", "G1 F500", "G1 X2.5", "G90"]


def test_bridge_dry_run_relative_move_raises_pen_and_plans_xy_move(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.relative_move_machine(
        MachineRelativeMoveRequest(
            x_mm=2.5,
            y_mm=-1.25,
            feed_mm_min=300.0,
            request_id="rel-test",
        )
    )

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.planned_commands == [
        "M3 S40",
        "G4 P0.3",
        "G21",
        "G91",
        "G94",
        "G1 F300",
        "G1 X2.5 Y-1.25",
        "G90",
    ]


def test_bridge_relative_move_rejects_oversized_vector(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.relative_move_machine(
        MachineRelativeMoveRequest(x_mm=51.0, y_mm=0.0, feed_mm_min=300.0)
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "exceeds max_jog_mm" in response.error


def test_bridge_dry_run_dot_mark_plans_pen_down_up(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.dot_mark_machine(MachineDotMarkRequest(request_id="dot-mark"))

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.planned_commands == [
        "M3 S720",
        "G4 P0.3",
        "M3 S40",
        "G4 P0.3",
    ]


def test_bridge_dry_run_relative_mark_draws_visible_cross_and_returns_to_center(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.relative_mark_machine(
        MachineRelativeMarkRequest(
            request_id="rel-mark",
            mark_size_mm=6.0,
            draw_feed_mm_min=120.0,
            travel_feed_mm_min=300.0,
        )
    )

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.planned_commands[0:4] == ["G21", "G91", "G94", "M3 S40"]
    assert "G1 X-3" in response.planned_commands
    assert "M3 S720" in response.planned_commands
    assert "G1 X6" in response.planned_commands
    assert "G1 X-3 Y-3" in response.planned_commands
    assert "G1 Y6" in response.planned_commands
    assert "G1 Y-3" in response.planned_commands
    assert response.planned_commands[-1] == "G90"


def test_bridge_axis_model_trust_requires_visual_readiness_artifact(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.trust_axis_model(
        AxisModelTrustRequest(
            sample_count=4,
            command_distance_mm=25.0,
            min_observed_distance_mm=22.0,
            rms_residual_mm=2.5,
            max_residual_mm=4.0,
            samples=[
                AxisModelTrustSample(
                    axis="X",
                    commanded_distance_mm=-25.0,
                    observed_dx_mm=-23.0,
                    observed_dy_mm=1.0,
                    observed_distance_mm=23.02,
                ),
                AxisModelTrustSample(
                    axis="X",
                    commanded_distance_mm=25.0,
                    observed_dx_mm=23.2,
                    observed_dy_mm=-1.2,
                    observed_distance_mm=23.23,
                ),
                AxisModelTrustSample(
                    axis="Y",
                    commanded_distance_mm=-25.0,
                    observed_dx_mm=0.8,
                    observed_dy_mm=-22.5,
                    observed_distance_mm=22.51,
                ),
                AxisModelTrustSample(
                    axis="Y",
                    commanded_distance_mm=25.0,
                    observed_dx_mm=-1.1,
                    observed_dy_mm=22.8,
                    observed_distance_mm=22.83,
                ),
            ],
        )
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "visual readiness artifact" in response.error
    saved = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    assert saved.axis_model_trusted is False


def test_bridge_axis_model_trust_rejects_weak_green_cap_probe(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.trust_axis_model(
        AxisModelTrustRequest(
            sample_count=4,
            command_distance_mm=25.0,
            min_observed_distance_mm=4.0,
            rms_residual_mm=2.5,
            max_residual_mm=4.0,
            samples=[
                AxisModelTrustSample(
                    axis="X",
                    commanded_distance_mm=-25.0,
                    observed_dx_mm=-4.0,
                    observed_dy_mm=0.0,
                    observed_distance_mm=4.0,
                ),
                AxisModelTrustSample(
                    axis="X",
                    commanded_distance_mm=25.0,
                    observed_dx_mm=4.0,
                    observed_dy_mm=0.0,
                    observed_distance_mm=4.0,
                ),
                AxisModelTrustSample(
                    axis="Y",
                    commanded_distance_mm=-25.0,
                    observed_dx_mm=0.0,
                    observed_dy_mm=-4.0,
                    observed_distance_mm=4.0,
                ),
                AxisModelTrustSample(
                    axis="Y",
                    commanded_distance_mm=25.0,
                    observed_dx_mm=0.0,
                    observed_dy_mm=4.0,
                    observed_distance_mm=4.0,
                ),
            ],
        )
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "8mm observed cap displacement" in response.error
    saved = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    assert saved.axis_model_trusted is False


def test_bridge_dry_run_pen_up_down_use_saved_config(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    up = bridge.pen_up_machine(MachinePenRequest(request_id="pen-up"))
    down = bridge.pen_down_machine(MachinePenRequest(request_id="pen-down"))

    assert up.status == "completed"
    assert up.planned_commands == ["M3 S40", "G4 P0.3"]
    assert down.status == "completed"
    assert down.planned_commands == ["M3 S720", "G4 P0.3"]


def test_bridge_dry_run_stop_plans_realtime_feed_hold(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.stop_machine(MachineStopRequest(request_id="stop"))

    assert response.status == "completed"
    assert response.planned_commands == ["!"]


def test_bridge_dry_run_unlock_plans_clear_alarm(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.unlock_machine(MachineUnlockRequest(request_id="unlock"))

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.planned_commands == ["$X"]


def test_bridge_mock_live_center_uses_machine_geometry(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.center_machine(MachineCenterRequest(feed_mm_min=500.0, request_id="center"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert "G53 G1 X-266.7 Y-107.95" in response.planned_commands
    assert response.controller_transcript is not None
    assert Path(response.controller_transcript).exists()


def test_bridge_mock_live_pen_down_writes_transcript(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.pen_down_machine(MachinePenRequest(request_id="pen-down-live"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.planned_commands == ["M3 S720", "G4 P0.3"]
    assert response.controller_transcript is not None
    text = Path(response.controller_transcript).read_text(encoding="utf-8")
    assert '"payload":"M3 S720"' in text


def test_bridge_mock_live_stop_is_noop_when_controller_is_idle(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.stop_machine(MachineStopRequest(request_id="stop-live"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.planned_commands == ["!"]
    assert response.controller_transcript is not None
    text = Path(response.controller_transcript).read_text(encoding="utf-8")
    assert '"payload":"!"' not in text
    assert response.machine_status is not None
    assert response.machine_status.state == "Idle"


def test_bridge_mock_live_unlock_writes_transcript_when_armed(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.unlock_machine(MachineUnlockRequest(request_id="unlock-live"))

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.planned_commands == ["$X"]
    assert response.controller_transcript is not None
    text = Path(response.controller_transcript).read_text(encoding="utf-8")
    assert '"payload":"$X"' in text


def test_bridge_mock_live_unlock_requires_arm(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            arm_unlock=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )

    response = bridge.unlock_machine(MachineUnlockRequest(request_id="unlock-blocked"))

    assert response.status == "failed"
    assert response.error == "Real unlock requires arm_unlock=true."


def test_bridge_mock_live_home_recenters_by_default(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
    bridge = _live_bridge(tmp_path=tmp_path, config_path=config_path)

    response = bridge.home_machine(MachineHomeRequest(request_id="home"))

    assert response.status == "completed"
    assert response.planned_commands[0] == "$H"
    assert "G53 G1 X-266.7 Y-107.95" in response.planned_commands
    assert response.machine_status is not None
    assert response.machine_status.homing_trusted is True
    saved = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    assert saved.homing_trusted is True


def _machine_with_pen() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    return machine


def _write_machine_config(tmp_path: Path) -> Path:
    config_path = tmp_path / "machine_config.json"
    _machine_with_pen().save_json(config_path)
    return config_path


def _bridge(*, tmp_path: Path, config_path: Path) -> PlotterBridge:
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )


def _live_bridge(*, tmp_path: Path, config_path: Path) -> PlotterBridge:
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=False,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=True,
            arm_unlock=True,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )




def _project_paper_to_camera(x_norm: float, y_norm: float) -> tuple[float, float]:
    denominator = 1.0 + 0.06 * x_norm - 0.04 * y_norm
    return (
        (0.16 + 0.68 * x_norm + 0.05 * y_norm) / denominator,
        (0.14 + 0.04 * x_norm + 0.70 * y_norm) / denominator,
    )
