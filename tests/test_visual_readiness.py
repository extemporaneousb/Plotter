from __future__ import annotations

from pathlib import Path
from typing import Literal

import pytest

from plotter_vision.calibration.readiness import (
    DrawingSafeZone,
    RelativeMotionModel,
    SafeZoneMarginsMM,
    VisualCapObservation,
    VisualReadinessState,
    build_visual_readiness_state,
    evaluate_cap_inside_safe_zone,
)
from plotter_vision.calibration.probe_evidence import (
    VisualProbeCapSnapshot,
    VisualProbeRun,
    VisualProbeSample,
)
from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    PaperPointNorm,
)
from plotter_vision.drawing import DrawingFrameMM


def test_visual_cap_inside_safe_zone_is_accepted() -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.50, paper_y=0.50, logical_x=250.0, logical_y=100.0)

    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)

    assert evaluation.inside is True
    assert evaluation.abort_reasons == []
    assert evaluation.logical_mm == LogicalPointMM(x=250.0, y=100.0)


def test_visual_cap_outside_safe_zone_has_explicit_abort_reasons() -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.02, paper_y=0.98, logical_x=10.0, logical_y=198.0)

    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)

    assert evaluation.inside is False
    assert [reason.code for reason in evaluation.abort_reasons] == [
        "cap_paper_x_below_safe_zone",
        "cap_paper_y_above_safe_zone",
        "cap_logical_x_below_safe_zone",
        "cap_logical_y_above_safe_zone",
    ]
    assert "below safe zone minimum" in evaluation.abort_reasons[0].message
    assert "above safe zone maximum" in evaluation.abort_reasons[-1].message


def test_visual_readiness_serialization_round_trip(tmp_path: Path) -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.50, paper_y=0.50, logical_x=250.0, logical_y=100.0)
    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)
    readiness = build_visual_readiness_state(
        paper_registered=True,
        cap_observation=observation,
        safe_zone_evaluation=evaluation,
        probe_observation_count=2,
        probe_rms_residual_mm=1.2,
        probe_p95_residual_mm=2.0,
        probe_max_residual_mm=2.4,
        relative_motion_model=_motion_model(rms=1.2, p95=2.0, max_residual=2.4),
    )

    path = tmp_path / "visual_readiness.json"
    readiness.save_json(path)

    loaded = VisualReadinessState.load_json(path)
    assert loaded == readiness
    assert loaded.visual_ready_to_plot is True
    assert loaded.blockers == []


def test_visual_readiness_reports_blockers_without_homing_or_axis_trust() -> None:
    readiness = build_visual_readiness_state(
        paper_registered=False,
        cap_observation=None,
        safe_zone_evaluation=None,
        probe_observation_count=0,
    )

    assert readiness.visual_ready_to_plot is False
    assert readiness.paper_registered is False
    assert readiness.cap_localized is False
    assert readiness.cap_inside_safe_zone is False
    assert any("Visual field registration" in blocker for blocker in readiness.blockers)
    assert any("Green cap/carriage marker is not localized" in blocker for blocker in readiness.blockers)
    assert any("at least 2 observations" in blocker for blocker in readiness.blockers)
    assert "homing_trusted" not in readiness.model_dump()
    assert "axis_model_trusted" not in readiness.model_dump()


def test_visual_readiness_blocks_high_probe_residuals() -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.50, paper_y=0.50, logical_x=250.0, logical_y=100.0)
    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)

    readiness = build_visual_readiness_state(
        paper_registered=True,
        cap_observation=observation,
        safe_zone_evaluation=evaluation,
        probe_observation_count=2,
        probe_rms_residual_mm=11.1,
        probe_p95_residual_mm=21.0,
        probe_max_residual_mm=21.0,
        relative_motion_model=_motion_model(rms=11.1, p95=21.0, max_residual=21.0),
    )

    assert readiness.visual_ready_to_plot is False
    assert any("RMS residual" in blocker for blocker in readiness.blockers)
    assert any("p95 residual" in blocker for blocker in readiness.blockers)


def test_visual_readiness_tolerates_single_probe_residual_outlier() -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.50, paper_y=0.50, logical_x=250.0, logical_y=100.0)
    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)

    readiness = build_visual_readiness_state(
        paper_registered=True,
        cap_observation=observation,
        safe_zone_evaluation=evaluation,
        probe_observation_count=27,
        probe_rms_residual_mm=3.2,
        probe_p95_residual_mm=5.8,
        probe_max_residual_mm=9.1,
        relative_motion_model=_motion_model(rms=3.2, p95=5.8, max_residual=9.1),
    )

    assert readiness.visual_ready_to_plot is True
    assert readiness.blockers == []


def test_visual_readiness_blocks_hard_probe_residual_outlier() -> None:
    safe_zone = _safe_zone()
    observation = _cap(paper_x=0.50, paper_y=0.50, logical_x=250.0, logical_y=100.0)
    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)

    readiness = build_visual_readiness_state(
        paper_registered=True,
        cap_observation=observation,
        safe_zone_evaluation=evaluation,
        probe_observation_count=27,
        probe_rms_residual_mm=3.2,
        probe_p95_residual_mm=5.8,
        probe_max_residual_mm=45.0,
        relative_motion_model=_motion_model(rms=3.2, p95=5.8, max_residual=45.0),
    )

    assert readiness.visual_ready_to_plot is False
    assert any("hard max residual" in blocker for blocker in readiness.blockers)


def test_visual_probe_artifact_serialization_round_trip(tmp_path: Path) -> None:
    sample = _probe_sample(
        run_id="probe-run-test",
        sample_id="sample-1",
        axis="X",
        commanded_dx=25.0,
        commanded_dy=0.0,
        before_x=100.0,
        before_y=80.0,
        after_x=124.0,
        after_y=81.0,
    )
    run = VisualProbeRun(run_id="probe-run-test")
    run.upsert_sample(
        sample,
        current_paper_registration_id="paper-1",
        current_camera_id="cam-1",
    )

    path = tmp_path / "probe-run.json"
    run.save_json(path)

    loaded = VisualProbeRun.load_json(path)
    assert loaded == run
    assert loaded.summary.raw_sample_count == 1
    assert loaded.summary.accepted_sample_count == 1
    assert loaded.samples[0].observed_dx_mm == pytest.approx(24.0)
    assert loaded.samples[0].observed_distance_mm == pytest.approx((24.0**2 + 1.0**2) ** 0.5)
    assert loaded.summary.p95_residual_mm is None


def _safe_zone() -> DrawingSafeZone:
    return DrawingSafeZone.from_frame(
        drawing_frame=DrawingFrameMM(
            origin_x_mm=0.0,
            origin_y_mm=0.0,
            width_mm=500.0,
            height_mm=200.0,
        ),
        margins_mm=SafeZoneMarginsMM(left=20.0, right=40.0, bottom=10.0, top=20.0),
    )


def _cap(
    *,
    paper_x: float,
    paper_y: float,
    logical_x: float,
    logical_y: float,
) -> VisualCapObservation:
    return VisualCapObservation(
        camera_norm=CameraPointNorm(x=paper_x, y=paper_y),
        paper_norm=PaperPointNorm(x=paper_x, y=paper_y),
        logical_mm=LogicalPointMM(x=logical_x, y=logical_y),
        camera_id="cam-1",
        camera_name="Fixed Camera",
        confidence=0.94,
        source="operator_confirmed",
    )


def _motion_model(*, rms: float, p95: float, max_residual: float) -> RelativeMotionModel:
    return RelativeMotionModel(
        machine_to_field_matrix=((1.0, 0.0), (0.0, 1.0)),
        field_to_machine_matrix=((1.0, 0.0), (0.0, 1.0)),
        determinant=1.0,
        sample_count=4,
        rms_residual_mm=rms,
        p95_residual_mm=p95,
        max_residual_mm=max_residual,
    )


def _probe_sample(
    *,
    run_id: str,
    sample_id: str,
    axis: Literal["X", "Y"],
    commanded_dx: float,
    commanded_dy: float,
    before_x: float,
    before_y: float,
    after_x: float,
    after_y: float,
) -> VisualProbeSample:
    return VisualProbeSample(
        run_id=run_id,
        sample_id=sample_id,
        paper_registration_id="paper-1",
        camera_id="cam-1",
        camera_name="Fixed Camera",
        source="motion_probe",
        axis=axis,
        commanded_dx_mm=commanded_dx,
        commanded_dy_mm=commanded_dy,
        before=_probe_snapshot(before_x, before_y, frame=1),
        after=_probe_snapshot(after_x, after_y, frame=2),
    )


def _probe_snapshot(x: float, y: float, *, frame: int) -> VisualProbeCapSnapshot:
    return VisualProbeCapSnapshot(
        camera_norm=CameraPointNorm(x=x / 500.0, y=y / 200.0),
        paper_norm=PaperPointNorm(x=x / 500.0, y=y / 200.0),
        logical_mm=LogicalPointMM(x=x, y=y),
        frame_id=frame,
        confidence=0.9,
    )
