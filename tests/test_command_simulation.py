from __future__ import annotations

from plotter_vision.bridge.planner import ShapeExecutionRequest, build_shape_execution_plan
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.motion.simulator import simulate_plotter_commands


def test_shape_square_command_stream_simulates_closed_shape() -> None:
    machine = _machine_with_pen()
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(pattern="square", side_mm=20.0, request_id="sim-square"),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="sim-square",
    )

    assert plan.simulation.status == "ok"
    assert len(plan.simulation.drawn_segments) == 4
    assert len(plan.simulation.preview_segments) == 4
    assert plan.simulation.drawn_length_mm == 80.0
    assert plan.evaluation.status == "passed"


def test_shape_triangle_command_stream_simulates_expected_angles() -> None:
    machine = _machine_with_pen()
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(pattern="triangle", side_mm=30.0, request_id="sim-triangle"),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="sim-triangle",
    )

    angle_check = next(
        check
        for check in plan.evaluation.checks
        if check.name == "max_corner_angle_error_deg"
    )

    assert len(plan.simulation.drawn_segments) == 3
    assert plan.evaluation.status == "passed"
    assert angle_check.actual < 0.001


def test_shape_triangle_can_be_positioned_away_from_workspace_center() -> None:
    machine = _machine_with_pen()
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(
            pattern="triangle",
            side_mm=30.0,
            center_x_mm=320.0,
            center_y_mm=120.0,
            request_id="sim-positioned-triangle",
        ),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="sim-positioned-triangle",
    )

    first_segment = plan.simulation.preview_segments[0]

    assert plan.evaluation.status == "passed"
    assert first_segment.start_norm[0] > 0.5
    assert first_segment.start_norm[1] > 0.5


def test_shape_without_pen_commands_fails_geometry_gate() -> None:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    plan = build_shape_execution_plan(
        request=ShapeExecutionRequest(pattern="square", side_mm=20.0, request_id="sim-no-pen"),
        machine=machine,
        safety=SafetyState(dry_run=True),
        command_id="sim-no-pen",
    )

    assert plan.simulation.status == "ok"
    assert plan.simulation.drawn_segments == []
    assert plan.evaluation.status == "failed"
    assert "Expected 4 drawn edges" in plan.evaluation.message


def test_relative_motion_before_known_position_is_not_simulatable() -> None:
    machine = _machine_with_pen()
    simulation = simulate_plotter_commands(
        ["G91", "M3 S720", "G1 X10"],
        machine=machine,
        pen_up_command=machine.pen.up_command,
        pen_down_command=machine.pen.down_command,
    )

    assert simulation.status == "failed"
    assert "Relative motion cannot start from an unknown position" in simulation.errors[0]


def test_dwell_command_does_not_break_simulation() -> None:
    machine = _machine_with_pen()
    simulation = simulate_plotter_commands(
        ["G90", "G1 X10 Y10", "M3 S720", "G4 P0.3", "G1 X20 Y10"],
        machine=machine,
        pen_up_command=machine.pen.up_command,
        pen_down_command=machine.pen.down_command,
    )

    assert simulation.status == "ok"
    assert len(simulation.drawn_segments) == 1


def _machine_with_pen() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.pen.up_command = "M3 S40"
    machine.pen.down_command = "M3 S720"
    return machine
