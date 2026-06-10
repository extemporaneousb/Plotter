from __future__ import annotations

import re

from plotter_vision.config import SafetyState


class PenCommandError(ValueError):
    """Raised when a pen trial command is not safe enough to send."""


PEN_MCODE_RE = re.compile(r"^M(?P<code>[345])(?:\s*S(?P<s>\d+(?:\.\d+)?))?$", re.IGNORECASE)


def normalize_pen_command(command: str) -> str:
    stripped = command.split(";", 1)[0].strip().upper()
    return re.sub(r"\s+", " ", stripped)


def validate_pen_trial_command(command: str, safety: SafetyState) -> str:
    normalized = normalize_pen_command(command)
    if not normalized:
        raise PenCommandError("Pen command must be non-empty.")
    if "\n" in command or "\r" in command:
        raise PenCommandError("Pen trial accepts one command line at a time.")
    if not PEN_MCODE_RE.match(normalized):
        raise PenCommandError(
            "Pen trial allows only explicit M3/M4/M5 commands with optional S value."
        )
    if not safety.dry_run and not safety.allow_pen_actuation:
        raise PenCommandError("Real pen actuation requires allow_pen_actuation=true.")
    return normalized
