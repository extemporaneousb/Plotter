from __future__ import annotations

import uuid
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

from plotter_vision.calibration.vision_model import (
    LogicalPointMM,
    MachinePointMM,
    VisionCalibrationObservation,
    VisionMachineModel,
)
from plotter_vision.config import MachineConfig
from plotter_vision.controller.base import utc_now_iso
from plotter_vision.motion.gcode import format_mm

CalibrationSessionStatus = Literal[
    "planned",
    "awaiting_observations",
    "solved",
    "failed",
]


class CalibrationWaypoint(BaseModel):
    point_id: str
    role: str = "pen_tip_waypoint"
    logical_mm: LogicalPointMM
    machine_mm: MachinePointMM
    observed: bool = False


class CalibrationSession(BaseModel):
    session_id: str = Field(default_factory=lambda: f"cal-{uuid.uuid4().hex[:12]}")
    created_at: str = Field(default_factory=utc_now_iso)
    updated_at: str = Field(default_factory=utc_now_iso)
    status: CalibrationSessionStatus = "planned"
    waypoints: list[CalibrationWaypoint]
    planned_commands: list[str]
    model: VisionMachineModel = Field(default_factory=VisionMachineModel)

    def add_observation(self, observation: VisionCalibrationObservation) -> None:
        self.model.add_observation(observation)
        for waypoint in self.waypoints:
            if waypoint.point_id == observation.point_id:
                waypoint.observed = True
                break
        if self.observed_count >= 3:
            self.model.solve()
            self.status = "solved"
        else:
            self.status = "awaiting_observations"
        self.updated_at = utc_now_iso()

    @property
    def observed_count(self) -> int:
        return sum(1 for waypoint in self.waypoints if waypoint.observed)

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


def build_calibration_session(
    *,
    machine: MachineConfig,
    margin_mm: float = 25.0,
    travel_feed_mm_min: float = 500.0,
    include_homing: bool = True,
) -> CalibrationSession:
    logical_points = build_logical_calibration_points(machine=machine, margin_mm=margin_mm)
    waypoints: list[CalibrationWaypoint] = []
    for index, logical in enumerate(logical_points):
        machine_x, machine_y = machine.logical_to_machine(x_mm=logical.x, y_mm=logical.y)
        waypoints.append(
            CalibrationWaypoint(
                point_id=f"P{index:02d}",
                logical_mm=logical,
                machine_mm=MachinePointMM(x=machine_x, y=machine_y),
            )
        )

    commands: list[str] = []
    if include_homing:
        commands.append("$H")
    commands.extend(["G21", "G90", "G94", f"G1 F{format_mm(travel_feed_mm_min)}"])
    for waypoint in waypoints:
        commands.append(
            f"G53 G1 X{format_mm(waypoint.machine_mm.x)} Y{format_mm(waypoint.machine_mm.y)}"
        )

    return CalibrationSession(
        status="awaiting_observations",
        waypoints=waypoints,
        planned_commands=commands,
    )


def build_logical_calibration_points(
    *,
    machine: MachineConfig,
    margin_mm: float,
) -> list[LogicalPointMM]:
    x_min = max(0.0, margin_mm)
    y_min = max(0.0, margin_mm)
    x_max = max(x_min, machine.axes.x.travel_mm - margin_mm)
    y_max = max(y_min, machine.axes.y.travel_mm - margin_mm)
    center_x, center_y = machine.logical_center_mm()
    return [
        LogicalPointMM(x=center_x, y=center_y),
        LogicalPointMM(x=x_min, y=y_min),
        LogicalPointMM(x=x_max, y=y_min),
        LogicalPointMM(x=x_max, y=y_max),
        LogicalPointMM(x=x_min, y=y_max),
    ]
