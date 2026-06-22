from __future__ import annotations

import pytest

from plotter_vision.calibration.paper import (
    PaperCornerObservation,
    PaperPointMM,
    build_paper_frame_registration,
    paper_corner_norm,
)
from plotter_vision.calibration.vision_model import CameraPointNorm


def test_paper_registration_solves_homography_from_manual_corners() -> None:
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
        paper_width_mm=210.0,
        paper_height_mm=297.0,
    )

    assert registration.status == "locked"
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
    assert paper_center.x == pytest.approx(105.0, abs=1e-9)
    assert paper_center.y == pytest.approx(148.5, abs=1e-9)

    camera_top_right = registration.paper_mm_to_camera_norm(PaperPointMM(x=210.0, y=297.0))
    expected_top_right = _project_paper_to_camera(1.0, 1.0)
    assert camera_top_right.x == pytest.approx(expected_top_right[0], abs=1e-12)
    assert camera_top_right.y == pytest.approx(expected_top_right[1], abs=1e-12)


def test_paper_registration_rejects_missing_corners() -> None:
    with pytest.raises(ValueError, match="four paper corner observations"):
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


def test_paper_registration_rejects_crossed_corner_order() -> None:
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


def _project_paper_to_camera(x_norm: float, y_norm: float) -> tuple[float, float]:
    denominator = 1.0 + 0.06 * x_norm - 0.04 * y_norm
    return (
        (0.16 + 0.68 * x_norm + 0.05 * y_norm) / denominator,
        (0.14 + 0.04 * x_norm + 0.70 * y_norm) / denominator,
    )
