from __future__ import annotations

import pytest

from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.machine.safety import (
    MotionSafetyError,
    validate_calibration_line_request,
    validate_shape_execution_request,
    validate_jog_request,
    validate_polygon_draw_request,
    validate_projected_workspace_motion,
    validate_workspace_point,
)
from plotter_vision.motion.gcode import (
    build_parallel_line_motion_commands,
    build_relative_jog_commands,
)


def test_jog_preview_is_allowed_without_arming() -> None:
    axis = validate_jog_request(
        axis="x",
        distance_mm=25.0,
        feed_mm_min=60,
        machine=MachineConfig(),
        safety=SafetyState(dry_run=True, armed_motion=False),
    )

    assert axis == "X"


def test_real_jog_requires_motion_arm() -> None:
    with pytest.raises(MotionSafetyError, match="armed_motion"):
        validate_jog_request(
            axis="X",
            distance_mm=1.0,
            feed_mm_min=60,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=False, armed_motion=False),
        )


@pytest.mark.parametrize(
    ("axis", "distance", "feed", "message"),
    [
        ("Z", 1.0, 60, "Only X and Y"),
        ("X", 0.0, 60, "non-zero"),
        ("X", 60.0, 60, "exceeds max_jog"),
        ("X", 1.0, 1201, "exceeds max_feed"),
    ],
)
def test_jog_rejects_unsafe_parameters(
    axis: str,
    distance: float,
    feed: float,
    message: str,
) -> None:
    with pytest.raises(MotionSafetyError, match=message):
        validate_jog_request(
            axis=axis,
            distance_mm=distance,
            feed_mm_min=feed,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=True, armed_motion=False),
        )


def test_relative_return_to_start_gcode() -> None:
    commands = build_relative_jog_commands(
        axis="X",
        distance_mm=1.0,
        feed_mm_min=60,
        return_to_start=True,
    )

    assert commands == [
        "G21",
        "G91",
        "G94",
        "G1 F60",
        "G1 X1",
        "G4 P0.05",
        "G1 X-1",
        "G4 P0.05",
        "G90",
    ]


def test_relative_one_way_measurement_gcode() -> None:
    commands = build_relative_jog_commands(
        axis="Y",
        distance_mm=1.0,
        feed_mm_min=60,
        return_to_start=False,
    )

    assert commands == [
        "G21",
        "G91",
        "G94",
        "G1 F60",
        "G1 Y1",
        "G90",
    ]


def test_calibration_line_allows_longer_distance_than_jog() -> None:
    axis = validate_calibration_line_request(
        axis="X",
        distance_mm=20.0,
        feed_mm_min=120,
        machine=MachineConfig(),
        safety=SafetyState(dry_run=True, armed_motion=False),
    )

    assert axis == "X"


def test_calibration_line_rejects_too_long_distance() -> None:
    with pytest.raises(MotionSafetyError, match="max_calibration_line"):
        validate_calibration_line_request(
            axis="X",
            distance_mm=60.0,
            feed_mm_min=120,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=True, armed_motion=False),
        )


def test_real_calibration_line_requires_motion_arm() -> None:
    with pytest.raises(MotionSafetyError, match="armed_motion"):
        validate_calibration_line_request(
            axis="Y",
            distance_mm=20.0,
            feed_mm_min=120,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=False, armed_motion=False),
        )


def test_shape_shape_preview_is_allowed_without_arming() -> None:
    validate_shape_execution_request(
        side_mm=20.0,
        draw_feed_mm_min=180,
        travel_feed_mm_min=500,
        machine=MachineConfig(),
        safety=SafetyState(dry_run=True, armed_motion=False),
    )


def test_real_shape_shape_requires_motion_arm() -> None:
    with pytest.raises(MotionSafetyError, match="armed_motion"):
        validate_shape_execution_request(
            side_mm=20.0,
            draw_feed_mm_min=180,
            travel_feed_mm_min=500,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=False, armed_motion=False),
        )


def test_shape_shape_rejects_too_large_side() -> None:
    with pytest.raises(MotionSafetyError, match="max_calibration_line"):
        validate_shape_execution_request(
            side_mm=60.0,
            draw_feed_mm_min=180,
            travel_feed_mm_min=500,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=True),
        )


def test_polygon_draw_preview_allows_bounded_segments_without_arming() -> None:
    machine = MachineConfig()

    validate_polygon_draw_request(
        draw_feed_mm_min=180.0,
        travel_feed_mm_min=500.0,
        max_segment_mm=25.0,
        machine=machine,
        safety=SafetyState(dry_run=True, armed_motion=False),
    )


def test_polygon_draw_rejects_segments_above_calibration_motion_limit() -> None:
    machine = MachineConfig()

    with pytest.raises(MotionSafetyError, match="max_calibration_line"):
        validate_polygon_draw_request(
            draw_feed_mm_min=180.0,
            travel_feed_mm_min=500.0,
            max_segment_mm=60.0,
            machine=machine,
            safety=SafetyState(dry_run=True, armed_motion=False),
        )


def test_real_polygon_draw_requires_motion_arm() -> None:
    with pytest.raises(MotionSafetyError, match="armed_motion"):
        validate_polygon_draw_request(
            draw_feed_mm_min=180.0,
            travel_feed_mm_min=500.0,
            max_segment_mm=25.0,
            machine=MachineConfig(),
            safety=SafetyState(dry_run=False, armed_motion=False),
        )


def test_workspace_point_rejects_out_of_bounds_coordinates() -> None:
    with pytest.raises(MotionSafetyError, match="outside workspace"):
        validate_workspace_point(x_mm=301.0, y_mm=150.0, machine=MachineConfig())


def test_projected_workspace_motion_rejects_accumulated_relative_x_overrun() -> None:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)

    with pytest.raises(MotionSafetyError, match="Projected X position 557\\.900"):
        validate_projected_workspace_motion(
            start_mpos_mm=(457.9, -88.4, 0.0),
            commands=[
                "G21",
                "G91",
                "G1 F300",
                "G1 X50",
                "G90",
                "G91",
                "G1 F300",
                "G1 X50",
                "G90",
            ],
            machine=machine,
        )


def test_projected_workspace_motion_only_checks_commanded_axes() -> None:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)

    validate_projected_workspace_motion(
        start_mpos_mm=(457.9, -88.4, 0.0),
        commands=["G91", "G1 X25", "G90"],
        machine=machine,
    )


def test_parallel_x_line_motion_commands_space_on_y() -> None:
    commands = build_parallel_line_motion_commands(
        line_axis="X",
        line_distance_mm=10,
        spacing_mm=5,
        count=3,
        draw_feed_mm_min=120,
        travel_feed_mm_min=500,
    )

    assert commands == [
        ["G1 F120", "G1 X10", "G1 F500", "G1 X-10", "G1 Y5"],
        ["G1 F120", "G1 X10", "G1 F500", "G1 X-10", "G1 Y5"],
        ["G1 F120", "G1 X10"],
    ]


def test_parallel_y_line_motion_commands_space_on_x() -> None:
    commands = build_parallel_line_motion_commands(
        line_axis="Y",
        line_distance_mm=10,
        spacing_mm=5,
        count=3,
        draw_feed_mm_min=120,
        travel_feed_mm_min=500,
    )

    assert commands == [
        ["G1 F120", "G1 Y10", "G1 F500", "G1 Y-10", "G1 X5"],
        ["G1 F120", "G1 Y10", "G1 F500", "G1 Y-10", "G1 X5"],
        ["G1 F120", "G1 Y10"],
    ]
