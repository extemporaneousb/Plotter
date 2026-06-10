from __future__ import annotations

import time
from dataclasses import dataclass

import serial
from serial.tools import list_ports


DEFAULT_BAUD = 115200


@dataclass(frozen=True)
class SerialPortInfo:
    device: str
    description: str
    hwid: str


def list_serial_ports() -> list[SerialPortInfo]:
    return [
        SerialPortInfo(device=port.device, description=port.description, hwid=port.hwid)
        for port in list_ports.comports()
    ]


class SerialTransport:
    def __init__(self, port: str, baud: int = DEFAULT_BAUD) -> None:
        self.port = port
        self.baud = baud
        self.description = f"serial:{port}@{baud}"
        self._serial: serial.Serial | None = None

    def connect(self) -> None:
        self._serial = serial.Serial(
            port=self.port,
            baudrate=self.baud,
            timeout=0.1,
            write_timeout=1.0,
        )

    def disconnect(self) -> None:
        if self._serial is not None:
            self._serial.close()
            self._serial = None

    def write_line(self, line: str) -> None:
        ser = self._require_serial()
        ser.write((line + "\n").encode("ascii"))
        ser.flush()

    def write_realtime(self, data: bytes) -> None:
        ser = self._require_serial()
        ser.write(data)
        ser.flush()

    def write_wake(self) -> None:
        ser = self._require_serial()
        ser.write(b"\r\n\r\n")
        ser.flush()

    def read_line(self, timeout_s: float) -> str | None:
        ser = self._require_serial()
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            raw = ser.readline()
            if not raw:
                continue
            line = raw.decode("utf-8", errors="replace").strip()
            if line:
                return line
        return None

    def _require_serial(self) -> serial.Serial:
        if self._serial is None:
            raise RuntimeError("Serial transport is not connected.")
        return self._serial
