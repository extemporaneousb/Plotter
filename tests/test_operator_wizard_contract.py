from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "macos" / "PlotterVisionCameraDemo" / "Sources" / "PlotterVisionCameraDemo"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_operator_ui_exposes_only_wizard_calibration_path() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
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
    assert "private var visualControlsMenu" in content
    assert "private var drawingTestsMenu" in content
    assert "startCalibrationWizard" in content


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
    build_script = _read(ROOT / "macos" / "PlotterVisionCameraDemo" / "build.sh")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")

    assert "PlotterRequiredBridgeAPIVersion integer 3" in build_script
    assert "var hasBridgeContractMismatch" in client
    assert "hasLifecycleBuildMismatch { return \"Motion blocked" in client
    assert "guard let rawVersion = cleanBridgeMetadata(bridgeApiVersion)" in client
    assert "return true" in client.split("var hasBridgeApiMismatch", 1)[1].split("var hasBridgeContractMismatch", 1)[0]


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
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")

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
    assert "func resetVisualCalibrationSession" in client
    assert '"visual_calibration_session_reset"' in client


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
