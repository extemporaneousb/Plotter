from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from plotter_vision.controller.base import utc_now_iso


class LogicalPointMM(BaseModel):
    x: float
    y: float

    @field_validator("x", "y")
    @classmethod
    def _validate_finite(cls, value: float) -> float:
        return _finite(value, label="logical point")


class MachinePointMM(BaseModel):
    x: float
    y: float

    @field_validator("x", "y")
    @classmethod
    def _validate_finite(cls, value: float) -> float:
        return _finite(value, label="machine point")


class CameraPointNorm(BaseModel):
    x: float
    y: float

    @field_validator("x", "y")
    @classmethod
    def _validate_norm(cls, value: float) -> float:
        value = _finite(value, label="camera point")
        if value < -1e-9 or value > 1.0 + 1e-9:
            raise ValueError("camera normalized coordinates must be in [0, 1].")
        return value


class PaperPointNorm(BaseModel):
    x: float
    y: float

    @field_validator("x", "y")
    @classmethod
    def _validate_norm(cls, value: float) -> float:
        value = _finite(value, label="paper point")
        if value < -1e-9 or value > 1.0 + 1e-9:
            raise ValueError("paper normalized coordinates must be in [0, 1].")
        return value


class VisionCalibrationObservation(BaseModel):
    schema_version: int = 1
    observation_id: str = Field(default_factory=lambda: f"obs-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    command_id: str
    point_id: str
    role: str = "pen_tip_waypoint"
    observation_source: Literal[
        "manual_click",
        "camera_detection",
        "operator_confirmed",
        "synthetic",
    ] = "manual_click"
    expected_logical_mm: LogicalPointMM
    expected_paper_norm: PaperPointNorm | None = None
    commanded_machine_mm: MachinePointMM
    reported_machine_mm: MachinePointMM | None = None
    observed_norm: CameraPointNorm
    observed_paper_norm: PaperPointNorm | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    paper_registration_id: str | None = None
    strength: float = 1.0

    @field_validator("strength")
    @classmethod
    def _validate_strength(cls, value: float) -> float:
        value = _finite(value, label="observation strength")
        if value <= 0:
            raise ValueError("observation strength must be positive.")
        return value


class AffineCameraTransform(BaseModel):
    type: Literal["affine_2d"] = "affine_2d"
    logical_to_camera_x: tuple[float, float, float]
    logical_to_camera_y: tuple[float, float, float]

    def map_logical(self, point: LogicalPointMM) -> CameraPointNorm:
        ax, bx, cx = self.logical_to_camera_x
        ay, by, cy = self.logical_to_camera_y
        return CameraPointNorm(
            x=ax * point.x + bx * point.y + cx,
            y=ay * point.x + by * point.y + cy,
        )


class VisionCalibrationResidual(BaseModel):
    point_id: str
    observation_id: str
    residual_norm: float
    dx_norm: float
    dy_norm: float
    strength: float
    expected_logical_mm: LogicalPointMM
    observed_norm: CameraPointNorm
    predicted_norm: CameraPointNorm


class VisionMachineModel(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["vision_machine_model"] = "vision_machine_model"
    model_id: str = Field(default_factory=lambda: f"model-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    method: Literal["affine_logical_to_camera"] = "affine_logical_to_camera"
    input_space: Literal["logical_plotter_mm"] = "logical_plotter_mm"
    output_space: Literal["camera_norm"] = "camera_norm"
    camera_id: str | None = None
    camera_name: str | None = None
    paper_registration_id: str | None = None
    observation_count: int = 0
    transform: AffineCameraTransform | None = None
    rms_error_norm: float | None = None
    max_error_norm: float | None = None
    drawing_surface_norm: dict[str, float] | None = None
    residuals: list[VisionCalibrationResidual] = Field(default_factory=list)
    observations: list[VisionCalibrationObservation] = Field(default_factory=list)
    note: str = (
        "Logical plotter coordinates use the corner opposite homing switches as X0 Y0; "
        "controller machine coordinates are recorded separately."
    )

    def add_observation(self, observation: VisionCalibrationObservation) -> None:
        self.observations.append(observation)
        self.updated_at = utc_now_iso()
        self.observation_count = len(self.observations)

    def solve(self) -> VisionMachineModel:
        _validate_affine_observations(self.observations)

        rows = [
            (
                observation.expected_logical_mm.x,
                observation.expected_logical_mm.y,
                1.0,
            )
            for observation in self.observations
        ]
        observed_x = [observation.observed_norm.x for observation in self.observations]
        observed_y = [observation.observed_norm.y for observation in self.observations]
        transform = AffineCameraTransform(
            logical_to_camera_x=tuple(_least_squares_3(rows, observed_x)),  # type: ignore[arg-type]
            logical_to_camera_y=tuple(_least_squares_3(rows, observed_y)),  # type: ignore[arg-type]
        )

        residuals: list[float] = []
        residual_records: list[VisionCalibrationResidual] = []
        for observation in self.observations:
            predicted = transform.map_logical(observation.expected_logical_mm)
            dx = predicted.x - observation.observed_norm.x
            dy = predicted.y - observation.observed_norm.y
            error = math.hypot(dx, dy)
            residuals.append(error)
            residual_records.append(
                VisionCalibrationResidual(
                    point_id=observation.point_id,
                    observation_id=observation.observation_id,
                    residual_norm=error,
                    dx_norm=dx,
                    dy_norm=dy,
                    strength=observation.strength,
                    expected_logical_mm=observation.expected_logical_mm,
                    observed_norm=observation.observed_norm,
                    predicted_norm=predicted,
                )
            )

        self.transform = transform
        self.rms_error_norm = (sum(error * error for error in residuals) / len(residuals)) ** 0.5
        self.max_error_norm = max(residuals)
        self.residuals = residual_records
        self.drawing_surface_norm = _observed_bounds(
            [observation.observed_norm for observation in self.observations]
        )
        self.camera_id = _common_optional_value(
            [observation.camera_id for observation in self.observations]
        )
        self.camera_name = _common_optional_value(
            [observation.camera_name for observation in self.observations]
        )
        self.paper_registration_id = _common_optional_value(
            [observation.paper_registration_id for observation in self.observations]
        )
        self.updated_at = utc_now_iso()
        self.observation_count = len(self.observations)
        return self

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> VisionMachineModel:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))


def _validate_affine_observations(observations: list[VisionCalibrationObservation]) -> None:
    if len(observations) < 3:
        raise ValueError("At least three observations are required to solve an affine model.")

    logical_points = [
        (observation.expected_logical_mm.x, observation.expected_logical_mm.y)
        for observation in observations
    ]
    observed_points = [
        (observation.observed_norm.x, observation.observed_norm.y)
        for observation in observations
    ]
    if _max_triangle_area(logical_points) < 1e-6:
        raise ValueError(
            "Calibration observations are degenerate; logical points do not span an area."
        )
    if _max_triangle_area(observed_points) < 1e-8:
        raise ValueError(
            "Calibration observations are degenerate; observed camera points do not span an area."
        )


def _least_squares_3(rows: list[tuple[float, float, float]], values: list[float]) -> list[float]:
    if len(rows) != len(values):
        raise ValueError("rows and values must have the same length.")

    normal = [[0.0, 0.0, 0.0] for _ in range(3)]
    rhs = [0.0, 0.0, 0.0]
    for row, value in zip(rows, values):
        for i in range(3):
            rhs[i] += row[i] * value
            for j in range(3):
                normal[i][j] += row[i] * row[j]

    return _solve_3x3(normal, rhs)


def _solve_3x3(matrix: list[list[float]], rhs: list[float]) -> list[float]:
    augmented = [row[:] + [value] for row, value in zip(matrix, rhs)]

    for column in range(3):
        pivot_row = max(range(column, 3), key=lambda row: abs(augmented[row][column]))
        if abs(augmented[pivot_row][column]) < 1e-12:
            raise ValueError("Calibration observations are degenerate; affine solve is singular.")
        augmented[column], augmented[pivot_row] = augmented[pivot_row], augmented[column]

        pivot = augmented[column][column]
        for item in range(column, 4):
            augmented[column][item] /= pivot

        for row in range(3):
            if row == column:
                continue
            factor = augmented[row][column]
            for item in range(column, 4):
                augmented[row][item] -= factor * augmented[column][item]

    return [augmented[row][3] for row in range(3)]


def _observed_bounds(points: list[CameraPointNorm]) -> dict[str, float]:
    min_x = min(point.x for point in points)
    max_x = max(point.x for point in points)
    min_y = min(point.y for point in points)
    max_y = max(point.y for point in points)
    return {
        "x": min_x,
        "y": min_y,
        "w": max_x - min_x,
        "h": max_y - min_y,
    }


def _max_triangle_area(points: list[tuple[float, float]]) -> float:
    max_area = 0.0
    for i in range(len(points)):
        for j in range(i + 1, len(points)):
            for k in range(j + 1, len(points)):
                max_area = max(max_area, abs(_triangle_area(points[i], points[j], points[k])))
    return max_area


def _triangle_area(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
) -> float:
    return ((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])) / 2.0


def _common_optional_value(values: list[str | None]) -> str | None:
    present = [value for value in values if value]
    if not present:
        return None
    first = present[0]
    if all(value == first for value in present):
        return first
    return None


def _finite(value: float, *, label: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{label} coordinates must be finite.")
    return value
