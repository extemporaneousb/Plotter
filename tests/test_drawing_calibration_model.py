from __future__ import annotations

import math

import pytest

from plotter_vision.calibration.drawing_model import (
    DrawingCalibrationActionMetadata,
    DrawingCalibrationObservation,
    DrawingCalibrationSample,
    build_drawing_calibration_model,
)
from plotter_vision.calibration.paper import PaperPointMM

FIELD_WIDTH_MM = 200.0
FIELD_HEIGHT_MM = 150.0


def test_affine_only_samples_solve_global_model_and_inverse_correction() -> None:
    model = _build_model(_sample_grid(_affine_observed, columns=5, rows=5))

    assert model.validation_status == "ready"
    assert model.model_version == "residual_grid_v1"
    assert model.solver_kind == "residual_grid_v1"
    assert model.expected_to_observed is not None
    assert model.residual_grid is not None
    assert model.residual_grid.columns == 5
    assert model.fit_metrics is not None
    assert model.fit_metrics.rms_mm == pytest.approx(0.0, abs=0.35)

    expected = PaperPointMM(x=87.0, y=63.0)
    predicted = model.apply_expected_to_observed(expected)
    observed_x, observed_y = _affine_observed(expected.x, expected.y)
    assert predicted.x == pytest.approx(observed_x, abs=0.35)
    assert predicted.y == pytest.approx(observed_y, abs=0.35)

    correction = model.correct_target_for_planning(PaperPointMM(x=100.0, y=75.0))
    assert correction.usable
    assert correction.commanded_mm.x != pytest.approx(100.0)
    assert correction.predicted_observed_mm is not None
    assert correction.predicted_observed_mm.x == pytest.approx(100.0, abs=0.08)
    assert correction.predicted_observed_mm.y == pytest.approx(75.0, abs=0.08)


def test_nonlinear_warp_uses_residual_grid_and_reports_holdout_metrics() -> None:
    fit_samples = _sample_grid(_nonlinear_observed, columns=7, rows=7)
    holdout_samples = [
        _sample(25.0, 22.0, _nonlinear_observed, role="holdout"),
        _sample(92.0, 47.0, _nonlinear_observed, role="holdout"),
        _sample(137.0, 103.0, _nonlinear_observed, role="holdout"),
        _sample(175.0, 128.0, _nonlinear_observed, role="holdout"),
    ]
    model = _build_model(
        fit_samples + holdout_samples,
        residual_grid_columns=7,
        residual_grid_rows=7,
    )

    assert model.validation_status == "ready"
    assert model.residual_grid is not None
    assert model.fit_metrics is not None
    assert model.holdout_metrics is not None
    assert model.fit_metrics.rms_mm is not None and model.fit_metrics.rms_mm < 0.8
    assert model.holdout_metrics.rms_mm is not None and model.holdout_metrics.rms_mm < 1.8
    assert model.coverage is not None
    assert model.coverage.coverage_fraction > 0.8

    target = PaperPointMM(x=120.0, y=85.0)
    correction = model.correct_target_for_planning(target)
    assert correction.usable
    assert correction.predicted_observed_mm is not None
    assert correction.predicted_observed_mm.x == pytest.approx(target.x, abs=0.35)
    assert correction.predicted_observed_mm.y == pytest.approx(target.y, abs=0.35)


def test_sparse_samples_do_not_claim_ready_model() -> None:
    samples = [
        _sample(0.0, 0.0, _affine_observed),
        _sample(FIELD_WIDTH_MM, 0.0, _affine_observed),
        _sample(0.0, FIELD_HEIGHT_MM, _affine_observed),
    ]

    model = _build_model(samples)

    assert model.validation_status == "needs_more_evidence"
    assert model.residual_grid is None
    assert model.blockers == ["At least four fit samples are required for drawing calibration."]


def test_outlier_rejection_excludes_bad_sample_before_grid_fit() -> None:
    samples = _sample_grid(_affine_observed, columns=5, rows=5)
    samples.append(
        DrawingCalibrationSample(
            sample_id="bad-center",
            sample_kind="mark",
            expected_mm=PaperPointMM(x=100.0, y=75.0),
            observed_mm=PaperPointMM(x=170.0, y=18.0),
        )
    )

    model = _build_model(samples)

    assert model.validation_status == "ready"
    assert model.rejected_sample_count == 1
    assert model.rejected_sample_ids == ["bad-center"]
    assert model.fit_metrics is not None
    assert model.fit_metrics.max_mm is not None and model.fit_metrics.max_mm < 1.0


def test_holdout_failure_blocks_model_even_when_fit_samples_are_good() -> None:
    samples = _sample_grid(_affine_observed, columns=5, rows=5)
    samples.append(
        DrawingCalibrationSample(
            sample_id="bad-holdout",
            sample_kind="mark",
            expected_mm=PaperPointMM(x=97.0, y=61.0),
            observed_mm=PaperPointMM(x=150.0, y=10.0),
            role="holdout",
        )
    )

    model = _build_model(samples)

    assert model.validation_status == "blocked"
    assert model.holdout_metrics is not None
    assert model.holdout_metrics.max_mm is not None and model.holdout_metrics.max_mm > 50.0
    assert any("holdout" in blocker for blocker in model.blockers)


def test_stale_registration_observations_are_rejected() -> None:
    observation = _observation(_sample_grid(_affine_observed, columns=5, rows=5), registration_id="old-reg")

    model = build_drawing_calibration_model(
        observations=[observation],
        paper_registration_id="current-reg",
        camera_id="plotter-cam",
        camera_name="Plotter Cam",
        field_width_mm=FIELD_WIDTH_MM,
        field_height_mm=FIELD_HEIGHT_MM,
    )

    assert model.validation_status == "blocked"
    assert model.freshness_status == "stale"
    assert model.sample_count == 0
    assert not model.is_fresh_for(paper_registration_id="current-reg", camera_id="plotter-cam")
    assert any("paper_registration_id" in reason for reason in model.stale_reasons)


def _build_model(
    samples: list[DrawingCalibrationSample],
    *,
    residual_grid_columns: int = 5,
    residual_grid_rows: int = 5,
):
    return build_drawing_calibration_model(
        observations=[_observation(samples)],
        paper_registration_id="reg-1",
        camera_id="plotter-cam",
        camera_name="Plotter Cam",
        field_width_mm=FIELD_WIDTH_MM,
        field_height_mm=FIELD_HEIGHT_MM,
        residual_grid_columns=residual_grid_columns,
        residual_grid_rows=residual_grid_rows,
    )


def _observation(
    samples: list[DrawingCalibrationSample],
    *,
    registration_id: str = "reg-1",
) -> DrawingCalibrationObservation:
    return DrawingCalibrationObservation(
        paper_registration_id=registration_id,
        camera_id="plotter-cam",
        camera_name="Plotter Cam",
        field_width_mm=FIELD_WIDTH_MM,
        field_height_mm=FIELD_HEIGHT_MM,
        observation_kind="synthetic",
        action_metadata=DrawingCalibrationActionMetadata(action_kind="synthetic"),
        samples=samples,
    )


def _sample_grid(
    observed_fn,
    *,
    columns: int,
    rows: int,
) -> list[DrawingCalibrationSample]:
    samples: list[DrawingCalibrationSample] = []
    for y_index in range(rows):
        y = FIELD_HEIGHT_MM * y_index / (rows - 1)
        for x_index in range(columns):
            x = FIELD_WIDTH_MM * x_index / (columns - 1)
            samples.append(_sample(x, y, observed_fn))
    return samples


def _sample(
    x_mm: float,
    y_mm: float,
    observed_fn,
    *,
    role: str = "fit",
) -> DrawingCalibrationSample:
    observed_x, observed_y = observed_fn(x_mm, y_mm)
    return DrawingCalibrationSample(
        sample_kind="mark",
        expected_mm=PaperPointMM(x=x_mm, y=y_mm),
        observed_mm=PaperPointMM(x=observed_x, y=observed_y),
        role=role,  # type: ignore[arg-type]
    )


def _affine_observed(x_mm: float, y_mm: float) -> tuple[float, float]:
    return (
        4.0 + 1.012 * x_mm - 0.009 * y_mm,
        -3.0 + 0.007 * x_mm + 0.991 * y_mm,
    )


def _nonlinear_observed(x_mm: float, y_mm: float) -> tuple[float, float]:
    base_x, base_y = _affine_observed(x_mm, y_mm)
    nx = x_mm / FIELD_WIDTH_MM
    ny = y_mm / FIELD_HEIGHT_MM
    return (
        base_x + 2.8 * math.sin(math.pi * nx) * math.sin(math.pi * ny),
        base_y - 2.1 * math.sin(2.0 * math.pi * nx) * math.sin(math.pi * ny),
    )
