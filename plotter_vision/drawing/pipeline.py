from __future__ import annotations

import uuid
from typing import Literal

from pydantic import BaseModel, Field

from plotter_vision.calibration.paper import PaperPointMM
from plotter_vision.calibration.vision_model import CameraPointNorm
from plotter_vision.controller.base import utc_now_iso
from plotter_vision.motion.simulator import SimulatedPath


PipelineStageStatus = Literal["pending", "ready", "completed", "blocked", "failed"]
OverlayCoordinateSpace = Literal["paper_mm", "camera_norm"]
ExecutionAuthority = Literal["dry_run", "axis_model_trusted", "visual_position_binding"]


class Planner(BaseModel):
    stage: Literal["planner"] = "planner"
    status: PipelineStageStatus = "ready"
    command_id: str
    program_kind: str = "drawing_program"
    command_count: int
    draw_segment_count: int


class Simulator(BaseModel):
    stage: Literal["simulator"] = "simulator"
    status: PipelineStageStatus
    simulation: SimulatedPath


class PreviewOverlayPrimitive(BaseModel):
    primitive_id: str
    stroke_id: str | None = None
    semantic_role: str | None = None
    source_role: str | None = None
    command_id: str
    segment_index: int
    start_paper_mm: PaperPointMM
    end_paper_mm: PaperPointMM
    start_camera_norm: CameraPointNorm | None = None
    end_camera_norm: CameraPointNorm | None = None
    length_mm: float


class PreviewOverlay(BaseModel):
    stage: Literal["preview_overlay"] = "preview_overlay"
    overlay_id: str = Field(default_factory=lambda: f"overlay-{uuid.uuid4().hex[:12]}")
    command_id: str
    coordinate_space: OverlayCoordinateSpace
    projected: bool
    paper_registration_id: str | None = None
    visual_position_binding_id: str | None = None
    primitives: list[PreviewOverlayPrimitive] = Field(default_factory=list)


class VideoProjector(BaseModel):
    stage: Literal["video_projector"] = "video_projector"
    status: PipelineStageStatus
    paper_registration_id: str | None = None
    visual_position_binding_id: str | None = None
    overlay: PreviewOverlay | None = None
    blockers: list[str] = Field(default_factory=list)


class Executor(BaseModel):
    stage: Literal["executor"] = "executor"
    status: PipelineStageStatus
    authority: ExecutionAuthority
    controller_transcript: str | None = None
    blockers: list[str] = Field(default_factory=list)


class VisionObserver(BaseModel):
    stage: Literal["vision_observer"] = "vision_observer"
    status: PipelineStageStatus = "pending"
    observation_count: int = 0
    command_ids: list[str] = Field(default_factory=list)


class ResidualSolver(BaseModel):
    stage: Literal["residual_solver"] = "residual_solver"
    status: PipelineStageStatus = "pending"
    model_type: Literal["residual_grid_v1"] = "residual_grid_v1"
    observation_count: int = 0
    rms_residual_mm: float | None = None
    p95_residual_mm: float | None = None
    max_residual_mm: float | None = None
    blockers: list[str] = Field(default_factory=list)


class PersistedBinding(BaseModel):
    stage: Literal["persisted_binding"] = "persisted_binding"
    status: PipelineStageStatus = "pending"
    binding_id: str | None = None
    binding_file: str | None = None
    validation_status: str = "missing"
    blockers: list[str] = Field(default_factory=list)


class DrawingPipelineTrace(BaseModel):
    schema_version: int = 1
    artifact_type: Literal["drawing_pipeline_trace"] = "drawing_pipeline_trace"
    trace_id: str = Field(default_factory=lambda: f"pipe-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    planner: Planner
    simulator: Simulator
    video_projector: VideoProjector | None = None
    preview_overlay: PreviewOverlay | None = None
    executor: Executor | None = None
    vision_observer: VisionObserver | None = None
    residual_solver: ResidualSolver | None = None
    persisted_binding: PersistedBinding | None = None
