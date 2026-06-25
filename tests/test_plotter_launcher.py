import json
import os
import subprocess
import textwrap
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "scripts" / "plotter_launcher.sh"
INSTALLER = ROOT / "scripts" / "install_launcher_shortcuts.sh"


def _write_executable(path: Path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")
    path.chmod(0o755)


def _run_launcher(
    tmp_path: Path,
    *args: str,
    health: str | None,
    lsof_output: str = "",
) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
    make_log = tmp_path / "make.log"
    status_path = tmp_path / "launcher_status.json"
    fake_make = tmp_path / "fake_make.sh"
    fake_curl = tmp_path / "fake_curl.sh"
    fake_lsof = tmp_path / "fake_lsof.sh"

    _write_executable(
        fake_make,
        """\
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$*" >> "$PLOTTER_FAKE_MAKE_LOG"
        """,
    )
    _write_executable(
        fake_curl,
        """\
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "${PLOTTER_FAKE_CURL_EXIT:-0}" != "0" ]]; then
          exit "$PLOTTER_FAKE_CURL_EXIT"
        fi
        printf '%s' "${PLOTTER_FAKE_HEALTH:-}"
        """,
    )
    _write_executable(
        fake_lsof,
        """\
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ -n "${PLOTTER_FAKE_LSOF_OUTPUT:-}" ]]; then
          printf '%s\\n' "$PLOTTER_FAKE_LSOF_OUTPUT"
          exit 0
        fi
        exit 1
        """,
    )

    env = os.environ.copy()
    env.update(
        {
            "PLOTTER_LAUNCHER_MAKE": str(fake_make),
            "PLOTTER_LAUNCHER_CURL": str(fake_curl),
            "PLOTTER_LAUNCHER_LSOF": str(fake_lsof),
            "PLOTTER_LAUNCHER_STATUS_PATH": str(status_path),
            "PLOTTER_FAKE_MAKE_LOG": str(make_log),
            "PLOTTER_FAKE_LSOF_OUTPUT": lsof_output,
        }
    )
    if health is None:
        env["PLOTTER_FAKE_CURL_EXIT"] = "22"
    else:
        env["PLOTTER_FAKE_CURL_EXIT"] = "0"
        env["PLOTTER_FAKE_HEALTH"] = health

    result = subprocess.run(
        ["bash", str(LAUNCHER), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    return result, make_log, status_path


@pytest.mark.parametrize("script", [LAUNCHER, INSTALLER])
def test_launcher_shell_scripts_parse(script: Path) -> None:
    subprocess.run(["bash", "-n", str(script)], cwd=ROOT, check=True)


def test_smart_reuses_live_bridge_without_safe_restart(tmp_path: Path) -> None:
    result, make_log, status_path = _run_launcher(
        tmp_path,
        "smart",
        health='{ "controller" : "serial:/dev/cu.usbserial-live@115200", "dry_run" : false }',
    )

    assert result.returncode == 0, result.stderr
    assert "LIVE bridge is already running" in result.stdout
    make_invocation = make_log.read_text(encoding="utf-8")
    assert make_invocation.split()[-1] == "app"
    assert "standby-app" not in make_invocation
    assert "bridge-live-restart" not in make_invocation

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["detected"] == "live"
    assert status["target"] == "app"
    assert status["action"] == "preserve_external_live_open_app"
    assert status["safe_restart"] is False


@pytest.mark.parametrize(
    ("controller", "expected_label"),
    [
        ("mock", "preview"),
        ("serial:/dev/cu.usbserial-standby@115200", "standby"),
    ],
)
def test_smart_dry_run_bridge_uses_safe_standby_restart(
    tmp_path: Path,
    controller: str,
    expected_label: str,
) -> None:
    result, make_log, status_path = _run_launcher(
        tmp_path,
        "smart",
        health=f'{{ "controller" : "{controller}", "dry_run" : true }}',
    )

    assert result.returncode == 0, result.stderr
    make_invocation = make_log.read_text(encoding="utf-8")
    assert make_invocation.split()[-1] == "app"
    assert "standby-app" not in make_invocation
    assert "bridge-live-restart" not in make_invocation

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["detected"] == expected_label
    assert status["target"] == "app"
    assert status["action"] == "stop_external_dry_run_open_app"
    assert status["safe_restart"] is True


def test_smart_refuses_unknown_listener_without_make_restart(tmp_path: Path) -> None:
    result, make_log, status_path = _run_launcher(
        tmp_path,
        "smart",
        health=None,
        lsof_output="12345",
    )

    assert result.returncode == 0
    assert "Not killing an unknown process" in result.stderr
    make_invocation = make_log.read_text(encoding="utf-8")
    assert make_invocation.split()[-1] == "app"

    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["detected"] == "unknown"
    assert status["target"] == "app"
    assert status["action"] == "ignore_unknown_listener_open_app"
    assert status["safe_restart"] is False


def test_launcher_status_smoke_writes_build_identity(tmp_path: Path) -> None:
    status_path = tmp_path / "launcher_status.json"
    env = os.environ.copy()
    env["PLOTTER_LAUNCHER_STATUS_PATH"] = str(status_path)
    env["PLOTTER_BUILD_ID"] = "test-build-id"
    env["HTTP_PORT"] = "9876"

    result = subprocess.run(
        ["bash", str(LAUNCHER), "status-smoke"],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "[plotter-launch +" in result.stderr
    assert "launcher mode: status-smoke http_port=9876" in result.stderr
    assert "launcher status: wrote" in result.stderr
    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["schema_version"] == 1
    assert status["mode"] == "status-smoke"
    assert status["action"] == "write_status_smoke"
    assert status["build_id"] == "test-build-id"
    assert status["bridge_url"] == "http://127.0.0.1:9876/health"
    assert status["safe_restart"] is False
