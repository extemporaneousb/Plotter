from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, field_validator, model_validator

from plotter_vision.drawing.polygons import (
    DrawingProgram,
    PaperPointNorm,
    PolylinePrimitive,
    PolygonPrimitive,
)


PortraitRenderTechnique = Literal["contours", "hatch", "crosshatch", "facets", "stipple"]
PortraitPolylineRole = Literal["outline", "hatch", "mark", "contour"]


class LuminanceRaster(BaseModel):
    """Top-to-bottom normalized luminance samples. 0 is black, 1 is white."""

    samples: list[list[float]]

    @field_validator("samples")
    @classmethod
    def _validate_samples(cls, value: list[list[float]]) -> list[list[float]]:
        if len(value) < 2:
            raise ValueError("luminance raster must contain at least two rows.")
        width = len(value[0])
        if width < 2:
            raise ValueError("luminance raster must contain at least two columns.")
        if len(value) > 80 or width > 80:
            raise ValueError("luminance raster is limited to 80x80 samples.")

        for row in value:
            if len(row) != width:
                raise ValueError("luminance raster rows must all have the same width.")
            for sample in row:
                if not math.isfinite(sample):
                    raise ValueError("luminance samples must be finite.")
                if sample < 0.0 or sample > 1.0:
                    raise ValueError("luminance samples must be in [0, 1].")
        return value

    @property
    def width(self) -> int:
        return len(self.samples[0])

    @property
    def height(self) -> int:
        return len(self.samples)


class RasterPolygonOptions(BaseModel):
    darkness_threshold: float = 0.14
    gamma: float = 1.0
    auto_contrast: bool = True
    triangulate: bool = True
    outline: bool = False
    hatch_angle_deg: float = 35.0
    min_hatch_spacing_mm: float = 1.6
    max_hatch_spacing_mm: float = 8.0
    max_hatch_segments: int = 1600
    max_polygons: int = 1200

    @model_validator(mode="after")
    def _validate_options(self) -> RasterPolygonOptions:
        if not 0.0 <= self.darkness_threshold <= 1.0:
            raise ValueError("darkness_threshold must be in [0, 1].")
        if self.gamma <= 0.0 or not math.isfinite(self.gamma):
            raise ValueError("gamma must be positive and finite.")
        if self.min_hatch_spacing_mm <= 0 or self.max_hatch_spacing_mm <= 0:
            raise ValueError("hatch spacing values must be positive.")
        if self.min_hatch_spacing_mm > self.max_hatch_spacing_mm:
            raise ValueError("min_hatch_spacing_mm cannot exceed max_hatch_spacing_mm.")
        if self.max_hatch_segments < 1:
            raise ValueError("max_hatch_segments must be positive.")
        if self.max_polygons < 1:
            raise ValueError("max_polygons must be positive.")
        return self


class RasterPolygonSummary(BaseModel):
    raster_width: int
    raster_height: int
    cell_count: int
    selected_cell_count: int
    polygon_count: int
    min_luminance: float
    max_luminance: float
    min_shade: float | None = None
    max_shade: float | None = None


class RasterContourOptions(BaseModel):
    darkness_threshold: float = 0.35
    auto_contrast: bool = True
    max_contours: int = 900

    @model_validator(mode="after")
    def _validate_options(self) -> RasterContourOptions:
        if not 0.0 <= self.darkness_threshold <= 1.0:
            raise ValueError("darkness_threshold must be in [0, 1].")
        if self.max_contours < 1:
            raise ValueError("max_contours must be positive.")
        return self


class RasterContourSummary(BaseModel):
    raster_width: int
    raster_height: int
    cell_count: int
    selected_cell_count: int
    contour_count: int
    min_luminance: float
    max_luminance: float


class PortraitContourOptions(BaseModel):
    technique: PortraitRenderTechnique = "contours"
    contour_levels: int = 7
    low_quantile: float = 0.18
    high_quantile: float = 0.92
    auto_contrast: bool = True
    illumination_radius: int = 5
    illumination_strength: float = 0.72
    smoothing_radius: int = 1
    simplification_epsilon_norm: float = 0.004
    min_contour_length_norm: float = 0.035
    min_points_per_contour: int = 4
    max_contours: int = 700
    max_points: int = 8000

    @model_validator(mode="after")
    def _validate_options(self) -> PortraitContourOptions:
        if self.contour_levels < 1 or self.contour_levels > 24:
            raise ValueError("contour_levels must be between 1 and 24.")
        if not 0.0 <= self.low_quantile < self.high_quantile <= 1.0:
            raise ValueError("low_quantile must be less than high_quantile within [0, 1].")
        if self.illumination_radius < 0 or self.illumination_radius > 30:
            raise ValueError("illumination_radius must be between 0 and 30.")
        if not 0.0 <= self.illumination_strength <= 1.0:
            raise ValueError("illumination_strength must be in [0, 1].")
        if self.smoothing_radius < 0 or self.smoothing_radius > 8:
            raise ValueError("smoothing_radius must be between 0 and 8.")
        if self.simplification_epsilon_norm < 0.0 or self.simplification_epsilon_norm > 0.05:
            raise ValueError("simplification_epsilon_norm must be between 0 and 0.05.")
        if self.min_contour_length_norm < 0.0 or self.min_contour_length_norm > 2.0:
            raise ValueError("min_contour_length_norm must be between 0 and 2.")
        if self.min_points_per_contour < 2:
            raise ValueError("min_points_per_contour must be at least 2.")
        if self.max_contours < 1:
            raise ValueError("max_contours must be positive.")
        if self.max_points < 2:
            raise ValueError("max_points must be at least 2.")
        return self


class PortraitContourSummary(BaseModel):
    technique: PortraitRenderTechnique = "contours"
    raster_width: int
    raster_height: int
    cell_count: int
    contour_count: int
    raw_contour_count: int
    raw_point_count: int
    kept_point_count: int
    min_luminance: float
    max_luminance: float
    min_normalized_value: float
    max_normalized_value: float
    levels: list[float]
    illumination_radius: int
    illumination_strength: float
    smoothing_radius: int
    simplification_epsilon_norm: float


def build_paper_program_from_luminance_raster(
    *,
    raster: LuminanceRaster,
    options: RasterPolygonOptions | None = None,
) -> tuple[DrawingProgram, RasterPolygonSummary]:
    opts = options or RasterPolygonOptions()
    darkness_values = _darkness_values(raster.samples, auto_contrast=opts.auto_contrast)

    polygons: list[PolygonPrimitive] = []
    selected_shades: list[float] = []
    width = raster.width
    height = raster.height

    for row_index, row in enumerate(darkness_values):
        for column_index, darkness in enumerate(row):
            shade = max(0.0, min(1.0, darkness)) ** opts.gamma
            if shade < opts.darkness_threshold:
                continue

            x0 = column_index / width
            x1 = (column_index + 1) / width
            y_top = 1.0 - row_index / height
            y_bottom = 1.0 - (row_index + 1) / height
            selected_shades.append(shade)
            polygons.extend(
                _cell_polygons(
                    x0=x0,
                    x1=x1,
                    y0=y_bottom,
                    y1=y_top,
                    shade=shade,
                    triangulate=opts.triangulate,
                    outline=opts.outline,
                    hatch_angle_deg=opts.hatch_angle_deg,
                    alternate_diagonal=(row_index + column_index) % 2 == 0,
                )
            )
            if len(polygons) > opts.max_polygons:
                raise ValueError(
                    f"raster polygon expansion exceeded {opts.max_polygons} polygons."
                )

    luminance_values = [sample for row in raster.samples for sample in row]
    summary = RasterPolygonSummary(
        raster_width=width,
        raster_height=height,
        cell_count=width * height,
        selected_cell_count=len(selected_shades),
        polygon_count=len(polygons),
        min_luminance=min(luminance_values),
        max_luminance=max(luminance_values),
        min_shade=min(selected_shades) if selected_shades else None,
        max_shade=max(selected_shades) if selected_shades else None,
    )
    return (
        DrawingProgram(
            polygons=polygons,
            min_hatch_spacing_mm=opts.min_hatch_spacing_mm,
            max_hatch_spacing_mm=opts.max_hatch_spacing_mm,
            max_hatch_segments=opts.max_hatch_segments,
        ),
        summary,
    )


def build_portrait_contour_program_from_luminance_raster(
    *,
    raster: LuminanceRaster,
    options: PortraitContourOptions | None = None,
) -> tuple[DrawingProgram, PortraitContourSummary]:
    opts = options or PortraitContourOptions()
    values = _portrait_normalized_values(raster.samples, options=opts)
    flat_values = [value for row in values for value in row]
    levels = _contour_levels(flat_values, options=opts) if opts.technique == "contours" else []
    raw_polylines = _portrait_raw_polylines(values=values, levels=levels, options=opts)
    if opts.technique != "contours":
        raw_polylines = raw_polylines[: opts.max_contours]

    polylines: list[PolylinePrimitive] = []
    raw_point_count = 0
    kept_point_count = 0
    min_points = opts.min_points_per_contour if opts.technique == "contours" else 2
    min_length = opts.min_contour_length_norm if opts.technique == "contours" else 0.004
    for points, closed, role in sorted(
        raw_polylines,
        key=lambda contour: _polyline_length_norm(contour[0], closed=contour[1]),
        reverse=True,
    ):
        raw_point_count += len(points)
        if len(points) < min_points:
            continue
        if _polyline_length_norm(points, closed=closed) < min_length:
            continue

        simplified = (
            _simplify_points(points, epsilon=opts.simplification_epsilon_norm)
            if opts.technique == "contours"
            else points
        )
        if len(simplified) < min_points:
            continue
        kept_point_count += len(simplified)
        if kept_point_count > opts.max_points:
            raise ValueError(f"portrait contour expansion exceeded {opts.max_points} points.")

        polylines.append(
            PolylinePrimitive(
                role=role,
                closed=closed,
                points=[PaperPointNorm(x=x, y=y) for x, y in simplified],
            )
        )
        if len(polylines) > opts.max_contours:
            raise ValueError(f"portrait contour expansion exceeded {opts.max_contours} contours.")

    luminance_values = [sample for row in raster.samples for sample in row]
    summary = PortraitContourSummary(
        technique=opts.technique,
        raster_width=raster.width,
        raster_height=raster.height,
        cell_count=raster.width * raster.height,
        contour_count=len(polylines),
        raw_contour_count=len(raw_polylines),
        raw_point_count=raw_point_count,
        kept_point_count=kept_point_count,
        min_luminance=min(luminance_values),
        max_luminance=max(luminance_values),
        min_normalized_value=min(flat_values),
        max_normalized_value=max(flat_values),
        levels=levels,
        illumination_radius=opts.illumination_radius,
        illumination_strength=opts.illumination_strength,
        smoothing_radius=opts.smoothing_radius,
        simplification_epsilon_norm=opts.simplification_epsilon_norm,
    )
    return DrawingProgram(polylines=polylines, max_primitive_count=opts.max_contours), summary


def build_paper_contour_program_from_luminance_raster(
    *,
    raster: LuminanceRaster,
    options: RasterContourOptions | None = None,
) -> tuple[DrawingProgram, RasterContourSummary]:
    opts = options or RasterContourOptions()
    darkness_values = _darkness_values(raster.samples, auto_contrast=opts.auto_contrast)

    polylines: list[PolylinePrimitive] = []
    width = raster.width
    height = raster.height

    for row_index, row in enumerate(darkness_values):
        for column_index, darkness in enumerate(row):
            if darkness < opts.darkness_threshold:
                continue

            x0 = column_index / width
            x1 = (column_index + 1) / width
            y_top = 1.0 - row_index / height
            y_bottom = 1.0 - (row_index + 1) / height
            polylines.append(
                PolylinePrimitive(
                    role="contour",
                    closed=True,
                    points=[
                        PaperPointNorm(x=x0, y=y_bottom),
                        PaperPointNorm(x=x1, y=y_bottom),
                        PaperPointNorm(x=x1, y=y_top),
                        PaperPointNorm(x=x0, y=y_top),
                    ],
                )
            )
            if len(polylines) > opts.max_contours:
                raise ValueError(
                    f"raster contour expansion exceeded {opts.max_contours} contours."
                )

    luminance_values = [sample for row in raster.samples for sample in row]
    summary = RasterContourSummary(
        raster_width=width,
        raster_height=height,
        cell_count=width * height,
        selected_cell_count=len(polylines),
        contour_count=len(polylines),
        min_luminance=min(luminance_values),
        max_luminance=max(luminance_values),
    )
    return (
        DrawingProgram(
            polylines=polylines,
            max_primitive_count=max(opts.max_contours, 1),
        ),
        summary,
    )


def _darkness_values(samples: list[list[float]], *, auto_contrast: bool) -> list[list[float]]:
    darkness = [[1.0 - sample for sample in row] for row in samples]
    if not auto_contrast:
        return darkness

    flat = sorted(value for row in darkness for value in row)
    low = _percentile(flat, 0.05)
    high = _percentile(flat, 0.95)
    span = high - low
    if span <= 1e-9:
        return darkness

    return [
        [max(0.0, min(1.0, (value - low) / span)) for value in row]
        for row in darkness
    ]


def _portrait_normalized_values(
    samples: list[list[float]],
    *,
    options: PortraitContourOptions,
) -> list[list[float]]:
    darkness = [[1.0 - sample for sample in row] for row in samples]
    if options.illumination_radius > 0 and options.illumination_strength > 0:
        field = _box_blur(darkness, radius=options.illumination_radius)
        strength = options.illumination_strength
        darkness = [
            [
                (1.0 - strength) * value + strength * (0.5 + value - field_value)
                for value, field_value in zip(row, field_row)
            ]
            for row, field_row in zip(darkness, field)
        ]

    if options.smoothing_radius > 0:
        darkness = _box_blur(darkness, radius=options.smoothing_radius)

    if options.auto_contrast:
        darkness = _contrast_stretch(
            darkness,
            low_quantile=options.low_quantile,
            high_quantile=options.high_quantile,
        )

    return [[max(0.0, min(1.0, value)) for value in row] for row in darkness]


def _contrast_stretch(
    values: list[list[float]],
    *,
    low_quantile: float,
    high_quantile: float,
) -> list[list[float]]:
    flat = sorted(value for row in values for value in row)
    low = _percentile(flat, low_quantile)
    high = _percentile(flat, high_quantile)
    span = high - low
    if span <= 1e-9:
        return values
    return [
        [max(0.0, min(1.0, (value - low) / span)) for value in row]
        for row in values
    ]


def _box_blur(values: list[list[float]], *, radius: int) -> list[list[float]]:
    if radius <= 0:
        return [list(row) for row in values]
    height = len(values)
    width = len(values[0])
    blurred: list[list[float]] = []
    for row_index in range(height):
        row_values: list[float] = []
        y0 = max(0, row_index - radius)
        y1 = min(height - 1, row_index + radius)
        for column_index in range(width):
            x0 = max(0, column_index - radius)
            x1 = min(width - 1, column_index + radius)
            total = 0.0
            count = 0
            for source_y in range(y0, y1 + 1):
                for source_x in range(x0, x1 + 1):
                    total += values[source_y][source_x]
                    count += 1
            row_values.append(total / count)
        blurred.append(row_values)
    return blurred


def _contour_levels(values: list[float], *, options: PortraitContourOptions) -> list[float]:
    sorted_values = sorted(values)
    low = _percentile(sorted_values, options.low_quantile)
    high = _percentile(sorted_values, options.high_quantile)
    if high - low <= 1e-9:
        return [0.5]
    return [
        low + (high - low) * ((index + 1) / (options.contour_levels + 1))
        for index in range(options.contour_levels)
    ]


def _portrait_raw_polylines(
    *,
    values: list[list[float]],
    levels: list[float],
    options: PortraitContourOptions,
) -> list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]]:
    if options.technique == "contours":
        polylines: list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]] = []
        for level in levels:
            polylines.extend(
                (points, closed, "contour")
                for points, closed in _marching_squares_contours(values, level=level)
            )
        return polylines
    if options.technique == "hatch":
        return _portrait_hatch_polylines(values=values, options=options, crosshatch=False)
    if options.technique == "crosshatch":
        return _portrait_hatch_polylines(values=values, options=options, crosshatch=True)
    if options.technique == "facets":
        return _portrait_facet_polylines(values=values, options=options)
    return _portrait_stipple_polylines(values=values, options=options)


def _portrait_hatch_polylines(
    *,
    values: list[list[float]],
    options: PortraitContourOptions,
    crosshatch: bool,
) -> list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]]:
    height = len(values)
    width = len(values[0])
    cell_width = 1.0 / max(width - 1, 1)
    cell_height = 1.0 / max(height - 1, 1)
    polylines: list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]] = []
    for row_index, row in enumerate(values):
        for column_index, darkness in enumerate(row):
            if darkness <= 0.18:
                continue
            density = max(0.0, min(1.0, (darkness - 0.18) / 0.82))
            skip = 1 if density > 0.72 else 2 if density > 0.44 else 3
            if (row_index + column_index) % skip != 0:
                continue

            center_x, center_y = _portrait_grid_point(
                row=row_index,
                column=column_index,
                height=height,
                width=width,
            )
            scale = 0.28 + 0.26 * density
            dx = cell_width * scale
            dy = cell_height * scale
            polylines.append(
                (
                    [
                        _clamped_point(center_x - dx, center_y + dy),
                        _clamped_point(center_x + dx, center_y - dy),
                    ],
                    False,
                    "hatch",
                )
            )

            if crosshatch and darkness > 0.42 and (row_index * 2 + column_index) % max(1, skip - 1) == 0:
                polylines.append(
                    (
                        [
                            _clamped_point(center_x - dx, center_y - dy),
                            _clamped_point(center_x + dx, center_y + dy),
                        ],
                        False,
                        "hatch",
                    )
                )

            if len(polylines) >= options.max_contours:
                return polylines
    return polylines


def _portrait_facet_polylines(
    *,
    values: list[list[float]],
    options: PortraitContourOptions,
) -> list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]]:
    height = len(values)
    width = len(values[0])
    polylines: list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]] = []
    for row_index in range(height - 1):
        for column_index in range(width - 1):
            top_left = values[row_index][column_index]
            top_right = values[row_index][column_index + 1]
            bottom_right = values[row_index + 1][column_index + 1]
            bottom_left = values[row_index + 1][column_index]
            local = [top_left, top_right, bottom_right, bottom_left]
            avg_darkness = sum(local) / 4.0
            contrast = max(local) - min(local)
            if avg_darkness <= 0.22 and contrast <= 0.11:
                continue

            p0 = _portrait_grid_point(row=row_index, column=column_index, height=height, width=width)
            p1 = _portrait_grid_point(row=row_index, column=column_index + 1, height=height, width=width)
            p2 = _portrait_grid_point(row=row_index + 1, column=column_index + 1, height=height, width=width)
            p3 = _portrait_grid_point(row=row_index + 1, column=column_index, height=height, width=width)
            if top_left + bottom_right >= top_right + bottom_left:
                polylines.append(([p0, p1, p2], True, "outline"))
                if avg_darkness > 0.40 or contrast > 0.18:
                    polylines.append(([p0, p2, p3], True, "outline"))
            else:
                polylines.append(([p0, p1, p3], True, "outline"))
                if avg_darkness > 0.40 or contrast > 0.18:
                    polylines.append(([p1, p2, p3], True, "outline"))

            if len(polylines) >= options.max_contours:
                return polylines
    return polylines


def _portrait_stipple_polylines(
    *,
    values: list[list[float]],
    options: PortraitContourOptions,
) -> list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]]:
    height = len(values)
    width = len(values[0])
    base_radius = min(1.0 / max(width - 1, 1), 1.0 / max(height - 1, 1))
    polylines: list[tuple[list[tuple[float, float]], bool, PortraitPolylineRole]] = []
    for row_index, row in enumerate(values):
        for column_index, darkness in enumerate(row):
            if darkness <= 0.24:
                continue
            density = max(0.0, min(1.0, (darkness - 0.24) / 0.76))
            skip = 2 if density > 0.78 else 3 if density > 0.48 else 4
            if (row_index * 5 + column_index * 3) % skip != 0:
                continue

            center_x, center_y = _portrait_grid_point(
                row=row_index,
                column=column_index,
                height=height,
                width=width,
            )
            radius = base_radius * (0.16 + 0.26 * density)
            polylines.append(
                (
                    [
                        _clamped_point(center_x, center_y + radius),
                        _clamped_point(center_x + radius, center_y),
                        _clamped_point(center_x, center_y - radius),
                        _clamped_point(center_x - radius, center_y),
                    ],
                    True,
                    "mark",
                )
            )
            if len(polylines) >= options.max_contours:
                return polylines
    return polylines


def _portrait_grid_point(
    *,
    row: int,
    column: int,
    height: int,
    width: int,
) -> tuple[float, float]:
    return (
        column / max(width - 1, 1),
        1.0 - row / max(height - 1, 1),
    )


def _clamped_point(x: float, y: float) -> tuple[float, float]:
    return (max(0.0, min(1.0, x)), max(0.0, min(1.0, y)))


def _marching_squares_contours(
    values: list[list[float]],
    *,
    level: float,
) -> list[tuple[list[tuple[float, float]], bool]]:
    segments: list[tuple[tuple[float, float], tuple[float, float]]] = []
    height = len(values)
    width = len(values[0])
    if height < 2 or width < 2:
        return []

    for row_index in range(height - 1):
        for column_index in range(width - 1):
            x0 = column_index / (width - 1)
            x1 = (column_index + 1) / (width - 1)
            y_top = 1.0 - row_index / (height - 1)
            y_bottom = 1.0 - (row_index + 1) / (height - 1)
            corners = [
                ((x0, y_top), values[row_index][column_index]),
                ((x1, y_top), values[row_index][column_index + 1]),
                ((x1, y_bottom), values[row_index + 1][column_index + 1]),
                ((x0, y_bottom), values[row_index + 1][column_index]),
            ]
            edges = [
                (corners[0], corners[1]),
                (corners[1], corners[2]),
                (corners[2], corners[3]),
                (corners[3], corners[0]),
            ]
            crossings = [
                _edge_crossing(edge_start, edge_end, level=level)
                for edge_start, edge_end in edges
            ]
            points = [point for point in crossings if point is not None]
            unique_points = _dedupe_points(points)
            if len(unique_points) == 2:
                segments.append((unique_points[0], unique_points[1]))
            elif len(unique_points) == 4:
                segments.append((unique_points[0], unique_points[1]))
                segments.append((unique_points[2], unique_points[3]))

    return _stitch_segments(segments)


def _edge_crossing(
    edge_start: tuple[tuple[float, float], float],
    edge_end: tuple[tuple[float, float], float],
    *,
    level: float,
) -> tuple[float, float] | None:
    (start_x, start_y), start_value = edge_start
    (end_x, end_y), end_value = edge_end
    if start_value == end_value:
        return None
    if not (
        (start_value < level <= end_value)
        or (end_value < level <= start_value)
    ):
        return None
    fraction = (level - start_value) / (end_value - start_value)
    return (
        max(0.0, min(1.0, start_x + fraction * (end_x - start_x))),
        max(0.0, min(1.0, start_y + fraction * (end_y - start_y))),
    )


def _dedupe_points(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    seen: set[tuple[int, int]] = set()
    unique: list[tuple[float, float]] = []
    for point in points:
        key = _point_key(point)
        if key in seen:
            continue
        seen.add(key)
        unique.append(point)
    return unique


def _stitch_segments(
    segments: list[tuple[tuple[float, float], tuple[float, float]]]
) -> list[tuple[list[tuple[float, float]], bool]]:
    unused = list(segments)
    contours: list[tuple[list[tuple[float, float]], bool]] = []
    while unused:
        start, end = unused.pop()
        points = [start, end]
        changed = True
        while changed:
            changed = False
            for index, (candidate_start, candidate_end) in enumerate(unused):
                if _same_point(candidate_end, points[0]):
                    points.insert(0, candidate_start)
                elif _same_point(candidate_start, points[0]):
                    points.insert(0, candidate_end)
                elif _same_point(candidate_start, points[-1]):
                    points.append(candidate_end)
                elif _same_point(candidate_end, points[-1]):
                    points.append(candidate_start)
                else:
                    continue
                unused.pop(index)
                changed = True
                break

        closed = len(points) > 2 and _same_point(points[0], points[-1])
        if closed:
            points = points[:-1]
        contours.append((points, closed))
    return contours


def _same_point(point_a: tuple[float, float], point_b: tuple[float, float]) -> bool:
    return _point_key(point_a) == _point_key(point_b)


def _point_key(point: tuple[float, float]) -> tuple[int, int]:
    return (round(point[0] * 1_000_000), round(point[1] * 1_000_000))


def _polyline_length_norm(points: list[tuple[float, float]], *, closed: bool) -> float:
    if len(points) < 2:
        return 0.0
    pairs = list(zip(points, points[1:]))
    if closed:
        pairs.append((points[-1], points[0]))
    return sum(math.hypot(end[0] - start[0], end[1] - start[1]) for start, end in pairs)


def _simplify_points(
    points: list[tuple[float, float]],
    *,
    epsilon: float,
) -> list[tuple[float, float]]:
    if epsilon <= 0 or len(points) <= 2:
        return points
    keep = _rdp(points, epsilon=epsilon)
    return keep if len(keep) >= 2 else points[:2]


def _rdp(points: list[tuple[float, float]], *, epsilon: float) -> list[tuple[float, float]]:
    if len(points) <= 2:
        return points
    start = points[0]
    end = points[-1]
    max_distance = -1.0
    split_index = 0
    for index, point in enumerate(points[1:-1], start=1):
        distance = _point_line_distance(point=point, start=start, end=end)
        if distance > max_distance:
            max_distance = distance
            split_index = index
    if max_distance <= epsilon:
        return [start, end]
    left = _rdp(points[: split_index + 1], epsilon=epsilon)
    right = _rdp(points[split_index:], epsilon=epsilon)
    return [*left[:-1], *right]


def _point_line_distance(
    *,
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    denominator = math.hypot(dx, dy)
    if denominator <= 1e-12:
        return math.hypot(point[0] - start[0], point[1] - start[1])
    return abs(dy * point[0] - dx * point[1] + end[0] * start[1] - end[1] * start[0]) / denominator


def _cell_polygons(
    *,
    x0: float,
    x1: float,
    y0: float,
    y1: float,
    shade: float,
    triangulate: bool,
    outline: bool,
    hatch_angle_deg: float,
    alternate_diagonal: bool,
) -> list[PolygonPrimitive]:
    bottom_left = PaperPointNorm(x=x0, y=y0)
    bottom_right = PaperPointNorm(x=x1, y=y0)
    top_right = PaperPointNorm(x=x1, y=y1)
    top_left = PaperPointNorm(x=x0, y=y1)

    if not triangulate:
        return [
            PolygonPrimitive(
                vertices=[bottom_left, bottom_right, top_right, top_left],
                shade=shade,
                outline=outline,
                hatch_angle_deg=hatch_angle_deg,
            )
        ]

    if alternate_diagonal:
        triangles = [
            [bottom_left, bottom_right, top_right],
            [bottom_left, top_right, top_left],
        ]
    else:
        triangles = [
            [bottom_left, bottom_right, top_left],
            [bottom_right, top_right, top_left],
        ]
    return [
        PolygonPrimitive(
            vertices=vertices,
            shade=shade,
            outline=outline,
            hatch_angle_deg=hatch_angle_deg,
        )
        for vertices in triangles
    ]


def _percentile(sorted_values: list[float], fraction: float) -> float:
    if not sorted_values:
        raise ValueError("Cannot compute percentile of an empty sequence.")
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = max(0.0, min(1.0, fraction)) * (len(sorted_values) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return sorted_values[lower]
    t = position - lower
    return sorted_values[lower] * (1.0 - t) + sorted_values[upper] * t
