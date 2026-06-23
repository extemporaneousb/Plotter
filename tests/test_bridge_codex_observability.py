from __future__ import annotations

import json
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from typer.testing import CliRunner

from plotter_vision.bridge.server import (
    BridgeRuntimeConfig,
    EventLog,
    LocalThreadingHTTPServer,
    PlotterBridge,
    _make_handler,
)
from plotter_vision.cli import app
from plotter_vision.config import MachineConfig


def test_codex_snapshot_merges_bridge_state_and_app_diagnostics(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, dry_run=True, mock=True)

    with _running_bridge(bridge) as client:
        status_code, state_response = client.post(
            "/codex/app/state",
            {
                "source": "PlotterVision",
                "app_build_id": "app/test",
                "bridge_url": "http://127.0.0.1:8765",
                "trace_id": "trace-panel",
                "status": "ready",
                "payload": {
                    "selected_panel": "machine",
                    "paper_locked": True,
                    "last_bridge_label": "Preview Bridge",
                },
            },
        )
        assert status_code == 200
        assert state_response["command_control"] is False
        assert state_response["event_log_appended"] is True

        status_code, event_response = client.post(
            "/codex/app/events",
            {
                "source": "PlotterVision",
                "event_type": "ui.selection_changed",
                "trace_id": "trace-panel",
                "parent_span_id": state_response["record"]["span_id"],
                "status": "observed",
                "payload": {"selected_panel": "diagnostics"},
            },
        )
        assert status_code == 200
        assert event_response["record"]["kind"] == "event"

        bridge_event_count = _jsonl_count(tmp_path / "bridge_events.jsonl")
        app_event_count = _jsonl_count(tmp_path / "app_events.jsonl")

        status_code, snapshot = client.get("/codex/snapshot")
        events_status, events = client.get("/codex/events")

    assert status_code == 200
    assert events_status == 200
    assert snapshot["schema"] == 1
    assert snapshot["read_only"] is True
    assert snapshot["health"]["status"] == "ready"
    assert snapshot["health"]["controller"] == "mock"
    assert snapshot["machine"]["controller"] == "mock"
    assert snapshot["machine"]["status"] == "dry_run"
    assert snapshot["paper"]["status"] == "missing"
    assert [
        event["event_type"]
        for event in snapshot["recent_events"]
        if event["source"] == "bridge"
    ] == ["app.diagnostics_ingested", "app.diagnostics_ingested"]
    assert snapshot["state_summary"]["bridge_build_id"] == snapshot["health"]["bridge_build_id"]
    assert "paper_registration_missing" in snapshot["exact_blockers"]
    assert "binding_untrusted" in snapshot["exact_blockers"]
    assert any(trace["trace_id"] == "trace-panel" for trace in snapshot["recent_traces"])
    assert events["canonical"] is True
    assert any(event["trace_id"] == "trace-panel" for event in events["events"])
    assert all("event_type" in event for event in events["events"])

    app_diagnostics = snapshot["app_diagnostics"]
    assert app_diagnostics["latest_state"]["payload"]["paper_locked"] is True
    assert app_diagnostics["latest_event"]["event_type"] == "ui.selection_changed"
    assert [record["sequence"] for record in app_diagnostics["recent_events"]] == [1, 2]
    assert _jsonl_count(tmp_path / "bridge_events.jsonl") == bridge_event_count
    assert _jsonl_count(tmp_path / "app_events.jsonl") == app_event_count


def test_canonical_codex_events_reads_are_read_only_and_posts_append(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, dry_run=True, mock=False)

    with _running_bridge(bridge) as client:
        assert _jsonl_count(tmp_path / "app_events.jsonl") == 0

        status_code, first = client.post(
            "/codex/app/events",
            {
                "event_type": "bridge.poll_completed",
                "trace_id": "trace-poll",
                "payload": {"health_status": "ready"},
            },
        )
        assert status_code == 200
        assert first["record"]["sequence"] == 1
        assert _jsonl_count(tmp_path / "app_events.jsonl") == 1

        status_code, state = client.post(
            "/codex/app/state",
            {
                "status": "ready",
                "trace_id": "trace-poll",
                "payload": {"bridge_label": "Hardware Standby"},
            },
        )
        assert status_code == 200
        assert state["record"]["sequence"] == 2
        assert _jsonl_count(tmp_path / "app_events.jsonl") == 2

        status_code, events = client.get("/codex/events")
        assert status_code == 200
        assert events["canonical"] is True
        assert any(event["trace_id"] == "trace-poll" for event in events["events"])
        assert _jsonl_count(tmp_path / "app_events.jsonl") == 2

        status_code, snapshot = client.get("/codex/snapshot")
        assert status_code == 200
        assert snapshot["app_diagnostics"]["latest_event"]["event_type"] == "bridge.poll_completed"
        assert snapshot["app_diagnostics"]["latest_state"]["payload"]["bridge_label"] == "Hardware Standby"
        assert _jsonl_count(tmp_path / "app_events.jsonl") == 2

        status_code, response = client.post("/codex/snapshot", {"payload": {"action": "move"}})

    assert status_code == 404
    assert response == {"error": "not found"}
    assert _jsonl_count(tmp_path / "app_events.jsonl") == 2


def test_bridge_event_log_aggregates_repeated_identical_events(tmp_path: Path) -> None:
    event_log = EventLog(tmp_path / "bridge_events.jsonl")

    first = event_log.emit(
        "machine.status_failed",
        status="failed",
        payload={"error": "offline"},
    )
    second = event_log.emit(
        "machine.status_failed",
        status="failed",
        payload={"error": "offline"},
    )

    assert first.sequence == second.sequence
    assert second.payload["repeat_count"] == 2
    assert _jsonl_count(tmp_path / "bridge_events.jsonl") == 1


def test_doctor_json_writes_debug_bundle(tmp_path: Path) -> None:
    bridge = _bridge(tmp_path=tmp_path, dry_run=True, mock=True)
    runner = CliRunner()

    with _running_bridge(bridge) as client:
        result = runner.invoke(
            app,
            [
                "doctor",
                "--json",
                "--base-url",
                client.base_url,
                "--artifacts-dir",
                str(tmp_path),
            ],
    )

    assert result.exit_code == 0, result.output
    manifest = json.loads(result.output[result.output.find("{"):])
    bundle_dir = Path(manifest["bundle_dir"])
    assert manifest["read_only"] is True
    assert (bundle_dir / "manifest.json").exists()
    assert (bundle_dir / "codex_snapshot.json").exists()
    assert (bundle_dir / "codex_events.json").exists()
    assert manifest["endpoints"]["codex_events"].endswith("codex_events.json")


class _BridgeClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url

    def get(self, path: str) -> tuple[int, dict[str, Any]]:
        return self._request("GET", path)

    def post(self, path: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return self._request("POST", path, payload=payload)

    def _request(
        self, method: str, path: str, payload: dict[str, Any] | None = None
    ) -> tuple[int, dict[str, Any]]:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        request = Request(
            f"{self.base_url}{path}",
            data=body,
            method=method,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=5.0) as response:
                return (response.status, json.loads(response.read().decode("utf-8")))
        except HTTPError as error:
            return (error.code, json.loads(error.read().decode("utf-8")))


@contextmanager
def _running_bridge(bridge: PlotterBridge) -> Iterator[_BridgeClient]:
    server = LocalThreadingHTTPServer(("127.0.0.1", 0), _make_handler(bridge))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host, port = server.server_address
        yield _BridgeClient(f"http://{host}:{port}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2.0)


def _bridge(*, tmp_path: Path, dry_run: bool, mock: bool) -> PlotterBridge:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.save_json(config_path)
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=dry_run,
            mock=mock,
            config_path=config_path,
            event_log_path=tmp_path / "bridge_events.jsonl",
            app_state_path=tmp_path / "app_state.json",
            app_event_log_path=tmp_path / "app_events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )


def _jsonl_count(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
