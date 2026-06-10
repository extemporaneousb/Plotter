from __future__ import annotations

from collections import deque

import pytest

from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.parser import ControllerError


class FakeTransport:
    description = "fake transport"

    def __init__(self, script: dict[str, list[str]] | None = None) -> None:
        self.script = script or {}
        self.connected = False
        self.written_lines: list[str] = []
        self.written_realtime: list[bytes] = []
        self.rx: deque[str] = deque()

    def connect(self) -> None:
        self.connected = True

    def disconnect(self) -> None:
        self.connected = False

    def write_line(self, line: str) -> None:
        self.written_lines.append(line)
        self.rx.extend(self.script.get(line, []))

    def write_realtime(self, data: bytes) -> None:
        self.written_realtime.append(data)
        if data == b"?":
            self.rx.extend(self.script.get("?", []))
        elif data == b"\x18":
            self.rx.extend(self.script.get("Ctrl-X", []))

    def read_line(self, timeout_s: float) -> str | None:
        _ = timeout_s
        if self.rx:
            return self.rx.popleft()
        return None


def test_fake_transport_send_response_and_logging() -> None:
    transport = FakeTransport({"$I": ["[VER:fake]", "ok"]})
    controller = GrblHalController(transport)

    controller.connect()
    result = controller.send_command("$I")

    assert result.ok is True
    assert result.responses == ["[VER:fake]", "ok"]
    assert transport.written_lines == ["$I"]
    assert [(event.direction, event.payload) for event in controller.events] == [
        ("TX", "$I"),
        ("RX", "[VER:fake]"),
        ("RX", "ok"),
    ]


def test_error_response_raises_controller_error() -> None:
    controller = GrblHalController(FakeTransport({"$I": ["error:2"]}))
    controller.connect()

    with pytest.raises(ControllerError, match="error:2"):
        controller.send_command("$I")


def test_alarm_response_raises_controller_error() -> None:
    controller = GrblHalController(FakeTransport({"$I": ["ALARM:1"]}))
    controller.connect()

    with pytest.raises(ControllerError, match="ALARM:1"):
        controller.send_command("$I")


def test_command_timeout_includes_command() -> None:
    controller = GrblHalController(FakeTransport())
    controller.connect()

    with pytest.raises(TimeoutError, match=r"\$I"):
        controller.send_command("$I", timeout_s=0.01)


def test_status_query_returns_typed_report() -> None:
    controller = GrblHalController(
        FakeTransport({"?": ["<Idle|MPos:1.000,2.000,0.000|FS:0,0>"]})
    )
    controller.connect()

    status = controller.query_status_report()

    assert status.state == "Idle"
    assert status.machine_position == (1.0, 2.0, 0.0)


def test_repeated_status_queries_can_observe_pin_changes() -> None:
    transport = FakeTransport()
    transport.script["?"] = ["<Idle|MPos:0.000,0.000,0.000|Pn:X>"]
    controller = GrblHalController(transport)
    controller.connect()

    first = controller.query_status_report()
    transport.script["?"] = ["<Idle|MPos:0.000,0.000,0.000|Pn:XY>"]
    second = controller.query_status_report()

    assert first.fields["Pn"] == "X"
    assert second.fields["Pn"] == "XY"


def test_status_query_timeout() -> None:
    controller = GrblHalController(FakeTransport())
    controller.connect()

    with pytest.raises(TimeoutError, match="status report"):
        controller.query_status(timeout_s=0.01)


def test_realtime_hooks_are_explicit_and_logged() -> None:
    transport = FakeTransport({"Ctrl-X": ["GrblHAL 1.1f ['$' or '$HELP' for help]"]})
    controller = GrblHalController(transport)
    controller.connect()

    controller.feed_hold()
    controller.resume()
    drained = controller.soft_reset(drain_s=0.01)

    assert transport.written_realtime == [b"!", b"~", b"\x18"]
    assert drained == ["GrblHAL 1.1f ['$' or '$HELP' for help]"]
    assert [event.payload for event in controller.events if event.direction == "TX"] == [
        "!",
        "~",
        "Ctrl-X",
    ]


def test_soft_reset_is_explicit_named_operation() -> None:
    transport = FakeTransport({"Ctrl-X": ["GrblHAL 1.1f ['$' or '$HELP' for help]"]})
    controller = GrblHalController(transport)
    controller.connect()

    drained = controller.soft_reset(drain_s=0.01)

    assert transport.written_realtime == [b"\x18"]
    assert drained == ["GrblHAL 1.1f ['$' or '$HELP' for help]"]


def test_unlock_is_explicit_named_operation() -> None:
    transport = FakeTransport({"$X": ["ok"]})
    controller = GrblHalController(transport)
    controller.connect()

    result = controller.unlock()

    assert result.ok is True
    assert transport.written_lines == ["$X"]


def test_optional_ok_command_accepts_absent_response() -> None:
    transport = FakeTransport()
    controller = GrblHalController(transport)
    controller.connect()

    result = controller.send_optional_ok_command("M3 S40", wait_s=0.01)

    assert result.ok is False
    assert result.responses == []
    assert transport.written_lines == ["M3 S40"]


def test_optional_ok_command_still_raises_on_error() -> None:
    controller = GrblHalController(FakeTransport({"M3 S40": ["error:2"]}))
    controller.connect()

    with pytest.raises(ControllerError, match="error:2"):
        controller.send_optional_ok_command("M3 S40", wait_s=0.01)
