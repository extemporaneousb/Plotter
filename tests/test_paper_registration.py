from __future__ import annotations

import pytest

from plotter_vision.calibration.paper import (
    DEFAULT_FIELD_HEIGHT_MM,
    DEFAULT_FIELD_WIDTH_MM,
    PaperCornerObservation,
    PaperPointMM,
    build_paper_frame_registration,
    paper_corner_norm,
)
from plotter_vision.calibration.vision_model import CameraPointNorm


def test_visual_field_registration_solves_homography_from_manual_corners() -> None:
    corners = [
        PaperCornerObservation(
            corner=corner,  # type: ignore[arg-type]
            expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
            observed_norm=CameraPointNorm(x=x, y=y),
        )
        for corner, x, y in [
            ("bottom_left", *_project_paper_to_camera(0.0, 0.0)),
            ("bottom_right", *_project_paper_to_camera(1.0, 0.0)),
            ("top_right", *_project_paper_to_camera(1.0, 1.0)),
            ("top_left", *_project_paper_to_camera(0.0, 1.0)),
        ]
    ]

    registration = build_paper_frame_registration(
        corners,
        paper_width_mm=DEFAULT_FIELD_WIDTH_MM,
        paper_height_mm=DEFAULT_FIELD_HEIGHT_MM,
    )

    assert registration.status == "locked"
    assert registration.paper_size_mm.width == pytest.approx(200.0)
    assert registration.paper_size_mm.height == pytest.approx(150.0)
    assert [observation.corner for observation in registration.corner_observations] == [
        "bottom_left",
        "bottom_right",
        "top_right",
        "top_left",
    ]
    assert registration.rms_error_norm == pytest.approx(0.0, abs=1e-12)
    assert registration.max_error_norm == pytest.approx(0.0, abs=1e-12)

    center_x, center_y = _project_paper_to_camera(0.5, 0.5)
    paper_center = registration.camera_norm_to_paper_mm(CameraPointNorm(x=center_x, y=center_y))
    assert paper_center.x == pytest.approx(100.0, abs=1e-9)
    assert paper_center.y == pytest.approx(75.0, abs=1e-9)

    origin = registration.camera_norm_to_paper_mm(
        CameraPointNorm(
            x=_project_paper_to_camera(0.0, 0.0)[0],
            y=_project_paper_to_camera(0.0, 0.0)[1],
        )
    )
    assert origin.x == pytest.approx(0.0, abs=1e-9)
    assert origin.y == pytest.approx(0.0, abs=1e-9)

    camera_top_right = registration.paper_mm_to_camera_norm(PaperPointMM(x=200.0, y=150.0))
    expected_top_right = _project_paper_to_camera(1.0, 1.0)
    assert camera_top_right.x == pytest.approx(expected_top_right[0], abs=1e-12)
    assert camera_top_right.y == pytest.approx(expected_top_right[1], abs=1e-12)


def test_visual_field_registration_honors_configured_field_size() -> None:
    registration = build_paper_frame_registration(
        _corner_observations(),
        paper_width_mm=240.0,
        paper_height_mm=120.0,
    )

    center_x, center_y = _project_paper_to_camera(0.5, 0.5)
    field_center = registration.camera_norm_to_paper_mm(CameraPointNorm(x=center_x, y=center_y))
    assert field_center.x == pytest.approx(120.0, abs=1e-9)
    assert field_center.y == pytest.approx(60.0, abs=1e-9)


def test_visual_field_registration_rejects_missing_corners() -> None:
    with pytest.raises(ValueError, match="four visual field corner observations"):
        build_paper_frame_registration(
            [
                PaperCornerObservation(
                    corner=corner,  # type: ignore[arg-type]
                    expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=x, y=y),
                )
                for corner, x, y in [
                    ("bottom_left", 0.1, 0.1),
                    ("bottom_right", 0.8, 0.1),
                    ("top_right", 0.8, 0.8),
                ]
            ],
            paper_width_mm=210.0,
            paper_height_mm=297.0,
        )


def test_visual_field_registration_rejects_crossed_corner_order() -> None:
    with pytest.raises(ValueError, match="crossed quadrilateral"):
        build_paper_frame_registration(
            [
                PaperCornerObservation(
                    corner=corner,  # type: ignore[arg-type]
                    expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=x, y=y),
                )
                for corner, x, y in [
                    ("bottom_left", 0.60, 0.20),
                    ("bottom_right", 0.49, 0.21),
                    ("top_right", 0.61, 0.70),
                    ("top_left", 0.49, 0.71),
                ]
            ],
            paper_width_mm=210.0,
            paper_height_mm=297.0,
        )


def test_visual_field_registration_rejects_concave_corner_order() -> None:
    with pytest.raises(ValueError, match="concave quadrilateral"):
        build_paper_frame_registration(
            [
                PaperCornerObservation(
                    corner=corner,  # type: ignore[arg-type]
                    expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=x, y=y),
                )
                for corner, x, y in [
                    ("bottom_left", 0.10, 0.10),
                    ("bottom_right", 0.90, 0.10),
                    ("top_right", 0.45, 0.20),
                    ("top_left", 0.10, 0.90),
                ]
            ],
            paper_width_mm=DEFAULT_FIELD_WIDTH_MM,
            paper_height_mm=DEFAULT_FIELD_HEIGHT_MM,
        )


def test_visual_field_registration_allows_reflected_convex_field() -> None:
    registration = build_paper_frame_registration(
        [
            PaperCornerObservation(
                corner=corner,  # type: ignore[arg-type]
                expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
                observed_norm=CameraPointNorm(x=x, y=y),
            )
            for corner, x, y in [
                ("bottom_left", 0.12, 0.86),
                ("bottom_right", 0.18, 0.14),
                ("top_right", 0.82, 0.12),
                ("top_left", 0.86, 0.84),
            ]
        ],
        paper_width_mm=DEFAULT_FIELD_WIDTH_MM,
        paper_height_mm=DEFAULT_FIELD_HEIGHT_MM,
    )

    assert registration.status == "locked"
    bottom_left = registration.paper_mm_to_camera_norm(PaperPointMM(x=0.0, y=0.0))
    assert bottom_left.x == pytest.approx(0.12, abs=1e-12)
    assert bottom_left.y == pytest.approx(0.86, abs=1e-12)


def test_visual_field_registration_rejects_degenerate_corners() -> None:
    with pytest.raises(ValueError, match="degenerate"):
        build_paper_frame_registration(
            [
                PaperCornerObservation(
                    corner=corner,  # type: ignore[arg-type]
                    expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
                    observed_norm=CameraPointNorm(x=x, y=y),
                )
                for corner, x, y in [
                    ("bottom_left", 0.10, 0.10),
                    ("bottom_right", 0.101, 0.10),
                    ("top_right", 0.102, 0.10),
                    ("top_left", 0.103, 0.10),
                ]
            ],
            paper_width_mm=DEFAULT_FIELD_WIDTH_MM,
            paper_height_mm=DEFAULT_FIELD_HEIGHT_MM,
        )


def _corner_observations() -> list[PaperCornerObservation]:
    return [
        PaperCornerObservation(
            corner=corner,  # type: ignore[arg-type]
            expected_paper_norm=paper_corner_norm(corner),  # type: ignore[arg-type]
            observed_norm=CameraPointNorm(x=x, y=y),
        )
        for corner, x, y in [
            ("bottom_left", *_project_paper_to_camera(0.0, 0.0)),
            ("bottom_right", *_project_paper_to_camera(1.0, 0.0)),
            ("top_right", *_project_paper_to_camera(1.0, 1.0)),
            ("top_left", *_project_paper_to_camera(0.0, 1.0)),
        ]
    ]


def _project_paper_to_camera(x_norm: float, y_norm: float) -> tuple[float, float]:
    denominator = 1.0 + 0.06 * x_norm - 0.04 * y_norm
    return (
        (0.16 + 0.68 * x_norm + 0.05 * y_norm) / denominator,
        (0.14 + 0.04 * x_norm + 0.70 * y_norm) / denominator,
    )
