"""Paper-space drawing primitives for calibrated plotter output."""

from plotter_vision.drawing.polygons import (
    ContourGroupPrimitive,
    DrawingFrameMM,
    PaperDrawingProgram,
    PaperPointNorm,
    PointMarkPrimitive,
    PlannedPolyline,
    PolylinePrimitive,
    PolygonPrimitive,
    SimpleShapePrimitive,
    build_polygon_polylines,
    validate_polylines_in_workspace,
)
from plotter_vision.drawing.raster import (
    LuminanceRaster,
    RasterContourOptions,
    RasterContourSummary,
    RasterPolygonOptions,
    RasterPolygonSummary,
    build_paper_contour_program_from_luminance_raster,
    build_paper_program_from_luminance_raster,
)

__all__ = [
    "DrawingFrameMM",
    "LuminanceRaster",
    "ContourGroupPrimitive",
    "PaperDrawingProgram",
    "PaperPointNorm",
    "PointMarkPrimitive",
    "PlannedPolyline",
    "PolylinePrimitive",
    "PolygonPrimitive",
    "SimpleShapePrimitive",
    "RasterPolygonOptions",
    "RasterPolygonSummary",
    "RasterContourOptions",
    "RasterContourSummary",
    "build_paper_contour_program_from_luminance_raster",
    "build_paper_program_from_luminance_raster",
    "build_polygon_polylines",
    "validate_polylines_in_workspace",
]
