from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, Field

from plotter_vision.controller.base import utc_now_iso


class LogicalPointMM(BaseModel):
    x: float
    y: float


class MachinePointMM(BaseModel):
    x: float
    y: float


class CameraPointNorm(BaseModel):
    x: float
    y: float


class VisionCalibrationObservation(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    command_id: str
    point_id: str
    role: str = "pen_tip_waypoint"
    expected_logical_mm: LogicalPointMM
    commanded_machine_mm: MachinePointMM
    reported_machine_mm: MachinePointMM | None = None
    observed_norm: CameraPointNorm
    camera_id: str | None = None
    camera_name: str | None = None
    paper_registration_id: str | None = None
    strength: float = 1.0


class AffineCameraTransform(BaseModel):
    logical_to_camera_x: tuple[float, float, float]
    logical_to_camera_y: tuple[float, float, float]

    def map_logical(self, point: LogicalPointMM) -> CameraPointNorm:
        ax, bx, cx = self.logical_to_camera_x
        ay, by, cy = self.logical_to_camera_y
        return CameraPointNorm(
            x=ax * point.x + bx * point.y + cx,
            y=ay * point.x + by * point.y + cy,
        )


class VisionMachineModel(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    observation_count: int = 0
    transform: AffineCameraTransform | None = None
    rms_error_norm: float | None = None
    max_error_norm: float | None = None
    drawing_surface_norm: dict[str, float] | None = None
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
        if len(self.observations) < 3:
            raise ValueError("At least three observations are required to solve an affine model.")

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
        for observation in self.observations:
            predicted = transform.map_logical(observation.expected_logical_mm)
            dx = predicted.x - observation.observed_norm.x
            dy = predicted.y - observation.observed_norm.y
            residuals.append((dx * dx + dy * dy) ** 0.5)

        self.transform = transform
        self.rms_error_norm = (sum(error * error for error in residuals) / len(residuals)) ** 0.5
        self.max_error_norm = max(residuals)
        self.drawing_surface_norm = _observed_bounds(
            [observation.observed_norm for observation in self.observations]
        )
        self.updated_at = utc_now_iso()
        self.observation_count = len(self.observations)
        return self

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


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
