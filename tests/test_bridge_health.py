from __future__ import annotations

import json
import os
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from threading import Thread
from typing import Any, Iterator
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from plotter_vision.bridge.server import (
    BRIDGE_API_VERSION,
    BRIDGE_BUILD_ID,
    BRIDGE_SOURCE_ROOT,
    BridgeRuntimeConfig,
    LocalThreadingHTTPServer,
    PlotterBridge,
    _make_handler,
)
from plotter_vision.config import MachineConfig


def test_health_endpoint_reports_mock_preview_lifecycle_and_identity(tmp_path: Path) -> None:
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=_write_machine_config(tmp_path),
        dry_run=True,
        mock=True,
    )

    with _running_bridge(bridge) as client:
        status_code, health = client.get("/health")

    assert status_code == 200
    assert health["schema"] == 2
    assert health["status"] == "ready"
    assert health["dry_run"] is True
    assert health["controller"] == "mock"
    assert health["lifecycle_mode"] == "mock_preview"
    assert health["lifecycle_label"] == "Preview Bridge"
    assert health["can_restart_safely"] is True
    assert health["arm_motion"] is False
    assert health["arm_pen"] is False
    assert health["arm_homing"] is False
    assert health["arm_unlock"] is False
    _assert_identity_fields(health, bridge)


def test_health_endpoint_reports_hardware_standby_dry_run_lifecycle(
    tmp_path: Path,
) -> None:
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=_write_machine_config(tmp_path),
        dry_run=True,
        mock=False,
    )

    with _running_bridge(bridge) as client:
        status_code, health = client.get("/health")

    assert status_code == 200
    assert health["dry_run"] is True
    assert health["controller"] == "unconfigured"
    assert health["lifecycle_mode"] == "hardware_standby"
    assert health["lifecycle_label"] == "Hardware Standby"
    assert health["can_restart_safely"] is True
    _assert_identity_fields(health, bridge)


def test_health_endpoint_reports_live_lifecycle_and_blocks_safe_restart(
    tmp_path: Path,
) -> None:
    bridge = _bridge(
        tmp_path=tmp_path,
        config_path=_write_machine_config(tmp_path),
        dry_run=False,
        mock=True,
        arm_motion=True,
        arm_pen=True,
        arm_homing=True,
        arm_unlock=True,
    )

    with _running_bridge(bridge) as client:
        status_code, health = client.get("/health")

    assert status_code == 200
    assert health["dry_run"] is False
    assert health["controller"] == "mock"
    assert health["lifecycle_mode"] == "live"
    assert health["lifecycle_label"] == "Live Bridge"
    assert health["can_restart_safely"] is False
    assert health["arm_motion"] is True
    assert health["arm_pen"] is True
    assert health["arm_homing"] is True
    assert health["arm_unlock"] is True
    _assert_identity_fields(health, bridge)


def _assert_identity_fields(health: dict[str, Any], bridge: PlotterBridge) -> None:
    assert health["bridge_api_version"] == BRIDGE_API_VERSION
    assert health["bridge_build_id"] == BRIDGE_BUILD_ID
    assert health["bridge_source_root"] == str(BRIDGE_SOURCE_ROOT)
    assert health["bridge_pid"] == os.getpid()
    assert health["bridge_started_at"] == bridge.health().bridge_started_at
    datetime.fromisoformat(health["bridge_started_at"])
    assert health["event_log"].endswith("events.jsonl")
    assert health["workspace_x_mm"] == 533.4
    assert health["workspace_y_mm"] == 215.9


class _BridgeClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url

    def get(self, path: str) -> tuple[int, dict[str, Any]]:
        return self._request("GET", path)

    def _request(self, method: str, path: str) -> tuple[int, dict[str, Any]]:
        request = Request(
            f"{self.base_url}{path}",
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
    config_path: Path,
    dry_run: bool,
    mock: bool,
    arm_motion: bool = False,
    arm_pen: bool = False,
    arm_homing: bool = False,
    arm_unlock: bool = False,
) -> PlotterBridge:
    return PlotterBridge(
        BridgeRuntimeConfig(
            dry_run=dry_run,
            mock=mock,
            arm_motion=arm_motion,
            arm_pen=arm_pen,
            arm_homing=arm_homing,
            arm_unlock=arm_unlock,
            config_path=config_path,
            event_log_path=tmp_path / "events.jsonl",
            transcript_dir=tmp_path / "transcripts",
            calibration_dir=tmp_path / "calibration",
            workspace_x_max=533.4,
            workspace_y_max=215.9,
        )
    )


def _write_machine_config(tmp_path: Path) -> Path:
    config_path = tmp_path / "machine_config.json"
    machine = MachineConfig()
    machine.set_axis_travel(x_travel_mm=533.4, y_travel_mm=215.9)
    machine.save_json(config_path)
    return config_path
