from __future__ import annotations

import time
from pathlib import Path
from typing import Annotated

import typer

from plotter_vision.calibration.scale import build_scale_observation
from plotter_vision.bridge.server import BridgeRuntimeConfig, serve_bridge
from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.mock import MockTransport
from plotter_vision.controller.parser import ControllerError
from plotter_vision.controller.serial_transport import DEFAULT_BAUD, SerialTransport, list_serial_ports
from plotter_vision.config import MachineConfig, SafetyState
from plotter_vision.machine.homing import validate_homing_request
from plotter_vision.machine.pen import validate_pen_trial_command
from plotter_vision.machine.safety import validate_calibration_line_request, validate_jog_request
from plotter_vision.machine.settings import (
    HardLimitsSettingsPlan,
    HomingTuningSettingsPlan,
    HomingXYSettingsPlan,
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
from plotter_vision.motion.gcode import (
    build_parallel_line_motion_commands,
    build_relative_jog_commands,
)

app = typer.Typer(help="Safe controller interrogation tools for the pen plotter.")


@app.command("bridge-server")
def bridge_server(
    host: Annotated[str, typer.Option(help="Local HTTP host for the bridge")] = "127.0.0.1",
    http_port: Annotated[int, typer.Option("--http-port", help="Local HTTP bridge port")] = 8765,
    controller_port: Annotated[
        str | None,
        typer.Option("--controller-port", help="USB serial port, usually /dev/cu.*"),
    ] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller for live bridge runs")] = False,
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview bridge plans without sending motion"),
    ] = True,
    arm_motion: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real motion commands are sent"),
    ] = False,
    arm_pen: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real pen commands are sent"),
    ] = False,
    arm_homing: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real homing is sent"),
    ] = False,
    arm_unlock: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before UI alarm unlock is allowed"),
    ] = False,
    config_path: Annotated[
        Path,
        typer.Option(help="Machine config JSON containing pen commands"),
    ] = Path("artifacts/machine_config.json"),
    event_log: Annotated[
        Path,
        typer.Option(help="Append-only bridge event JSONL path"),
    ] = Path("artifacts/bridge_events.jsonl"),
    transcript_dir: Annotated[
        Path,
        typer.Option(help="Directory for per-command controller transcripts"),
    ] = Path("artifacts/bridge_transcripts"),
    calibration_dir: Annotated[
        Path,
        typer.Option(help="Directory for persisted calibration sessions and machine models"),
    ] = Path("artifacts/calibration_sessions"),
    workspace_x_max: Annotated[
        float | None,
        typer.Option(help="Override configured workspace X max in mm"),
    ] = None,
    workspace_y_max: Annotated[
        float | None,
        typer.Option(help="Override configured workspace Y max in mm"),
    ] = None,
) -> None:
    """Run the local controller bridge for the native camera app."""
    if http_port < 1 or http_port > 65535:
        raise typer.BadParameter("http_port must be between 1 and 65535.")
    if not dry_run and not mock and controller_port is None:
        raise typer.BadParameter("Real bridge runs require --controller-port or --mock.")
    if not dry_run and not (arm_motion and arm_pen and arm_homing):
        raise typer.BadParameter(
            "Real bridge runs require --arm-motion, --arm-pen, --arm-homing, and --no-dry-run."
        )

    serve_bridge(
        BridgeRuntimeConfig(
            host=host,
            http_port=http_port,
            dry_run=dry_run,
            mock=mock,
            controller_port=controller_port,
            baud=baud,
            arm_motion=arm_motion,
            arm_pen=arm_pen,
            arm_homing=arm_homing,
            arm_unlock=arm_unlock,
            config_path=config_path,
            event_log_path=event_log,
            transcript_dir=transcript_dir,
            calibration_dir=calibration_dir,
            workspace_x_max=workspace_x_max,
            workspace_y_max=workspace_y_max,
        )
    )


def _make_controller(
    *,
    mock: bool,
    port: str | None,
    baud: int,
    transcript: Path | None,
) -> GrblHalController:
    if mock:
        return GrblHalController(MockTransport(), transcript_path=transcript)
    if port is None:
        raise typer.BadParameter("Provide --port /dev/cu.usbmodemXXXX or use --mock.")
    return GrblHalController(SerialTransport(port=port, baud=baud), transcript_path=transcript)


@app.command()
def ports() -> None:
    """List serial ports visible to macOS."""
    found = list_serial_ports()
    if not found:
        typer.echo("No serial ports found.")
        return
    for port in found:
        typer.echo(f"{port.device}\t{port.description}\t{port.hwid}")


@app.command()
def probe(
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/controller_transcript.jsonl"),
) -> None:
    """Run passive interrogation and print a parsed snapshot."""
    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        snapshot = controller.probe()
    typer.echo(snapshot.model_dump_json(indent=2))


@app.command()
def snapshot(
    out: Annotated[Path, typer.Option(help="Snapshot JSON output path")],
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/controller_transcript.jsonl"),
) -> None:
    """Run passive interrogation and save a controller snapshot."""
    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller_snapshot = controller.probe()
    controller_snapshot.save_json(out)
    typer.echo(f"Wrote snapshot: {out}")
    typer.echo(f"Wrote transcript: {transcript}")


@app.command()
def status(
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    count: Annotated[int, typer.Option(help="Number of status samples to read")] = 1,
    interval_s: Annotated[float, typer.Option(help="Delay between status samples")] = 0.25,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/status_transcript.jsonl"),
) -> None:
    """Read realtime status reports. No motion or settings writes."""
    if count < 1 or count > 500:
        raise typer.BadParameter("count must be between 1 and 500.")
    if interval_s < 0 or interval_s > 10:
        raise typer.BadParameter("interval_s must be between 0 and 10 seconds.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        for index in range(count):
            try:
                report = controller.query_status_report()
            except ControllerError as exc:
                typer.echo(f"{index + 1:03d} controller_error={exc}")
                typer.echo("Stop: release any pressed switch before unlocking.")
                break
            pins = report.fields.get("Pn", "")
            mpos = report.fields.get("MPos", "")
            feed_spindle = report.fields.get("FS", "")
            typer.echo(
                f"{index + 1:03d} state={report.state} "
                f"MPos={mpos or '-'} FS={feed_spindle or '-'} Pn={pins or '-'}"
            )
            if index < count - 1:
                time.sleep(interval_s)
        controller.flush_transcript()
    typer.echo(f"Wrote transcript: {transcript}")


@app.command()
def unlock(
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    arm_unlock: Annotated[
        bool,
        typer.Option(help="Required before $X alarm unlock is sent"),
    ] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/unlock_transcript.jsonl"),
) -> None:
    """Explicitly send $X after an alarm. No motion, homing, or settings writes."""
    if not arm_unlock:
        raise typer.BadParameter("Unlock requires --arm-unlock.")
    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        try:
            controller.unlock()
        except ControllerError as exc:
            typer.echo(f"Unlock failed: {exc}")
            typer.echo("Release all switches, then try soft-reset before unlocking again.")
            controller.flush_transcript()
            return
        try:
            report = controller.query_status_report()
            typer.echo(
                f"state={report.state} MPos={report.fields.get('MPos', '-') or '-'} "
                f"Pn={report.fields.get('Pn', '-') or '-'}"
            )
        except ControllerError as exc:
            typer.echo(f"Unlock command sent, but status still reports: {exc}")
        controller.flush_transcript()
    typer.echo(f"Wrote transcript: {transcript}")


@app.command("soft-reset")
def soft_reset(
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    arm_reset: Annotated[
        bool,
        typer.Option(help="Required before Ctrl-X soft reset is sent"),
    ] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/soft_reset_transcript.jsonl"),
) -> None:
    """Explicitly send Ctrl-X soft reset. No motion, homing, or settings writes."""
    if not arm_reset:
        raise typer.BadParameter("Soft reset requires --arm-reset.")
    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        drained = controller.soft_reset(drain_s=2.0)
        for line in drained:
            typer.echo(line)
        try:
            report = controller.query_status_report()
            typer.echo(
                f"state={report.state} MPos={report.fields.get('MPos', '-') or '-'} "
                f"Pn={report.fields.get('Pn', '-') or '-'}"
            )
        except ControllerError as exc:
            typer.echo(f"Soft reset sent, but status still reports: {exc}")
        controller.flush_transcript()
    typer.echo(f"Wrote transcript: {transcript}")


@app.command("home-xy")
def home_xy(
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview homing without sending $H"),
    ] = True,
    arm_homing: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before $H is sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/home_xy_transcript.jsonl"),
) -> None:
    """Preview or run the configured XY homing cycle."""
    command = "$H"
    typer.echo("Planned homing command:")
    typer.echo(command)
    typer.echo("This is real machine motion when run with --no-dry-run and --arm-homing.")
    if dry_run:
        typer.echo("Dry run only; no homing command was sent.")
        return

    safety = SafetyState(dry_run=dry_run, allow_homing=arm_homing)
    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        validate_homing_request(
            state=status.state,
            pins=status.fields.get("Pn", ""),
            safety=safety,
        )
        controller.send_validated_command(command, timeout_s=180.0)
        report = controller.query_status_report()
        typer.echo(
            f"state={report.state} MPos={report.fields.get('MPos', '-') or '-'} "
            f"Pn={report.fields.get('Pn', '-') or '-'}"
        )
        controller.flush_transcript()
    typer.echo(f"Wrote transcript: {transcript}")


@app.command()
def jog(
    axis: Annotated[str, typer.Option(help="Axis to jog: X or Y")] = "X",
    distance: Annotated[float, typer.Option(help="Relative jog distance in mm")] = 1.0,
    feed: Annotated[float, typer.Option(help="Feed rate in mm/min")] = 60.0,
    return_to_start: Annotated[
        bool,
        typer.Option(help="Queue the reverse move after the first jog"),
    ] = False,
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview commands without sending motion"),
    ] = True,
    arm_motion: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real motion is sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/jog_transcript.jsonl"),
) -> None:
    """Preview or run a tightly gated relative jog."""
    machine = MachineConfig()
    safety = SafetyState(dry_run=dry_run, armed_motion=arm_motion)
    normalized_axis = validate_jog_request(
        axis=axis,
        distance_mm=distance,
        feed_mm_min=feed,
        machine=machine,
        safety=safety,
    )
    commands = build_relative_jog_commands(
        axis=normalized_axis,
        distance_mm=distance,
        feed_mm_min=feed,
        return_to_start=return_to_start,
    )

    typer.echo("Planned commands:")
    for command in commands:
        typer.echo(command)

    if dry_run:
        typer.echo("Dry run only; no commands were sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before jog; got {status.state!r}.")
        for command in commands:
            controller.send_validated_command(command)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Jog commands sent. Wrote transcript: {transcript}")


@app.command("draw-line")
def draw_line(
    axis: Annotated[str, typer.Option(help="Axis to draw along: X or Y")] = "X",
    distance: Annotated[float, typer.Option(help="Relative line distance in mm")] = 20.0,
    feed: Annotated[float, typer.Option(help="Feed rate in mm/min")] = 120.0,
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview commands without sending motion"),
    ] = True,
    arm_motion: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real motion is sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/draw_line_transcript.jsonl"),
) -> None:
    """Draw one relative line. Pen actuation is manual; no pen commands are sent."""
    machine = MachineConfig()
    safety = SafetyState(dry_run=dry_run, armed_motion=arm_motion)
    normalized_axis = validate_calibration_line_request(
        axis=axis,
        distance_mm=distance,
        feed_mm_min=feed,
        machine=machine,
        safety=safety,
    )
    commands = build_relative_jog_commands(
        axis=normalized_axis,
        distance_mm=distance,
        feed_mm_min=feed,
        return_to_start=False,
    )

    typer.echo("Planned commands:")
    for command in commands:
        typer.echo(command)
    typer.echo("Pen actuation is manual; no pen up/down commands are included.")

    if dry_run:
        typer.echo("Dry run only; no commands were sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before line draw; got {status.state!r}.")
        for command in commands:
            controller.send_validated_command(command)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Line commands sent. Wrote transcript: {transcript}")


@app.command("pen-trial")
def pen_trial(
    command: Annotated[str, typer.Option(help="Explicit pen M-code, e.g. 'M3 S1000'")],
    label: Annotated[str, typer.Option(help="Operator label for this trial")] = "pen",
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview command without sending it"),
    ] = True,
    arm_pen: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before pen command is sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/pen_trial_transcript.jsonl"),
) -> None:
    """Preview or send one explicitly supplied pen command."""
    safety = SafetyState(dry_run=dry_run, allow_pen_actuation=arm_pen)
    normalized = validate_pen_trial_command(command, safety)

    typer.echo(f"Planned {label} pen command:")
    typer.echo(normalized)
    typer.echo("No motion, homing, unlock, or settings-write commands are included.")
    if dry_run:
        typer.echo("Dry run only; no pen command was sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before pen trial; got {status.state!r}.")
        controller.send_optional_ok_command(normalized)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Pen command sent. Wrote transcript: {transcript}")


@app.command("pen-cycle")
def pen_cycle(
    down_command: Annotated[str, typer.Option(help="Explicit pen-down M-code")],
    up_command: Annotated[str, typer.Option(help="Explicit pen-up M-code")],
    dwell_s: Annotated[float, typer.Option(help="Seconds to wait between down and up")] = 1.0,
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview commands without sending them"),
    ] = True,
    arm_pen: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before pen commands are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/pen_cycle_transcript.jsonl"),
) -> None:
    """Send explicit pen-down then pen-up commands, with no motion."""
    if dwell_s < 0 or dwell_s > 10:
        raise typer.BadParameter("dwell_s must be between 0 and 10 seconds.")
    safety = SafetyState(dry_run=dry_run, allow_pen_actuation=arm_pen)
    down = validate_pen_trial_command(down_command, safety)
    up = validate_pen_trial_command(up_command, safety)

    typer.echo("Planned pen cycle:")
    typer.echo(f"DOWN: {down}")
    typer.echo(f"WAIT: {dwell_s:.2f}s")
    typer.echo(f"UP:   {up}")
    typer.echo("No motion, homing, unlock, or settings-write commands are included.")
    if dry_run:
        typer.echo("Dry run only; no pen commands were sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before pen cycle; got {status.state!r}.")
        controller.send_optional_ok_command(down)
        time.sleep(dwell_s)
        controller.send_optional_ok_command(up)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Pen cycle sent. Wrote transcript: {transcript}")


@app.command("save-pen-config")
def save_pen_config(
    up_command: Annotated[str, typer.Option(help="Known-good pen-up command")],
    down_command: Annotated[str, typer.Option(help="Known-good pen-down command")],
    out: Annotated[Path, typer.Option(help="Machine config JSON output path")]
    = Path("artifacts/machine_config.json"),
) -> None:
    """Save known-good pen commands locally. Does not contact the controller."""
    dry_safety = SafetyState(dry_run=True)
    up = validate_pen_trial_command(up_command, dry_safety)
    down = validate_pen_trial_command(down_command, dry_safety)
    if out.exists():
        config = MachineConfig.model_validate_json(out.read_text(encoding="utf-8"))
    else:
        config = MachineConfig()
    config.pen.up_command = up
    config.pen.down_command = down
    config.save_json(out)
    typer.echo(config.model_dump_json(indent=2))
    typer.echo(f"Wrote machine config: {out}")


@app.command("draw-config-line")
def draw_config_line(
    axis: Annotated[str, typer.Option(help="Axis to draw along: X or Y")] = "X",
    distance: Annotated[float, typer.Option(help="Relative line distance in mm")] = 20.0,
    feed: Annotated[float, typer.Option(help="Feed rate in mm/min")] = 120.0,
    config_path: Annotated[
        Path,
        typer.Option(help="Machine config JSON containing pen commands"),
    ] = Path("artifacts/machine_config.json"),
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview commands without sending them"),
    ] = True,
    arm_motion: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real motion is sent"),
    ] = False,
    arm_pen: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before pen commands are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/draw_config_line_transcript.jsonl"),
) -> None:
    """Lower pen, draw one line, then raise pen using saved pen config."""
    config = _load_machine_config(config_path)
    if config.pen.down_command is None or config.pen.up_command is None:
        raise typer.BadParameter("Machine config must contain pen.down_command and pen.up_command.")

    motion_safety = SafetyState(dry_run=dry_run, armed_motion=arm_motion)
    pen_safety = SafetyState(dry_run=dry_run, allow_pen_actuation=arm_pen)
    normalized_axis = validate_calibration_line_request(
        axis=axis,
        distance_mm=distance,
        feed_mm_min=feed,
        machine=config,
        safety=motion_safety,
    )
    down = validate_pen_trial_command(config.pen.down_command, pen_safety)
    up = validate_pen_trial_command(config.pen.up_command, pen_safety)
    motion_commands = build_relative_jog_commands(
        axis=normalized_axis,
        distance_mm=distance,
        feed_mm_min=feed,
        return_to_start=False,
    )
    commands = [down, *motion_commands, up]

    typer.echo("Planned configured line:")
    for command in commands:
        typer.echo(command)
    if dry_run:
        typer.echo("Dry run only; no commands were sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before configured line; got {status.state!r}.")
        controller.send_optional_ok_command(down)
        for command in motion_commands:
            controller.send_validated_command(command)
        controller.send_optional_ok_command(up)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Configured line sent. Wrote transcript: {transcript}")


@app.command("draw-measure-pattern")
def draw_measure_pattern(
    line_distance: Annotated[float, typer.Option(help="Length of each measurement line in mm")] = 10.0,
    spacing: Annotated[float, typer.Option(help="Pen-up spacing between parallel lines in mm")] = 5.0,
    group_gap: Annotated[float, typer.Option(help="Pen-up Y gap before the Y-line group in mm")] = 15.0,
    count: Annotated[int, typer.Option(help="Number of lines per axis group")] = 3,
    draw_feed: Annotated[float, typer.Option(help="Pen-down draw feed in mm/min")] = 180.0,
    travel_feed: Annotated[float, typer.Option(help="Pen-up travel feed in mm/min")] = 500.0,
    config_path: Annotated[
        Path,
        typer.Option(help="Machine config JSON containing pen commands"),
    ] = Path("artifacts/machine_config.json"),
    dry_run: Annotated[
        bool,
        typer.Option("--dry-run/--no-dry-run", help="Preview commands without sending them"),
    ] = True,
    arm_motion: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before real motion is sent"),
    ] = False,
    arm_pen: Annotated[
        bool,
        typer.Option(help="Required with --no-dry-run before pen commands are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/draw_measure_pattern_transcript.jsonl"),
) -> None:
    """Draw separated X and Y measurement-line groups using saved pen config."""
    if count < 1 or count > 5:
        raise typer.BadParameter("count must be between 1 and 5.")
    if spacing < 0 or spacing > 20:
        raise typer.BadParameter("spacing must be between 0 and 20 mm.")
    if group_gap < 0 or group_gap > 30:
        raise typer.BadParameter("group_gap must be between 0 and 30 mm.")

    config = _load_machine_config(config_path)
    if config.pen.down_command is None or config.pen.up_command is None:
        raise typer.BadParameter("Machine config must contain pen.down_command and pen.up_command.")

    motion_safety = SafetyState(dry_run=dry_run, armed_motion=arm_motion)
    pen_safety = SafetyState(dry_run=dry_run, allow_pen_actuation=arm_pen)
    validate_calibration_line_request(
        axis="X",
        distance_mm=line_distance,
        feed_mm_min=draw_feed,
        machine=config,
        safety=motion_safety,
    )
    validate_calibration_line_request(
        axis="Y",
        distance_mm=line_distance,
        feed_mm_min=draw_feed,
        machine=config,
        safety=motion_safety,
    )
    validate_calibration_line_request(
        axis="X",
        distance_mm=line_distance,
        feed_mm_min=travel_feed,
        machine=config,
        safety=motion_safety,
    )
    validate_calibration_line_request(
        axis="Y",
        distance_mm=group_gap,
        feed_mm_min=travel_feed,
        machine=config,
        safety=motion_safety,
    )
    down = validate_pen_trial_command(config.pen.down_command, pen_safety)
    up = validate_pen_trial_command(config.pen.up_command, pen_safety)

    x_lines = build_parallel_line_motion_commands(
        line_axis="X",
        line_distance_mm=line_distance,
        spacing_mm=spacing,
        count=count,
        draw_feed_mm_min=draw_feed,
        travel_feed_mm_min=travel_feed,
    )
    y_lines = build_parallel_line_motion_commands(
        line_axis="Y",
        line_distance_mm=line_distance,
        spacing_mm=spacing,
        count=count,
        draw_feed_mm_min=draw_feed,
        travel_feed_mm_min=travel_feed,
    )

    commands: list[str] = ["G21", "G91", "G94"]
    for line in x_lines:
        commands.extend([down, *line[:2], up])
        commands.extend(line[2:])
    commands.append(f"G1 F{travel_feed:.3f}".rstrip("0").rstrip("."))
    commands.append(f"G1 Y{group_gap:.3f}".rstrip("0").rstrip("."))
    for line in y_lines:
        commands.extend([down, *line[:2], up])
        commands.extend(line[2:])
    commands.append("G90")

    typer.echo("Planned measurement pattern:")
    for command in commands:
        typer.echo(command)
    if dry_run:
        typer.echo("Dry run only; no commands were sent.")
        return

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before pattern; got {status.state!r}.")
        for command in commands:
            if command in {down, up}:
                controller.send_optional_ok_command(command)
            else:
                controller.send_validated_command(command)
        controller.query_status()
        controller.flush_transcript()
    typer.echo(f"Measurement pattern sent. Wrote transcript: {transcript}")


@app.command("scale-report")
def scale_report(
    axis: Annotated[str, typer.Option(help="Measured axis: X or Y")],
    commanded: Annotated[float, typer.Option(help="Commanded move distance in mm")],
    measured: Annotated[float, typer.Option(help="Measured actual move distance in mm")],
    snapshot: Annotated[
        Path | None,
        typer.Option(help="Optional controller snapshot JSON for current steps/mm"),
    ] = Path("artifacts/controller_snapshot.json"),
    out: Annotated[
        Path,
        typer.Option(help="Observation JSON output path"),
    ] = Path("artifacts/scale_observation.json"),
) -> None:
    """Compute a scale observation without writing controller settings."""
    current_steps = _steps_for_axis(snapshot, axis)
    observation = build_scale_observation(
        axis=axis,
        commanded_mm=commanded,
        measured_mm=measured,
        current_steps_per_mm=current_steps,
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(observation.model_dump_json(indent=2) + "\n", encoding="utf-8")

    typer.echo(observation.model_dump_json(indent=2))
    typer.echo(f"Wrote scale observation: {out}")
    typer.echo("No controller settings were written.")


@app.command("settings-plan")
def settings_plan(
    x_steps: Annotated[float, typer.Option(help="Planned X steps/mm for $100")],
    y_steps: Annotated[float, typer.Option(help="Planned Y steps/mm for $101")],
    out: Annotated[
        Path,
        typer.Option(help="Settings write plan JSON output path"),
    ] = Path("artifacts/settings_plan.json"),
) -> None:
    """Create a plan for $100/$101 only. Does not contact the controller."""
    plan = build_xy_steps_plan(x_steps_per_mm=x_steps, y_steps_per_mm=y_steps)
    plan.save_json(out)
    typer.echo(plan.model_dump_json(indent=2))
    typer.echo(f"Wrote settings plan: {out}")
    typer.echo("No controller settings were written.")


@app.command("apply-settings")
def apply_settings(
    plan_path: Annotated[
        Path,
        typer.Option(help="Settings plan JSON path"),
    ] = Path("artifacts/settings_plan.json"),
    arm_settings: Annotated[
        bool,
        typer.Option(help="Required before $100/$101 writes are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/settings_write_transcript.jsonl"),
    verify_snapshot: Annotated[
        Path,
        typer.Option(help="Post-write snapshot output path"),
    ] = Path("artifacts/controller_snapshot_after_settings.json"),
) -> None:
    """Apply a gated $100/$101 settings plan and save a post-write snapshot."""
    plan = _load_settings_plan(plan_path)
    validated = validate_settings_write_plan(
        plan,
        SafetyState(allow_settings_write=arm_settings),
    )

    typer.echo("Applying settings commands:")
    for command in validated.commands:
        typer.echo(command)
    typer.echo("No motion, homing, unlock, or pen commands are included.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        if status.state != "Idle":
            raise typer.BadParameter(f"Controller must be Idle before settings write; got {status.state!r}.")
        for command in validated.commands:
            controller.send_validated_command(command)
        snapshot = controller.probe()
        snapshot.save_json(verify_snapshot)
        controller.flush_transcript()

    typer.echo(f"Wrote settings transcript: {transcript}")
    typer.echo(f"Wrote post-write snapshot: {verify_snapshot}")


@app.command("xy-homing-plan")
def xy_homing_plan(
    out: Annotated[
        Path,
        typer.Option(help="XY homing settings plan JSON output path"),
    ] = Path("artifacts/xy_homing_plan.json"),
) -> None:
    """Create the XY-only homing/limit plan. Does not contact the controller."""
    plan = build_xy_homing_settings_plan()
    plan.save_json(out)
    typer.echo(plan.model_dump_json(indent=2))
    typer.echo(f"Wrote XY homing plan: {out}")
    typer.echo("No controller settings were written.")


@app.command("hard-limits-plan")
def hard_limits_plan(
    enabled: Annotated[
        bool,
        typer.Option("--enabled/--disabled", help="Plan $21 hard limits on or off"),
    ] = True,
    out: Annotated[
        Path,
        typer.Option(help="Hard-limit settings plan JSON output path"),
    ] = Path("artifacts/hard_limits_plan.json"),
) -> None:
    """Create a hard-limits-only settings plan. Does not contact the controller."""
    plan = build_hard_limits_settings_plan(enabled=enabled)
    plan.save_json(out)
    typer.echo(plan.model_dump_json(indent=2))
    typer.echo(f"Wrote hard-limit plan: {out}")
    typer.echo("No controller settings were written.")


@app.command("apply-hard-limits")
def apply_hard_limits(
    plan_path: Annotated[
        Path,
        typer.Option(help="Hard-limit plan JSON path"),
    ] = Path("artifacts/hard_limits_plan.json"),
    arm_settings: Annotated[
        bool,
        typer.Option(help="Required before $21 is sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/hard_limits_settings_transcript.jsonl"),
    verify_snapshot: Annotated[
        Path,
        typer.Option(help="Post-write snapshot output path"),
    ] = Path("artifacts/controller_snapshot_after_hard_limits_settings.json"),
) -> None:
    """Apply a gated $21 hard-limit setting. Does not run $H or move."""
    plan = _load_hard_limits_plan(plan_path)
    validated = validate_hard_limits_settings_plan(
        plan,
        SafetyState(allow_settings_write=arm_settings),
    )

    typer.echo("Applying hard-limit settings commands:")
    for command in validated.commands:
        typer.echo(command)
    typer.echo("No motion, homing, unlock, or pen commands are included.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        validate_hard_limits_apply_status(
            enabled=validated.enabled,
            state=status.state,
            pins=status.fields.get("Pn", ""),
        )
        for command in validated.commands:
            controller.send_validated_command(command)
        snapshot = controller.probe()
        snapshot.save_json(verify_snapshot)
        controller.flush_transcript()

    typer.echo(f"Wrote hard-limit settings transcript: {transcript}")
    typer.echo(f"Wrote post-write snapshot: {verify_snapshot}")


@app.command("homing-tune-plan")
def homing_tune_plan(
    pull_off: Annotated[float, typer.Option(help="Homing pull-off distance for $27")] = 10.0,
    x_max_travel: Annotated[float, typer.Option(help="X max travel/search distance for $130")] = 400.0,
    out: Annotated[
        Path,
        typer.Option(help="Homing tuning plan JSON output path"),
    ] = Path("artifacts/homing_tune_plan.json"),
) -> None:
    """Create a homing tuning settings plan. Does not contact the controller."""
    plan = build_homing_tuning_settings_plan(
        pull_off_mm=pull_off,
        x_max_travel_mm=x_max_travel,
    )
    plan.save_json(out)
    typer.echo(plan.model_dump_json(indent=2))
    typer.echo(f"Wrote homing tuning plan: {out}")
    typer.echo("No controller settings were written.")


@app.command("apply-homing-tune")
def apply_homing_tune(
    plan_path: Annotated[
        Path,
        typer.Option(help="Homing tuning plan JSON path"),
    ] = Path("artifacts/homing_tune_plan.json"),
    arm_settings: Annotated[
        bool,
        typer.Option(help="Required before $27/$130 are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/homing_tune_settings_transcript.jsonl"),
    verify_snapshot: Annotated[
        Path,
        typer.Option(help="Post-write snapshot output path"),
    ] = Path("artifacts/controller_snapshot_after_homing_tune.json"),
) -> None:
    """Apply gated homing tuning settings. Does not run $H."""
    plan = _load_homing_tune_plan(plan_path)
    validated = validate_homing_tuning_settings_plan(
        plan,
        SafetyState(allow_settings_write=arm_settings),
    )

    typer.echo("Applying homing tuning settings commands:")
    for command in validated.commands:
        typer.echo(command)
    typer.echo("No motion, homing, unlock, or pen commands are included.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        validate_xy_homing_apply_status(
            state=status.state,
            pins=status.fields.get("Pn", ""),
        )
        for command in validated.commands:
            controller.send_validated_command(command)
        snapshot = controller.probe()
        snapshot.save_json(verify_snapshot)
        controller.flush_transcript()

    typer.echo(f"Wrote homing tuning settings transcript: {transcript}")
    typer.echo(f"Wrote post-write snapshot: {verify_snapshot}")


@app.command("workspace-travel-plan")
def workspace_travel_plan(
    x_max_travel: Annotated[float, typer.Option(help="X axis travel for $130")],
    y_max_travel: Annotated[float, typer.Option(help="Y axis travel for $131")],
    out: Annotated[
        Path,
        typer.Option(help="Workspace travel plan JSON output path"),
    ] = Path("artifacts/workspace_travel_plan.json"),
) -> None:
    """Create a workspace travel settings plan. Does not contact the controller."""
    plan = build_workspace_travel_settings_plan(
        x_max_travel_mm=x_max_travel,
        y_max_travel_mm=y_max_travel,
    )
    plan.save_json(out)
    typer.echo(plan.model_dump_json(indent=2))
    typer.echo(f"Wrote workspace travel plan: {out}")
    typer.echo("No controller settings were written.")


@app.command("apply-workspace-travel")
def apply_workspace_travel(
    plan_path: Annotated[
        Path,
        typer.Option(help="Workspace travel plan JSON path"),
    ] = Path("artifacts/workspace_travel_plan.json"),
    arm_settings: Annotated[
        bool,
        typer.Option(help="Required before $130/$131 are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/workspace_travel_settings_transcript.jsonl"),
    verify_snapshot: Annotated[
        Path,
        typer.Option(help="Post-write snapshot output path"),
    ] = Path("artifacts/controller_snapshot_after_workspace_travel.json"),
) -> None:
    """Apply gated workspace travel settings. Does not run $H or move."""
    plan = _load_workspace_travel_plan(plan_path)
    validated = validate_workspace_travel_settings_plan(
        plan,
        SafetyState(allow_settings_write=arm_settings),
    )

    typer.echo("Applying workspace travel settings commands:")
    for command in validated.commands:
        typer.echo(command)
    typer.echo("No motion, homing, unlock, or pen commands are included.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        validate_xy_homing_apply_status(
            state=status.state,
            pins=status.fields.get("Pn", ""),
        )
        for command in validated.commands:
            controller.send_validated_command(command)
        snapshot = controller.probe()
        snapshot.save_json(verify_snapshot)
        controller.flush_transcript()

    typer.echo(f"Wrote workspace travel settings transcript: {transcript}")
    typer.echo(f"Wrote post-write snapshot: {verify_snapshot}")


@app.command("apply-xy-homing-settings")
def apply_xy_homing_settings(
    plan_path: Annotated[
        Path,
        typer.Option(help="XY homing plan JSON path"),
    ] = Path("artifacts/xy_homing_plan.json"),
    arm_settings: Annotated[
        bool,
        typer.Option(help="Required before homing-related settings are sent"),
    ] = False,
    port: Annotated[str | None, typer.Option(help="USB serial port, usually /dev/cu.*")] = None,
    baud: Annotated[int, typer.Option(help="Serial baud rate")] = DEFAULT_BAUD,
    mock: Annotated[bool, typer.Option(help="Use the mock controller")] = False,
    transcript: Annotated[
        Path,
        typer.Option(help="Raw JSONL transcript path"),
    ] = Path("artifacts/xy_homing_settings_transcript.jsonl"),
    verify_snapshot: Annotated[
        Path,
        typer.Option(help="Post-write snapshot output path"),
    ] = Path("artifacts/controller_snapshot_after_xy_homing_settings.json"),
) -> None:
    """Apply gated XY-only homing settings. Does not run $H."""
    plan = _load_xy_homing_plan(plan_path)
    validated = validate_xy_homing_settings_plan(
        plan,
        SafetyState(allow_settings_write=arm_settings),
    )

    typer.echo("Applying XY homing settings commands:")
    for command in validated.commands:
        typer.echo(command)
    typer.echo("No motion, homing, unlock, or pen commands are included.")

    with _make_controller(mock=mock, port=port, baud=baud, transcript=transcript) as controller:
        controller.wake_and_drain()
        status = controller.query_status_report()
        validate_xy_homing_apply_status(
            state=status.state,
            pins=status.fields.get("Pn", ""),
        )
        for command in validated.commands:
            controller.send_validated_command(command)
        snapshot = controller.probe()
        snapshot.save_json(verify_snapshot)
        controller.flush_transcript()

    typer.echo(f"Wrote XY homing settings transcript: {transcript}")
    typer.echo(f"Wrote post-write snapshot: {verify_snapshot}")


def _steps_for_axis(snapshot: Path | None, axis: str) -> float | None:
    if snapshot is None or not snapshot.exists():
        return None
    setting_by_axis = {"X": "100", "Y": "101"}
    setting_key = setting_by_axis.get(axis.upper())
    if setting_key is None:
        return None
    import json

    data = json.loads(snapshot.read_text(encoding="utf-8"))
    value = data.get("settings", {}).get(setting_key)
    if value in {None, ""}:
        return None
    return float(value)


def _load_machine_config(path: Path) -> MachineConfig:
    import json

    if not path.exists():
        raise typer.BadParameter(f"Machine config not found: {path}")
    return MachineConfig.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _load_settings_plan(path: Path) -> SettingsWritePlan:
    import json

    if not path.exists():
        raise typer.BadParameter(f"Settings plan not found: {path}")
    return SettingsWritePlan.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _load_xy_homing_plan(path: Path) -> HomingXYSettingsPlan:
    import json

    if not path.exists():
        raise typer.BadParameter(f"XY homing plan not found: {path}")
    return HomingXYSettingsPlan.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _load_hard_limits_plan(path: Path) -> HardLimitsSettingsPlan:
    import json

    if not path.exists():
        raise typer.BadParameter(f"Hard-limit plan not found: {path}")
    return HardLimitsSettingsPlan.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _load_homing_tune_plan(path: Path) -> HomingTuningSettingsPlan:
    import json

    if not path.exists():
        raise typer.BadParameter(f"Homing tuning plan not found: {path}")
    return HomingTuningSettingsPlan.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _load_workspace_travel_plan(path: Path) -> WorkspaceTravelSettingsPlan:
    import json

    if not path.exists():
        raise typer.BadParameter(f"Workspace travel plan not found: {path}")
    return WorkspaceTravelSettingsPlan.model_validate(json.loads(path.read_text(encoding="utf-8")))


if __name__ == "__main__":
    app()
