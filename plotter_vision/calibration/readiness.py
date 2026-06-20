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
ProbePlanStatus = Literal["planned", "blocked"]

GREEN_CAP_TARGET = "green_cap_carriage_marker"
X_PROBE_MAX_MM = 200.0
Y_PROBE_MAX_MM = 50.0
DEFAULT_PROBE_STEP_FRACTION = 0.60
DEFAULT_MIN_PROBE_OBSERVATIONS = 2
DEFAULT_MAX_PROBE_RMS_RESIDUAL_MM = 5.0
DEFAULT_MAX_PROBE_MAX_RESIDUAL_MM = 8.0


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
    ) -> DrawingSafeZone:
        if margins_mm.left + margins_mm.right >= drawing_frame.width_mm:
            raise ValueError("safe-zone left/right margins collapse the drawing frame.")
        if margins_mm.bottom + margins_mm.top >= drawing_frame.height_mm:
            raise ValueError("safe-zone bottom/top margins collapse the drawing frame.")

        return cls(
            drawing_frame=drawing_frame,
            margins_mm=margins_mm,
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
    abort_reasons: list[SafeZoneAbortReason] = Field(default_factory=list)


class VisualProbeMove(BaseModel):
    axis: ProbeAxis
    direction: Literal[-1, 1]
    step_mm: float
    relative_x_mm: float
    relative_y_mm: float
    available_negative_mm: float
    available_positive_mm: float
    max_step_mm: float

    @field_validator("step_mm", "available_negative_mm", "available_positive_mm", "max_step_mm")
    @classmethod
    def _validate_non_negative_finite(cls, value: float) -> float:
        value = _finite(value, label="probe move")
        if value < 0.0:
            raise ValueError("probe move distances must be non-negative.")
        return value

    @model_validator(mode="after")
    def _validate_relative_move(self) -> VisualProbeMove:
        if self.step_mm <= 0.0:
            raise ValueError("probe step_mm must be positive.")
        if self.step_mm > self.max_step_mm + 1e-9:
            raise ValueError("probe step_mm exceeds max_step_mm.")
        expected_x = self.direction * self.step_mm if self.axis == "X" else 0.0
        expected_y = self.direction * self.step_mm if self.axis == "Y" else 0.0
        if abs(self.relative_x_mm - expected_x) > 1e-9:
            raise ValueError("relative_x_mm does not match axis, direction, and step.")
        if abs(self.relative_y_mm - expected_y) > 1e-9:
            raise ValueError("relative_y_mm does not match axis, direction, and step.")
        return self


class AdaptiveVisualProbePlan(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["adaptive_visual_probe_plan"] = "adaptive_visual_probe_plan"
    plan_id: str = Field(default_factory=lambda: f"probe-{uuid.uuid4().hex[:12]}")
    target: Literal["green_cap_carriage_marker"] = GREEN_CAP_TARGET
    status: ProbePlanStatus
    preview_only: Literal[True] = True
    requires_homing: Literal[False] = False
    cap_observation_id: str
    safe_zone_evaluation: SafeZoneEvaluation
    moves: list[VisualProbeMove] = Field(default_factory=list)
    blockers: list[str] = Field(default_factory=list)
    feed_mm_min: float = 300.0

    @model_validator(mode="after")
    def _validate_status(self) -> AdaptiveVisualProbePlan:
        if self.status == "planned" and not self.moves:
            raise ValueError("planned visual probe requires at least one move.")
        if self.status == "blocked" and not self.blockers:
            raise ValueError("blocked visual probe requires blockers.")
        return self


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
    latest_probe_plan: AdaptiveVisualProbePlan | None = None
    probe_observation_count: int = 0
    probe_rms_residual_mm: float | None = None
    probe_max_residual_mm: float | None = None
    visual_ready_to_plot: bool = False
    blockers: list[str] = Field(default_factory=list)

    @field_validator("probe_observation_count")
    @classmethod
    def _validate_probe_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("probe_observation_count must be non-negative.")
        return value

    @field_validator("probe_rms_residual_mm", "probe_max_residual_mm")
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
            self.paper_registered and self.cap_localized and self.cap_inside_safe_zone
        ):
            raise ValueError("visual_ready_to_plot requires paper, cap, and safe-zone readiness.")
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
            probe_rms_residual_mm=self.probe_rms_residual_mm,
            probe_max_residual_mm=self.probe_max_residual_mm,
        )
        self.updated_at = utc_now_iso()
        self.cap_localized = updated.cap_localized
        self.cap_inside_safe_zone = updated.cap_inside_safe_zone
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
        abort_reasons=reasons,
    )


def plan_adaptive_visual_probe(
    *,
    observation: VisualCapObservation,
    safe_zone: DrawingSafeZone,
    step_fraction: float = DEFAULT_PROBE_STEP_FRACTION,
    x_probe_max_mm: float = X_PROBE_MAX_MM,
    y_probe_max_mm: float = Y_PROBE_MAX_MM,
    feed_mm_min: float = 300.0,
) -> AdaptiveVisualProbePlan:
    step_fraction = _finite(step_fraction, label="probe step fraction")
    if step_fraction <= 0.0 or step_fraction > 1.0:
        raise ValueError("probe step_fraction must be in (0, 1].")
    x_probe_max_mm = _finite(x_probe_max_mm, label="X probe max")
    y_probe_max_mm = _finite(y_probe_max_mm, label="Y probe max")
    feed_mm_min = _finite(feed_mm_min, label="probe feed")
    if x_probe_max_mm <= 0.0 or y_probe_max_mm <= 0.0:
        raise ValueError("probe axis maxima must be positive.")
    if feed_mm_min <= 0.0:
        raise ValueError("probe feed must be positive.")

    evaluation = evaluate_cap_inside_safe_zone(observation=observation, safe_zone=safe_zone)
    if not evaluation.inside:
        return AdaptiveVisualProbePlan(
            status="blocked",
            cap_observation_id=observation.observation_id,
            safe_zone_evaluation=evaluation,
            blockers=[reason.message for reason in evaluation.abort_reasons],
            feed_mm_min=feed_mm_min,
        )

    logical = evaluation.logical_mm
    moves: list[VisualProbeMove] = []
    blockers: list[str] = []
    for axis, lower, upper, coordinate, axis_max_step in [
        (
            "X",
            safe_zone.logical_min_x_mm,
            safe_zone.logical_max_x_mm,
            logical.x,
            x_probe_max_mm,
        ),
        (
            "Y",
            safe_zone.logical_min_y_mm,
            safe_zone.logical_max_y_mm,
            logical.y,
            y_probe_max_mm,
        ),
    ]:
        move = _plan_axis_probe_move(
            axis=axis,
            lower=lower,
            upper=upper,
            coordinate=coordinate,
            max_step=axis_max_step,
            step_fraction=step_fraction,
        )
        if move is None:
            blockers.append(f"{axis} probe has no usable safe-zone margin.")
        else:
            moves.append(move)

    if blockers:
        return AdaptiveVisualProbePlan(
            status="blocked",
            cap_observation_id=observation.observation_id,
            safe_zone_evaluation=evaluation,
            blockers=blockers,
            feed_mm_min=feed_mm_min,
        )

    return AdaptiveVisualProbePlan(
        status="planned",
        cap_observation_id=observation.observation_id,
        safe_zone_evaluation=evaluation,
        moves=moves,
        feed_mm_min=feed_mm_min,
    )


def build_visual_readiness_state(
    *,
    paper_registered: bool,
    cap_observation: VisualCapObservation | None,
    safe_zone_evaluation: SafeZoneEvaluation | None,
    probe_observation_count: int,
    probe_rms_residual_mm: float | None = None,
    probe_max_residual_mm: float | None = None,
    min_probe_observation_count: int = DEFAULT_MIN_PROBE_OBSERVATIONS,
    max_probe_rms_residual_mm: float = DEFAULT_MAX_PROBE_RMS_RESIDUAL_MM,
    max_probe_max_residual_mm: float = DEFAULT_MAX_PROBE_MAX_RESIDUAL_MM,
) -> VisualReadinessState:
    if min_probe_observation_count < 0:
        raise ValueError("min_probe_observation_count must be non-negative.")
    max_probe_rms_residual_mm = _finite(
        max_probe_rms_residual_mm,
        label="max probe RMS residual",
    )
    max_probe_max_residual_mm = _finite(
        max_probe_max_residual_mm,
        label="max probe max residual",
    )

    blockers: list[str] = []
    cap_localized = cap_observation is not None
    cap_inside_safe_zone = bool(safe_zone_evaluation and safe_zone_evaluation.inside)

    if not paper_registered:
        blockers.append("Paper registration is required before visual plotting.")
    if not cap_localized:
        blockers.append("Green cap/carriage marker is not localized.")
    if cap_localized and safe_zone_evaluation is None:
        blockers.append("Green cap/carriage marker has not been checked against the safe zone.")
    elif safe_zone_evaluation is not None and not safe_zone_evaluation.inside:
        blockers.extend(reason.message for reason in safe_zone_evaluation.abort_reasons)

    if probe_observation_count < min_probe_observation_count:
        blockers.append(
            "Visual probe needs at least "
            f"{min_probe_observation_count} observations; got {probe_observation_count}."
        )
    if probe_observation_count >= min_probe_observation_count:
        if probe_rms_residual_mm is None:
            blockers.append("Visual probe RMS residual is missing.")
        elif probe_rms_residual_mm > max_probe_rms_residual_mm:
            blockers.append(
                "Visual probe RMS residual "
                f"{probe_rms_residual_mm:.3f} mm exceeds {max_probe_rms_residual_mm:.3f} mm."
            )
        if probe_max_residual_mm is None:
            blockers.append("Visual probe max residual is missing.")
        elif probe_max_residual_mm > max_probe_max_residual_mm:
            blockers.append(
                "Visual probe max residual "
                f"{probe_max_residual_mm:.3f} mm exceeds {max_probe_max_residual_mm:.3f} mm."
            )

    return VisualReadinessState(
        paper_registered=paper_registered,
        paper_registration_id=cap_observation.paper_registration_id if cap_observation else None,
        cap_localized=cap_localized,
        cap_inside_safe_zone=cap_inside_safe_zone,
        latest_cap_observation=cap_observation,
        safe_zone_evaluation=safe_zone_evaluation,
        probe_observation_count=probe_observation_count,
        probe_rms_residual_mm=probe_rms_residual_mm,
        probe_max_residual_mm=probe_max_residual_mm,
        visual_ready_to_plot=not blockers,
        blockers=blockers,
    )


def _plan_axis_probe_move(
    *,
    axis: ProbeAxis,
    lower: float,
    upper: float,
    coordinate: float,
    max_step: float,
    step_fraction: float,
) -> VisualProbeMove | None:
    available_negative = max(0.0, coordinate - lower)
    available_positive = max(0.0, upper - coordinate)
    if available_negative <= 1e-9 and available_positive <= 1e-9:
        return None

    direction: Literal[-1, 1]
    if available_positive >= available_negative:
        direction = 1
        chosen_margin = available_positive
    else:
        direction = -1
        chosen_margin = available_negative

    if chosen_margin <= 1e-9:
        if direction == 1 and available_negative > 1e-9:
            direction = -1
            chosen_margin = available_negative
        elif direction == -1 and available_positive > 1e-9:
            direction = 1
            chosen_margin = available_positive
        else:
            return None

    step = min(max_step, chosen_margin * step_fraction)
    if step <= 1e-9:
        return None

    return VisualProbeMove(
        axis=axis,
        direction=direction,
        step_mm=step,
        relative_x_mm=direction * step if axis == "X" else 0.0,
        relative_y_mm=direction * step if axis == "Y" else 0.0,
        available_negative_mm=available_negative,
        available_positive_mm=available_positive,
        max_step_mm=max_step,
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


def _finite(value: float, *, label: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite.")
    return value
