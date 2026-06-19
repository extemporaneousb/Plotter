from __future__ import annotations

from plotter_vision.config import SafetyState


class HomingSafetyError(ValueError):
    """Raised when a homing request is not explicitly armed and safe to start."""


def validate_homing_request(*, state: str, pins: str, safety: SafetyState) -> None:
    if not safety.allow_homing:
        raise HomingSafetyError("Homing requires allow_homing=true.")
    if state != "Idle":
        raise HomingSafetyError(f"Controller must be Idle before homing; got {state!r}.")
    if pins and pins != "-":
        raise HomingSafetyError(f"All limit pins must be released before homing; got Pn={pins!r}.")
