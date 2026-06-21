from __future__ import annotations

from plotter_vision.calibration.binding import (
    ObservedGeometrySample,
    VisualPositionBinding,
    solve_visual_position_binding,
)
from plotter_vision.calibration.paper import PaperPointMM
from plotter_vision.drawing import DrawingFrameMM


def test_visual_position_binding_validates_affine_residuals() -> None:
    binding = _binding()
    for index, (x_mm, y_mm) in enumerate(
        [
            (20.0, 20.0),
            (140.0, 20.0),
            (140.0, 120.0),
            (20.0, 120.0),
            (80.0, 70.0),
        ],
        start=1,
    ):
        binding.observed_geometry.append(
            ObservedGeometrySample(
                command_id="cmd-test",
                point_id=f"P{index}",
                kind="ink",
                expected_paper_mm=PaperPointMM(x=x_mm, y=y_mm),
                observed_paper_mm=PaperPointMM(x=x_mm + 1.5, y=y_mm - 2.0),
                camera_id="cam-1",
                paper_registration_id="paper-1",
            )
        )

    solved = solve_visual_position_binding(
        binding,
        current_paper_registration_id="paper-1",
        current_camera_id="cam-1",
    )

    assert solved.validation_status == "validated"
    assert solved.learned_transform is not None
    assert solved.residuals.observation_count == 5
    assert solved.residuals.non_collinear is True
    assert set(solved.residuals.axes_represented) == {"X", "Y"}
    assert solved.residuals.rms_residual_mm is not None
    assert solved.residuals.rms_residual_mm < 1e-9


def test_visual_position_binding_blocks_collinear_observations() -> None:
    binding = _binding()
    for index, x_mm in enumerate([10.0, 20.0, 30.0, 40.0, 50.0], start=1):
        binding.observed_geometry.append(
            ObservedGeometrySample(
                command_id="cmd-line",
                point_id=f"P{index}",
                kind="pen_tip",
                expected_paper_mm=PaperPointMM(x=x_mm, y=25.0),
                observed_paper_mm=PaperPointMM(x=x_mm, y=25.0),
                camera_id="cam-1",
                paper_registration_id="paper-1",
            )
        )

    solved = solve_visual_position_binding(
        binding,
        current_paper_registration_id="paper-1",
        current_camera_id="cam-1",
    )

    assert solved.validation_status == "blocked"
    assert solved.learned_transform is None
    assert any("non-collinear" in blocker for blocker in solved.blockers)
    assert any("both X and Y axes" in blocker for blocker in solved.blockers)


def _binding() -> VisualPositionBinding:
    return VisualPositionBinding(
        paper_registration_id="paper-1",
        camera={"camera_id": "cam-1", "camera_name": "Fixed Camera"},
        drawing_frame=DrawingFrameMM(
            origin_x_mm=0.0,
            origin_y_mm=0.0,
            width_mm=200.0,
            height_mm=150.0,
        ),
    )
