from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.paper import Homography2D, PaperPointMM, solve_homography
from plotter_vision.controller.base import utc_now_iso

DEFAULT_DRAWING_CALIBRATION_RMS_LIMIT_MM = 8.0
DEFAULT_DRAWING_CALIBRATION_MAX_LIMIT_MM = 20.0

DrawingCalibrationStatus = Literal["collecting", "ready", "needs_more_evidence", "blocked"]


class DrawingFrameEdgeObservation(BaseModel):
    edge_index: int
    expected_start_mm: PaperPointMM
    expected_end_mm: PaperPointMM
    observed_start_mm: PaperPointMM | None = None
    observed_end_mm: PaperPointMM | None = None
    sample_count: int = 0
    detected_sample_count: int = 0
    green_pixel_count: int = 0
    coverage_fraction: float = 0.0
    rms_expected_residual_mm: float | None = None
    max_expected_residual_mm: float | None = None
    fit_rms_residual_mm: float | None = None
    angle_error_deg: float | None = None

    @field_validator("edge_index")
    @classmethod
    def _validate_edge_index(cls, value: int) -> int:
        if value < 1:
            raise ValueError("edge_index must be positive.")
        return value

    @field_validator("sample_count", "detected_sample_count", "green_pixel_count")
    @classmethod
    def _validate_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("drawing frame observation counts must be non-negative.")
        return value

    @field_validator(
        "coverage_fraction",
        "rms_expected_residual_mm",
        "max_expected_residual_mm",
        "fit_rms_residual_mm",
        "angle_error_deg",
    )
    @classmethod
    def _validate_optional_scalar(cls, value: float | None) -> float | None:
        if value is None:
            return None
        if not math.isfinite(value):
            raise ValueError("drawing frame edge values must be finite.")
        if value < 0.0:
            raise ValueError("drawing frame edge values must be non-negative.")
        return value


class DrawingFrameCornerObservation(BaseModel):
    corner_index: int
    expected_mm: PaperPointMM
    observed_mm: PaperPointMM
    residual_mm: float

    @field_validator("corner_index")
    @classmethod
    def _validate_corner_index(cls, value: int) -> int:
        if value < 1:
            raise ValueError("corner_index must be positive.")
        return value

    @field_validator("residual_mm")
    @classmethod
    def _validate_residual(cls, value: float) -> float:
        if not math.isfinite(value) or value < 0.0:
            raise ValueError("corner residual_mm must be finite and non-negative.")
        return value


class DrawingFrameObservation(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["drawing_frame_observation"] = "drawing_frame_observation"
    observation_id: str = Field(default_factory=lambda: f"drawing-frame-{uuid.uuid4().hex[:12]}")
    observed_at: str = Field(default_factory=utc_now_iso)
    command_id: str | None = None
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    field_width_mm: float
    field_height_mm: float
    expected_corners_mm: list[PaperPointMM] = Field(default_factory=list)
    edges: list[DrawingFrameEdgeObservation] = Field(default_factory=list)
    corners: list[DrawingFrameCornerObservation] = Field(default_factory=list)
    total_green_pixels: int = 0
    detected_edge_count: int = 0
    rms_residual_mm: float | None = None
    max_residual_mm: float | None = None
    corner_rms_residual_mm: float | None = None
    corner_max_residual_mm: float | None = None
    usable: bool = False

    @field_validator("field_width_mm", "field_height_mm")
    @classmethod
    def _validate_field_dimension(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("drawing field dimensions must be positive.")
        return value

    @field_validator("total_green_pixels", "detected_edge_count")
    @classmethod
    def _validate_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("drawing frame counts must be non-negative.")
        return value

    @field_validator(
        "rms_residual_mm",
        "max_residual_mm",
        "corner_rms_residual_mm",
        "corner_max_residual_mm",
    )
    @classmethod
    def _validate_optional_residual(cls, value: float | None) -> float | None:
        if value is None:
            return None
        if not math.isfinite(value) or value < 0.0:
            raise ValueError("drawing frame residuals must be finite and non-negative.")
        return value

    @model_validator(mode="after")
    def _validate_geometry(self) -> DrawingFrameObservation:
        if self.usable and (len(self.expected_corners_mm) < 4 or len(self.corners) < 4):
            raise ValueError("usable drawing frame observations require four expected and observed corners.")
        return self


class DrawingCalibrationModel(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["drawing_calibration_model"] = "drawing_calibration_model"
    model_id: str = Field(default_factory=lambda: f"drawing-cal-{uuid.uuid4().hex[:12]}")
    updated_at: str = Field(default_factory=utc_now_iso)
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    field_width_mm: float
    field_height_mm: float
    model_family: Literal["frame_homography_with_residual_field_v1"] = (
        "frame_homography_with_residual_field_v1"
    )
    solver_kind: Literal["none", "corner_homography"] = "none"
    validation_status: DrawingCalibrationStatus = "collecting"
    observation_count: int = 0
    usable_observation_count: int = 0
    latest_observation_id: str | None = None
    expected_to_observed: Homography2D | None = None
    observed_to_expected: Homography2D | None = None
    rms_residual_mm: float | None = None
    max_residual_mm: float | None = None
    corner_rms_residual_mm: float | None = None
    corner_max_residual_mm: float | None = None
    blockers: list[str] = Field(default_factory=list)
    frame_observations: list[DrawingFrameObservation] = Field(default_factory=list)

    @property
    def ready(self) -> bool:
        return self.validation_status == "ready" and not self.blockers

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> DrawingCalibrationModel:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))


def build_drawing_calibration_model(
    *,
    observations: list[DrawingFrameObservation],
    paper_registration_id: str,
    camera_id: str | None,
    camera_name: str | None,
    field_width_mm: float,
    field_height_mm: float,
    rms_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_RMS_LIMIT_MM,
    max_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_MAX_LIMIT_MM,
) -> DrawingCalibrationModel:
    usable = [
        observation
        for observation in observations
        if observation.usable and len(observation.corners) >= 4 and len(observation.expected_corners_mm) >= 4
    ]
    model = DrawingCalibrationModel(
        paper_registration_id=paper_registration_id,
        camera_id=camera_id,
        camera_name=camera_name,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        observation_count=len(observations),
        usable_observation_count=len(usable),
        frame_observations=observations,
    )
    if not observations:
        model.validation_status = "collecting"
        model.blockers = ["No drawing frame observations have been recorded."]
        return model
    latest = observations[-1]
    model.latest_observation_id = latest.observation_id
    model.rms_residual_mm = latest.rms_residual_mm
    model.max_residual_mm = latest.max_residual_mm
    model.corner_rms_residual_mm = latest.corner_rms_residual_mm
    model.corner_max_residual_mm = latest.corner_max_residual_mm

    if not usable:
        model.validation_status = "needs_more_evidence"
        model.blockers = ["No usable four-edge observed frame has been detected."]
        return model

    latest_usable = usable[-1]
    model.latest_observation_id = latest_usable.observation_id
    model.rms_residual_mm = latest_usable.rms_residual_mm
    model.max_residual_mm = latest_usable.max_residual_mm
    model.corner_rms_residual_mm = latest_usable.corner_rms_residual_mm
    model.corner_max_residual_mm = latest_usable.corner_max_residual_mm

    expected_points = [
        _normalize_mm(corner.expected_mm, field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for corner in sorted(latest_usable.corners, key=lambda item: item.corner_index)[:4]
    ]
    observed_points = [
        _normalize_mm(corner.observed_mm, field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for corner in sorted(latest_usable.corners, key=lambda item: item.corner_index)[:4]
    ]
    model.expected_to_observed = solve_homography(expected_points, observed_points)
    model.observed_to_expected = solve_homography(observed_points, expected_points)
    model.solver_kind = "corner_homography"

    blockers: list[str] = []
    if latest_usable.detected_edge_count < 4:
        blockers.append("Observed frame detection did not find all four edges.")
    if latest_usable.rms_residual_mm is None:
        blockers.append("Observed frame RMS residual is unavailable.")
    elif latest_usable.rms_residual_mm > rms_limit_mm:
        blockers.append(
            f"Observed frame RMS residual {latest_usable.rms_residual_mm:.1f}mm exceeds {rms_limit_mm:.1f}mm."
        )
    if latest_usable.max_residual_mm is None:
        blockers.append("Observed frame max residual is unavailable.")
    elif latest_usable.max_residual_mm > max_limit_mm:
        blockers.append(
            f"Observed frame max residual {latest_usable.max_residual_mm:.1f}mm exceeds {max_limit_mm:.1f}mm."
        )

    model.blockers = blockers
    model.validation_status = "ready" if not blockers else "needs_more_evidence"
    return model


def _normalize_mm(
    point: PaperPointMM,
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> tuple[float, float]:
    return (point.x / field_width_mm, point.y / field_height_mm)
