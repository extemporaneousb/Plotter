from __future__ import annotations

import pytest

from plotter_vision.config import SafetyState
from plotter_vision.machine.pen import PenCommandError, validate_pen_trial_command


@pytest.mark.parametrize(
    ("command", "expected"),
    [
        ("M3 S1000", "M3 S1000"),
        ("m3s500", "M3S500"),
        ("M4 S250.5", "M4 S250.5"),
        ("M5", "M5"),
    ],
)
def test_pen_trial_allows_explicit_mcode_preview(command: str, expected: str) -> None:
    assert validate_pen_trial_command(command, SafetyState(dry_run=True)) == expected


@pytest.mark.parametrize(
    "command",
    ["", "$X", "$100=1", "G1 X1", "X1", "M3 X1", "M7", "M8", "M9", "M3 S100\nM5"],
)
def test_pen_trial_rejects_non_pen_or_multi_line_commands(command: str) -> None:
    with pytest.raises(PenCommandError):
        validate_pen_trial_command(command, SafetyState(dry_run=True))


def test_real_pen_trial_requires_pen_arm() -> None:
    with pytest.raises(PenCommandError, match="allow_pen_actuation"):
        validate_pen_trial_command("M3 S1000", SafetyState(dry_run=False, allow_pen_actuation=False))


def test_real_pen_trial_allows_explicit_arm() -> None:
    command = validate_pen_trial_command(
        "M3 S1000",
        SafetyState(dry_run=False, allow_pen_actuation=True),
    )

    assert command == "M3 S1000"
