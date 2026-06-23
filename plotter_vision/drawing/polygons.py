from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.vision_model import LogicalPointMM
from plotter_vision.config import MachineConfig
from plotter_vision.machine.safety import validate_workspace_point


PolylineRole = Literal["outline", "hatch", "mark", "contour"]
SimpleShapeKind = Literal["triangle", "square"]


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


class PointMarkPrimitive(BaseModel):
    center: PaperPointNorm
    mark_size_mm: float = 4.0

    @field_validator("mark_size_mm")
    @classmethod
    def _validate_mark_size(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0:
            raise ValueError("mark_size_mm must be positive and finite.")
        if value > 50.0:
            raise ValueError("mark_size_mm is limited to 50 mm.")
        return value


class PolylinePrimitive(BaseModel):
    points: list[PaperPointNorm]
    role: Literal["outline", "hatch", "mark", "contour"] = "contour"
    closed: bool = False

    @model_validator(mode="after")
    def _validate_points(self) -> PolylinePrimitive:
        if len(self.points) < 2:
            raise ValueError("polyline primitives require at least two points.")
        return self


class ContourGroupPrimitive(BaseModel):
    contours: list[list[PaperPointNorm]]

    @model_validator(mode="after")
    def _validate_contours(self) -> ContourGroupPrimitive:
        if not self.contours:
            raise ValueError("contour groups require at least one contour.")
        for contour in self.contours:
            if len(contour) < 2:
                raise ValueError("each contour requires at least two points.")
        return self


class SimpleShapePrimitive(BaseModel):
    kind: SimpleShapeKind
    center: PaperPointNorm
    size_norm: float = 0.2

    @field_validator("size_norm")
    @classmethod
    def _validate_size(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0:
            raise ValueError("shape size_norm must be positive and finite.")
        if value > 1.0:
            raise ValueError("shape size_norm is limited to 1.0.")
        return value


class DrawingProgram(BaseModel):
    polygons: list[PolygonPrimitive] = Field(default_factory=list)
    point_marks: list[PointMarkPrimitive] = Field(default_factory=list)
    polylines: list[PolylinePrimitive] = Field(default_factory=list)
    contour_groups: list[ContourGroupPrimitive] = Field(default_factory=list)
    simple_shapes: list[SimpleShapePrimitive] = Field(default_factory=list)
    min_hatch_spacing_mm: float = 1.2
    max_hatch_spacing_mm: float = 9.0
    max_hatch_segments: int = 1200
    max_primitive_count: int = 1600

    @model_validator(mode="after")
    def _validate_program(self) -> DrawingProgram:
        if self.min_hatch_spacing_mm <= 0 or self.max_hatch_spacing_mm <= 0:
            raise ValueError("hatch spacing values must be positive.")
        if self.min_hatch_spacing_mm > self.max_hatch_spacing_mm:
            raise ValueError("min_hatch_spacing_mm cannot exceed max_hatch_spacing_mm.")
        if self.max_hatch_segments < 1:
            raise ValueError("max_hatch_segments must be positive.")
        if self.max_primitive_count < 1:
            raise ValueError("max_primitive_count must be positive.")
        primitive_count = (
            len(self.polygons)
            + len(self.point_marks)
            + len(self.polylines)
            + len(self.simple_shapes)
            + sum(len(group.contours) for group in self.contour_groups)
        )
        if primitive_count > self.max_primitive_count:
            raise ValueError(
                f"drawing program contains {primitive_count} primitives; "
                f"limit is {self.max_primitive_count}."
            )
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
    program: DrawingProgram,
    frame: DrawingFrameMM,
) -> list[PlannedPolyline]:
    polylines: list[PlannedPolyline] = []
    hatch_count = 0

    for mark in program.point_marks:
        polylines.extend(_point_mark_polylines(mark=mark, frame=frame))

    for polyline in program.polylines:
        polylines.append(_map_polyline_primitive(polyline=polyline, frame=frame))

    for group in program.contour_groups:
        for contour in group.contours:
            polylines.append(
                _planned_polyline_from_paper_points(
                    points=contour,
                    role="contour",
                    closed=False,
                    frame=frame,
                )
            )

    for shape in program.simple_shapes:
        polylines.append(_simple_shape_polyline(shape=shape, frame=frame))

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


def _point_mark_polylines(
    *,
    mark: PointMarkPrimitive,
    frame: DrawingFrameMM,
) -> list[PlannedPolyline]:
    center = frame.map_point(mark.center)
    half = mark.mark_size_mm / 2.0
    return [
        PlannedPolyline(
            role="mark",
            points=[
                LogicalPointMM(x=center.x - half, y=center.y),
                LogicalPointMM(x=center.x + half, y=center.y),
            ],
        ),
        PlannedPolyline(
            role="mark",
            points=[
                LogicalPointMM(x=center.x, y=center.y - half),
                LogicalPointMM(x=center.x, y=center.y + half),
            ],
        ),
    ]


def _map_polyline_primitive(
    *,
    polyline: PolylinePrimitive,
    frame: DrawingFrameMM,
) -> PlannedPolyline:
    return _planned_polyline_from_paper_points(
        points=polyline.points,
        role=polyline.role,
        closed=polyline.closed,
        frame=frame,
    )


def _planned_polyline_from_paper_points(
    *,
    points: list[PaperPointNorm],
    role: PolylineRole,
    closed: bool,
    frame: DrawingFrameMM,
) -> PlannedPolyline:
    logical_points = [frame.map_point(point) for point in points]
    if closed and logical_points[0] != logical_points[-1]:
        logical_points.append(logical_points[0])
    return PlannedPolyline(role=role, points=logical_points)


def _simple_shape_polyline(
    *,
    shape: SimpleShapePrimitive,
    frame: DrawingFrameMM,
) -> PlannedPolyline:
    vertices = _simple_shape_vertices(shape)
    return _planned_polyline_from_paper_points(
        points=vertices,
        role="outline",
        closed=True,
        frame=frame,
    )


def _simple_shape_vertices(shape: SimpleShapePrimitive) -> list[PaperPointNorm]:
    half = shape.size_norm / 2.0
    if shape.kind == "square":
        raw_vertices = [
            (shape.center.x - half, shape.center.y - half),
            (shape.center.x + half, shape.center.y - half),
            (shape.center.x + half, shape.center.y + half),
            (shape.center.x - half, shape.center.y + half),
        ]
    else:
        height = shape.size_norm * math.sqrt(3.0) / 2.0
        raw_vertices = [
            (shape.center.x - half, shape.center.y - height / 3.0),
            (shape.center.x + half, shape.center.y - height / 3.0),
            (shape.center.x, shape.center.y + 2.0 * height / 3.0),
        ]
    return [PaperPointNorm(x=x, y=y) for x, y in raw_vertices]


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
