from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, Field

from plotter_vision.controller.base import utc_now_iso
from plotter_vision.controller.parser import StatusReport


class ControllerSnapshot(BaseModel):
    timestamp: str = Field(default_factory=utc_now_iso)
    transport: str
    firmware_identity: list[str] = Field(default_factory=list)
    parser_modal_state: list[str] = Field(default_factory=list)
    status_report: StatusReport | None = None
    settings: dict[str, str] = Field(default_factory=dict)
    coordinate_parameters: dict[str, str] = Field(default_factory=dict)
    raw_transcript_file: str | None = None
    parser_warnings: list[str] = Field(default_factory=list)

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")
