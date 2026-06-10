from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, model_validator

from plotter_vision.calibration.vision_model import CameraPointNorm
from plotter_vision.controller.base import utc_now_iso

PaperCorner = Literal["bottom_left", "bottom_right", "top_right", "top_left"]


class PaperPointNorm(BaseModel):
    x: float
    y: float


class PaperPointMM(BaseModel):
    x: float
    y: float


class PaperSizeMM(BaseModel):
    width: float
    height: float


class PaperFiducialDetection(BaseModel):
    observed_norm: CameraPointNorm
    strength: float = 1.0
    label: str | None = None
    pixel_area: float | None = None


class PaperCornerObservation(BaseModel):
    corner: PaperCorner
    expected_paper_norm: PaperPointNorm
    observed_norm: CameraPointNorm
    strength: float = 1.0


class Homography2D(BaseModel):
    coefficients: tuple[
        float,
        float,
        float,
        float,
        float,
        float,
        float,
        float,
        float,
    ]

    def map_xy(self, x: float, y: float) -> tuple[float, float]:
        a, b, c, d, e, f, g, h, i = self.coefficients
        denominator = g * x + h * y + i
        if abs(denominator) < 1e-12:
            raise ValueError("Homography denominator is too close to zero.")
        return (
            (a * x + b * y + c) / denominator,
            (d * x + e * y + f) / denominator,
        )


class PaperFrameRegistration(BaseModel):
    registration_id: str = Field(default_factory=lambda: f"paper-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    status: Literal["locked"] = "locked"
    paper_size_mm: PaperSizeMM
    corner_observations: list[PaperCornerObservation]
    paper_to_camera: Homography2D
    camera_to_paper: Homography2D
    rms_error_norm: float
    max_error_norm: float

    @model_validator(mode="after")
    def _validate_observed_quad(self) -> PaperFrameRegistration:
        _validate_observed_corner_quad(self.corner_observations)
        return self

    def camera_norm_to_paper_norm(self, point: CameraPointNorm) -> PaperPointNorm:
        x, y = self.camera_to_paper.map_xy(point.x, point.y)
        return PaperPointNorm(x=x, y=y)

    def camera_norm_to_paper_mm(self, point: CameraPointNorm) -> PaperPointMM:
        paper = self.camera_norm_to_paper_norm(point)
        return PaperPointMM(
            x=paper.x * self.paper_size_mm.width,
            y=paper.y * self.paper_size_mm.height,
        )

    def paper_mm_to_camera_norm(self, point: PaperPointMM) -> CameraPointNorm:
        x_norm = point.x / self.paper_size_mm.width
        y_norm = point.y / self.paper_size_mm.height
        x, y = self.paper_to_camera.map_xy(x_norm, y_norm)
        return CameraPointNorm(x=x, y=y)

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


def build_paper_registration_from_red_fiducials(
    detections: list[PaperFiducialDetection],
    *,
    paper_width_mm: float,
    paper_height_mm: float,
) -> PaperFrameRegistration:
    observations = build_corner_observations_from_red_fiducials(detections)
    return build_paper_frame_registration(
        observations,
        paper_width_mm=paper_width_mm,
        paper_height_mm=paper_height_mm,
    )


def build_corner_observations_from_red_fiducials(
    detections: list[PaperFiducialDetection],
) -> list[PaperCornerObservation]:
    if len(detections) < 4:
        raise ValueError("At least four red paper fiducials are required for paper registration.")

    selected = sorted(detections, key=lambda detection: detection.strength, reverse=True)[:4]
    center_x = sum(detection.observed_norm.x for detection in selected) / 4.0
    center_y = sum(detection.observed_norm.y for detection in selected) / 4.0
    ordered = sorted(
        selected,
        key=lambda detection: math.atan2(
            detection.observed_norm.y - center_y,
            detection.observed_norm.x - center_x,
        ),
    )
    start_index = min(
        range(4),
        key=lambda index: ordered[index].observed_norm.x + ordered[index].observed_norm.y,
    )
    ordered = ordered[start_index:] + ordered[:start_index]

    corners: list[PaperCorner] = ["bottom_left", "bottom_right", "top_right", "top_left"]
    return [
        PaperCornerObservation(
            corner=corner,
            expected_paper_norm=paper_corner_norm(corner),
            observed_norm=detection.observed_norm,
            strength=detection.strength,
        )
        for corner, detection in zip(corners, ordered)
    ]


def build_paper_frame_registration(
    corner_observations: list[PaperCornerObservation],
    *,
    paper_width_mm: float,
    paper_height_mm: float,
) -> PaperFrameRegistration:
    if len(corner_observations) < 4:
        raise ValueError("At least four paper corner observations are required.")
    if paper_width_mm <= 0 or paper_height_mm <= 0:
        raise ValueError("Paper width and height must be positive.")

    corners = {observation.corner for observation in corner_observations}
    if len(corners) != len(corner_observations):
        raise ValueError("Paper corner observations must not contain duplicate corners.")

    _validate_observed_corner_quad(corner_observations)

    paper_points = [
        (observation.expected_paper_norm.x, observation.expected_paper_norm.y)
        for observation in corner_observations
    ]
    camera_points = [
        (observation.observed_norm.x, observation.observed_norm.y)
        for observation in corner_observations
    ]

    paper_to_camera = _solve_homography(paper_points, camera_points)
    camera_to_paper = _solve_homography(camera_points, paper_points)

    residuals: list[float] = []
    for observation in corner_observations:
        predicted_x, predicted_y = paper_to_camera.map_xy(
            observation.expected_paper_norm.x,
            observation.expected_paper_norm.y,
        )
        dx = predicted_x - observation.observed_norm.x
        dy = predicted_y - observation.observed_norm.y
        residuals.append((dx * dx + dy * dy) ** 0.5)

    return PaperFrameRegistration(
        paper_size_mm=PaperSizeMM(width=paper_width_mm, height=paper_height_mm),
        corner_observations=corner_observations,
        paper_to_camera=paper_to_camera,
        camera_to_paper=camera_to_paper,
        rms_error_norm=(sum(error * error for error in residuals) / len(residuals)) ** 0.5,
        max_error_norm=max(residuals),
    )


def paper_corner_norm(corner: PaperCorner) -> PaperPointNorm:
    if corner == "bottom_left":
        return PaperPointNorm(x=0.0, y=0.0)
    if corner == "bottom_right":
        return PaperPointNorm(x=1.0, y=0.0)
    if corner == "top_right":
        return PaperPointNorm(x=1.0, y=1.0)
    return PaperPointNorm(x=0.0, y=1.0)


def _validate_observed_corner_quad(corner_observations: list[PaperCornerObservation]) -> None:
    by_corner = {observation.corner: observation.observed_norm for observation in corner_observations}
    required: list[PaperCorner] = ["bottom_left", "bottom_right", "top_right", "top_left"]
    if any(corner not in by_corner for corner in required):
        return

    points = [(by_corner[corner].x, by_corner[corner].y) for corner in required]
    area = abs(_signed_area(points))
    if area < 1e-4:
        raise ValueError("Observed paper fiducials are degenerate; selected area is too small.")
    if _segments_intersect(points[0], points[1], points[2], points[3]) or _segments_intersect(
        points[1],
        points[2],
        points[3],
        points[0],
    ):
        raise ValueError(
            "Observed paper fiducials form a crossed quadrilateral. "
            "Click corners in BL, BR, TR, TL order."
        )


def _signed_area(points: list[tuple[float, float]]) -> float:
    area = 0.0
    for (x0, y0), (x1, y1) in zip(points, [*points[1:], points[0]]):
        area += x0 * y1 - x1 * y0
    return area / 2.0


def _segments_intersect(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
    d: tuple[float, float],
) -> bool:
    o1 = _orientation(a, b, c)
    o2 = _orientation(a, b, d)
    o3 = _orientation(c, d, a)
    o4 = _orientation(c, d, b)
    return o1 * o2 < 0 and o3 * o4 < 0


def _orientation(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def _solve_homography(
    source_points: list[tuple[float, float]],
    target_points: list[tuple[float, float]],
) -> Homography2D:
    if len(source_points) != len(target_points):
        raise ValueError("source_points and target_points must have the same length.")
    if len(source_points) < 4:
        raise ValueError("At least four point pairs are required to solve a homography.")

    rows: list[list[float]] = []
    values: list[float] = []
    for (source_x, source_y), (target_x, target_y) in zip(source_points, target_points):
        rows.append(
            [
                source_x,
                source_y,
                1.0,
                0.0,
                0.0,
                0.0,
                -target_x * source_x,
                -target_x * source_y,
            ]
        )
        values.append(target_x)
        rows.append(
            [
                0.0,
                0.0,
                0.0,
                source_x,
                source_y,
                1.0,
                -target_y * source_x,
                -target_y * source_y,
            ]
        )
        values.append(target_y)

    solved = _least_squares(rows, values)
    return Homography2D(
        coefficients=(
            solved[0],
            solved[1],
            solved[2],
            solved[3],
            solved[4],
            solved[5],
            solved[6],
            solved[7],
            1.0,
        )
    )


def _least_squares(rows: list[list[float]], values: list[float]) -> list[float]:
    if len(rows) != len(values):
        raise ValueError("rows and values must have the same length.")
    if not rows:
        raise ValueError("At least one row is required.")

    column_count = len(rows[0])
    normal = [[0.0 for _ in range(column_count)] for _ in range(column_count)]
    rhs = [0.0 for _ in range(column_count)]
    for row, value in zip(rows, values):
        if len(row) != column_count:
            raise ValueError("All rows must have the same width.")
        for i in range(column_count):
            rhs[i] += row[i] * value
            for j in range(column_count):
                normal[i][j] += row[i] * row[j]

    return _solve_linear(normal, rhs)


def _solve_linear(matrix: list[list[float]], rhs: list[float]) -> list[float]:
    size = len(rhs)
    augmented = [row[:] + [value] for row, value in zip(matrix, rhs)]

    for column in range(size):
        pivot_row = max(range(column, size), key=lambda row: abs(augmented[row][column]))
        if abs(augmented[pivot_row][column]) < 1e-12:
            raise ValueError("Paper fiducial observations are degenerate; homography solve is singular.")
        augmented[column], augmented[pivot_row] = augmented[pivot_row], augmented[column]

        pivot = augmented[column][column]
        for item in range(column, size + 1):
            augmented[column][item] /= pivot

        for row in range(size):
            if row == column:
                continue
            factor = augmented[row][column]
            for item in range(column, size + 1):
                augmented[row][item] -= factor * augmented[column][item]

    return [augmented[row][size] for row in range(size)]
