from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, Field

from plotter_vision.config import SafetyState
from plotter_vision.controller.base import utc_now_iso


class SettingsWriteError(ValueError):
    """Raised when a controller settings write is outside the allowed gate."""


class SettingsWritePlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    x_steps_per_mm: float
    y_steps_per_mm: float
    commands: list[str]
    note: str = "Plan only until applied with explicit settings-write arming."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


class HomingXYSettingsPlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    limit_invert_mask: int
    homing_cycle_1: int
    homing_cycle_2: int
    commands: list[str]
    note: str = "XY homing setup only; no homing command is run by this plan."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


class HardLimitsSettingsPlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    enabled: bool
    commands: list[str]
    note: str = "Hard-limit setting only; no homing or motion command is run by this plan."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


class XMaxTravelSettingsPlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    x_max_travel_mm: float
    commands: list[str]
    note: str = "X max-travel setting only; no homing or motion command is run by this plan."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


class HomingTuningSettingsPlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    pull_off_mm: float
    x_max_travel_mm: float
    commands: list[str]
    note: str = "Homing tuning settings only; no homing or motion command is run by this plan."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


class WorkspaceTravelSettingsPlan(BaseModel):
    created_at: str = Field(default_factory=utc_now_iso)
    x_max_travel_mm: float
    y_max_travel_mm: float
    commands: list[str]
    note: str = "Workspace travel settings only; no homing or motion command is run by this plan."

    def save_json(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.model_dump_json(indent=2) + "\n", encoding="utf-8")


def build_xy_steps_plan(*, x_steps_per_mm: float, y_steps_per_mm: float) -> SettingsWritePlan:
    x = validate_steps_value(x_steps_per_mm)
    y = validate_steps_value(y_steps_per_mm)
    return SettingsWritePlan(
        x_steps_per_mm=x,
        y_steps_per_mm=y,
        commands=[f"$100={x:.5f}", f"$101={y:.5f}"],
    )


def validate_steps_value(value: float) -> float:
    if value <= 0:
        raise SettingsWriteError("Steps/mm must be positive.")
    if value > 1000:
        raise SettingsWriteError("Steps/mm value is unexpectedly high for this workflow.")
    return value


def validate_settings_write_plan(
    plan: SettingsWritePlan,
    safety: SafetyState,
) -> SettingsWritePlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("Settings writes require allow_settings_write=true.")
    expected = build_xy_steps_plan(
        x_steps_per_mm=plan.x_steps_per_mm,
        y_steps_per_mm=plan.y_steps_per_mm,
    )
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only $100 and $101 writes.")
    return expected


def build_xy_homing_settings_plan() -> HomingXYSettingsPlan:
    return HomingXYSettingsPlan(
        limit_invert_mask=7,
        homing_cycle_1=3,
        homing_cycle_2=0,
        commands=["$5=7", "$44=3", "$45=0"],
    )


def build_hard_limits_settings_plan(*, enabled: bool) -> HardLimitsSettingsPlan:
    return HardLimitsSettingsPlan(enabled=enabled, commands=[f"$21={1 if enabled else 0}"])


def build_x_max_travel_settings_plan(*, x_max_travel_mm: float) -> XMaxTravelSettingsPlan:
    if x_max_travel_mm < 200:
        raise SettingsWriteError("X max travel must be at least 200 mm for this workflow.")
    if x_max_travel_mm > 600:
        raise SettingsWriteError("X max travel is unexpectedly high for this workflow.")
    return XMaxTravelSettingsPlan(
        x_max_travel_mm=x_max_travel_mm,
        commands=[f"$130={x_max_travel_mm:.3f}"],
    )


def build_homing_tuning_settings_plan(
    *,
    pull_off_mm: float = 5.0,
    x_max_travel_mm: float = 400.0,
) -> HomingTuningSettingsPlan:
    if pull_off_mm < 1:
        raise SettingsWriteError("Homing pull-off must be at least 1 mm.")
    if pull_off_mm > 20:
        raise SettingsWriteError("Homing pull-off is unexpectedly high for this workflow.")
    if x_max_travel_mm < 200:
        raise SettingsWriteError("X max travel must be at least 200 mm for this workflow.")
    if x_max_travel_mm > 600:
        raise SettingsWriteError("X max travel is unexpectedly high for this workflow.")
    return HomingTuningSettingsPlan(
        pull_off_mm=pull_off_mm,
        x_max_travel_mm=x_max_travel_mm,
        commands=[f"$27={pull_off_mm:.3f}", f"$130={x_max_travel_mm:.3f}"],
    )


def build_workspace_travel_settings_plan(
    *,
    x_max_travel_mm: float,
    y_max_travel_mm: float,
) -> WorkspaceTravelSettingsPlan:
    x = validate_travel_value(x_max_travel_mm)
    y = validate_travel_value(y_max_travel_mm)
    return WorkspaceTravelSettingsPlan(
        x_max_travel_mm=x,
        y_max_travel_mm=y,
        commands=[f"$130={x:.3f}", f"$131={y:.3f}"],
    )


def validate_travel_value(value: float) -> float:
    if value <= 0:
        raise SettingsWriteError("Travel value must be positive.")
    if value > 1000:
        raise SettingsWriteError("Travel value is unexpectedly high for this workflow.")
    return value


def validate_xy_homing_settings_plan(
    plan: HomingXYSettingsPlan,
    safety: SafetyState,
) -> HomingXYSettingsPlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("Homing settings writes require allow_settings_write=true.")
    expected = build_xy_homing_settings_plan()
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only $5=7, $44=3, and $45=0.")
    return expected


def validate_hard_limits_settings_plan(
    plan: HardLimitsSettingsPlan,
    safety: SafetyState,
) -> HardLimitsSettingsPlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("Hard-limit settings writes require allow_settings_write=true.")
    expected = build_hard_limits_settings_plan(enabled=plan.enabled)
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only the expected $21 write.")
    return expected


def validate_x_max_travel_settings_plan(
    plan: XMaxTravelSettingsPlan,
    safety: SafetyState,
) -> XMaxTravelSettingsPlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("X max-travel settings writes require allow_settings_write=true.")
    expected = build_x_max_travel_settings_plan(x_max_travel_mm=plan.x_max_travel_mm)
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only the expected $130 write.")
    return expected


def validate_homing_tuning_settings_plan(
    plan: HomingTuningSettingsPlan,
    safety: SafetyState,
) -> HomingTuningSettingsPlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("Homing tuning settings writes require allow_settings_write=true.")
    expected = build_homing_tuning_settings_plan(
        pull_off_mm=plan.pull_off_mm,
        x_max_travel_mm=plan.x_max_travel_mm,
    )
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only the expected $27 and $130 writes.")
    return expected


def validate_workspace_travel_settings_plan(
    plan: WorkspaceTravelSettingsPlan,
    safety: SafetyState,
) -> WorkspaceTravelSettingsPlan:
    if not safety.allow_settings_write:
        raise SettingsWriteError("Workspace travel settings writes require allow_settings_write=true.")
    expected = build_workspace_travel_settings_plan(
        x_max_travel_mm=plan.x_max_travel_mm,
        y_max_travel_mm=plan.y_max_travel_mm,
    )
    if plan.commands != expected.commands:
        raise SettingsWriteError("Plan commands must contain only the expected $130 and $131 writes.")
    return expected


def validate_hard_limits_apply_status(
    *,
    enabled: bool,
    state: str,
    pins: str,
) -> None:
    normalized_state = state.lower()
    normalized_pins = pins.upper()
    if enabled:
        validate_xy_homing_apply_status(state=state, pins=pins)
        return
    if normalized_state == "idle":
        return
    if normalized_state == "alarm" and set(normalized_pins).issubset({"X", "Y", "Z"}):
        return
    raise SettingsWriteError(
        "Disabling hard limits requires Idle or Alarm with only limit pins reported."
    )


def validate_xy_homing_apply_status(*, state: str, pins: str) -> None:
    normalized_state = state.lower()
    normalized_pins = pins.upper()
    if normalized_state == "idle":
        return
    if normalized_state == "alarm" and normalized_pins in {"", "Z"}:
        return
    raise SettingsWriteError(
        "XY homing settings require Idle, Alarm with no active pins, "
        "or Alarm with only the unused Z input reported."
    )
