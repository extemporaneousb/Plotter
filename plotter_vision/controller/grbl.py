from __future__ import annotations

import json
import time
from pathlib import Path

from plotter_vision.controller.base import CommandLogEvent, CommandResult, ControllerTransport
from plotter_vision.controller.parser import (
    ControllerError,
    StatusReport,
    assert_phase0_safe_command,
    parse_bracket_line,
    parse_response_line,
    parse_setting_line,
    parse_status_report,
)
from plotter_vision.controller.snapshot import ControllerSnapshot


class GrblHalController:
    def __init__(
        self,
        transport: ControllerTransport,
        *,
        source: str = "controller_probe",
        transcript_path: Path | None = None,
    ) -> None:
        self.transport = transport
        self.source = source
        self.transcript_path = transcript_path
        self.events: list[CommandLogEvent] = []

    def __enter__(self) -> GrblHalController:
        self.connect()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:  # type: ignore[no-untyped-def]
        self.disconnect()

    def connect(self) -> None:
        self.transport.connect()

    def disconnect(self) -> None:
        self.flush_transcript()
        self.transport.disconnect()

    def wake_and_drain(self, quiet_s: float = 0.25, max_s: float = 3.0) -> list[str]:
        if hasattr(self.transport, "write_wake"):
            self._record("TX", "<wake: CRLF CRLF>")
            self.transport.write_wake()  # type: ignore[attr-defined]

        return self.drain_until_quiet(quiet_s=quiet_s, max_s=max_s)

    def drain_until_quiet(self, quiet_s: float = 0.25, max_s: float = 3.0) -> list[str]:
        lines: list[str] = []
        deadline = time.monotonic() + max_s
        quiet_deadline = time.monotonic() + quiet_s
        while time.monotonic() < deadline:
            line = self.transport.read_line(timeout_s=0.1)
            if line is None:
                if time.monotonic() >= quiet_deadline:
                    break
                continue
            self._record("RX", line)
            lines.append(line)
            quiet_deadline = time.monotonic() + quiet_s
        return lines

    def send_command(
        self,
        command: str,
        *,
        timeout_s: float = 10.0,
        raise_on_error: bool = True,
    ) -> CommandResult:
        safe_command = assert_phase0_safe_command(command)
        if not safe_command:
            return CommandResult(command=command, responses=[])

        self._record("TX", safe_command)
        self.transport.write_line(safe_command)

        responses: list[str] = []
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            line = self.transport.read_line(timeout_s=0.25)
            if line is None:
                continue
            self._record("RX", line)
            responses.append(line)
            parsed = parse_response_line(line)
            if parsed.kind == "ok":
                return CommandResult(command=safe_command, responses=responses, ok=True)
            if parsed.kind in {"error", "alarm"}:
                if not raise_on_error:
                    return CommandResult(
                        command=safe_command,
                        responses=responses,
                        ok=False,
                        error_line=line,
                    )
                raise ControllerError(f"Controller returned {line!r} for {safe_command!r}")

        raise TimeoutError(f"Timed out waiting for ok/error after {safe_command!r}")

    def send_validated_command(self, command: str, *, timeout_s: float = 10.0) -> CommandResult:
        """Send a command that has already passed a higher-level safety validator."""
        stripped = command.split(";", 1)[0].strip()
        if not stripped:
            return CommandResult(command=command, responses=[])

        self._record("TX", stripped)
        self.transport.write_line(stripped)

        responses: list[str] = []
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            line = self.transport.read_line(timeout_s=0.25)
            if line is None:
                continue
            self._record("RX", line)
            responses.append(line)
            parsed = parse_response_line(line)
            if parsed.kind == "ok":
                return CommandResult(command=stripped, responses=responses, ok=True)
            if parsed.kind in {"error", "alarm"}:
                raise ControllerError(f"Controller returned {line!r} for {stripped!r}")

        raise TimeoutError(f"Timed out waiting for ok/error after {stripped!r}")

    def send_optional_ok_command(
        self,
        command: str,
        *,
        wait_s: float = 0.5,
    ) -> CommandResult:
        """Send a validated command whose firmware response may be absent.

        This is intended for observed pen servo commands only. Motion commands should use
        send_validated_command(), which requires ok/error.
        """
        stripped = command.split(";", 1)[0].strip()
        if not stripped:
            return CommandResult(command=command, responses=[])

        self._record("TX", stripped)
        self.transport.write_line(stripped)

        responses: list[str] = []
        deadline = time.monotonic() + wait_s
        while time.monotonic() < deadline:
            line = self.transport.read_line(timeout_s=0.05)
            if line is None:
                continue
            self._record("RX", line)
            responses.append(line)
            parsed = parse_response_line(line)
            if parsed.kind == "ok":
                return CommandResult(command=stripped, responses=responses, ok=True)
            if parsed.kind in {"error", "alarm"}:
                raise ControllerError(f"Controller returned {line!r} for {stripped!r}")

        return CommandResult(command=stripped, responses=responses, ok=False)

    def query_status(self, *, timeout_s: float = 2.0) -> list[str]:
        safe_command = assert_phase0_safe_command("?")
        self._record("TX", safe_command)
        self.transport.write_realtime(b"?")

        responses: list[str] = []
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            line = self.transport.read_line(timeout_s=0.1)
            if line is None:
                continue
            self._record("RX", line)
            responses.append(line)
            if line.startswith("<") and line.endswith(">"):
                return responses
            parsed = parse_response_line(line)
            if parsed.kind in {"error", "alarm"}:
                raise ControllerError(f"Controller returned {line!r} after status query")

        raise TimeoutError("Timed out waiting for a status report after '?'.")

    def query_status_report(self, *, timeout_s: float = 2.0) -> StatusReport:
        for line in self.query_status(timeout_s=timeout_s):
            if line.startswith("<") and line.endswith(">"):
                return parse_status_report(line)
        raise TimeoutError("Status query completed without a parseable status report.")

    def feed_hold(self) -> None:
        """Send explicit realtime feed hold. Does not unlock, home, or move."""
        self._write_realtime(b"!", "!")

    def resume(self) -> None:
        """Send explicit realtime cycle-start/resume."""
        self._write_realtime(b"~", "~")

    def unlock(self) -> CommandResult:
        """Send explicit $X alarm unlock. Caller must enforce safety gates."""
        return self.send_validated_command("$X")

    def soft_reset(self, *, drain_s: float = 1.0) -> list[str]:
        """Send explicit Ctrl-X soft reset and drain startup chatter."""
        self._write_realtime(b"\x18", "Ctrl-X")
        return self.drain_until_quiet(quiet_s=0.25, max_s=drain_s)

    def probe(self, *, transcript_path: Path | None = None) -> ControllerSnapshot:
        if transcript_path is not None:
            self.transcript_path = transcript_path

        warnings: list[str] = []
        self.wake_and_drain()
        identity_result = self.send_command("$I", raise_on_error=False)
        modal_result = self.send_command("$G", raise_on_error=False)
        try:
            status_lines = self.query_status()
        except (ControllerError, TimeoutError) as exc:
            status_lines = []
            warnings.append(f"Status query '?' failed: {exc}")
        settings_result = self.send_command("$$", raise_on_error=False)
        coordinate_result = self.send_command("$#", raise_on_error=False)

        identity = self._non_terminal_lines(identity_result)
        modal = self._non_terminal_lines(modal_result)
        settings_lines = settings_result.responses
        coordinate_lines = coordinate_result.responses

        for result in [identity_result, modal_result, settings_result, coordinate_result]:
            if not result.ok:
                warnings.append(
                    f"Command {result.command!r} returned {result.error_line!r}; "
                    "partial responses were preserved."
                )

        status_report = None
        for line in status_lines:
            if line.startswith("<") and line.endswith(">"):
                status_report = parse_status_report(line)
                break
        if status_report is None:
            warnings.append("No status report was parsed from the '?' response.")

        settings: dict[str, str] = {}
        for line in settings_lines:
            setting = parse_setting_line(line)
            if setting is not None:
                settings[str(setting.number)] = setting.value

        coordinates: dict[str, str] = {}
        for line in coordinate_lines:
            bracket = parse_bracket_line(line)
            if bracket is None:
                continue
            key, value = bracket
            coordinates[key] = value

        snapshot = ControllerSnapshot(
            transport=self.transport.description,
            firmware_identity=identity,
            parser_modal_state=modal,
            status_report=status_report,
            settings=settings,
            coordinate_parameters=coordinates,
            raw_transcript_file=str(self.transcript_path) if self.transcript_path else None,
            parser_warnings=warnings,
        )
        self.flush_transcript()
        return snapshot

    def flush_transcript(self) -> None:
        if self.transcript_path is None:
            return
        self.transcript_path.parent.mkdir(parents=True, exist_ok=True)
        payload = "\n".join(event.model_dump_json() for event in self.events)
        self.transcript_path.write_text(payload + ("\n" if payload else ""), encoding="utf-8")

    def _record(self, direction: str, payload: str) -> None:
        event = CommandLogEvent(direction=direction, payload=payload, source=self.source)  # type: ignore[arg-type]
        self.events.append(event)
        print(f"{direction}: {payload}")

    def _write_realtime(self, data: bytes, label: str) -> None:
        self._record("TX", label)
        self.transport.write_realtime(data)

    def transcript_as_json(self) -> str:
        return json.dumps([event.model_dump() for event in self.events], indent=2)

    def _non_terminal_lines(self, result: CommandResult) -> list[str]:
        return [
            line
            for line in result.responses
            if line.lower() != "ok"
            and not line.lower().startswith("error:")
            and not line.lower().startswith("alarm:")
        ]
