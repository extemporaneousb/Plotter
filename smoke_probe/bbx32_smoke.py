#!/usr/bin/env python3
"""Minimal BlackBox X32 / grblHAL smoke probe.

This tool intentionally starts with passive, no-motion interrogation. It can also
run tiny gated motion tests, but those require an explicit --arm-motion flag.
"""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

import serial
from serial.tools import list_ports


DEFAULT_BAUD = 115200


class GrblError(RuntimeError):
    """Raised when the controller reports error/alarm or times out."""


@dataclass(frozen=True)
class TranscriptEvent:
    timestamp_s: float
    direction: str
    payload: str

    def render(self) -> str:
        return f"{self.timestamp_s:.6f}\t{self.direction}\t{self.payload}"


class Transcript:
    def __init__(self, file: TextIO | None = None) -> None:
        self.events: list[TranscriptEvent] = []
        self.file = file

    def record(self, direction: str, payload: str) -> None:
        event = TranscriptEvent(time.time(), direction, payload)
        self.events.append(event)
        if self.file is not None:
            self.file.write(event.render() + "\n")
            self.file.flush()

    def tx(self, payload: str) -> None:
        print(f"TX: {payload}")
        self.record("TX", payload)

    def rx(self, payload: str) -> None:
        print(f"RX: {payload}")
        self.record("RX", payload)


class TranscriptFile:
    def __init__(self, path: str | None) -> None:
        self.path = Path(path) if path else None
        self.handle: TextIO | None = None

    def __enter__(self) -> Transcript:
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.handle = self.path.open("w", encoding="utf-8")
        return Transcript(self.handle)

    def __exit__(self, exc_type, exc, tb) -> None:  # type: ignore[no-untyped-def]
        if self.handle is not None:
            self.handle.close()


def list_serial_ports() -> None:
    ports = list(list_ports.comports())
    if not ports:
        print("No serial ports found.")
        return

    for port in ports:
        print(f"{port.device}\t{port.description}\t{port.hwid}")


def open_controller(
    port: str,
    baud: int = DEFAULT_BAUD,
    transcript: Transcript | None = None,
) -> serial.Serial:
    ser = serial.Serial(
        port=port,
        baudrate=baud,
        timeout=1.0,
        write_timeout=1.0,
    )

    # Wake GRBL/grblHAL-style controllers and drain startup chatter.
    ser.write(b"\r\n\r\n")
    ser.flush()
    if transcript is not None:
        transcript.tx("<wake: CRLF CRLF>")
    time.sleep(2.0)
    drain_until_quiet(ser, transcript=transcript, quiet_s=0.25, max_s=3.0)
    return ser


def drain_until_quiet(
    ser: serial.Serial,
    transcript: Transcript | None,
    quiet_s: float,
    max_s: float,
) -> list[str]:
    lines: list[str] = []
    start = time.monotonic()
    last_rx = time.monotonic()

    while time.monotonic() - start < max_s:
        raw = ser.readline()
        if raw:
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                if transcript is not None:
                    transcript.rx(line)
                else:
                    print(f"RX: {line}")
                lines.append(line)
            last_rx = time.monotonic()
        elif time.monotonic() - last_rx >= quiet_s:
            break

    return lines


def strip_gcode_line(line: str) -> str:
    # Intentionally simple: remove semicolon comments and trim whitespace.
    return line.split(";", 1)[0].strip()


def reject_phase0_unsafe(line: str) -> None:
    """Reject commands that should not appear in passive interrogation."""
    stripped = strip_gcode_line(line).upper().replace(" ", "")
    if not stripped:
        return

    forbidden_exact = {"$X", "$H", "$RST=$", "$RST=#", "$RST=*"}
    if stripped in forbidden_exact:
        raise GrblError(f"Refusing unsafe phase-0 command: {line!r}")

    if stripped.startswith("$N"):
        raise GrblError(f"Refusing startup-block command in phase 0: {line!r}")

    # Settings writes look like $100=250.000. They are forbidden here.
    if stripped.startswith("$") and "=" in stripped and not stripped.startswith("$RST="):
        raise GrblError(f"Refusing settings write in phase 0: {line!r}")

    # Plain motion/spindle/servo-ish G/M-code is not part of passive probe.
    if stripped[0] in {"G", "M"}:
        raise GrblError(f"Refusing motion/modal command in phase 0: {line!r}")


def send_line(
    ser: serial.Serial,
    line: str,
    transcript: Transcript,
    timeout_s: float = 5.0,
    phase0_safe: bool = False,
) -> list[str]:
    stripped = strip_gcode_line(line)
    if not stripped:
        return []
    if phase0_safe:
        reject_phase0_unsafe(stripped)

    transcript.tx(stripped)
    ser.write((stripped + "\n").encode("ascii"))
    ser.flush()

    responses: list[str] = []
    start = time.monotonic()

    while time.monotonic() - start < timeout_s:
        raw = ser.readline()
        if not raw:
            continue

        text = raw.decode("utf-8", errors="replace").strip()
        if not text:
            continue

        transcript.rx(text)
        responses.append(text)

        lower = text.lower()
        if lower == "ok":
            return responses
        if lower.startswith("error:"):
            raise GrblError(f"Controller returned {text!r} for command {stripped!r}")
        if lower.startswith("alarm:"):
            raise GrblError(f"Controller alarmed with {text!r}")

    raise TimeoutError(f"No ok/error response for command {stripped!r}")


def send_realtime(ser: serial.Serial, data: bytes, transcript: Transcript, label: str) -> None:
    transcript.tx(label)
    ser.write(data)
    ser.flush()


def query_status(ser: serial.Serial, transcript: Transcript, timeout_s: float = 2.0) -> list[str]:
    send_realtime(ser, b"?", transcript, "?")

    responses: list[str] = []
    start = time.monotonic()

    while time.monotonic() - start < timeout_s:
        raw = ser.readline()
        if not raw:
            continue

        text = raw.decode("utf-8", errors="replace").strip()
        if not text:
            continue

        transcript.rx(text)
        responses.append(text)

        if text.startswith("<") and text.endswith(">"):
            return responses

    raise TimeoutError("No status report received after '?'.")


def stream_file(ser: serial.Serial, path: Path, transcript: Transcript) -> None:
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = strip_gcode_line(line)
        if not stripped:
            continue
        try:
            send_line(ser, stripped, transcript=transcript, timeout_s=10.0)
        except Exception as exc:
            raise RuntimeError(f"Failed on line {line_number}: {stripped!r}") from exc


def cmd_probe(args: argparse.Namespace) -> None:
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            for command in ["$I", "$G", "?", "$$", "$#"]:
                if command == "?":
                    query_status(ser, transcript)
                else:
                    send_line(ser, command, transcript=transcript, timeout_s=10.0, phase0_safe=True)


def cmd_check(args: argparse.Namespace) -> None:
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            send_line(ser, "$C", transcript=transcript, timeout_s=10.0)
            try:
                stream_file(ser, Path(args.file), transcript=transcript)
            finally:
                # Disabling check mode resets parser state on GRBL-style controllers.
                send_line(ser, "$C", transcript=transcript, timeout_s=10.0)


def cmd_no_motion(args: argparse.Namespace) -> None:
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            for command in ["G21", "G90", "G94", "G4 P0.01", "$G"]:
                send_line(ser, command, transcript=transcript, timeout_s=10.0)
            query_status(ser, transcript)


def require_arm(args: argparse.Namespace) -> None:
    if not args.arm_motion:
        raise SystemExit("Refusing to move. Re-run with --arm-motion after clearing the machine.")


def cmd_micro_x(args: argparse.Namespace) -> None:
    require_arm(args)
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            for command in [
                "G21",
                "G91",
                "G94",
                "G1 F60",
                "G1 X1.0",
                "G4 P0.01",
                "G1 X-1.0",
                "G4 P0.01",
                "G90",
            ]:
                send_line(ser, command, transcript=transcript, timeout_s=10.0)
                query_status(ser, transcript)


def cmd_square(args: argparse.Namespace) -> None:
    require_arm(args)
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            for command in [
                "G21",
                "G91",
                "G94",
                "G1 F120",
                "G1 X5.0",
                "G1 Y5.0",
                "G1 X-5.0",
                "G1 Y-5.0",
                "G90",
            ]:
                send_line(ser, command, transcript=transcript, timeout_s=10.0)
                query_status(ser, transcript)


def cmd_hold(args: argparse.Namespace) -> None:
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            send_realtime(ser, b"!", transcript, "!")
            time.sleep(0.2)
            query_status(ser, transcript)


def cmd_reset(args: argparse.Namespace) -> None:
    with TranscriptFile(args.transcript) as transcript:
        with open_controller(args.port, args.baud, transcript) as ser:
            send_realtime(ser, b"\x18", transcript, "Ctrl-X")
            time.sleep(1.0)
            drain_until_quiet(ser, transcript=transcript, quiet_s=0.25, max_s=3.0)


def add_serial_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--port", required=True, help="Serial port, usually /dev/cu.* on macOS")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument(
        "--transcript",
        default=None,
        help="Optional path to write a timestamped TX/RX transcript TSV",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bbx32-smoke")
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("ports", help="List serial ports")
    p.set_defaults(func=lambda args: list_serial_ports())

    p = sub.add_parser("probe", help="Passive no-motion controller interrogation")
    add_serial_args(p)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("check", help="Stream a G-code file through GRBL check mode")
    add_serial_args(p)
    p.add_argument("--file", required=True)
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("no-motion", help="Send modal setup and dwell; should not move")
    add_serial_args(p)
    p.set_defaults(func=cmd_no_motion)

    p = sub.add_parser("micro-x", help="Move X +1mm then -1mm; requires --arm-motion")
    add_serial_args(p)
    p.add_argument("--arm-motion", action="store_true")
    p.set_defaults(func=cmd_micro_x)

    p = sub.add_parser("square", help="Move a tiny 5mm relative square; requires --arm-motion")
    add_serial_args(p)
    p.add_argument("--arm-motion", action="store_true")
    p.set_defaults(func=cmd_square)

    p = sub.add_parser("hold", help="Send realtime feed hold '!'")
    add_serial_args(p)
    p.set_defaults(func=cmd_hold)

    p = sub.add_parser("reset", help="Send explicit soft reset Ctrl-X")
    add_serial_args(p)
    p.set_defaults(func=cmd_reset)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        args.func(args)
        return 0
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
