from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field


class ControllerError(RuntimeError):
    """Raised when controller communication returns an error, alarm, or timeout."""


class UnsafeCommandError(ValueError):
    """Raised when a command is not allowed by the current safety phase."""


PASSIVE_PHASE0_COMMANDS = {"$I", "$G", "?", "$$", "$#"}
SETTING_WRITE_RE = re.compile(r"^\$\d+\s*=")
SETTING_RE = re.compile(r"^\$(?P<number>\d+)=(?P<value>.*)$")


class ParsedLine(BaseModel):
    kind: Literal["ok", "error", "alarm", "status", "setting", "bracket", "text"]
    raw: str
    data: dict[str, Any] = Field(default_factory=dict)


class StatusReport(BaseModel):
    state: str
    machine_position: tuple[float, ...] | None = None
    work_position: tuple[float, ...] | None = None
    feed_spindle: tuple[float, ...] | None = None
    fields: dict[str, str] = Field(default_factory=dict)


class Setting(BaseModel):
    number: int
    value: str


def normalize_command(command: str) -> str:
    no_semicolon = command.split(";", 1)[0].strip()
    if not no_semicolon:
        return ""
    return re.sub(r"\s+", "", no_semicolon).upper()


def assert_phase0_safe_command(command: str) -> str:
    normalized = normalize_command(command)
    if not normalized:
        return ""
    if normalized in PASSIVE_PHASE0_COMMANDS:
        return normalized

    if normalized in {"$X", "$H", "$C"}:
        raise UnsafeCommandError(f"Refusing phase-0 controller state command: {command!r}")
    if normalized.startswith("$N"):
        raise UnsafeCommandError(f"Refusing startup block command in phase 0: {command!r}")
    if normalized.startswith("$RST"):
        raise UnsafeCommandError(f"Refusing reset command in phase 0: {command!r}")
    if SETTING_WRITE_RE.match(normalized):
        raise UnsafeCommandError(f"Refusing settings write in phase 0: {command!r}")
    if normalized.startswith("$J="):
        raise UnsafeCommandError(f"Refusing jog command in phase 0: {command!r}")
    if normalized[0] in {"G", "M", "T", "S", "F", "X", "Y", "Z"}:
        raise UnsafeCommandError(f"Refusing motion or actuator command in phase 0: {command!r}")
    if normalized in {"!", "~"} or "\x18" in command:
        raise UnsafeCommandError(f"Refusing realtime control command in phase 0: {command!r}")

    raise UnsafeCommandError(f"Command is not on the phase-0 passive allow-list: {command!r}")


def parse_float_tuple(value: str) -> tuple[float, ...]:
    return tuple(float(part) for part in value.split(",") if part != "")


def parse_status_report(line: str) -> StatusReport:
    if not (line.startswith("<") and line.endswith(">")):
        raise ValueError(f"Not a status report: {line!r}")

    parts = line[1:-1].split("|")
    state = parts[0]
    fields: dict[str, str] = {}
    machine_position: tuple[float, ...] | None = None
    work_position: tuple[float, ...] | None = None
    feed_spindle: tuple[float, ...] | None = None

    for part in parts[1:]:
        if ":" not in part:
            fields[part] = ""
            continue
        key, value = part.split(":", 1)
        fields[key] = value
        if key == "MPos":
            machine_position = parse_float_tuple(value)
        elif key == "WPos":
            work_position = parse_float_tuple(value)
        elif key == "FS":
            feed_spindle = parse_float_tuple(value)

    return StatusReport(
        state=state,
        machine_position=machine_position,
        work_position=work_position,
        feed_spindle=feed_spindle,
        fields=fields,
    )


def parse_setting_line(line: str) -> Setting | None:
    match = SETTING_RE.match(line.strip())
    if match is None:
        return None
    return Setting(number=int(match.group("number")), value=match.group("value"))


def parse_bracket_line(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if not (stripped.startswith("[") and stripped.endswith("]")):
        return None
    inner = stripped[1:-1]
    if ":" not in inner:
        return inner, ""
    key, value = inner.split(":", 1)
    return key, value


def parse_response_line(line: str) -> ParsedLine:
    stripped = line.strip()
    lower = stripped.lower()
    if lower == "ok":
        return ParsedLine(kind="ok", raw=stripped)
    if lower.startswith("error:"):
        return ParsedLine(kind="error", raw=stripped, data={"code": stripped.split(":", 1)[1]})
    if lower.startswith("alarm:"):
        return ParsedLine(kind="alarm", raw=stripped, data={"code": stripped.split(":", 1)[1]})
    if stripped.startswith("<") and stripped.endswith(">"):
        return ParsedLine(kind="status", raw=stripped, data=parse_status_report(stripped).model_dump())

    setting = parse_setting_line(stripped)
    if setting is not None:
        return ParsedLine(kind="setting", raw=stripped, data=setting.model_dump())

    bracket = parse_bracket_line(stripped)
    if bracket is not None:
        key, value = bracket
        return ParsedLine(kind="bracket", raw=stripped, data={"key": key, "value": value})

    return ParsedLine(kind="text", raw=stripped)
