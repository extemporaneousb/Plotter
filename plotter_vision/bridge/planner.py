from __future__ import annotations

import math
from typing import Literal

from pydantic import BaseModel, Field

from plotter_vision.calibration.vision_model import LogicalPointMM
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.drawing import (
    DrawingProgram,
    DrawingFrameMM,
    PlannedPolyline,
    build_polygon_polylines,
    validate_polylines_in_workspace,
)
from plotter_vision.machine.homing import HomingSafetyError
from plotter_vision.machine.pen import validate_pen_trial_command
from plotter_vision.machine.safety import (
    MotionSafetyError,
    validate_shape_execution_request,
    validate_polygon_draw_request,
    validate_workspace_point,
)
from plotter_vision.motion.gcode import format_mm
from plotter_vision.motion.simulator import (
    ShapeGeometryEvaluation,
    SimulatedPath,
    evaluate_shape_geometry,
    simulate_plotter_commands,
)

ShapePattern = Literal["triangle", "square"]
PlannedCommandKind = Literal["homing", "motion", "pen"]


class PolygonDrawRequest(BaseModel):
    program: DrawingProgram = Field(default_factory=DrawingProgram)
    frame: DrawingFrameMM | None = None
    polylines: list[PlannedPolyline] = Field(default_factory=list)
    include_homing: bool = False
    visual_position_trusted: bool = False
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    max_segment_mm: float = 25.0
    max_polyline_count: int = 1600
    request_id: str | None = None


class ShapeExecutionRequest(BaseModel):
    pattern: ShapePattern = "triangle"
    include_homing: bool = True
    include_centering: bool = True
    side_mm: float = 20.0
    center_x_mm: float | None = None
    center_y_mm: float | None = None
    draw_feed_mm_min: float = 180.0
    travel_feed_mm_min: float = 500.0
    park_offset_mm: float = 25.0
    request_id: str | None = None


class PlannedCommand(BaseModel):
    command: str
    kind: PlannedCommandKind
    description: str


class ShapeExecutionPlan(BaseModel):
    command_id: str
    pattern: ShapePattern
    dry_run: bool
    planned_commands: list[PlannedCommand] = Field(default_factory=list)
    simulation: SimulatedPath
    evaluation: ShapeGeometryEvaluation

    @property
    def command_strings(self) -> list[str]:
        return [planned.command for planned in self.planned_commands]


class PolygonDrawPlanSummary(BaseModel):
    coordinate_frame: str = "paper_norm_to_logical_mm"
    polyline_count: int
    outline_polyline_count: int
    hatch_polyline_count: int
    mark_polyline_count: int = 0
    contour_polyline_count: int = 0
    draw_segment_count: int
    command_count: int
    drawn_length_mm: float
    bounds_logical_mm: dict[str, float] = Field(default_factory=dict)


class PolygonDrawPlan(BaseModel):
    command_id: str
    dry_run: bool
    planned_commands: list[PlannedCommand] = Field(default_factory=list)
    simulation: SimulatedPath
    summary: PolygonDrawPlanSummary

    @property
    def command_strings(self) -> list[str]:
        return [planned.command for planned in self.planned_commands]


def build_polygon_draw_plan(
    *,
    request: PolygonDrawRequest,
    machine: MachineConfig,
    safety: SafetyState,
    command_id: str,
) -> PolygonDrawPlan:
    """Build a bounded paper-space polygon drawing command stream without contacting hardware."""
    validate_polygon_draw_request(
        draw_feed_mm_min=request.draw_feed_mm_min,
        travel_feed_mm_min=request.travel_feed_mm_min,
        max_segment_mm=request.max_segment_mm,
        machine=machine,
        safety=safety,
    )
    if request.include_homing and not safety.dry_run and not safety.allow_homing:
        raise HomingSafetyError("Real polygon drawing homing requires allow_homing=true.")
    has_trusted_absolute_position = machine.axis_model_trusted or request.visual_position_trusted
    if not safety.dry_run and not has_trusted_absolute_position:
        raise MotionSafetyError(
            "Real absolute polygon drawing requires axis_model_trusted=true or "
            "visual_position_trusted=true."
        )

    pen_down = _validated_pen_command(machine.pen.down_command, safety)
    pen_up = _validated_pen_command(machine.pen.up_command, safety)
    if safety.dry_run:
        pen_down = pen_down or "M3 S1"
        pen_up = pen_up or "M5"
    elif pen_down is None or pen_up is None:
        raise MotionSafetyError("Polygon drawing requires configured pen up/down commands.")

    frame = request.frame or _default_drawing_frame(machine)
    polylines = [
        *build_polygon_polylines(program=request.program, frame=frame),
        *request.polylines,
    ]
    if not polylines:
        raise MotionSafetyError("Polygon drawing requires at least one polygon or polyline.")
    if request.max_polyline_count < 1:
        raise MotionSafetyError("max_polyline_count must be positive.")
    if len(polylines) > request.max_polyline_count:
        raise MotionSafetyError(
            f"Polygon drawing produced {len(polylines)} polylines; "
            f"limit is {request.max_polyline_count}."
        )

    validate_polylines_in_workspace(polylines=polylines, machine=machine)
    split_polylines = [
        _split_polyline(polyline=polyline, max_segment_mm=request.max_segment_mm)
        for polyline in polylines
    ]
    draw_segment_count = sum(len(points) - 1 for points in split_polylines)
    if draw_segment_count <= 0:
        raise MotionSafetyError("Polygon drawing produced no drawable segments.")

    commands = _polygon_draw_commands(
        split_polylines=split_polylines,
        source_polylines=polylines,
        machine=machine,
        pen_up=pen_up,
        pen_down=pen_down,
        include_homing=request.include_homing,
        draw_feed_mm_min=request.draw_feed_mm_min,
        travel_feed_mm_min=request.travel_feed_mm_min,
    )
    command_strings = [planned.command for planned in commands]
    simulation = simulate_plotter_commands(
        command_strings,
        machine=machine,
        pen_up_command=pen_up,
        pen_down_command=pen_down,
    )
    if simulation.status != "ok":
        raise MotionSafetyError(
            "Polygon drawing command stream failed simulation: "
            + "; ".join(simulation.errors)
        )
    if len(simulation.drawn_segments) != draw_segment_count:
        raise MotionSafetyError(
            "Polygon drawing command stream did not simulate the expected drawn segment count."
        )

    summary = PolygonDrawPlanSummary(
        polyline_count=len(polylines),
        outline_polyline_count=sum(1 for polyline in polylines if polyline.role == "outline"),
        hatch_polyline_count=sum(1 for polyline in polylines if polyline.role == "hatch"),
        mark_polyline_count=sum(1 for polyline in polylines if polyline.role == "mark"),
        contour_polyline_count=sum(1 for polyline in polylines if polyline.role == "contour"),
        draw_segment_count=draw_segment_count,
        command_count=len(commands),
        drawn_length_mm=simulation.drawn_length_mm,
        bounds_logical_mm=_logical_bounds(split_polylines),
    )
    return PolygonDrawPlan(
        command_id=command_id,
        dry_run=safety.dry_run,
        planned_commands=commands,
        simulation=simulation,
        summary=summary,
    )


def build_shape_execution_plan(
    *,
    request: ShapeExecutionRequest,
    machine: MachineConfig,
    safety: SafetyState,
    command_id: str,
) -> ShapeExecutionPlan:
    """Build the first camera-driven machine shape execution without contacting hardware."""
    validate_shape_execution_request(
        side_mm=request.side_mm,
        draw_feed_mm_min=request.draw_feed_mm_min,
        travel_feed_mm_min=request.travel_feed_mm_min,
        machine=machine,
        safety=safety,
    )
    if request.include_homing and not safety.dry_run and not safety.allow_homing:
        raise HomingSafetyError("Real shape execution homing requires allow_homing=true.")
    if request.park_offset_mm < 0 or request.park_offset_mm > 100:
        raise MotionSafetyError("park_offset_mm must be between 0 and 100 mm.")

    pen_down = _validated_pen_command(machine.pen.down_command, safety)
    pen_up = _validated_pen_command(machine.pen.up_command, safety)
    if not safety.dry_run and (pen_down is None or pen_up is None):
        raise MotionSafetyError("Real shape drawing requires configured pen up/down commands.")

    default_center_x, default_center_y = machine.logical_center_mm()
    center_x = request.center_x_mm if request.center_x_mm is not None else default_center_x
    center_y = request.center_y_mm if request.center_y_mm is not None else default_center_y
    validate_workspace_point(x_mm=center_x, y_mm=center_y, machine=machine)

    vertices = _shape_vertices(
        pattern=request.pattern,
        side_mm=request.side_mm,
        center_x=center_x,
        center_y=center_y,
    )
    for x_mm, y_mm in vertices:
        validate_workspace_point(x_mm=x_mm, y_mm=y_mm, machine=machine)

    park_x, park_y = _park_point(
        machine=machine,
        center_x=center_x,
        center_y=center_y,
        side_mm=request.side_mm,
        offset_mm=request.park_offset_mm,
    )
    machine_center_x, machine_center_y = machine.logical_to_machine(x_mm=center_x, y_mm=center_y)
    machine_vertices = [
        machine.logical_to_machine(x_mm=x_mm, y_mm=y_mm)
        for x_mm, y_mm in vertices
    ]
    machine_start_x, machine_start_y = machine_vertices[0]
    machine_park_x, machine_park_y = machine.logical_to_machine(x_mm=park_x, y_mm=park_y)

    commands: list[PlannedCommand] = []
    if request.include_homing:
        commands.append(PlannedCommand(command="$H", kind="homing", description="Run XY homing"))

    commands.extend(
        [
            PlannedCommand(command="G21", kind="motion", description="Use millimeter units"),
            PlannedCommand(command="G90", kind="motion", description="Use absolute positioning"),
            PlannedCommand(command="G94", kind="motion", description="Use feed per minute"),
            PlannedCommand(
                command=f"G1 F{format_mm(request.travel_feed_mm_min)}",
                kind="motion",
                description="Set travel feed",
            ),
        ]
    )

    if pen_up is not None:
        _append_pen_command(
            commands=commands,
            machine=machine,
            command=pen_up,
            description="Raise pen",
        )

    if request.include_centering:
        commands.append(
            PlannedCommand(
                command=f"G53 G1 X{format_mm(machine_center_x)} Y{format_mm(machine_center_y)}",
                kind="motion",
                description="Move to workspace center",
            )
        )

    commands.append(
        PlannedCommand(
            command=f"G53 G1 X{format_mm(machine_start_x)} Y{format_mm(machine_start_y)}",
            kind="motion",
            description="Move to shape start",
        )
    )

    if pen_down is not None:
        _append_pen_command(
            commands=commands,
            machine=machine,
            command=pen_down,
            description="Lower pen",
        )

    commands.extend(
        [
            PlannedCommand(command="G91", kind="motion", description="Use relative drawing moves"),
            PlannedCommand(
                command=f"G1 F{format_mm(request.draw_feed_mm_min)}",
                kind="motion",
                description="Set draw feed",
            ),
        ]
    )
    commands.extend(_relative_shape_commands(request.pattern, machine_vertices))
    commands.append(PlannedCommand(command="G90", kind="motion", description="Restore absolute mode"))

    if pen_up is not None:
        _append_pen_command(
            commands=commands,
            machine=machine,
            command=pen_up,
            description="Raise pen",
        )

    commands.extend(
        [
            PlannedCommand(
                command=f"G1 F{format_mm(request.travel_feed_mm_min)}",
                kind="motion",
                description="Set travel feed",
            ),
            PlannedCommand(
                command=f"G53 G1 X{format_mm(machine_park_x)} Y{format_mm(machine_park_y)}",
                kind="motion",
                description="Park pen away from the drawn shape",
            ),
        ]
    )

    command_strings = [planned.command for planned in commands]
    simulation = simulate_plotter_commands(
        command_strings,
        machine=machine,
        pen_up_command=pen_up,
        pen_down_command=pen_down,
    )
    evaluation = evaluate_shape_geometry(
        pattern=request.pattern,
        side_mm=request.side_mm,
        simulation=simulation,
    )

    return ShapeExecutionPlan(
        command_id=command_id,
        pattern=request.pattern,
        dry_run=safety.dry_run,
        planned_commands=commands,
        simulation=simulation,
        evaluation=evaluation,
    )


def _validated_pen_command(command: str | None, safety: SafetyState) -> str | None:
    if command is None:
        return None
    return validate_pen_trial_command(command, safety)


def _append_pen_command(
    *,
    commands: list[PlannedCommand],
    machine: MachineConfig,
    command: str,
    description: str,
) -> None:
    commands.append(PlannedCommand(command=command, kind="pen", description=description))
    if machine.pen.settle_s <= 0:
        return
    commands.append(
        PlannedCommand(
            command=f"G4 P{format_mm(machine.pen.settle_s)}",
            kind="motion",
            description=f"Wait for {description.lower()}",
        )
    )


def _default_drawing_frame(machine: MachineConfig) -> DrawingFrameMM:
    return DrawingFrameMM(
        origin_x_mm=machine.workspace.x_min,
        origin_y_mm=machine.workspace.y_min,
        width_mm=machine.workspace.x_max - machine.workspace.x_min,
        height_mm=machine.workspace.y_max - machine.workspace.y_min,
    )


def _polygon_draw_commands(
    *,
    split_polylines: list[list[LogicalPointMM]],
    source_polylines: list[PlannedPolyline],
    machine: MachineConfig,
    pen_up: str,
    pen_down: str,
    include_homing: bool,
    draw_feed_mm_min: float,
    travel_feed_mm_min: float,
) -> list[PlannedCommand]:
    commands: list[PlannedCommand] = []
    if include_homing:
        commands.append(PlannedCommand(command="$H", kind="homing", description="Run XY homing"))

    commands.extend(
        [
            PlannedCommand(command="G21", kind="motion", description="Use millimeter units"),
            PlannedCommand(command="G90", kind="motion", description="Use absolute positioning"),
            PlannedCommand(command="G94", kind="motion", description="Use feed per minute"),
        ]
    )
    _append_pen_command(
        commands=commands,
        machine=machine,
        command=pen_up,
        description="Raise pen",
    )

    for index, (points, source) in enumerate(zip(split_polylines, source_polylines), start=1):
        start = points[0]
        commands.append(
            PlannedCommand(
                command=f"G1 F{format_mm(travel_feed_mm_min)}",
                kind="motion",
                description=f"Set travel feed for {source.role} polyline {index}",
            )
        )
        commands.append(
            PlannedCommand(
                command=_absolute_machine_move_command(point=start, machine=machine),
                kind="motion",
                description=f"Travel to {source.role} polyline {index} start",
            )
        )
        _append_pen_command(
            commands=commands,
            machine=machine,
            command=pen_down,
            description="Lower pen",
        )
        commands.append(
            PlannedCommand(
                command=f"G1 F{format_mm(draw_feed_mm_min)}",
                kind="motion",
                description=f"Set draw feed for {source.role} polyline {index}",
            )
        )
        for segment_index, point in enumerate(points[1:], start=1):
            commands.append(
                PlannedCommand(
                    command=_absolute_machine_move_command(point=point, machine=machine),
                    kind="motion",
                    description=(
                        f"Draw {source.role} polyline {index} segment {segment_index}"
                    ),
                )
            )
        _append_pen_command(
            commands=commands,
            machine=machine,
            command=pen_up,
            description="Raise pen",
        )

    return commands


def _absolute_machine_move_command(*, point: LogicalPointMM, machine: MachineConfig) -> str:
    machine_x, machine_y = machine.logical_to_machine(x_mm=point.x, y_mm=point.y)
    return f"G53 G1 X{format_mm(_zero_near(machine_x))} Y{format_mm(_zero_near(machine_y))}"


def _split_polyline(*, polyline: PlannedPolyline, max_segment_mm: float) -> list[LogicalPointMM]:
    points = polyline.points
    if len(points) < 2:
        raise MotionSafetyError("Planned polylines require at least two points.")

    split: list[LogicalPointMM] = [points[0]]
    for start, end in zip(points, points[1:]):
        _validate_logical_point(start)
        _validate_logical_point(end)
        distance_mm = math.hypot(end.x - start.x, end.y - start.y)
        if distance_mm <= 1e-9:
            raise MotionSafetyError("Polygon drawing contains a zero-length segment.")
        step_count = max(1, math.ceil(distance_mm / max_segment_mm))
        for step in range(1, step_count + 1):
            t = step / step_count
            split.append(
                LogicalPointMM(
                    x=start.x + (end.x - start.x) * t,
                    y=start.y + (end.y - start.y) * t,
                )
            )
    return split


def _validate_logical_point(point: LogicalPointMM) -> None:
    if not math.isfinite(point.x) or not math.isfinite(point.y):
        raise MotionSafetyError("Polygon drawing points must be finite.")


def _logical_bounds(polylines: list[list[LogicalPointMM]]) -> dict[str, float]:
    points = [point for polyline in polylines for point in polyline]
    return {
        "x_min": min(point.x for point in points),
        "x_max": max(point.x for point in points),
        "y_min": min(point.y for point in points),
        "y_max": max(point.y for point in points),
    }


def _zero_near(value: float) -> float:
    return 0.0 if abs(value) <= 1e-9 else value


def _shape_vertices(
    *,
    pattern: ShapePattern,
    side_mm: float,
    center_x: float,
    center_y: float,
) -> list[tuple[float, float]]:
    if pattern == "square":
        half = side_mm / 2
        return [
            (center_x - half, center_y - half),
            (center_x + half, center_y - half),
            (center_x + half, center_y + half),
            (center_x - half, center_y + half),
        ]

    height = side_mm * math.sqrt(3) / 2
    return [
        (center_x - side_mm / 2, center_y - height / 3),
        (center_x + side_mm / 2, center_y - height / 3),
        (center_x, center_y + (2 * height / 3)),
    ]


def _relative_shape_commands(
    pattern: ShapePattern,
    vertices: list[tuple[float, float]],
) -> list[PlannedCommand]:
    commands: list[PlannedCommand] = []
    closed_vertices = [*vertices, vertices[0]]

    for index, ((from_x, from_y), (to_x, to_y)) in enumerate(
        zip(closed_vertices, closed_vertices[1:]),
        start=1,
    ):
        dx = to_x - from_x
        dy = to_y - from_y
        commands.append(
            PlannedCommand(
                command=_relative_line_command(dx=dx, dy=dy),
                kind="motion",
                description=f"Draw {pattern} edge {index}",
            )
        )

    return commands


def _relative_line_command(*, dx: float, dy: float) -> str:
    axes: list[str] = []
    if abs(dx) > 0.000_001:
        axes.append(f"X{format_mm(dx)}")
    if abs(dy) > 0.000_001:
        axes.append(f"Y{format_mm(dy)}")
    return "G1 " + " ".join(axes)


def _park_point(
    *,
    machine: MachineConfig,
    center_x: float,
    center_y: float,
    side_mm: float,
    offset_mm: float,
) -> tuple[float, float]:
    margin = 5.0
    desired_offset = side_mm + offset_mm
    right = center_x + desired_offset
    left = center_x - desired_offset
    if right <= machine.workspace.x_max - margin:
        park_x = right
    elif left >= machine.workspace.x_min + margin:
        park_x = left
    else:
        park_x = center_x

    park_y = center_y
    validate_workspace_point(x_mm=park_x, y_mm=park_y, machine=machine)
    return park_x, park_y
