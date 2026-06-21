from __future__ import annotations

from pathlib import Path

import pytest

from plotter_vision.bridge.server import (
    BridgeRuntimeConfig,
    CapabilityTestRequest,
    PaperRegistrationCornerRequest,
    PaperRegistrationRequest,
    PlotterBridge,
)
from plotter_vision.bridge.planner import PolygonDrawRequest, build_polygon_draw_plan
from plotter_vision.calibration.vision_model import CameraPointNorm
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.drawing import (
    CapabilityTestKind,
    DrawingProgram,
    build_capability_test_definition,
    build_capability_test_program,
)


@pytest.mark.parametrize(
    "kind",
    [
        "center_crosshair",
        "line_length",
        "square_closure",
        "triangle",
        "multi_shape_coordinate_sheet",
    ],
)
def test_capability_tests_produce_drawing_programs(kind: CapabilityTestKind) -> None:
    program = build_capability_test_program(kind)
    definition = build_capability_test_definition(kind)
    machine = _machine_with_pen()

    assert isinstance(program, DrawingProgram)
    assert definition.kind == kind
    assert definition.residual_roles

    plan = build_polygon_draw_plan(
        request=PolygonDrawRequest(program=program, request_id=f"{kind}-preview"),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id=f"{kind}-preview",
    )

    assert plan.simulation.status == "ok"
    assert plan.summary.draw_segment_count > 0


def test_capability_preview_projects_overlay_and_records_expected_geometry(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path), dry_run=True)
    bridge.register_paper(_paper_registration_request())

    response = bridge.preview_capability_test(
        CapabilityTestRequest(
            kind="multi_shape_coordinate_sheet",
            request_id="cap-preview",
        )
    )

    assert response.status == "ready"
    assert response.preview_only is True
    assert response.plan_hash
    assert response.preview_overlay is not None
    assert response.preview_overlay.projected is True
    assert len(response.preview_overlay.primitives) == response.summary.draw_segment_count

    binding = bridge.visual_position_binding_status()
    assert binding.binding is not None
    assert binding.status == "collecting"
    assert len(binding.binding.expected_simulated_geometry) >= len(response.preview_overlay.primitives)


def test_capability_run_requires_axis_model_or_validated_binding(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, config_path=_write_machine_config(tmp_path), dry_run=False)

    response = bridge.run_capability_test(
        CapabilityTestRequest(kind="line_length", request_id="cap-blocked")
    )

    assert response.status == "failed"
    assert response.error is not None
    assert "VisualPositionBinding" in response.error
    assert response.controller_transcript is None


def test_capability_run_allows_axis_model_and_preview_hash(tmp_path: Path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = _machine_with_pen()
    machine.axis_model_trusted = True
    machine.save_json(config_path)
    bridge = _bridge(tmp_path=tmp_path, config_path=config_path, dry_run=False)
    preview = bridge.preview_capability_test(
        CapabilityTestRequest(
            kind="square_closure",
            request_id="cap-square-preview",
        )
    )

    response = bridge.run_capability_test(
        CapabilityTestRequest(
            kind="square_closure",
            request_id="cap-square-run",
            expected_plan_hash=preview.plan_hash,
        )
    )

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.controller_transcript is not None
    transcript = Path(response.controller_transcript)
    assert transcript.exists()
    assert '"payload":"M3 S720"' in transcript.read_text(encoding="utf-8")


def _bridge(*, tmp_path: Path, config_path: Path, dry_run: bool) -> PlotterBridge:
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=dry_run,
            mock=True,
            arm_motion=True,
            arm_pen=True,
            arm_homing=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )


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


def _paper_registration_request() -> PaperRegistrationRequest:
    return PaperRegistrationRequest(
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


def _project_paper_to_camera(x_norm: float, y_norm: float) -> tuple[float, float]:
    denominator = 1.0 + 0.06 * x_norm - 0.04 * y_norm
    return (
        (0.16 + 0.68 * x_norm + 0.05 * y_norm) / denominator,
        (0.14 + 0.04 * x_norm + 0.70 * y_norm) / denominator,
    )
