from __future__ import annotations

import math
from collections.abc import Sequence

from plotter_vision.config import MachineConfig, SafetyState


class MotionSafetyError(ValueError):
    """Raised when a motion request does not satisfy configured safety gates."""


WORKSPACE_PROJECTION_EPSILON_MM = 0.01


def validate_jog_request(
    *,
    axis: str,
    distance_mm: float,
    feed_mm_min: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> str:
    normalized_axis = axis.upper()
    if normalized_axis not in {"X", "Y"}:
        raise MotionSafetyError("Only X and Y jogs are allowed in this phase.")
    if distance_mm == 0:
        raise MotionSafetyError("Jog distance must be non-zero.")
    if abs(distance_mm) > machine.max_jog_mm:
        raise MotionSafetyError(
            f"Jog distance {distance_mm} mm exceeds max_jog_mm {machine.max_jog_mm}."
        )
    if feed_mm_min <= 0:
        raise MotionSafetyError("Feed must be positive.")
    if feed_mm_min > machine.max_feed_mm_min:
        raise MotionSafetyError(
            f"Feed {feed_mm_min} mm/min exceeds max_feed_mm_min {machine.max_feed_mm_min}."
        )
    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real motion requires armed_motion=true.")
    return normalized_axis


def validate_relative_xy_move_request(
    *,
    x_mm: float,
    y_mm: float,
    feed_mm_min: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> None:
    if not math.isfinite(x_mm) or not math.isfinite(y_mm):
        raise MotionSafetyError("Relative move coordinates must be finite.")
    if abs(x_mm) < 0.000_001 and abs(y_mm) < 0.000_001:
        raise MotionSafetyError("Relative move distance must be non-zero.")
    distance_mm = math.hypot(x_mm, y_mm)
    if distance_mm > machine.max_jog_mm:
        raise MotionSafetyError(
            f"Relative move distance {distance_mm:.3f} mm exceeds max_jog_mm "
            f"{machine.max_jog_mm}."
        )
    if feed_mm_min <= 0:
        raise MotionSafetyError("Feed must be positive.")
    if feed_mm_min > machine.max_feed_mm_min:
        raise MotionSafetyError(
            f"Feed {feed_mm_min} mm/min exceeds max_feed_mm_min {machine.max_feed_mm_min}."
        )
    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real relative motion requires armed_motion=true.")


def validate_calibration_line_request(
    *,
    axis: str,
    distance_mm: float,
    feed_mm_min: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> str:
    normalized_axis = axis.upper()
    if normalized_axis not in {"X", "Y"}:
        raise MotionSafetyError("Only X and Y calibration lines are allowed in this phase.")
    if distance_mm == 0:
        raise MotionSafetyError("Calibration line distance must be non-zero.")
    if abs(distance_mm) > machine.max_calibration_line_mm:
        raise MotionSafetyError(
            f"Calibration line distance {distance_mm} mm exceeds "
            f"max_calibration_line_mm {machine.max_calibration_line_mm}."
        )
    if feed_mm_min <= 0:
        raise MotionSafetyError("Feed must be positive.")
    if feed_mm_min > machine.max_feed_mm_min:
        raise MotionSafetyError(
            f"Feed {feed_mm_min} mm/min exceeds max_feed_mm_min {machine.max_feed_mm_min}."
        )
    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real motion requires armed_motion=true.")
    return normalized_axis


def validate_shape_execution_request(
    *,
    side_mm: float,
    draw_feed_mm_min: float,
    travel_feed_mm_min: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> None:
    if side_mm <= 0:
        raise MotionSafetyError("Shape execution side_mm must be positive.")
    if side_mm > machine.max_calibration_line_mm:
        raise MotionSafetyError(
            f"Shape execution side_mm {side_mm} mm exceeds "
            f"max_calibration_line_mm {machine.max_calibration_line_mm}."
        )
    for label, feed_mm_min in [
        ("draw_feed_mm_min", draw_feed_mm_min),
        ("travel_feed_mm_min", travel_feed_mm_min),
    ]:
        if feed_mm_min <= 0:
            raise MotionSafetyError(f"{label} must be positive.")
        if feed_mm_min > machine.max_feed_mm_min:
            raise MotionSafetyError(
                f"{label} {feed_mm_min} mm/min exceeds "
                f"max_feed_mm_min {machine.max_feed_mm_min}."
            )
    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real shape execution motion requires armed_motion=true.")


def validate_polygon_draw_request(
    *,
    draw_feed_mm_min: float,
    travel_feed_mm_min: float,
    max_segment_mm: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> None:
    for label, feed_mm_min in [
        ("draw_feed_mm_min", draw_feed_mm_min),
        ("travel_feed_mm_min", travel_feed_mm_min),
    ]:
        if feed_mm_min <= 0:
            raise MotionSafetyError(f"{label} must be positive.")
        if feed_mm_min > machine.max_feed_mm_min:
            raise MotionSafetyError(
                f"{label} {feed_mm_min} mm/min exceeds "
                f"max_feed_mm_min {machine.max_feed_mm_min}."
            )

    if max_segment_mm <= 0:
        raise MotionSafetyError("max_segment_mm must be positive.")
    if max_segment_mm > machine.max_calibration_line_mm:
        raise MotionSafetyError(
            f"max_segment_mm {max_segment_mm} mm exceeds "
            f"max_calibration_line_mm {machine.max_calibration_line_mm}."
        )

    if not safety.dry_run and not safety.armed_motion:
        raise MotionSafetyError("Real polygon drawing motion requires armed_motion=true.")


def validate_workspace_point(
    *,
    x_mm: float,
    y_mm: float,
    machine: MachineConfig,
) -> None:
    if not machine.workspace.x_min <= x_mm <= machine.workspace.x_max:
        raise MotionSafetyError(
            f"X coordinate {x_mm:.3f} mm is outside workspace "
            f"[{machine.workspace.x_min:.3f}, {machine.workspace.x_max:.3f}]."
        )
    if not machine.workspace.y_min <= y_mm <= machine.workspace.y_max:
        raise MotionSafetyError(
            f"Y coordinate {y_mm:.3f} mm is outside workspace "
            f"[{machine.workspace.y_min:.3f}, {machine.workspace.y_max:.3f}]."
        )


def validate_projected_workspace_motion(
    *,
    start_mpos_mm: Sequence[float] | None,
    commands: Sequence[str],
    machine: MachineConfig,
) -> None:
    """Project planned XY motion against current MPos before live execution."""
    if start_mpos_mm is None or len(start_mpos_mm) < 2:
        raise MotionSafetyError("Workspace projection guard requires current controller MPos.")

    current_x = _finite_axis_position(start_mpos_mm[0], axis="X")
    current_y = _finite_axis_position(start_mpos_mm[1], axis="Y")
    relative_mode = False

    for command in commands:
        words = command.strip().split()
        if not words:
            continue
        for word in words:
            modal = word.upper()
            if modal in {"G90", "G90.0"}:
                relative_mode = False
            elif modal in {"G91", "G91.0"}:
                relative_mode = True

        if not _is_motion_command(words):
            continue

        x_word = _axis_word_value(words, "X")
        y_word = _axis_word_value(words, "Y")
        if x_word is None and y_word is None:
            continue

        projected_x = current_x
        projected_y = current_y
        if x_word is not None:
            projected_x = current_x + x_word if relative_mode else x_word
            _validate_projected_axis(
                axis="X",
                value=projected_x,
                minimum=machine.workspace.x_min,
                maximum=machine.workspace.x_max,
                command=command,
            )
        if y_word is not None:
            projected_y = current_y + y_word if relative_mode else y_word
            _validate_projected_axis(
                axis="Y",
                value=projected_y,
                minimum=machine.workspace.y_min,
                maximum=machine.workspace.y_max,
                command=command,
            )

        current_x = projected_x
        current_y = projected_y


def _finite_axis_position(value: float, *, axis: str) -> float:
    position = float(value)
    if not math.isfinite(position):
        raise MotionSafetyError(f"Workspace projection guard needs finite {axis} MPos.")
    return position


def _is_motion_command(words: Sequence[str]) -> bool:
    return any(word.upper() in {"G0", "G00", "G1", "G01"} for word in words)


def _axis_word_value(words: Sequence[str], axis: str) -> float | None:
    for word in words:
        if word.upper().startswith(axis):
            try:
                value = float(word[1:])
            except ValueError as exc:
                raise MotionSafetyError(f"Invalid {axis} axis word in motion command {word!r}.") from exc
            if not math.isfinite(value):
                raise MotionSafetyError(f"Invalid non-finite {axis} axis value in motion command.")
            return value
    return None


def _validate_projected_axis(
    *,
    axis: str,
    value: float,
    minimum: float,
    maximum: float,
    command: str,
) -> None:
    if minimum <= value <= maximum:
        return
    if minimum - WORKSPACE_PROJECTION_EPSILON_MM <= value <= maximum + WORKSPACE_PROJECTION_EPSILON_MM:
        return
    raise MotionSafetyError(
        f"Projected {axis} position {value:.3f} mm for {command!r} is outside workspace "
        f"[{minimum:.3f}, {maximum:.3f}]. Motion not sent."
    )
