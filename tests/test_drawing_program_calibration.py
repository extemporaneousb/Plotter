from __future__ import annotations

from plotter_vision.bridge.planner import PolygonDrawRequest, build_polygon_draw_plan
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.drawing import (
    DrawingFrameMM,
    build_polygon_polylines,
    build_rich_drawing_calibration_program,
)


def test_rich_calibration_program_lowers_shapes_with_stable_ids() -> None:
    frame = _calibration_frame()
    program = build_rich_drawing_calibration_program()

    polylines = build_polygon_polylines(program=program, frame=frame)

    assert all(polyline.primitive_id for polyline in polylines)
    assert all(polyline.stroke_id for polyline in polylines)
    assert all(polyline.semantic_role for polyline in polylines)
    assert {polyline.primitive_id for polyline in polylines} >= {
        "cal.mark.center",
        "cal.grid.horizontal_mid",
        "cal.rectangle.outer",
        "cal.circle.left",
        "cal.arc.clockwise",
        "cal.repeat.forward",
        "cal.repeat.reverse",
    }
    assert {polyline.semantic_role for polyline in polylines} >= {
        "center_cross_mark",
        "grid_cross_axis",
        "angle_length_line_45deg",
        "nested_rectangle_inner",
        "closed_circle",
        "arc_clockwise",
        "opposite_direction_repeat_forward",
        "opposite_direction_repeat_reverse",
    }

    center_mark_strokes = [
        polyline
        for polyline in polylines
        if polyline.primitive_id == "cal.mark.center"
    ]
    circle = next(polyline for polyline in polylines if polyline.primitive_id == "cal.circle.left")
    arc = next(polyline for polyline in polylines if polyline.primitive_id == "cal.arc.clockwise")

    assert [polyline.stroke_id for polyline in center_mark_strokes] == [
        "cal.mark.center:x",
        "cal.mark.center:y",
    ]
    assert circle.stroke_id == "cal.circle.left:circle"
    assert len(circle.points) == 33
    assert circle.points[0] == circle.points[-1]
    assert arc.stroke_id == "cal.arc.clockwise:arc"
    assert len(arc.points) == 19
    assert arc.points[0] != arc.points[-1]


def test_rich_calibration_ids_survive_planner_and_simulation() -> None:
    machine = _machine_with_pen()
    frame = _calibration_frame()
    program = build_rich_drawing_calibration_program()

    plan = build_polygon_draw_plan(
        request=PolygonDrawRequest(
            program=program,
            frame=frame,
            max_segment_mm=20.0,
            request_id="rich-calibration",
        ),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="rich-calibration",
    )

    travel_trace = [step for step in plan.planned_trace if step.action == "travel"]
    draw_trace = [step for step in plan.planned_trace if step.action == "draw"]

    assert len(travel_trace) == plan.summary.polyline_count
    assert len(draw_trace) == plan.summary.draw_segment_count
    assert len(plan.simulation.drawn_segments) == plan.summary.draw_segment_count
    assert len(plan.planned_trace) == plan.summary.polyline_count + plan.summary.draw_segment_count
    assert any(step.primitive_id == "cal.circle.left" for step in draw_trace)
    assert any(step.primitive_id == "cal.arc.clockwise" for step in draw_trace)

    simulated_identity = [
        (segment.primitive_id, segment.stroke_id, segment.semantic_role)
        for segment in plan.simulation.drawn_segments
    ]
    trace_identity = [
        (step.primitive_id, step.stroke_id, step.semantic_role)
        for step in draw_trace
    ]

    assert simulated_identity == trace_identity
    assert all(segment.primitive_id for segment in plan.simulation.drawn_segments)
    assert all(segment.stroke_id for segment in plan.simulation.drawn_segments)
    assert all(segment.semantic_role for segment in plan.simulation.drawn_segments)
    forward_roles = [
        segment.semantic_role
        for segment in plan.simulation.drawn_segments
        if segment.primitive_id == "cal.repeat.forward"
    ]
    reverse_roles = [
        segment.semantic_role
        for segment in plan.simulation.drawn_segments
        if segment.primitive_id == "cal.repeat.reverse"
    ]

    assert forward_roles
    assert reverse_roles
    assert set(forward_roles) == {"opposite_direction_repeat_forward"}
    assert set(reverse_roles) == {"opposite_direction_repeat_reverse"}
    assert [
        segment.stroke_id
        for segment in plan.simulation.preview_segments
        if segment.primitive_id == "cal.circle.left"
    ]


def _calibration_frame() -> DrawingFrameMM:
    return DrawingFrameMM(origin_x_mm=20.0, origin_y_mm=15.0, width_mm=200.0, height_mm=150.0)


def _machine_with_pen() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=240.0, y_travel_mm=180.0)
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    return machine
