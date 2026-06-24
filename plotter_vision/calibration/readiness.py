from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    PaperPointNorm,
)
from plotter_vision.controller.base import utc_now_iso
from plotter_vision.drawing.polygons import DrawingFrameMM

VisualCapObservationSource = Literal[
    "manual_click",
    "camera_detection",
    "operator_confirmed",
    "synthetic",
]

ProbeAxis = Literal["X", "Y"]

GREEN_CAP_TARGET = "green_cap_carriage_marker"
DEFAULT_MIN_PROBE_OBSERVATIONS = 2
DEFAULT_MAX_PROBE_RMS_RESIDUAL_MM = 10.0
DEFAULT_MAX_PROBE_P95_RESIDUAL_MM = 20.0
DEFAULT_MAX_PROBE_HARD_RESIDUAL_MM = 40.0
# Compatibility name for older callers: this is now the robust p95 gate, not a worst-frame veto.
DEFAULT_MAX_PROBE_MAX_RESIDUAL_MM = DEFAULT_MAX_PROBE_P95_RESIDUAL_MM


class RelativeMotionModel(BaseModel):
    """2x2 relative machine-motion to visual-field-motion model."""

    schema_version: int = 1
    artifact_type: Literal["relative_motion_model"] = "relative_motion_model"
    machine_to_field_matrix: tuple[tuple[float, float], tuple[float, float]]
    field_to_machine_matrix: tuple[tuple[float, float], tuple[float, float]]
    determinant: float
    sample_count: int
    rms_residual_mm: float
    p95_residual_mm: float
    max_residual_mm: float

    @field_validator("sample_count")
    @classmethod
    def _validate_sample_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("relative motion model sample_count must be non-negative.")
        return value

    @field_validator("determinant", "rms_residual_mm", "p95_residual_mm", "max_residual_mm")
    @classmethod
    def _validate_scalar(cls, value: float) -> float:
        return _finite(value, label="relative motion model value")

    @model_validator(mode="after")
    def _validate_matrix_shape(self) -> RelativeMotionModel:
        _validate_2x2_matrix(self.machine_to_field_matrix, label="machine_to_field_matrix")
        _validate_2x2_matrix(self.field_to_machine_matrix, label="field_to_machine_matrix")
        if abs(self.determinant) < 1e-9:
            raise ValueError("relative motion model determinant is singular.")
        if self.rms_residual_mm < 0.0 or self.p95_residual_mm < 0.0 or self.max_residual_mm < 0.0:
            raise ValueError("relative motion model residuals must be non-negative.")
        return self

    def machine_delta_to_field_delta(self, dx_mm: float, dy_mm: float) -> tuple[float, float]:
        a = self.machine_to_field_matrix
        return (
            a[0][0] * dx_mm + a[0][1] * dy_mm,
            a[1][0] * dx_mm + a[1][1] * dy_mm,
        )

    def field_delta_to_machine_delta(self, dx_mm: float, dy_mm: float) -> tuple[float, float]:
        inverse = self.field_to_machine_matrix
        return (
            inverse[0][0] * dx_mm + inverse[0][1] * dy_mm,
            inverse[1][0] * dx_mm + inverse[1][1] * dy_mm,
        )


class VisualCapObservation(BaseModel):
    """Camera observation of the green cap/carriage marker used for visual readiness."""

    schema_version: int = 1
    observation_id: str = Field(default_factory=lambda: f"cap-{uuid.uuid4().hex[:12]}")
    target: Literal["green_cap_carriage_marker"] = GREEN_CAP_TARGET
    timestamp: str = Field(default_factory=utc_now_iso)
    camera_norm: CameraPointNorm
    paper_norm: PaperPointNorm
    logical_mm: LogicalPointMM | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    paper_registration_id: str | None = None
    confidence: float = 1.0
    source: VisualCapObservationSource = "manual_click"

    @field_validator("confidence")
    @classmethod
    def _validate_confidence(cls, value: float) -> float:
        value = _finite(value, label="confidence")
        if value < 0.0 or value > 1.0:
            raise ValueError("confidence must be in [0, 1].")
        return value


class SafeZoneMarginsMM(BaseModel):
    left: float
    right: float
    bottom: float
    top: float

    @field_validator("left", "right", "bottom", "top")
    @classmethod
    def _validate_margin(cls, value: float) -> float:
        value = _finite(value, label="safe-zone margin")
        if value < 0.0:
            raise ValueError("safe-zone margins must be non-negative.")
        return value


class DrawingSafeZone(BaseModel):
    """Inset drawing rectangle expressed in both logical millimeters and paper coordinates."""

    schema_version: int = 1
    artifact_type: Literal["drawing_safe_zone"] = "drawing_safe_zone"
    drawing_frame: DrawingFrameMM
    margins_mm: SafeZoneMarginsMM
    extra_padding_mm: float = 0.0
    mark_clearance_mm: float = 0.0
    park_clearance_mm: float = 0.0
    observation_clearance_mm: float = 0.0
    cap_to_tip_offset_x_mm: float = 0.0
    cap_to_tip_offset_y_mm: float = 0.0
    logical_min_x_mm: float
    logical_max_x_mm: float
    logical_min_y_mm: float
    logical_max_y_mm: float
    paper_min_x_norm: float
    paper_max_x_norm: float
    paper_min_y_norm: float
    paper_max_y_norm: float

    @classmethod
    def from_frame(
        cls,
        *,
        drawing_frame: DrawingFrameMM,
        margins_mm: SafeZoneMarginsMM,
        extra_padding_mm: float = 0.0,
        mark_clearance_mm: float = 0.0,
        park_clearance_mm: float = 0.0,
        observation_clearance_mm: float = 0.0,
        cap_to_tip_offset_x_mm: float = 0.0,
        cap_to_tip_offset_y_mm: float = 0.0,
    ) -> DrawingSafeZone:
        if margins_mm.left + margins_mm.right >= drawing_frame.width_mm:
            raise ValueError("safe-zone left/right margins collapse the drawing frame.")
        if margins_mm.bottom + margins_mm.top >= drawing_frame.height_mm:
            raise ValueError("safe-zone bottom/top margins collapse the drawing frame.")

        return cls(
            drawing_frame=drawing_frame,
            margins_mm=margins_mm,
            extra_padding_mm=extra_padding_mm,
            mark_clearance_mm=mark_clearance_mm,
            park_clearance_mm=park_clearance_mm,
            observation_clearance_mm=observation_clearance_mm,
            cap_to_tip_offset_x_mm=cap_to_tip_offset_x_mm,
            cap_to_tip_offset_y_mm=cap_to_tip_offset_y_mm,
            logical_min_x_mm=drawing_frame.origin_x_mm + margins_mm.left,
            logical_max_x_mm=(
                drawing_frame.origin_x_mm + drawing_frame.width_mm - margins_mm.right
            ),
            logical_min_y_mm=drawing_frame.origin_y_mm + margins_mm.bottom,
            logical_max_y_mm=(
                drawing_frame.origin_y_mm + drawing_frame.height_mm - margins_mm.top
            ),
            paper_min_x_norm=margins_mm.left / drawing_frame.width_mm,
            paper_max_x_norm=1.0 - margins_mm.right / drawing_frame.width_mm,
            paper_min_y_norm=margins_mm.bottom / drawing_frame.height_mm,
            paper_max_y_norm=1.0 - margins_mm.top / drawing_frame.height_mm,
        )

    @field_validator(
        "extra_padding_mm",
        "mark_clearance_mm",
        "park_clearance_mm",
        "observation_clearance_mm",
        "cap_to_tip_offset_x_mm",
        "cap_to_tip_offset_y_mm",
    )
    @classmethod
    def _validate_policy_value(cls, value: float) -> float:
        return _finite(value, label="safe-zone policy value")

    @model_validator(mode="after")
    def _validate_bounds(self) -> DrawingSafeZone:
        if self.logical_min_x_mm >= self.logical_max_x_mm:
            raise ValueError("safe-zone logical X bounds are collapsed.")
        if self.logical_min_y_mm >= self.logical_max_y_mm:
            raise ValueError("safe-zone logical Y bounds are collapsed.")
        for label, value in [
            ("paper_min_x_norm", self.paper_min_x_norm),
            ("paper_max_x_norm", self.paper_max_x_norm),
            ("paper_min_y_norm", self.paper_min_y_norm),
            ("paper_max_y_norm", self.paper_max_y_norm),
        ]:
            if not 0.0 <= value <= 1.0:
                raise ValueError(f"{label} must be in [0, 1].")
        if self.paper_min_x_norm >= self.paper_max_x_norm:
            raise ValueError("safe-zone paper X bounds are collapsed.")
        if self.paper_min_y_norm >= self.paper_max_y_norm:
            raise ValueError("safe-zone paper Y bounds are collapsed.")
        return self

    def logical_point_for(self, observation: VisualCapObservation) -> LogicalPointMM:
        if observation.logical_mm is not None:
            return observation.logical_mm
        y_norm = 1.0 - observation.paper_norm.y if self.drawing_frame.flip_y else observation.paper_norm.y
        return LogicalPointMM(
            x=self.drawing_frame.origin_x_mm + observation.paper_norm.x * self.drawing_frame.width_mm,
            y=self.drawing_frame.origin_y_mm + y_norm * self.drawing_frame.height_mm,
        )


SafeZoneAbortCode = Literal[
    "cap_paper_x_below_safe_zone",
    "cap_paper_x_above_safe_zone",
    "cap_paper_y_below_safe_zone",
    "cap_paper_y_above_safe_zone",
    "cap_logical_x_below_safe_zone",
    "cap_logical_x_above_safe_zone",
    "cap_logical_y_below_safe_zone",
    "cap_logical_y_above_safe_zone",
]


class SafeZoneAbortReason(BaseModel):
    code: SafeZoneAbortCode
    message: str


class SafeZoneEvaluation(BaseModel):
    cap_observation_id: str
    target: Literal["green_cap_carriage_marker"] = GREEN_CAP_TARGET
    inside: bool
    logical_mm: LogicalPointMM
    safe_zone: DrawingSafeZone | None = None
    abort_reasons: list[SafeZoneAbortReason] = Field(default_factory=list)


class VisualReadinessState(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["visual_readiness_state"] = "visual_readiness_state"
    state_id: str = Field(default_factory=lambda: f"visual-ready-{uuid.uuid4().hex[:12]}")
    updated_at: str = Field(default_factory=utc_now_iso)
    paper_registered: bool = False
    paper_registration_id: str | None = None
    cap_localized: bool = False
    cap_inside_safe_zone: bool = False
    latest_cap_observation: VisualCapObservation | None = None
    safe_zone: DrawingSafeZone | None = None
    safe_zone_evaluation: SafeZoneEvaluation | None = None
    zone_check: SafeZoneEvaluation | None = None
    latest_visual_probe_run_id: str | None = None
    latest_visual_probe_sample_id: str | None = None
    latest_visual_probe_run_file: str | None = None
    probe_raw_sample_count: int = 0
    probe_observation_count: int = 0
    probe_rejected_sample_count: int = 0
    probe_stale_sample_count: int = 0
    probe_axes_represented: list[ProbeAxis] = Field(default_factory=list)
    probe_adaptive_sample_count: int = 0
    probe_center_target_sample_count: int = 0
    probe_x_field_recovery_sample_count: int = 0
    probe_rms_residual_mm: float | None = None
    probe_p95_residual_mm: float | None = None
    probe_max_residual_mm: float | None = None
    motion_model_valid: bool = False
    relative_motion_model: RelativeMotionModel | None = None
    motion_model_blockers: list[str] = Field(default_factory=list)
    visual_ready_to_plot: bool = False
    blockers: list[str] = Field(default_factory=list)

    @field_validator(
        "probe_raw_sample_count",
        "probe_observation_count",
        "probe_rejected_sample_count",
        "probe_stale_sample_count",
        "probe_adaptive_sample_count",
        "probe_center_target_sample_count",
        "probe_x_field_recovery_sample_count",
    )
    @classmethod
    def _validate_probe_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("probe evidence counts must be non-negative.")
        return value

    @field_validator("probe_rms_residual_mm", "probe_p95_residual_mm", "probe_max_residual_mm")
    @classmethod
    def _validate_optional_residual(cls, value: float | None) -> float | None:
        if value is None:
            return None
        value = _finite(value, label="probe residual")
        if value < 0.0:
            raise ValueError("probe residuals must be non-negative.")
        return value

    @model_validator(mode="after")
    def _validate_ready_consistency(self) -> VisualReadinessState:
        if self.visual_ready_to_plot and self.blockers:
            raise ValueError("visual_ready_to_plot cannot be true when blockers are present.")
        if self.visual_ready_to_plot and not (
            self.paper_registered
            and self.cap_localized
            and self.cap_inside_safe_zone
            and self.motion_model_valid
        ):
            raise ValueError(
                "visual_ready_to_plot requires field, cap, safe-zone, and motion-model readiness."
            )
        if self.motion_model_valid and self.relative_motion_model is None:
            raise ValueError("motion_model_valid requires relative_motion_model.")
        return self

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> VisualReadinessState:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def recompute(self) -> None:
        check = self.zone_check or self.safe_zone_evaluation
        updated = build_visual_readiness_state(
            paper_registered=self.paper_registered,
            cap_observation=self.latest_cap_observation,
            safe_zone_evaluation=check,
            probe_observation_count=self.probe_observation_count,
            probe_raw_sample_count=self.probe_raw_sample_count,
            probe_rejected_sample_count=self.probe_rejected_sample_count,
            probe_stale_sample_count=self.probe_stale_sample_count,
            probe_axes_represented=self.probe_axes_represented,
            probe_adaptive_sample_count=self.probe_adaptive_sample_count,
            probe_center_target_sample_count=self.probe_center_target_sample_count,
            probe_x_field_recovery_sample_count=self.probe_x_field_recovery_sample_count,
            probe_rms_residual_mm=self.probe_rms_residual_mm,
            probe_p95_residual_mm=self.probe_p95_residual_mm,
            probe_max_residual_mm=self.probe_max_residual_mm,
            relative_motion_model=self.relative_motion_model,
            motion_model_blockers=self.motion_model_blockers,
            latest_visual_probe_run_id=self.latest_visual_probe_run_id,
            latest_visual_probe_sample_id=self.latest_visual_probe_sample_id,
            latest_visual_probe_run_file=self.latest_visual_probe_run_file,
        )
        self.updated_at = utc_now_iso()
        self.cap_localized = updated.cap_localized
        self.cap_inside_safe_zone = updated.cap_inside_safe_zone
        self.motion_model_valid = updated.motion_model_valid
        self.relative_motion_model = updated.relative_motion_model
        self.motion_model_blockers = updated.motion_model_blockers
        self.visual_ready_to_plot = updated.visual_ready_to_plot
        self.blockers = updated.blockers
        self.safe_zone_evaluation = check
        self.zone_check = check


def evaluate_cap_inside_safe_zone(
    *,
    observation: VisualCapObservation,
    safe_zone: DrawingSafeZone,
) -> SafeZoneEvaluation:
    logical = safe_zone.logical_point_for(observation)
    reasons: list[SafeZoneAbortReason] = []

    _append_range_reason(
        reasons,
        value=observation.paper_norm.x,
        min_value=safe_zone.paper_min_x_norm,
        max_value=safe_zone.paper_max_x_norm,
        below_code="cap_paper_x_below_safe_zone",
        above_code="cap_paper_x_above_safe_zone",
        label="paper X",
        units="norm",
    )
    _append_range_reason(
        reasons,
        value=observation.paper_norm.y,
        min_value=safe_zone.paper_min_y_norm,
        max_value=safe_zone.paper_max_y_norm,
        below_code="cap_paper_y_below_safe_zone",
        above_code="cap_paper_y_above_safe_zone",
        label="paper Y",
        units="norm",
    )
    _append_range_reason(
        reasons,
        value=logical.x,
        min_value=safe_zone.logical_min_x_mm,
        max_value=safe_zone.logical_max_x_mm,
        below_code="cap_logical_x_below_safe_zone",
        above_code="cap_logical_x_above_safe_zone",
        label="logical X",
        units="mm",
    )
    _append_range_reason(
        reasons,
        value=logical.y,
        min_value=safe_zone.logical_min_y_mm,
        max_value=safe_zone.logical_max_y_mm,
        below_code="cap_logical_y_below_safe_zone",
        above_code="cap_logical_y_above_safe_zone",
        label="logical Y",
        units="mm",
    )
    return SafeZoneEvaluation(
        cap_observation_id=observation.observation_id,
        inside=not reasons,
        logical_mm=logical,
        safe_zone=safe_zone,
        abort_reasons=reasons,
    )


def build_visual_readiness_state(
    *,
    paper_registered: bool,
    cap_observation: VisualCapObservation | None,
    safe_zone_evaluation: SafeZoneEvaluation | None,
    probe_observation_count: int,
    probe_raw_sample_count: int | None = None,
    probe_rejected_sample_count: int = 0,
    probe_stale_sample_count: int = 0,
    probe_axes_represented: list[ProbeAxis] | None = None,
    probe_adaptive_sample_count: int = 0,
    probe_center_target_sample_count: int = 0,
    probe_x_field_recovery_sample_count: int = 0,
    probe_rms_residual_mm: float | None = None,
    probe_p95_residual_mm: float | None = None,
    probe_max_residual_mm: float | None = None,
    relative_motion_model: RelativeMotionModel | None = None,
    motion_model_blockers: list[str] | None = None,
    latest_visual_probe_run_id: str | None = None,
    latest_visual_probe_sample_id: str | None = None,
    latest_visual_probe_run_file: str | None = None,
    min_probe_observation_count: int = DEFAULT_MIN_PROBE_OBSERVATIONS,
    max_probe_rms_residual_mm: float = DEFAULT_MAX_PROBE_RMS_RESIDUAL_MM,
    max_probe_p95_residual_mm: float = DEFAULT_MAX_PROBE_P95_RESIDUAL_MM,
    max_probe_hard_residual_mm: float = DEFAULT_MAX_PROBE_HARD_RESIDUAL_MM,
    max_probe_max_residual_mm: float | None = None,
) -> VisualReadinessState:
    if min_probe_observation_count < 0:
        raise ValueError("min_probe_observation_count must be non-negative.")
    max_probe_rms_residual_mm = _finite(
        max_probe_rms_residual_mm,
        label="max probe RMS residual",
    )
    if max_probe_max_residual_mm is not None:
        max_probe_p95_residual_mm = max_probe_max_residual_mm
    max_probe_p95_residual_mm = _finite(
        max_probe_p95_residual_mm,
        label="max probe p95 residual",
    )
    max_probe_hard_residual_mm = _finite(
        max_probe_hard_residual_mm,
        label="max probe hard residual",
    )

    blockers: list[str] = []
    motion_blockers = list(motion_model_blockers or [])
    cap_localized = cap_observation is not None
    cap_inside_safe_zone = bool(safe_zone_evaluation and safe_zone_evaluation.inside)

    if not paper_registered:
        blockers.append("Visual field registration is required before motion validation.")
    if not cap_localized:
        blockers.append("Green cap/carriage marker is not localized.")
    if cap_localized and safe_zone_evaluation is None:
        blockers.append("Green cap/carriage marker has not been checked inside the visual field.")
    elif safe_zone_evaluation is not None and not safe_zone_evaluation.inside:
        blockers.extend(reason.message for reason in safe_zone_evaluation.abort_reasons)

    if probe_observation_count < min_probe_observation_count:
        motion_blockers.append(
            "Motion calibration needs at least "
            f"{min_probe_observation_count} observations; got {probe_observation_count}."
        )
    if probe_observation_count >= min_probe_observation_count:
        if relative_motion_model is None:
            motion_blockers.append(
                "Motion calibration required: valid relative motion model has not been learned."
            )
        if probe_rms_residual_mm is None:
            motion_blockers.append("Motion calibration RMS residual is missing.")
        elif probe_rms_residual_mm > max_probe_rms_residual_mm:
            motion_blockers.append(
                "Motion calibration RMS residual "
                f"{probe_rms_residual_mm:.3f} mm exceeds {max_probe_rms_residual_mm:.3f} mm."
            )
        robust_residual_mm = (
            probe_p95_residual_mm
            if probe_p95_residual_mm is not None
            else probe_max_residual_mm
        )
        if robust_residual_mm is None:
            motion_blockers.append("Motion calibration p95 residual is missing.")
        elif robust_residual_mm > max_probe_p95_residual_mm:
            label = "p95" if probe_p95_residual_mm is not None else "max"
            motion_blockers.append(
                f"Motion calibration {label} residual "
                f"{robust_residual_mm:.3f} mm exceeds {max_probe_p95_residual_mm:.3f} mm."
            )
        if probe_max_residual_mm is not None and probe_max_residual_mm > max_probe_hard_residual_mm:
            motion_blockers.append(
                "Motion calibration hard max residual "
                f"{probe_max_residual_mm:.3f} mm exceeds {max_probe_hard_residual_mm:.3f} mm."
            )
    if relative_motion_model is None and not motion_blockers:
        motion_blockers.append(
            "Motion calibration required: valid relative motion model has not been learned."
        )

    motion_blockers = list(dict.fromkeys(motion_blockers))
    motion_model_valid = relative_motion_model is not None and not motion_blockers
    blockers.extend(motion_blockers)

    return VisualReadinessState(
        paper_registered=paper_registered,
        paper_registration_id=cap_observation.paper_registration_id if cap_observation else None,
        cap_localized=cap_localized,
        cap_inside_safe_zone=cap_inside_safe_zone,
        latest_cap_observation=cap_observation,
        safe_zone=safe_zone_evaluation.safe_zone if safe_zone_evaluation else None,
        safe_zone_evaluation=safe_zone_evaluation,
        latest_visual_probe_run_id=latest_visual_probe_run_id,
        latest_visual_probe_sample_id=latest_visual_probe_sample_id,
        latest_visual_probe_run_file=latest_visual_probe_run_file,
        probe_raw_sample_count=(
            probe_raw_sample_count if probe_raw_sample_count is not None else probe_observation_count
        ),
        probe_observation_count=probe_observation_count,
        probe_rejected_sample_count=probe_rejected_sample_count,
        probe_stale_sample_count=probe_stale_sample_count,
        probe_axes_represented=probe_axes_represented or [],
        probe_adaptive_sample_count=probe_adaptive_sample_count,
        probe_center_target_sample_count=probe_center_target_sample_count,
        probe_x_field_recovery_sample_count=probe_x_field_recovery_sample_count,
        probe_rms_residual_mm=probe_rms_residual_mm,
        probe_p95_residual_mm=probe_p95_residual_mm,
        probe_max_residual_mm=probe_max_residual_mm,
        motion_model_valid=motion_model_valid,
        relative_motion_model=relative_motion_model if motion_model_valid else None,
        motion_model_blockers=motion_blockers,
        visual_ready_to_plot=not blockers,
        blockers=blockers,
    )


def _append_range_reason(
    reasons: list[SafeZoneAbortReason],
    *,
    value: float,
    min_value: float,
    max_value: float,
    below_code: SafeZoneAbortCode,
    above_code: SafeZoneAbortCode,
    label: str,
    units: str,
) -> None:
    if value < min_value - 1e-9:
        reasons.append(
            SafeZoneAbortReason(
                code=below_code,
                message=(
                    f"Green cap {label} {value:.3f} {units} is below safe zone minimum "
                    f"{min_value:.3f} {units}."
                ),
            )
        )
    elif value > max_value + 1e-9:
        reasons.append(
            SafeZoneAbortReason(
                code=above_code,
                message=(
                    f"Green cap {label} {value:.3f} {units} is above safe zone maximum "
                    f"{max_value:.3f} {units}."
                ),
            )
        )


def _validate_2x2_matrix(
    matrix: tuple[tuple[float, float], tuple[float, float]],
    *,
    label: str,
) -> None:
    if len(matrix) != 2 or any(len(row) != 2 for row in matrix):
        raise ValueError(f"{label} must be 2x2.")
    for row in matrix:
        for value in row:
            _finite(value, label=label)


def _finite(value: float, *, label: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite.")
    return value
