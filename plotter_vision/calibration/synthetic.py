from __future__ import annotations

import random

from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    MachinePointMM,
    PaperPointNorm,
    VisionCalibrationObservation,
)
from plotter_vision.config import MachineConfig


def synthetic_observations(
    *,
    machine: MachineConfig,
    logical_points: list[LogicalPointMM],
    command_id: str = "synthetic-calibration",
    noise_norm: float = 0.0,
    seed: int = 7,
) -> list[VisionCalibrationObservation]:
    rng = random.Random(seed)
    observations: list[VisionCalibrationObservation] = []
    for index, logical in enumerate(logical_points):
        machine_x, machine_y = machine.logical_to_machine(x_mm=logical.x, y_mm=logical.y)
        observed = _synthetic_camera_point(
            logical=logical,
            machine=machine,
            noise_norm=noise_norm,
            rng=rng,
        )
        observations.append(
            VisionCalibrationObservation(
                command_id=command_id,
                point_id=f"P{index:02d}",
                observation_source="synthetic",
                expected_logical_mm=logical,
                expected_paper_norm=PaperPointNorm(
                    x=logical.x / machine.axes.x.travel_mm,
                    y=logical.y / machine.axes.y.travel_mm,
                ),
                commanded_machine_mm=MachinePointMM(x=machine_x, y=machine_y),
                reported_machine_mm=MachinePointMM(x=machine_x, y=machine_y),
                observed_norm=observed,
                observed_paper_norm=PaperPointNorm(
                    x=logical.x / machine.axes.x.travel_mm,
                    y=logical.y / machine.axes.y.travel_mm,
                ),
                strength=1.0,
            )
        )
    return observations


def _synthetic_camera_point(
    *,
    logical: LogicalPointMM,
    machine: MachineConfig,
    noise_norm: float,
    rng: random.Random,
) -> CameraPointNorm:
    x_unit = logical.x / machine.axes.x.travel_mm
    y_unit = logical.y / machine.axes.y.travel_mm

    # Mildly rotated and skewed camera framing, with margins inside the normalized image.
    x = 0.12 + 0.72 * x_unit + 0.045 * y_unit
    y = 0.18 + 0.035 * x_unit + 0.62 * y_unit
    if noise_norm:
        x += rng.uniform(-noise_norm, noise_norm)
        y += rng.uniform(-noise_norm, noise_norm)
    return CameraPointNorm(x=x, y=y)
