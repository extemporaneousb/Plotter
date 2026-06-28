from __future__ import annotations

from plotter_vision.calibration.drawing_model import (
    DrawingCalibrationCoverage,
    DrawingCalibrationMetrics,
    DrawingCalibrationModel,
    DrawingCalibrationObservation,
    DrawingResidualGridNode,
    DrawingResidualGridV1,
    DrawingCalibrationSample,
)
from plotter_vision.calibration.drawing_session import (
    DrawingCalibrationBatch,
    DrawingCalibrationObservationRecord,
    DrawingCalibrationSession,
    choose_next_batch_purpose,
    plan_next_drawing_calibration_batch,
    record_batch_observation,
    schedule_retry_if_allowed,
    update_session_from_model,
)
from plotter_vision.calibration.paper import PaperPointMM


def test_adaptive_batch_policy_selects_bootstrap_then_coverage_then_validation() -> None:
    session = _session()

    assert choose_next_batch_purpose(session, model=None) == "bootstrap_sheet"

    session.observations.append(_record())
    sparse_model = _model(sample_count=8, coverage_fraction=0.2, max_uncertainty=8.0)
    assert choose_next_batch_purpose(session, model=sparse_model) == "coverage_fill"

    uncertain_model = _model(sample_count=40, coverage_fraction=0.8, max_uncertainty=30.0)
    assert choose_next_batch_purpose(session, model=uncertain_model) == "high_uncertainty_patch"

    ready_model = _model(sample_count=40, coverage_fraction=0.8, max_uncertainty=6.0)
    assert choose_next_batch_purpose(session, model=ready_model) == "direction_backlash_probe"

    session.batches.append(
        DrawingCalibrationBatch(
            batch_id="direction-batch",
            batch_index=1,
            purpose="direction_backlash_probe",
            program_kind="progressive_direction_backlash_probe",
        )
    )
    assert choose_next_batch_purpose(session, model=ready_model) == "validation_holdout"


def test_failed_validation_selects_more_evidence_and_retry_does_not_accept_model_evidence() -> None:
    session = _session()
    plan = plan_next_drawing_calibration_batch(session, model=None)
    weak = DrawingCalibrationObservation(
        paper_registration_id=session.paper_registration_id,
        camera_id=session.camera_id,
        field_width_mm=session.field_width_mm,
        field_height_mm=session.field_height_mm,
        observation_kind="mixed",
        samples=[],
        usable=False,
        blockers=["no green ink"],
    )

    record, reasons = record_batch_observation(session, observation=weak, batch_id=plan.batch.batch_id)
    retry = schedule_retry_if_allowed(session, batch_id=plan.batch.batch_id, reasons=reasons)

    assert retry is True
    assert record.disposition == "rejected"
    assert session.accepted_observations == []
    assert session.batches[0].retry_count == 1

    session.observations.append(_record())
    failed_validation = _model(
        sample_count=40,
        coverage_fraction=0.85,
        max_uncertainty=6.0,
        validation_max=24.0,
    )
    assert choose_next_batch_purpose(session, model=failed_validation) == "high_uncertainty_patch"


def test_session_stops_ready_when_completion_gates_pass() -> None:
    session = _session()
    model = _model(sample_count=48, coverage_fraction=0.9, max_uncertainty=6.0)

    update_session_from_model(session, model=model, promoting=True)

    assert session.status == "ready"
    assert session.promotion_status == "promoted"
    assert session.blockers == []


def _session() -> DrawingCalibrationSession:
    return DrawingCalibrationSession(
        paper_registration_id="reg-1",
        camera_id="plotter-camera",
        camera_name="Plotter Camera",
        field_width_mm=200.0,
        field_height_mm=150.0,
    )


def _record() -> DrawingCalibrationObservationRecord:
    return DrawingCalibrationObservationRecord(
        observation_id="obs-1",
        batch_id="batch-1",
        disposition="accepted",
        observation=DrawingCalibrationObservation(
            paper_registration_id="reg-1",
            camera_id="plotter-camera",
            field_width_mm=200.0,
            field_height_mm=150.0,
            observation_kind="synthetic",
            samples=[
                DrawingCalibrationSample(
                    sample_kind="mark",
                    expected_mm=PaperPointMM(x=20.0, y=20.0),
                    observed_mm=PaperPointMM(x=21.0, y=20.0),
                )
            ],
        ),
    )


def _model(
    *,
    sample_count: int,
    coverage_fraction: float,
    max_uncertainty: float,
    validation_max: float = 4.0,
) -> DrawingCalibrationModel:
    return DrawingCalibrationModel(
        paper_registration_id="reg-1",
        camera_id="plotter-camera",
        field_width_mm=200.0,
        field_height_mm=150.0,
        validation_status="ready",
        freshness_status="fresh",
        sample_count=sample_count,
        residual_grid=DrawingResidualGridV1(
            columns=5,
            rows=5,
            field_width_mm=200.0,
            field_height_mm=150.0,
            coverage_radius_mm=50.0,
            nodes=[
                DrawingResidualGridNode(
                    index_x=x_index,
                    index_y=y_index,
                    x_mm=200.0 * x_index / 4.0,
                    y_mm=150.0 * y_index / 4.0,
                    residual_x_mm=0.0,
                    residual_y_mm=0.0,
                    source_sample_count=1,
                    uncertainty_mm=max_uncertainty if x_index == 4 and y_index == 4 else 2.0,
                )
                for y_index in range(5)
                for x_index in range(5)
            ],
        ),
        coverage=DrawingCalibrationCoverage(
            field_width_mm=200.0,
            field_height_mm=150.0,
            sample_count=sample_count,
            accepted_sample_count=sample_count,
            total_node_count=25,
            covered_node_count=int(coverage_fraction * 25),
            coverage_fraction=coverage_fraction,
            max_node_uncertainty_mm=max_uncertainty,
        ),
        fit_metrics=DrawingCalibrationMetrics(
            sample_count=sample_count,
            rms_mm=1.0,
            p95_mm=2.0,
            max_mm=3.0,
        ),
        validation_metrics=DrawingCalibrationMetrics(
            sample_count=6,
            rms_mm=1.0,
            p95_mm=2.0,
            max_mm=validation_max,
        ),
    )
