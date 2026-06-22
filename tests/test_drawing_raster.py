from __future__ import annotations

import pytest

from plotter_vision.drawing import (
    LuminanceRaster,
    PortraitContourOptions,
    RasterContourOptions,
    RasterPolygonOptions,
    build_portrait_contour_program_from_luminance_raster,
    build_paper_contour_program_from_luminance_raster,
    build_paper_program_from_luminance_raster,
)


def test_luminance_raster_dark_cells_expand_to_shaded_triangles() -> None:
    program, summary = build_paper_program_from_luminance_raster(
        raster=LuminanceRaster(
            samples=[
                [1.0, 0.1],
                [0.8, 0.0],
            ]
        ),
        options=RasterPolygonOptions(
            auto_contrast=False,
            darkness_threshold=0.25,
            triangulate=True,
            outline=False,
        ),
    )

    assert summary.raster_width == 2
    assert summary.raster_height == 2
    assert summary.selected_cell_count == 2
    assert summary.polygon_count == 4
    assert len(program.polygons) == 4
    assert all(len(polygon.vertices) == 3 for polygon in program.polygons)
    assert {round(polygon.shade, 3) for polygon in program.polygons} == {0.9, 1.0}


def test_all_light_raster_produces_empty_program() -> None:
    program, summary = build_paper_program_from_luminance_raster(
        raster=LuminanceRaster(samples=[[1.0, 0.95], [0.9, 1.0]]),
        options=RasterPolygonOptions(auto_contrast=False, darkness_threshold=0.2),
    )

    assert program.polygons == []
    assert summary.selected_cell_count == 0
    assert summary.min_shade is None
    assert summary.max_shade is None


def test_contour_baseline_outputs_polylines_without_hatch_fill() -> None:
    program, summary = build_paper_contour_program_from_luminance_raster(
        raster=LuminanceRaster(
            samples=[
                [1.0, 1.0, 1.0],
                [1.0, 0.0, 0.1],
                [1.0, 1.0, 1.0],
            ]
        ),
        options=RasterContourOptions(auto_contrast=False, darkness_threshold=0.5),
    )

    assert summary.contour_count == 2
    assert len(program.polylines) == 2
    assert program.polygons == []
    assert all(polyline.role == "contour" for polyline in program.polylines)
    assert all(polyline.closed for polyline in program.polylines)


def test_auto_contrast_stretches_face_luminance_range() -> None:
    raw = LuminanceRaster(
        samples=[
            [0.62, 0.42],
            [0.52, 0.32],
        ]
    )
    direct, _ = build_paper_program_from_luminance_raster(
        raster=raw,
        options=RasterPolygonOptions(auto_contrast=False, darkness_threshold=0.0),
    )
    contrasted, _ = build_paper_program_from_luminance_raster(
        raster=raw,
        options=RasterPolygonOptions(auto_contrast=True, darkness_threshold=0.0),
    )

    assert max(polygon.shade for polygon in contrasted.polygons) > max(
        polygon.shade for polygon in direct.polygons
    )


def test_portrait_contours_trace_synthetic_relief_without_hatching() -> None:
    size = 24
    center = (size - 1) / 2
    samples = []
    for y in range(size):
        row = []
        for x in range(size):
            distance = ((x - center) ** 2 + (y - center) ** 2) ** 0.5 / center
            darkness = max(0.0, 1.0 - distance)
            row.append(1.0 - 0.72 * darkness)
        samples.append(row)

    program, summary = build_portrait_contour_program_from_luminance_raster(
        raster=LuminanceRaster(samples=samples),
        options=PortraitContourOptions(
            auto_contrast=False,
            illumination_radius=0,
            smoothing_radius=0,
            contour_levels=5,
            min_contour_length_norm=0.02,
        ),
    )

    assert summary.contour_count >= 3
    assert summary.raw_point_count > summary.kept_point_count >= 6
    assert program.polygons == []
    assert all(polyline.role == "contour" for polyline in program.polylines)
    assert any(polyline.closed for polyline in program.polylines)


def test_portrait_normalization_keeps_features_under_uneven_illumination() -> None:
    width = 28
    height = 36
    samples = []
    for y in range(height):
        row = []
        for x in range(width):
            gradient = 0.20 * (x / (width - 1))
            eye_shadow = 0.22 if 8 <= y <= 12 and x in range(8, 21) else 0.0
            nose_shadow = 0.18 if 14 <= y <= 24 and 12 <= x <= 15 else 0.0
            mouth_shadow = 0.20 if 25 <= y <= 28 and 9 <= x <= 19 else 0.0
            luminance = 0.74 + gradient - eye_shadow - nose_shadow - mouth_shadow
            row.append(max(0.0, min(1.0, luminance)))
        samples.append(row)

    program, summary = build_portrait_contour_program_from_luminance_raster(
        raster=LuminanceRaster(samples=samples),
        options=PortraitContourOptions(
            contour_levels=6,
            illumination_radius=5,
            illumination_strength=0.8,
            smoothing_radius=1,
            min_contour_length_norm=0.025,
        ),
    )

    assert summary.contour_count > 0
    assert summary.max_normalized_value > 0.85
    assert summary.min_normalized_value < 0.15
    assert len(program.polylines) == summary.contour_count


def test_raster_rejects_non_rectangular_samples() -> None:
    with pytest.raises(ValueError, match="same width"):
        LuminanceRaster(samples=[[0.1, 0.2], [0.3]])


def test_raster_polygon_limit_blocks_excessive_expansion() -> None:
    with pytest.raises(ValueError, match="exceeded 3 polygons"):
        build_paper_program_from_luminance_raster(
            raster=LuminanceRaster(samples=[[0.0, 0.0], [0.0, 0.0]]),
            options=RasterPolygonOptions(
                auto_contrast=False,
                darkness_threshold=0.0,
                triangulate=True,
                max_polygons=3,
            ),
        )
