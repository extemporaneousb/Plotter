from __future__ import annotations

from pathlib import Path

import pytest

from plotter_vision.bridge.planner import PolygonDrawRequest, build_polygon_draw_plan
from plotter_vision.bridge.server import BridgeRuntimeConfig, PlotterBridge
from plotter_vision.calibration.vision_model import LogicalPointMM
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.drawing import (
    DrawingFrameMM,
    DrawingProgram,
    PaperPointNorm,
    PlannedPolyline,
    PolygonPrimitive,
    SimpleShapePrimitive,
)
from plotter_vision.machine.safety import MotionSafetyError


def test_polygon_draw_plan_maps_paper_frame_to_machine_coordinates() -> None:
    machine = _machine_with_pen()
    request = PolygonDrawRequest(
        program=DrawingProgram(
            polygons=[
                PolygonPrimitive(
                    vertices=[
                        PaperPointNorm(x=0.1, y=0.1),
                        PaperPointNorm(x=0.9, y=0.1),
                        PaperPointNorm(x=0.9, y=0.9),
                        PaperPointNorm(x=0.1, y=0.9),
                    ],
                    shade=0.0,
                    outline=True,
                )
            ]
        ),
        frame=DrawingFrameMM(origin_x_mm=10.0, origin_y_mm=20.0, width_mm=100.0, height_mm=50.0),
        max_segment_mm=120.0,
        request_id="paper-square",
    )

    plan = build_polygon_draw_plan(
        request=request,
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="paper-square",
    )

    assert plan.summary.polyline_count == 1
    assert plan.summary.draw_segment_count == 4
    assert "G53 G1 X-513.4 Y-190.9" in plan.command_strings
    assert plan.simulation.status == "ok"
    assert plan.simulation.preview_segments[0].start_norm == pytest.approx(
        (20.0 / 533.4, 25.0 / 215.9)
    )


def test_polygon_draw_plan_accepts_preplanned_line_polyline_and_splits_long_segments() -> None:
    machine = _machine_with_pen()
    request = PolygonDrawRequest(
        polylines=[
            PlannedPolyline(
                role="outline",
                points=[
                    LogicalPointMM(x=10.0, y=20.0),
                    LogicalPointMM(x=70.0, y=20.0),
                ],
            )
        ],
        max_segment_mm=25.0,
        request_id="line",
    )

    plan = build_polygon_draw_plan(
        request=request,
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="line",
    )

    assert plan.summary.polyline_count == 1
    assert plan.summary.draw_segment_count == 3
    assert "G53 G1 X-503.4 Y-195.9" in plan.command_strings
    assert "G53 G1 X-483.4 Y-195.9" in plan.command_strings
    assert "G53 G1 X-463.4 Y-195.9" in plan.command_strings


def test_shaded_polygon_program_expands_to_hatch_motion() -> None:
    machine = _machine_with_pen()
    request = PolygonDrawRequest(
        program=DrawingProgram(
            polygons=[
                PolygonPrimitive(
                    vertices=[
                        PaperPointNorm(x=0.25, y=0.25),
                        PaperPointNorm(x=0.75, y=0.25),
                        PaperPointNorm(x=0.75, y=0.75),
                        PaperPointNorm(x=0.25, y=0.75),
                    ],
                    shade=0.8,
                    outline=False,
                    hatch_angle_deg=0.0,
                )
            ],
            min_hatch_spacing_mm=5.0,
            max_hatch_spacing_mm=10.0,
        ),
        frame=DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=100.0),
        max_segment_mm=120.0,
        request_id="hatch",
    )

    plan = build_polygon_draw_plan(
        request=request,
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="hatch",
    )

    assert plan.summary.outline_polyline_count == 0
    assert plan.summary.hatch_polyline_count > 0
    assert len(plan.simulation.drawn_segments) == plan.summary.draw_segment_count
    assert plan.summary.drawn_length_mm > 0


@pytest.mark.parametrize(("kind", "segment_count"), [("triangle", 3), ("square", 4)])
def test_simple_shape_primitives_produce_expected_preview_segments(
    kind: str,
    segment_count: int,
) -> None:
    machine = _machine_with_pen()
    request = PolygonDrawRequest(
        program=DrawingProgram(
            simple_shapes=[
                SimpleShapePrimitive(
                    kind=kind,  # type: ignore[arg-type]
                    center=PaperPointNorm(x=0.5, y=0.5),
                    size_norm=0.2,
                )
            ]
        ),
        max_segment_mm=120.0,
        request_id=f"{kind}-primitive",
    )

    plan = build_polygon_draw_plan(
        request=request,
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id=f"{kind}-primitive",
    )

    assert plan.summary.outline_polyline_count == 1
    assert plan.summary.hatch_polyline_count == 0
    assert plan.summary.draw_segment_count == segment_count
    assert len(plan.simulation.preview_segments) == segment_count


def test_real_polygon_draw_requires_motion_arm() -> None:
    machine = _machine_with_pen()

    with pytest.raises(MotionSafetyError, match="armed_motion"):
        build_polygon_draw_plan(
            request=_line_request(),
            machine=machine,
            safety=SafetyState(dry_run=False, armed_motion=False, allow_pen_actuation=True),
            command_id="blocked",
        )


def test_real_polygon_draw_requires_axis_model_or_visual_binding() -> None:
    machine = _machine_with_pen()

    with pytest.raises(MotionSafetyError, match="axis_model_trusted"):
        build_polygon_draw_plan(
            request=_line_request(),
            machine=machine,
            safety=SafetyState(dry_run=False, armed_motion=True, allow_pen_actuation=True),
            command_id="blocked",
        )


def test_real_polygon_draw_allows_axis_model_without_visual_binding() -> None:
    machine = _machine_with_pen()
    machine.axis_model_trusted = True

    plan = build_polygon_draw_plan(
        request=_line_request(),
        machine=machine,
        safety=SafetyState(
            dry_run=False,
            armed_motion=True,
            allow_pen_actuation=True,
        ),
        command_id="axis-only",
    )

    assert plan.command_id == "axis-only"


def test_real_polygon_draw_allows_visual_position_without_homing() -> None:
    machine = _machine_with_pen()

    plan = build_polygon_draw_plan(
        request=_line_request(request_id="visual-position").model_copy(
            update={"visual_position_trusted": True}
        ),
        machine=machine,
        safety=SafetyState(dry_run=False, armed_motion=True, allow_pen_actuation=True),
        command_id="visual-position",
    )

    assert plan.command_id == "visual-position"
    assert not any(command.kind == "homing" for command in plan.planned_commands)


def test_real_polygon_draw_rejects_homing_without_axis_model_or_binding() -> None:
    machine = _machine_with_pen()
    machine.homing_trusted = True

    with pytest.raises(MotionSafetyError, match="axis_model_trusted"):
        build_polygon_draw_plan(
            request=_line_request(),
            machine=machine,
            safety=SafetyState(
                dry_run=False,
                armed_motion=True,
                allow_pen_actuation=True,
            ),
            command_id="homing-only",
        )


def test_bridge_dry_run_draw_program_returns_preview_and_planned_commands(tmp_path: Path) -> None:
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

    response = bridge.draw_program(_line_request(request_id="draw-dry"))

    assert response.status == "completed"
    assert response.dry_run is True
    assert response.controller_transcript is None
    assert response.summary is not None
    assert response.summary.draw_segment_count == 3
    assert response.simulation is not None
    assert response.simulation.status == "ok"
    assert response.machine_status is not None
    assert response.machine_status.status == "dry_run"
    assert (tmp_path / "events.jsonl").exists()


def test_bridge_mock_live_draw_program_writes_transcript(tmp_path: Path) -> None:
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

    response = bridge.draw_program(_line_request(request_id="draw-live", include_homing=True))

    assert response.status == "completed"
    assert response.dry_run is False
    assert response.planned_commands[0] == "$H"
    assert response.controller_transcript is not None
    text = Path(response.controller_transcript).read_text(encoding="utf-8")
    assert '"payload":"$H"' in text
    assert '"payload":"G53 G1 X-523.4 Y-195.9"' in text


def test_bridge_mock_live_draw_program_requires_trusted_axis_model(tmp_path: Path) -> None:
    config_path = _write_machine_config(tmp_path)
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

    response = bridge.draw_program(_line_request(request_id="draw-blocked", include_homing=True))

    assert response.status == "failed"
    assert response.error is not None
    assert "axis_model_trusted=true" in response.error


def _line_request(*, request_id: str = "line", include_homing: bool = False) -> PolygonDrawRequest:
    return PolygonDrawRequest(
        polylines=[
            PlannedPolyline(
                role="outline",
                points=[
                    LogicalPointMM(x=10.0, y=20.0),
                    LogicalPointMM(x=70.0, y=20.0),
                ],
            )
        ],
        max_segment_mm=25.0,
        request_id=request_id,
        include_homing=include_homing,
    )


def _machine_with_pen() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.max_calibration_line_mm = 120.0
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    return machine


def _write_machine_config(tmp_path: Path) -> Path:
    config_path = tmp_path / "machine_config.json"
    _machine_with_pen().save_json(config_path)
    return config_path
