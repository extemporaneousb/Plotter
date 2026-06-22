from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "macos" / "PlotterVision" / "Sources" / "PlotterVision"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_operator_ui_exposes_only_wizard_calibration_path() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    draw_verify = _read(SWIFT_DIR / "DrawVerifyMenu.swift")
    visual_controls = _read(SWIFT_DIR / "VisualControlsMenu.swift")
    removed_labels = [
        "Triangle Residual Runner Pending",
        "Square Residual Runner Pending",
        "Circle Residual Runner Pending",
        "Scan Plotter Frame",
        "Reset Change Baseline",
        "Hide Fiducials",
        "Show Fiducials",
        "Start Model Session",
        "Run Center Dot Motion",
        "Calibrate Pen: Mark Current Cap",
        "Preview Center Mark",
        "Run Visual Center Mark",
        "Preview 5-Point Marks",
        "Run Visual 5-Point Marks",
        "FID auto",
    ]

    for label in removed_labels:
        assert label not in content
    assert "private var calibrationMenu" not in content
    assert "VisualControlsMenu(" in content
    assert "DrawVerifyMenu(" in content
    assert "struct VisualControlsMenu" in visual_controls
    assert "struct DrawVerifyMenu" in draw_verify
    assert "startCalibrationWizard" in content


def test_app_uses_canonical_plotter_vision_paths_without_stale_names() -> None:
    stale_word = "de" + "mo"
    stale_app_name = f"PlotterVisionCamera{stale_word.capitalize()}"

    assert (ROOT / "macos" / "PlotterVision" / "build.sh").exists()
    assert SWIFT_DIR.exists()
    assert not (ROOT / "macos" / stale_app_name).exists()

    tracked = subprocess.run(
        ["git", "ls-files"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.splitlines()
    assert all(stale_word not in path.lower() for path in tracked)

    grep = subprocess.run(
        ["git", "grep", "-n", "-i", stale_word, "--", "."],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert grep.returncode == 1, grep.stdout


def test_draw_verify_operator_surface_replaces_tests_menu() -> None:
    swift_text = "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    draw_verify = _read(SWIFT_DIR / "DrawVerifyMenu.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "Draw/Verify" in draw_verify
    assert "Run Verified Capability" in draw_verify
    assert "previewDrawVerifyCapability" in model
    assert "runVerifiedDrawVerifyCapability" in model
    assert "expectedPlanHash: expectedHash" in model
    assert 'label: "Tests"' not in swift_text
    assert "drawingTestsMenu" not in swift_text
    assert "TEST " not in swift_text


def test_swift_app_split_keeps_transport_client_separate_from_app_model() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert (SWIFT_DIR / "CalibrationWizardView.swift").exists()
    assert (SWIFT_DIR / "CameraOverlaySupportViews.swift").exists()
    assert (SWIFT_DIR / "DrawVerifyCoordinator.swift").exists()
    assert "final class PlotterBridgeModel" not in client
    assert "final class PlotterBridgeModel" in model
    assert len(content.splitlines()) < 3500


def test_swift_auto_red_fiducial_path_is_removed() -> None:
    swift_text = "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    removed_terms = [
        "fiducialDetectionEnabled",
        "redFiducialsEnabled",
        "detectRedFiducials",
        "FiducialMark",
        "PaperCalibrationObservation",
        "paperRegistration:",
    ]

    for term in removed_terms:
        assert term not in swift_text


def test_bridge_contract_requires_api_3_and_gates_build_mismatch() -> None:
    build_script = _read(ROOT / "macos" / "PlotterVision" / "build.sh")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "PlotterRequiredBridgeAPIVersion integer 3" in build_script
    assert "var hasBridgeContractMismatch" in model
    assert "hasLifecycleBuildMismatch { return \"Motion blocked" in model
    assert "guard let rawVersion = cleanBridgeMetadata(bridgeApiVersion)" in model
    assert "return true" in model.split("var hasBridgeApiMismatch", 1)[1].split("var hasBridgeContractMismatch", 1)[0]


def test_wizard_drives_visual_position_binding_loop() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")

    assert "Preview Binding Marks" in content
    assert "Run Binding Marks" in content
    assert "recordVisualBindingInkObservation" in content
    assert "observeVisualBindingPoint" in content
    assert "solveVisualBinding" in content
    assert "visualBindingValid" in content
    assert "BridgeVisualBindingObservationRequest" in client
    assert 'post(path: "calibration/binding/observe"' in client
    assert 'post(path: "calibration/binding/solve"' in client


def test_visual_probe_reacquires_cap_before_stopping() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "visualCapReacquireMaxAttempts" in content
    assert "reacquireGreenCapByXAxis" in content
    assert "waitForFreshGreenCapPaperObservation" in content
    assert '"visual_cap_reacquire_started"' in content
    assert '"visual_cap_reacquired"' in content
    assert '"visual_target_no_new_frame"' in content
    assert '"probe_after_move"' in content
    assert "preferredXReacquireDirection(opposingCommandX: commandX)" in content
    assert "preferredXReacquireDirection(opposingCommandX: commandDx)" in content
    assert "resetVisualCalibrationSession(prefix: \"swift-probe\")" in content
    assert "func resetVisualCalibrationSession" in model
    assert '"visual_calibration_session_reset"' in model


def test_removed_bridge_routes_and_red_detection_support_are_absent() -> None:
    server = _read(ROOT / "plotter_vision" / "bridge" / "server.py")
    paper = _read(ROOT / "plotter_vision" / "calibration" / "paper.py")

    removed_terms = [
        "/calibration/start",
        "/calibration/observe",
        "/calibration/status",
        "CalibrationStartRequest",
        "CalibrationObservationRequest",
        "CalibrationSessionResponse",
        "start_calibration",
        "add_calibration_observation",
        "calibration_status",
        "PaperFiducialDetection",
        "build_paper_registration_from_red_fiducials",
        "red_fiducial",
    ]

    for term in removed_terms:
        assert term not in server
        assert term not in paper
