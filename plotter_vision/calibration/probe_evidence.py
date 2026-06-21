from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.readiness import ProbeAxis
from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    PaperPointNorm,
)
from plotter_vision.controller.base import utc_now_iso

VisualProbeSource = Literal[
    "motion_probe",
    "x_min_bootstrap",
    "center_target_residual",
    "center_target_segment",
    "x_field_recovery",
]
VisualProbeSampleStatus = Literal["accepted", "rejected", "blocked"]


class VisualProbeCapSnapshot(BaseModel):
    schema_version: int = 1
    camera_norm: CameraPointNorm
    paper_norm: PaperPointNorm
    logical_mm: LogicalPointMM
    frame_id: str | int
    confidence: float = 1.0

    @field_validator("confidence")
    @classmethod
    def _validate_confidence(cls, value: float) -> float:
        value = _finite(value, label="cap snapshot confidence")
        if value < 0.0 or value > 1.0:
            raise ValueError("cap snapshot confidence must be in [0, 1].")
        return value


class VisualProbeSample(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["visual_probe_sample"] = "visual_probe_sample"
    run_id: str
    sample_id: str = Field(default_factory=lambda: f"probe-sample-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    observed_at: str = Field(default_factory=utc_now_iso)
    request_id: str | None = None
    plan_id: str | None = None
    command_id: str | None = None
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    source: VisualProbeSource
    axis: ProbeAxis | None = None
    commanded_dx_mm: float
    commanded_dy_mm: float
    commanded_distance_mm: float = 0.0
    before: VisualProbeCapSnapshot
    after: VisualProbeCapSnapshot
    observed_dx_mm: float = 0.0
    observed_dy_mm: float = 0.0
    observed_distance_mm: float = 0.0
    predicted_dx_mm: float | None = None
    predicted_dy_mm: float | None = None
    predicted_distance_mm: float | None = None
    residual_mm: float | None = None
    residual_limit_mm: float | None = None
    status: VisualProbeSampleStatus = "accepted"
    blockers: list[str] = Field(default_factory=list)
    rejection_reason: str | None = None
    controller_transcript: str | None = None

    @field_validator(
        "commanded_dx_mm",
        "commanded_dy_mm",
        "commanded_distance_mm",
        "observed_dx_mm",
        "observed_dy_mm",
        "observed_distance_mm",
        "predicted_dx_mm",
        "predicted_dy_mm",
        "predicted_distance_mm",
        "residual_mm",
        "residual_limit_mm",
    )
    @classmethod
    def _validate_distance(cls, value: float | None) -> float | None:
        if value is None:
            return None
        value = _finite(value, label="probe sample distance")
        return value

    @model_validator(mode="after")
    def _derive_motion_fields(self) -> VisualProbeSample:
        self.commanded_distance_mm = math.hypot(self.commanded_dx_mm, self.commanded_dy_mm)
        self.observed_dx_mm = self.after.logical_mm.x - self.before.logical_mm.x
        self.observed_dy_mm = self.after.logical_mm.y - self.before.logical_mm.y
        self.observed_distance_mm = math.hypot(self.observed_dx_mm, self.observed_dy_mm)
        if self.predicted_dx_mm is not None and self.predicted_dy_mm is not None:
            self.predicted_distance_mm = math.hypot(self.predicted_dx_mm, self.predicted_dy_mm)
            if self.residual_mm is None:
                self.residual_mm = math.hypot(
                    self.observed_dx_mm - self.predicted_dx_mm,
                    self.observed_dy_mm - self.predicted_dy_mm,
                )
        if self.status == "rejected" and not (self.rejection_reason or self.blockers):
            raise ValueError("rejected probe samples require rejection_reason or blockers.")
        if self.status == "blocked" and not self.blockers:
            raise ValueError("blocked probe samples require blockers.")
        return self


class VisualProbeSummary(BaseModel):
    schema_version: int = 1
    raw_sample_count: int = 0
    accepted_sample_count: int = 0
    rejected_sample_count: int = 0
    stale_sample_count: int = 0
    axes_represented: list[ProbeAxis] = Field(default_factory=list)
    bootstrap_sample_count: int = 0
    adaptive_sample_count: int = 0
    center_target_sample_count: int = 0
    x_field_recovery_sample_count: int = 0
    rms_residual_mm: float | None = None
    max_residual_mm: float | None = None
    latest_sample_id: str | None = None
    latest_observed_at: str | None = None
    blockers: list[str] = Field(default_factory=list)

    @field_validator(
        "raw_sample_count",
        "accepted_sample_count",
        "rejected_sample_count",
        "stale_sample_count",
        "bootstrap_sample_count",
        "adaptive_sample_count",
        "center_target_sample_count",
        "x_field_recovery_sample_count",
    )
    @classmethod
    def _validate_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("probe summary counts must be non-negative.")
        return value

    @field_validator("rms_residual_mm", "max_residual_mm")
    @classmethod
    def _validate_residual(cls, value: float | None) -> float | None:
        if value is None:
            return None
        value = _finite(value, label="probe summary residual")
        if value < 0.0:
            raise ValueError("probe summary residuals must be non-negative.")
        return value


class VisualProbeRun(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["visual_probe_run"] = "visual_probe_run"
    run_id: str = Field(default_factory=lambda: f"probe-run-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    paper_registration_id: str | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    samples: list[VisualProbeSample] = Field(default_factory=list)
    summary: VisualProbeSummary = Field(default_factory=VisualProbeSummary)

    def upsert_sample(
        self,
        sample: VisualProbeSample,
        *,
        current_paper_registration_id: str | None,
        current_camera_id: str | None,
    ) -> VisualProbeRun:
        existing = {stored.sample_id: stored for stored in self.samples}
        existing[sample.sample_id] = sample
        self.samples = list(existing.values())
        if self.paper_registration_id is None:
            self.paper_registration_id = sample.paper_registration_id
        if self.camera_id is None and sample.camera_id is not None:
            self.camera_id = sample.camera_id
        if self.camera_name is None and sample.camera_name is not None:
            self.camera_name = sample.camera_name
        self.updated_at = utc_now_iso()
        self.summary = summarize_visual_probe_samples(
            self.samples,
            current_paper_registration_id=current_paper_registration_id,
            current_camera_id=current_camera_id,
        )
        return self

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> VisualProbeRun:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))


def summarize_visual_probe_samples(
    samples: list[VisualProbeSample],
    *,
    current_paper_registration_id: str | None,
    current_camera_id: str | None,
) -> VisualProbeSummary:
    raw_count = len(samples)
    current_samples = [
        sample
        for sample in samples
        if _sample_matches_current(
            sample,
            current_paper_registration_id=current_paper_registration_id,
            current_camera_id=current_camera_id,
        )
    ]
    stale_count = raw_count - len(current_samples)
    accepted = [sample for sample in current_samples if sample.status == "accepted"]
    rejected = [sample for sample in current_samples if sample.status == "rejected"]
    axes = sorted({sample.axis for sample in accepted if sample.axis is not None})
    rms, max_residual = _motion_residual_summary(accepted)
    latest_sample = max(samples, key=lambda sample: sample.observed_at, default=None)

    blockers: list[str] = []
    if stale_count:
        blockers.append(f"{stale_count} visual probe samples do not match current paper/camera.")
    if accepted and not {"X", "Y"}.issubset(set(axes)):
        blockers.append("Visual probe needs accepted current samples spanning X and Y axes.")

    return VisualProbeSummary(
        raw_sample_count=raw_count,
        accepted_sample_count=len(accepted),
        rejected_sample_count=len(rejected),
        stale_sample_count=stale_count,
        axes_represented=axes,
        bootstrap_sample_count=sum(1 for sample in accepted if sample.source == "x_min_bootstrap"),
        adaptive_sample_count=sum(1 for sample in accepted if sample.source == "motion_probe"),
        center_target_sample_count=sum(
            1
            for sample in accepted
            if sample.source in {"center_target_residual", "center_target_segment"}
        ),
        x_field_recovery_sample_count=sum(
            1 for sample in accepted if sample.source == "x_field_recovery"
        ),
        rms_residual_mm=rms,
        max_residual_mm=max_residual,
        latest_sample_id=latest_sample.sample_id if latest_sample is not None else None,
        latest_observed_at=latest_sample.observed_at if latest_sample is not None else None,
        blockers=blockers,
    )


def _sample_matches_current(
    sample: VisualProbeSample,
    *,
    current_paper_registration_id: str | None,
    current_camera_id: str | None,
) -> bool:
    if (
        current_paper_registration_id is not None
        and sample.paper_registration_id != current_paper_registration_id
    ):
        return False
    if current_camera_id and sample.camera_id and sample.camera_id != current_camera_id:
        return False
    return True


def _motion_residual_summary(samples: list[VisualProbeSample]) -> tuple[float | None, float | None]:
    if not samples:
        return (None, None)
    explicit_residuals = [sample.residual_mm for sample in samples if sample.residual_mm is not None]
    if len(explicit_residuals) == len(samples):
        return _residual_stats(explicit_residuals)

    residuals = _least_squares_motion_residuals(samples)
    if residuals is None:
        return (None, None)
    return _residual_stats(residuals)


def _least_squares_motion_residuals(samples: list[VisualProbeSample]) -> list[float] | None:
    if len(samples) < 2:
        return None
    sxx = sxy = syy = 0.0
    tx = ty = ux = uy = 0.0
    for sample in samples:
        x = sample.commanded_dx_mm
        y = sample.commanded_dy_mm
        sxx += x * x
        sxy += x * y
        syy += y * y
        tx += x * sample.observed_dx_mm
        ty += y * sample.observed_dx_mm
        ux += x * sample.observed_dy_mm
        uy += y * sample.observed_dy_mm
    determinant = sxx * syy - sxy * sxy
    if abs(determinant) <= 1.0:
        return None

    x_basis_dx = (tx * syy - ty * sxy) / determinant
    y_basis_dx = (sxx * ty - sxy * tx) / determinant
    x_basis_dy = (ux * syy - uy * sxy) / determinant
    y_basis_dy = (sxx * uy - sxy * ux) / determinant
    basis_determinant = x_basis_dx * y_basis_dy - y_basis_dx * x_basis_dy
    if abs(basis_determinant) <= 0.05:
        return None

    return [
        math.hypot(
            sample.observed_dx_mm
            - (x_basis_dx * sample.commanded_dx_mm + y_basis_dx * sample.commanded_dy_mm),
            sample.observed_dy_mm
            - (x_basis_dy * sample.commanded_dx_mm + y_basis_dy * sample.commanded_dy_mm),
        )
        for sample in samples
    ]


def _residual_stats(residuals: list[float]) -> tuple[float, float]:
    rms = math.sqrt(sum(residual * residual for residual in residuals) / len(residuals))
    return (rms, max(residuals))


def _finite(value: float, *, label: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{label} must be finite.")
    return value
