from __future__ import annotations

import json
from contextlib import contextmanager
from pathlib import Path
from threading import Thread
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from plotter_vision.bridge.server import (
    BridgeRuntimeConfig,
    LocalThreadingHTTPServer,
    PlotterBridge,
    _make_handler,
)
from plotter_vision.config import MachineConfig


def test_codex_snapshot_reads_app_artifacts_without_status_poll(tmp_path: Path) -> None:
    app_state_path = tmp_path / "app_state.json"
    app_event_log_path = tmp_path / "app_events.jsonl"
    app_state_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_type": "plotter_app_state",
                "updated_at": "2026-06-20T17:00:00Z",
                "app_build_id": "app-build-123",
                "lifecycle_label": "Hardware Standby",
                "bridge": {"status_text": "Hardware Standby ready"},
                "machine": {"state": "DryRun", "pins": "-"},
                "paper": {"status": "PAPER --"},
                "gates": {"motion": "Motion blocked: dry-run bridge"},
            }
        ),
        encoding="utf-8",
    )
    app_event_log_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "artifact_type": "plotter_app_event",
                "timestamp": "2026-06-20T17:00:01Z",
                "event": "bridge.health.completed",
                "status": "completed",
                "bridge": {"lifecycle_label": "Hardware Standby"},
            }
        )
        + "\n",
        encoding="utf-8",
    )
    bridge = _bridge(
        tmp_path=tmp_path,
        app_state_path=app_state_path,
        app_event_log_path=app_event_log_path,
    )

    with _running_bridge(bridge) as client:
        status_code, snapshot = client.get("/codex/snapshot")

    assert status_code == 200
    assert snapshot["read_only"] is True
    assert snapshot["health"]["dry_run"] is True
    assert snapshot["machine"]["status"] == "dry_run"
    assert snapshot["machine"]["state"] == "DryRun"
    assert snapshot["app_diagnostics"]["latest_state"]["payload"]["lifecycle_label"] == (
        "Hardware Standby"
    )
    assert snapshot["app_diagnostics"]["latest_state"]["app_build_id"] == "app-build-123"
    assert snapshot["app_diagnostics"]["latest_event"]["event_type"] == (
        "bridge.health.completed"
    )
    assert not list((tmp_path / "transcripts").glob("status-*.jsonl"))


def test_app_diagnostic_ingest_is_visible_in_codex_snapshot(tmp_path: Path) -> None:
    app_state_path = tmp_path / "app_state.json"
    app_event_log_path = tmp_path / "app_events.jsonl"
    bridge = _bridge(
        tmp_path=tmp_path,
        app_state_path=app_state_path,
        app_event_log_path=app_event_log_path,
    )

    with _running_bridge(bridge) as client:
        state_status, state_response = client.post(
            "/codex/app/state",
            {
                "source": "macos_app",
                "observed_at": "2026-06-20T17:01:00Z",
                "app_build_id": "app-build-456",
                "bridge_url": "http://127.0.0.1:8765",
                "status": "reported",
                "payload": {
                    "lifecycle_label": "Preview Bridge",
                    "machine": {"state": "DryRun"},
                    "paper": {"status": "PAPER --"},
                },
            },
        )
        event_status, event_response = client.post(
            "/codex/app/events",
            {
                "source": "macos_app",
                "event_type": "machine.stop.blocked",
                "observed_at": "2026-06-20T17:01:01Z",
                "app_build_id": "app-build-456",
                "status": "blocked",
                "payload": {"reason": "Motion blocked: dry-run bridge"},
            },
        )
        snapshot_status, snapshot = client.get("/codex/snapshot")
        events_status, events = client.get("/events")

    assert state_status == 200
    assert state_response["command_control"] is False
    assert state_response["event_log_appended"] is True
    assert state_response["record"]["kind"] == "state"
    assert event_status == 200
    assert event_response["record"]["kind"] == "event"
    assert snapshot_status == 200
    assert snapshot["app_diagnostics"]["latest_state"]["payload"]["lifecycle_label"] == (
        "Preview Bridge"
    )
    assert snapshot["app_diagnostics"]["latest_event"]["event_type"] == "machine.stop.blocked"
    assert app_state_path.exists()
    assert app_event_log_path.exists()
    assert events_status == 200
    assert any(
        event["type"] == "app.diagnostics_ingested"
        for event in events["events"]
    )


class _BridgeClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url

    def get(self, path: str) -> tuple[int, dict[str, Any]]:
        return self._request("GET", path)

    def post(self, path: str, payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return self._request("POST", path, payload=payload)

    def _request(
        self,
        method: str,
        path: str,
        payload: dict[str, Any] | None = None,
    ) -> tuple[int, dict[str, Any]]:
        request = Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload or {}).encode("utf-8") if method == "POST" else None,
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


def _bridge(
    *,
    tmp_path: Path,
    app_state_path: Path,
    app_event_log_path: Path,
) -> PlotterBridge:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.save_json(config_path)
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=True,
            mock=False,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            app_state_path=app_state_path,
            app_event_log_path=app_event_log_path,
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )
