from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import TYPE_CHECKING, Literal, Protocol

from pydantic import BaseModel, Field

if TYPE_CHECKING:
    from plotter_vision.controller.parser import StatusReport
    from plotter_vision.controller.snapshot import ControllerSnapshot


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class CommandLogEvent(BaseModel):
    timestamp: str = Field(default_factory=utc_now_iso)
    direction: Literal["TX", "RX"]
    payload: str
    source: str = "controller_probe"


class CommandResult(BaseModel):
    command: str
    responses: list[str]
    ok: bool = True
    error_line: str | None = None


class ControllerTransport(Protocol):
    description: str

    def connect(self) -> None: ...

    def disconnect(self) -> None: ...

    def write_line(self, line: str) -> None: ...

    def write_realtime(self, data: bytes) -> None: ...

    def read_line(self, timeout_s: float) -> str | None: ...


class MotionController(Protocol):
    def probe(self, *, transcript_path: Path | None = None) -> "ControllerSnapshot": ...

    def send_command(
        self,
        command: str,
        *,
        timeout_s: float = 10.0,
        raise_on_error: bool = True,
    ) -> CommandResult: ...

    def query_status_report(self, *, timeout_s: float = 2.0) -> "StatusReport": ...
