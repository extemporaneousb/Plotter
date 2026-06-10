"""Paper-space drawing primitives for calibrated plotter output."""

from plotter_vision.drawing.polygons import (
    DrawingFrameMM,
    PaperDrawingProgram,
    PaperPointNorm,
    PlannedPolyline,
    PolygonPrimitive,
    build_polygon_polylines,
    validate_polylines_in_workspace,
)
from plotter_vision.drawing.raster import (
    LuminanceRaster,
    RasterPolygonOptions,
    RasterPolygonSummary,
    build_paper_program_from_luminance_raster,
)

__all__ = [
    "DrawingFrameMM",
    "LuminanceRaster",
    "PaperDrawingProgram",
    "PaperPointNorm",
    "PlannedPolyline",
    "PolygonPrimitive",
    "RasterPolygonOptions",
    "RasterPolygonSummary",
    "build_paper_program_from_luminance_raster",
    "build_polygon_polylines",
    "validate_polylines_in_workspace",
]
