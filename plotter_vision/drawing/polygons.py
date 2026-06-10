from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.vision_model import LogicalPointMM
from plotter_vision.config import MachineConfig
from plotter_vision.machine.safety import validate_workspace_point


PolylineRole = Literal["outline", "hatch"]


class PaperPointNorm(BaseModel):
    """A point in registered paper coordinates, normalized to the paper rectangle."""

    x: float
    y: float

    @field_validator("x", "y")
    @classmethod
    def _validate_norm(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("paper coordinates must be finite.")
        if value < 0.0 or value > 1.0:
            raise ValueError("paper coordinates must be in [0, 1].")
        return value


class DrawingFrameMM(BaseModel):
    """Logical plotter rectangle where registered paper-space drawings are emitted."""

    origin_x_mm: float = 0.0
    origin_y_mm: float = 0.0
    width_mm: float
    height_mm: float
    flip_y: bool = False

    @field_validator("origin_x_mm", "origin_y_mm", "width_mm", "height_mm")
    @classmethod
    def _validate_finite(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("drawing frame values must be finite.")
        return value

    @model_validator(mode="after")
    def _validate_size(self) -> DrawingFrameMM:
        if self.width_mm <= 0 or self.height_mm <= 0:
            raise ValueError("drawing frame width_mm and height_mm must be positive.")
        return self

    def map_point(self, point: PaperPointNorm) -> LogicalPointMM:
        y_norm = 1.0 - point.y if self.flip_y else point.y
        return LogicalPointMM(
            x=self.origin_x_mm + point.x * self.width_mm,
            y=self.origin_y_mm + y_norm * self.height_mm,
        )


class PolygonPrimitive(BaseModel):
    vertices: list[PaperPointNorm]
    shade: float = 0.0
    outline: bool = True
    hatch_angle_deg: float = 35.0

    @field_validator("shade")
    @classmethod
    def _validate_shade(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("shade must be finite.")
        if value < 0.0 or value > 1.0:
            raise ValueError("shade must be in [0, 1].")
        return value

    @field_validator("hatch_angle_deg")
    @classmethod
    def _validate_angle(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("hatch_angle_deg must be finite.")
        return value

    @model_validator(mode="after")
    def _validate_vertices(self) -> PolygonPrimitive:
        if len(self.vertices) < 3:
            raise ValueError("polygon primitives require at least three vertices.")
        return self


class PaperDrawingProgram(BaseModel):
    polygons: list[PolygonPrimitive] = Field(default_factory=list)
    min_hatch_spacing_mm: float = 1.2
    max_hatch_spacing_mm: float = 9.0
    max_hatch_segments: int = 1200

    @model_validator(mode="after")
    def _validate_hatching(self) -> PaperDrawingProgram:
        if self.min_hatch_spacing_mm <= 0 or self.max_hatch_spacing_mm <= 0:
            raise ValueError("hatch spacing values must be positive.")
        if self.min_hatch_spacing_mm > self.max_hatch_spacing_mm:
            raise ValueError("min_hatch_spacing_mm cannot exceed max_hatch_spacing_mm.")
        if self.max_hatch_segments < 1:
            raise ValueError("max_hatch_segments must be positive.")
        return self


class PlannedPolyline(BaseModel):
    role: PolylineRole
    points: list[LogicalPointMM]

    @model_validator(mode="after")
    def _validate_points(self) -> PlannedPolyline:
        if len(self.points) < 2:
            raise ValueError("planned polylines require at least two points.")
        return self


def build_polygon_polylines(
    *,
    program: PaperDrawingProgram,
    frame: DrawingFrameMM,
) -> list[PlannedPolyline]:
    polylines: list[PlannedPolyline] = []
    hatch_count = 0

    for polygon in program.polygons:
        logical_vertices = [frame.map_point(vertex) for vertex in polygon.vertices]
        if polygon.outline:
            polylines.append(
                PlannedPolyline(role="outline", points=[*logical_vertices, logical_vertices[0]])
            )

        if polygon.shade <= 0:
            continue

        spacing_mm = _shade_to_spacing(
            shade=polygon.shade,
            min_spacing_mm=program.min_hatch_spacing_mm,
            max_spacing_mm=program.max_hatch_spacing_mm,
        )
        for segment in _hatch_segments(
            vertices=logical_vertices,
            spacing_mm=spacing_mm,
            angle_deg=polygon.hatch_angle_deg,
        ):
            hatch_count += 1
            if hatch_count > program.max_hatch_segments:
                raise ValueError(
                    f"polygon hatch expansion exceeded {program.max_hatch_segments} segments."
                )
            polylines.append(PlannedPolyline(role="hatch", points=list(segment)))

    return polylines


def validate_polylines_in_workspace(
    *,
    polylines: list[PlannedPolyline],
    machine: MachineConfig,
) -> None:
    for polyline in polylines:
        for point in polyline.points:
            validate_workspace_point(x_mm=point.x, y_mm=point.y, machine=machine)


def _shade_to_spacing(
    *,
    shade: float,
    min_spacing_mm: float,
    max_spacing_mm: float,
) -> float:
    return max_spacing_mm - shade * (max_spacing_mm - min_spacing_mm)


def _hatch_segments(
    *,
    vertices: list[LogicalPointMM],
    spacing_mm: float,
    angle_deg: float,
) -> list[tuple[LogicalPointMM, LogicalPointMM]]:
    angle_rad = math.radians(angle_deg)
    rotated = [_rotate(point, angle_rad=-angle_rad) for point in vertices]
    y_min = min(point.y for point in rotated)
    y_max = max(point.y for point in rotated)
    start_y = math.floor(y_min / spacing_mm) * spacing_mm

    segments: list[tuple[LogicalPointMM, LogicalPointMM]] = []
    scan_y = start_y
    while scan_y <= y_max + 1e-9:
        intersections = _scanline_intersections(vertices=rotated, y=scan_y)
        for x0, x1 in zip(intersections[0::2], intersections[1::2]):
            if abs(x1 - x0) <= 1e-9:
                continue
            start = _rotate(LogicalPointMM(x=x0, y=scan_y), angle_rad=angle_rad)
            end = _rotate(LogicalPointMM(x=x1, y=scan_y), angle_rad=angle_rad)
            segments.append((start, end))
        scan_y += spacing_mm

    return segments


def _scanline_intersections(*, vertices: list[LogicalPointMM], y: float) -> list[float]:
    intersections: list[float] = []
    closed = [*vertices, vertices[0]]
    for a, b in zip(closed, closed[1:]):
        if abs(a.y - b.y) <= 1e-12:
            continue
        low_y = min(a.y, b.y)
        high_y = max(a.y, b.y)
        if y < low_y or y >= high_y:
            continue
        t = (y - a.y) / (b.y - a.y)
        intersections.append(a.x + t * (b.x - a.x))
    intersections.sort()
    return intersections


def _rotate(point: LogicalPointMM, *, angle_rad: float) -> LogicalPointMM:
    cos_a = math.cos(angle_rad)
    sin_a = math.sin(angle_rad)
    return LogicalPointMM(
        x=point.x * cos_a - point.y * sin_a,
        y=point.x * sin_a + point.y * cos_a,
    )
