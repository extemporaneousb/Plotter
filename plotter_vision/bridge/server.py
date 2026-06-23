from __future__ import annotations

import hashlib
import json
import math
import os
import time
import uuid
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from threading import Lock
from typing import Any, Callable, Literal
from urllib.parse import urlparse

from pydantic import BaseModel, Field, ValidationError

from plotter_vision import __version__ as PLOTTER_VERSION
from plotter_vision.calibration.paper import (
    PaperCorner,
    PaperCornerObservation,
    PaperFrameRegistration,
    PaperPointMM,
    paper_corner_norm,
    build_paper_frame_registration,
)
from plotter_vision.calibration.binding import (
    ExpectedGeometrySample,
    ObservedGeometrySample,
    VisualPositionBinding,
    create_visual_position_binding,
    expected_geometry_from_overlay,
    find_expected_sample,
    solve_visual_position_binding,
    upsert_expected_geometry,
)
from plotter_vision.calibration.probe_evidence import (
    VisualProbeCapSnapshot,
    VisualProbeRun,
    VisualProbeSample,
    VisualProbeSource,
    VisualProbeSummary,
    summarize_visual_probe_samples,
)
from plotter_vision.calibration.readiness import (
    DrawingSafeZone,
    SafeZoneMarginsMM,
    VisualCapObservation,
    VisualReadinessState,
    build_visual_readiness_state,
    evaluate_cap_inside_safe_zone,
)
from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    PaperPointNorm,
)
from plotter_vision.bridge.planner import (
    ShapeExecutionPlan,
    ShapeExecutionRequest,
    PlannedCommand,
    PolygonDrawPlan,
    PolygonDrawPlanSummary,
    PolygonDrawRequest,
    build_shape_execution_plan,
    build_polygon_draw_plan,
)
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.mock import MockTransport
from plotter_vision.controller.parser import StatusReport
from plotter_vision.controller.serial_transport import DEFAULT_BAUD, SerialTransport, list_serial_ports
from plotter_vision.drawing import (
    CapabilityTestKind,
    DrawingFrameMM,
    LuminanceRaster,
    PlannedPolyline,
    PortraitContourOptions,
    PortraitContourSummary,
    RasterContourOptions,
    RasterContourSummary,
    RasterPolygonOptions,
    RasterPolygonSummary,
    build_portrait_contour_program_from_luminance_raster,
    build_paper_contour_program_from_luminance_raster,
    build_paper_program_from_luminance_raster,
    build_capability_test_definition,
)
from plotter_vision.drawing.pipeline import (
    PreviewOverlay,
    PreviewOverlayPrimitive,
)
from plotter_vision.machine.homing import validate_homing_request
from plotter_vision.machine.pen import validate_pen_trial_command
from plotter_vision.machine.safety import (
    MotionSafetyError,
    validate_jog_request,
    validate_projected_workspace_motion,
    validate_relative_xy_move_request,
    validate_workspace_point,
)
from plotter_vision.motion.gcode import (
    build_relative_jog_commands,
    build_relative_xy_move_commands,
    format_mm,
)
from plotter_vision.motion.simulator import (
    ShapeGeometryEvaluation,
    DrawnSegment,
    SimulatedPath,
)

BindingMarkPointSet = Literal["five"]
BridgeLifecycleMode = Literal["mock_preview", "hardware_standby", "live"]
BRIDGE_API_VERSION = 3
BRIDGE_SOURCE_ROOT = Path(__file__).resolve().parents[2]


def _bridge_build_id() -> str:
    env_build_id = os.environ.get("PLOTTER_BRIDGE_BUILD_ID", "").strip()
    if env_build_id:
        return env_build_id
    try:
        source_digest = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:12]
    except OSError:
        source_digest = "unknown"
    return f"plotter-bridge/{PLOTTER_VERSION}+{source_digest}"


BRIDGE_BUILD_ID = _bridge_build_id()


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _clean_optional_string(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _coerce_positive_int(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed >= 0 else None


class BridgeRuntimeConfig(BaseModel):
    host: str = "127.0.0.1"
    http_port: int = 8765
    dry_run: bool = True
    mock: bool = False
    controller_port: str | None = None
    baud: int = DEFAULT_BAUD
    arm_motion: bool = False
    arm_pen: bool = False
    arm_homing: bool = False
    arm_unlock: bool = False
    config_path: Path = Path("artifacts/machine_config.json")
    event_log_path: Path = Path("artifacts/bridge_events.jsonl")
    app_state_path: Path = Path("artifacts/app_state.json")
    app_event_log_path: Path = Path("artifacts/app_events.jsonl")
    transcript_dir: Path = Path("artifacts/bridge_transcripts")
    calibration_dir: Path = Path("artifacts/calibration_sessions")
    workspace_x_max: float | None = None
    workspace_y_max: float | None = None


class BridgeEvent(BaseModel):
    type: str
    schema_version: int = Field(default=1, serialization_alias="schema", validation_alias="schema")
    sequence: int
    t_monotonic: float = Field(default_factory=time.monotonic)
    command_id: str | None = None
    status: str
    payload: dict[str, Any] = Field(default_factory=dict)


class BridgeHealthResponse(BaseModel):
    status: str = "ready"
    schema_version: int = Field(default=2, serialization_alias="schema", validation_alias="schema")
    dry_run: bool
    controller: str
    bridge_api_version: int
    lifecycle_mode: BridgeLifecycleMode
    lifecycle_label: str
    bridge_build_id: str
    bridge_source_root: str
    bridge_pid: int
    bridge_started_at: str
    can_restart_safely: bool
    arm_motion: bool = False
    arm_pen: bool = False
    arm_homing: bool = False
    arm_unlock: bool = False
    event_log: str
    workspace_x_mm: float | None = None
    workspace_y_mm: float | None = None
    max_feed_mm_min: float | None = None
    max_jog_mm: float | None = None


class AppDiagnosticStateRequest(BaseModel):
    source: str = "macos_app"
    observed_at: str | None = None
    app_build_id: str | None = None
    bridge_url: str | None = None
    status: str = "reported"
    payload: dict[str, Any] = Field(default_factory=dict)


class AppDiagnosticEventRequest(BaseModel):
    source: str = "macos_app"
    event_type: str
    observed_at: str | None = None
    app_build_id: str | None = None
    bridge_url: str | None = None
    status: str = "reported"
    payload: dict[str, Any] = Field(default_factory=dict)


class AppDiagnosticRecord(BaseModel):
    schema_version: int = Field(default=1, serialization_alias="schema", validation_alias="schema")
    sequence: int
    kind: Literal["state", "event"]
    event_type: str
    source: str
    received_at: str
    observed_at: str | None = None
    app_build_id: str | None = None
    bridge_url: str | None = None
    status: str
    payload: dict[str, Any] = Field(default_factory=dict)


class AppDiagnosticIngestResponse(BaseModel):
    status: str = "accepted"
    command_control: bool = False
    event_log_appended: bool = True
    read_only_snapshot: bool = True
    state_file: str
    event_log: str
    record: AppDiagnosticRecord


class AppDiagnosticsSnapshot(BaseModel):
    state_file: str
    event_log: str
    latest_state: AppDiagnosticRecord | None = None
    latest_event: AppDiagnosticRecord | None = None
    recent_events: list[AppDiagnosticRecord] = Field(default_factory=list)


class ShapeExecutionResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    pattern: str
    planned_commands: list[str]
    simulation: SimulatedPath | None = None
    evaluation: ShapeGeometryEvaluation | None = None
    preview_overlay: PreviewOverlay | None = None
    event_log: str
    controller_transcript: str | None = None
    error: str | None = None


class PaperRegistrationCornerRequest(BaseModel):
    corner: PaperCorner
    observed_norm: CameraPointNorm
    strength: float = 1.0
    observation_source: Literal["manual_click", "synthetic"] = "manual_click"
    camera_id: str | None = None
    camera_name: str | None = None


class PaperRegistrationRequest(BaseModel):
    paper_width_mm: float | None = None
    paper_height_mm: float | None = None
    corners: list[PaperRegistrationCornerRequest] = Field(default_factory=list)


class PaperRegistrationResponse(BaseModel):
    status: str
    dry_run: bool
    registration: dict[str, Any] | None = None
    registration_file: str = ""
    error: str | None = None


class VisualCapObservationRequest(BaseModel):
    observed_norm: CameraPointNorm
    observed_paper_norm: PaperPointNorm | None = None
    observed_logical_mm: LogicalPointMM | None = None
    source: Literal["manual_click", "camera_detection", "operator_confirmed", "synthetic"] = (
        "manual_click"
    )
    confidence: float = 1.0
    camera_id: str | None = None
    camera_name: str | None = None
    safe_zone_inset_x_mm: float = 10.0
    safe_zone_inset_y_mm: float = 10.0


class VisualReadinessResponse(BaseModel):
    status: str
    dry_run: bool
    readiness: dict[str, Any] | None = None
    readiness_file: str = ""
    error: str | None = None


class VisualBindingObservationRequest(BaseModel):
    command_id: str
    point_id: str | None = None
    kind: Literal["ink", "pen_tip"] = "ink"
    observed_norm: CameraPointNorm | None = None
    observed_paper_mm: PaperPointMM | None = None
    expected_paper_mm: PaperPointMM | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    confidence: float = 1.0


class VisualBindingSolveRequest(BaseModel):
    request_id: str | None = None


class VisualPositionBindingResponse(BaseModel):
    status: str
    dry_run: bool
    binding: VisualPositionBinding | None = None
    binding_file: str = ""
    observation_id: str | None = None
    error: str | None = None


class VisualProbeSampleObservationRequest(BaseModel):
    run_id: str | None = None
    sample_id: str | None = None
    observed_at: str | None = None
    request_id: str | None = None
    plan_id: str | None = None
    command_id: str | None = None
    paper_registration_id: str | None = None
    camera_id: str | None = None
    camera_name: str | None = None
    source: VisualProbeSource
    axis: Literal["X", "Y"] | None = None
    commanded_dx_mm: float
    commanded_dy_mm: float
    before: VisualProbeCapSnapshot
    after: VisualProbeCapSnapshot
    predicted_dx_mm: float | None = None
    predicted_dy_mm: float | None = None
    residual_mm: float | None = None
    residual_limit_mm: float | None = None
    status: Literal["accepted", "rejected", "blocked"] = "accepted"
    blockers: list[str] = Field(default_factory=list)
    rejection_reason: str | None = None
    controller_transcript: str | None = None


class VisualProbeSampleObservationResponse(BaseModel):
    status: str
    dry_run: bool
    sample: VisualProbeSample | None = None
    summary: VisualProbeSummary | None = None
    probe_run_file: str = ""
    latest_probe_run_file: str = ""
    readiness: dict[str, Any] | None = None
    readiness_file: str = ""
    error: str | None = None


class BindingMarkPreviewRequest(BaseModel):
    point_set: BindingMarkPointSet = "five"
    margin_mm: float = 40.0
    mark_size_mm: float = 6.0
    draw_feed_mm_min: float = 240.0
    travel_feed_mm_min: float = 1200.0
    max_segment_mm: float = 25.0
    request_id: str | None = None


class BindingMarkPreviewPoint(BaseModel):
    point_id: str
    paper_mm: PaperPointMM
    camera_norm: CameraPointNorm


class BindingMarkPreviewSegment(BaseModel):
    point_id: str
    start_paper_mm: PaperPointMM
    end_paper_mm: PaperPointMM
    start_norm: CameraPointNorm
    end_norm: CameraPointNorm
    length_mm: float


class BindingMarkPreviewResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    preview_only: bool = True
    registration_id: str = ""
    point_set: BindingMarkPointSet = "five"
    point_count: int = 0
    mark_size_mm: float = 0.0
    plan_hash: str = ""
    planned_commands: list[str] = Field(default_factory=list)
    simulation: SimulatedPath | None = None
    points: list[BindingMarkPreviewPoint] = Field(default_factory=list)
    camera_segments: list[BindingMarkPreviewSegment] = Field(default_factory=list)
    event_log: str
    error: str | None = None


@dataclass(frozen=True)
class BindingMarkPreviewBundle:
    machine: MachineConfig
    registration: PaperFrameRegistration
    plan: PolygonDrawPlan
    points: list[tuple[str, PaperPointMM]]
    camera_points: list[BindingMarkPreviewPoint]
    camera_segments: list[BindingMarkPreviewSegment]
    plan_hash: str


class MachineStatusResponse(BaseModel):
    status: str
    dry_run: bool
    controller: str
    arm_motion: bool = False
    arm_pen: bool = False
    arm_homing: bool = False
    arm_unlock: bool = False
    state: str
    homing_trusted: bool = False
    axis_model_trusted: bool = False
    visual_ready_to_plot: bool = False
    visual_readiness_blockers: list[str] = Field(default_factory=list)
    mpos_mm: tuple[float, ...] | None = None
    wpos_mm: tuple[float, ...] | None = None
    pins: str = ""
    feed_spindle: tuple[float, ...] | None = None
    fields: dict[str, str] = Field(default_factory=dict)
    is_busy: bool = False
    is_alarm: bool = False
    active_command_id: str | None = None
    active_action: str | None = None
    error: str | None = None


class CodexSnapshotResponse(BaseModel):
    schema_version: int = Field(default=1, serialization_alias="schema", validation_alias="schema")
    generated_at: str
    read_only: bool = True
    health: BridgeHealthResponse
    machine: MachineStatusResponse
    paper: PaperRegistrationResponse
    recent_events: list[BridgeEvent] = Field(default_factory=list)
    app_diagnostics: AppDiagnosticsSnapshot


class PolygonDrawResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    planned_commands: list[str]
    simulation: SimulatedPath | None = None
    summary: PolygonDrawPlanSummary | None = None
    preview_overlay: PreviewOverlay | None = None
    event_log: str
    controller_transcript: str | None = None
    machine_status: MachineStatusResponse | None = None
    error: str | None = None


class FaceRasterDrawRequest(BaseModel):
    raster: LuminanceRaster
    frame: DrawingFrameMM | None = None
    options: RasterPolygonOptions = Field(default_factory=RasterPolygonOptions)
    include_homing: bool = False
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    request_id: str | None = None


class FaceRasterDrawResponse(PolygonDrawResponse):
    raster_summary: RasterPolygonSummary | None = None


class ImageShapePreviewRequest(BaseModel):
    raster: LuminanceRaster
    frame: DrawingFrameMM | None = None
    options: RasterContourOptions = Field(default_factory=RasterContourOptions)
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    request_id: str | None = None


class ImageShapePreviewResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool = True
    preview_only: bool = True
    eligible_for_bridge_preview: bool = False
    planned_commands: list[str] = Field(default_factory=list)
    simulation: SimulatedPath | None = None
    summary: PolygonDrawPlanSummary | None = None
    raster_summary: RasterContourSummary | None = None
    preview_overlay: PreviewOverlay | None = None
    event_log: str
    controller_transcript: str | None = None
    error: str | None = None


class PortraitContourPreviewRequest(BaseModel):
    raster: LuminanceRaster
    frame: DrawingFrameMM | None = None
    options: PortraitContourOptions = Field(default_factory=PortraitContourOptions)
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    request_id: str | None = None


class PortraitContourPolyline(BaseModel):
    points: list[PaperPointNorm]
    closed: bool = False


class PortraitContourOverlay(BaseModel):
    coordinate_space: Literal["portrait_crop_norm"] = "portrait_crop_norm"
    raster_width: int
    raster_height: int
    contours: list[PortraitContourPolyline] = Field(default_factory=list)


class PortraitContourPreviewResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool = True
    preview_only: bool = True
    eligible_for_bridge_preview: bool = False
    planned_commands: list[str] = Field(default_factory=list)
    simulation: SimulatedPath | None = None
    summary: PolygonDrawPlanSummary | None = None
    portrait_summary: PortraitContourSummary | None = None
    portrait_overlay: PortraitContourOverlay | None = None
    preview_overlay: PreviewOverlay | None = None
    event_log: str
    controller_transcript: str | None = None
    error: str | None = None


class CapabilityTestRequest(BaseModel):
    kind: CapabilityTestKind = "center_crosshair"
    frame: DrawingFrameMM | None = None
    include_homing: bool = False
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    expected_plan_hash: str | None = None
    request_id: str | None = None


class CapabilityTestResponse(PolygonDrawResponse):
    preview_only: bool = False
    kind: CapabilityTestKind = "center_crosshair"
    label: str = ""
    residual_roles: list[str] = Field(default_factory=list)
    plan_hash: str = ""


class MachineActionRequest(BaseModel):
    request_id: str | None = None


class MachineJogRequest(MachineActionRequest):
    axis: str
    distance_mm: float
    feed_mm_min: float = 500.0


class MachineRelativeMoveRequest(MachineActionRequest):
    x_mm: float = 0.0
    y_mm: float = 0.0
    feed_mm_min: float = 300.0
    ensure_pen_up: bool = True


class MachineRelativeMarkRequest(MachineActionRequest):
    mark_size_mm: float = 6.0
    draw_feed_mm_min: float = 120.0
    travel_feed_mm_min: float = 300.0


class MachineHomeRequest(MachineActionRequest):
    center_after: bool = True
    center_feed_mm_min: float = 500.0


class MachineCenterRequest(MachineActionRequest):
    feed_mm_min: float = 500.0


class MachinePenRequest(MachineActionRequest):
    pass


class MachineDotMarkRequest(MachineActionRequest):
    pass


class MachineStopRequest(MachineActionRequest):
    pass


class MachineReconnectRequest(MachineActionRequest):
    controller_port: str | None = None
    auto_connect: bool = True


class MachineResumeRequest(MachineActionRequest):
    pass


class MachineUnlockRequest(MachineActionRequest):
    pass


class MachineArmRequest(MachineActionRequest):
    live: bool = True
    controller_port: str | None = None
    auto_connect: bool = True
    arm_motion: bool = True
    arm_pen: bool = True
    arm_homing: bool = True
    arm_unlock: bool = True


class AxisModelTrustSample(BaseModel):
    axis: str
    commanded_distance_mm: float
    observed_dx_mm: float
    observed_dy_mm: float
    observed_distance_mm: float


class AxisModelTrustRequest(MachineActionRequest):
    source: str = "green_cap_visual_probe"
    sample_count: int
    rms_residual_mm: float
    max_residual_mm: float
    min_observed_distance_mm: float
    command_distance_mm: float
    samples: list[AxisModelTrustSample] = Field(default_factory=list)


class MachineCommandResponse(BaseModel):
    command_id: str
    action: str
    status: str
    dry_run: bool
    planned_commands: list[str]
    event_log: str
    controller_transcript: str | None = None
    machine_status: MachineStatusResponse | None = None
    error: str | None = None


class EventLog:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._sequence = 0
        self._lock = Lock()
        self._recent: deque[BridgeEvent] = deque(maxlen=200)

    def emit(
        self,
        event_type: str,
        *,
        status: str,
        command_id: str | None = None,
        payload: dict[str, Any] | None = None,
    ) -> BridgeEvent:
        with self._lock:
            self._sequence += 1
            event = BridgeEvent(
                type=event_type,
                sequence=self._sequence,
                command_id=command_id,
                status=status,
                payload=payload or {},
            )
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as file:
                file.write(event.model_dump_json(by_alias=True) + "\n")
            self._recent.append(event)
            return event

    def recent(self) -> list[BridgeEvent]:
        with self._lock:
            return list(self._recent)


class PlotterBridge:
    def __init__(self, config: BridgeRuntimeConfig) -> None:
        self.config = config
        self.event_log = EventLog(config.event_log_path)
        self._started_at = datetime.now(timezone.utc).isoformat()
        self._machine_lock = Lock()
        self._state_lock = Lock()
        self._active_command_id: str | None = None
        self._active_action: str | None = None
        self._active_controller: GrblHalController | None = None
        self._last_machine_status: MachineStatusResponse | None = None
        self._app_diagnostics_lock = Lock()
        self._app_event_sequence = 0
        self._recent_app_events: deque[AppDiagnosticRecord] = deque(maxlen=100)
        self._latest_app_state: AppDiagnosticRecord | None = None
        self._load_app_diagnostics_from_disk()

    def health(self) -> BridgeHealthResponse:
        machine = self._load_machine_config()
        lifecycle_mode = self._lifecycle_mode()
        return BridgeHealthResponse(
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            bridge_api_version=BRIDGE_API_VERSION,
            lifecycle_mode=lifecycle_mode,
            lifecycle_label=self._lifecycle_label(lifecycle_mode),
            bridge_build_id=BRIDGE_BUILD_ID,
            bridge_source_root=str(BRIDGE_SOURCE_ROOT),
            bridge_pid=os.getpid(),
            bridge_started_at=self._started_at,
            can_restart_safely=self._can_restart_safely(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            event_log=str(self.config.event_log_path),
            workspace_x_mm=machine.axes.x.travel_mm,
            workspace_y_mm=machine.axes.y.travel_mm,
            max_feed_mm_min=machine.max_feed_mm_min,
            max_jog_mm=machine.max_jog_mm,
        )

    def record_app_state(
        self, request: AppDiagnosticStateRequest
    ) -> AppDiagnosticIngestResponse:
        record = self._record_app_diagnostic(
            kind="state",
            event_type="app.state",
            source=request.source,
            observed_at=request.observed_at,
            app_build_id=request.app_build_id,
            bridge_url=request.bridge_url,
            status=request.status,
            payload=request.payload,
        )
        self.event_log.emit(
            "app.diagnostics_ingested",
            status="accepted",
            payload={
                "kind": record.kind,
                "event_type": record.event_type,
                "source": record.source,
                "app_sequence": record.sequence,
            },
        )
        return AppDiagnosticIngestResponse(
            state_file=str(self.config.app_state_path),
            event_log=str(self.config.app_event_log_path),
            record=record,
        )

    def record_app_event(
        self, request: AppDiagnosticEventRequest
    ) -> AppDiagnosticIngestResponse:
        record = self._record_app_diagnostic(
            kind="event",
            event_type=request.event_type,
            source=request.source,
            observed_at=request.observed_at,
            app_build_id=request.app_build_id,
            bridge_url=request.bridge_url,
            status=request.status,
            payload=request.payload,
        )
        self.event_log.emit(
            "app.diagnostics_ingested",
            status="accepted",
            payload={
                "kind": record.kind,
                "event_type": record.event_type,
                "source": record.source,
                "app_sequence": record.sequence,
            },
        )
        return AppDiagnosticIngestResponse(
            state_file=str(self.config.app_state_path),
            event_log=str(self.config.app_event_log_path),
            record=record,
        )

    def app_diagnostics_snapshot(self) -> AppDiagnosticsSnapshot:
        disk_state, disk_events = self._read_app_diagnostics_from_disk()
        with self._app_diagnostics_lock:
            memory_events = list(self._recent_app_events)
            memory_state = self._latest_app_state

        recent = self._merge_app_diagnostic_events(disk_events, memory_events)
        latest_state = disk_state or memory_state
        if latest_state is None:
            latest_state = next(
                (record for record in reversed(recent) if record.kind == "state"),
                None,
            )
        latest_event = next((record for record in reversed(recent) if record.kind == "event"), None)
        return AppDiagnosticsSnapshot(
            state_file=str(self.config.app_state_path),
            event_log=str(self.config.app_event_log_path),
            latest_state=latest_state,
            latest_event=latest_event,
            recent_events=recent,
        )

    def codex_snapshot(self) -> CodexSnapshotResponse:
        return CodexSnapshotResponse(
            generated_at=_utc_now_iso(),
            health=self.health(),
            machine=self._machine_status_snapshot(),
            paper=self.paper_registration_status(),
            recent_events=self.recent_events(),
            app_diagnostics=self.app_diagnostics_snapshot(),
        )

    def machine_status(self) -> MachineStatusResponse:
        active_status = self._active_machine_status()
        if active_status is not None:
            return active_status

        if self.config.controller_port is None and not self.config.mock:
            status = self._offline_machine_status(
                status="dry_run" if self.config.dry_run else "offline",
                state="DryRun" if self.config.dry_run else "Offline",
                error=None if self.config.dry_run else "No controller is configured.",
            )
            self._remember_machine_status(status)
            return status

        if not self._machine_lock.acquire(blocking=False):
            return self._locked_machine_status()

        try:
            transcript_path = self.config.transcript_dir / f"status-{uuid.uuid4().hex[:12]}.jsonl"
            with self._make_controller(transcript_path=transcript_path) as controller:
                controller.drain_until_quiet(quiet_s=0.05, max_s=0.25)
                report = controller.query_status_report(timeout_s=2.0)
                status = self._machine_status_from_report(report, status="ready")
                controller.flush_transcript()
            self._remember_machine_status(status)
            self.event_log.emit(
                "machine.status_sample",
                status=status.state,
                payload={
                    "mpos_mm": status.mpos_mm,
                    "wpos_mm": status.wpos_mm,
                    "pins": status.pins,
                    "dry_run": self.config.dry_run,
                },
            )
            return status
        except Exception as exc:
            status = self._offline_machine_status(status="failed", state="Offline", error=str(exc))
            self._remember_machine_status(status)
            self.event_log.emit(
                "machine.status_failed",
                status="failed",
                payload={"error": str(exc)},
            )
            return status
        finally:
            self._machine_lock.release()

    def reconnect_machine(self, request: MachineReconnectRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"reconnect-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        action = "reconnect"
        planned_commands = ["<reconnect>"]
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={"action": action, "dry_run": self.config.dry_run},
        )

        try:
            self._configure_controller_port(
                controller_port=request.controller_port,
                auto_connect=request.auto_connect,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

        if self.config.controller_port is None and not self.config.mock:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error="No controller is configured.",
            )

        if not self._machine_lock.acquire(blocking=False):
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error="Machine is busy; reconnect could not attach.",
            )

        self._set_active_command(command_id=command_id, action=action)
        try:
            with self._make_controller(transcript_path=transcript_path) as controller:
                self._set_active_controller(controller)
                try:
                    controller.wake_and_drain(quiet_s=0.25, max_s=3.0)
                    report = controller.query_status_report(timeout_s=3.0)
                    machine_status = self._machine_status_from_report(report, status="ready")
                    self._remember_machine_status(machine_status)
                    controller.flush_transcript()
                finally:
                    self._set_active_controller(None)

            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": self.config.dry_run,
                    "transcript": str(transcript_path),
                    "state": machine_status.state,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=self.config.dry_run,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path),
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )
        finally:
            self._set_active_command(command_id=None, action=None)
            self._machine_lock.release()

    def arm_machine(self, request: MachineArmRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"arm-{uuid.uuid4().hex[:12]}"
        action = "arm" if request.live else "disarm"
        planned_commands = ["<runtime-arm>" if request.live else "<runtime-disarm>"]
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={
                "action": action,
                "dry_run": self.config.dry_run,
                "live": request.live,
            },
        )

        if not self._machine_lock.acquire(blocking=False):
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error="Machine is busy; runtime arming is blocked.",
            )

        self._set_active_command(command_id=command_id, action=action)
        try:
            if request.live:
                if self.config.mock:
                    raise MotionSafetyError(
                        "Runtime hardware arming requires a serial controller bridge, not mock."
                    )
                self._configure_controller_port(
                    controller_port=request.controller_port,
                    auto_connect=request.auto_connect,
                )
                if self.config.controller_port is None:
                    raise MotionSafetyError("No controller is configured.")

                with self._make_controller(transcript_path=transcript_path) as controller:
                    self._set_active_controller(controller)
                    try:
                        controller.drain_until_quiet(quiet_s=0.05, max_s=0.25)
                        report = controller.query_status_report(timeout_s=3.0)
                    finally:
                        self._set_active_controller(None)

                    self.config.dry_run = False
                    self.config.arm_motion = request.arm_motion
                    self.config.arm_pen = request.arm_pen
                    self.config.arm_homing = request.arm_homing
                    self.config.arm_unlock = request.arm_unlock
                    machine_status = self._machine_status_from_report(report, status="ready")
                    controller.flush_transcript()
                controller_transcript = str(transcript_path)
            else:
                self.config.dry_run = True
                self.config.arm_motion = False
                self.config.arm_pen = False
                self.config.arm_homing = False
                self.config.arm_unlock = False
                controller_transcript = None
                if self.config.controller_port is not None or self.config.mock:
                    try:
                        with self._make_controller(transcript_path=transcript_path) as controller:
                            controller.drain_until_quiet(quiet_s=0.05, max_s=0.25)
                            report = controller.query_status_report(timeout_s=2.0)
                            machine_status = self._machine_status_from_report(
                                report,
                                status="ready",
                            )
                            controller.flush_transcript()
                        controller_transcript = str(transcript_path)
                    except Exception as exc:
                        machine_status = self._offline_machine_status(
                            status="dry_run",
                            state="DryRun",
                            error=str(exc),
                        )
                else:
                    machine_status = self._offline_machine_status(
                        status="dry_run",
                        state="DryRun",
                    )

            self._remember_machine_status(machine_status)
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": self.config.dry_run,
                    "controller": self._controller_description(),
                    "arm_motion": self.config.arm_motion,
                    "arm_pen": self.config.arm_pen,
                    "arm_homing": self.config.arm_homing,
                    "arm_unlock": self.config.arm_unlock,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=self.config.dry_run,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                controller_transcript=controller_transcript,
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )
        finally:
            self._set_active_controller(None)
            self._set_active_command(command_id=None, action=None)
            self._machine_lock.release()

    def draw_shape(self, request: ShapeExecutionRequest) -> ShapeExecutionResponse:
        command_id = request.request_id or f"cmd-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"

        try:
            machine = self._load_machine_config()
            self._require_axis_model_trusted(machine)
            safety = SafetyState(
                dry_run=self.config.dry_run,
                armed_motion=self.config.arm_motion,
                allow_pen_actuation=self.config.arm_pen,
                allow_homing=self.config.arm_homing,
            )
            plan = build_shape_execution_plan(
                request=request,
                machine=machine,
                safety=safety,
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            if plan.evaluation.status != "passed":
                raise MotionSafetyError(
                    f"Shape preview failed geometry gate: {plan.evaluation.message}"
                )
            self.event_log.emit(
                "draw.shape_started",
                command_id=command_id,
                status="running",
                payload={
                    "pattern": request.pattern,
                    "dry_run": self.config.dry_run,
                    "command_count": len(plan.planned_commands),
                    "preview_status": plan.evaluation.status,
                },
            )

            if self.config.dry_run:
                for planned in plan.planned_commands:
                    self.event_log.emit(
                        "machine.command_planned",
                        command_id=command_id,
                        status="planned",
                        payload=planned.model_dump(),
                    )
                self.event_log.emit(
                    "draw.shape_completed",
                    command_id=command_id,
                    status="completed",
                    payload={"dry_run": True},
                )
                return self._response(
                    plan=plan,
                    status="completed",
                    transcript_path=None,
                    preview_overlay=preview_overlay,
                )

            self._run_plan(plan=plan, transcript_path=transcript_path)
            self.event_log.emit(
                "draw.shape_completed",
                command_id=command_id,
                status="completed",
                payload={"dry_run": False, "transcript": str(transcript_path)},
            )
            return self._response(
                plan=plan,
                status="completed",
                transcript_path=transcript_path,
                preview_overlay=preview_overlay,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.shape_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return ShapeExecutionResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                pattern=request.pattern,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                evaluation=locals().get("plan").evaluation if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path) if transcript_path.exists() else None,
                error=str(exc),
            )

    def preview_shape(self, request: ShapeExecutionRequest) -> ShapeExecutionResponse:
        command_id = request.request_id or f"preview-{uuid.uuid4().hex[:12]}"

        try:
            machine = self._load_machine_config()
            plan = build_shape_execution_plan(
                request=request,
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            if plan.evaluation.status != "passed":
                raise MotionSafetyError(
                    f"Shape preview failed geometry gate: {plan.evaluation.message}"
                )
            self.event_log.emit(
                "draw.shape_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "pattern": request.pattern,
                    "command_count": len(plan.planned_commands),
                    "preview_status": plan.evaluation.status,
                },
            )
            return self._response(
                plan=plan,
                status="ready",
                transcript_path=None,
                preview_overlay=preview_overlay,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.shape_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return ShapeExecutionResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                pattern=request.pattern,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                evaluation=locals().get("plan").evaluation if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def preview_draw_program(self, request: PolygonDrawRequest) -> PolygonDrawResponse:
        command_id = request.request_id or f"draw-preview-{uuid.uuid4().hex[:12]}"

        try:
            machine = self._load_machine_config()
            plan = build_polygon_draw_plan(
                request=request,
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            self.event_log.emit(
                "draw.program_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "polyline_count": plan.summary.polyline_count,
                    "draw_segment_count": plan.summary.draw_segment_count,
                    "command_count": len(plan.planned_commands),
                    "dry_run": True,
                    "preview_only": True,
                },
            )
            return PolygonDrawResponse(
                command_id=command_id,
                status="ready",
                dry_run=True,
                planned_commands=plan.command_strings,
                simulation=plan.simulation,
                summary=plan.summary,
                preview_overlay=preview_overlay,
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.program_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc), "preview_only": True},
            )
            return PolygonDrawResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def preview_image_contours(self, request: ImageShapePreviewRequest) -> ImageShapePreviewResponse:
        command_id = request.request_id or f"image-preview-{uuid.uuid4().hex[:12]}"
        try:
            program, raster_summary = build_paper_contour_program_from_luminance_raster(
                raster=request.raster,
                options=request.options,
            )
            if not program.polylines:
                raise MotionSafetyError("Image baseline produced no preview contours.")

            machine = self._load_machine_config()
            plan = build_polygon_draw_plan(
                request=PolygonDrawRequest(
                    program=program,
                    frame=request.frame,
                    include_homing=False,
                    draw_feed_mm_min=request.draw_feed_mm_min,
                    travel_feed_mm_min=request.travel_feed_mm_min,
                    max_segment_mm=request.max_segment_mm,
                    request_id=command_id,
                ),
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            self.event_log.emit(
                "draw.image_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "contour_count": raster_summary.contour_count,
                    "draw_segment_count": plan.summary.draw_segment_count,
                    "dry_run": True,
                    "preview_only": True,
                },
            )
            return ImageShapePreviewResponse(
                command_id=command_id,
                status="ready",
                dry_run=True,
                preview_only=True,
                eligible_for_bridge_preview=True,
                planned_commands=plan.command_strings,
                simulation=plan.simulation,
                summary=plan.summary,
                raster_summary=raster_summary,
                preview_overlay=preview_overlay,
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.image_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc), "preview_only": True},
            )
            return ImageShapePreviewResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                preview_only=True,
                eligible_for_bridge_preview=False,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                raster_summary=locals().get("raster_summary"),
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def draw_program(self, request: PolygonDrawRequest) -> PolygonDrawResponse:
        command_id = request.request_id or f"draw-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"

        try:
            machine = self._load_machine_config()
            self._require_axis_model_trusted(machine)
            draw_request = request
            if self._visual_ready_to_plot():
                draw_request = request.model_copy(update={"visual_position_trusted": True})
            plan = build_polygon_draw_plan(
                request=draw_request,
                machine=machine,
                safety=self._safety_state(),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            self.event_log.emit(
                "draw.program_started",
                command_id=command_id,
                status="running",
                payload={
                    "dry_run": self.config.dry_run,
                    "polyline_count": plan.summary.polyline_count,
                    "draw_segment_count": plan.summary.draw_segment_count,
                    "command_count": len(plan.planned_commands),
                },
            )
            machine_response = self._run_machine_action(
                action="draw_program",
                command_id=command_id,
                planned_commands=plan.planned_commands,
                transcript_path=transcript_path,
            )
            if machine_response.status == "completed":
                self.event_log.emit(
                    "draw.program_completed",
                    command_id=command_id,
                    status="completed",
                    payload={
                        "dry_run": self.config.dry_run,
                        "drawn_length_mm": plan.summary.drawn_length_mm,
                        "transcript": machine_response.controller_transcript,
                    },
                )
            else:
                self.event_log.emit(
                    "draw.program_failed",
                    command_id=command_id,
                    status="failed",
                    payload={"error": machine_response.error},
                )
            return self._draw_program_response(
                plan=plan,
                machine_response=machine_response,
                preview_overlay=preview_overlay,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.program_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return PolygonDrawResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path) if transcript_path.exists() else None,
                error=str(exc),
            )

    def preview_portrait_contours(
        self,
        request: PortraitContourPreviewRequest,
    ) -> PortraitContourPreviewResponse:
        command_id = request.request_id or f"portrait-preview-{uuid.uuid4().hex[:12]}"
        try:
            program, portrait_summary = build_portrait_contour_program_from_luminance_raster(
                raster=request.raster,
                options=request.options,
            )
            if not program.polylines:
                raise MotionSafetyError("Portrait normalization produced no preview contours.")

            portrait_overlay = PortraitContourOverlay(
                raster_width=request.raster.width,
                raster_height=request.raster.height,
                contours=[
                    PortraitContourPolyline(
                        points=[PaperPointNorm(x=point.x, y=point.y) for point in polyline.points],
                        closed=polyline.closed,
                    )
                    for polyline in program.polylines
                ],
            )
            machine = self._load_machine_config()
            plan = build_polygon_draw_plan(
                request=PolygonDrawRequest(
                    program=program,
                    frame=request.frame,
                    include_homing=False,
                    draw_feed_mm_min=request.draw_feed_mm_min,
                    travel_feed_mm_min=request.travel_feed_mm_min,
                    max_segment_mm=request.max_segment_mm,
                    max_polyline_count=request.options.max_contours,
                    request_id=command_id,
                ),
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            self.event_log.emit(
                "draw.portrait_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "contour_count": portrait_summary.contour_count,
                    "draw_segment_count": plan.summary.draw_segment_count,
                    "dry_run": True,
                    "preview_only": True,
                },
            )
            return PortraitContourPreviewResponse(
                command_id=command_id,
                status="ready",
                dry_run=True,
                preview_only=True,
                eligible_for_bridge_preview=True,
                planned_commands=plan.command_strings,
                simulation=plan.simulation,
                summary=plan.summary,
                portrait_summary=portrait_summary,
                portrait_overlay=portrait_overlay,
                preview_overlay=preview_overlay,
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.portrait_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc), "preview_only": True},
            )
            return PortraitContourPreviewResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                preview_only=True,
                eligible_for_bridge_preview=False,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                portrait_summary=locals().get("portrait_summary"),
                portrait_overlay=locals().get("portrait_overlay"),
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def draw_face_raster(self, request: FaceRasterDrawRequest) -> FaceRasterDrawResponse:
        command_id = request.request_id or f"face-{uuid.uuid4().hex[:12]}"
        try:
            program, raster_summary = build_paper_program_from_luminance_raster(
                raster=request.raster,
                options=request.options,
            )
            if not program.polygons:
                raise MotionSafetyError("Face raster produced no drawable dark regions.")

            self.event_log.emit(
                "draw.face_raster_started",
                command_id=command_id,
                status="running",
                payload={
                    "raster_width": raster_summary.raster_width,
                    "raster_height": raster_summary.raster_height,
                    "polygon_count": raster_summary.polygon_count,
                    "selected_cell_count": raster_summary.selected_cell_count,
                    "dry_run": self.config.dry_run,
                },
            )
            polygon_response = self.draw_program(
                PolygonDrawRequest(
                    program=program,
                    frame=request.frame,
                    include_homing=request.include_homing,
                    draw_feed_mm_min=request.draw_feed_mm_min,
                    travel_feed_mm_min=request.travel_feed_mm_min,
                    max_segment_mm=request.max_segment_mm,
                    request_id=command_id,
                )
            )
            if polygon_response.status == "completed":
                self.event_log.emit(
                    "draw.face_raster_completed",
                    command_id=command_id,
                    status="completed",
                    payload={
                        "polygon_count": raster_summary.polygon_count,
                        "draw_segment_count": (
                            polygon_response.summary.draw_segment_count
                            if polygon_response.summary
                            else None
                        ),
                        "drawn_length_mm": (
                            polygon_response.summary.drawn_length_mm
                            if polygon_response.summary
                            else None
                        ),
                    },
                )
            else:
                self.event_log.emit(
                    "draw.face_raster_failed",
                    command_id=command_id,
                    status="failed",
                    payload={"error": polygon_response.error},
                )
            return FaceRasterDrawResponse(
                **polygon_response.model_dump(mode="json"),
                raster_summary=raster_summary,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.face_raster_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return FaceRasterDrawResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                planned_commands=[],
                simulation=None,
                summary=None,
                raster_summary=locals().get("raster_summary"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                machine_status=self._machine_error_status(error=str(exc)),
                error=str(exc),
            )

    def preview_capability_test(
        self,
        request: CapabilityTestRequest,
    ) -> CapabilityTestResponse:
        command_id = request.request_id or f"cap-preview-{uuid.uuid4().hex[:12]}"
        try:
            definition = build_capability_test_definition(request.kind)
            machine = self._load_machine_config()
            plan = build_polygon_draw_plan(
                request=PolygonDrawRequest(
                    program=definition.program,
                    frame=request.frame,
                    include_homing=request.include_homing,
                    draw_feed_mm_min=request.draw_feed_mm_min,
                    travel_feed_mm_min=request.travel_feed_mm_min,
                    max_segment_mm=request.max_segment_mm,
                    request_id=command_id,
                ),
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            plan_hash = _planned_command_hash(plan.command_strings)
            self.event_log.emit(
                "capabilities.test_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "kind": request.kind,
                    "draw_segment_count": plan.summary.draw_segment_count,
                    "plan_hash": plan_hash,
                    "preview_only": True,
                },
            )
            return CapabilityTestResponse(
                command_id=command_id,
                status="ready",
                dry_run=True,
                preview_only=True,
                kind=request.kind,
                label=definition.label,
                residual_roles=definition.residual_roles,
                plan_hash=plan_hash,
                planned_commands=plan.command_strings,
                simulation=plan.simulation,
                summary=plan.summary,
                preview_overlay=preview_overlay,
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
            )
        except Exception as exc:
            self.event_log.emit(
                "capabilities.test_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"kind": request.kind, "error": str(exc), "preview_only": True},
            )
            return CapabilityTestResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                preview_only=True,
                kind=request.kind,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def run_capability_test(self, request: CapabilityTestRequest) -> CapabilityTestResponse:
        command_id = request.request_id or f"cap-run-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            definition = build_capability_test_definition(request.kind)
            machine = self._load_machine_config()
            self._require_axis_model_trusted(machine)
            plan = build_polygon_draw_plan(
                request=PolygonDrawRequest(
                    program=definition.program,
                    frame=request.frame,
                    include_homing=request.include_homing,
                    visual_position_trusted=self._visual_ready_to_plot(),
                    draw_feed_mm_min=request.draw_feed_mm_min,
                    travel_feed_mm_min=request.travel_feed_mm_min,
                    max_segment_mm=request.max_segment_mm,
                    request_id=command_id,
                ),
                machine=machine,
                safety=self._safety_state(),
                command_id=command_id,
            )
            plan_hash = _planned_command_hash(plan.command_strings)
            if request.expected_plan_hash and request.expected_plan_hash != plan_hash:
                raise MotionSafetyError(
                    "Capabilities test plan changed after preview; preview the test again."
                )
            preview_overlay = self._preview_overlay_for_simulation(
                command_id=command_id,
                simulation=plan.simulation,
                machine=machine,
            )
            machine_response = self._run_machine_action(
                action="capability_test",
                command_id=command_id,
                planned_commands=plan.planned_commands,
                transcript_path=transcript_path,
            )
            self.event_log.emit(
                (
                    "capabilities.test_completed"
                    if machine_response.status == "completed"
                    else "capabilities.test_failed"
                ),
                command_id=command_id,
                status=machine_response.status,
                payload={
                    "kind": request.kind,
                    "plan_hash": plan_hash,
                    "dry_run": machine_response.dry_run,
                    "error": machine_response.error,
                },
            )
            return CapabilityTestResponse(
                **self._draw_program_response(
                    plan=plan,
                    machine_response=machine_response,
                    preview_overlay=preview_overlay,
                ).model_dump(mode="json"),
                preview_only=False,
                kind=request.kind,
                label=definition.label,
                residual_roles=definition.residual_roles,
                plan_hash=plan_hash,
            )
        except Exception as exc:
            self.event_log.emit(
                "capabilities.test_failed",
                command_id=command_id,
                status="failed",
                payload={"kind": request.kind, "error": str(exc)},
            )
            return CapabilityTestResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                preview_only=False,
                kind=request.kind,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                summary=locals().get("plan").summary if "plan" in locals() else None,
                preview_overlay=locals().get("preview_overlay"),
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path) if transcript_path.exists() else None,
                error=str(exc),
            )

    def register_paper(self, request: PaperRegistrationRequest) -> PaperRegistrationResponse:
        try:
            machine = self._load_machine_config()
            paper_width_mm = request.paper_width_mm or machine.axes.x.travel_mm
            paper_height_mm = request.paper_height_mm or machine.axes.y.travel_mm
            if not request.corners:
                raise ValueError("Provide four paper corner observations.")
            corner_observations = [
                PaperCornerObservation(
                    corner=corner.corner,
                    expected_paper_norm=paper_corner_norm(corner.corner),
                    observed_norm=corner.observed_norm,
                    strength=corner.strength,
                    observation_source=corner.observation_source,
                    camera_id=corner.camera_id,
                    camera_name=corner.camera_name,
                )
                for corner in request.corners
            ]
            registration = build_paper_frame_registration(
                corner_observations,
                paper_width_mm=paper_width_mm,
                paper_height_mm=paper_height_mm,
            )

            self._save_paper_registration(registration)
            self.event_log.emit(
                "paper.registration_locked",
                command_id=registration.registration_id,
                status=registration.status,
                payload={
                    "rms_error_norm": registration.rms_error_norm,
                    "max_error_norm": registration.max_error_norm,
                    "corner_count": len(registration.corner_observations),
                    "paper_width_mm": registration.paper_size_mm.width,
                    "paper_height_mm": registration.paper_size_mm.height,
                },
            )
            return self._paper_registration_response(registration)
        except Exception as exc:
            registration_id = f"paper-{uuid.uuid4().hex[:12]}"
            self.event_log.emit(
                "paper.registration_failed",
                command_id=registration_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return PaperRegistrationResponse(
                status="failed",
                dry_run=self.config.dry_run,
                error=str(exc),
            )

    def paper_registration_status(self) -> PaperRegistrationResponse:
        try:
            return self._paper_registration_response(self._load_latest_paper_registration())
        except Exception as exc:
            return PaperRegistrationResponse(
                status="missing",
                dry_run=self.config.dry_run,
                error=str(exc),
            )

    def visual_readiness_status(self) -> VisualReadinessResponse:
        try:
            state = self._load_latest_visual_readiness()
            state = self._visual_state_with_latest_probe_evidence(state)
            self._save_visual_readiness(state)
            return self._visual_readiness_response(state)
        except Exception as exc:
            paper_registered = False
            paper_registration_id: str | None = None
            try:
                registration = self._load_latest_paper_registration()
                paper_registered = True
                paper_registration_id = registration.registration_id
            except Exception:
                pass
            state = build_visual_readiness_state(
                paper_registered=paper_registered,
                cap_observation=None,
                safe_zone_evaluation=None,
                probe_observation_count=0,
            )
            state.paper_registration_id = paper_registration_id
            return VisualReadinessResponse(
                status="blocked",
                dry_run=self.config.dry_run,
                readiness=state.model_dump(mode="json"),
                readiness_file=str(self._latest_visual_readiness_path()),
                error=str(exc),
            )

    def observe_visual_probe_sample(
        self,
        request: VisualProbeSampleObservationRequest,
    ) -> VisualProbeSampleObservationResponse:
        try:
            registration = self._load_latest_paper_registration()
            if (
                request.paper_registration_id is not None
                and request.paper_registration_id != registration.registration_id
            ):
                raise ValueError(
                    "Probe sample paper_registration_id does not match the current paper registration."
                )
            run_id = request.run_id or f"probe-run-{uuid.uuid4().hex[:12]}"
            sample_kwargs: dict[str, Any] = {}
            if request.sample_id is not None:
                sample_kwargs["sample_id"] = request.sample_id
            if request.observed_at is not None:
                sample_kwargs["observed_at"] = request.observed_at
            sample = VisualProbeSample(
                **sample_kwargs,
                run_id=run_id,
                request_id=request.request_id,
                plan_id=request.plan_id,
                command_id=request.command_id,
                paper_registration_id=registration.registration_id,
                camera_id=request.camera_id or registration.camera_id,
                camera_name=request.camera_name or registration.camera_name,
                source=request.source,
                axis=request.axis,
                commanded_dx_mm=request.commanded_dx_mm,
                commanded_dy_mm=request.commanded_dy_mm,
                before=request.before,
                after=request.after,
                predicted_dx_mm=request.predicted_dx_mm,
                predicted_dy_mm=request.predicted_dy_mm,
                residual_mm=request.residual_mm,
                residual_limit_mm=request.residual_limit_mm,
                status=request.status,
                blockers=request.blockers,
                rejection_reason=request.rejection_reason,
                controller_transcript=request.controller_transcript,
            )
            run = self._load_visual_probe_run_or_new(run_id)
            run.upsert_sample(
                sample,
                current_paper_registration_id=registration.registration_id,
                current_camera_id=registration.camera_id,
            )
            self._save_visual_probe_run(run)

            previous = self._load_latest_visual_readiness_or_none()
            machine = self._load_machine_config()
            safe_zone = (
                previous.safe_zone
                if previous is not None and previous.safe_zone is not None
                else self._drawing_safe_zone(machine=machine, inset_x_mm=10.0, inset_y_mm=10.0)
            )
            cap = VisualCapObservation(
                timestamp=sample.observed_at,
                camera_norm=sample.after.camera_norm,
                paper_norm=sample.after.paper_norm,
                logical_mm=sample.after.logical_mm,
                confidence=sample.after.confidence,
                source="camera_detection",
                camera_id=sample.camera_id,
                camera_name=sample.camera_name,
                paper_registration_id=registration.registration_id,
            )
            evaluation = evaluate_cap_inside_safe_zone(observation=cap, safe_zone=safe_zone)
            state = self._visual_state_from_probe_run(
                cap=cap,
                safe_zone_evaluation=evaluation,
                previous=previous,
                run=run,
            )
            self._save_visual_readiness(state)
            self.event_log.emit(
                "calibration.probe_sample_observed",
                command_id=sample.command_id or sample.sample_id,
                status=sample.status,
                payload={
                    "run_id": run.run_id,
                    "sample_id": sample.sample_id,
                    "source": sample.source,
                    "axis": sample.axis,
                    "status": sample.status,
                    "accepted_sample_count": run.summary.accepted_sample_count,
                    "rejected_sample_count": run.summary.rejected_sample_count,
                    "axes_represented": run.summary.axes_represented,
                    "visual_ready_to_plot": state.visual_ready_to_plot,
                    "blockers": state.blockers,
                    "probe_run_file": str(self._visual_probe_run_path(run.run_id)),
                },
            )
            return VisualProbeSampleObservationResponse(
                status=sample.status,
                dry_run=self.config.dry_run,
                sample=sample,
                summary=run.summary,
                probe_run_file=str(self._visual_probe_run_path(run.run_id)),
                latest_probe_run_file=str(self._latest_visual_probe_run_path()),
                readiness=state.model_dump(mode="json"),
                readiness_file=str(self._latest_visual_readiness_path()),
            )
        except Exception as exc:
            self.event_log.emit(
                "calibration.probe_sample_failed",
                status="failed",
                payload={"error": str(exc), "source": request.source},
            )
            return VisualProbeSampleObservationResponse(
                status="failed",
                dry_run=self.config.dry_run,
                latest_probe_run_file=str(self._latest_visual_probe_run_path()),
                readiness_file=str(self._latest_visual_readiness_path()),
                error=str(exc),
            )

    def observe_visual_cap(self, request: VisualCapObservationRequest) -> VisualReadinessResponse:
        try:
            machine = self._load_machine_config()
            registration = self._load_latest_paper_registration()
            cap = self._visual_cap_observation(
                request=request,
                machine=machine,
                registration=registration,
            )
            previous = self._load_latest_visual_readiness_or_none()
            safe_zone = self._drawing_safe_zone(
                machine=machine,
                inset_x_mm=request.safe_zone_inset_x_mm,
                inset_y_mm=request.safe_zone_inset_y_mm,
            )
            evaluation = evaluate_cap_inside_safe_zone(observation=cap, safe_zone=safe_zone)
            state = self._visual_state_from_evidence(
                cap=cap,
                safe_zone_evaluation=evaluation,
                previous=previous,
            )
            self._save_visual_readiness(state)
            self.event_log.emit(
                "calibration.visual_cap_observed",
                command_id=cap.observation_id,
                status="ready" if state.cap_inside_safe_zone else "blocked",
                payload={
                    "paper_registration_id": registration.registration_id,
                    "cap_inside_safe_zone": state.cap_inside_safe_zone,
                    "visual_ready_to_plot": state.visual_ready_to_plot,
                    "blockers": state.blockers,
                },
            )
            return self._visual_readiness_response(state)
        except Exception as exc:
            self.event_log.emit(
                "calibration.visual_cap_failed",
                status="failed",
                payload={"error": str(exc)},
            )
            return VisualReadinessResponse(
                status="failed",
                dry_run=self.config.dry_run,
                readiness_file=str(self._latest_visual_readiness_path()),
                error=str(exc),
            )

    def visual_position_binding_status(self) -> VisualPositionBindingResponse:
        try:
            binding = self._load_latest_visual_position_binding()
            registration = self._load_latest_paper_registration()
            binding = solve_visual_position_binding(
                binding,
                current_paper_registration_id=registration.registration_id,
                current_camera_id=registration.camera_id,
            )
            self._save_visual_position_binding(binding)
            return self._visual_position_binding_response(binding)
        except Exception as exc:
            return VisualPositionBindingResponse(
                status="missing",
                dry_run=self.config.dry_run,
                binding_file=str(self._latest_visual_position_binding_path()),
                error=str(exc),
            )

    def add_visual_binding_observation(
        self,
        request: VisualBindingObservationRequest,
    ) -> VisualPositionBindingResponse:
        try:
            registration = self._load_latest_paper_registration()
            binding = self._load_or_create_visual_position_binding(registration=registration)
            expected_sample = None
            if request.expected_paper_mm is None:
                expected_sample = find_expected_sample(
                    binding,
                    command_id=request.command_id,
                    point_id=request.point_id,
                )
                if expected_sample is None:
                    raise ValueError(
                        "No expected simulated geometry found for the observation; "
                        "preview the drawing first or provide expected_paper_mm."
                    )
                expected_paper_mm = expected_sample.expected_paper_mm
                point_id = expected_sample.point_id
            else:
                expected_paper_mm = request.expected_paper_mm
                point_id = request.point_id or f"manual-{len(binding.observed_geometry) + 1:04d}"

            if request.observed_paper_mm is not None:
                observed_paper_mm = request.observed_paper_mm
            elif request.observed_norm is not None:
                observed_paper_mm = registration.camera_norm_to_paper_mm(request.observed_norm)
            else:
                raise ValueError("Provide observed_norm or observed_paper_mm.")

            camera_id = request.camera_id or registration.camera_id
            camera_name = request.camera_name or registration.camera_name
            if binding.camera.camera_id is None and camera_id is not None:
                binding.camera.camera_id = camera_id
            if binding.camera.camera_name is None and camera_name is not None:
                binding.camera.camera_name = camera_name

            observation = ObservedGeometrySample(
                command_id=request.command_id,
                point_id=point_id,
                kind=request.kind,
                expected_paper_mm=expected_paper_mm,
                observed_paper_mm=observed_paper_mm,
                observed_camera_norm=request.observed_norm,
                camera_id=camera_id,
                camera_name=camera_name,
                paper_registration_id=registration.registration_id,
                confidence=request.confidence,
            )
            binding.observed_geometry.append(observation)
            binding = solve_visual_position_binding(
                binding,
                current_paper_registration_id=registration.registration_id,
                current_camera_id=registration.camera_id,
            )
            self._save_visual_position_binding(binding)
            self.event_log.emit(
                "calibration.binding_observation_added",
                command_id=request.command_id,
                status=binding.validation_status,
                payload={
                    "binding_id": binding.binding_id,
                    "observation_id": observation.observation_id,
                    "point_id": observation.point_id,
                    "kind": observation.kind,
                    "validation_status": binding.validation_status,
                    "blockers": binding.blockers,
                },
            )
            return self._visual_position_binding_response(
                binding,
                observation_id=observation.observation_id,
            )
        except Exception as exc:
            self.event_log.emit(
                "calibration.binding_observation_failed",
                command_id=request.command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return VisualPositionBindingResponse(
                status="failed",
                dry_run=self.config.dry_run,
                binding_file=str(self._latest_visual_position_binding_path()),
                error=str(exc),
            )

    def solve_visual_binding(
        self,
        request: VisualBindingSolveRequest,
    ) -> VisualPositionBindingResponse:
        command_id = request.request_id or f"binding-solve-{uuid.uuid4().hex[:12]}"
        try:
            registration = self._load_latest_paper_registration()
            binding = self._load_latest_visual_position_binding()
            binding = solve_visual_position_binding(
                binding,
                current_paper_registration_id=registration.registration_id,
                current_camera_id=registration.camera_id,
            )
            self._save_visual_position_binding(binding)
            self.event_log.emit(
                "calibration.binding_solved",
                command_id=command_id,
                status=binding.validation_status,
                payload={
                    "binding_id": binding.binding_id,
                    "validation_status": binding.validation_status,
                    "rms_residual_mm": binding.residuals.rms_residual_mm,
                    "max_residual_mm": binding.residuals.max_residual_mm,
                    "blockers": binding.blockers,
                },
            )
            return self._visual_position_binding_response(binding)
        except Exception as exc:
            self.event_log.emit(
                "calibration.binding_solve_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return VisualPositionBindingResponse(
                status="failed",
                dry_run=self.config.dry_run,
                binding_file=str(self._latest_visual_position_binding_path()),
                error=str(exc),
            )

    def preview_binding_marks(
        self,
        request: BindingMarkPreviewRequest,
    ) -> BindingMarkPreviewResponse:
        command_id = request.request_id or f"binding-preview-{uuid.uuid4().hex[:12]}"
        try:
            mark_plan = self._build_binding_mark_preview(
                request=request,
                command_id=command_id,
                safety=SafetyState(dry_run=True),
            )
            binding = self._load_or_create_visual_position_binding(
                registration=mark_plan.registration
            )
            binding = upsert_expected_geometry(
                binding,
                _binding_mark_expected_geometry(
                    command_id=command_id,
                    points=mark_plan.camera_points,
                ),
            )
            self._save_visual_position_binding(binding)
            response = BindingMarkPreviewResponse(
                command_id=command_id,
                status="ready",
                dry_run=True,
                registration_id=mark_plan.registration.registration_id,
                point_set=request.point_set,
                point_count=len(mark_plan.points),
                mark_size_mm=request.mark_size_mm,
                plan_hash=mark_plan.plan_hash,
                planned_commands=mark_plan.plan.command_strings,
                simulation=mark_plan.plan.simulation,
                points=mark_plan.camera_points,
                camera_segments=mark_plan.camera_segments,
                event_log=str(self.config.event_log_path),
            )
            self.event_log.emit(
                "calibration.binding_preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "registration_id": mark_plan.registration.registration_id,
                    "point_set": request.point_set,
                    "point_count": len(mark_plan.points),
                    "camera_segment_count": len(mark_plan.camera_segments),
                    "plan_hash": mark_plan.plan_hash,
                    "preview_only": True,
                },
            )
            return response
        except Exception as exc:
            self.event_log.emit(
                "calibration.binding_preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc), "preview_only": True},
            )
            return BindingMarkPreviewResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                point_set=request.point_set,
                event_log=str(self.config.event_log_path),
                error=str(exc),
            )

    def _build_binding_mark_preview(
        self,
        *,
        request: BindingMarkPreviewRequest,
        command_id: str,
        safety: SafetyState,
    ) -> BindingMarkPreviewBundle:
        machine = self._load_machine_config()
        registration = self._load_latest_paper_registration()
        points = _binding_mark_points(
            registration=registration,
            point_set=request.point_set,
            margin_mm=request.margin_mm,
        )
        polylines, segment_point_ids = _binding_mark_polylines(
            points=points,
            mark_size_mm=request.mark_size_mm,
        )
        plan = build_polygon_draw_plan(
            request=PolygonDrawRequest(
                polylines=polylines,
                include_homing=False,
                visual_position_trusted=self._visual_ready_to_plot(),
                draw_feed_mm_min=request.draw_feed_mm_min,
                travel_feed_mm_min=request.travel_feed_mm_min,
                max_segment_mm=request.max_segment_mm,
                request_id=command_id,
            ),
            machine=machine,
            safety=safety,
            command_id=command_id,
        )
        _validate_binding_mark_simulation(plan=plan, segment_point_ids=segment_point_ids)

        camera_points = [
            BindingMarkPreviewPoint(
                point_id=point_id,
                paper_mm=paper_mm,
                camera_norm=_project_paper_mm_to_camera_norm(
                    paper_mm=paper_mm,
                    registration=registration,
                ),
            )
            for point_id, paper_mm in points
        ]
        camera_segments = [
            _project_drawn_segment_to_camera(
                segment=segment,
                point_id=point_id,
                machine=machine,
                registration=registration,
            )
            for segment, point_id in zip(plan.simulation.drawn_segments, segment_point_ids)
        ]
        return BindingMarkPreviewBundle(
            machine=machine,
            registration=registration,
            plan=plan,
            points=points,
            camera_points=camera_points,
            camera_segments=camera_segments,
            plan_hash=_planned_command_hash(plan.command_strings),
        )

    def jog_machine(self, request: MachineJogRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"jog-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = self._safety_state()
            axis = validate_jog_request(
                axis=request.axis,
                distance_mm=request.distance_mm,
                feed_mm_min=request.feed_mm_min,
                machine=machine,
                safety=safety,
            )
            commands = build_relative_jog_commands(
                axis=axis,
                distance_mm=request.distance_mm,
                feed_mm_min=request.feed_mm_min,
            )
            planned_commands = [
                PlannedCommand(command=command, kind="motion", description=f"Jog {axis}")
                for command in commands
            ]
            return self._run_machine_action(
                action="jog",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action="jog",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def relative_move_machine(self, request: MachineRelativeMoveRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"rel-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = SafetyState(
                dry_run=self.config.dry_run,
                armed_motion=self.config.arm_motion,
                allow_pen_actuation=self.config.arm_pen,
            )
            validate_relative_xy_move_request(
                x_mm=request.x_mm,
                y_mm=request.y_mm,
                feed_mm_min=request.feed_mm_min,
                machine=machine,
                safety=safety,
            )
            planned_commands: list[PlannedCommand] = []
            if request.ensure_pen_up:
                if machine.pen.up_command is None:
                    raise MotionSafetyError("Relative visual move requires configured pen up command.")
                pen_up = validate_pen_trial_command(machine.pen.up_command, safety)
                planned_commands.append(
                    PlannedCommand(command=pen_up, kind="pen", description="Raise pen")
                )
                if machine.pen.settle_s > 0:
                    planned_commands.append(
                        PlannedCommand(
                            command=f"G4 P{format_mm(machine.pen.settle_s)}",
                            kind="motion",
                            description="Wait for pen lift",
                        )
                    )
            planned_commands.extend(
                PlannedCommand(command=command, kind="motion", description="Relative visual move")
                for command in build_relative_xy_move_commands(
                    x_mm=request.x_mm,
                    y_mm=request.y_mm,
                    feed_mm_min=request.feed_mm_min,
                )
            )
            return self._run_machine_action(
                action="relative_move",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action="relative_move",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def relative_mark_machine(self, request: MachineRelativeMarkRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"rel-mark-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = SafetyState(
                dry_run=self.config.dry_run,
                armed_motion=self.config.arm_motion,
                allow_pen_actuation=self.config.arm_pen,
            )
            planned_commands = _relative_cross_mark_commands(
                request=request,
                machine=machine,
                safety=safety,
            )
            return self._run_machine_action(
                action="relative_mark",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action="relative_mark",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def trust_axis_model(self, request: AxisModelTrustRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"axis-trust-{uuid.uuid4().hex[:12]}"
        try:
            machine = self._load_machine_config()
            self._validate_axis_model_trust_request(request=request, machine=machine)
            state = self._load_latest_visual_readiness()
            if not state.cap_inside_safe_zone:
                raise MotionSafetyError(
                    "Visual readiness requires the green cap/carriage marker inside "
                    "the drawing-safe zone."
                )
            state = self._visual_state_from_evidence(
                cap=state.latest_cap_observation,
                safe_zone_evaluation=state.safe_zone_evaluation,
                previous=state,
                sample_count=request.sample_count,
                rms_residual_mm=request.rms_residual_mm,
                max_residual_mm=request.max_residual_mm,
            )
            self._save_visual_readiness(state)
            self.event_log.emit(
                "calibration.visual_readiness_trusted",
                command_id=command_id,
                status="completed",
                payload={
                    "source": request.source,
                    "sample_count": request.sample_count,
                    "rms_residual_mm": request.rms_residual_mm,
                    "max_residual_mm": request.max_residual_mm,
                    "min_observed_distance_mm": request.min_observed_distance_mm,
                    "command_distance_mm": request.command_distance_mm,
                    "axis_model_trusted": machine.axis_model_trusted,
                    "visual_ready_to_plot": state.visual_ready_to_plot,
                    "readiness_file": str(self._latest_visual_readiness_path()),
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action="visual_readiness_trust",
                status="completed" if state.visual_ready_to_plot else "failed",
                dry_run=self.config.dry_run,
                planned_commands=["<visual-readiness>"],
                event_log=str(self.config.event_log_path),
                machine_status=self.machine_status(),
                error=None if state.visual_ready_to_plot else "; ".join(state.blockers),
            )
        except Exception as exc:
            return self._machine_command_error(
                action="visual_readiness_trust",
                command_id=command_id,
                transcript_path=self.config.transcript_dir / f"{command_id}.jsonl",
                error=str(exc),
            )

    def home_machine(self, request: MachineHomeRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"home-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = self._safety_state()
            if not safety.dry_run and not safety.allow_homing:
                raise MotionSafetyError("Real homing requires allow_homing=true.")

            planned_commands = [
                PlannedCommand(command="$H", kind="homing", description="Run XY homing")
            ]
            if request.center_after:
                planned_commands.extend(
                    self._center_planned_commands(
                        machine=machine,
                        safety=safety,
                        feed_mm_min=request.center_feed_mm_min,
                    )
                )
            response = self._run_machine_action(
                action="home",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
            if response.status == "completed" and not response.dry_run:
                self._mark_machine_homing_trusted(machine)
                if response.machine_status is not None:
                    response.machine_status.homing_trusted = True
                    self._remember_machine_status(response.machine_status)
            return response
        except Exception as exc:
            return self._machine_command_error(
                action="home",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def center_machine(self, request: MachineCenterRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"center-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = self._safety_state()
            planned_commands = self._center_planned_commands(
                machine=machine,
                safety=safety,
                feed_mm_min=request.feed_mm_min,
            )
            return self._run_machine_action(
                action="center",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action="center",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def pen_up_machine(self, request: MachinePenRequest) -> MachineCommandResponse:
        return self._pen_machine(position="up", request=request)

    def pen_down_machine(self, request: MachinePenRequest) -> MachineCommandResponse:
        return self._pen_machine(position="down", request=request)

    def dot_mark_machine(self, request: MachineDotMarkRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"dot-mark-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = SafetyState(
                dry_run=self.config.dry_run,
                allow_pen_actuation=self.config.arm_pen,
            )
            if machine.pen.down_command is None or machine.pen.up_command is None:
                raise MotionSafetyError("Dot mark requires configured pen down and pen up commands.")
            pen_down = validate_pen_trial_command(machine.pen.down_command, safety)
            pen_up = validate_pen_trial_command(machine.pen.up_command, safety)
            planned_commands = [
                PlannedCommand(command=pen_down, kind="pen", description="Lower pen for dot mark")
            ]
            if machine.pen.settle_s > 0:
                planned_commands.append(
                    PlannedCommand(
                        command=f"G4 P{format_mm(machine.pen.settle_s)}",
                        kind="motion",
                        description="Wait for pen drop",
                    )
                )
            planned_commands.append(
                PlannedCommand(command=pen_up, kind="pen", description="Raise pen after dot mark")
            )
            if machine.pen.settle_s > 0:
                planned_commands.append(
                    PlannedCommand(
                        command=f"G4 P{format_mm(machine.pen.settle_s)}",
                        kind="motion",
                        description="Wait for pen lift",
                    )
                )
            return self._run_machine_action(
                action="dot_mark",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action="dot_mark",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def stop_machine(self, request: MachineStopRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"stop-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        action = "stop"
        planned_commands = ["!"]
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={
                "action": action,
                "dry_run": self.config.dry_run,
                "command_count": len(planned_commands),
            },
        )

        if self.config.dry_run:
            self.event_log.emit(
                "machine.command_planned",
                command_id=command_id,
                status="planned",
                payload={
                    "command": "!",
                    "kind": "realtime",
                    "description": "Realtime feed hold",
                },
            )
            machine_status = self._offline_machine_status(status="dry_run", state="DryRun")
            self._remember_machine_status(machine_status)
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={"action": action, "dry_run": True},
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=True,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                machine_status=machine_status,
            )

        try:
            active_controller = self._get_active_controller()
            if active_controller is not None:
                active_controller.feed_hold()
                machine_status = self._hold_machine_status()
                self._remember_machine_status(machine_status)
                self.event_log.emit(
                    "machine.realtime_sent",
                    command_id=command_id,
                    status="completed",
                    payload={
                        "command": "!",
                        "kind": "realtime",
                        "description": "Realtime feed hold",
                    },
                )
                self.event_log.emit(
                    "machine.action_completed",
                    command_id=command_id,
                    status="completed",
                    payload={"action": action, "dry_run": False, "active_command": True},
                )
                return MachineCommandResponse(
                    command_id=command_id,
                    action=action,
                    status="completed",
                    dry_run=False,
                    planned_commands=planned_commands,
                    event_log=str(self.config.event_log_path),
                    machine_status=machine_status,
                )

            if not self._machine_lock.acquire(timeout=1.0):
                raise MotionSafetyError("Machine is busy; realtime stop could not attach.")
            try:
                with self._make_controller(transcript_path=transcript_path) as controller:
                    report = controller.query_status_report()
                    state_root = report.state.split(":", 1)[0]
                    sent_hold = False
                    if state_root not in {"Idle", "Hold", "Alarm", "Door", "Check"}:
                        controller.feed_hold()
                        sent_hold = True
                        report = controller.query_status_report()
                    machine_status = self._machine_status_from_report(report, status="ready")
                    self._remember_machine_status(machine_status)
                    controller.flush_transcript()
            finally:
                self._machine_lock.release()

            if sent_hold:
                self.event_log.emit(
                    "machine.realtime_sent",
                    command_id=command_id,
                    status="completed",
                    payload={
                        "command": "!",
                        "kind": "realtime",
                        "description": "Realtime feed hold",
                    },
                )
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": False,
                    "transcript": str(transcript_path),
                    "state": machine_status.state,
                    "sent_hold": sent_hold,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=False,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path),
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def resume_machine(self, request: MachineResumeRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"resume-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        action = "resume"
        planned_commands = ["~"]
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={
                "action": action,
                "dry_run": self.config.dry_run,
                "command_count": len(planned_commands),
            },
        )

        if self.config.dry_run:
            machine_status = self._offline_machine_status(status="dry_run", state="DryRun")
            self._remember_machine_status(machine_status)
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={"action": action, "dry_run": True},
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=True,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                machine_status=machine_status,
            )

        if not self.config.arm_motion:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error="Real resume requires arm_motion=true.",
            )

        try:
            if not self._machine_lock.acquire(blocking=False):
                raise MotionSafetyError("Machine is busy; resume could not attach.")
            try:
                with self._make_controller(transcript_path=transcript_path) as controller:
                    controller.resume()
                    time.sleep(0.2)
                    final_report = controller.query_status_report()
                    machine_status = self._machine_status_from_report(final_report, status="ready")
                    self._remember_machine_status(machine_status)
                    controller.flush_transcript()
            finally:
                self._machine_lock.release()

            self.event_log.emit(
                "machine.realtime_sent",
                command_id=command_id,
                status="completed",
                payload={
                    "command": "~",
                    "kind": "realtime",
                    "description": "Realtime cycle start/resume",
                },
            )
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": False,
                    "transcript": str(transcript_path),
                    "state": machine_status.state,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=False,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path),
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def unlock_machine(self, request: MachineUnlockRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"unlock-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        action = "unlock"
        planned_commands = ["$X"]
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={
                "action": action,
                "dry_run": self.config.dry_run,
                "command_count": len(planned_commands),
            },
        )

        if self.config.dry_run:
            self.event_log.emit(
                "machine.command_planned",
                command_id=command_id,
                status="planned",
                payload={
                    "command": "$X",
                    "kind": "unlock",
                    "description": "Clear controller alarm",
                },
            )
            machine_status = self._offline_machine_status(status="dry_run", state="DryRun")
            self._remember_machine_status(machine_status)
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={"action": action, "dry_run": True},
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=True,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                machine_status=machine_status,
            )

        if not self.config.arm_unlock:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error="Real unlock requires arm_unlock=true.",
            )

        try:
            if not self._machine_lock.acquire(blocking=False):
                raise MotionSafetyError("Machine is busy; unlock could not attach.")
            try:
                self._set_active_command(command_id=command_id, action=action)
                with self._make_controller(transcript_path=transcript_path) as controller:
                    self._set_active_controller(controller)
                    try:
                        controller.wake_and_drain()
                        report = controller.query_status_report()
                        pins = report.fields.get("Pn", "")
                        if pins and pins != "-":
                            raise MotionSafetyError(
                                f"Cannot unlock while input pins are active: Pn:{pins}."
                            )
                        self.event_log.emit(
                            "machine.command_started",
                            command_id=command_id,
                            status="running",
                            payload={
                                "command": "$X",
                                "kind": "unlock",
                                "description": "Clear controller alarm",
                            },
                        )
                        controller.unlock()
                        self.event_log.emit(
                            "machine.command_completed",
                            command_id=command_id,
                            status="completed",
                            payload={
                                "command": "$X",
                                "kind": "unlock",
                                "description": "Clear controller alarm",
                            },
                        )
                        final_report = controller.query_status_report()
                        machine_status = self._machine_status_from_report(
                            final_report,
                            status="ready",
                        )
                        self._remember_machine_status(machine_status)
                        controller.flush_transcript()
                    finally:
                        self._set_active_controller(None)
            finally:
                self._set_active_command(command_id=None, action=None)
                self._machine_lock.release()

            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": False,
                    "transcript": str(transcript_path),
                    "state": machine_status.state,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=False,
                planned_commands=planned_commands,
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path),
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def recent_events(self) -> list[BridgeEvent]:
        return self.event_log.recent()

    def _machine_status_snapshot(self) -> MachineStatusResponse:
        active_status = self._active_machine_status()
        if active_status is not None:
            return active_status

        with self._state_lock:
            last_status = self._last_machine_status
        if last_status is not None:
            return last_status

        return self._offline_machine_status(
            status="dry_run" if self.config.dry_run else "offline",
            state="DryRun" if self.config.dry_run else "Unknown",
            error=None if self.config.dry_run else "No cached machine status.",
        )

    def _record_app_diagnostic(
        self,
        *,
        kind: Literal["state", "event"],
        event_type: str,
        source: str,
        observed_at: str | None,
        app_build_id: str | None,
        bridge_url: str | None,
        status: str,
        payload: dict[str, Any],
    ) -> AppDiagnosticRecord:
        with self._app_diagnostics_lock:
            self._app_event_sequence += 1
            record = AppDiagnosticRecord(
                sequence=self._app_event_sequence,
                kind=kind,
                event_type=event_type,
                source=source,
                received_at=_utc_now_iso(),
                observed_at=observed_at,
                app_build_id=app_build_id,
                bridge_url=bridge_url,
                status=status,
                payload=payload,
            )
            self.config.app_event_log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.config.app_event_log_path.open("a", encoding="utf-8") as file:
                file.write(record.model_dump_json(by_alias=True) + "\n")
            self._recent_app_events.append(record)

            if kind == "state":
                self._latest_app_state = record
                self.config.app_state_path.parent.mkdir(parents=True, exist_ok=True)
                self.config.app_state_path.write_text(
                    record.model_dump_json(by_alias=True) + "\n",
                    encoding="utf-8",
                )
            return record

    def _load_app_diagnostics_from_disk(self) -> None:
        latest_state, recent_events = self._read_app_diagnostics_from_disk()
        with self._app_diagnostics_lock:
            for record in recent_events:
                self._recent_app_events.append(record)
                self._app_event_sequence = max(self._app_event_sequence, record.sequence)
                if record.kind == "state":
                    self._latest_app_state = record
            if latest_state is not None:
                self._latest_app_state = latest_state
                self._app_event_sequence = max(self._app_event_sequence, latest_state.sequence)

    def _read_app_diagnostics_from_disk(
        self,
    ) -> tuple[AppDiagnosticRecord | None, list[AppDiagnosticRecord]]:
        latest_state = self._read_app_diagnostic_file(
            self.config.app_state_path,
            fallback_kind="state",
            fallback_event_type="app.state",
            fallback_sequence=0,
        )
        recent_events: list[AppDiagnosticRecord] = []
        if self.config.app_event_log_path.exists():
            try:
                lines = self.config.app_event_log_path.read_text(encoding="utf-8").splitlines()
            except OSError:
                lines = []
            for index, line in enumerate(lines[-100:], start=1):
                record = self._app_diagnostic_record_from_json(
                    line,
                    fallback_kind="event",
                    fallback_event_type="app.event",
                    fallback_sequence=index,
                )
                if record is None:
                    continue
                recent_events.append(record)
                if record.kind == "state":
                    latest_state = record
        return latest_state, recent_events

    def _read_app_diagnostic_file(
        self,
        path: Path,
        *,
        fallback_kind: Literal["state", "event"],
        fallback_event_type: str,
        fallback_sequence: int,
    ) -> AppDiagnosticRecord | None:
        if not path.exists():
            return None
        try:
            return self._app_diagnostic_record_from_json(
                path.read_text(encoding="utf-8"),
                fallback_kind=fallback_kind,
                fallback_event_type=fallback_event_type,
                fallback_sequence=fallback_sequence,
            )
        except OSError:
            return None

    def _app_diagnostic_record_from_json(
        self,
        content: str,
        *,
        fallback_kind: Literal["state", "event"],
        fallback_event_type: str,
        fallback_sequence: int,
    ) -> AppDiagnosticRecord | None:
        if not content.strip():
            return None
        try:
            return AppDiagnosticRecord.model_validate_json(content)
        except ValidationError:
            try:
                payload = json.loads(content)
            except json.JSONDecodeError:
                return None
            return self._coerce_app_diagnostic_record(
                payload,
                fallback_kind=fallback_kind,
                fallback_event_type=fallback_event_type,
                fallback_sequence=fallback_sequence,
            )

    def _coerce_app_diagnostic_record(
        self,
        payload: Any,
        *,
        fallback_kind: Literal["state", "event"],
        fallback_event_type: str,
        fallback_sequence: int,
    ) -> AppDiagnosticRecord | None:
        if not isinstance(payload, dict):
            return None

        kind = payload.get("kind")
        if kind not in {"state", "event"}:
            kind = fallback_kind

        observed_at = _clean_optional_string(
            payload.get("observed_at")
            or payload.get("updated_at")
            or payload.get("timestamp")
            or payload.get("created_at")
        )
        received_at = _clean_optional_string(payload.get("received_at")) or observed_at or _utc_now_iso()
        event_type = _clean_optional_string(
            payload.get("event_type")
            or payload.get("event")
            or payload.get("artifact_type")
            or fallback_event_type
        ) or fallback_event_type
        status = _clean_optional_string(payload.get("status")) or "reported"
        source = _clean_optional_string(payload.get("source")) or "macos_app"
        app_build_id = _clean_optional_string(
            payload.get("app_build_id") or payload.get("appBuildId")
        )
        bridge_url = _clean_optional_string(payload.get("bridge_url") or payload.get("bridgeUrl"))
        sequence = _coerce_positive_int(payload.get("sequence")) or fallback_sequence

        record_payload = payload.get("payload")
        if not isinstance(record_payload, dict):
            record_payload = payload

        return AppDiagnosticRecord(
            sequence=sequence,
            kind=kind,
            event_type=event_type,
            source=source,
            received_at=received_at,
            observed_at=observed_at,
            app_build_id=app_build_id,
            bridge_url=bridge_url,
            status=status,
            payload=record_payload,
        )

    def _merge_app_diagnostic_events(
        self,
        disk_events: list[AppDiagnosticRecord],
        memory_events: list[AppDiagnosticRecord],
    ) -> list[AppDiagnosticRecord]:
        merged: list[AppDiagnosticRecord] = []
        seen: set[tuple[int, str, str, str]] = set()
        for record in [*disk_events, *memory_events]:
            key = (record.sequence, record.kind, record.event_type, record.received_at)
            if key in seen:
                continue
            seen.add(key)
            merged.append(record)
        return merged[-100:]

    def _preview_overlay_for_simulation(
        self,
        *,
        command_id: str,
        simulation: SimulatedPath,
        machine: MachineConfig,
    ) -> PreviewOverlay:
        registration = self._load_latest_paper_registration_or_none()
        binding: VisualPositionBinding | None = None
        if registration is not None:
            binding = self._load_or_create_visual_position_binding(registration=registration)
        overlay = _preview_overlay_from_simulation(
            command_id=command_id,
            simulation=simulation,
            machine=machine,
            registration=registration,
            visual_position_binding_id=binding.binding_id if binding is not None else None,
        )
        if binding is not None and overlay.primitives:
            binding = upsert_expected_geometry(binding, expected_geometry_from_overlay(overlay))
            self._save_visual_position_binding(binding)
        return overlay

    def _run_plan(self, *, plan: ShapeExecutionPlan, transcript_path: Path) -> None:
        self._run_planned_commands(
            command_id=plan.command_id,
            action="draw_shape",
            planned_commands=plan.planned_commands,
            transcript_path=transcript_path,
        )

    def _run_planned_commands(
        self,
        *,
        command_id: str,
        action: str,
        planned_commands: list[PlannedCommand],
        transcript_path: Path,
    ) -> MachineStatusResponse:
        with self._machine_lock:
            self._set_active_command(command_id=command_id, action=action)
            try:
                return self._run_planned_commands_locked(
                    command_id=command_id,
                    action=action,
                    planned_commands=planned_commands,
                    transcript_path=transcript_path,
                )
            finally:
                self._set_active_command(command_id=None, action=None)

    def _run_planned_commands_locked(
        self,
        *,
        command_id: str,
        action: str,
        planned_commands: list[PlannedCommand],
        transcript_path: Path,
    ) -> MachineStatusResponse:
        with self._make_controller(transcript_path=transcript_path) as controller:
            self._set_active_controller(controller)
            try:
                controller.wake_and_drain()
                initial_report = controller.query_status_report(timeout_s=3.0)
                initial_status = self._machine_status_from_report(initial_report, status="guard")
                self._remember_machine_status(initial_status)
                if action in {"adaptive_probe", "relative_move", "relative_mark", "jog"}:
                    validate_projected_workspace_motion(
                        start_mpos_mm=initial_status.mpos_mm,
                        commands=[planned.command for planned in planned_commands],
                        machine=self._load_machine_config(),
                    )
                    self.event_log.emit(
                        "machine.motion_workspace_guard",
                        command_id=command_id,
                        status="accepted",
                        payload={
                            "action": action,
                            "start_mpos_mm": initial_status.mpos_mm,
                            "command_count": len(planned_commands),
                        },
                    )
                current_feed_mm_min: float | None = None
                for planned in planned_commands:
                    self.event_log.emit(
                        "machine.command_started",
                        command_id=command_id,
                        status="running",
                        payload=planned.model_dump(),
                    )
                    if planned.kind == "homing":
                        report = controller.query_status_report()
                        validate_homing_request(
                            state=report.state,
                            pins=report.fields.get("Pn", ""),
                            safety=SafetyState(allow_homing=self.config.arm_homing),
                        )
                        controller.send_validated_command(planned.command, timeout_s=180.0)
                    elif planned.kind == "pen":
                        controller.send_optional_ok_command(planned.command)
                    else:
                        self._guard_motion_limit_pins(controller=controller, command=planned.command)
                        controller.send_validated_command(planned.command)
                        command_feed = _command_feed_mm_min(planned.command)
                        if command_feed is not None:
                            current_feed_mm_min = command_feed
                        self._wait_for_motion_idle(
                            controller=controller,
                            command=planned.command,
                            timeout_s=_motion_idle_timeout_s(
                                planned.command,
                                feed_mm_min=current_feed_mm_min,
                            ),
                        )
                        self._guard_motion_limit_pins(controller=controller, command=planned.command)
                    self.event_log.emit(
                        "machine.command_completed",
                        command_id=command_id,
                        status="completed",
                        payload=planned.model_dump(),
                    )

                final_report = controller.query_status_report()
                final_status = self._machine_status_from_report(final_report, status="ready")
                self._remember_machine_status(final_status)
                self.event_log.emit(
                    "machine.position_sample",
                    command_id=command_id,
                    status=final_report.state,
                    payload={
                        "mpos_mm": final_report.machine_position,
                        "wpos_mm": final_report.work_position,
                        "fields": final_report.fields,
                    },
                )
                controller.flush_transcript()
                return final_status
            finally:
                self._set_active_controller(None)

    def _guard_motion_limit_pins(self, *, controller: GrblHalController, command: str) -> None:
        report = controller.query_status_report()
        status = self._machine_status_from_report(report, status="guard")
        self._remember_machine_status(status)
        pins = report.fields.get("Pn", "")
        if not pins or pins == "-":
            return

        controller.feed_hold()
        raise MotionSafetyError(
            f"Limit/input pin active during motion guard for {command!r}: Pn:{pins}. "
            "Motion stopped."
        )

    def _wait_for_motion_idle(
        self,
        *,
        controller: GrblHalController,
        command: str,
        timeout_s: float = 15.0,
    ) -> None:
        if not _command_can_move(command):
            return

        deadline = time.monotonic() + timeout_s
        last_state = ""
        last_state_root = ""
        while time.monotonic() < deadline:
            report = controller.query_status_report(timeout_s=2.0)
            status = self._machine_status_from_report(report, status="running")
            self._remember_machine_status(status)
            pins = report.fields.get("Pn", "")
            if pins and pins != "-":
                controller.feed_hold()
                raise MotionSafetyError(
                    f"Limit/input pin active while waiting for {command!r}: Pn:{pins}. "
                    "Motion stopped."
                )

            state_root = report.state.split(":", 1)[0]
            last_state = report.state
            last_state_root = state_root
            if state_root == "Alarm":
                raise MotionSafetyError(f"Controller alarm while waiting for {command!r}.")
            if state_root == "Hold":
                raise MotionSafetyError(
                    f"Controller entered Hold while waiting for {command!r}; "
                    "press Resume or Reset before sending more motion."
                )
            if state_root in {"Idle", "Check", "Door"}:
                ready_status = self._machine_status_from_report(report, status="ready")
                self._remember_machine_status(ready_status)
                return
            time.sleep(0.08)

        if last_state_root == "Run":
            controller.feed_hold()
        raise TimeoutError(
            f"Timed out waiting for motion to become idle after {command!r}; "
            f"last_state={last_state or 'unknown'}; timeout_s={timeout_s:.1f}."
        )

    def _run_machine_action(
        self,
        *,
        action: str,
        command_id: str,
        planned_commands: list[PlannedCommand],
        transcript_path: Path,
    ) -> MachineCommandResponse:
        self.event_log.emit(
            "machine.action_started",
            command_id=command_id,
            status="running",
            payload={
                "action": action,
                "dry_run": self.config.dry_run,
                "command_count": len(planned_commands),
            },
        )
        if self.config.dry_run:
            for planned in planned_commands:
                self.event_log.emit(
                    "machine.command_planned",
                    command_id=command_id,
                    status="planned",
                    payload=planned.model_dump(),
                )
            dry_status = self._offline_machine_status(status="dry_run", state="DryRun")
            self._remember_machine_status(dry_status)
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={"action": action, "dry_run": True},
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=True,
                planned_commands=[planned.command for planned in planned_commands],
                event_log=str(self.config.event_log_path),
                machine_status=dry_status,
            )

        try:
            machine_status = self._run_planned_commands(
                command_id=command_id,
                action=action,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
            self.event_log.emit(
                "machine.action_completed",
                command_id=command_id,
                status="completed",
                payload={
                    "action": action,
                    "dry_run": False,
                    "transcript": str(transcript_path),
                    "state": machine_status.state,
                },
            )
            return MachineCommandResponse(
                command_id=command_id,
                action=action,
                status="completed",
                dry_run=False,
                planned_commands=[planned.command for planned in planned_commands],
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path),
                machine_status=machine_status,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=action,
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
                planned_commands=planned_commands,
            )

    def _machine_command_error(
        self,
        *,
        action: str,
        command_id: str,
        transcript_path: Path,
        error: str,
        planned_commands: list[PlannedCommand] | None = None,
    ) -> MachineCommandResponse:
        self.event_log.emit(
            "machine.action_failed",
            command_id=command_id,
            status="failed",
            payload={"action": action, "error": error},
        )
        machine_status = self._machine_error_status(error=error)
        self._remember_machine_status(machine_status)
        return MachineCommandResponse(
            command_id=command_id,
            action=action,
            status="failed",
            dry_run=self.config.dry_run,
            planned_commands=[planned.command for planned in planned_commands or []],
            event_log=str(self.config.event_log_path),
            controller_transcript=str(transcript_path) if transcript_path.exists() else None,
            machine_status=machine_status,
            error=error,
        )

    def _center_planned_commands(
        self,
        *,
        machine: MachineConfig,
        safety: SafetyState,
        feed_mm_min: float,
    ) -> list[PlannedCommand]:
        self._validate_travel_feed(feed_mm_min=feed_mm_min, machine=machine, safety=safety)
        center_x, center_y = machine.logical_center_mm()
        validate_workspace_point(x_mm=center_x, y_mm=center_y, machine=machine)
        machine_x, machine_y = machine.logical_to_machine(x_mm=center_x, y_mm=center_y)

        commands = [
            PlannedCommand(command="G21", kind="motion", description="Use millimeter units"),
            PlannedCommand(command="G90", kind="motion", description="Use absolute positioning"),
            PlannedCommand(command="G94", kind="motion", description="Use feed per minute"),
        ]

        if machine.pen.up_command is not None:
            pen_up = validate_pen_trial_command(machine.pen.up_command, safety)
            commands.append(PlannedCommand(command=pen_up, kind="pen", description="Raise pen"))

        commands.extend(
            [
                PlannedCommand(
                    command=f"G1 F{format_mm(feed_mm_min)}",
                    kind="motion",
                    description="Set travel feed",
                ),
                PlannedCommand(
                    command=f"G53 G1 X{format_mm(machine_x)} Y{format_mm(machine_y)}",
                    kind="motion",
                    description="Move to logical workspace center",
                ),
            ]
        )
        return commands

    def _pen_machine(self, *, position: str, request: MachinePenRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"pen-{position}-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            machine = self._load_machine_config()
            safety = SafetyState(
                dry_run=self.config.dry_run,
                allow_pen_actuation=self.config.arm_pen,
            )
            configured = machine.pen.up_command if position == "up" else machine.pen.down_command
            if configured is None:
                raise MotionSafetyError(f"Machine config must contain pen.{position}_command.")
            command = validate_pen_trial_command(configured, safety)
            planned_commands = [
                PlannedCommand(
                    command=command,
                    kind="pen",
                    description="Raise pen" if position == "up" else "Lower pen",
                )
            ]
            if machine.pen.settle_s > 0:
                planned_commands.append(
                    PlannedCommand(
                        command=f"G4 P{format_mm(machine.pen.settle_s)}",
                        kind="motion",
                        description=(
                            "Wait for pen lift" if position == "up" else "Wait for pen drop"
                        ),
                    )
                )
            return self._run_machine_action(
                action=f"pen_{position}",
                command_id=command_id,
                planned_commands=planned_commands,
                transcript_path=transcript_path,
            )
        except Exception as exc:
            return self._machine_command_error(
                action=f"pen_{position}",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def _validate_travel_feed(
        self,
        *,
        feed_mm_min: float,
        machine: MachineConfig,
        safety: SafetyState,
    ) -> None:
        if feed_mm_min <= 0:
            raise MotionSafetyError("feed_mm_min must be positive.")
        if feed_mm_min > machine.max_feed_mm_min:
            raise MotionSafetyError(
                f"feed_mm_min {feed_mm_min} mm/min exceeds "
                f"max_feed_mm_min {machine.max_feed_mm_min}."
            )
        if not safety.dry_run and not safety.armed_motion:
            raise MotionSafetyError("Real motion requires armed_motion=true.")

    def _safety_state(self) -> SafetyState:
        return SafetyState(
            dry_run=self.config.dry_run,
            armed_motion=self.config.arm_motion,
            allow_pen_actuation=self.config.arm_pen,
            allow_homing=self.config.arm_homing,
        )

    def _make_controller(self, *, transcript_path: Path) -> GrblHalController:
        if self.config.mock:
            return GrblHalController(
                MockTransport(),
                source="controller_bridge",
                transcript_path=transcript_path,
            )
        if self.config.controller_port is None:
            raise ValueError("Provide controller_port or enable mock mode for live bridge runs.")
        controller_port = self._resolve_controller_port()
        return GrblHalController(
            SerialTransport(port=controller_port, baud=self.config.baud),
            source="controller_bridge",
            transcript_path=transcript_path,
        )

    def _configure_controller_port(
        self,
        *,
        controller_port: str | None,
        auto_connect: bool,
    ) -> None:
        if self.config.mock:
            return
        if controller_port:
            self.config.controller_port = controller_port
            return
        if self.config.controller_port is None and auto_connect:
            self.config.controller_port = self._auto_detect_controller_port()

    def _auto_detect_controller_port(self) -> str:
        candidates = _candidate_serial_ports()
        if len(candidates) == 1:
            return candidates[0]
        if not candidates:
            raise ValueError("No USB serial controller is currently visible.")
        raise ValueError(
            "Multiple USB serial controllers are visible; choose one explicitly: "
            + ", ".join(candidates)
        )

    def _resolve_controller_port(self) -> str:
        configured = self.config.controller_port
        if configured is None:
            raise ValueError("Provide controller_port or enable mock mode for live bridge runs.")

        if Path(configured).exists():
            return configured

        candidates = _candidate_serial_ports()
        if len(candidates) == 1:
            resolved = candidates[0]
            self.config.controller_port = resolved
            return resolved

        if not candidates:
            raise ValueError(
                f"Configured controller port is missing: {configured}. "
                "No USB serial controller is currently visible."
            )

        raise ValueError(
            f"Configured controller port is missing: {configured}. "
            f"Multiple USB serial controllers are visible: {', '.join(candidates)}."
        )

    def _load_machine_config(self) -> MachineConfig:
        if self.config.config_path.exists():
            machine = MachineConfig.model_validate_json(
                self.config.config_path.read_text(encoding="utf-8")
            )
        else:
            machine = MachineConfig()

        if self.config.workspace_x_max is not None:
            machine.set_axis_travel(
                x_travel_mm=abs(self.config.workspace_x_max),
                y_travel_mm=machine.axes.y.travel_mm,
            )
        if self.config.workspace_y_max is not None:
            machine.set_axis_travel(
                x_travel_mm=machine.axes.x.travel_mm,
                y_travel_mm=abs(self.config.workspace_y_max),
            )
        return machine

    def _mark_machine_homing_trusted(self, machine: MachineConfig) -> None:
        machine.homing_trusted = True
        machine.save_json(self.config.config_path)

    def _validate_axis_model_trust_request(
        self,
        *,
        request: AxisModelTrustRequest,
        machine: MachineConfig,
    ) -> None:
        if request.source != "green_cap_visual_probe":
            raise MotionSafetyError("Axis model trust requires source=green_cap_visual_probe.")
        if request.sample_count < 4 or len(request.samples) < 4:
            raise MotionSafetyError("Axis model trust requires at least four visual jog samples.")
        max_visual_probe_mm = max(machine.max_jog_mm, 200.0)
        if request.command_distance_mm < 10.0 or request.command_distance_mm > max_visual_probe_mm:
            raise MotionSafetyError(
                "Visual readiness requires command distance from 10mm to "
                f"{max_visual_probe_mm:g}mm."
            )
        if request.min_observed_distance_mm < 8.0:
            raise MotionSafetyError("Axis model trust requires at least 8mm observed cap displacement.")
        if request.rms_residual_mm > 6.0:
            raise MotionSafetyError("Axis model trust residual RMS exceeds 6mm.")
        if request.max_residual_mm > 10.0:
            raise MotionSafetyError("Axis model trust max residual exceeds 10mm.")
        axes = {sample.axis.upper() for sample in request.samples}
        if not {"X", "Y"}.issubset(axes):
            raise MotionSafetyError("Axis model trust requires both X and Y visual samples.")
        for sample in request.samples:
            if abs(sample.commanded_distance_mm) < 10.0:
                raise MotionSafetyError("Axis model trust sample command distance is too small.")
            if sample.observed_distance_mm < 8.0:
                raise MotionSafetyError("Axis model trust sample observed displacement is too small.")

    def _require_axis_model_trusted(self, machine: MachineConfig) -> None:
        if self.config.dry_run or machine.axis_model_trusted or self._visual_ready_to_plot():
            return
        raise MotionSafetyError(
            "Real drawing requires axis_model_trusted=true or a validated current "
            "VisualPositionBinding. Cap-only visual readiness is relative evidence and "
            "cannot unlock absolute drawing."
        )

    def _latest_machine_model_path(self) -> Path:
        return self.config.calibration_dir / "latest_machine_model.json"

    def _paper_registration_path(self, registration_id: str) -> Path:
        if "/" in registration_id or ".." in registration_id:
            raise ValueError("Invalid paper registration_id.")
        return self.config.calibration_dir / "paper" / f"{registration_id}.json"

    def _latest_paper_registration_path(self) -> Path:
        return self.config.calibration_dir / "latest_paper_registration.json"

    def _save_paper_registration(self, registration: PaperFrameRegistration) -> None:
        registration.save_json(self._paper_registration_path(registration.registration_id))
        registration.save_json(self._latest_paper_registration_path())

    def _load_latest_paper_registration(self) -> PaperFrameRegistration:
        path = self._latest_paper_registration_path()
        if not path.exists():
            raise ValueError("No paper registration has been saved.")
        return PaperFrameRegistration.model_validate_json(path.read_text(encoding="utf-8"))

    def _load_latest_paper_registration_or_none(self) -> PaperFrameRegistration | None:
        try:
            return self._load_latest_paper_registration()
        except Exception:
            return None

    def _visual_position_binding_path(self, binding_id: str) -> Path:
        if "/" in binding_id or ".." in binding_id:
            raise ValueError("Invalid visual position binding_id.")
        return self.config.calibration_dir / "visual_position_bindings" / f"{binding_id}.json"

    def _latest_visual_position_binding_path(self) -> Path:
        return self.config.calibration_dir / "latest_visual_position_binding.json"

    def _save_visual_position_binding(self, binding: VisualPositionBinding) -> None:
        binding.save_json(self._visual_position_binding_path(binding.binding_id))
        binding.save_json(self._latest_visual_position_binding_path())

    def _load_latest_visual_position_binding(self) -> VisualPositionBinding:
        path = self._latest_visual_position_binding_path()
        if not path.exists():
            raise ValueError("No visual position binding has been saved.")
        return VisualPositionBinding.load_json(path)

    def _load_latest_visual_position_binding_or_none(self) -> VisualPositionBinding | None:
        try:
            return self._load_latest_visual_position_binding()
        except Exception:
            return None

    def _load_or_create_visual_position_binding(
        self,
        *,
        registration: PaperFrameRegistration,
    ) -> VisualPositionBinding:
        existing = self._load_latest_visual_position_binding_or_none()
        if existing is not None and existing.paper_registration_id == registration.registration_id:
            return existing

        machine = self._load_machine_config()
        readiness = self._load_latest_visual_readiness_or_none()
        cap_observations = []
        if readiness is not None and readiness.latest_cap_observation is not None:
            cap_observations.append(readiness.latest_cap_observation)
        safe_zone = (
            readiness.safe_zone
            if readiness is not None and readiness.safe_zone is not None
            else self._drawing_safe_zone(machine=machine, inset_x_mm=10.0, inset_y_mm=10.0)
        )
        binding = create_visual_position_binding(
            paper_registration_id=registration.registration_id,
            camera_id=registration.camera_id,
            camera_name=registration.camera_name,
            drawing_frame=DrawingFrameMM(
                origin_x_mm=machine.workspace.x_min,
                origin_y_mm=machine.workspace.y_min,
                width_mm=machine.workspace.x_max - machine.workspace.x_min,
                height_mm=machine.workspace.y_max - machine.workspace.y_min,
            ),
            safe_zone=safe_zone,
            cap_observations=cap_observations,
        )
        self._save_visual_position_binding(binding)
        return binding

    def _visual_position_binding_response(
        self,
        binding: VisualPositionBinding,
        *,
        observation_id: str | None = None,
    ) -> VisualPositionBindingResponse:
        status = "ready" if binding.validated else binding.validation_status
        return VisualPositionBindingResponse(
            status=status,
            dry_run=self.config.dry_run,
            binding=binding,
            binding_file=str(self._latest_visual_position_binding_path()),
            observation_id=observation_id,
        )

    def _visual_probe_run_path(self, run_id: str) -> Path:
        if "/" in run_id or ".." in run_id:
            raise ValueError("Invalid visual probe run_id.")
        return self.config.calibration_dir / "visual_probe_runs" / f"{run_id}.json"

    def _latest_visual_probe_run_path(self) -> Path:
        return self.config.calibration_dir / "latest_visual_probe_run.json"

    def _load_visual_probe_run_or_new(self, run_id: str) -> VisualProbeRun:
        path = self._visual_probe_run_path(run_id)
        if path.exists():
            return VisualProbeRun.load_json(path)
        return VisualProbeRun(run_id=run_id)

    def _load_latest_visual_probe_run_or_none(self) -> VisualProbeRun | None:
        path = self._latest_visual_probe_run_path()
        if not path.exists():
            return None
        return VisualProbeRun.load_json(path)

    def _save_visual_probe_run(self, run: VisualProbeRun) -> None:
        run.save_json(self._visual_probe_run_path(run.run_id))
        run.save_json(self._latest_visual_probe_run_path())

    def _latest_visual_readiness_path(self) -> Path:
        return self.config.calibration_dir / "latest_visual_readiness.json"

    def _save_visual_readiness(self, state: VisualReadinessState) -> None:
        state.save_json(self._latest_visual_readiness_path())

    def _load_latest_visual_readiness(self) -> VisualReadinessState:
        path = self._latest_visual_readiness_path()
        if not path.exists():
            raise ValueError("No visual readiness artifact has been saved.")
        return VisualReadinessState.load_json(path)

    def _load_latest_visual_readiness_or_none(self) -> VisualReadinessState | None:
        try:
            return self._load_latest_visual_readiness()
        except Exception:
            return None

    def _visual_ready_to_plot(self) -> bool:
        try:
            registration = self._load_latest_paper_registration()
            binding = self._load_latest_visual_position_binding()
            return binding.is_valid_for(
                paper_registration_id=registration.registration_id,
                camera_id=registration.camera_id,
            )
        except Exception:
            return False

    def _visual_readiness_status_fields(self) -> tuple[bool, list[str]]:
        try:
            registration = self._load_latest_paper_registration()
            binding = self._load_latest_visual_position_binding()
            ready = binding.is_valid_for(
                paper_registration_id=registration.registration_id,
                camera_id=registration.camera_id,
            )
            return (ready, list(binding.blockers))
        except Exception:
            return (False, [])

    def _visual_readiness_response(self, state: VisualReadinessState) -> VisualReadinessResponse:
        return VisualReadinessResponse(
            status="ready" if state.visual_ready_to_plot else "blocked",
            dry_run=self.config.dry_run,
            readiness=state.model_dump(mode="json"),
            readiness_file=str(self._latest_visual_readiness_path()),
        )

    def _visual_state_with_latest_probe_evidence(
        self,
        state: VisualReadinessState,
    ) -> VisualReadinessState:
        run = self._load_latest_visual_probe_run_or_none()
        if run is None:
            return state
        registration = self._load_latest_paper_registration_or_none()
        run.summary = summarize_visual_probe_samples(
            run.samples,
            current_paper_registration_id=(
                registration.registration_id if registration is not None else state.paper_registration_id
            ),
            current_camera_id=registration.camera_id if registration is not None else None,
        )
        return self._visual_state_from_probe_run(
            cap=state.latest_cap_observation,
            safe_zone_evaluation=state.zone_check or state.safe_zone_evaluation,
            previous=state,
            run=run,
        )

    def _visual_state_from_probe_run(
        self,
        *,
        cap: VisualCapObservation | None,
        safe_zone_evaluation: Any | None,
        previous: VisualReadinessState | None,
        run: VisualProbeRun,
    ) -> VisualReadinessState:
        summary = run.summary
        return self._visual_state_from_evidence(
            cap=cap,
            safe_zone_evaluation=safe_zone_evaluation,
            previous=previous,
            sample_count=summary.accepted_sample_count,
            raw_sample_count=summary.raw_sample_count,
            rejected_sample_count=summary.rejected_sample_count,
            stale_sample_count=summary.stale_sample_count,
            axes_represented=summary.axes_represented,
            adaptive_sample_count=summary.adaptive_sample_count,
            center_target_sample_count=summary.center_target_sample_count,
            x_field_recovery_sample_count=summary.x_field_recovery_sample_count,
            rms_residual_mm=summary.rms_residual_mm,
            p95_residual_mm=summary.p95_residual_mm,
            max_residual_mm=summary.max_residual_mm,
            latest_probe_run_id=run.run_id,
            latest_probe_sample_id=summary.latest_sample_id,
            latest_probe_run_file=str(self._visual_probe_run_path(run.run_id)),
            extra_probe_blockers=summary.blockers,
        )

    def _visual_cap_observation(
        self,
        *,
        request: VisualCapObservationRequest,
        machine: MachineConfig,
        registration: PaperFrameRegistration,
    ) -> VisualCapObservation:
        raw_paper = (
            request.observed_paper_norm
            if request.observed_paper_norm is not None
            else registration.camera_norm_to_paper_norm(request.observed_norm)
        )
        paper_norm = PaperPointNorm(
            x=_clamp(raw_paper.x, 0.0, 1.0),
            y=_clamp(raw_paper.y, 0.0, 1.0),
        )
        logical_mm = request.observed_logical_mm or LogicalPointMM(
            x=machine.workspace.x_min
            + raw_paper.x * (machine.workspace.x_max - machine.workspace.x_min),
            y=machine.workspace.y_min
            + raw_paper.y * (machine.workspace.y_max - machine.workspace.y_min),
        )
        return VisualCapObservation(
            source=request.source,
            camera_norm=request.observed_norm,
            paper_norm=paper_norm,
            logical_mm=logical_mm,
            confidence=request.confidence,
            camera_id=request.camera_id or registration.camera_id,
            camera_name=request.camera_name or registration.camera_name,
            paper_registration_id=registration.registration_id,
        )

    def _drawing_safe_zone(
        self,
        *,
        machine: MachineConfig,
        inset_x_mm: float,
        inset_y_mm: float,
    ) -> DrawingSafeZone:
        return DrawingSafeZone.from_frame(
            drawing_frame=DrawingFrameMM(
                origin_x_mm=machine.workspace.x_min,
                origin_y_mm=machine.workspace.y_min,
                width_mm=machine.workspace.x_max - machine.workspace.x_min,
                height_mm=machine.workspace.y_max - machine.workspace.y_min,
            ),
            margins_mm=SafeZoneMarginsMM(
                left=inset_x_mm,
                right=inset_x_mm,
                bottom=inset_y_mm,
                top=inset_y_mm,
            ),
        )

    def _visual_state_from_evidence(
        self,
        *,
        cap: VisualCapObservation | None,
        safe_zone_evaluation: Any | None,
        previous: VisualReadinessState | None,
        sample_count: int | None = None,
        raw_sample_count: int | None = None,
        rejected_sample_count: int | None = None,
        stale_sample_count: int | None = None,
        axes_represented: list[Literal["X", "Y"]] | None = None,
        adaptive_sample_count: int | None = None,
        center_target_sample_count: int | None = None,
        x_field_recovery_sample_count: int | None = None,
        rms_residual_mm: float | None = None,
        p95_residual_mm: float | None = None,
        max_residual_mm: float | None = None,
        latest_probe_run_id: str | None = None,
        latest_probe_sample_id: str | None = None,
        latest_probe_run_file: str | None = None,
        extra_probe_blockers: list[str] | None = None,
    ) -> VisualReadinessState:
        state = build_visual_readiness_state(
            paper_registered=cap is not None or bool(previous and previous.paper_registered),
            cap_observation=cap,
            safe_zone_evaluation=safe_zone_evaluation,
            probe_observation_count=(
                sample_count
                if sample_count is not None
                else (previous.probe_observation_count if previous is not None else 0)
            ),
            probe_raw_sample_count=(
                raw_sample_count
                if raw_sample_count is not None
                else (previous.probe_raw_sample_count if previous is not None else None)
            ),
            probe_rejected_sample_count=(
                rejected_sample_count
                if rejected_sample_count is not None
                else (previous.probe_rejected_sample_count if previous is not None else 0)
            ),
            probe_stale_sample_count=(
                stale_sample_count
                if stale_sample_count is not None
                else (previous.probe_stale_sample_count if previous is not None else 0)
            ),
            probe_axes_represented=(
                axes_represented if axes_represented is not None else None
            ),
            probe_adaptive_sample_count=(
                adaptive_sample_count
                if adaptive_sample_count is not None
                else (previous.probe_adaptive_sample_count if previous is not None else 0)
            ),
            probe_center_target_sample_count=(
                center_target_sample_count
                if center_target_sample_count is not None
                else (previous.probe_center_target_sample_count if previous is not None else 0)
            ),
            probe_x_field_recovery_sample_count=(
                x_field_recovery_sample_count
                if x_field_recovery_sample_count is not None
                else (previous.probe_x_field_recovery_sample_count if previous is not None else 0)
            ),
            probe_rms_residual_mm=(
                rms_residual_mm
                if rms_residual_mm is not None
                else (previous.probe_rms_residual_mm if previous is not None else None)
            ),
            probe_p95_residual_mm=(
                p95_residual_mm
                if p95_residual_mm is not None
                else (previous.probe_p95_residual_mm if previous is not None else None)
            ),
            probe_max_residual_mm=(
                max_residual_mm
                if max_residual_mm is not None
                else (previous.probe_max_residual_mm if previous is not None else None)
            ),
            latest_visual_probe_run_id=(
                latest_probe_run_id
                if latest_probe_run_id is not None
                else (previous.latest_visual_probe_run_id if previous is not None else None)
            ),
            latest_visual_probe_sample_id=(
                latest_probe_sample_id
                if latest_probe_sample_id is not None
                else (previous.latest_visual_probe_sample_id if previous is not None else None)
            ),
            latest_visual_probe_run_file=(
                latest_probe_run_file
                if latest_probe_run_file is not None
                else (previous.latest_visual_probe_run_file if previous is not None else None)
            ),
        )
        if previous is not None:
            state.state_id = previous.state_id
            state.paper_registration_id = previous.paper_registration_id
            if axes_represented is None:
                state.probe_axes_represented = previous.probe_axes_represented
        if cap is not None and cap.paper_registration_id is not None:
            state.paper_registration_id = cap.paper_registration_id
        if extra_probe_blockers:
            for blocker in extra_probe_blockers:
                if blocker not in state.blockers:
                    state.blockers.append(blocker)
            state.visual_ready_to_plot = False
        return state

    def _machine_status_from_report(
        self,
        report: StatusReport,
        *,
        status: str,
    ) -> MachineStatusResponse:
        machine = self._load_machine_config()
        visual_ready, visual_blockers = self._visual_readiness_status_fields()
        state_root = report.state.split(":", 1)[0]
        pins = report.fields.get("Pn", "")
        is_alarm = state_root == "Alarm" or report.state.lower().startswith("alarm")
        is_busy = state_root not in {"Idle", "Alarm", "Door", "Check"}
        return MachineStatusResponse(
            status=status,
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            state=report.state,
            homing_trusted=machine.homing_trusted,
            axis_model_trusted=machine.axis_model_trusted,
            visual_ready_to_plot=visual_ready,
            visual_readiness_blockers=visual_blockers,
            mpos_mm=report.machine_position,
            wpos_mm=report.work_position,
            pins=pins,
            feed_spindle=report.feed_spindle,
            fields=report.fields,
            is_busy=is_busy,
            is_alarm=is_alarm,
        )

    def _offline_machine_status(
        self,
        *,
        status: str,
        state: str,
        error: str | None = None,
    ) -> MachineStatusResponse:
        visual_ready, visual_blockers = self._visual_readiness_status_fields()
        return MachineStatusResponse(
            status=status,
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            state=state,
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
            visual_ready_to_plot=visual_ready,
            visual_readiness_blockers=visual_blockers,
            pins="",
            is_busy=False,
            is_alarm=status == "failed" or state.lower().startswith("alarm"),
            error=error,
        )

    def _busy_machine_status(self) -> MachineStatusResponse:
        with self._state_lock:
            active_command_id = self._active_command_id
            active_action = self._active_action
            last_status = self._last_machine_status

        if last_status is not None:
            return last_status.model_copy(
                update={
                    "status": "busy",
                    "is_busy": True,
                    "active_command_id": active_command_id,
                    "active_action": active_action,
                }
            )

        visual_ready, visual_blockers = self._visual_readiness_status_fields()
        return MachineStatusResponse(
            status="busy",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            state="Run",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
            visual_ready_to_plot=visual_ready,
            visual_readiness_blockers=visual_blockers,
            mpos_mm=last_status.mpos_mm if last_status else None,
            wpos_mm=last_status.wpos_mm if last_status else None,
            pins=last_status.pins if last_status else "",
            feed_spindle=last_status.feed_spindle if last_status else None,
            fields=last_status.fields if last_status else {},
            is_busy=True,
            is_alarm=False,
            active_command_id=active_command_id,
            active_action=active_action,
        )

    def _locked_machine_status(self) -> MachineStatusResponse:
        with self._state_lock:
            active_command_id = self._active_command_id
            active_action = self._active_action
            last_status = self._last_machine_status

        if active_command_id is not None:
            return self._busy_machine_status()

        if last_status is not None:
            return last_status.model_copy(
                update={
                    "active_command_id": active_command_id,
                    "active_action": active_action,
                }
            )

        visual_ready, visual_blockers = self._visual_readiness_status_fields()
        return MachineStatusResponse(
            status="sampling",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            state="Unknown",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
            visual_ready_to_plot=visual_ready,
            visual_readiness_blockers=visual_blockers,
            is_busy=False,
            is_alarm=False,
            active_command_id=active_command_id,
            active_action=active_action,
        )

    def _hold_machine_status(self) -> MachineStatusResponse:
        with self._state_lock:
            active_command_id = self._active_command_id
            active_action = self._active_action
            last_status = self._last_machine_status

        visual_ready, visual_blockers = self._visual_readiness_status_fields()
        return MachineStatusResponse(
            status="stopping",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            arm_motion=self.config.arm_motion,
            arm_pen=self.config.arm_pen,
            arm_homing=self.config.arm_homing,
            arm_unlock=self.config.arm_unlock,
            state="Hold",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
            visual_ready_to_plot=visual_ready,
            visual_readiness_blockers=visual_blockers,
            mpos_mm=last_status.mpos_mm if last_status else None,
            wpos_mm=last_status.wpos_mm if last_status else None,
            pins=last_status.pins if last_status else "",
            feed_spindle=last_status.feed_spindle if last_status else None,
            fields=last_status.fields if last_status else {},
            is_busy=True,
            is_alarm=False,
            active_command_id=active_command_id,
            active_action=active_action,
        )

    def _active_machine_status(self) -> MachineStatusResponse | None:
        with self._state_lock:
            if self._active_command_id is None:
                return None
        return self._busy_machine_status()

    def _remember_machine_status(self, status: MachineStatusResponse) -> None:
        with self._state_lock:
            self._last_machine_status = status

    def _machine_error_status(self, *, error: str) -> MachineStatusResponse:
        with self._state_lock:
            active_command_id = self._active_command_id
            active_action = self._active_action
            last_status = self._last_machine_status

        if last_status is not None:
            return last_status.model_copy(
                update={
                    "status": "failed",
                    "error": error,
                    "active_command_id": active_command_id,
                    "active_action": active_action,
                }
            )

        return self._offline_machine_status(status="failed", state="Error", error=error)

    def _set_active_command(self, *, command_id: str | None, action: str | None) -> None:
        with self._state_lock:
            self._active_command_id = command_id
            self._active_action = action

    def _set_active_controller(self, controller: GrblHalController | None) -> None:
        with self._state_lock:
            self._active_controller = controller

    def _get_active_controller(self) -> GrblHalController | None:
        with self._state_lock:
            return self._active_controller

    def _paper_registration_response(
        self,
        registration: PaperFrameRegistration,
    ) -> PaperRegistrationResponse:
        return PaperRegistrationResponse(
            status=registration.status,
            dry_run=self.config.dry_run,
            registration=registration.model_dump(mode="json"),
            registration_file=str(self._latest_paper_registration_path()),
        )

    def _response(
        self,
        *,
        plan: ShapeExecutionPlan,
        status: str,
        transcript_path: Path | None,
        preview_overlay: PreviewOverlay | None = None,
    ) -> ShapeExecutionResponse:
        return ShapeExecutionResponse(
            command_id=plan.command_id,
            status=status,
            dry_run=plan.dry_run,
            pattern=plan.pattern,
            planned_commands=plan.command_strings,
            simulation=plan.simulation,
            evaluation=plan.evaluation,
            preview_overlay=preview_overlay,
            event_log=str(self.config.event_log_path),
            controller_transcript=str(transcript_path) if transcript_path else None,
        )

    def _draw_program_response(
        self,
        *,
        plan: PolygonDrawPlan,
        machine_response: MachineCommandResponse,
        preview_overlay: PreviewOverlay | None = None,
    ) -> PolygonDrawResponse:
        return PolygonDrawResponse(
            command_id=plan.command_id,
            status=machine_response.status,
            dry_run=plan.dry_run,
            planned_commands=plan.command_strings,
            simulation=plan.simulation,
            summary=plan.summary,
            preview_overlay=preview_overlay,
            event_log=str(self.config.event_log_path),
            controller_transcript=machine_response.controller_transcript,
            machine_status=machine_response.machine_status,
            error=machine_response.error,
        )

    def _controller_description(self) -> str:
        if self.config.mock:
            return "mock"
        if self.config.controller_port is None:
            return "unconfigured"
        suffix = "" if Path(self.config.controller_port).exists() else " (missing)"
        return f"serial:{self.config.controller_port}@{self.config.baud}{suffix}"

    def _lifecycle_mode(self) -> BridgeLifecycleMode:
        if not self.config.dry_run:
            return "live"
        if self.config.mock:
            return "mock_preview"
        return "hardware_standby"

    def _lifecycle_label(self, mode: BridgeLifecycleMode) -> str:
        labels: dict[BridgeLifecycleMode, str] = {
            "mock_preview": "Preview Bridge",
            "hardware_standby": "Hardware Standby",
            "live": "Live Bridge",
        }
        return labels[mode]

    def _can_restart_safely(self) -> bool:
        with self._state_lock:
            active_command_id = self._active_command_id
        return self.config.dry_run and active_command_id is None


def serve_bridge(config: BridgeRuntimeConfig) -> None:
    bridge = PlotterBridge(config)
    bridge.event_log.emit(
        "bridge.ready",
        status="ready",
        payload={"dry_run": config.dry_run, "controller": bridge.health().controller},
    )
    server = LocalThreadingHTTPServer((config.host, config.http_port), _make_handler(bridge))
    print(f"Plotter bridge listening on http://{config.host}:{config.http_port}", flush=True)
    print(f"Controller mode: {bridge.health().controller}; dry_run={config.dry_run}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


class LocalThreadingHTTPServer(ThreadingHTTPServer):
    def server_bind(self) -> None:
        TCPServer.server_bind(self)
        self.server_name = str(self.server_address[0])
        self.server_port = int(self.server_address[1])


@dataclass(frozen=True)
class PostRoute:
    request_model: type[BaseModel]
    handler: Callable[[Any], BaseModel]
    succeeds: Callable[[BaseModel], bool]


def _clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def _binding_mark_points(
    *,
    registration: PaperFrameRegistration,
    point_set: BindingMarkPointSet,
    margin_mm: float,
) -> list[tuple[str, PaperPointMM]]:
    width = registration.paper_size_mm.width
    height = registration.paper_size_mm.height
    if margin_mm < 0:
        raise ValueError("Binding mark margin_mm must be non-negative.")
    if margin_mm * 2 >= width or margin_mm * 2 >= height:
        raise ValueError("Binding mark margin_mm leaves no drawable paper area.")
    if point_set != "five":
        raise ValueError("Binding mark preview supports only the five-point set.")

    center = PaperPointMM(x=width / 2.0, y=height / 2.0)
    left = margin_mm
    right = width - margin_mm
    bottom = margin_mm
    top = height - margin_mm
    points = [
        center,
        PaperPointMM(x=left, y=bottom),
        PaperPointMM(x=right, y=bottom),
        PaperPointMM(x=right, y=top),
        PaperPointMM(x=left, y=top),
    ]

    return [(f"P{index:02d}", point) for index, point in enumerate(points, start=1)]


def _binding_mark_polylines(
    *,
    points: list[tuple[str, PaperPointMM]],
    mark_size_mm: float,
) -> tuple[list[PlannedPolyline], list[str]]:
    if mark_size_mm <= 0:
        raise ValueError("Binding mark_size_mm must be positive.")

    half = mark_size_mm / 2.0
    polylines: list[PlannedPolyline] = []
    segment_point_ids: list[str] = []
    for point_id, point in points:
        horizontal = PlannedPolyline(
            role="outline",
            points=[
                LogicalPointMM(x=point.x - half, y=point.y),
                LogicalPointMM(x=point.x + half, y=point.y),
            ],
        )
        vertical = PlannedPolyline(
            role="outline",
            points=[
                LogicalPointMM(x=point.x, y=point.y - half),
                LogicalPointMM(x=point.x, y=point.y + half),
            ],
        )
        polylines.extend([horizontal, vertical])
        segment_point_ids.extend([point_id, point_id])

    return polylines, segment_point_ids


def _binding_mark_expected_geometry(
    *,
    command_id: str,
    points: list[BindingMarkPreviewPoint],
) -> list[ExpectedGeometrySample]:
    return [
        ExpectedGeometrySample(
            command_id=command_id,
            point_id=point.point_id,
            segment_index=index,
            role="segment_midpoint",
            expected_paper_mm=point.paper_mm,
            expected_camera_norm=point.camera_norm,
        )
        for index, point in enumerate(points)
    ]


def _relative_cross_mark_commands(
    *,
    request: MachineRelativeMarkRequest,
    machine: MachineConfig,
    safety: SafetyState,
) -> list[PlannedCommand]:
    mark_size_mm = request.mark_size_mm
    if not math.isfinite(mark_size_mm) or mark_size_mm <= 0:
        raise MotionSafetyError("Relative mark size must be positive and finite.")
    if mark_size_mm > min(machine.max_jog_mm, 20.0):
        raise MotionSafetyError(
            f"Relative mark size {mark_size_mm:.3f} mm exceeds limit "
            f"{min(machine.max_jog_mm, 20.0):.3f}."
        )
    for label, feed_mm_min in [
        ("draw_feed_mm_min", request.draw_feed_mm_min),
        ("travel_feed_mm_min", request.travel_feed_mm_min),
    ]:
        if feed_mm_min <= 0:
            raise MotionSafetyError(f"{label} must be positive.")
        if feed_mm_min > machine.max_feed_mm_min:
            raise MotionSafetyError(
                f"{label} {feed_mm_min} mm/min exceeds max_feed_mm_min "
                f"{machine.max_feed_mm_min}."
            )
    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real relative mark motion requires armed_motion=true.")
    if machine.pen.down_command is None or machine.pen.up_command is None:
        raise MotionSafetyError("Relative mark requires configured pen down and pen up commands.")

    pen_down = validate_pen_trial_command(machine.pen.down_command, safety)
    pen_up = validate_pen_trial_command(machine.pen.up_command, safety)
    half = mark_size_mm / 2.0
    validate_relative_xy_move_request(
        x_mm=mark_size_mm,
        y_mm=0,
        feed_mm_min=request.draw_feed_mm_min,
        machine=machine,
        safety=safety,
    )
    validate_relative_xy_move_request(
        x_mm=0,
        y_mm=mark_size_mm,
        feed_mm_min=request.draw_feed_mm_min,
        machine=machine,
        safety=safety,
    )
    validate_relative_xy_move_request(
        x_mm=-half,
        y_mm=-half,
        feed_mm_min=request.travel_feed_mm_min,
        machine=machine,
        safety=safety,
    )

    commands: list[PlannedCommand] = [
        PlannedCommand(command="G21", kind="motion", description="Use millimeter units"),
        PlannedCommand(command="G91", kind="motion", description="Use relative positioning"),
        PlannedCommand(command="G94", kind="motion", description="Use feed per minute"),
        PlannedCommand(command=pen_up, kind="pen", description="Raise pen before relative mark"),
    ]
    if machine.pen.settle_s > 0:
        commands.append(
            PlannedCommand(
                command=f"G4 P{format_mm(machine.pen.settle_s)}",
                kind="motion",
                description="Wait for pen lift",
            )
        )

    def add_motion(command: str, description: str, *, draw: bool = False) -> None:
        commands.append(
            PlannedCommand(
                command=f"G1 F{format_mm(request.draw_feed_mm_min if draw else request.travel_feed_mm_min)}",
                kind="motion",
                description="Set draw feed" if draw else "Set travel feed",
            )
        )
        commands.append(PlannedCommand(command=command, kind="motion", description=description))

    def add_pen(command: str, description: str) -> None:
        commands.append(PlannedCommand(command=command, kind="pen", description=description))
        if machine.pen.settle_s > 0:
            commands.append(
                PlannedCommand(
                    command=f"G4 P{format_mm(machine.pen.settle_s)}",
                    kind="motion",
                    description="Wait for pen",
                )
            )

    add_motion(f"G1 X{format_mm(-half)}", "Travel to relative mark left edge")
    add_pen(pen_down, "Lower pen for horizontal mark")
    add_motion(f"G1 X{format_mm(mark_size_mm)}", "Draw horizontal relative mark", draw=True)
    add_pen(pen_up, "Raise pen after horizontal mark")
    add_motion(
        f"G1 X{format_mm(-half)} Y{format_mm(-half)}",
        "Travel to relative mark bottom edge",
    )
    add_pen(pen_down, "Lower pen for vertical mark")
    add_motion(f"G1 Y{format_mm(mark_size_mm)}", "Draw vertical relative mark", draw=True)
    add_pen(pen_up, "Raise pen after vertical mark")
    add_motion(f"G1 Y{format_mm(-half)}", "Return to relative mark center")
    commands.append(PlannedCommand(command="G90", kind="motion", description="Restore absolute mode"))
    return commands


def _validate_binding_mark_simulation(
    *,
    plan: PolygonDrawPlan,
    segment_point_ids: list[str],
) -> None:
    if plan.simulation.status != "ok":
        raise MotionSafetyError(
            "Binding mark simulation failed: " + "; ".join(plan.simulation.errors)
        )
    if len(plan.simulation.drawn_segments) != len(segment_point_ids):
        raise MotionSafetyError(
            "Binding mark simulation did not preserve one segment per planned mark leg."
        )


def _project_drawn_segment_to_camera(
    *,
    segment: DrawnSegment,
    point_id: str,
    machine: MachineConfig,
    registration: PaperFrameRegistration,
) -> BindingMarkPreviewSegment:
    start_paper = PaperPointMM(
        x=machine.axes.x.machine_to_logical(segment.start.x),
        y=machine.axes.y.machine_to_logical(segment.start.y),
    )
    end_paper = PaperPointMM(
        x=machine.axes.x.machine_to_logical(segment.end.x),
        y=machine.axes.y.machine_to_logical(segment.end.y),
    )
    return BindingMarkPreviewSegment(
        point_id=point_id,
        start_paper_mm=start_paper,
        end_paper_mm=end_paper,
        start_norm=_project_paper_mm_to_camera_norm(
            paper_mm=start_paper,
            registration=registration,
        ),
        end_norm=_project_paper_mm_to_camera_norm(
            paper_mm=end_paper,
            registration=registration,
        ),
        length_mm=segment.length_mm,
    )


def _preview_overlay_from_simulation(
    *,
    command_id: str,
    simulation: SimulatedPath,
    machine: MachineConfig,
    registration: PaperFrameRegistration | None,
    visual_position_binding_id: str | None = None,
) -> PreviewOverlay:
    primitives: list[PreviewOverlayPrimitive] = []
    for index, segment in enumerate(simulation.drawn_segments):
        start_paper = _machine_point_to_paper_mm(point=segment.start, machine=machine)
        end_paper = _machine_point_to_paper_mm(point=segment.end, machine=machine)
        start_camera: CameraPointNorm | None = None
        end_camera: CameraPointNorm | None = None
        if registration is not None:
            start_camera = _project_paper_mm_to_camera_norm(
                paper_mm=start_paper,
                registration=registration,
            )
            end_camera = _project_paper_mm_to_camera_norm(
                paper_mm=end_paper,
                registration=registration,
            )
        primitives.append(
            PreviewOverlayPrimitive(
                primitive_id=f"{command_id}-seg-{index:04d}",
                command_id=command_id,
                segment_index=index,
                start_paper_mm=start_paper,
                end_paper_mm=end_paper,
                start_camera_norm=start_camera,
                end_camera_norm=end_camera,
                length_mm=segment.length_mm,
            )
        )
    return PreviewOverlay(
        command_id=command_id,
        coordinate_space="camera_norm" if registration is not None else "paper_mm",
        projected=registration is not None,
        paper_registration_id=registration.registration_id if registration is not None else None,
        visual_position_binding_id=visual_position_binding_id,
        primitives=primitives,
    )


def _machine_point_to_paper_mm(*, point: Any, machine: MachineConfig) -> PaperPointMM:
    return PaperPointMM(
        x=machine.axes.x.machine_to_logical(point.x),
        y=machine.axes.y.machine_to_logical(point.y),
    )


def _project_paper_mm_to_camera_norm(
    *,
    paper_mm: PaperPointMM,
    registration: PaperFrameRegistration,
) -> CameraPointNorm:
    width = registration.paper_size_mm.width
    height = registration.paper_size_mm.height
    if width <= 0 or height <= 0:
        raise ValueError("Paper registration has invalid dimensions.")
    x_norm = paper_mm.x / width
    y_norm = paper_mm.y / height
    _validate_projected_paper_norm(x_norm=x_norm, y_norm=y_norm)
    x_camera, y_camera = registration.paper_to_camera.map_xy(x_norm, y_norm)
    return CameraPointNorm(x=x_camera, y=y_camera)


def _validate_projected_paper_norm(*, x_norm: float, y_norm: float) -> None:
    tolerance = 1e-9
    if x_norm < -tolerance or x_norm > 1.0 + tolerance:
        raise ValueError(f"Projected paper X {x_norm:.4f} is outside [0, 1].")
    if y_norm < -tolerance or y_norm > 1.0 + tolerance:
        raise ValueError(f"Projected paper Y {y_norm:.4f} is outside [0, 1].")


def _zero_near(value: float) -> float:
    return 0.0 if abs(value) <= 1e-9 else value


def _planned_command_hash(commands: list[str]) -> str:
    digest = hashlib.sha256("\n".join(commands).encode("utf-8")).hexdigest()
    return digest[:16]


def _command_can_move(command: str) -> bool:
    normalized = command.split(";", 1)[0].strip().upper()
    words = normalized.split()
    if not any(word in {"G0", "G00", "G1", "G01"} for word in words):
        return False
    return any(word.startswith(("X", "Y")) for word in words)


def _command_feed_mm_min(command: str) -> float | None:
    normalized = command.split(";", 1)[0].strip().upper()
    for word in normalized.split():
        if not word.startswith("F"):
            continue
        try:
            value = float(word[1:])
        except ValueError:
            return None
        if value > 0:
            return value
    return None


def _motion_idle_timeout_s(command: str, *, feed_mm_min: float | None) -> float:
    if not _command_can_move(command):
        return 0.0

    distance_mm = _command_xy_distance_mm(command)
    if distance_mm <= 0 or feed_mm_min is None or feed_mm_min <= 0:
        return 45.0

    expected_s = distance_mm / feed_mm_min * 60.0
    return max(15.0, min(180.0, expected_s * 2.0 + 8.0))


def _command_xy_distance_mm(command: str) -> float:
    normalized = command.split(";", 1)[0].strip().upper()
    x = 0.0
    y = 0.0
    for word in normalized.split():
        if word.startswith("X"):
            x = _axis_word_value(word)
        elif word.startswith("Y"):
            y = _axis_word_value(word)
    return math.hypot(x, y)


def _axis_word_value(word: str) -> float:
    try:
        return float(word[1:])
    except ValueError:
        return 0.0


def _candidate_serial_ports() -> list[str]:
    candidates: list[str] = []
    tokens = (
        "usbserial",
        "usbmodem",
        "wchusbserial",
        "slab_usb",
        "cp210",
        "ch340",
        "ftdi",
        "uart",
    )
    for port in list_serial_ports():
        haystack = f"{port.device} {port.description} {port.hwid}".lower()
        if any(token in haystack for token in tokens):
            candidates.append(port.device)
    return sorted(set(candidates))


def _make_handler(bridge: PlotterBridge) -> type[BaseHTTPRequestHandler]:
    post_routes = {
        "/draw/shape/preview": PostRoute(
            ShapeExecutionRequest,
            bridge.preview_shape,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/draw/shape": PostRoute(
            ShapeExecutionRequest,
            bridge.draw_shape,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/draw/program/preview": PostRoute(
            PolygonDrawRequest,
            bridge.preview_draw_program,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/draw/program": PostRoute(
            PolygonDrawRequest,
            bridge.draw_program,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/draw/image/preview": PostRoute(
            ImageShapePreviewRequest,
            bridge.preview_image_contours,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/draw/portrait/preview": PostRoute(
            PortraitContourPreviewRequest,
            bridge.preview_portrait_contours,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/draw/face": PostRoute(
            FaceRasterDrawRequest,
            bridge.draw_face_raster,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/capabilities/tests/preview": PostRoute(
            CapabilityTestRequest,
            bridge.preview_capability_test,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/capabilities/tests/run": PostRoute(
            CapabilityTestRequest,
            bridge.run_capability_test,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/arm": PostRoute(
            MachineArmRequest,
            bridge.arm_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/codex/app/state": PostRoute(
            AppDiagnosticStateRequest,
            bridge.record_app_state,
            lambda response: getattr(response, "status", "") == "accepted",
        ),
        "/codex/app/events": PostRoute(
            AppDiagnosticEventRequest,
            bridge.record_app_event,
            lambda response: getattr(response, "status", "") == "accepted",
        ),
        "/machine/jog": PostRoute(
            MachineJogRequest,
            bridge.jog_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/axis-model/trust": PostRoute(
            AxisModelTrustRequest,
            bridge.trust_axis_model,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/relative-move": PostRoute(
            MachineRelativeMoveRequest,
            bridge.relative_move_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/relative-mark": PostRoute(
            MachineRelativeMarkRequest,
            bridge.relative_mark_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/reconnect": PostRoute(
            MachineReconnectRequest,
            bridge.reconnect_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/home": PostRoute(
            MachineHomeRequest,
            bridge.home_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/center": PostRoute(
            MachineCenterRequest,
            bridge.center_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/pen-up": PostRoute(
            MachinePenRequest,
            bridge.pen_up_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/pen-down": PostRoute(
            MachinePenRequest,
            bridge.pen_down_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/dot-mark": PostRoute(
            MachineDotMarkRequest,
            bridge.dot_mark_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/stop": PostRoute(
            MachineStopRequest,
            bridge.stop_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/resume": PostRoute(
            MachineResumeRequest,
            bridge.resume_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/machine/unlock": PostRoute(
            MachineUnlockRequest,
            bridge.unlock_machine,
            lambda response: getattr(response, "status", "") == "completed",
        ),
        "/calibration/pen/observe": PostRoute(
            VisualCapObservationRequest,
            bridge.observe_visual_cap,
            lambda response: getattr(response, "status", "") != "failed",
        ),
        "/calibration/binding/preview": PostRoute(
            BindingMarkPreviewRequest,
            bridge.preview_binding_marks,
            lambda response: getattr(response, "status", "") == "ready",
        ),
        "/calibration/binding/observe": PostRoute(
            VisualBindingObservationRequest,
            bridge.add_visual_binding_observation,
            lambda response: getattr(response, "status", "") in {"ready", "validated", "collecting", "blocked"},
        ),
        "/calibration/binding/solve": PostRoute(
            VisualBindingSolveRequest,
            bridge.solve_visual_binding,
            lambda response: getattr(response, "status", "") in {"ready", "validated", "collecting", "blocked"},
        ),
        "/calibration/probe/observe": PostRoute(
            VisualProbeSampleObservationRequest,
            bridge.observe_visual_probe_sample,
            lambda response: getattr(response, "status", "") in {"accepted", "rejected", "blocked"},
        ),
        "/paper/register": PostRoute(
            PaperRegistrationRequest,
            bridge.register_paper,
            lambda response: getattr(response, "status", "") != "failed",
        ),
    }

    class PlotterBridgeHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            parsed_url = urlparse(self.path)
            if parsed_url.path == "/health":
                self._write_model(HTTPStatus.OK, bridge.health())
                return
            if parsed_url.path == "/events":
                self._write_json(
                    HTTPStatus.OK,
                    {
                        "events": [
                            event.model_dump(mode="json", by_alias=True)
                            for event in bridge.recent_events()
                        ]
                    },
                )
                return
            if parsed_url.path == "/codex/snapshot":
                self._write_model(HTTPStatus.OK, bridge.codex_snapshot())
                return
            if parsed_url.path == "/codex/app/state":
                self._write_model(HTTPStatus.OK, bridge.app_diagnostics_snapshot())
                return
            if parsed_url.path == "/codex/app/events":
                self._write_model(HTTPStatus.OK, bridge.app_diagnostics_snapshot())
                return
            if parsed_url.path == "/machine/status":
                self._write_model(HTTPStatus.OK, bridge.machine_status())
                return
            if parsed_url.path == "/calibration/workflow/status":
                self._write_model(HTTPStatus.OK, bridge.visual_readiness_status())
                return
            if parsed_url.path == "/calibration/binding/status":
                self._write_model(HTTPStatus.OK, bridge.visual_position_binding_status())
                return
            if parsed_url.path == "/paper/status":
                response = bridge.paper_registration_status()
                self._write_model(HTTPStatus.OK, response)
                return
            self._write_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:
            parsed_url = urlparse(self.path)
            route = post_routes.get(parsed_url.path)
            if route is not None:
                self._handle_post(route)
                return
            self._write_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        def log_message(self, format: str, *args: object) -> None:
            print(f"bridge {self.address_string()} {format % args}", flush=True)

        def _read_json_body(self) -> dict[str, Any]:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
            payload = json.loads(body.decode("utf-8") or "{}")
            if not isinstance(payload, dict):
                raise ValueError("JSON body must be an object.")
            return payload

        def _write_model(self, status: HTTPStatus, model: BaseModel) -> None:
            self._write_json(status, model.model_dump(mode="json", by_alias=True))

        def _handle_post(self, route: PostRoute) -> None:
            try:
                request = route.request_model.model_validate(self._read_json_body())
            except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                return

            response = route.handler(request)
            status = HTTPStatus.OK if route.succeeds(response) else HTTPStatus.BAD_REQUEST
            self._write_model(status, response)

        def _write_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(status.value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    return PlotterBridgeHandler
