from __future__ import annotations

import pytest

from plotter_vision.config import SafetyState
from plotter_vision.machine.homing import HomingSafetyError, validate_homing_request


def test_homing_requires_explicit_arm() -> None:
    with pytest.raises(HomingSafetyError, match="allow_homing"):
        validate_homing_request(
            state="Idle",
            pins="",
            safety=SafetyState(allow_homing=False),
        )


def test_homing_requires_idle_controller() -> None:
    with pytest.raises(HomingSafetyError, match="Idle"):
        validate_homing_request(
            state="Alarm",
            pins="",
            safety=SafetyState(allow_homing=True),
        )


def test_homing_requires_released_limit_pins() -> None:
    with pytest.raises(HomingSafetyError, match="Pn='X'"):
        validate_homing_request(
            state="Idle",
            pins="X",
            safety=SafetyState(allow_homing=True),
        )


def test_homing_accepts_idle_with_no_active_pins_and_explicit_arm() -> None:
    validate_homing_request(
        state="Idle",
        pins="",
        safety=SafetyState(allow_homing=True),
    )
