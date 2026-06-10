from __future__ import annotations

import math

from plotter_vision.config import MachineConfig, SafetyState


class MotionSafetyError(ValueError):
    """Raised when a motion request does not satisfy configured safety gates."""


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


def validate_demo_shape_request(
    *,
    side_mm: float,
    draw_feed_mm_min: float,
    travel_feed_mm_min: float,
    machine: MachineConfig,
    safety: SafetyState,
) -> None:
    if side_mm <= 0:
        raise MotionSafetyError("Demo shape side_mm must be positive.")
    if side_mm > machine.max_calibration_line_mm:
        raise MotionSafetyError(
            f"Demo shape side_mm {side_mm} mm exceeds "
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
        raise MotionSafetyError("Real demo motion requires armed_motion=true.")


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
