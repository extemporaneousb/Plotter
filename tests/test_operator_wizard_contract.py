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
    assert "Confirm Setup" in content + _read(SWIFT_DIR / "CalibrationWizardView.swift")


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


def test_draw_verify_portrait_preview_uses_burst_capture_and_bridge_preview_route() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    draw_verify = _read(SWIFT_DIR / "DrawVerifyMenu.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    overlays = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    portrait_panel = _read(SWIFT_DIR / "PortraitPanel.swift")

    assert "Preview Portrait Contours" not in draw_verify
    assert 'Label("Create \\(bridge.portraitContourSettings.technique.captureLabel) Drawing"' in portrait_panel
    assert "PortraitPanel(" in content
    assert "portraitPanelVisible" in content
    assert "portraitPanelVisible.toggle()" in content
    assert "canCreateContourDrawing: faceCamera.isRunning && !bridge.isCalibrating" in content
    assert "portraitContourMonitorEnabled" in content
    assert "runPortraitContourMonitor" in content
    assert "captureFaceRaster(" in content
    assert "columns: 28" in content
    assert "updatesStatus: false" in content
    assert "PortraitCaptureThumbnail" in portrait_panel
    assert "captureFaceRasterBurst(columns: 28, rows: 36)" in content
    assert "bridge.expectedPathSegments = []" in content
    assert "technique: technique" in content
    assert "portraitContourMonitorEnabled = false" in content
    assert "func captureFaceRasterBurst" in camera_model
    assert "targetFrames: Int = 24" in camera_model
    assert "previewPortraitContours(" in content
    assert "settings: bridge.portraitContourSettings" in content
    assert "func previewPortraitContours" in model
    assert "enum PortraitRenderTechnique" in models
    assert "case hatch" in models
    assert "case crosshatch" in models
    assert "case facets" in models
    assert "case stipple" in models
    assert "Picker(\"Mode\"" in portrait_panel
    assert "settingsTechniqueBinding()" in portrait_panel
    assert "BridgePortraitContourPreviewRequest" in client
    assert "let technique: String" in client
    assert "technique: settings.technique.rawValue" in model
    assert "BridgePortraitContourOverlay" in client
    assert "portraitOverlay" in client
    assert 'post(path: "draw/portrait/preview"' in client
    assert "BridgePortraitContourOptionsRequest" in model
    assert "struct PortraitContourSettings" in models
    assert "portraitContourSettings" in model
    assert "struct FaceContourPreviewOverlay" in models
    assert "faceContourPreviewOverlay" in model
    assert "makeFaceContourPreviewOverlay(" in model
    assert "response.portraitOverlay" in model
    assert "makeFallbackFaceContourPreviewOverlay(" in model
    assert "settings: settings" in model
    assert "updateLivePortraitContourPreview" in model
    assert "fallbackHatchPolylines(" in model
    assert "fallbackFacetPolylines(" in model
    assert "fallbackStipplePolylines(" in model
    assert "fallbackContours(values: values" in model
    assert "PortraitContourPreviewOverlay(" in content
    assert "struct PortraitContourPreviewOverlay" in overlays
    portrait_preview_block = model.split("func previewPortraitContours", 1)[1].split(
        "func replayExpectedPath", 1
    )[0]
    assert 'revealExpectedPathImmediately(status: "FULL PREVIEW")' in portrait_preview_block
    assert "animateExpectedPath" not in portrait_preview_block
    assert "func revealExpectedPathImmediately" in model


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
    assert "private func liveMachineCommandBlockReason" in model
    assert "var canRunLiveRelativeMotionCommand" in model
    assert "private func liveRelativeMotionBlockReason" in model
    assert "hasBridgeApiMismatch { return \"Motion blocked" in model.split(
        "private func liveMachineCommandBlockReason",
        1,
    )[1]
    assert "hasLifecycleBuildMismatch { return \"Motion blocked" in model.split(
        "private func liveMachineCommandBlockReason",
        1,
    )[1]
    assert "liveMachineCommandBlockReason(allowBusy: allowBusy)" in model.split(
        "private func liveRelativeMotionBlockReason",
        1,
    )[1]
    assert "guard canRunLiveRelativeMotionCommand else" in model.split(
        "func visualRelativeMove",
        1,
    )[1].split("func dotMarkCurrentPosition", 1)[0]
    assert "guard canRunLiveRelativeMotionCommand else" in model.split(
        "func relativeMarkCurrentPosition",
        1,
    )[1].split("func stopMachine", 1)[0]
    assert "if let blockReason = liveMachineCommandBlockReason" in model.split(
        "private func runMachineCommand",
        1,
    )[1]
    assert '"can_run_visual_relative_motion": canRunLiveRelativeMotionCommand' in model


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


def test_visual_binding_loop_retries_observably_and_draws_bounds_frame() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    runner = _read(SWIFT_DIR / "VisualBindingMarkRunner.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")
    models = _read(SWIFT_DIR / "Models.swift")

    assert "visualBindingMaxMarkAttempts = 4" in runner
    assert "visualBindingParkOffsetsMm = [32.0, -32.0, 44.0, -44.0]" in runner
    assert "visual_binding_mark_attempt" in runner
    assert "visual_binding_incomplete" in content
    assert "BIND INCOMPLETE" in content
    assert "solveVisualBinding" in content
    assert content.find("guard visibleCount >= requiredObservations") < content.find("solveVisualBinding")
    assert "drawVisualBindingBoundsFrame(points: targets)" in content
    assert "VIS READY" in content
    assert "waitForFreshGreenCapPaperObservation" in content.split("func parkAwayFromMark", 1)[1]
    assert "visualMotionTravelFeedMmMin = 1200.0" in runner

    assert "horizontalDarkFraction" in models
    assert "verticalDarkFraction" in models
    assert "crossDarkFraction" in models
    assert "strokeScore" in models
    assert "inHorizontalBand" in camera_model
    assert "inVerticalBand" in camera_model

    assert "BridgeDrawProgramRequest" in client
    assert 'post(path: "draw/program"' in client
    assert "func drawVisualBindingBoundsFrame" in model
    assert '"visual_binding_bounds_frame_started"' in model
    assert '"visual_binding_bounds_frame_completed"' in model
    assert "shapeDrawFeedMmMin = 240.0" in model
    assert "machineMaxFeedMmMin = 1200.0" in model
    assert "manualFeedMmMin = 1200.0" in model


def test_wizard_can_reuse_locked_paper_setup_after_restart() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")

    assert 'Button("Confirm Setup", action: confirmSetup)' in wizard
    assert "canConfirmSetup: bridge.hasPaperLock" in content
    assert "confirmSetup: confirmWizardSetupFromExistingRegistration" in content
    assert "private func confirmWizardSetupFromExistingRegistration" in content
    assert '"wizard_setup_confirmed"' in content
    assert "Visual Field Setup" in wizard
    assert "Paper Homography" not in wizard
    assert "Stored visual field in use" in content
    assert "FIELD visual field ready; confirm setup if grid aligns" in content

    primary_title = content.split("private var wizardPrimaryActionTitle", 1)[1].split(
        "private var wizardPrimaryActionEnabled",
        1,
    )[0]
    primary_action = content.split("private func runCalibrationWizardPrimaryAction", 1)[1].split(
        "private func startCalibrationWizard",
        1,
    )[0]
    assert primary_title.find("if !bridge.hasPaperLock") < primary_title.find("Start Fiducial Clicks")
    assert primary_action.find("if !bridge.hasPaperLock") < primary_action.find("startCalibrationWizard()")


def test_visual_machine_setup_uses_clearance_aware_motion() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "visualMachineCalibrationProbeDistances" in content
    assert "visualMachineCalibrationBoundedDistance" in content
    assert "visualFieldRecoveryCommandMm" in content
    assert "No safe X/Y calibration travel from current machine position" in content
    assert "boundedMachineTravelDistance" in model
    assert "availableMachineTravelMm" in model
    assert "previewBootstrapAdaptiveProbe(" not in content
    assert "runBootstrapAdaptiveProbe(" not in content
    assert "previewBootstrapAdaptiveProbe(" not in model
    assert "runBootstrapAdaptiveProbe(" not in model


def test_plotter_view_focus_is_persisted_ui_state_and_click_safe() -> None:
    models = _read(SWIFT_DIR / "Models.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    visual_controls = _read(SWIFT_DIR / "VisualControlsMenu.swift")
    content = _read(SWIFT_DIR / "ContentView.swift")
    viewport_intent = _read(SWIFT_DIR / "ContentViewViewportIntent.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")

    assert "enum PlotterViewportFocusMode" in models
    assert "var focusMode = PlotterViewportFocusMode.original" in models
    assert "var zoomScale = 1.0" in models
    assert "var zoomCenterX = 0.5" in models
    assert "var zoomCenterY = 0.5" in models
    assert "focusOnCameraBounds" in models
    assert "decodeIfPresent(PlotterViewportFocusMode.self, forKey: .focusMode)" in models
    assert "decodeIfPresent(Double.self, forKey: .zoomScale)" in models
    assert "plotterViewport: plotterViewport" in _read(SWIFT_DIR / "FrameStateStore.swift")

    assert "plotterViewportZoomScale(settings)" in support
    assert "plotterViewportZoomOffset(size: geometry.size, settings: settings)" in support
    assert "let unzoomed = CGPoint" in support
    assert "point.x - zoomOffset.width - center.x" in support

    assert "Section(\"Plotter View\")" in visual_controls
    assert "Original Video" in visual_controls
    assert "Zoom In" not in visual_controls
    assert "Zoom Out" not in visual_controls
    assert "Reset FOV" not in visual_controls
    assert "togglePlotterFocusMode()" in viewport_intent
    assert ".keyboardShortcut(\"f\", modifiers: [.command])" in content
    assert "focusPlotterVideoOnPaper(source: \"wizard_fiducials_solved\")" in content
    assert "focusPlotterVideoOnPaper(source: \"wizard_confirm_setup\")" in content

    assert "func captureOutput(" in camera_model
    assert "try self.analyzer.analyze(pixelBuffer: pixelBuffer" in camera_model
    assert "zoomScale" not in camera_model


def test_confirmed_cap_overlay_is_not_persistent_video_annotation() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")

    assert "ConfirmedCapOverlay(point: nil, isActive: manualPenMode)" in content
    assert "confirmedCapPoint: confirmedCapPoint" not in content
    assert "draw(confirmedCapPoint" not in overlay
    assert "CONF CAP" in _read(SWIFT_DIR / "Models.swift")


def test_visual_move_intent_is_projected_on_video() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    viewport_intent = _read(SWIFT_DIR / "ContentViewViewportIntent.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")
    models = _read(SWIFT_DIR / "Models.swift")

    assert "struct VisualMoveIntent" in models
    assert "@State var visualMoveIntent" in content
    assert "visualMoveIntent: visualMoveIntent" in content
    assert '"visual_move_intent_set"' in viewport_intent
    assert '"visual_move_intent_cleared"' in viewport_intent
    assert "CAL-BAND" in content
    assert "MOVE \\(label)" in content
    assert "drawVisualMoveIntent" in overlay
    assert "drawArrowHead" in overlay


def test_main_window_placement_only_filters_main_window_candidates() -> None:
    app_main = _read(SWIFT_DIR / "AppMain.swift")

    assert "applicationDidBecomeActive" not in app_main
    assert "isMainWindowCandidate" in app_main
    assert "window.title != PlotterWindowConfiguration.machineTitle" not in app_main
    assert "window.identifier == PlotterWindowConfiguration.mainIdentifier" in app_main
    assert "window.title == PlotterWindowConfiguration.mainTitle" in app_main


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


def test_visual_cap_gates_use_stabilized_marker_observation() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")

    assert "@Published var stabilizedCarriageMarker" in camera_model
    assert "carriageMarkerSmoothingWindow = 5" in camera_model
    assert "carriageMarkerHoldMisses = 6" in camera_model
    assert "publishCarriageMarkerObservation(visionResult.carriageMarker)" in camera_model
    assert "averagedCarriageMarker(from: carriageMarkerHistory)" in camera_model
    assert "private var currentCarriageMarker" in content
    assert "plotterCamera.stabilizedCarriageMarker ?? plotterCamera.carriageMarker" in content
    assert "visualCapFreshFrameAdvance = 3" in content
    assert "minimumFrameAdvance: visualCapFreshFrameAdvance" in content
    assert "guard let marker = currentCarriageMarker else { return nil }" in content
    assert "plotterCamera.carriageMarker != nil" not in content


def test_removed_bridge_routes_and_red_detection_support_are_absent() -> None:
    server = _read(ROOT / "plotter_vision" / "bridge" / "server.py")
    paper = _read(ROOT / "plotter_vision" / "calibration" / "paper.py")

    removed_terms = [
        "/calibration/start",
        "/calibration/observe",
        "/calibration/status",
        "/calibration/probe/preview",
        "/calibration/probe/run",
        "CalibrationStartRequest",
        "CalibrationObservationRequest",
        "CalibrationSessionResponse",
        "AdaptiveProbePreviewRequest",
        "AdaptiveProbeRunRequest",
        "AdaptiveProbeResponse",
        "start_calibration",
        "add_calibration_observation",
        "calibration_status",
        "preview_adaptive_probe",
        "run_adaptive_probe",
        "PaperFiducialDetection",
        "build_paper_registration_from_red_fiducials",
        "red_fiducial",
    ]

    for term in removed_terms:
        assert term not in server
        assert term not in paper
