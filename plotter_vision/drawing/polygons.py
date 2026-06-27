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
    primitive_id: str | None = None
    semantic_role: str = "polygon"
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
    primitive_id: str | None = None
    semantic_role: str = "point_mark"
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
    primitive_id: str | None = None
    semantic_role: str | None = None
    points: list[PaperPointNorm]
    role: Literal["outline", "hatch", "mark", "contour"] = "contour"
    closed: bool = False

    @model_validator(mode="after")
    def _validate_points(self) -> PolylinePrimitive:
        if len(self.points) < 2:
            raise ValueError("polyline primitives require at least two points.")
        return self


class ContourGroupPrimitive(BaseModel):
    primitive_id: str | None = None
    semantic_role: str = "contour_group"
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
    primitive_id: str | None = None
    semantic_role: str | None = None
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


class CirclePrimitive(BaseModel):
    primitive_id: str | None = None
    semantic_role: str = "circle"
    center: PaperPointNorm
    radius_mm: float
    segment_count: int = 48

    @field_validator("radius_mm")
    @classmethod
    def _validate_radius(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0:
            raise ValueError("circle radius_mm must be positive and finite.")
        return value

    @field_validator("segment_count")
    @classmethod
    def _validate_segment_count(cls, value: int) -> int:
        if value < 8 or value > 240:
            raise ValueError("circle segment_count must be between 8 and 240.")
        return value


class ArcPrimitive(BaseModel):
    primitive_id: str | None = None
    semantic_role: str = "arc"
    center: PaperPointNorm
    radius_mm: float
    start_angle_deg: float
    end_angle_deg: float
    segment_count: int = 24

    @field_validator("radius_mm")
    @classmethod
    def _validate_radius(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0:
            raise ValueError("arc radius_mm must be positive and finite.")
        return value

    @field_validator("start_angle_deg", "end_angle_deg")
    @classmethod
    def _validate_angle(cls, value: float) -> float:
        if not math.isfinite(value):
            raise ValueError("arc angles must be finite.")
        return value

    @field_validator("segment_count")
    @classmethod
    def _validate_segment_count(cls, value: int) -> int:
        if value < 1 or value > 240:
            raise ValueError("arc segment_count must be between 1 and 240.")
        return value

    @model_validator(mode="after")
    def _validate_sweep(self) -> ArcPrimitive:
        sweep = self.end_angle_deg - self.start_angle_deg
        if abs(sweep) <= 1e-9:
            raise ValueError("arc sweep must be non-zero.")
        if abs(sweep) > 360.0:
            raise ValueError("arc sweep is limited to 360 degrees.")
        return self


class DrawingProgram(BaseModel):
    polygons: list[PolygonPrimitive] = Field(default_factory=list)
    point_marks: list[PointMarkPrimitive] = Field(default_factory=list)
    polylines: list[PolylinePrimitive] = Field(default_factory=list)
    contour_groups: list[ContourGroupPrimitive] = Field(default_factory=list)
    simple_shapes: list[SimpleShapePrimitive] = Field(default_factory=list)
    circles: list[CirclePrimitive] = Field(default_factory=list)
    arcs: list[ArcPrimitive] = Field(default_factory=list)
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
            + len(self.circles)
            + len(self.arcs)
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
    primitive_id: str | None = None
    stroke_id: str | None = None
    semantic_role: str | None = None

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

    for index, mark in enumerate(program.point_marks, start=1):
        primitive_id = _primitive_id("point_mark", index, mark.primitive_id)
        polylines.extend(
            _point_mark_polylines(
                mark=mark,
                frame=frame,
                primitive_id=primitive_id,
                semantic_role=mark.semantic_role,
            )
        )

    for index, polyline in enumerate(program.polylines, start=1):
        primitive_id = _primitive_id("polyline", index, polyline.primitive_id)
        polylines.append(
            _map_polyline_primitive(
                polyline=polyline,
                frame=frame,
                primitive_id=primitive_id,
            )
        )

    for index, group in enumerate(program.contour_groups, start=1):
        primitive_id = _primitive_id("contour_group", index, group.primitive_id)
        for contour_index, contour in enumerate(group.contours, start=1):
            polylines.append(
                _planned_polyline_from_paper_points(
                    points=contour,
                    role="contour",
                    closed=False,
                    frame=frame,
                    primitive_id=primitive_id,
                    stroke_id=f"{primitive_id}:contour:{contour_index:03d}",
                    semantic_role=group.semantic_role,
                )
            )

    for index, shape in enumerate(program.simple_shapes, start=1):
        primitive_id = _primitive_id(shape.kind, index, shape.primitive_id)
        polylines.append(_simple_shape_polyline(shape=shape, frame=frame, primitive_id=primitive_id))

    for index, circle in enumerate(program.circles, start=1):
        primitive_id = _primitive_id("circle", index, circle.primitive_id)
        polylines.append(_circle_polyline(circle=circle, frame=frame, primitive_id=primitive_id))

    for index, arc in enumerate(program.arcs, start=1):
        primitive_id = _primitive_id("arc", index, arc.primitive_id)
        polylines.append(_arc_polyline(arc=arc, frame=frame, primitive_id=primitive_id))

    for index, polygon in enumerate(program.polygons, start=1):
        primitive_id = _primitive_id("polygon", index, polygon.primitive_id)
        logical_vertices = [frame.map_point(vertex) for vertex in polygon.vertices]
        if polygon.outline:
            polylines.append(
                PlannedPolyline(
                    role="outline",
                    points=[*logical_vertices, logical_vertices[0]],
                    primitive_id=primitive_id,
                    stroke_id=f"{primitive_id}:outline",
                    semantic_role=polygon.semantic_role,
                )
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
            polylines.append(
                PlannedPolyline(
                    role="hatch",
                    points=list(segment),
                    primitive_id=primitive_id,
                    stroke_id=f"{primitive_id}:hatch:{hatch_count:03d}",
                    semantic_role=polygon.semantic_role,
                )
            )

    return polylines


def _point_mark_polylines(
    *,
    mark: PointMarkPrimitive,
    frame: DrawingFrameMM,
    primitive_id: str,
    semantic_role: str,
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
            primitive_id=primitive_id,
            stroke_id=f"{primitive_id}:x",
            semantic_role=semantic_role,
        ),
        PlannedPolyline(
            role="mark",
            points=[
                LogicalPointMM(x=center.x, y=center.y - half),
                LogicalPointMM(x=center.x, y=center.y + half),
            ],
            primitive_id=primitive_id,
            stroke_id=f"{primitive_id}:y",
            semantic_role=semantic_role,
        ),
    ]


def _map_polyline_primitive(
    *,
    polyline: PolylinePrimitive,
    frame: DrawingFrameMM,
    primitive_id: str,
) -> PlannedPolyline:
    return _planned_polyline_from_paper_points(
        points=polyline.points,
        role=polyline.role,
        closed=polyline.closed,
        frame=frame,
        primitive_id=primitive_id,
        stroke_id=f"{primitive_id}:stroke",
        semantic_role=polyline.semantic_role or polyline.role,
    )


def _planned_polyline_from_paper_points(
    *,
    points: list[PaperPointNorm],
    role: PolylineRole,
    closed: bool,
    frame: DrawingFrameMM,
    primitive_id: str,
    stroke_id: str,
    semantic_role: str,
) -> PlannedPolyline:
    logical_points = [frame.map_point(point) for point in points]
    if closed and logical_points[0] != logical_points[-1]:
        logical_points.append(logical_points[0])
    return PlannedPolyline(
        role=role,
        points=logical_points,
        primitive_id=primitive_id,
        stroke_id=stroke_id,
        semantic_role=semantic_role,
    )


def _simple_shape_polyline(
    *,
    shape: SimpleShapePrimitive,
    frame: DrawingFrameMM,
    primitive_id: str,
) -> PlannedPolyline:
    vertices = _simple_shape_vertices(shape)
    return _planned_polyline_from_paper_points(
        points=vertices,
        role="outline",
        closed=True,
        frame=frame,
        primitive_id=primitive_id,
        stroke_id=f"{primitive_id}:outline",
        semantic_role=shape.semantic_role or shape.kind,
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


def _circle_polyline(
    *,
    circle: CirclePrimitive,
    frame: DrawingFrameMM,
    primitive_id: str,
) -> PlannedPolyline:
    center = frame.map_point(circle.center)
    points = [
        _point_on_circle(
            center=center,
            radius_mm=circle.radius_mm,
            angle_rad=(2.0 * math.pi * index) / circle.segment_count,
        )
        for index in range(circle.segment_count)
    ]
    points.append(points[0])
    return PlannedPolyline(
        role="outline",
        points=points,
        primitive_id=primitive_id,
        stroke_id=f"{primitive_id}:circle",
        semantic_role=circle.semantic_role,
    )


def _arc_polyline(
    *,
    arc: ArcPrimitive,
    frame: DrawingFrameMM,
    primitive_id: str,
) -> PlannedPolyline:
    center = frame.map_point(arc.center)
    start_rad = math.radians(arc.start_angle_deg)
    sweep_rad = math.radians(arc.end_angle_deg - arc.start_angle_deg)
    points = [
        _point_on_circle(
            center=center,
            radius_mm=arc.radius_mm,
            angle_rad=start_rad + sweep_rad * (index / arc.segment_count),
        )
        for index in range(arc.segment_count + 1)
    ]
    return PlannedPolyline(
        role="outline",
        points=points,
        primitive_id=primitive_id,
        stroke_id=f"{primitive_id}:arc",
        semantic_role=arc.semantic_role,
    )


def _point_on_circle(
    *,
    center: LogicalPointMM,
    radius_mm: float,
    angle_rad: float,
) -> LogicalPointMM:
    return LogicalPointMM(
        x=center.x + math.cos(angle_rad) * radius_mm,
        y=center.y + math.sin(angle_rad) * radius_mm,
    )


def _primitive_id(prefix: str, index: int, explicit_id: str | None) -> str:
    return explicit_id if explicit_id else f"{prefix}:{index:03d}"


def build_rich_drawing_calibration_program() -> DrawingProgram:
    """Build a deterministic multi-primitive sheet for drawing residual calibration."""
    return DrawingProgram(
        point_marks=[
            PointMarkPrimitive(
                primitive_id="cal.mark.center",
                semantic_role="center_cross_mark",
                center=PaperPointNorm(x=0.50, y=0.50),
                mark_size_mm=8.0,
            ),
            PointMarkPrimitive(
                primitive_id="cal.mark.lower_left",
                semantic_role="corner_cross_mark",
                center=PaperPointNorm(x=0.12, y=0.12),
                mark_size_mm=5.0,
            ),
            PointMarkPrimitive(
                primitive_id="cal.mark.upper_right",
                semantic_role="corner_cross_mark",
                center=PaperPointNorm(x=0.88, y=0.88),
                mark_size_mm=5.0,
            ),
        ],
        polylines=[
            PolylinePrimitive(
                primitive_id="cal.grid.horizontal_mid",
                semantic_role="grid_cross_axis",
                role="mark",
                points=[PaperPointNorm(x=0.18, y=0.50), PaperPointNorm(x=0.82, y=0.50)],
            ),
            PolylinePrimitive(
                primitive_id="cal.grid.vertical_mid",
                semantic_role="grid_cross_axis",
                role="mark",
                points=[PaperPointNorm(x=0.50, y=0.18), PaperPointNorm(x=0.50, y=0.82)],
            ),
            PolylinePrimitive(
                primitive_id="cal.line.horizontal_short",
                semantic_role="angle_length_line_0deg_short",
                role="outline",
                points=[PaperPointNorm(x=0.18, y=0.28), PaperPointNorm(x=0.38, y=0.28)],
            ),
            PolylinePrimitive(
                primitive_id="cal.line.vertical_medium",
                semantic_role="angle_length_line_90deg_medium",
                role="outline",
                points=[PaperPointNorm(x=0.18, y=0.34), PaperPointNorm(x=0.18, y=0.66)],
            ),
            PolylinePrimitive(
                primitive_id="cal.line.diagonal_pos",
                semantic_role="angle_length_line_45deg",
                role="outline",
                points=[PaperPointNorm(x=0.25, y=0.22), PaperPointNorm(x=0.45, y=0.42)],
            ),
            PolylinePrimitive(
                primitive_id="cal.line.diagonal_neg",
                semantic_role="angle_length_line_minus45deg",
                role="outline",
                points=[PaperPointNorm(x=0.25, y=0.78), PaperPointNorm(x=0.45, y=0.58)],
            ),
            PolylinePrimitive(
                primitive_id="cal.line.shallow",
                semantic_role="angle_length_line_shallow",
                role="outline",
                points=[PaperPointNorm(x=0.56, y=0.20), PaperPointNorm(x=0.84, y=0.28)],
            ),
            PolylinePrimitive(
                primitive_id="cal.rectangle.outer",
                semantic_role="nested_rectangle_outer",
                role="outline",
                closed=True,
                points=[
                    PaperPointNorm(x=0.10, y=0.10),
                    PaperPointNorm(x=0.90, y=0.10),
                    PaperPointNorm(x=0.90, y=0.90),
                    PaperPointNorm(x=0.10, y=0.90),
                ],
            ),
            PolylinePrimitive(
                primitive_id="cal.rectangle.inner",
                semantic_role="nested_rectangle_inner",
                role="outline",
                closed=True,
                points=[
                    PaperPointNorm(x=0.28, y=0.30),
                    PaperPointNorm(x=0.72, y=0.30),
                    PaperPointNorm(x=0.72, y=0.70),
                    PaperPointNorm(x=0.28, y=0.70),
                ],
            ),
            PolylinePrimitive(
                primitive_id="cal.repeat.forward",
                semantic_role="opposite_direction_repeat_forward",
                role="mark",
                points=[PaperPointNorm(x=0.62, y=0.54), PaperPointNorm(x=0.84, y=0.54)],
            ),
            PolylinePrimitive(
                primitive_id="cal.repeat.reverse",
                semantic_role="opposite_direction_repeat_reverse",
                role="mark",
                points=[PaperPointNorm(x=0.84, y=0.60), PaperPointNorm(x=0.62, y=0.60)],
            ),
        ],
        circles=[
            CirclePrimitive(
                primitive_id="cal.circle.left",
                semantic_role="closed_circle",
                center=PaperPointNorm(x=0.34, y=0.72),
                radius_mm=14.0,
                segment_count=32,
            ),
            CirclePrimitive(
                primitive_id="cal.circle.right",
                semantic_role="closed_circle",
                center=PaperPointNorm(x=0.72, y=0.36),
                radius_mm=18.0,
                segment_count=40,
            ),
        ],
        arcs=[
            ArcPrimitive(
                primitive_id="cal.arc.clockwise",
                semantic_role="arc_clockwise",
                center=PaperPointNorm(x=0.70, y=0.72),
                radius_mm=20.0,
                start_angle_deg=300.0,
                end_angle_deg=60.0,
                segment_count=18,
            ),
            ArcPrimitive(
                primitive_id="cal.arc.counterclockwise",
                semantic_role="arc_counterclockwise",
                center=PaperPointNorm(x=0.36, y=0.38),
                radius_mm=16.0,
                start_angle_deg=20.0,
                end_angle_deg=260.0,
                segment_count=24,
            ),
        ],
        max_primitive_count=64,
    )


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
