from __future__ import annotations

import pytest

from plotter_vision.calibration.vision_model import LogicalPointMM
from plotter_vision.config import MachineConfig
from plotter_vision.drawing import (
    DrawingFrameMM,
    PaperDrawingProgram,
    PaperPointNorm,
    PointMarkPrimitive,
    PolylinePrimitive,
    PolygonPrimitive,
    SimpleShapePrimitive,
    build_polygon_polylines,
    validate_polylines_in_workspace,
)
from plotter_vision.machine.safety import MotionSafetyError


def test_paper_point_maps_into_logical_drawing_frame() -> None:
    frame = DrawingFrameMM(origin_x_mm=10.0, origin_y_mm=20.0, width_mm=200.0, height_mm=100.0)

    mapped = frame.map_point(PaperPointNorm(x=0.25, y=0.75))

    assert mapped.x == 60.0
    assert mapped.y == 95.0


def test_flipped_y_frame_maps_image_top_to_workspace_top() -> None:
    frame = DrawingFrameMM(
        origin_x_mm=0.0,
        origin_y_mm=0.0,
        width_mm=200.0,
        height_mm=100.0,
        flip_y=True,
    )

    mapped = frame.map_point(PaperPointNorm(x=0.5, y=0.0))

    assert mapped.x == 100.0
    assert mapped.y == 100.0


def test_shaded_polygon_expands_to_outline_and_hatch_polylines() -> None:
    program = PaperDrawingProgram(
        polygons=[
            PolygonPrimitive(
                vertices=[
                    PaperPointNorm(x=0.1, y=0.1),
                    PaperPointNorm(x=0.9, y=0.1),
                    PaperPointNorm(x=0.9, y=0.9),
                    PaperPointNorm(x=0.1, y=0.9),
                ],
                shade=0.65,
                outline=True,
                hatch_angle_deg=0.0,
            )
        ],
        min_hatch_spacing_mm=2.0,
        max_hatch_spacing_mm=10.0,
    )
    frame = DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=100.0)

    polylines = build_polygon_polylines(program=program, frame=frame)

    assert polylines[0].role == "outline"
    assert polylines[0].points[0] == polylines[0].points[-1]
    assert len([polyline for polyline in polylines if polyline.role == "hatch"]) >= 10


def test_darker_shade_produces_more_hatch_segments() -> None:
    frame = DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=100.0)

    light = _square_program(shade=0.2)
    dark = _square_program(shade=0.9)

    light_count = len(build_polygon_polylines(program=light, frame=frame))
    dark_count = len(build_polygon_polylines(program=dark, frame=frame))

    assert dark_count > light_count


def test_polygon_coordinates_are_limited_to_registered_paper_space() -> None:
    with pytest.raises(ValueError, match=r"\[0, 1\]"):
        PaperPointNorm(x=1.2, y=0.5)


def test_planned_polylines_validate_against_machine_workspace() -> None:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=50.0, y_travel_mm=50.0)
    frame = DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=100.0)
    polylines = build_polygon_polylines(program=_square_program(shade=0.0), frame=frame)

    with pytest.raises(MotionSafetyError, match="outside workspace"):
        validate_polylines_in_workspace(polylines=polylines, machine=machine)


def test_point_mark_maps_to_cross_mark_polylines() -> None:
    frame = DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=50.0)
    program = PaperDrawingProgram(
        point_marks=[
            PointMarkPrimitive(center=PaperPointNorm(x=0.5, y=0.5), mark_size_mm=10.0)
        ]
    )

    polylines = build_polygon_polylines(program=program, frame=frame)

    assert [polyline.role for polyline in polylines] == ["mark", "mark"]
    assert polylines[0].points[0] == LogicalPointMM(x=45.0, y=25.0)
    assert polylines[0].points[1] == LogicalPointMM(x=55.0, y=25.0)
    assert polylines[1].points[0] == LogicalPointMM(x=50.0, y=20.0)
    assert polylines[1].points[1] == LogicalPointMM(x=50.0, y=30.0)


def test_polyline_contour_maps_without_hatching() -> None:
    frame = DrawingFrameMM(origin_x_mm=10.0, origin_y_mm=20.0, width_mm=100.0, height_mm=50.0)
    program = PaperDrawingProgram(
        polylines=[
            PolylinePrimitive(
                role="contour",
                closed=True,
                points=[
                    PaperPointNorm(x=0.1, y=0.2),
                    PaperPointNorm(x=0.3, y=0.2),
                    PaperPointNorm(x=0.3, y=0.4),
                ],
            )
        ]
    )

    polylines = build_polygon_polylines(program=program, frame=frame)

    assert len(polylines) == 1
    assert polylines[0].role == "contour"
    assert polylines[0].points[0] == LogicalPointMM(x=20.0, y=30.0)
    assert polylines[0].points[-1] == polylines[0].points[0]


def test_simple_triangle_and_square_primitives_make_outline_segments() -> None:
    frame = DrawingFrameMM(origin_x_mm=0.0, origin_y_mm=0.0, width_mm=100.0, height_mm=100.0)
    triangle = build_polygon_polylines(
        program=PaperDrawingProgram(
            simple_shapes=[
                SimpleShapePrimitive(
                    kind="triangle",
                    center=PaperPointNorm(x=0.5, y=0.5),
                    size_norm=0.2,
                )
            ]
        ),
        frame=frame,
    )
    square = build_polygon_polylines(
        program=PaperDrawingProgram(
            simple_shapes=[
                SimpleShapePrimitive(
                    kind="square",
                    center=PaperPointNorm(x=0.5, y=0.5),
                    size_norm=0.2,
                )
            ]
        ),
        frame=frame,
    )

    assert triangle[0].role == "outline"
    assert len(triangle[0].points) == 4
    assert square[0].role == "outline"
    assert len(square[0].points) == 5


def _square_program(*, shade: float) -> PaperDrawingProgram:
    return PaperDrawingProgram(
        polygons=[
            PolygonPrimitive(
                vertices=[
                    PaperPointNorm(x=0.1, y=0.1),
                    PaperPointNorm(x=0.9, y=0.1),
                    PaperPointNorm(x=0.9, y=0.9),
                    PaperPointNorm(x=0.1, y=0.9),
                ],
                shade=shade,
                outline=True,
                hatch_angle_deg=0.0,
            )
        ]
    )
