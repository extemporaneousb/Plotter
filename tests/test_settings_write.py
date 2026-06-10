from __future__ import annotations

import pytest

from plotter_vision.config import SafetyState
from plotter_vision.machine.settings import (
    HardLimitsSettingsPlan,
    HomingTuningSettingsPlan,
    HomingXYSettingsPlan,
    SettingsWriteError,
    SettingsWritePlan,
    WorkspaceTravelSettingsPlan,
    build_hard_limits_settings_plan,
    build_homing_tuning_settings_plan,
    build_workspace_travel_settings_plan,
    build_xy_homing_settings_plan,
    build_xy_steps_plan,
    validate_hard_limits_apply_status,
    validate_hard_limits_settings_plan,
    validate_homing_tuning_settings_plan,
    validate_settings_write_plan,
    validate_workspace_travel_settings_plan,
    validate_xy_homing_apply_status,
    validate_xy_homing_settings_plan,
)


def test_build_xy_steps_plan_only_contains_100_and_101() -> None:
    plan = build_xy_steps_plan(x_steps_per_mm=39.86843, y_steps_per_mm=35.79098)

    assert plan.commands == ["$100=39.86843", "$101=35.79098"]
    assert plan.x_steps_per_mm == 39.86843
    assert plan.y_steps_per_mm == 35.79098


def test_settings_plan_requires_explicit_arm() -> None:
    plan = build_xy_steps_plan(x_steps_per_mm=39.86843, y_steps_per_mm=35.79098)

    with pytest.raises(SettingsWriteError, match="allow_settings_write"):
        validate_settings_write_plan(plan, SafetyState(allow_settings_write=False))


def test_settings_plan_accepts_explicit_arm() -> None:
    plan = build_xy_steps_plan(x_steps_per_mm=39.86843, y_steps_per_mm=35.79098)

    validated = validate_settings_write_plan(plan, SafetyState(allow_settings_write=True))

    assert validated.commands == ["$100=39.86843", "$101=35.79098"]


@pytest.mark.parametrize("value", [0.0, -1.0, 1001.0])
def test_settings_plan_rejects_invalid_steps_values(value: float) -> None:
    with pytest.raises(SettingsWriteError):
        build_xy_steps_plan(x_steps_per_mm=value, y_steps_per_mm=35.79098)


def test_settings_plan_rejects_tampered_commands() -> None:
    plan = SettingsWritePlan(
        x_steps_per_mm=39.86843,
        y_steps_per_mm=35.79098,
        commands=["$100=39.86843", "$102=35.79098"],
    )

    with pytest.raises(SettingsWriteError, match="only \\$100 and \\$101"):
        validate_settings_write_plan(plan, SafetyState(allow_settings_write=True))


def test_build_xy_homing_settings_plan_only_contains_observed_limit_fix() -> None:
    plan = build_xy_homing_settings_plan()

    assert plan.limit_invert_mask == 7
    assert plan.homing_cycle_1 == 3
    assert plan.homing_cycle_2 == 0
    assert plan.commands == ["$5=7", "$44=3", "$45=0"]


def test_xy_homing_settings_plan_requires_explicit_arm() -> None:
    plan = build_xy_homing_settings_plan()

    with pytest.raises(SettingsWriteError, match="allow_settings_write"):
        validate_xy_homing_settings_plan(plan, SafetyState(allow_settings_write=False))


def test_xy_homing_settings_plan_accepts_explicit_arm() -> None:
    plan = build_xy_homing_settings_plan()

    validated = validate_xy_homing_settings_plan(plan, SafetyState(allow_settings_write=True))

    assert validated.commands == ["$5=7", "$44=3", "$45=0"]


def test_xy_homing_settings_plan_rejects_tampered_commands() -> None:
    plan = HomingXYSettingsPlan(
        limit_invert_mask=7,
        homing_cycle_1=3,
        homing_cycle_2=0,
        commands=["$5=7", "$44=3", "$45=0", "$H"],
    )

    with pytest.raises(SettingsWriteError, match="only \\$5=7, \\$44=3, and \\$45=0"):
        validate_xy_homing_settings_plan(plan, SafetyState(allow_settings_write=True))


@pytest.mark.parametrize(
    ("state", "pins"),
    [
        ("Idle", ""),
        ("Idle", "Z"),
        ("Alarm", ""),
        ("Alarm", "Z"),
    ],
)
def test_xy_homing_apply_status_allows_idle_or_alarm_with_no_pins_or_only_z(
    state: str,
    pins: str,
) -> None:
    validate_xy_homing_apply_status(state=state, pins=pins)


@pytest.mark.parametrize(
    ("state", "pins"),
    [
        ("Alarm", "X"),
        ("Alarm", "Y"),
        ("Alarm", "XZ"),
        ("Alarm", "YZ"),
        ("Run", ""),
    ],
)
def test_xy_homing_apply_status_blocks_pressed_xy_or_non_idle_motion(
    state: str,
    pins: str,
) -> None:
    with pytest.raises(SettingsWriteError, match="Alarm with no active pins"):
        validate_xy_homing_apply_status(state=state, pins=pins)


@pytest.mark.parametrize(("enabled", "command"), [(False, "$21=0"), (True, "$21=1")])
def test_build_hard_limits_settings_plan_only_contains_21(enabled: bool, command: str) -> None:
    plan = build_hard_limits_settings_plan(enabled=enabled)

    assert plan.enabled is enabled
    assert plan.commands == [command]


def test_hard_limits_settings_plan_requires_explicit_arm() -> None:
    plan = build_hard_limits_settings_plan(enabled=False)

    with pytest.raises(SettingsWriteError, match="allow_settings_write"):
        validate_hard_limits_settings_plan(plan, SafetyState(allow_settings_write=False))


def test_hard_limits_settings_plan_rejects_tampered_commands() -> None:
    plan = HardLimitsSettingsPlan(enabled=False, commands=["$21=0", "$H"])

    with pytest.raises(SettingsWriteError, match="only the expected \\$21"):
        validate_hard_limits_settings_plan(plan, SafetyState(allow_settings_write=True))


@pytest.mark.parametrize("pins", ["", "X", "Y", "XY", "YZ"])
def test_hard_limits_off_apply_status_allows_limit_alarm_recovery(pins: str) -> None:
    validate_hard_limits_apply_status(enabled=False, state="Alarm", pins=pins)


def test_hard_limits_on_apply_status_blocks_active_limit_pin() -> None:
    with pytest.raises(SettingsWriteError, match="Alarm with no active pins"):
        validate_hard_limits_apply_status(enabled=True, state="Alarm", pins="Y")


def test_build_homing_tuning_settings_plan_only_contains_27_and_130() -> None:
    plan = build_homing_tuning_settings_plan(pull_off_mm=10, x_max_travel_mm=400)

    assert plan.commands == ["$27=10.000", "$130=400.000"]


def test_homing_tuning_settings_plan_requires_explicit_arm() -> None:
    plan = build_homing_tuning_settings_plan(pull_off_mm=10, x_max_travel_mm=400)

    with pytest.raises(SettingsWriteError, match="allow_settings_write"):
        validate_homing_tuning_settings_plan(plan, SafetyState(allow_settings_write=False))


def test_homing_tuning_settings_plan_rejects_tampered_commands() -> None:
    plan = HomingTuningSettingsPlan(
        pull_off_mm=10,
        x_max_travel_mm=400,
        commands=["$27=10.000", "$130=400.000", "$H"],
    )

    with pytest.raises(SettingsWriteError, match="only the expected \\$27 and \\$130"):
        validate_homing_tuning_settings_plan(plan, SafetyState(allow_settings_write=True))


def test_build_workspace_travel_settings_plan_only_contains_130_and_131() -> None:
    plan = build_workspace_travel_settings_plan(
        x_max_travel_mm=533.4,
        y_max_travel_mm=215.9,
    )

    assert plan.commands == ["$130=533.400", "$131=215.900"]


def test_workspace_travel_settings_plan_requires_explicit_arm() -> None:
    plan = build_workspace_travel_settings_plan(
        x_max_travel_mm=533.4,
        y_max_travel_mm=215.9,
    )

    with pytest.raises(SettingsWriteError, match="allow_settings_write"):
        validate_workspace_travel_settings_plan(plan, SafetyState(allow_settings_write=False))


def test_workspace_travel_settings_plan_rejects_tampered_commands() -> None:
    plan = WorkspaceTravelSettingsPlan(
        x_max_travel_mm=533.4,
        y_max_travel_mm=215.9,
        commands=["$130=533.400", "$132=215.900"],
    )

    with pytest.raises(SettingsWriteError, match="only the expected \\$130 and \\$131"):
        validate_workspace_travel_settings_plan(plan, SafetyState(allow_settings_write=True))
