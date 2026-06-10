from __future__ import annotations

import pytest

from plotter_vision.drawing import (
    LuminanceRaster,
    RasterPolygonOptions,
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
