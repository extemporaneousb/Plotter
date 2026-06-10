from __future__ import annotations

from pathlib import Path

from plotter_vision.controller.grbl import GrblHalController
from plotter_vision.controller.mock import MockTransport


class PartialCoordinateErrorTransport(MockTransport):
    def write_line(self, line: str) -> None:
        if line != "$#":
            super().write_line(line)
            return

        self.written_lines.append(line)
        self._rx.extend(  # noqa: SLF001 - test transport deliberately simulates device internals.
            [
                "[G54:0.000,0.000,0.000]",
                "[G55:0.000,0.000,0.000]",
                "[G59.3:0.000,0.000,0.000]",
                "[G28:0.000,0.000,0.000]",
                "error:7",
            ]
        )


def test_snapshot_from_mock_transport(tmp_path: Path) -> None:
    transcript = tmp_path / "mock_transcript.jsonl"
    with GrblHalController(MockTransport(), transcript_path=transcript) as controller:
        snapshot = controller.probe()

    assert snapshot.transport == "mock grblHAL-compatible controller"
    assert snapshot.status_report is not None
    assert snapshot.status_report.state == "Idle"
    assert snapshot.settings["100"] == "250.000"
    assert snapshot.coordinate_parameters["G54"] == "0.000,0.000,0.000"
    assert transcript.exists()
    assert '"direction":"TX"' in transcript.read_text(encoding="utf-8")


def test_snapshot_json_round_trip(tmp_path: Path) -> None:
    out = tmp_path / "snapshot.json"
    with GrblHalController(MockTransport()) as controller:
        snapshot = controller.probe()

    snapshot.save_json(out)

    saved = out.read_text(encoding="utf-8")
    assert '"transport": "mock grblHAL-compatible controller"' in saved
    assert '"parser_warnings": []' in saved


def test_snapshot_preserves_partial_coordinate_response_on_error(tmp_path: Path) -> None:
    transcript = tmp_path / "partial_error_transcript.jsonl"
    with GrblHalController(PartialCoordinateErrorTransport(), transcript_path=transcript) as controller:
        snapshot = controller.probe()

    assert snapshot.coordinate_parameters["G54"] == "0.000,0.000,0.000"
    assert snapshot.coordinate_parameters["G59.3"] == "0.000,0.000,0.000"
    assert snapshot.coordinate_parameters["G28"] == "0.000,0.000,0.000"
    assert any("'$#' returned 'error:7'" in warning for warning in snapshot.parser_warnings)
    assert "error:7" in transcript.read_text(encoding="utf-8")
