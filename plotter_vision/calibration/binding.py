from __future__ import annotations

import math
import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field, field_validator

from plotter_vision.calibration.paper import PaperPointMM
from plotter_vision.calibration.readiness import DrawingSafeZone, VisualCapObservation
from plotter_vision.calibration.vision_model import CameraPointNorm
from plotter_vision.controller.base import utc_now_iso
from plotter_vision.drawing import DrawingFrameMM
from plotter_vision.drawing.pipeline import PreviewOverlay


BindingValidationStatus = Literal["collecting", "validated", "blocked", "stale"]
ObservedGeometryKind = Literal["ink"]
ExpectedGeometryRole = Literal["segment_start", "segment_end", "segment_midpoint"]
FIRST_UNLOCK_MIN_OBSERVATIONS = 5
FIRST_UNLOCK_MAX_RMS_RESIDUAL_MM = 3.0
FIRST_UNLOCK_MAX_RESIDUAL_MM = 6.0


class CameraIdentity(BaseModel):
    camera_id: str | None = None
    camera_name: str | None = None


class CapToTipModel(BaseModel):
    model_type: Literal["offset_mm"] = "offset_mm"
    offset_x_mm: float = 0.0
    offset_y_mm: float = 0.0
    source: Literal["unsolved", "residual_solver"] = "unsolved"


class AffineTransform2D(BaseModel):
    transform_type: Literal["affine_2d"] = "affine_2d"
    coefficients: tuple[float, float, float, float, float, float]

    def map_point(self, point: PaperPointMM) -> PaperPointMM:
        a, b, c, d, e, f = self.coefficients
        return PaperPointMM(
            x=a * point.x + b * point.y + c,
            y=d * point.x + e * point.y + f,
        )


class ExpectedGeometrySample(BaseModel):
    sample_id: str = Field(default_factory=lambda: f"expected-{uuid.uuid4().hex[:12]}")
    command_id: str
    point_id: str
    segment_index: int
    role: ExpectedGeometryRole
    expected_paper_mm: PaperPointMM
    expected_camera_norm: CameraPointNorm | None = None


class ObservedGeometrySample(BaseModel):
    observation_id: str = Field(default_factory=lambda: f"obs-{uuid.uuid4().hex[:12]}")
    command_id: str
    point_id: str
    kind: ObservedGeometryKind
    expected_paper_mm: PaperPointMM
    observed_paper_mm: PaperPointMM
    observed_camera_norm: CameraPointNorm | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    paper_registration_id: str
    created_at: str = Field(default_factory=utc_now_iso)
    confidence: float = 1.0

    @field_validator("confidence")
    @classmethod
    def _validate_confidence(cls, value: float) -> float:
        if not math.isfinite(value) or value < 0.0 or value > 1.0:
            raise ValueError("confidence must be in [0, 1].")
        return value


class BindingResidual(BaseModel):
    observation_id: str
    command_id: str
    point_id: str
    dx_mm: float
    dy_mm: float
    distance_mm: float


class BindingResidualSummary(BaseModel):
    observation_count: int = 0
    rms_residual_mm: float | None = None
    max_residual_mm: float | None = None
    axes_represented: list[Literal["X", "Y"]] = Field(default_factory=list)
    non_collinear: bool = False
    residuals: list[BindingResidual] = Field(default_factory=list)


class BindingFreshness(BaseModel):
    current_paper_registration_id: str | None = None
    current_camera_id: str | None = None
    fresh_session_evidence: bool = False
    latest_observed_at: str | None = None


class VisualPositionBinding(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["visual_position_binding"] = "visual_position_binding"
    binding_id: str = Field(default_factory=lambda: f"binding-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    paper_registration_id: str
    camera: CameraIdentity = Field(default_factory=CameraIdentity)
    drawing_frame: DrawingFrameMM
    safe_zone: DrawingSafeZone | None = None
    cap_observations: list[VisualCapObservation] = Field(default_factory=list)
    command_ids: list[str] = Field(default_factory=list)
    expected_simulated_geometry: list[ExpectedGeometrySample] = Field(default_factory=list)
    observed_geometry: list[ObservedGeometrySample] = Field(default_factory=list)
    learned_transform: AffineTransform2D | None = None
    cap_to_tip_model: CapToTipModel = Field(default_factory=CapToTipModel)
    residuals: BindingResidualSummary = Field(default_factory=BindingResidualSummary)
    freshness: BindingFreshness = Field(default_factory=BindingFreshness)
    validation_status: BindingValidationStatus = "collecting"
    blockers: list[str] = Field(default_factory=list)

    @property
    def validated(self) -> bool:
        return self.validation_status == "validated" and not self.blockers

    def is_valid_for(
        self,
        *,
        paper_registration_id: str,
        camera_id: str | None,
    ) -> bool:
        if not self.validated:
            return False
        if self.paper_registration_id != paper_registration_id:
            return False
        if self.camera.camera_id and camera_id and self.camera.camera_id != camera_id:
            return False
        return True

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load_json(cls, path: Path) -> VisualPositionBinding:
        return cls.model_validate_json(path.read_text(encoding="utf-8"))


def create_visual_position_binding(
    *,
    paper_registration_id: str,
    camera_id: str | None,
    camera_name: str | None,
    drawing_frame: DrawingFrameMM,
    safe_zone: DrawingSafeZone | None,
    cap_observations: list[VisualCapObservation],
) -> VisualPositionBinding:
    return VisualPositionBinding(
        paper_registration_id=paper_registration_id,
        camera=CameraIdentity(camera_id=camera_id, camera_name=camera_name),
        drawing_frame=drawing_frame,
        safe_zone=safe_zone,
        cap_observations=cap_observations,
        freshness=BindingFreshness(
            current_paper_registration_id=paper_registration_id,
            current_camera_id=camera_id,
        ),
        blockers=[
            f"Needs at least {FIRST_UNLOCK_MIN_OBSERVATIONS} binding mark observations."
        ],
    )


def expected_geometry_from_overlay(
    overlay: PreviewOverlay,
) -> list[ExpectedGeometrySample]:
    samples: list[ExpectedGeometrySample] = []
    for primitive in overlay.primitives:
        start_point_id = f"seg-{primitive.segment_index:04d}-start"
        end_point_id = f"seg-{primitive.segment_index:04d}-end"
        samples.extend(
            [
                ExpectedGeometrySample(
                    command_id=primitive.command_id,
                    point_id=start_point_id,
                    segment_index=primitive.segment_index,
                    role="segment_start",
                    expected_paper_mm=primitive.start_paper_mm,
                    expected_camera_norm=primitive.start_camera_norm,
                ),
                ExpectedGeometrySample(
                    command_id=primitive.command_id,
                    point_id=end_point_id,
                    segment_index=primitive.segment_index,
                    role="segment_end",
                    expected_paper_mm=primitive.end_paper_mm,
                    expected_camera_norm=primitive.end_camera_norm,
                ),
            ]
        )
    return samples


def upsert_expected_geometry(
    binding: VisualPositionBinding,
    samples: list[ExpectedGeometrySample],
) -> VisualPositionBinding:
    existing = {
        (sample.command_id, sample.point_id): sample
        for sample in binding.expected_simulated_geometry
    }
    for sample in samples:
        existing[(sample.command_id, sample.point_id)] = sample
        if sample.command_id not in binding.command_ids:
            binding.command_ids.append(sample.command_id)
    binding.expected_simulated_geometry = list(existing.values())
    binding.updated_at = utc_now_iso()
    return binding


def solve_visual_position_binding(
    binding: VisualPositionBinding,
    *,
    current_paper_registration_id: str,
    current_camera_id: str | None,
) -> VisualPositionBinding:
    observations = list(binding.observed_geometry)
    blockers: list[str] = []
    observation_count = len(observations)
    axes = _axes_represented([sample.expected_paper_mm for sample in observations])
    non_collinear = _has_non_collinear_points([sample.expected_paper_mm for sample in observations])

    if observation_count < FIRST_UNLOCK_MIN_OBSERVATIONS:
        blockers.append(
            f"Needs at least {FIRST_UNLOCK_MIN_OBSERVATIONS} binding mark observations; "
            f"got {observation_count}."
        )
    if not {"X", "Y"}.issubset(set(axes)):
        blockers.append("First drawing unlock requires observations spanning both X and Y axes.")
    if not non_collinear:
        blockers.append("First drawing unlock requires non-collinear observations.")
    if binding.paper_registration_id != current_paper_registration_id:
        blockers.append("Binding paper registration does not match the current paper registration.")
    if binding.camera.camera_id and current_camera_id and binding.camera.camera_id != current_camera_id:
        blockers.append("Binding camera id does not match the current camera.")
    if _observation_camera_ids_disagree(observations, binding.camera.camera_id):
        blockers.append("Observed geometry camera ids do not match the binding camera.")

    transform: AffineTransform2D | None = None
    residual_summary = BindingResidualSummary(
        observation_count=observation_count,
        axes_represented=axes,
        non_collinear=non_collinear,
    )
    if observation_count >= 3 and non_collinear:
        transform = _solve_affine_transform(observations)
        residual_summary = _residual_summary(
            observations=observations,
            transform=transform,
            axes=axes,
            non_collinear=non_collinear,
        )
        if (
            residual_summary.rms_residual_mm is not None
            and residual_summary.rms_residual_mm > FIRST_UNLOCK_MAX_RMS_RESIDUAL_MM
        ):
            blockers.append(
                "Binding RMS residual "
                f"{residual_summary.rms_residual_mm:.3f} mm exceeds "
                f"{FIRST_UNLOCK_MAX_RMS_RESIDUAL_MM:.3f} mm."
            )
        if (
            residual_summary.max_residual_mm is not None
            and residual_summary.max_residual_mm > FIRST_UNLOCK_MAX_RESIDUAL_MM
        ):
            blockers.append(
                "Binding max residual "
                f"{residual_summary.max_residual_mm:.3f} mm exceeds "
                f"{FIRST_UNLOCK_MAX_RESIDUAL_MM:.3f} mm."
            )

    latest_observed_at = max((sample.created_at for sample in observations), default=None)
    if not blockers and observations:
        binding.cap_to_tip_model = _learn_cap_to_tip_model(observations)
    binding.learned_transform = transform
    binding.residuals = residual_summary
    binding.freshness = BindingFreshness(
        current_paper_registration_id=current_paper_registration_id,
        current_camera_id=current_camera_id,
        fresh_session_evidence=observation_count >= FIRST_UNLOCK_MIN_OBSERVATIONS,
        latest_observed_at=latest_observed_at,
    )
    binding.validation_status = (
        "validated"
        if not blockers
        else ("collecting" if observation_count < FIRST_UNLOCK_MIN_OBSERVATIONS else "blocked")
    )
    binding.blockers = blockers
    binding.updated_at = utc_now_iso()
    return binding


def _learn_cap_to_tip_model(observations: list[ObservedGeometrySample]) -> CapToTipModel:
    total_weight = sum(max(sample.confidence, 0.0) for sample in observations)
    if total_weight <= 0.0:
        total_weight = float(len(observations))
        weighted = [(sample, 1.0) for sample in observations]
    else:
        weighted = [(sample, max(sample.confidence, 0.0)) for sample in observations]

    offset_x = sum(
        (sample.observed_paper_mm.x - sample.expected_paper_mm.x) * weight
        for sample, weight in weighted
    ) / total_weight
    offset_y = sum(
        (sample.observed_paper_mm.y - sample.expected_paper_mm.y) * weight
        for sample, weight in weighted
    ) / total_weight
    return CapToTipModel(
        offset_x_mm=offset_x,
        offset_y_mm=offset_y,
        source="residual_solver",
    )


def find_expected_sample(
    binding: VisualPositionBinding,
    *,
    command_id: str,
    point_id: str | None,
) -> ExpectedGeometrySample | None:
    candidates = [
        sample
        for sample in binding.expected_simulated_geometry
        if sample.command_id == command_id
    ]
    if point_id is not None:
        for sample in candidates:
            if sample.point_id == point_id:
                return sample
        return None
    return candidates[0] if len(candidates) == 1 else None


def _residual_summary(
    *,
    observations: list[ObservedGeometrySample],
    transform: AffineTransform2D,
    axes: list[Literal["X", "Y"]],
    non_collinear: bool,
) -> BindingResidualSummary:
    residuals: list[BindingResidual] = []
    for observation in observations:
        predicted = transform.map_point(observation.expected_paper_mm)
        dx = observation.observed_paper_mm.x - predicted.x
        dy = observation.observed_paper_mm.y - predicted.y
        residuals.append(
            BindingResidual(
                observation_id=observation.observation_id,
                command_id=observation.command_id,
                point_id=observation.point_id,
                dx_mm=dx,
                dy_mm=dy,
                distance_mm=math.hypot(dx, dy),
            )
        )
    rms = (
        sum(residual.distance_mm * residual.distance_mm for residual in residuals)
        / len(residuals)
    ) ** 0.5
    return BindingResidualSummary(
        observation_count=len(observations),
        rms_residual_mm=rms,
        max_residual_mm=max(residual.distance_mm for residual in residuals),
        axes_represented=axes,
        non_collinear=non_collinear,
        residuals=residuals,
    )


def _solve_affine_transform(observations: list[ObservedGeometrySample]) -> AffineTransform2D:
    rows = [
        [sample.expected_paper_mm.x, sample.expected_paper_mm.y, 1.0]
        for sample in observations
    ]
    observed_x = [sample.observed_paper_mm.x for sample in observations]
    observed_y = [sample.observed_paper_mm.y for sample in observations]
    x_coefficients = _least_squares(rows, observed_x)
    y_coefficients = _least_squares(rows, observed_y)
    return AffineTransform2D(
        coefficients=(
            x_coefficients[0],
            x_coefficients[1],
            x_coefficients[2],
            y_coefficients[0],
            y_coefficients[1],
            y_coefficients[2],
        )
    )


def _least_squares(rows: list[list[float]], values: list[float]) -> list[float]:
    if not rows or len(rows) != len(values):
        raise ValueError("Least-squares rows and values must have the same non-zero length.")
    column_count = len(rows[0])
    normal_rows = [[0.0 for _ in range(column_count)] for _ in range(column_count)]
    normal_values = [0.0 for _ in range(column_count)]
    for row, value in zip(rows, values):
        if len(row) != column_count:
            raise ValueError("Least-squares rows must have consistent width.")
        for i in range(column_count):
            normal_values[i] += row[i] * value
            for j in range(column_count):
                normal_rows[i][j] += row[i] * row[j]
    return _solve_linear_system(normal_rows, normal_values)


def _solve_linear_system(matrix: list[list[float]], values: list[float]) -> list[float]:
    n = len(values)
    augmented = [row[:] + [value] for row, value in zip(matrix, values)]
    for pivot_index in range(n):
        best = max(range(pivot_index, n), key=lambda row_index: abs(augmented[row_index][pivot_index]))
        if abs(augmented[best][pivot_index]) < 1e-12:
            raise ValueError("Observation geometry is degenerate; affine transform cannot be solved.")
        if best != pivot_index:
            augmented[pivot_index], augmented[best] = augmented[best], augmented[pivot_index]
        pivot = augmented[pivot_index][pivot_index]
        for column in range(pivot_index, n + 1):
            augmented[pivot_index][column] /= pivot
        for row_index in range(n):
            if row_index == pivot_index:
                continue
            factor = augmented[row_index][pivot_index]
            for column in range(pivot_index, n + 1):
                augmented[row_index][column] -= factor * augmented[pivot_index][column]
    return [augmented[row_index][n] for row_index in range(n)]


def _axes_represented(points: list[PaperPointMM]) -> list[Literal["X", "Y"]]:
    if not points:
        return []
    axes: list[Literal["X", "Y"]] = []
    if max(point.x for point in points) - min(point.x for point in points) >= 1.0:
        axes.append("X")
    if max(point.y for point in points) - min(point.y for point in points) >= 1.0:
        axes.append("Y")
    return axes


def _has_non_collinear_points(points: list[PaperPointMM]) -> bool:
    if len(points) < 3:
        return False
    for first in range(len(points) - 2):
        for second in range(first + 1, len(points) - 1):
            for third in range(second + 1, len(points)):
                area = abs(
                    (points[second].x - points[first].x)
                    * (points[third].y - points[first].y)
                    - (points[second].y - points[first].y)
                    * (points[third].x - points[first].x)
                )
                if area > 1e-6:
                    return True
    return False


def _observation_camera_ids_disagree(
    observations: list[ObservedGeometrySample],
    binding_camera_id: str | None,
) -> bool:
    if binding_camera_id is None:
        return False
    return any(
        observation.camera_id is not None and observation.camera_id != binding_camera_id
        for observation in observations
    )
