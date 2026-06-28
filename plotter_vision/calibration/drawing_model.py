from __future__ import annotations

import itertools
import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from plotter_vision.calibration.paper import Homography2D, PaperPointMM, solve_homography
from plotter_vision.controller.base import utc_now_iso

DEFAULT_DRAWING_CALIBRATION_RMS_LIMIT_MM = 8.0
DEFAULT_DRAWING_CALIBRATION_MAX_LIMIT_MM = 20.0
DEFAULT_DRAWING_CALIBRATION_HOLDOUT_RMS_LIMIT_MM = 5.0
DEFAULT_DRAWING_CALIBRATION_HOLDOUT_MAX_LIMIT_MM = 12.0
DEFAULT_DRAWING_CALIBRATION_OUTLIER_LIMIT_MM = 10.0
DEFAULT_RESIDUAL_GRID_COLUMNS = 5
DEFAULT_RESIDUAL_GRID_ROWS = 5
DEFAULT_RESIDUAL_GRID_UNCERTAINTY_LIMIT_MM = 14.0
DEFAULT_RESIDUAL_GRID_MAX_CORRECTION_MM = 30.0
DEFAULT_RESIDUAL_GRID_MIN_COVERAGE_FRACTION = 0.2
DEFAULT_ACTION_RESIDUAL_REGULARIZATION = 4.0
DEFAULT_ACTION_RESIDUAL_MIN_SAMPLE_COUNT = 8
DEFAULT_ACTION_RESIDUAL_MAX_CORRECTION_MM = 5.0

DrawingCalibrationStatus = Literal["collecting", "ready", "needs_more_evidence", "blocked"]
DrawingCalibrationFreshness = Literal["unknown", "fresh", "stale"]
DrawingCalibrationModelVersion = Literal["residual_grid_v1"]
DrawingCalibrationCorrectionMode = Literal["uncorrected", "current_model", "validation", "retry"]
DrawingCalibrationSampleKind = Literal[
    "mark",
    "stroke_endpoint",
    "dense_edge_sample",
    "frame_corner",
    "frame_edge_endpoint",
    "circle",
    "arc",
]
DrawingCalibrationObservationKind = Literal[
    "marks",
    "stroke",
    "dense_edge",
    "frame",
    "circle",
    "arc",
    "synthetic",
    "mixed",
]
DrawingCalibrationSampleRole = Literal["fit", "holdout", "ignore"]
DrawingCalibrationActionKind = Literal[
    "mark",
    "stroke",
    "edge",
    "circle",
    "arc",
    "frame",
    "synthetic",
    "unknown",
]


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


class DrawingCalibrationActionMetadata(BaseModel):
    action_id: str | None = None
    command_id: str | None = None
    action_kind: DrawingCalibrationActionKind = "unknown"
    tool_id: str | None = None
    stroke_id: str | None = None
    sequence_index: int | None = None
    feed_mm_min: float | None = None
    pen_state: Literal["up", "down", "unknown"] = "unknown"
    features: dict[str, float] = Field(default_factory=dict)

    @field_validator("sequence_index")
    @classmethod
    def _validate_sequence_index(cls, value: int | None) -> int | None:
        if value is not None and value < 0:
            raise ValueError("sequence_index must be non-negative.")
        return value

    @field_validator("feed_mm_min")
    @classmethod
    def _validate_feed(cls, value: float | None) -> float | None:
        if value is None:
            return None
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("feed_mm_min must be positive.")
        return value

    @field_validator("features")
    @classmethod
    def _validate_features(cls, value: dict[str, float]) -> dict[str, float]:
        return {key: _finite_float(feature, f"action feature {key}") for key, feature in value.items()}


class DrawingCalibrationSample(BaseModel):
    sample_id: str = Field(default_factory=lambda: f"drawing-sample-{uuid.uuid4().hex[:12]}")
    sample_kind: DrawingCalibrationSampleKind
    expected_mm: PaperPointMM
    desired_mm: PaperPointMM | None = None
    commanded_mm: PaperPointMM | None = None
    predicted_observed_mm: PaperPointMM | None = None
    observed_mm: PaperPointMM
    correction_mode: DrawingCalibrationCorrectionMode = "uncorrected"
    model_id_used: str | None = None
    session_id: str | None = None
    batch_id: str | None = None
    run_id: str | None = None
    plan_hash: str | None = None
    primitive_id: str | None = None
    stroke_id: str | None = None
    sample_index: int | None = None
    role: DrawingCalibrationSampleRole = "fit"
    source_observation_id: str | None = None
    geometry_id: str | None = None
    weight: float = 1.0
    confidence: float = 1.0
    expected_radius_mm: float | None = None
    observed_radius_mm: float | None = None
    arc_start_angle_deg: float | None = None
    arc_end_angle_deg: float | None = None
    action_metadata: DrawingCalibrationActionMetadata | None = None
    action_features: dict[str, float] = Field(default_factory=dict)

    @field_validator("weight")
    @classmethod
    def _validate_weight(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("sample weight must be positive.")
        return value

    @field_validator("confidence")
    @classmethod
    def _validate_confidence(cls, value: float) -> float:
        if not math.isfinite(value) or value < 0.0 or value > 1.0:
            raise ValueError("sample confidence must be in [0, 1].")
        return value

    @field_validator(
        "expected_radius_mm",
        "observed_radius_mm",
        "arc_start_angle_deg",
        "arc_end_angle_deg",
    )
    @classmethod
    def _validate_optional_scalar(cls, value: float | None) -> float | None:
        if value is None:
            return None
        if not math.isfinite(value):
            raise ValueError("sample geometry scalars must be finite.")
        return value

    @field_validator("action_features")
    @classmethod
    def _validate_action_features(cls, value: dict[str, float]) -> dict[str, float]:
        return {key: _finite_float(feature, f"sample action feature {key}") for key, feature in value.items()}

    @field_validator("sample_index")
    @classmethod
    def _validate_sample_index(cls, value: int | None) -> int | None:
        if value is not None and value < 0:
            raise ValueError("sample_index must be non-negative.")
        return value

    @model_validator(mode="after")
    def _default_provenance_coordinates(self) -> DrawingCalibrationSample:
        if self.desired_mm is None:
            self.desired_mm = self.expected_mm
        if self.commanded_mm is None:
            self.commanded_mm = self.expected_mm
        if self.geometry_id is None and self.primitive_id is not None:
            self.geometry_id = self.primitive_id
        return self

    def feature_vector(self) -> dict[str, float]:
        features: dict[str, float] = {}
        if self.action_metadata is not None:
            features.update(self.action_metadata.features)
        features.update(self.action_features)
        return {
            key: value
            for key, value in features.items()
            if _is_production_action_feature(key) and math.isfinite(value)
        }


class DrawingCalibrationObservation(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["drawing_calibration_observation"] = "drawing_calibration_observation"
    observation_id: str = Field(default_factory=lambda: f"drawing-obs-{uuid.uuid4().hex[:12]}")
    observed_at: str = Field(default_factory=utc_now_iso)
    command_id: str | None = None
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    field_width_mm: float
    field_height_mm: float
    observation_kind: DrawingCalibrationObservationKind = "mixed"
    action_metadata: DrawingCalibrationActionMetadata | None = None
    samples: list[DrawingCalibrationSample] = Field(default_factory=list)
    usable: bool = True
    blockers: list[str] = Field(default_factory=list)

    @field_validator("field_width_mm", "field_height_mm")
    @classmethod
    def _validate_field_dimension(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("drawing calibration observation field dimensions must be positive.")
        return value

    @model_validator(mode="after")
    def _validate_samples(self) -> DrawingCalibrationObservation:
        if self.usable and not self.samples:
            raise ValueError("usable drawing calibration observations require at least one sample.")
        return self


class DrawingResidualGridNode(BaseModel):
    index_x: int
    index_y: int
    x_mm: float
    y_mm: float
    residual_x_mm: float
    residual_y_mm: float
    source_sample_count: int = 0
    nearest_sample_distance_mm: float | None = None
    uncertainty_mm: float

    @field_validator("index_x", "index_y", "source_sample_count")
    @classmethod
    def _validate_count(cls, value: int) -> int:
        if value < 0:
            raise ValueError("grid indices and counts must be non-negative.")
        return value

    @field_validator(
        "x_mm",
        "y_mm",
        "residual_x_mm",
        "residual_y_mm",
        "nearest_sample_distance_mm",
        "uncertainty_mm",
    )
    @classmethod
    def _validate_scalar(cls, value: float | None) -> float | None:
        if value is None:
            return None
        if not math.isfinite(value):
            raise ValueError("residual grid values must be finite.")
        return value


class DrawingResidualGridV1(BaseModel):
    model_version: DrawingCalibrationModelVersion = "residual_grid_v1"
    columns: int = DEFAULT_RESIDUAL_GRID_COLUMNS
    rows: int = DEFAULT_RESIDUAL_GRID_ROWS
    field_width_mm: float
    field_height_mm: float
    coverage_radius_mm: float
    uncertainty_limit_mm: float = DEFAULT_RESIDUAL_GRID_UNCERTAINTY_LIMIT_MM
    max_correction_mm: float = DEFAULT_RESIDUAL_GRID_MAX_CORRECTION_MM
    nodes: list[DrawingResidualGridNode] = Field(default_factory=list)

    @field_validator("columns", "rows")
    @classmethod
    def _validate_grid_dimension(cls, value: int) -> int:
        if value < 2:
            raise ValueError("residual grid dimensions must be at least 2.")
        return value

    @field_validator(
        "field_width_mm",
        "field_height_mm",
        "coverage_radius_mm",
        "uncertainty_limit_mm",
        "max_correction_mm",
    )
    @classmethod
    def _validate_positive_scalar(cls, value: float) -> float:
        if not math.isfinite(value) or value <= 0.0:
            raise ValueError("residual grid scalar values must be positive.")
        return value

    @model_validator(mode="after")
    def _validate_nodes(self) -> DrawingResidualGridV1:
        expected_count = self.columns * self.rows
        if self.nodes and len(self.nodes) != expected_count:
            raise ValueError("residual grid node count must equal columns * rows.")
        return self

    def residual_at(self, x_mm: float, y_mm: float) -> tuple[float, float]:
        node_values = self._interpolate_node_values(x_mm, y_mm)
        return (node_values[0], node_values[1])

    def uncertainty_at(self, x_mm: float, y_mm: float) -> float:
        return self._interpolate_node_values(x_mm, y_mm)[2]

    def in_coverage(self, x_mm: float, y_mm: float, *, uncertainty_limit_mm: float | None = None) -> bool:
        if x_mm < 0.0 or y_mm < 0.0 or x_mm > self.field_width_mm or y_mm > self.field_height_mm:
            return False
        limit = uncertainty_limit_mm if uncertainty_limit_mm is not None else self.uncertainty_limit_mm
        return self.uncertainty_at(x_mm, y_mm) <= limit

    def _interpolate_node_values(self, x_mm: float, y_mm: float) -> tuple[float, float, float]:
        if not self.nodes:
            return (0.0, 0.0, self.uncertainty_limit_mm * 10.0)
        x = _clamp(x_mm, 0.0, self.field_width_mm)
        y = _clamp(y_mm, 0.0, self.field_height_mm)
        gx = (x / self.field_width_mm) * (self.columns - 1)
        gy = (y / self.field_height_mm) * (self.rows - 1)
        x0 = min(int(math.floor(gx)), self.columns - 2)
        y0 = min(int(math.floor(gy)), self.rows - 2)
        x1 = x0 + 1
        y1 = y0 + 1
        tx = gx - x0
        ty = gy - y0

        n00 = self._node(x0, y0)
        n10 = self._node(x1, y0)
        n01 = self._node(x0, y1)
        n11 = self._node(x1, y1)
        return (
            _bilinear(n00.residual_x_mm, n10.residual_x_mm, n01.residual_x_mm, n11.residual_x_mm, tx, ty),
            _bilinear(n00.residual_y_mm, n10.residual_y_mm, n01.residual_y_mm, n11.residual_y_mm, tx, ty),
            _bilinear(n00.uncertainty_mm, n10.uncertainty_mm, n01.uncertainty_mm, n11.uncertainty_mm, tx, ty),
        )

    def _node(self, index_x: int, index_y: int) -> DrawingResidualGridNode:
        return self.nodes[index_y * self.columns + index_x]


class DrawingCalibrationCoverage(BaseModel):
    field_width_mm: float
    field_height_mm: float
    sample_count: int = 0
    accepted_sample_count: int = 0
    holdout_sample_count: int = 0
    min_x_mm: float | None = None
    max_x_mm: float | None = None
    min_y_mm: float | None = None
    max_y_mm: float | None = None
    total_node_count: int = 0
    covered_node_count: int = 0
    coverage_fraction: float = 0.0
    coverage_radius_mm: float = 0.0
    uncertainty_limit_mm: float = DEFAULT_RESIDUAL_GRID_UNCERTAINTY_LIMIT_MM
    max_node_uncertainty_mm: float | None = None


class DrawingCalibrationMetrics(BaseModel):
    sample_count: int = 0
    rms_mm: float | None = None
    p95_mm: float | None = None
    max_mm: float | None = None


class DrawingActionResidualCoefficient(BaseModel):
    feature_name: str
    residual_x_mm: float
    residual_y_mm: float
    sample_count: int
    regularization: float = DEFAULT_ACTION_RESIDUAL_REGULARIZATION
    rms_remaining_mm: float | None = None


class DrawingTargetCorrection(BaseModel):
    desired_mm: PaperPointMM
    commanded_mm: PaperPointMM
    predicted_observed_mm: PaperPointMM | None = None
    correction_x_mm: float = 0.0
    correction_y_mm: float = 0.0
    correction_norm_mm: float = 0.0
    uncertainty_mm: float | None = None
    in_coverage: bool = False
    iterations: int = 0
    blockers: list[str] = Field(default_factory=list)

    @property
    def usable(self) -> bool:
        return not self.blockers


class DrawingCalibrationModel(BaseModel):
    schema_version: int = 2
    artifact_type: Literal["drawing_calibration_model"] = "drawing_calibration_model"
    model_id: str = Field(default_factory=lambda: f"drawing-cal-{uuid.uuid4().hex[:12]}")
    updated_at: str = Field(default_factory=utc_now_iso)
    model_version: str = "residual_grid_v1"
    paper_registration_id: str
    camera_id: str | None = None
    camera_name: str | None = None
    field_width_mm: float
    field_height_mm: float
    model_family: Literal["residual_grid_v1"] = "residual_grid_v1"
    solver_kind: Literal["none", "corner_homography", "homography_baseline", "residual_grid_v1"] = "none"
    global_model_kind: Literal["identity", "homography"] = "identity"
    validation_status: DrawingCalibrationStatus = "collecting"
    freshness_status: DrawingCalibrationFreshness = "unknown"
    observation_count: int = 0
    usable_observation_count: int = 0
    sample_count: int = 0
    fit_sample_count: int = 0
    accepted_fit_sample_count: int = 0
    rejected_sample_count: int = 0
    holdout_sample_count: int = 0
    latest_observation_id: str | None = None
    expected_to_observed: Homography2D | None = None
    observed_to_expected: Homography2D | None = None
    residual_grid: DrawingResidualGridV1 | None = None
    action_model_kind: Literal["none", "regularized_linear_v1"] = "none"
    action_feature_names: list[str] = Field(default_factory=list)
    action_residual_coefficients: list[DrawingActionResidualCoefficient] = Field(default_factory=list)
    action_regularization: float | None = None
    action_max_correction_mm: float = DEFAULT_ACTION_RESIDUAL_MAX_CORRECTION_MM
    action_fit_metrics_without_action_residuals: DrawingCalibrationMetrics | None = None
    action_fit_metrics_with_action_residuals: DrawingCalibrationMetrics | None = None
    action_model_blockers: list[str] = Field(default_factory=list)
    coverage: DrawingCalibrationCoverage | None = None
    fit_metrics: DrawingCalibrationMetrics | None = None
    holdout_metrics: DrawingCalibrationMetrics | None = None
    validation_metrics: DrawingCalibrationMetrics | None = None
    rms_residual_mm: float | None = None
    p95_residual_mm: float | None = None
    max_residual_mm: float | None = None
    corner_rms_residual_mm: float | None = None
    corner_max_residual_mm: float | None = None
    blockers: list[str] = Field(default_factory=list)
    stale_reasons: list[str] = Field(default_factory=list)
    rejected_sample_ids: list[str] = Field(default_factory=list)
    observations: list[DrawingCalibrationObservation] = Field(default_factory=list)
    frame_observations: list[DrawingFrameObservation] = Field(default_factory=list)

    @property
    def ready(self) -> bool:
        return self.validation_status == "ready" and self.freshness_status != "stale" and not self.blockers

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> DrawingCalibrationModel:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))

    def stale_reasons_for(
        self,
        *,
        paper_registration_id: str,
        camera_id: str | None = None,
    ) -> list[str]:
        reasons: list[str] = []
        if self.paper_registration_id != paper_registration_id:
            reasons.append("Drawing calibration paper_registration_id does not match the current Drawing Border.")
        if camera_id is not None and self.camera_id is not None and self.camera_id != camera_id:
            reasons.append("Drawing calibration camera_id does not match the current plotter camera.")
        if self.freshness_status == "stale":
            reasons.extend(reason for reason in self.stale_reasons if reason not in reasons)
        return reasons

    def is_fresh_for(
        self,
        *,
        paper_registration_id: str,
        camera_id: str | None = None,
    ) -> bool:
        return not self.stale_reasons_for(
            paper_registration_id=paper_registration_id,
            camera_id=camera_id,
        )

    def apply_expected_to_observed(
        self,
        expected_mm: PaperPointMM,
        *,
        action_features: dict[str, float] | None = None,
        include_action_residual: bool = True,
    ) -> PaperPointMM:
        base_x, base_y = _apply_global_model(
            self.expected_to_observed,
            expected_mm,
            field_width_mm=self.field_width_mm,
            field_height_mm=self.field_height_mm,
        )
        residual_x = 0.0
        residual_y = 0.0
        if self.residual_grid is not None:
            residual_x, residual_y = self.residual_grid.residual_at(expected_mm.x, expected_mm.y)
        if include_action_residual:
            action_x, action_y = self.action_residual_for_features(action_features or {})
            residual_x += action_x
            residual_y += action_y
        return PaperPointMM(x=base_x + residual_x, y=base_y + residual_y)

    def action_residual_for_features(self, action_features: dict[str, float]) -> tuple[float, float]:
        if not self.action_residual_coefficients or not action_features:
            return (0.0, 0.0)
        residual_x = 0.0
        residual_y = 0.0
        for coefficient in self.action_residual_coefficients:
            feature_value = action_features.get(coefficient.feature_name, 0.0)
            if not math.isfinite(feature_value):
                continue
            residual_x += coefficient.residual_x_mm * feature_value
            residual_y += coefficient.residual_y_mm * feature_value
        norm = math.hypot(residual_x, residual_y)
        if norm > self.action_max_correction_mm > 0.0:
            scale = self.action_max_correction_mm / norm
            residual_x *= scale
            residual_y *= scale
        return (residual_x, residual_y)

    def correct_target_for_planning(
        self,
        desired_mm: PaperPointMM,
        *,
        action_features: dict[str, float] | None = None,
        max_correction_mm: float | None = None,
        uncertainty_limit_mm: float | None = None,
        max_iterations: int = 8,
    ) -> DrawingTargetCorrection:
        blockers: list[str] = []
        if not self.ready:
            blockers.append("Drawing calibration is not ready.")
        if self.residual_grid is None:
            blockers.append("Drawing calibration has no residual_grid_v1 model.")
        if desired_mm.x < 0.0 or desired_mm.y < 0.0:
            blockers.append("Desired drawing target is outside the calibrated field.")
        if desired_mm.x > self.field_width_mm or desired_mm.y > self.field_height_mm:
            blockers.append("Desired drawing target is outside the calibrated field.")

        grid = self.residual_grid
        uncertainty = None
        in_coverage = False
        if grid is not None:
            uncertainty = grid.uncertainty_at(desired_mm.x, desired_mm.y)
            in_coverage = grid.in_coverage(
                desired_mm.x,
                desired_mm.y,
                uncertainty_limit_mm=uncertainty_limit_mm,
            )
            if not in_coverage:
                blockers.append("Desired drawing target is outside residual grid coverage.")

        if blockers:
            return DrawingTargetCorrection(
                desired_mm=desired_mm,
                commanded_mm=desired_mm,
                uncertainty_mm=uncertainty,
                in_coverage=in_coverage,
                blockers=blockers,
            )

        assert grid is not None
        limit = max_correction_mm if max_correction_mm is not None else grid.max_correction_mm
        commanded = PaperPointMM(x=desired_mm.x, y=desired_mm.y)
        predicted = self.apply_expected_to_observed(
            commanded,
            action_features=action_features,
        )
        iterations = 0
        for iterations in range(1, max_iterations + 1):
            error_x = predicted.x - desired_mm.x
            error_y = predicted.y - desired_mm.y
            if math.hypot(error_x, error_y) < 0.01:
                break
            commanded = PaperPointMM(
                x=_clamp(commanded.x - error_x, 0.0, self.field_width_mm),
                y=_clamp(commanded.y - error_y, 0.0, self.field_height_mm),
            )
            if not grid.in_coverage(
                commanded.x,
                commanded.y,
                uncertainty_limit_mm=uncertainty_limit_mm,
            ):
                blockers.append("Inverse correction left residual grid coverage.")
                break
            predicted = self.apply_expected_to_observed(
                commanded,
                action_features=action_features,
            )

        correction_x = commanded.x - desired_mm.x
        correction_y = commanded.y - desired_mm.y
        correction_norm = math.hypot(correction_x, correction_y)
        if correction_norm > limit:
            scale = limit / correction_norm
            commanded = PaperPointMM(
                x=_clamp(desired_mm.x + correction_x * scale, 0.0, self.field_width_mm),
                y=_clamp(desired_mm.y + correction_y * scale, 0.0, self.field_height_mm),
            )
            predicted = self.apply_expected_to_observed(
                commanded,
                action_features=action_features,
            )
            correction_x = commanded.x - desired_mm.x
            correction_y = commanded.y - desired_mm.y
            correction_norm = math.hypot(correction_x, correction_y)
            blockers.append("Inverse correction exceeded the configured correction bound.")

        return DrawingTargetCorrection(
            desired_mm=desired_mm,
            commanded_mm=commanded,
            predicted_observed_mm=predicted,
            correction_x_mm=correction_x,
            correction_y_mm=correction_y,
            correction_norm_mm=correction_norm,
            uncertainty_mm=grid.uncertainty_at(commanded.x, commanded.y),
            in_coverage=not blockers,
            iterations=iterations,
            blockers=blockers,
        )


def drawing_observation_from_frame_observation(
    observation: DrawingFrameObservation,
) -> DrawingCalibrationObservation:
    action = DrawingCalibrationActionMetadata(
        action_id=observation.observation_id,
        command_id=observation.command_id,
        action_kind="frame",
        features={"frame_observation": 1.0},
    )
    samples: list[DrawingCalibrationSample] = []
    seen: set[tuple[str, int, int]] = set()

    for corner in sorted(observation.corners, key=lambda item: item.corner_index):
        sample = DrawingCalibrationSample(
            sample_id=f"{observation.observation_id}-corner-{corner.corner_index}",
            sample_kind="frame_corner",
            expected_mm=corner.expected_mm,
            desired_mm=corner.expected_mm,
            commanded_mm=corner.expected_mm,
            observed_mm=corner.observed_mm,
            correction_mode="uncorrected",
            source_observation_id=observation.observation_id,
            geometry_id=f"corner-{corner.corner_index}",
            primitive_id=f"corner-{corner.corner_index}",
            sample_index=corner.corner_index,
            confidence=1.0,
            action_metadata=action,
        )
        _append_unique_sample(samples, seen, sample)

    for edge in sorted(observation.edges, key=lambda item: item.edge_index):
        if edge.observed_start_mm is not None:
            sample = DrawingCalibrationSample(
                sample_id=f"{observation.observation_id}-edge-{edge.edge_index}-start",
                sample_kind="frame_edge_endpoint",
                expected_mm=edge.expected_start_mm,
                desired_mm=edge.expected_start_mm,
                commanded_mm=edge.expected_start_mm,
                observed_mm=edge.observed_start_mm,
                correction_mode="uncorrected",
                source_observation_id=observation.observation_id,
                geometry_id=f"edge-{edge.edge_index}",
                primitive_id=f"edge-{edge.edge_index}",
                sample_index=edge.edge_index * 2,
                confidence=_edge_confidence(edge),
                action_metadata=action,
            )
            _append_unique_sample(samples, seen, sample)
        if edge.observed_end_mm is not None:
            sample = DrawingCalibrationSample(
                sample_id=f"{observation.observation_id}-edge-{edge.edge_index}-end",
                sample_kind="frame_edge_endpoint",
                expected_mm=edge.expected_end_mm,
                desired_mm=edge.expected_end_mm,
                commanded_mm=edge.expected_end_mm,
                observed_mm=edge.observed_end_mm,
                correction_mode="uncorrected",
                source_observation_id=observation.observation_id,
                geometry_id=f"edge-{edge.edge_index}",
                primitive_id=f"edge-{edge.edge_index}",
                sample_index=edge.edge_index * 2 + 1,
                confidence=_edge_confidence(edge),
                action_metadata=action,
            )
            _append_unique_sample(samples, seen, sample)

    return DrawingCalibrationObservation(
        observation_id=observation.observation_id,
        observed_at=observation.observed_at,
        command_id=observation.command_id,
        paper_registration_id=observation.paper_registration_id,
        camera_id=observation.camera_id,
        camera_name=observation.camera_name,
        field_width_mm=observation.field_width_mm,
        field_height_mm=observation.field_height_mm,
        observation_kind="frame",
        action_metadata=action,
        samples=samples,
        usable=observation.usable and bool(samples),
        blockers=[] if observation.usable else ["Frame observation was not marked usable."],
    )


def build_drawing_calibration_model(
    *,
    observations: list[DrawingCalibrationObservation | DrawingFrameObservation],
    paper_registration_id: str,
    camera_id: str | None,
    camera_name: str | None,
    field_width_mm: float,
    field_height_mm: float,
    rms_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_RMS_LIMIT_MM,
    max_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_MAX_LIMIT_MM,
    holdout_rms_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_HOLDOUT_RMS_LIMIT_MM,
    holdout_max_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_HOLDOUT_MAX_LIMIT_MM,
    outlier_limit_mm: float = DEFAULT_DRAWING_CALIBRATION_OUTLIER_LIMIT_MM,
    residual_grid_columns: int = DEFAULT_RESIDUAL_GRID_COLUMNS,
    residual_grid_rows: int = DEFAULT_RESIDUAL_GRID_ROWS,
    residual_grid_uncertainty_limit_mm: float = DEFAULT_RESIDUAL_GRID_UNCERTAINTY_LIMIT_MM,
    residual_grid_max_correction_mm: float = DEFAULT_RESIDUAL_GRID_MAX_CORRECTION_MM,
    minimum_coverage_fraction: float = DEFAULT_RESIDUAL_GRID_MIN_COVERAGE_FRACTION,
) -> DrawingCalibrationModel:
    frame_observations, generic_observations = _normalize_observations(observations)
    model = DrawingCalibrationModel(
        paper_registration_id=paper_registration_id,
        camera_id=camera_id,
        camera_name=camera_name,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        observation_count=len(generic_observations),
        usable_observation_count=sum(1 for observation in generic_observations if observation.usable),
        observations=generic_observations,
        frame_observations=frame_observations,
    )

    if not generic_observations:
        model.validation_status = "collecting"
        model.freshness_status = "unknown"
        model.blockers = ["No drawing calibration observations have been recorded."]
        return model

    model.latest_observation_id = generic_observations[-1].observation_id
    fresh_observations, stale_reasons = _filter_fresh_observations(
        generic_observations,
        paper_registration_id=paper_registration_id,
        camera_id=camera_id,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    )
    model.stale_reasons = stale_reasons
    model.freshness_status = "stale" if stale_reasons and not fresh_observations else "fresh"
    if not fresh_observations:
        model.validation_status = "blocked"
        model.freshness_status = "stale"
        model.blockers = stale_reasons or ["No observations match the current Drawing Border."]
        return model

    samples = [
        sample
        for observation in fresh_observations
        if observation.usable
        for sample in observation.samples
        if sample.role != "ignore" and sample.confidence > 0.0
    ]
    model.sample_count = len(samples)
    fit_samples = [sample for sample in samples if sample.role == "fit"]
    holdout_samples = [sample for sample in samples if sample.role == "holdout"]
    model.fit_sample_count = len(fit_samples)
    model.holdout_sample_count = len(holdout_samples)
    model.coverage = _build_empty_coverage(
        samples,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        holdout_sample_count=len(holdout_samples),
        uncertainty_limit_mm=residual_grid_uncertainty_limit_mm,
    )

    if len(fit_samples) < 4:
        model.validation_status = "needs_more_evidence"
        model.blockers = ["At least four fit samples are required for drawing calibration."]
        return model

    try:
        baseline = _solve_sample_homography(
            fit_samples,
            field_width_mm=field_width_mm,
            field_height_mm=field_height_mm,
        )
    except ValueError as exc:
        model.validation_status = "blocked"
        model.blockers = [str(exc)]
        return model

    rejected_ids = _reject_outliers(
        fit_samples,
        baseline,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        outlier_limit_mm=outlier_limit_mm,
    )
    accepted_fit_samples = [sample for sample in fit_samples if sample.sample_id not in rejected_ids]
    if len(accepted_fit_samples) < 4:
        model.validation_status = "needs_more_evidence"
        model.rejected_sample_ids = sorted(rejected_ids)
        model.rejected_sample_count = len(rejected_ids)
        model.blockers = ["Outlier rejection left fewer than four fit samples."]
        return model

    if rejected_ids:
        baseline = _solve_sample_homography(
            accepted_fit_samples,
            field_width_mm=field_width_mm,
            field_height_mm=field_height_mm,
        )

    model.expected_to_observed = baseline
    model.observed_to_expected = _solve_reverse_sample_homography(
        accepted_fit_samples,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    )
    model.global_model_kind = "homography"
    model.solver_kind = "residual_grid_v1"
    model.accepted_fit_sample_count = len(accepted_fit_samples)
    model.rejected_sample_ids = sorted(rejected_ids)
    model.rejected_sample_count = len(rejected_ids)

    sample_residuals = [
        _sample_residual_after_global_model(
            sample,
            baseline,
            field_width_mm=field_width_mm,
            field_height_mm=field_height_mm,
        )
        for sample in accepted_fit_samples
    ]
    grid = _build_residual_grid(
        accepted_fit_samples,
        sample_residuals,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        columns=residual_grid_columns,
        rows=residual_grid_rows,
        uncertainty_limit_mm=residual_grid_uncertainty_limit_mm,
        max_correction_mm=residual_grid_max_correction_mm,
    )
    model.residual_grid = grid
    model.coverage = _build_coverage(
        accepted_fit_samples,
        holdout_samples,
        grid,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    )

    model.action_fit_metrics_without_action_residuals = _evaluate_fit_samples(
        model,
        accepted_fit_samples,
        include_action_residual=False,
    )
    model.action_residual_coefficients = _fit_action_residuals(model, accepted_fit_samples)
    model.action_feature_names = [coefficient.feature_name for coefficient in model.action_residual_coefficients]
    if model.action_residual_coefficients:
        model.action_model_kind = "regularized_linear_v1"
        model.action_regularization = DEFAULT_ACTION_RESIDUAL_REGULARIZATION
    else:
        model.action_model_kind = "none"
        model.action_model_blockers = [
            f"Action residual model requires at least {DEFAULT_ACTION_RESIDUAL_MIN_SAMPLE_COUNT} usable samples per feature."
        ]
    model.action_fit_metrics_with_action_residuals = _evaluate_fit_samples(
        model,
        accepted_fit_samples,
        include_action_residual=True,
    )
    fit_metrics = model.action_fit_metrics_with_action_residuals
    holdout_metrics = _evaluate_validation_samples(model, holdout_samples)
    model.fit_metrics = fit_metrics
    model.holdout_metrics = holdout_metrics if holdout_samples else None
    model.validation_metrics = holdout_metrics if holdout_samples else _evaluate_validation_samples(model, accepted_fit_samples)
    model.rms_residual_mm = fit_metrics.rms_mm
    model.p95_residual_mm = fit_metrics.p95_mm
    model.max_residual_mm = fit_metrics.max_mm
    model.corner_rms_residual_mm = fit_metrics.rms_mm
    model.corner_max_residual_mm = fit_metrics.max_mm

    blockers: list[str] = []
    if fit_metrics.rms_mm is None:
        blockers.append("Drawing calibration RMS residual is unavailable.")
    elif fit_metrics.rms_mm > rms_limit_mm:
        blockers.append(f"Drawing calibration RMS residual {fit_metrics.rms_mm:.1f}mm exceeds {rms_limit_mm:.1f}mm.")
    if fit_metrics.max_mm is None:
        blockers.append("Drawing calibration max residual is unavailable.")
    elif fit_metrics.max_mm > max_limit_mm:
        blockers.append(f"Drawing calibration max residual {fit_metrics.max_mm:.1f}mm exceeds {max_limit_mm:.1f}mm.")
    if model.coverage is not None and model.coverage.coverage_fraction < minimum_coverage_fraction:
        blockers.append(
            "Drawing calibration residual grid coverage "
            f"{model.coverage.coverage_fraction:.2f} is below {minimum_coverage_fraction:.2f}."
        )
    if holdout_samples and holdout_metrics.rms_mm is not None and holdout_metrics.rms_mm > holdout_rms_limit_mm:
        blockers.append(
            f"Drawing calibration holdout RMS residual {holdout_metrics.rms_mm:.1f}mm "
            f"exceeds {holdout_rms_limit_mm:.1f}mm."
        )
    if holdout_samples and holdout_metrics.max_mm is not None and holdout_metrics.max_mm > holdout_max_limit_mm:
        blockers.append(
            f"Drawing calibration holdout max residual {holdout_metrics.max_mm:.1f}mm "
            f"exceeds {holdout_max_limit_mm:.1f}mm."
        )

    model.blockers = blockers
    if any("holdout" in blocker for blocker in blockers):
        model.validation_status = "blocked"
    else:
        model.validation_status = "ready" if not blockers else "needs_more_evidence"
    return model


def _normalize_observations(
    observations: list[DrawingCalibrationObservation | DrawingFrameObservation],
) -> tuple[list[DrawingFrameObservation], list[DrawingCalibrationObservation]]:
    frame_observations: list[DrawingFrameObservation] = []
    generic_observations: list[DrawingCalibrationObservation] = []
    for observation in observations:
        if isinstance(observation, DrawingFrameObservation):
            frame_observations.append(observation)
            generic_observations.append(drawing_observation_from_frame_observation(observation))
        else:
            generic_observations.append(observation)
    return frame_observations, generic_observations


def _filter_fresh_observations(
    observations: list[DrawingCalibrationObservation],
    *,
    paper_registration_id: str,
    camera_id: str | None,
    field_width_mm: float,
    field_height_mm: float,
) -> tuple[list[DrawingCalibrationObservation], list[str]]:
    fresh: list[DrawingCalibrationObservation] = []
    stale_reasons: list[str] = []
    for observation in observations:
        reasons: list[str] = []
        if observation.paper_registration_id != paper_registration_id:
            reasons.append(
                f"Observation {observation.observation_id} paper_registration_id does not match the current Drawing Border."
            )
        if camera_id is not None and observation.camera_id is not None and observation.camera_id != camera_id:
            reasons.append(f"Observation {observation.observation_id} camera_id does not match the current camera.")
        if not _same_dimension(observation.field_width_mm, field_width_mm) or not _same_dimension(
            observation.field_height_mm,
            field_height_mm,
        ):
            reasons.append(f"Observation {observation.observation_id} field size does not match the current Drawing Border.")
        if reasons:
            stale_reasons.extend(reasons)
        else:
            fresh.append(observation)
    return fresh, stale_reasons


def _solve_sample_homography(
    samples: list[DrawingCalibrationSample],
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> Homography2D:
    source_points = [
        _normalize_mm(_fit_input_mm(sample), field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for sample in samples
    ]
    target_points = [
        _normalize_mm(sample.observed_mm, field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for sample in samples
    ]
    return solve_homography(source_points, target_points)


def _solve_reverse_sample_homography(
    samples: list[DrawingCalibrationSample],
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> Homography2D:
    source_points = [
        _normalize_mm(sample.observed_mm, field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for sample in samples
    ]
    target_points = [
        _normalize_mm(_fit_input_mm(sample), field_width_mm=field_width_mm, field_height_mm=field_height_mm)
        for sample in samples
    ]
    return solve_homography(source_points, target_points)


def _reject_outliers(
    samples: list[DrawingCalibrationSample],
    baseline: Homography2D,
    *,
    field_width_mm: float,
    field_height_mm: float,
    outlier_limit_mm: float,
) -> set[str]:
    if len(samples) < 6:
        return set()
    detection_baseline = _best_outlier_detection_baseline(
        samples,
        fallback=baseline,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        outlier_limit_mm=outlier_limit_mm,
    )
    residuals = [
        _norm(
            *_sample_residual_after_global_model(
                sample,
                detection_baseline,
                field_width_mm=field_width_mm,
                field_height_mm=field_height_mm,
            )
        )
        for sample in samples
    ]
    median = _percentile(residuals, 0.5)
    absolute_deviations = [abs(value - median) for value in residuals]
    mad = _percentile(absolute_deviations, 0.5)
    threshold = max(outlier_limit_mm, median + 6.0 * mad)
    return {
        sample.sample_id
        for sample, residual in zip(samples, residuals)
        if residual > threshold and residual > median * 2.5
    }


def _best_outlier_detection_baseline(
    samples: list[DrawingCalibrationSample],
    *,
    fallback: Homography2D,
    field_width_mm: float,
    field_height_mm: float,
    outlier_limit_mm: float,
) -> Homography2D:
    best_baseline = fallback
    best_score = _outlier_baseline_score(
        fallback,
        samples,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        outlier_limit_mm=outlier_limit_mm,
    )
    for indices in _candidate_baseline_index_sets(
        samples,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    ):
        candidate_samples = [samples[index] for index in indices]
        try:
            candidate = _solve_sample_homography(
                candidate_samples,
                field_width_mm=field_width_mm,
                field_height_mm=field_height_mm,
            )
        except ValueError:
            continue
        score = _outlier_baseline_score(
            candidate,
            samples,
            field_width_mm=field_width_mm,
            field_height_mm=field_height_mm,
            outlier_limit_mm=outlier_limit_mm,
        )
        if score > best_score:
            best_score = score
            best_baseline = candidate
    return best_baseline


def _candidate_baseline_index_sets(
    samples: list[DrawingCalibrationSample],
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> list[tuple[int, int, int, int]]:
    candidates: list[tuple[int, int, int, int]] = []
    corner_targets = [
        (0.0, 0.0),
        (field_width_mm, 0.0),
        (field_width_mm, field_height_mm),
        (0.0, field_height_mm),
    ]
    corner_indices: list[int] = []
    for target_x, target_y in corner_targets:
        corner_indices.append(
            min(
                range(len(samples)),
                key=lambda index: math.hypot(
                    samples[index].expected_mm.x - target_x,
                    samples[index].expected_mm.y - target_y,
                ),
            )
        )
    if len(set(corner_indices)) == 4:
        candidates.append(tuple(corner_indices))  # type: ignore[arg-type]

    if len(samples) <= 30:
        candidates.extend(itertools.combinations(range(len(samples)), 4))
    return candidates


def _outlier_baseline_score(
    baseline: Homography2D,
    samples: list[DrawingCalibrationSample],
    *,
    field_width_mm: float,
    field_height_mm: float,
    outlier_limit_mm: float,
) -> tuple[int, float, float]:
    residuals: list[float] = []
    for sample in samples:
        try:
            residuals.append(
                _norm(
                    *_sample_residual_after_global_model(
                        sample,
                        baseline,
                        field_width_mm=field_width_mm,
                        field_height_mm=field_height_mm,
                    )
                )
            )
        except ValueError:
            return (-1, float("-inf"), float("-inf"))
    inlier_count = sum(1 for residual in residuals if residual <= outlier_limit_mm)
    return (inlier_count, -_percentile(residuals, 0.5), -_rms(residuals))


def _build_residual_grid(
    samples: list[DrawingCalibrationSample],
    residuals: list[tuple[float, float]],
    *,
    field_width_mm: float,
    field_height_mm: float,
    columns: int,
    rows: int,
    uncertainty_limit_mm: float,
    max_correction_mm: float,
) -> DrawingResidualGridV1:
    x_step = field_width_mm / (columns - 1)
    y_step = field_height_mm / (rows - 1)
    coverage_radius = max(x_step, y_step) * 1.75
    sigma = max(x_step, y_step) * 1.15
    nodes: list[DrawingResidualGridNode] = []
    for index_y in range(rows):
        y_mm = y_step * index_y
        for index_x in range(columns):
            x_mm = x_step * index_x
            weighted_x = 0.0
            weighted_y = 0.0
            total_weight = 0.0
            local_count = 0
            nearest_distance = None
            distances: list[tuple[float, DrawingCalibrationSample, tuple[float, float]]] = []
            for sample, residual in zip(samples, residuals):
                fit_input = _fit_input_mm(sample)
                distance = math.hypot(fit_input.x - x_mm, fit_input.y - y_mm)
                if nearest_distance is None or distance < nearest_distance:
                    nearest_distance = distance
                distances.append((distance, sample, residual))
                if distance <= coverage_radius:
                    local_count += 1
                weight = sample.weight * sample.confidence * math.exp(-(distance * distance) / (2.0 * sigma * sigma))
                weighted_x += residual[0] * weight
                weighted_y += residual[1] * weight
                total_weight += weight
            if total_weight <= 0.0:
                residual_x = 0.0
                residual_y = 0.0
            else:
                residual_x = weighted_x / total_weight
                residual_y = weighted_y / total_weight
            variance_weight = 0.0
            variance_total = 0.0
            for distance, sample, residual in distances:
                weight = sample.weight * sample.confidence * math.exp(-(distance * distance) / (2.0 * sigma * sigma))
                delta = math.hypot(residual[0] - residual_x, residual[1] - residual_y)
                variance_weight += delta * delta * weight
                variance_total += weight
            spread = math.sqrt(variance_weight / variance_total) if variance_total > 0.0 else uncertainty_limit_mm * 2.0
            distance_penalty = (nearest_distance if nearest_distance is not None else coverage_radius * 2.0) * 0.08
            uncertainty = spread + distance_penalty
            nodes.append(
                DrawingResidualGridNode(
                    index_x=index_x,
                    index_y=index_y,
                    x_mm=x_mm,
                    y_mm=y_mm,
                    residual_x_mm=residual_x,
                    residual_y_mm=residual_y,
                    source_sample_count=local_count,
                    nearest_sample_distance_mm=nearest_distance,
                    uncertainty_mm=uncertainty,
                )
            )
    return DrawingResidualGridV1(
        columns=columns,
        rows=rows,
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        coverage_radius_mm=coverage_radius,
        uncertainty_limit_mm=uncertainty_limit_mm,
        max_correction_mm=max_correction_mm,
        nodes=nodes,
    )


def _fit_action_residuals(
    model: DrawingCalibrationModel,
    samples: list[DrawingCalibrationSample],
) -> list[DrawingActionResidualCoefficient]:
    feature_rows: dict[str, list[tuple[float, float, float]]] = {}
    for sample in samples:
        predicted = model.apply_expected_to_observed(_fit_input_mm(sample), include_action_residual=False)
        residual_x = sample.observed_mm.x - predicted.x
        residual_y = sample.observed_mm.y - predicted.y
        for feature_name, feature_value in sample.feature_vector().items():
            if feature_value == 0.0 or not math.isfinite(feature_value):
                continue
            feature_rows.setdefault(feature_name, []).append((feature_value, residual_x, residual_y))

    coefficients: list[DrawingActionResidualCoefficient] = []
    for feature_name, rows in sorted(feature_rows.items()):
        if len(rows) < DEFAULT_ACTION_RESIDUAL_MIN_SAMPLE_COUNT:
            continue
        denominator = sum(value * value for value, _, _ in rows) + DEFAULT_ACTION_RESIDUAL_REGULARIZATION
        if denominator <= 0.0:
            continue
        coefficient_x = sum(value * residual_x for value, residual_x, _ in rows) / denominator
        coefficient_y = sum(value * residual_y for value, _, residual_y in rows) / denominator
        if math.hypot(coefficient_x, coefficient_y) < 0.05:
            continue
        remaining = [
            math.hypot(residual_x - coefficient_x * value, residual_y - coefficient_y * value)
            for value, residual_x, residual_y in rows
        ]
        coefficients.append(
            DrawingActionResidualCoefficient(
                feature_name=feature_name,
                residual_x_mm=coefficient_x,
                residual_y_mm=coefficient_y,
                sample_count=len(rows),
                regularization=DEFAULT_ACTION_RESIDUAL_REGULARIZATION,
                rms_remaining_mm=_rms(remaining),
            )
        )
    return coefficients


def _evaluate_fit_samples(
    model: DrawingCalibrationModel,
    samples: list[DrawingCalibrationSample],
    *,
    include_action_residual: bool = True,
) -> DrawingCalibrationMetrics:
    residuals = [
        math.hypot(
            sample.observed_mm.x - predicted.x,
            sample.observed_mm.y - predicted.y,
        )
        for sample in samples
        for predicted in [
            model.apply_expected_to_observed(
                _fit_input_mm(sample),
                action_features=sample.feature_vector(),
                include_action_residual=include_action_residual,
            )
        ]
    ]
    if not residuals:
        return DrawingCalibrationMetrics(sample_count=0)
    return DrawingCalibrationMetrics(
        sample_count=len(samples),
        rms_mm=_rms(residuals),
        p95_mm=_percentile(residuals, 0.95),
        max_mm=max(residuals),
    )


def _evaluate_validation_samples(
    model: DrawingCalibrationModel,
    samples: list[DrawingCalibrationSample],
) -> DrawingCalibrationMetrics:
    residuals = [
        math.hypot(
            sample.observed_mm.x - target.x,
            sample.observed_mm.y - target.y,
        )
        for sample in samples
        for target in [_validation_target_mm(model, sample)]
    ]
    if not residuals:
        return DrawingCalibrationMetrics(sample_count=0)
    return DrawingCalibrationMetrics(
        sample_count=len(samples),
        rms_mm=_rms(residuals),
        p95_mm=_percentile(residuals, 0.95),
        max_mm=max(residuals),
    )


def _build_empty_coverage(
    samples: list[DrawingCalibrationSample],
    *,
    field_width_mm: float,
    field_height_mm: float,
    holdout_sample_count: int,
    uncertainty_limit_mm: float,
) -> DrawingCalibrationCoverage:
    return DrawingCalibrationCoverage(
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        sample_count=len(samples),
        holdout_sample_count=holdout_sample_count,
        uncertainty_limit_mm=uncertainty_limit_mm,
    )


def _build_coverage(
    accepted_fit_samples: list[DrawingCalibrationSample],
    holdout_samples: list[DrawingCalibrationSample],
    grid: DrawingResidualGridV1,
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> DrawingCalibrationCoverage:
    x_values = [sample.expected_mm.x for sample in accepted_fit_samples]
    y_values = [sample.expected_mm.y for sample in accepted_fit_samples]
    covered_nodes = [
        node
        for node in grid.nodes
        if node.source_sample_count > 0 and node.uncertainty_mm <= grid.uncertainty_limit_mm
    ]
    return DrawingCalibrationCoverage(
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
        sample_count=len(accepted_fit_samples) + len(holdout_samples),
        accepted_sample_count=len(accepted_fit_samples),
        holdout_sample_count=len(holdout_samples),
        min_x_mm=min(x_values) if x_values else None,
        max_x_mm=max(x_values) if x_values else None,
        min_y_mm=min(y_values) if y_values else None,
        max_y_mm=max(y_values) if y_values else None,
        total_node_count=len(grid.nodes),
        covered_node_count=len(covered_nodes),
        coverage_fraction=(len(covered_nodes) / len(grid.nodes)) if grid.nodes else 0.0,
        coverage_radius_mm=grid.coverage_radius_mm,
        uncertainty_limit_mm=grid.uncertainty_limit_mm,
        max_node_uncertainty_mm=max((node.uncertainty_mm for node in grid.nodes), default=None),
    )


def _sample_residual_after_global_model(
    sample: DrawingCalibrationSample,
    baseline: Homography2D | None,
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> tuple[float, float]:
    predicted_x, predicted_y = _apply_global_model(
        baseline,
        _fit_input_mm(sample),
        field_width_mm=field_width_mm,
        field_height_mm=field_height_mm,
    )
    return (sample.observed_mm.x - predicted_x, sample.observed_mm.y - predicted_y)


def _fit_input_mm(sample: DrawingCalibrationSample) -> PaperPointMM:
    return sample.commanded_mm or sample.expected_mm


def _validation_target_mm(
    model: DrawingCalibrationModel,
    sample: DrawingCalibrationSample,
) -> PaperPointMM:
    if sample.correction_mode in {"current_model", "validation", "retry"}:
        return sample.desired_mm or sample.expected_mm
    return model.apply_expected_to_observed(
        _fit_input_mm(sample),
        action_features=sample.feature_vector(),
        include_action_residual=True,
    )


def _is_production_action_feature(feature_name: str) -> bool:
    if feature_name.startswith("primitive_id:"):
        return False
    if feature_name.startswith("diagnostic:"):
        return False
    return feature_name in {
        "direction_unit_x",
        "direction_unit_y",
        "approach_direction_unit_x",
        "approach_direction_unit_y",
        "feed_mm_min_scaled",
        "segment_length_mm_scaled",
        "curvature_abs_turns",
        "pen_transition_down",
        "pen_transition_up",
        "stroke_order_bucket_0",
        "stroke_order_bucket_1",
        "stroke_order_bucket_2",
        "stroke_order_bucket_3",
        "opposite_direction_repeat",
        "source_role:outline",
        "source_role:hatch",
        "source_role:mark",
        "source_role:contour",
        "semantic_role:line",
        "semantic_role:arc",
        "semantic_role:circle",
        "semantic_role:point_mark",
        "semantic_role:validation",
        "semantic_role:direction_probe",
    }


def _apply_global_model(
    homography: Homography2D | None,
    point: PaperPointMM,
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> tuple[float, float]:
    if homography is None:
        return (point.x, point.y)
    x_norm, y_norm = _normalize_mm(point, field_width_mm=field_width_mm, field_height_mm=field_height_mm)
    mapped_x_norm, mapped_y_norm = homography.map_xy(x_norm, y_norm)
    return (mapped_x_norm * field_width_mm, mapped_y_norm * field_height_mm)


def _append_unique_sample(
    samples: list[DrawingCalibrationSample],
    seen: set[tuple[str, int, int]],
    sample: DrawingCalibrationSample,
) -> None:
    key = (
        sample.sample_kind,
        round(sample.expected_mm.x * 1000.0),
        round(sample.expected_mm.y * 1000.0),
    )
    if key in seen:
        return
    seen.add(key)
    samples.append(sample)


def _edge_confidence(edge: DrawingFrameEdgeObservation) -> float:
    if edge.sample_count <= 0:
        return 0.5
    return _clamp(edge.detected_sample_count / edge.sample_count, 0.1, 1.0)


def _normalize_mm(
    point: PaperPointMM,
    *,
    field_width_mm: float,
    field_height_mm: float,
) -> tuple[float, float]:
    return (point.x / field_width_mm, point.y / field_height_mm)


def _finite_float(value: float, name: str) -> float:
    if not math.isfinite(value):
        raise ValueError(f"{name} must be finite.")
    return value


def _same_dimension(left: float, right: float) -> bool:
    return abs(left - right) <= 1e-6


def _rms(values: list[float]) -> float:
    return math.sqrt(sum(value * value for value in values) / len(values))


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        raise ValueError("Cannot compute percentile for an empty list.")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = _clamp(percentile, 0.0, 1.0) * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _norm(x: float, y: float) -> float:
    return math.hypot(x, y)


def _clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


def _bilinear(
    n00: float,
    n10: float,
    n01: float,
    n11: float,
    tx: float,
    ty: float,
) -> float:
    bottom = n00 * (1.0 - tx) + n10 * tx
    top = n01 * (1.0 - tx) + n11 * tx
    return bottom * (1.0 - ty) + top * ty
