from __future__ import annotations

import pytest

from plotter_vision.config import AxisConfig, MachineConfig


def test_default_axis_homes_at_max_and_zeros_at_opposite_min() -> None:
    axis = AxisConfig(travel_mm=533.4, homing_switch_end="max", logical_zero_end="min")

    assert axis.logical_to_machine(0.0) == pytest.approx(-533.4)
    assert axis.logical_to_machine(266.7) == pytest.approx(-266.7)
    assert axis.logical_to_machine(533.4) == pytest.approx(0.0)


def test_axis_can_round_trip_machine_and_logical_coordinates() -> None:
    axis = AxisConfig(travel_mm=215.9, homing_switch_end="max", logical_zero_end="min")

    logical = axis.machine_to_logical(-107.95)

    assert logical == pytest.approx(107.95)
    assert axis.logical_to_machine(logical) == pytest.approx(-107.95)


def test_machine_config_sets_logical_workspace_from_axis_travel() -> None:
    machine = MachineConfig()

    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)

    assert machine.workspace.x_min == 0.0
    assert machine.workspace.x_max == 533.4
    assert machine.workspace.y_min == 0.0
    assert machine.workspace.y_max == 215.9
    assert machine.logical_center_mm() == pytest.approx((266.7, 107.95))
    assert machine.logical_to_machine(x_mm=266.7, y_mm=107.95) == pytest.approx(
        (-266.7, -107.95)
    )
