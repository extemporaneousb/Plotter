from __future__ import annotations

import pytest

from plotter_vision.controller.parser import (
    UnsafeCommandError,
    assert_phase0_safe_command,
    parse_response_line,
    parse_setting_line,
    parse_status_report,
)


def test_parse_ok_and_error() -> None:
    assert parse_response_line("ok").kind == "ok"

    parsed = parse_response_line("error:2")
    assert parsed.kind == "error"
    assert parsed.data["code"] == "2"


def test_parse_status_report() -> None:
    status = parse_status_report("<Idle|MPos:0.000,1.250,0.000|FS:0,0>")

    assert status.state == "Idle"
    assert status.machine_position == (0.0, 1.25, 0.0)
    assert status.feed_spindle == (0.0, 0.0)
    assert status.fields["MPos"] == "0.000,1.250,0.000"


def test_parse_setting_line() -> None:
    setting = parse_setting_line("$100=250.000")

    assert setting is not None
    assert setting.number == 100
    assert setting.value == "250.000"


def test_parse_empty_setting_line() -> None:
    setting = parse_setting_line("$74=")

    assert setting is not None
    assert setting.number == 74
    assert setting.value == ""


@pytest.mark.parametrize("command", ["$I", "$G", "?", "$$", "$#"])
def test_phase0_allows_only_passive_query_commands(command: str) -> None:
    assert assert_phase0_safe_command(command) == command


@pytest.mark.parametrize(
    "command",
    ["$X", "$H", "$C", "$100=250.000", "$N0=G54", "$RST=$", "G0 X1", "M3 S1000", "$J=X1"],
)
def test_phase0_rejects_unsafe_commands(command: str) -> None:
    with pytest.raises(UnsafeCommandError):
        assert_phase0_safe_command(command)
