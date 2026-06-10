from __future__ import annotations

from plotter_vision.cli import save_pen_config
from plotter_vision.config import MachineConfig


def test_save_pen_config_preserves_existing_machine_geometry_and_homing(tmp_path) -> None:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.homing_trusted = True
    machine.axis_model_trusted = True
    machine.save_json(config_path)

    save_pen_config(
        up_command="M3 S40",
        down_command="M3 S720",
        out=config_path,
    )

    saved = MachineConfig.model_validate_json(config_path.read_text(encoding="utf-8"))
    assert saved.axes.x.travel_mm == 533.4
    assert saved.axes.y.travel_mm == 215.9
    assert saved.homing_trusted is True
    assert saved.axis_model_trusted is True
    assert saved.pen.up_command == "M3 S40"
    assert saved.pen.down_command == "M3 S720"
