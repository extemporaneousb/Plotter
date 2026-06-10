from __future__ import annotations

import hashlib
import json
import math
import time
import uuid
from collections import deque
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from threading import Lock
from typing import Any, Literal
from urllib.parse import parse_qs, urlparse

from pydantic import BaseModel, Field, ValidationError

from plotter_vision.calibration.paper import (
    PaperCorner,
    PaperCornerObservation,
    PaperFiducialDetection,
    PaperFrameRegistration,
    PaperPointMM,
    paper_corner_norm,
    build_paper_frame_registration,
    build_paper_registration_from_red_fiducials,
)
from plotter_vision.calibration.session import CalibrationSession, build_calibration_session
from plotter_vision.calibration.synthetic import synthetic_observations
from plotter_vision.calibration.vision_model import (
    CameraPointNorm,
    LogicalPointMM,
    MachinePointMM,
    VisionCalibrationObservation,
)
from plotter_vision.bridge.planner import (
    DemoPlan,
    DemoRunRequest,
    PlannedCommand,
    PolygonDrawPlan,
    PolygonDrawPlanSummary,
    PolygonDrawRequest,
    build_demo_plan,
    build_polygon_draw_plan,
)
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.mock import MockTransport
from plotter_vision.controller.parser import StatusReport
from plotter_vision.controller.serial_transport import DEFAULT_BAUD, SerialTransport, list_serial_ports
from plotter_vision.drawing import (
    DrawingFrameMM,
    LuminanceRaster,
    PlannedPolyline,
    RasterPolygonOptions,
    RasterPolygonSummary,
    build_paper_program_from_luminance_raster,
)
from plotter_vision.machine.homing import validate_homing_request
from plotter_vision.machine.pen import validate_pen_trial_command
from plotter_vision.machine.safety import (
    MotionSafetyError,
    validate_jog_request,
    validate_relative_xy_move_request,
    validate_workspace_point,
)
from plotter_vision.motion.gcode import (
    build_relative_jog_commands,
    build_relative_xy_move_commands,
    format_mm,
)
from plotter_vision.motion.simulator import (
    DemoShapeEvaluation,
    DrawnSegment,
    SimulatedPath,
    simulate_plotter_commands,
)

DotTestPattern = Literal["center", "five", "nine"]


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
    schema_version: int = Field(default=1, serialization_alias="schema", validation_alias="schema")
    dry_run: bool
    controller: str
    event_log: str
    workspace_x_mm: float | None = None
    workspace_y_mm: float | None = None


class DemoRunResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    pattern: str
    planned_commands: list[str]
    simulation: SimulatedPath | None = None
    evaluation: DemoShapeEvaluation | None = None
    event_log: str
    controller_transcript: str | None = None
    error: str | None = None


class CalibrationStartRequest(BaseModel):
    margin_mm: float = 25.0
    travel_feed_mm_min: float = 500.0
    include_homing: bool = True
    simulate_observations: bool = False
    synthetic_noise_norm: float = 0.0


class CalibrationObservationRequest(BaseModel):
    session_id: str
    point_id: str
    observed_norm: CameraPointNorm
    reported_machine_mm: MachinePointMM | None = None
    strength: float = 1.0


class PaperRegistrationCornerRequest(BaseModel):
    corner: PaperCorner
    observed_norm: CameraPointNorm
    strength: float = 1.0


class PaperRegistrationRequest(BaseModel):
    paper_width_mm: float | None = None
    paper_height_mm: float | None = None
    corners: list[PaperRegistrationCornerRequest] = Field(default_factory=list)
    detections: list[PaperFiducialDetection] = Field(default_factory=list)


class CalibrationSessionResponse(BaseModel):
    session_id: str
    status: str
    dry_run: bool
    planned_commands: list[str]
    waypoints: list[dict[str, Any]]
    observed_count: int
    model: dict[str, Any]
    session_file: str
    error: str | None = None


class PaperRegistrationResponse(BaseModel):
    status: str
    dry_run: bool
    registration: dict[str, Any] | None = None
    registration_file: str = ""
    error: str | None = None


class DotTestPreviewRequest(BaseModel):
    pattern: DotTestPattern = "center"
    margin_mm: float = 25.0
    mark_size_mm: float = 4.0
    include_homing: bool = False
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    park_after: bool = True
    park_offset_mm: float = 50.0
    request_id: str | None = None


class DotTestRunRequest(DotTestPreviewRequest):
    expected_plan_hash: str | None = None


class DotTestPreviewPoint(BaseModel):
    point_id: str
    paper_mm: PaperPointMM
    camera_norm: CameraPointNorm


class DotTestPreviewSegment(BaseModel):
    point_id: str
    start_paper_mm: PaperPointMM
    end_paper_mm: PaperPointMM
    start_norm: CameraPointNorm
    end_norm: CameraPointNorm
    length_mm: float


class DotTestPreviewResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    preview_only: bool = True
    registration_id: str = ""
    pattern: DotTestPattern = "center"
    point_count: int = 0
    mark_size_mm: float = 0.0
    plan_hash: str = ""
    planned_commands: list[str] = Field(default_factory=list)
    simulation: SimulatedPath | None = None
    points: list[DotTestPreviewPoint] = Field(default_factory=list)
    camera_segments: list[DotTestPreviewSegment] = Field(default_factory=list)
    event_log: str
    error: str | None = None


@dataclass(frozen=True)
class DotTestPlanBundle:
    machine: MachineConfig
    registration: PaperFrameRegistration
    plan: PolygonDrawPlan
    points: list[tuple[str, PaperPointMM]]
    camera_points: list[DotTestPreviewPoint]
    camera_segments: list[DotTestPreviewSegment]
    plan_hash: str


class MachineStatusResponse(BaseModel):
    status: str
    dry_run: bool
    controller: str
    state: str
    homing_trusted: bool = False
    axis_model_trusted: bool = False
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


class PolygonDrawResponse(BaseModel):
    command_id: str
    status: str
    dry_run: bool
    planned_commands: list[str]
    simulation: SimulatedPath | None = None
    summary: PolygonDrawPlanSummary | None = None
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


class MachineJogRequest(BaseModel):
    axis: str
    distance_mm: float
    feed_mm_min: float = 500.0
    request_id: str | None = None


class MachineRelativeMoveRequest(BaseModel):
    x_mm: float = 0.0
    y_mm: float = 0.0
    feed_mm_min: float = 300.0
    ensure_pen_up: bool = True
    request_id: str | None = None


class MachineRelativeMarkRequest(BaseModel):
    mark_size_mm: float = 6.0
    draw_feed_mm_min: float = 120.0
    travel_feed_mm_min: float = 300.0
    request_id: str | None = None


class MachineHomeRequest(BaseModel):
    center_after: bool = True
    center_feed_mm_min: float = 500.0
    request_id: str | None = None


class MachineCenterRequest(BaseModel):
    feed_mm_min: float = 500.0
    request_id: str | None = None


class MachinePenRequest(BaseModel):
    request_id: str | None = None


class MachineDotMarkRequest(BaseModel):
    request_id: str | None = None


class MachineStopRequest(BaseModel):
    request_id: str | None = None


class MachineReconnectRequest(BaseModel):
    request_id: str | None = None


class MachineResumeRequest(BaseModel):
    request_id: str | None = None


class MachineUnlockRequest(BaseModel):
    request_id: str | None = None


class AxisModelTrustSample(BaseModel):
    axis: str
    commanded_distance_mm: float
    observed_dx_mm: float
    observed_dy_mm: float
    observed_distance_mm: float


class AxisModelTrustRequest(BaseModel):
    source: str = "green_cap_visual_probe"
    sample_count: int
    rms_residual_mm: float
    max_residual_mm: float
    min_observed_distance_mm: float
    command_distance_mm: float
    samples: list[AxisModelTrustSample] = Field(default_factory=list)
    request_id: str | None = None


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
        self._machine_lock = Lock()
        self._state_lock = Lock()
        self._active_command_id: str | None = None
        self._active_action: str | None = None
        self._active_controller: GrblHalController | None = None
        self._last_machine_status: MachineStatusResponse | None = None

    def health(self) -> BridgeHealthResponse:
        machine = self._load_machine_config()
        return BridgeHealthResponse(
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            event_log=str(self.config.event_log_path),
            workspace_x_mm=machine.axes.x.travel_mm,
            workspace_y_mm=machine.axes.y.travel_mm,
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

    def run_demo(self, request: DemoRunRequest) -> DemoRunResponse:
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
            plan = build_demo_plan(
                request=request,
                machine=machine,
                safety=safety,
                command_id=command_id,
            )
            if plan.evaluation.status != "passed":
                raise MotionSafetyError(
                    f"Demo preview failed geometry gate: {plan.evaluation.message}"
                )
            self.event_log.emit(
                "demo.started",
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
                    "demo.completed",
                    command_id=command_id,
                    status="completed",
                    payload={"dry_run": True},
                )
                return self._response(plan=plan, status="completed", transcript_path=None)

            self._run_plan(plan=plan, transcript_path=transcript_path)
            self.event_log.emit(
                "demo.completed",
                command_id=command_id,
                status="completed",
                payload={"dry_run": False, "transcript": str(transcript_path)},
            )
            return self._response(plan=plan, status="completed", transcript_path=transcript_path)
        except Exception as exc:
            self.event_log.emit(
                "demo.failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return DemoRunResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                pattern=request.pattern,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                evaluation=locals().get("plan").evaluation if "plan" in locals() else None,
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path) if transcript_path.exists() else None,
                error=str(exc),
            )

    def preview_demo(self, request: DemoRunRequest) -> DemoRunResponse:
        command_id = request.request_id or f"preview-{uuid.uuid4().hex[:12]}"

        try:
            machine = self._load_machine_config()
            plan = build_demo_plan(
                request=request,
                machine=machine,
                safety=SafetyState(dry_run=True),
                command_id=command_id,
            )
            if plan.evaluation.status != "passed":
                raise MotionSafetyError(
                    f"Demo preview failed geometry gate: {plan.evaluation.message}"
                )
            self.event_log.emit(
                "demo.preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "pattern": request.pattern,
                    "command_count": len(plan.planned_commands),
                    "preview_status": plan.evaluation.status,
                },
            )
            return self._response(plan=plan, status="ready", transcript_path=None)
        except Exception as exc:
            self.event_log.emit(
                "demo.preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return DemoRunResponse(
                command_id=command_id,
                status="failed",
                dry_run=True,
                pattern=request.pattern,
                planned_commands=[],
                simulation=locals().get("plan").simulation if "plan" in locals() else None,
                evaluation=locals().get("plan").evaluation if "plan" in locals() else None,
                event_log=str(self.config.event_log_path),
                controller_transcript=None,
                error=str(exc),
            )

    def draw_polygon(self, request: PolygonDrawRequest) -> PolygonDrawResponse:
        command_id = request.request_id or f"draw-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"

        try:
            machine = self._load_machine_config()
            self._require_axis_model_trusted(machine)
            plan = build_polygon_draw_plan(
                request=request,
                machine=machine,
                safety=self._safety_state(),
                command_id=command_id,
            )
            self.event_log.emit(
                "draw.polygon_started",
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
                action="draw_polygon",
                command_id=command_id,
                planned_commands=plan.planned_commands,
                transcript_path=transcript_path,
            )
            if machine_response.status == "completed":
                self.event_log.emit(
                    "draw.polygon_completed",
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
                    "draw.polygon_failed",
                    command_id=command_id,
                    status="failed",
                    payload={"error": machine_response.error},
                )
            return self._polygon_draw_response(
                plan=plan,
                machine_response=machine_response,
            )
        except Exception as exc:
            self.event_log.emit(
                "draw.polygon_failed",
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
                event_log=str(self.config.event_log_path),
                controller_transcript=str(transcript_path) if transcript_path.exists() else None,
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
            polygon_response = self.draw_polygon(
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

    def start_calibration(self, request: CalibrationStartRequest) -> CalibrationSessionResponse:
        try:
            machine = self._load_machine_config()
            session = build_calibration_session(
                machine=machine,
                margin_mm=request.margin_mm,
                travel_feed_mm_min=request.travel_feed_mm_min,
                include_homing=request.include_homing,
            )
            if request.simulate_observations:
                observations = synthetic_observations(
                    machine=machine,
                    logical_points=[waypoint.logical_mm for waypoint in session.waypoints],
                    command_id=session.session_id,
                    noise_norm=request.synthetic_noise_norm,
                )
                for observation in observations:
                    session.add_observation(observation)

            self._save_calibration_session(session)
            self.event_log.emit(
                "calibration.session_started",
                command_id=session.session_id,
                status=session.status,
                payload={
                    "point_count": len(session.waypoints),
                    "simulate_observations": request.simulate_observations,
                    "dry_run": self.config.dry_run,
                },
            )
            return self._calibration_response(session)
        except Exception as exc:
            session_id = f"cal-{uuid.uuid4().hex[:12]}"
            self.event_log.emit(
                "calibration.session_failed",
                command_id=session_id,
                status="failed",
                payload={"error": str(exc)},
            )
            return CalibrationSessionResponse(
                session_id=session_id,
                status="failed",
                dry_run=self.config.dry_run,
                planned_commands=[],
                waypoints=[],
                observed_count=0,
                model={},
                session_file="",
                error=str(exc),
            )

    def add_calibration_observation(
        self,
        request: CalibrationObservationRequest,
    ) -> CalibrationSessionResponse:
        try:
            session = self._load_calibration_session(request.session_id)
            waypoint = next(
                waypoint for waypoint in session.waypoints if waypoint.point_id == request.point_id
            )
            observation = VisionCalibrationObservation(
                command_id=session.session_id,
                point_id=waypoint.point_id,
                role=waypoint.role,
                expected_logical_mm=waypoint.logical_mm,
                commanded_machine_mm=waypoint.machine_mm,
                reported_machine_mm=request.reported_machine_mm,
                observed_norm=request.observed_norm,
                strength=request.strength,
            )
            session.add_observation(observation)
            self._save_calibration_session(session)
            self.event_log.emit(
                "calibration.observation_added",
                command_id=session.session_id,
                status=session.status,
                payload={
                    "point_id": waypoint.point_id,
                    "observed_count": session.observed_count,
                },
            )
            return self._calibration_response(session)
        except StopIteration:
            return self._calibration_error(
                session_id=request.session_id,
                error=f"Unknown calibration point_id {request.point_id!r}.",
            )
        except Exception as exc:
            return self._calibration_error(session_id=request.session_id, error=str(exc))

    def calibration_status(self, session_id: str) -> CalibrationSessionResponse:
        try:
            return self._calibration_response(self._load_calibration_session(session_id))
        except Exception as exc:
            return self._calibration_error(session_id=session_id, error=str(exc))

    def register_paper(self, request: PaperRegistrationRequest) -> PaperRegistrationResponse:
        try:
            machine = self._load_machine_config()
            paper_width_mm = request.paper_width_mm or machine.axes.x.travel_mm
            paper_height_mm = request.paper_height_mm or machine.axes.y.travel_mm
            if request.corners:
                corner_observations = [
                    PaperCornerObservation(
                        corner=corner.corner,
                        expected_paper_norm=paper_corner_norm(corner.corner),
                        observed_norm=corner.observed_norm,
                        strength=corner.strength,
                    )
                    for corner in request.corners
                ]
                registration = build_paper_frame_registration(
                    corner_observations,
                    paper_width_mm=paper_width_mm,
                    paper_height_mm=paper_height_mm,
                )
            elif request.detections:
                registration = build_paper_registration_from_red_fiducials(
                    request.detections,
                    paper_width_mm=paper_width_mm,
                    paper_height_mm=paper_height_mm,
                )
            else:
                raise ValueError("Provide four paper corner observations or red fiducial detections.")

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

    def preview_dot_test(self, request: DotTestPreviewRequest) -> DotTestPreviewResponse:
        command_id = request.request_id or f"dot-preview-{uuid.uuid4().hex[:12]}"
        try:
            dot_plan = self._build_dot_test_plan(
                request=request,
                command_id=command_id,
                safety=SafetyState(dry_run=True),
            )
            response = DotTestPreviewResponse(
                command_id=command_id,
                status="ready",
                dry_run=self.config.dry_run,
                registration_id=dot_plan.registration.registration_id,
                pattern=request.pattern,
                point_count=len(dot_plan.points),
                mark_size_mm=request.mark_size_mm,
                plan_hash=dot_plan.plan_hash,
                planned_commands=dot_plan.plan.command_strings,
                simulation=dot_plan.plan.simulation,
                points=dot_plan.camera_points,
                camera_segments=dot_plan.camera_segments,
                event_log=str(self.config.event_log_path),
            )
            self.event_log.emit(
                "dot_test.preview_ready",
                command_id=command_id,
                status="ready",
                payload={
                    "registration_id": dot_plan.registration.registration_id,
                    "pattern": request.pattern,
                    "point_count": len(dot_plan.points),
                    "camera_segment_count": len(dot_plan.camera_segments),
                    "plan_hash": dot_plan.plan_hash,
                    "preview_only": True,
                },
            )
            return response
        except Exception as exc:
            self.event_log.emit(
                "dot_test.preview_failed",
                command_id=command_id,
                status="failed",
                payload={"error": str(exc), "preview_only": True},
            )
            return DotTestPreviewResponse(
                command_id=command_id,
                status="failed",
                dry_run=self.config.dry_run,
                pattern=request.pattern,
                event_log=str(self.config.event_log_path),
                error=str(exc),
            )

    def run_dot_test(self, request: DotTestRunRequest) -> MachineCommandResponse:
        command_id = request.request_id or f"dot-run-{uuid.uuid4().hex[:12]}"
        transcript_path = self.config.transcript_dir / f"{command_id}.jsonl"
        try:
            if request.pattern != "center":
                raise MotionSafetyError("Real dot-test motion currently supports only center pattern.")

            dot_plan = self._build_dot_test_plan(
                request=request,
                command_id=command_id,
                safety=self._safety_state(),
            )
            self._require_axis_model_trusted(dot_plan.machine)
            if request.expected_plan_hash and request.expected_plan_hash != dot_plan.plan_hash:
                raise MotionSafetyError(
                    "Dot-test plan changed after preview; preview the center dot again before motion."
                )

            response = self._run_machine_action(
                action="dot_test_center",
                command_id=command_id,
                planned_commands=dot_plan.plan.planned_commands,
                transcript_path=transcript_path,
            )
            self.event_log.emit(
                "dot_test.run_completed" if response.status == "completed" else "dot_test.run_failed",
                command_id=command_id,
                status=response.status,
                payload={
                    "registration_id": dot_plan.registration.registration_id,
                    "pattern": request.pattern,
                    "point_count": len(dot_plan.points),
                    "plan_hash": dot_plan.plan_hash,
                    "dry_run": response.dry_run,
                    "error": response.error,
                },
            )
            return response
        except Exception as exc:
            return self._machine_command_error(
                action="dot_test_center",
                command_id=command_id,
                transcript_path=transcript_path,
                error=str(exc),
            )

    def _build_dot_test_plan(
        self,
        *,
        request: DotTestPreviewRequest,
        command_id: str,
        safety: SafetyState,
    ) -> DotTestPlanBundle:
        machine = self._load_machine_config()
        registration = self._load_latest_paper_registration()
        points = _dot_test_points(
            registration=registration,
            pattern=request.pattern,
            margin_mm=request.margin_mm,
        )
        polylines, segment_point_ids = _dot_test_polylines(
            points=points,
            mark_size_mm=request.mark_size_mm,
        )
        plan = build_polygon_draw_plan(
            request=PolygonDrawRequest(
                polylines=polylines,
                include_homing=request.include_homing,
                draw_feed_mm_min=request.draw_feed_mm_min,
                travel_feed_mm_min=request.travel_feed_mm_min,
                max_segment_mm=request.max_segment_mm,
                request_id=command_id,
            ),
            machine=machine,
            safety=safety,
            command_id=command_id,
        )
        if request.park_after:
            _append_dot_test_park_commands(
                plan=plan,
                machine=machine,
                point=points[0][1],
                travel_feed_mm_min=request.travel_feed_mm_min,
                park_offset_mm=request.park_offset_mm,
            )
        _validate_dot_test_simulation(plan=plan, segment_point_ids=segment_point_ids)

        camera_points = [
            DotTestPreviewPoint(
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
        return DotTestPlanBundle(
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
            self.event_log.emit(
                "machine.axis_model_probe_rejected",
                command_id=command_id,
                status="failed",
                payload={
                    "source": request.source,
                    "sample_count": request.sample_count,
                    "rms_residual_mm": request.rms_residual_mm,
                    "max_residual_mm": request.max_residual_mm,
                    "min_observed_distance_mm": request.min_observed_distance_mm,
                    "command_distance_mm": request.command_distance_mm,
                    "axis_model_trusted": machine.axis_model_trusted,
                },
            )
            raise MotionSafetyError(
                "Green-cap visual probing measures relative motion only; it cannot set "
                "axis_model_trusted or unlock absolute drawing. Use homing or a visual "
                "position binding before real dot/drawing motion."
            )
        except Exception as exc:
            return self._machine_command_error(
                action="axis_model_trust",
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

    def _run_plan(self, *, plan: DemoPlan, transcript_path: Path) -> None:
        self._run_planned_commands(
            command_id=plan.command_id,
            action="demo",
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
                    planned_commands=planned_commands,
                    transcript_path=transcript_path,
                )
            finally:
                self._set_active_command(command_id=None, action=None)

    def _run_planned_commands_locked(
        self,
        *,
        command_id: str,
        planned_commands: list[PlannedCommand],
        transcript_path: Path,
    ) -> MachineStatusResponse:
        with self._make_controller(transcript_path=transcript_path) as controller:
            self._set_active_controller(controller)
            try:
                controller.wake_and_drain()
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
        if request.command_distance_mm < 10.0 or request.command_distance_mm > machine.max_jog_mm:
            raise MotionSafetyError(
                f"Axis model trust requires command distance from 10mm to {machine.max_jog_mm:g}mm."
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
        if self.config.dry_run or machine.axis_model_trusted:
            return
        raise MotionSafetyError(
            "Real drawing requires axis_model_trusted=true for machine geometry. "
            "A green-cap visual probe is only relative motion evidence and is not sufficient."
        )

    def _calibration_path(self, session_id: str) -> Path:
        if "/" in session_id or ".." in session_id:
            raise ValueError("Invalid calibration session_id.")
        return self.config.calibration_dir / f"{session_id}.json"

    def _save_calibration_session(self, session: CalibrationSession) -> None:
        session.save_json(self._calibration_path(session.session_id))
        if session.status == "solved":
            latest = self.config.calibration_dir / "latest_machine_model.json"
            session.model.save_json(latest)

    def _load_calibration_session(self, session_id: str) -> CalibrationSession:
        path = self._calibration_path(session_id)
        if not path.exists():
            raise ValueError(f"Calibration session not found: {session_id}")
        return CalibrationSession.model_validate_json(path.read_text(encoding="utf-8"))

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

    def _machine_status_from_report(
        self,
        report: StatusReport,
        *,
        status: str,
    ) -> MachineStatusResponse:
        machine = self._load_machine_config()
        state_root = report.state.split(":", 1)[0]
        pins = report.fields.get("Pn", "")
        is_alarm = state_root == "Alarm" or report.state.lower().startswith("alarm")
        is_busy = state_root not in {"Idle", "Alarm", "Door", "Check"}
        return MachineStatusResponse(
            status=status,
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            state=report.state,
            homing_trusted=machine.homing_trusted,
            axis_model_trusted=machine.axis_model_trusted,
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
        return MachineStatusResponse(
            status=status,
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            state=state,
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
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

        return MachineStatusResponse(
            status="busy",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            state="Run",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
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

        return MachineStatusResponse(
            status="sampling",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            state="Unknown",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
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

        return MachineStatusResponse(
            status="stopping",
            dry_run=self.config.dry_run,
            controller=self._controller_description(),
            state="Hold",
            homing_trusted=self._load_machine_config().homing_trusted,
            axis_model_trusted=self._load_machine_config().axis_model_trusted,
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

    def _calibration_response(self, session: CalibrationSession) -> CalibrationSessionResponse:
        return CalibrationSessionResponse(
            session_id=session.session_id,
            status=session.status,
            dry_run=self.config.dry_run,
            planned_commands=session.planned_commands,
            waypoints=[waypoint.model_dump(mode="json") for waypoint in session.waypoints],
            observed_count=session.observed_count,
            model=session.model.model_dump(mode="json"),
            session_file=str(self._calibration_path(session.session_id)),
        )

    def _calibration_error(self, *, session_id: str, error: str) -> CalibrationSessionResponse:
        self.event_log.emit(
            "calibration.session_failed",
            command_id=session_id,
            status="failed",
            payload={"error": error},
        )
        return CalibrationSessionResponse(
            session_id=session_id,
            status="failed",
            dry_run=self.config.dry_run,
            planned_commands=[],
            waypoints=[],
            observed_count=0,
            model={},
            session_file="",
            error=error,
        )

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
        plan: DemoPlan,
        status: str,
        transcript_path: Path | None,
    ) -> DemoRunResponse:
        return DemoRunResponse(
            command_id=plan.command_id,
            status=status,
            dry_run=plan.dry_run,
            pattern=plan.pattern,
            planned_commands=plan.command_strings,
            simulation=plan.simulation,
            evaluation=plan.evaluation,
            event_log=str(self.config.event_log_path),
            controller_transcript=str(transcript_path) if transcript_path else None,
        )

    def _polygon_draw_response(
        self,
        *,
        plan: PolygonDrawPlan,
        machine_response: MachineCommandResponse,
    ) -> PolygonDrawResponse:
        return PolygonDrawResponse(
            command_id=plan.command_id,
            status=machine_response.status,
            dry_run=plan.dry_run,
            planned_commands=plan.command_strings,
            simulation=plan.simulation,
            summary=plan.summary,
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


def _dot_test_points(
    *,
    registration: PaperFrameRegistration,
    pattern: DotTestPattern,
    margin_mm: float,
) -> list[tuple[str, PaperPointMM]]:
    width = registration.paper_size_mm.width
    height = registration.paper_size_mm.height
    if margin_mm < 0:
        raise ValueError("Dot-test margin_mm must be non-negative.")
    if pattern != "center" and (margin_mm * 2 >= width or margin_mm * 2 >= height):
        raise ValueError("Dot-test margin_mm leaves no drawable paper area.")

    center = PaperPointMM(x=width / 2.0, y=height / 2.0)
    if pattern == "center":
        return [("P01", center)]

    left = margin_mm
    right = width - margin_mm
    bottom = margin_mm
    top = height - margin_mm
    mid_x = width / 2.0
    mid_y = height / 2.0

    if pattern == "five":
        points = [
            center,
            PaperPointMM(x=left, y=bottom),
            PaperPointMM(x=right, y=bottom),
            PaperPointMM(x=right, y=top),
            PaperPointMM(x=left, y=top),
        ]
    else:
        points = [
            center,
            PaperPointMM(x=left, y=bottom),
            PaperPointMM(x=mid_x, y=bottom),
            PaperPointMM(x=right, y=bottom),
            PaperPointMM(x=right, y=mid_y),
            PaperPointMM(x=right, y=top),
            PaperPointMM(x=mid_x, y=top),
            PaperPointMM(x=left, y=top),
            PaperPointMM(x=left, y=mid_y),
        ]

    return [(f"P{index:02d}", point) for index, point in enumerate(points, start=1)]


def _dot_test_polylines(
    *,
    points: list[tuple[str, PaperPointMM]],
    mark_size_mm: float,
) -> tuple[list[PlannedPolyline], list[str]]:
    if mark_size_mm <= 0:
        raise ValueError("Dot-test mark_size_mm must be positive.")

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


def _append_dot_test_park_commands(
    *,
    plan: PolygonDrawPlan,
    machine: MachineConfig,
    point: PaperPointMM,
    travel_feed_mm_min: float,
    park_offset_mm: float,
) -> None:
    if park_offset_mm < 0 or park_offset_mm > 100:
        raise MotionSafetyError("Dot-test park_offset_mm must be between 0 and 100 mm.")

    park_x, park_y = _dot_test_park_point(
        machine=machine,
        point=point,
        offset_mm=park_offset_mm,
    )
    validate_workspace_point(x_mm=park_x, y_mm=park_y, machine=machine)
    machine_x, machine_y = machine.logical_to_machine(x_mm=park_x, y_mm=park_y)
    plan.planned_commands.extend(
        [
            PlannedCommand(
                command=f"G1 F{format_mm(travel_feed_mm_min)}",
                kind="motion",
                description="Set observation park feed",
            ),
            PlannedCommand(
                command=(
                    f"G53 G1 X{format_mm(_zero_near(machine_x))} "
                    f"Y{format_mm(_zero_near(machine_y))}"
                ),
                kind="motion",
                description="Park pen away from dot-test mark",
            ),
        ]
    )
    plan.summary.command_count = len(plan.planned_commands)
    plan.simulation = simulate_plotter_commands(
        plan.command_strings,
        machine=machine,
        pen_up_command=machine.pen.up_command,
        pen_down_command=machine.pen.down_command,
    )


def _dot_test_park_point(
    *,
    machine: MachineConfig,
    point: PaperPointMM,
    offset_mm: float,
) -> tuple[float, float]:
    if offset_mm <= 1e-9:
        return (point.x, point.y)

    right_x = point.x + offset_mm
    left_x = point.x - offset_mm
    if right_x <= machine.workspace.x_max:
        return (right_x, point.y)
    if left_x >= machine.workspace.x_min:
        return (left_x, point.y)

    up_y = point.y + offset_mm
    down_y = point.y - offset_mm
    if up_y <= machine.workspace.y_max:
        return (point.x, up_y)
    if down_y >= machine.workspace.y_min:
        return (point.x, down_y)

    return (point.x, point.y)


def _validate_dot_test_simulation(
    *,
    plan: PolygonDrawPlan,
    segment_point_ids: list[str],
) -> None:
    if plan.simulation.status != "ok":
        raise MotionSafetyError(
            "Dot-test simulation failed: " + "; ".join(plan.simulation.errors)
        )
    if len(plan.simulation.drawn_segments) != len(segment_point_ids):
        raise MotionSafetyError(
            "Dot-test simulation did not preserve one segment per planned mark leg."
        )


def _project_drawn_segment_to_camera(
    *,
    segment: DrawnSegment,
    point_id: str,
    machine: MachineConfig,
    registration: PaperFrameRegistration,
) -> DotTestPreviewSegment:
    start_paper = PaperPointMM(
        x=machine.axes.x.machine_to_logical(segment.start.x),
        y=machine.axes.y.machine_to_logical(segment.start.y),
    )
    end_paper = PaperPointMM(
        x=machine.axes.x.machine_to_logical(segment.end.x),
        y=machine.axes.y.machine_to_logical(segment.end.y),
    )
    return DotTestPreviewSegment(
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
            if parsed_url.path == "/machine/status":
                self._write_model(HTTPStatus.OK, bridge.machine_status())
                return
            if parsed_url.path == "/calibration/status":
                query = parse_qs(parsed_url.query)
                session_id = query.get("session_id", [""])[0]
                if not session_id:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": "session_id is required"})
                    return
                response = bridge.calibration_status(session_id)
                status = HTTPStatus.OK if response.status != "failed" else HTTPStatus.NOT_FOUND
                self._write_model(status, response)
                return
            if parsed_url.path == "/paper/status":
                response = bridge.paper_registration_status()
                self._write_model(HTTPStatus.OK, response)
                return
            self._write_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:
            parsed_url = urlparse(self.path)
            if parsed_url.path == "/draw/shape/preview":
                try:
                    request = DemoRunRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.preview_demo(request)
                status = HTTPStatus.OK if response.status == "ready" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path in {"/demo/run", "/draw/shape"}:
                try:
                    request = DemoRunRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.run_demo(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/draw/polygon":
                try:
                    request = PolygonDrawRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.draw_polygon(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/draw/face":
                try:
                    request = FaceRasterDrawRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.draw_face_raster(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/jog":
                try:
                    request = MachineJogRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.jog_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/axis-model/trust":
                try:
                    request = AxisModelTrustRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.trust_axis_model(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/relative-move":
                try:
                    request = MachineRelativeMoveRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.relative_move_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/relative-mark":
                try:
                    request = MachineRelativeMarkRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.relative_mark_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/reconnect":
                try:
                    request = MachineReconnectRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.reconnect_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/home":
                try:
                    request = MachineHomeRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.home_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/center":
                try:
                    request = MachineCenterRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.center_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/pen-up":
                try:
                    request = MachinePenRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.pen_up_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/pen-down":
                try:
                    request = MachinePenRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.pen_down_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/dot-mark":
                try:
                    request = MachineDotMarkRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.dot_mark_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/stop":
                try:
                    request = MachineStopRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.stop_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/resume":
                try:
                    request = MachineResumeRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.resume_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/machine/unlock":
                try:
                    request = MachineUnlockRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.unlock_machine(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/calibration/start":
                try:
                    request = CalibrationStartRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.start_calibration(request)
                status = HTTPStatus.OK if response.status != "failed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return

            if parsed_url.path == "/calibration/observe":
                try:
                    request = CalibrationObservationRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.add_calibration_observation(request)
                status = HTTPStatus.OK if response.status != "failed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return
            if parsed_url.path == "/paper/register":
                try:
                    request = PaperRegistrationRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.register_paper(request)
                status = HTTPStatus.OK if response.status != "failed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return
            if parsed_url.path == "/dot-test/preview":
                try:
                    request = DotTestPreviewRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.preview_dot_test(request)
                status = HTTPStatus.OK if response.status == "ready" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
                return
            if parsed_url.path == "/dot-test/run":
                try:
                    request = DotTestRunRequest.model_validate(self._read_json_body())
                except (json.JSONDecodeError, ValidationError, ValueError) as exc:
                    self._write_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
                    return

                response = bridge.run_dot_test(request)
                status = HTTPStatus.OK if response.status == "completed" else HTTPStatus.BAD_REQUEST
                self._write_model(status, response)
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

        def _write_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(status.value)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    return PlotterBridgeHandler
