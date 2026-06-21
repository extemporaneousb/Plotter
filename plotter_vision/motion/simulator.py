from __future__ import annotations

import math
import re
from collections.abc import Sequence
from typing import Literal

from pydantic import BaseModel, Field

from plotter_vision.config import MachineConfig
from plotter_vision.machine.pen import normalize_pen_command


SimulationStatus = Literal["ok", "failed"]
EvaluationStatus = Literal["passed", "failed"]
CheckStatus = Literal["passed", "failed"]


class PointMM(BaseModel):
    x: float
    y: float


class DrawnSegment(BaseModel):
    start: PointMM
    end: PointMM
    length_mm: float


class PreviewSegment(BaseModel):
    start_norm: tuple[float, float]
    end_norm: tuple[float, float]
    start_machine_mm: tuple[float, float]
    end_machine_mm: tuple[float, float]
    length_mm: float


class SimulatedPath(BaseModel):
    status: SimulationStatus
    final_position_mm: PointMM | None = None
    pen_is_down: bool = False
    drawn_segments: list[DrawnSegment] = Field(default_factory=list)
    preview_segments: list[PreviewSegment] = Field(default_factory=list)
    drawn_length_mm: float = 0.0
    bounds_machine_mm: dict[str, float] = Field(default_factory=dict)
    errors: list[str] = Field(default_factory=list)


class ShapeEvaluationCheck(BaseModel):
    name: str
    status: CheckStatus
    actual: float
    expected: float
    tolerance: float


class ShapeGeometryEvaluation(BaseModel):
    status: EvaluationStatus
    message: str
    checks: list[ShapeEvaluationCheck] = Field(default_factory=list)


class GCodeSimulationError(ValueError):
    """Raised when the emitted command subset cannot be simulated deterministically."""


_WORD_RE = re.compile(r"^([A-Z])([+-]?(?:\d+(?:\.\d*)?|\.\d+))$")


def simulate_plotter_commands(
    commands: Sequence[str],
    *,
    machine: MachineConfig,
    pen_up_command: str | None,
    pen_down_command: str | None,
) -> SimulatedPath:
    interpreter = _CommandInterpreter(
        machine=machine,
        pen_up_command=pen_up_command,
        pen_down_command=pen_down_command,
    )

    for command in commands:
        interpreter.apply(command)

    return interpreter.result()


def evaluate_shape_geometry(
    *,
    pattern: str,
    side_mm: float,
    simulation: SimulatedPath,
    length_tolerance_mm: float = 0.05,
    closure_tolerance_mm: float = 0.05,
    angle_tolerance_deg: float = 1.0,
) -> ShapeGeometryEvaluation:
    if simulation.status != "ok":
        return ShapeGeometryEvaluation(
            status="failed",
            message="Simulation failed before geometry checks.",
        )

    expected_edges = 4 if pattern == "square" else 3
    expected_angle = 90.0 if pattern == "square" else 60.0
    checks: list[ShapeEvaluationCheck] = []

    segment_count = len(simulation.drawn_segments)
    checks.append(
        _check(
            name="edge_count",
            actual=float(segment_count),
            expected=float(expected_edges),
            tolerance=0.0,
        )
    )
    if segment_count != expected_edges:
        return ShapeGeometryEvaluation(
            status="failed",
            message=f"Expected {expected_edges} drawn edges, got {segment_count}.",
            checks=checks,
        )

    max_length_error = max(
        abs(segment.length_mm - side_mm)
        for segment in simulation.drawn_segments
    )
    checks.append(
        _check(
            name="max_side_length_error_mm",
            actual=max_length_error,
            expected=0.0,
            tolerance=length_tolerance_mm,
        )
    )

    continuity_error = _max_continuity_error(simulation.drawn_segments)
    checks.append(
        _check(
            name="max_continuity_error_mm",
            actual=continuity_error,
            expected=0.0,
            tolerance=closure_tolerance_mm,
        )
    )

    closure_error = _distance(
        simulation.drawn_segments[-1].end,
        simulation.drawn_segments[0].start,
    )
    checks.append(
        _check(
            name="closure_error_mm",
            actual=closure_error,
            expected=0.0,
            tolerance=closure_tolerance_mm,
        )
    )

    max_angle_error = max(
        abs(angle - expected_angle)
        for angle in _interior_angles_deg(simulation.drawn_segments)
    )
    checks.append(
        _check(
            name="max_corner_angle_error_deg",
            actual=max_angle_error,
            expected=0.0,
            tolerance=angle_tolerance_deg,
        )
    )

    status: EvaluationStatus = (
        "passed"
        if all(check.status == "passed" for check in checks)
        else "failed"
    )
    return ShapeGeometryEvaluation(
        status=status,
        message=(
            f"{pattern} command stream matches expected geometry."
            if status == "passed"
            else f"{pattern} command stream does not match expected geometry."
        ),
        checks=checks,
    )


class _CommandInterpreter:
    def __init__(
        self,
        *,
        machine: MachineConfig,
        pen_up_command: str | None,
        pen_down_command: str | None,
    ) -> None:
        self.machine = machine
        self.pen_up_command = _normalize_optional(pen_up_command)
        self.pen_down_command = _normalize_optional(pen_down_command)
        self.absolute_mode = True
        self.unit_scale = 1.0
        self.position: PointMM | None = None
        self.pen_is_down = False
        self.drawn_segments: list[DrawnSegment] = []
        self.errors: list[str] = []

    def apply(self, command: str) -> None:
        normalized = _normalize_command(command)
        if not normalized:
            return
        if normalized == "$H":
            return
        if normalized == self.pen_up_command:
            self.pen_is_down = False
            return
        if normalized == self.pen_down_command:
            self.pen_is_down = True
            return
        if normalized.startswith("M"):
            return

        try:
            self._apply_gcode(normalized)
        except GCodeSimulationError as exc:
            self.errors.append(f"{normalized}: {exc}")

    def result(self) -> SimulatedPath:
        preview_segments = [
            _preview_segment(segment=segment, machine=self.machine)
            for segment in self.drawn_segments
        ]
        drawn_length_mm = sum(segment.length_mm for segment in self.drawn_segments)
        return SimulatedPath(
            status="failed" if self.errors else "ok",
            final_position_mm=self.position,
            pen_is_down=self.pen_is_down,
            drawn_segments=self.drawn_segments,
            preview_segments=preview_segments,
            drawn_length_mm=drawn_length_mm,
            bounds_machine_mm=_bounds(self.drawn_segments),
            errors=self.errors,
        )

    def _apply_gcode(self, command: str) -> None:
        words = command.split()
        g_codes: list[int] = []
        axes: dict[str, float] = {}

        for word in words:
            parsed = _WORD_RE.match(word)
            if parsed is None:
                raise GCodeSimulationError(f"Unsupported word {word!r}.")
            letter, raw_value = parsed.groups()
            if letter == "G":
                g_codes.append(int(float(raw_value)))
            elif letter in {"X", "Y"}:
                axes[letter] = float(raw_value) * self.unit_scale
            elif letter in {"F", "P"}:
                continue
            else:
                raise GCodeSimulationError(f"Unsupported word {word!r}.")

        if 20 in g_codes:
            self.unit_scale = 25.4
        if 21 in g_codes:
            self.unit_scale = 1.0
        if 90 in g_codes:
            self.absolute_mode = True
        if 91 in g_codes:
            self.absolute_mode = False

        if not axes:
            return

        if not any(code in {0, 1} for code in g_codes):
            raise GCodeSimulationError("Axis words require G0 or G1 in this simulator.")

        target = self._target_position(axes=axes, machine_absolute=53 in g_codes)
        self._move_to(target)

    def _target_position(
        self,
        *,
        axes: dict[str, float],
        machine_absolute: bool,
    ) -> PointMM:
        if machine_absolute or self.absolute_mode:
            x = axes.get("X")
            y = axes.get("Y")
            if x is None:
                if self.position is None:
                    raise GCodeSimulationError("Absolute X is omitted before position is known.")
                x = self.position.x
            if y is None:
                if self.position is None:
                    raise GCodeSimulationError("Absolute Y is omitted before position is known.")
                y = self.position.y
            return PointMM(x=x, y=y)

        if self.position is None:
            raise GCodeSimulationError("Relative motion cannot start from an unknown position.")
        return PointMM(
            x=self.position.x + axes.get("X", 0.0),
            y=self.position.y + axes.get("Y", 0.0),
        )

    def _move_to(self, target: PointMM) -> None:
        if self.position is not None and self.pen_is_down:
            length_mm = _distance(self.position, target)
            if length_mm > 0:
                self.drawn_segments.append(
                    DrawnSegment(
                        start=self.position,
                        end=target,
                        length_mm=length_mm,
                    )
                )
        self.position = target


def _normalize_optional(command: str | None) -> str | None:
    return normalize_pen_command(command) if command is not None else None


def _normalize_command(command: str) -> str:
    no_comment = command.split(";", 1)[0].strip().upper()
    return re.sub(r"\s+", " ", no_comment)


def _preview_segment(*, segment: DrawnSegment, machine: MachineConfig) -> PreviewSegment:
    start_logical = _machine_to_logical_norm(segment.start, machine)
    end_logical = _machine_to_logical_norm(segment.end, machine)
    return PreviewSegment(
        start_norm=start_logical,
        end_norm=end_logical,
        start_machine_mm=(segment.start.x, segment.start.y),
        end_machine_mm=(segment.end.x, segment.end.y),
        length_mm=segment.length_mm,
    )


def _machine_to_logical_norm(point: PointMM, machine: MachineConfig) -> tuple[float, float]:
    logical_x = machine.axes.x.machine_to_logical(point.x)
    logical_y = machine.axes.y.machine_to_logical(point.y)
    return (
        logical_x / machine.axes.x.travel_mm,
        logical_y / machine.axes.y.travel_mm,
    )


def _bounds(segments: Sequence[DrawnSegment]) -> dict[str, float]:
    if not segments:
        return {}
    xs = [point.x for segment in segments for point in [segment.start, segment.end]]
    ys = [point.y for segment in segments for point in [segment.start, segment.end]]
    return {
        "x_min": min(xs),
        "x_max": max(xs),
        "y_min": min(ys),
        "y_max": max(ys),
    }


def _check(
    *,
    name: str,
    actual: float,
    expected: float,
    tolerance: float,
) -> ShapeEvaluationCheck:
    return ShapeEvaluationCheck(
        name=name,
        status="passed" if abs(actual - expected) <= tolerance else "failed",
        actual=actual,
        expected=expected,
        tolerance=tolerance,
    )


def _distance(a: PointMM, b: PointMM) -> float:
    return math.hypot(b.x - a.x, b.y - a.y)


def _max_continuity_error(segments: Sequence[DrawnSegment]) -> float:
    errors = [
        _distance(current.end, following.start)
        for current, following in zip(segments, segments[1:])
    ]
    return max(errors, default=0.0)


def _interior_angles_deg(segments: Sequence[DrawnSegment]) -> list[float]:
    angles: list[float] = []
    for previous, current in zip([segments[-1], *segments[:-1]], segments):
        incoming = (
            previous.start.x - previous.end.x,
            previous.start.y - previous.end.y,
        )
        outgoing = (
            current.end.x - current.start.x,
            current.end.y - current.start.y,
        )
        angles.append(_angle_between_deg(incoming, outgoing))
    return angles


def _angle_between_deg(a: tuple[float, float], b: tuple[float, float]) -> float:
    length_a = math.hypot(a[0], a[1])
    length_b = math.hypot(b[0], b[1])
    if length_a == 0 or length_b == 0:
        return 0.0
    cosine = ((a[0] * b[0]) + (a[1] * b[1])) / (length_a * length_b)
    return math.degrees(math.acos(max(-1.0, min(1.0, cosine))))
