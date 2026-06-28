from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.drawing_model import (
    DrawingCalibrationCorrectionMode,
    DrawingCalibrationMetrics,
    DrawingCalibrationModel,
    DrawingCalibrationObservation,
)
from plotter_vision.controller.base import utc_now_iso
from plotter_vision.drawing import (
    DrawingProgram,
    PaperPointNorm,
    PointMarkPrimitive,
    PolylinePrimitive,
)

DRAWING_CALIBRATION_SESSION_SCHEMA_VERSION = 1
DEFAULT_DRAWING_SESSION_MAX_RETRIES = 2
DEFAULT_DRAWING_SESSION_MIN_SAMPLE_COUNT = 24
DEFAULT_DRAWING_SESSION_MIN_COVERAGE_FRACTION = 0.6
DEFAULT_DRAWING_SESSION_MAX_NODE_UNCERTAINTY_MM = 14.0
DEFAULT_DRAWING_SESSION_FIT_RMS_LIMIT_MM = 3.5
DEFAULT_DRAWING_SESSION_FIT_P95_LIMIT_MM = 6.0
DEFAULT_DRAWING_SESSION_FIT_MAX_LIMIT_MM = 10.0
DEFAULT_DRAWING_SESSION_VALIDATION_RMS_LIMIT_MM = 4.0
DEFAULT_DRAWING_SESSION_VALIDATION_P95_LIMIT_MM = 7.0
DEFAULT_DRAWING_SESSION_VALIDATION_MAX_LIMIT_MM = 12.0

DrawingCalibrationSessionStatus = Literal[
    "idle",
    "collecting",
    "awaiting_observation",
    "fitting",
    "validating",
    "ready",
    "blocked",
]
DrawingCalibrationBatchPurpose = Literal[
    "bootstrap_sheet",
    "coverage_fill",
    "high_uncertainty_patch",
    "direction_backlash_probe",
    "validation_holdout",
]
DrawingCalibrationObservationDisposition = Literal["raw", "accepted", "rejected"]


class DrawingCalibrationCompletionCriteria(BaseModel):
    min_sample_count: int = DEFAULT_DRAWING_SESSION_MIN_SAMPLE_COUNT
    min_coverage_fraction: float = DEFAULT_DRAWING_SESSION_MIN_COVERAGE_FRACTION
    max_node_uncertainty_mm: float = DEFAULT_DRAWING_SESSION_MAX_NODE_UNCERTAINTY_MM
    fit_rms_limit_mm: float = DEFAULT_DRAWING_SESSION_FIT_RMS_LIMIT_MM
    fit_p95_limit_mm: float = DEFAULT_DRAWING_SESSION_FIT_P95_LIMIT_MM
    fit_max_limit_mm: float = DEFAULT_DRAWING_SESSION_FIT_MAX_LIMIT_MM
    validation_rms_limit_mm: float = DEFAULT_DRAWING_SESSION_VALIDATION_RMS_LIMIT_MM
    validation_p95_limit_mm: float = DEFAULT_DRAWING_SESSION_VALIDATION_P95_LIMIT_MM
    validation_max_limit_mm: float = DEFAULT_DRAWING_SESSION_VALIDATION_MAX_LIMIT_MM
    max_retries_per_batch: int = DEFAULT_DRAWING_SESSION_MAX_RETRIES


class DrawingCalibrationBatch(BaseModel):
    batch_id: str
    batch_index: int
    purpose: DrawingCalibrationBatchPurpose
    program_kind: str
    correction_mode: DrawingCalibrationCorrectionMode = "uncorrected"
    model_id_used: str | None = None
    command_id: str | None = None
    plan_hash: str | None = None
    retry_count: int = 0
    max_retries: int = DEFAULT_DRAWING_SESSION_MAX_RETRIES
    status: Literal["planned", "running", "awaiting_observation", "accepted", "retry", "blocked"] = "planned"
    expected_primitives: list[dict[str, Any]] = Field(default_factory=list)
    planned_trace_summary: dict[str, Any] = Field(default_factory=dict)
    observation_summary: dict[str, Any] = Field(default_factory=dict)
    fit_metrics: DrawingCalibrationMetrics | None = None
    validation_metrics: DrawingCalibrationMetrics | None = None
    blockers: list[str] = Field(default_factory=list)

    @field_validator("batch_index", "retry_count", "max_retries")
    @classmethod
    def _validate_non_negative(cls, value: int) -> int:
        if value < 0:
            raise ValueError("batch counters must be non-negative.")
        return value


class DrawingCalibrationRetryRecord(BaseModel):
    retry_id: str = Field(default_factory=lambda: f"drawing-retry-{uuid.uuid4().hex[:12]}")
    batch_id: str
    retry_index: int
    reason: str
    recorded_at: str = Field(default_factory=utc_now_iso)


class DrawingCalibrationObservationRecord(BaseModel):
    observation_id: str
    batch_id: str | None = None
    disposition: DrawingCalibrationObservationDisposition = "raw"
    reasons: list[str] = Field(default_factory=list)
    recorded_at: str = Field(default_factory=utc_now_iso)
    observation: DrawingCalibrationObservation


class DrawingCalibrationBatchPlan(BaseModel):
    batch: DrawingCalibrationBatch
    program: DrawingProgram


class DrawingCalibrationSession(BaseModel):
    schema_version: int = DRAWING_CALIBRATION_SESSION_SCHEMA_VERSION
    artifact_type: Literal["drawing_calibration_session"] = "drawing_calibration_session"
    session_id: str = Field(default_factory=lambda: f"drawing-session-{uuid.uuid4().hex[:12]}")
    status: DrawingCalibrationSessionStatus = "collecting"
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    field_width_mm: float
    field_height_mm: float
    started_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    latest_model_id: str | None = None
    current_batch_id: str | None = None
    batches: list[DrawingCalibrationBatch] = Field(default_factory=list)
    observations: list[DrawingCalibrationObservationRecord] = Field(default_factory=list)
    retry_history: list[DrawingCalibrationRetryRecord] = Field(default_factory=list)
    blockers: list[str] = Field(default_factory=list)
    completion_criteria: DrawingCalibrationCompletionCriteria = Field(
        default_factory=DrawingCalibrationCompletionCriteria
    )
    promotion_status: Literal["not_promoted", "candidate", "promoted", "blocked"] = "not_promoted"

    @field_validator("field_width_mm", "field_height_mm")
    @classmethod
    def _validate_field_dimension(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("drawing calibration session field dimensions must be positive.")
        return value

    @model_validator(mode="after")
    def _validate_current_batch(self) -> DrawingCalibrationSession:
        if self.current_batch_id and not any(batch.batch_id == self.current_batch_id for batch in self.batches):
            raise ValueError("current_batch_id must reference a session batch.")
        return self

    @property
    def accepted_observations(self) -> list[DrawingCalibrationObservation]:
        return [
            record.observation
            for record in self.observations
            if record.disposition == "accepted"
        ]

    def mark_updated(self) -> None:
        self.updated_at = utc_now_iso()

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> DrawingCalibrationSession:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def stale_reasons_for(
        self,
        *,
        paper_registration_id: str,
        camera_id: str | None,
        field_width_mm: float,
        field_height_mm: float,
    ) -> list[str]:
        reasons: list[str] = []
        if self.paper_registration_id != paper_registration_id:
            reasons.append("Drawing calibration session paper_registration_id does not match the current Drawing Border.")
        if camera_id is not None and self.camera_id is not None and self.camera_id != camera_id:
            reasons.append("Drawing calibration session camera_id does not match the current plotter camera.")
        if abs(self.field_width_mm - field_width_mm) > 1e-6 or abs(self.field_height_mm - field_height_mm) > 1e-6:
            reasons.append("Drawing calibration session field size does not match the current Drawing Border.")
        return reasons


def session_path(calibration_dir: Path, session_id: str) -> Path:
    if "/" in session_id or ".." in session_id:
        raise ValueError("Invalid drawing calibration session_id.")
    return calibration_dir / "drawing_calibration_sessions" / f"{session_id}.json"


def latest_session_path(calibration_dir: Path) -> Path:
    return calibration_dir / "latest_drawing_calibration_session.json"


def save_drawing_calibration_session(
    session: DrawingCalibrationSession,
    *,
    calibration_dir: Path,
) -> None:
    session.mark_updated()
    session.save_json(session_path(calibration_dir, session.session_id))
    session.save_json(latest_session_path(calibration_dir))


def load_latest_drawing_calibration_session(
    *,
    calibration_dir: Path,
) -> DrawingCalibrationSession:
    path = latest_session_path(calibration_dir)
    if not path.exists():
        raise ValueError("No drawing calibration session has been saved.")
    return DrawingCalibrationSession.load_json(path)


def load_latest_drawing_calibration_session_or_none(
    *,
    calibration_dir: Path,
) -> DrawingCalibrationSession | None:
    try:
        return load_latest_drawing_calibration_session(calibration_dir=calibration_dir)
    except Exception:
        return None


def start_drawing_calibration_session(
    *,
    paper_registration_id: str,
    camera_id: str | None,
    camera_name: str | None,
    field_width_mm: float,
    field_height_mm: float,
    existing: DrawingCalibrationSession | None = None,
) -> DrawingCalibrationSession:
    if existing is not None and not existing.stale_reasons_for(
        paper_registration_id=paper_registration_id,
        camera_id=camera_id,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    ):
        existing.status = "collecting" if existing.status in {"idle", "blocked"} else existing.status
        existing.mark_updated()
        return existing
    return DrawingCalibrationSession(
        paper_registration_id=paper_registration_id,
        camera_id=camera_id,
        camera_name=camera_name,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    )


def plan_next_drawing_calibration_batch(
    session: DrawingCalibrationSession,
    *,
    model: DrawingCalibrationModel | None = None,
    correction_mode: DrawingCalibrationCorrectionMode | None = None,
) -> DrawingCalibrationBatchPlan:
    purpose = choose_next_batch_purpose(session, model=model)
    batch_index = len(session.batches) + 1
    batch_id = f"{session.session_id}-batch-{batch_index:03d}"
    resolved_correction_mode = correction_mode or _default_correction_mode_for_purpose(purpose, model)
    model_id_used = model.model_id if model is not None and resolved_correction_mode != "uncorrected" else None
    program = build_drawing_calibration_batch_program(
        session=session,
        batch_id=batch_id,
        purpose=purpose,
        model=model,
    )
    expected_primitives = _program_expected_primitives(program)
    batch = DrawingCalibrationBatch(
        batch_id=batch_id,
        batch_index=batch_index,
        purpose=purpose,
        program_kind=f"progressive_{purpose}",
        correction_mode=resolved_correction_mode,
        model_id_used=model_id_used,
        max_retries=session.completion_criteria.max_retries_per_batch,
        expected_primitives=expected_primitives,
    )
    session.batches.append(batch)
    session.current_batch_id = batch.batch_id
    session.status = "collecting"
    session.mark_updated()
    return DrawingCalibrationBatchPlan(batch=batch, program=program)


def choose_next_batch_purpose(
    session: DrawingCalibrationSession,
    *,
    model: DrawingCalibrationModel | None = None,
) -> DrawingCalibrationBatchPurpose:
    if not session.accepted_observations:
        return "bootstrap_sheet"
    if model is None or model.residual_grid is None or model.coverage is None:
        return "coverage_fill"
    criteria = session.completion_criteria
    validation_failed = (
        model.validation_metrics is not None
        and model.validation_metrics.max_mm is not None
        and model.validation_metrics.max_mm > criteria.validation_max_limit_mm
    )
    if validation_failed:
        return "high_uncertainty_patch"
    if model.sample_count < criteria.min_sample_count:
        return "coverage_fill"
    if model.coverage.coverage_fraction < criteria.min_coverage_fraction:
        return "coverage_fill"
    if (
        model.coverage.max_node_uncertainty_mm is not None
        and model.coverage.max_node_uncertainty_mm > criteria.max_node_uncertainty_mm
    ):
        return "high_uncertainty_patch"
    if not any(batch.purpose == "direction_backlash_probe" for batch in session.batches):
        return "direction_backlash_probe"
    return "validation_holdout"


def build_drawing_calibration_batch_program(
    *,
    session: DrawingCalibrationSession,
    batch_id: str,
    purpose: DrawingCalibrationBatchPurpose,
    model: DrawingCalibrationModel | None = None,
) -> DrawingProgram:
    prefix = f"{batch_id}.{purpose}"
    if purpose == "bootstrap_sheet":
        return DrawingProgram(
            point_marks=[
                _mark(prefix, "center", 0.50, 0.50, 5.0),
                _mark(prefix, "bottom_left", 0.15, 0.15, 4.0),
                _mark(prefix, "bottom_right", 0.85, 0.15, 4.0),
                _mark(prefix, "top_right", 0.85, 0.85, 4.0),
                _mark(prefix, "top_left", 0.15, 0.85, 4.0),
            ],
            polylines=[
                _line(prefix, "axis_x", [(0.18, 0.50), (0.82, 0.50)], semantic_role="line"),
                _line(prefix, "axis_y", [(0.50, 0.18), (0.50, 0.82)], semantic_role="line"),
            ],
        )

    if purpose == "direction_backlash_probe":
        return DrawingProgram(
            polylines=[
                _line(prefix, "repeat_forward", [(0.25, 0.35), (0.75, 0.35)], semantic_role="direction_probe"),
                _line(prefix, "repeat_reverse", [(0.75, 0.43), (0.25, 0.43)], semantic_role="direction_probe"),
                _line(prefix, "vertical_forward", [(0.38, 0.25), (0.38, 0.75)], semantic_role="direction_probe"),
                _line(prefix, "vertical_reverse", [(0.46, 0.75), (0.46, 0.25)], semantic_role="direction_probe"),
            ],
        )

    if purpose == "validation_holdout":
        return DrawingProgram(
            point_marks=[
                _mark(prefix, "holdout_a", 0.23, 0.77, 4.0),
                _mark(prefix, "holdout_b", 0.77, 0.23, 4.0),
                _mark(prefix, "holdout_c", 0.63, 0.67, 4.0),
            ],
            polylines=[
                _line(prefix, "holdout_diag_a", [(0.20, 0.22), (0.39, 0.41)], semantic_role="validation"),
                _line(prefix, "holdout_diag_b", [(0.80, 0.78), (0.61, 0.59)], semantic_role="validation"),
            ],
        )

    targets = _coverage_targets(model=model, fallback_count=6)
    if purpose == "high_uncertainty_patch":
        center_x, center_y = targets[0]
        delta_x = min(0.08, 8.0 / max(session.field_width_mm, 1.0))
        delta_y = min(0.08, 8.0 / max(session.field_height_mm, 1.0))
        points = [
            (center_x - delta_x, center_y),
            (center_x + delta_x, center_y),
            (center_x, center_y - delta_y),
            (center_x, center_y + delta_y),
        ]
        return DrawingProgram(
            point_marks=[
                _mark(prefix, f"patch_mark_{index}", x, y, 3.5)
                for index, (x, y) in enumerate(_clamped_norm_points(points), start=1)
            ],
            polylines=[
                _line(prefix, "patch_x", [(center_x - delta_x, center_y), (center_x + delta_x, center_y)], semantic_role="line"),
                _line(prefix, "patch_y", [(center_x, center_y - delta_y), (center_x, center_y + delta_y)], semantic_role="line"),
            ],
        )

    return DrawingProgram(
        point_marks=[
            _mark(prefix, f"fill_{index}", x, y, 3.5)
            for index, (x, y) in enumerate(targets, start=1)
        ]
    )


def record_batch_run(
    session: DrawingCalibrationSession,
    *,
    batch_id: str,
    command_id: str,
    plan_hash: str,
    planned_trace_summary: dict[str, Any],
) -> DrawingCalibrationBatch:
    batch = require_batch(session, batch_id)
    batch.command_id = command_id
    batch.plan_hash = plan_hash
    batch.planned_trace_summary = planned_trace_summary
    batch.status = "awaiting_observation"
    session.current_batch_id = batch.batch_id
    session.status = "awaiting_observation"
    session.mark_updated()
    return batch


def record_batch_observation(
    session: DrawingCalibrationSession,
    *,
    observation: DrawingCalibrationObservation,
    batch_id: str | None = None,
) -> tuple[DrawingCalibrationObservationRecord, list[str]]:
    resolved_batch_id = batch_id or session.current_batch_id
    weak_reasons = weak_observation_reasons(observation)
    disposition: DrawingCalibrationObservationDisposition = "accepted" if not weak_reasons else "rejected"
    record = DrawingCalibrationObservationRecord(
        observation_id=observation.observation_id,
        batch_id=resolved_batch_id,
        disposition=disposition,
        reasons=weak_reasons,
        observation=observation,
    )
    session.observations.append(record)
    if resolved_batch_id is not None:
        batch = require_batch(session, resolved_batch_id)
        batch.observation_summary = {
            "observation_id": observation.observation_id,
            "sample_count": len(observation.samples),
            "usable": observation.usable,
            "disposition": disposition,
            "weak_reasons": weak_reasons,
        }
        if weak_reasons:
            batch.status = "retry" if can_retry_batch(batch) else "blocked"
            batch.blockers = weak_reasons
        else:
            batch.status = "accepted"
            batch.blockers = []
    session.status = "collecting" if not weak_reasons else "awaiting_observation"
    session.mark_updated()
    return record, weak_reasons


def schedule_retry_if_allowed(
    session: DrawingCalibrationSession,
    *,
    batch_id: str,
    reasons: list[str],
) -> bool:
    batch = require_batch(session, batch_id)
    if not reasons:
        return False
    if not can_retry_batch(batch):
        session.status = "blocked"
        session.blockers = list(dict.fromkeys([*session.blockers, *reasons, "Retry limit exhausted."]))
        batch.status = "blocked"
        batch.blockers = list(dict.fromkeys([*batch.blockers, *reasons, "Retry limit exhausted."]))
        session.mark_updated()
        return False
    batch.retry_count += 1
    batch.correction_mode = "retry"
    batch.status = "planned"
    session.retry_history.append(
        DrawingCalibrationRetryRecord(
            batch_id=batch.batch_id,
            retry_index=batch.retry_count,
            reason="; ".join(reasons),
        )
    )
    session.status = "collecting"
    session.current_batch_id = batch.batch_id
    session.mark_updated()
    return True


def can_retry_batch(batch: DrawingCalibrationBatch) -> bool:
    return batch.retry_count < batch.max_retries


def update_session_from_model(
    session: DrawingCalibrationSession,
    *,
    model: DrawingCalibrationModel,
    promoting: bool = False,
) -> None:
    session.latest_model_id = model.model_id
    criteria = session.completion_criteria
    blockers = list(model.blockers)
    coverage = model.coverage
    fit = model.fit_metrics
    validation = model.validation_metrics
    if model.sample_count < criteria.min_sample_count:
        blockers.append(
            f"Accepted sample count {model.sample_count} is below {criteria.min_sample_count}."
        )
    if coverage is None:
        blockers.append("Residual grid coverage is unavailable.")
    else:
        if coverage.coverage_fraction < criteria.min_coverage_fraction:
            blockers.append(
                f"Coverage {coverage.coverage_fraction:.2f} is below {criteria.min_coverage_fraction:.2f}."
            )
        if (
            coverage.max_node_uncertainty_mm is not None
            and coverage.max_node_uncertainty_mm > criteria.max_node_uncertainty_mm
        ):
            blockers.append(
                f"Max node uncertainty {coverage.max_node_uncertainty_mm:.1f}mm exceeds "
                f"{criteria.max_node_uncertainty_mm:.1f}mm."
            )
    _metrics_blockers(
        blockers,
        metrics=fit,
        label="fit",
        rms_limit=criteria.fit_rms_limit_mm,
        p95_limit=criteria.fit_p95_limit_mm,
        max_limit=criteria.fit_max_limit_mm,
    )
    _metrics_blockers(
        blockers,
        metrics=validation,
        label="validation",
        rms_limit=criteria.validation_rms_limit_mm,
        p95_limit=criteria.validation_p95_limit_mm,
        max_limit=criteria.validation_max_limit_mm,
    )
    session.blockers = list(dict.fromkeys(blockers))
    session.promotion_status = "promoted" if promoting and not session.blockers else ("blocked" if session.blockers else "candidate")
    session.status = "ready" if not session.blockers else "collecting"
    session.mark_updated()


def weak_observation_reasons(observation: DrawingCalibrationObservation) -> list[str]:
    reasons: list[str] = []
    if not observation.usable:
        reasons.append("observation not marked usable")
    if not observation.samples:
        reasons.append("no green ink")
    detected = [sample for sample in observation.samples if sample.confidence > 0.0]
    if len(detected) < 4:
        reasons.append("too few samples")
    average_confidence = (
        sum(sample.confidence for sample in detected) / len(detected)
        if detected
        else 0.0
    )
    if detected and average_confidence < 0.35:
        reasons.append("weak coverage")
    for blocker in observation.blockers:
        normalized = blocker.strip().lower()
        if "frame" in normalized:
            reasons.append("no frame")
        elif "green" in normalized:
            reasons.append("no green ink")
        elif normalized:
            reasons.append(blocker)
    return list(dict.fromkeys(reasons))


def require_batch(session: DrawingCalibrationSession, batch_id: str) -> DrawingCalibrationBatch:
    for batch in session.batches:
        if batch.batch_id == batch_id:
            return batch
    raise ValueError(f"Drawing calibration batch {batch_id} is not part of session {session.session_id}.")


def _default_correction_mode_for_purpose(
    purpose: DrawingCalibrationBatchPurpose,
    model: DrawingCalibrationModel | None,
) -> DrawingCalibrationCorrectionMode:
    if purpose == "validation_holdout" and model is not None and model.ready:
        return "validation"
    if model is not None and model.ready:
        return "current_model"
    return "uncorrected"


def _program_expected_primitives(program: DrawingProgram) -> list[dict[str, Any]]:
    primitives: list[dict[str, Any]] = []
    for mark in program.point_marks:
        primitives.append(
            {
                "primitive_id": mark.primitive_id,
                "primitive_kind": "mark",
                "semantic_role": mark.semantic_role,
            }
        )
    for line in program.polylines:
        primitives.append(
            {
                "primitive_id": line.primitive_id,
                "primitive_kind": "polyline",
                "semantic_role": line.semantic_role,
            }
        )
    return primitives


def _coverage_targets(
    *,
    model: DrawingCalibrationModel | None,
    fallback_count: int,
) -> list[tuple[float, float]]:
    if model is None or model.residual_grid is None:
        return [(0.20, 0.20), (0.80, 0.20), (0.20, 0.80), (0.80, 0.80), (0.50, 0.35), (0.50, 0.65)]
    nodes = sorted(
        model.residual_grid.nodes,
        key=lambda node: (-node.uncertainty_mm, node.source_sample_count, node.y_mm, node.x_mm),
    )
    targets = [
        (
            node.x_mm / model.field_width_mm if model.field_width_mm else 0.0,
            node.y_mm / model.field_height_mm if model.field_height_mm else 0.0,
        )
        for node in nodes[:fallback_count]
    ]
    return list(_clamped_norm_points(targets))


def _metrics_blockers(
    blockers: list[str],
    *,
    metrics: DrawingCalibrationMetrics | None,
    label: str,
    rms_limit: float,
    p95_limit: float,
    max_limit: float,
) -> None:
    if metrics is None or metrics.sample_count <= 0:
        blockers.append(f"{label} metrics are unavailable.")
        return
    if metrics.rms_mm is not None and metrics.rms_mm > rms_limit:
        blockers.append(f"{label} RMS {metrics.rms_mm:.1f}mm exceeds {rms_limit:.1f}mm.")
    if metrics.p95_mm is not None and metrics.p95_mm > p95_limit:
        blockers.append(f"{label} p95 {metrics.p95_mm:.1f}mm exceeds {p95_limit:.1f}mm.")
    if metrics.max_mm is not None and metrics.max_mm > max_limit:
        blockers.append(f"{label} max {metrics.max_mm:.1f}mm exceeds {max_limit:.1f}mm.")


def _mark(
    prefix: str,
    name: str,
    x: float,
    y: float,
    mark_size_mm: float,
) -> PointMarkPrimitive:
    return PointMarkPrimitive(
        primitive_id=f"{prefix}.mark.{name}",
        semantic_role="point_mark",
        center=PaperPointNorm(x=_clamp01(x), y=_clamp01(y)),
        mark_size_mm=mark_size_mm,
    )


def _line(
    prefix: str,
    name: str,
    points: list[tuple[float, float]],
    *,
    semantic_role: str,
) -> PolylinePrimitive:
    return PolylinePrimitive(
        primitive_id=f"{prefix}.line.{name}",
        semantic_role=semantic_role,
        role="outline",
        points=[PaperPointNorm(x=_clamp01(x), y=_clamp01(y)) for x, y in points],
    )


def _clamped_norm_points(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    return [(_clamp01(x), _clamp01(y)) for x, y in points]


def _clamp01(value: float) -> float:
    return max(0.05, min(0.95, value))
