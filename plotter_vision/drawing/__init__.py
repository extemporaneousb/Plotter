"""Paper-space drawing primitives for calibrated plotter output."""

from plotter_vision.drawing.capabilities import (
    CapabilityTestDefinition,
    CapabilityTestKind,
    build_capability_test_definition,
    build_capability_test_program,
)
from plotter_vision.drawing.polygons import (
    ContourGroupPrimitive,
    DrawingProgram,
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
    "DrawingProgram",
    "LuminanceRaster",
    "ContourGroupPrimitive",
    "CapabilityTestDefinition",
    "CapabilityTestKind",
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
    "build_capability_test_definition",
    "build_capability_test_program",
    "build_polygon_polylines",
    "validate_polylines_in_workspace",
]
