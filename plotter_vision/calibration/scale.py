from __future__ import annotations

from pydantic import BaseModel, Field

from plotter_vision.controller.base import utc_now_iso


class ScaleObservation(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    axis: str
    commanded_mm: float
    measured_mm: float
    observed_multiplier: float
    correction_multiplier: float
    current_steps_per_mm: float | None = None
    estimated_steps_per_mm: float | None = None
    note: str = "Observation only; no controller settings were written."


def build_scale_observation(
    *,
    axis: str,
    commanded_mm: float,
    measured_mm: float,
    current_steps_per_mm: float | None = None,
) -> ScaleObservation:
    normalized_axis = axis.upper()
    if normalized_axis not in {"X", "Y"}:
        raise ValueError("Only X and Y scale observations are supported in this phase.")
    if commanded_mm == 0:
        raise ValueError("commanded_mm must be non-zero.")
    if measured_mm == 0:
        raise ValueError("measured_mm must be non-zero.")

    observed_multiplier = measured_mm / commanded_mm
    correction_multiplier = commanded_mm / measured_mm
    estimated_steps = (
        current_steps_per_mm * correction_multiplier
        if current_steps_per_mm is not None
        else None
    )
    return ScaleObservation(
        axis=normalized_axis,
        commanded_mm=commanded_mm,
        measured_mm=measured_mm,
        observed_multiplier=observed_multiplier,
        correction_multiplier=correction_multiplier,
        current_steps_per_mm=current_steps_per_mm,
        estimated_steps_per_mm=estimated_steps,
    )
