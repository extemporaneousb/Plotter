from __future__ import annotations

import math

from pydantic import BaseModel, field_validator, model_validator

from plotter_vision.drawing.polygons import (
    PaperDrawingProgram,
    PaperPointNorm,
    PolylinePrimitive,
    PolygonPrimitive,
)


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


def build_paper_program_from_luminance_raster(
    *,
    raster: LuminanceRaster,
    options: RasterPolygonOptions | None = None,
) -> tuple[PaperDrawingProgram, RasterPolygonSummary]:
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
        PaperDrawingProgram(
            polygons=polygons,
            min_hatch_spacing_mm=opts.min_hatch_spacing_mm,
            max_hatch_spacing_mm=opts.max_hatch_spacing_mm,
            max_hatch_segments=opts.max_hatch_segments,
        ),
        summary,
    )


def build_paper_contour_program_from_luminance_raster(
    *,
    raster: LuminanceRaster,
    options: RasterContourOptions | None = None,
) -> tuple[PaperDrawingProgram, RasterContourSummary]:
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
        PaperDrawingProgram(
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
