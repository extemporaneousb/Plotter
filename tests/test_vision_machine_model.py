from __future__ import annotations

import pytest

from plotter_vision.calibration.session import build_calibration_session
from plotter_vision.calibration.synthetic import synthetic_observations
from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    MachinePointMM,
    VisionCalibrationObservation,
    VisionMachineModel,
)
from plotter_vision.config import MachineConfig


def test_vision_model_solves_synthetic_affine_transform() -> None:
    machine = _machine()
    session = build_calibration_session(machine=machine, include_homing=True)
    observations = synthetic_observations(
        machine=machine,
        logical_points=[waypoint.logical_mm for waypoint in session.waypoints],
        noise_norm=0.0,
    )
    model = VisionMachineModel()

    for observation in observations:
        model.add_observation(observation)
    model.solve()

    assert model.transform is not None
    assert model.schema_version == 1
    assert len(model.residuals) == len(observations)
    assert model.rms_error_norm == pytest.approx(0.0, abs=1e-12)
    assert model.max_error_norm == pytest.approx(0.0, abs=1e-12)
    predicted = model.transform.map_logical(LogicalPointMM(x=266.7, y=107.95))
    assert predicted.x == pytest.approx(0.5025, abs=0.001)
    assert predicted.y == pytest.approx(0.5075, abs=0.001)
    assert model.drawing_surface_norm is not None
    assert model.drawing_surface_norm["w"] > 0.60
    assert model.drawing_surface_norm["h"] > 0.45


def test_vision_model_requires_three_observations() -> None:
    model = VisionMachineModel()
    for index in range(2):
        model.add_observation(
            VisionCalibrationObservation(
                command_id="cmd",
                point_id=f"P{index}",
                expected_logical_mm=LogicalPointMM(x=float(index), y=float(index)),
                commanded_machine_mm=MachinePointMM(x=-float(index), y=-float(index)),
                observed_norm=CameraPointNorm(x=0.1 * index, y=0.1 * index),
            )
        )

    with pytest.raises(ValueError, match="At least three"):
        model.solve()


def test_vision_model_rejects_degenerate_observations() -> None:
    model = VisionMachineModel()
    for index in range(3):
        model.add_observation(
            VisionCalibrationObservation(
                command_id="cmd",
                point_id=f"P{index}",
                expected_logical_mm=LogicalPointMM(x=float(index), y=0.0),
                commanded_machine_mm=MachinePointMM(x=-float(index), y=0.0),
                observed_norm=CameraPointNorm(x=0.1 + 0.1 * index, y=0.2),
            )
        )

    with pytest.raises(ValueError, match="degenerate"):
        model.solve()


def test_calibration_session_plans_logical_waypoints_and_negative_machine_moves() -> None:
    machine = _machine()
    session = build_calibration_session(machine=machine, margin_mm=25.0)

    assert session.planned_commands[0] == "G21"
    assert "$H" not in session.planned_commands
    assert "G53 G1 X-266.7 Y-107.95" in session.planned_commands
    assert "G53 G1 X-508.4 Y-190.9" in session.planned_commands
    assert session.waypoints[0].logical_mm == LogicalPointMM(x=266.7, y=107.95)
    assert session.waypoints[0].paper_norm is not None
    assert session.waypoints[0].machine_mm == MachinePointMM(x=-266.7, y=-107.95)


def test_calibration_session_homing_is_explicit() -> None:
    session = build_calibration_session(machine=_machine(), margin_mm=25.0, include_homing=True)

    assert session.planned_commands[0] == "$H"


def test_calibration_session_can_resume_from_observations() -> None:
    machine = _machine()
    session = build_calibration_session(machine=machine, include_homing=False)
    observations = synthetic_observations(
        machine=machine,
        logical_points=[waypoint.logical_mm for waypoint in session.waypoints[:3]],
        noise_norm=0.0,
    )

    for observation in observations[:2]:
        session.add_observation(observation)

    assert session.status == "awaiting_observations"
    assert session.observed_count == 2
    assert session.model.transform is None

    session.add_observation(observations[2])

    assert session.status == "solved"
    assert session.observed_count == 3
    assert session.model.transform is not None


def _machine() -> MachineConfig:
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    return machine
