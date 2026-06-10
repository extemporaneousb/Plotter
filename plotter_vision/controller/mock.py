from __future__ import annotations

from collections import deque


class MockTransport:
    description = "mock grblHAL-compatible controller"

    def __init__(self) -> None:
        self.connected = False
        self._rx: deque[str] = deque()
        self.written_lines: list[str] = []
        self.written_realtime: list[bytes] = []

    def connect(self) -> None:
        self.connected = True
        self._rx.extend(
            [
                "GrblHAL 1.1f ['$' or '$HELP' for help]",
                "[MSG:Mock BlackBox X32 startup]",
            ]
        )

    def disconnect(self) -> None:
        self.connected = False

    def write_line(self, line: str) -> None:
        self.written_lines.append(line)
        normalized = line.strip().upper()
        responses = {
            "$I": [
                "[VER:1.1f.20240101:Mock grblHAL]",
                "[OPT:VNM,35,255]",
                "[NEWOPT:ENUMS,RT+,HOME,ES,TC,SED]",
                "ok",
            ],
            "$G": ["[GC:G0 G54 G17 G21 G90 G94 M5 M9 T0 F0 S0]", "ok"],
            "$$": [
                "$0=10",
                "$1=255",
                "$10=511",
                "$100=250.000",
                "$101=250.000",
                "$110=5000.000",
                "$111=5000.000",
                "ok",
            ],
            "$#": [
                "[G54:0.000,0.000,0.000]",
                "[G55:0.000,0.000,0.000]",
                "[G56:0.000,0.000,0.000]",
                "[G57:0.000,0.000,0.000]",
                "[G58:0.000,0.000,0.000]",
                "[G59:0.000,0.000,0.000]",
                "[G28:0.000,0.000,0.000]",
                "[G30:0.000,0.000,0.000]",
                "[G92:0.000,0.000,0.000]",
                "[TLO:0.000]",
                "[PRB:0.000,0.000,0.000:0]",
                "ok",
            ],
        }
        if line in responses:
            self._rx.extend(responses[line])
        elif normalized in {"$H", "$X"} or normalized.startswith(
            ("G0", "G1", "G4", "G21", "G53", "G90", "G91", "G94", "M3", "M4", "M5")
        ):
            self._rx.append("ok")
        else:
            self._rx.extend([f"error:Unsupported mock command {line}", "ok"])

    def write_realtime(self, data: bytes) -> None:
        self.written_realtime.append(data)
        if data == b"?":
            self._rx.append("<Idle|MPos:0.000,0.000,0.000|FS:0,0>")

    def read_line(self, timeout_s: float) -> str | None:
        _ = timeout_s
        if self._rx:
            return self._rx.popleft()
        return None
