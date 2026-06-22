from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field


class SafetyState(BaseModel):
    dry_run: bool = True
    armed_motion: bool = False
    allow_settings_write: bool = False
    allow_homing: bool = False
    allow_unlock: bool = False
    allow_pen_actuation: bool = False


class WorkspaceConfig(BaseModel):
    x_min: float = 0.0
    x_max: float = 300.0
    y_min: float = 0.0
    y_max: float = 300.0


AxisEnd = Literal["min", "max"]


class AxisConfig(BaseModel):
    travel_mm: float = 300.0
    homing_switch_end: AxisEnd = "max"
    logical_zero_end: AxisEnd = "min"

    def logical_to_machine(self, logical_mm: float) -> float:
        if logical_mm < 0 or logical_mm > self.travel_mm:
            raise ValueError(
                f"logical coordinate {logical_mm:.3f} mm is outside axis travel "
                f"[0.000, {self.travel_mm:.3f}]."
            )

        physical_from_min = (
            logical_mm
            if self.logical_zero_end == "min"
            else self.travel_mm - logical_mm
        )
        return (
            physical_from_min
            if self.homing_switch_end == "min"
            else physical_from_min - self.travel_mm
        )

    def machine_to_logical(self, machine_mm: float) -> float:
        physical_from_min = (
            machine_mm
            if self.homing_switch_end == "min"
            else machine_mm + self.travel_mm
        )
        return (
            physical_from_min
            if self.logical_zero_end == "min"
            else self.travel_mm - physical_from_min
        )

    @property
    def logical_center_mm(self) -> float:
        return self.travel_mm / 2


class AxesConfig(BaseModel):
    x: AxisConfig = Field(default_factory=AxisConfig)
    y: AxisConfig = Field(default_factory=AxisConfig)


class PenConfig(BaseModel):
    up_command: str | None = None
    down_command: str | None = None
    settle_s: float = 0.3


class MachineConfig(BaseModel):
    units: str = "mm"
    axes: AxesConfig = Field(default_factory=AxesConfig)
    workspace: WorkspaceConfig = Field(default_factory=WorkspaceConfig)
    max_feed_mm_min: float = 1200.0
    max_jog_mm: float = 50.0
    max_calibration_line_mm: float = 50.0
    homing_trusted: bool = False
    axis_model_trusted: bool = False
    pen: PenConfig = Field(default_factory=PenConfig)

    def set_axis_travel(self, *, x_travel_mm: float, y_travel_mm: float) -> None:
        self.axes.x.travel_mm = x_travel_mm
        self.axes.y.travel_mm = y_travel_mm
        self.workspace.x_min = 0.0
        self.workspace.x_max = x_travel_mm
        self.workspace.y_min = 0.0
        self.workspace.y_max = y_travel_mm

    def logical_center_mm(self) -> tuple[float, float]:
        return (self.axes.x.logical_center_mm, self.axes.y.logical_center_mm)

    def logical_to_machine(self, *, x_mm: float, y_mm: float) -> tuple[float, float]:
        return (
            self.axes.x.logical_to_machine(x_mm),
            self.axes.y.logical_to_machine(y_mm),
        )

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")
