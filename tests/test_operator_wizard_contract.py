from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "macos" / "PlotterVision" / "Sources" / "PlotterVision"
BRIDGE_SERVER = ROOT / "plotter_vision" / "bridge" / "server.py"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_operator_ui_uses_windowed_setup_and_video_panels() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    app_main = _read(SWIFT_DIR / "AppMain.swift")
    setup_panel = _read(SWIFT_DIR / "SetupPanel.swift")
    plotter_panel = _read(SWIFT_DIR / "PlotterVideoPanel.swift")
    face_panel = _read(SWIFT_DIR / "FaceVideoPanel.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")
    window_support = _read(SWIFT_DIR / "OperatorWindowSupport.swift")
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
        "Pick Region",
    ]

    for label in removed_labels:
        assert label not in content
    assert "private var calibrationMenu" not in content
    assert "VisualControlsMenu(" not in content
    assert "DrawVerifyMenu(" not in content
    assert not (SWIFT_DIR / "VisualControlsMenu.swift").exists()
    assert not (SWIFT_DIR / "DrawVerifyMenu.swift").exists()
    assert not (SWIFT_DIR / "ToolbarControls.swift").exists()
    assert (SWIFT_DIR / "SetupPanel.swift").exists()
    assert (SWIFT_DIR / "PlotterVideoPanel.swift").exists()
    assert (SWIFT_DIR / "FaceVideoPanel.swift").exists()
    assert (SWIFT_DIR / "OperatorWorkspaceState.swift").exists()
    assert (SWIFT_DIR / "OperatorWindowSupport.swift").exists()
    assert 'static let machineControls = "machine-controls"' in window_support
    assert 'static let setupPanel = "setup-panel"' in window_support
    assert 'static let plotterVideoPanel = "plotter-video-panel"' in window_support
    assert 'static let faceVideoPanel = "face-video-panel"' in window_support
    assert "Window(PlotterWindowConfiguration.setupTitle, id: OperatorWindowID.setupPanel)" in app_main
    assert "Window(PlotterWindowConfiguration.plotterVideoTitle, id: OperatorWindowID.plotterVideoPanel)" in app_main
    assert "Window(PlotterWindowConfiguration.faceVideoTitle, id: OperatorWindowID.faceVideoPanel)" in app_main
    assert "SetupPanel(workspace: workspace, bridge: bridge)" in app_main
    assert "PlotterVideoPanel(workspace: workspace, bridge: bridge)" in app_main
    assert "FaceVideoPanel(workspace: workspace, bridge: bridge)" in app_main
    assert "CalibrationWizardView(" in setup_panel
    assert "workspace.requestSetupCommand(.primary)" in setup_panel
    assert "Drawing examples are intentionally removed" in setup_panel
    assert "Sample Cap Color" in plotter_panel
    assert "Reset Cap Color" in plotter_panel
    assert "PortraitPanel(" in face_panel
    assert "CameraLayoutMode" not in "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    assert "CameraSelector(camera: plotterCamera)" in content
    assert "CameraSelector(camera: faceCamera)" in content
    assert "toggleCameraVisibility(plotterCamera, source: \"top_bar\")" in content
    assert "toggleCameraVisibility(faceCamera, source: \"top_bar\")" in content
    assert "if workspace.plotterCameraVisible && workspace.faceCameraVisible" in content
    assert "else if workspace.plotterCameraVisible" in content
    assert "else if workspace.faceCameraVisible" in content
    assert "emptyCameraWorkspace" in content
    assert "NO CAMERA SELECTED" in content
    assert "@Published var plotterCameraVisible = false" in workspace
    assert "@Published var faceCameraVisible = false" in workspace
    assert '"split_plane": plotterCameraVisible && faceCameraVisible' in workspace
    assert '"empty": !plotterCameraVisible && !faceCameraVisible' in workspace
    assert "Sample Cap Color" not in _read(SWIFT_DIR / "CalibrationWizardView.swift")
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


def test_draw_verify_examples_are_removed_from_operator_surface() -> None:
    swift_text = "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert not (SWIFT_DIR / "DrawVerifyMenu.swift").exists()
    assert not (SWIFT_DIR / "DrawVerifyCoordinator.swift").exists()
    assert "DrawVerifyMenu(" not in swift_text
    assert "DrawVerifyCoordinator" not in swift_text
    assert "previewDrawVerifyCapability" not in model
    assert "runVerifiedDrawVerifyCapability" not in model
    assert "previewShapeOverlay(" not in model
    assert "drawTriangle(" not in model
    assert "BridgeShapeExecutionRequest" not in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    assert "drawFaceRaster(" not in model
    assert "BridgeFaceRasterDrawRequest" not in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    assert "Preview Triangle Shape" not in swift_text
    assert "Preview Square Shape" not in swift_text
    assert "Run Verified Capability" not in swift_text
    assert "drawingTestsMenu" not in swift_text
    assert "TEST " not in swift_text
    assert "drawVisualBindingBoundsFrame" in model


def test_draw_verify_portrait_preview_uses_burst_capture_and_bridge_preview_route() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    face_panel = _read(SWIFT_DIR / "FaceVideoPanel.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    overlays = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    portrait_panel = _read(SWIFT_DIR / "PortraitPanel.swift")

    assert "Preview Portrait Contours" not in "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    assert 'Label("Create \\(bridge.portraitContourSettings.technique.captureLabel) Drawing"' in portrait_panel
    assert "PortraitPanel(" in face_panel
    assert "portraitPanelVisible" not in content
    assert "canCreateContourDrawing: workspace.faceCamera.isRunning && !bridge.isCalibrating" in face_panel
    assert "workspace.requestPanelCommand(.createPortraitDrawing)" in face_panel
    assert "workspace.requestPanelCommand(.selectPortraitCapture(item.id))" in face_panel
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
    assert not (SWIFT_DIR / "DrawVerifyCoordinator.swift").exists()
    assert "final class PlotterBridgeModel" not in client
    assert "final class PlotterBridgeModel" in model
    assert len(content.splitlines()) < 3700


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

    assert "Run Drawing Calibration" in content
    assert "runWizardDrawingCalibration()" in content
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
    assert "visualBindingMarkClearance(" in runner
    assert "clearance_failed" in runner
    assert "clearance_blocker" in runner
    assert "visual_binding_incomplete" in content
    assert "BIND INCOMPLETE" in content
    assert "solveVisualBinding" in content
    assert content.find("guard visibleCount >= requiredObservations") < content.find("solveVisualBinding")
    assert "drawVisualBindingBoundsFrame(points: targets)" in content
    assert "VIS READY" in content
    assert "waitForFreshGreenCapPaperObservation" in content.split("func parkAwayFromMark", 1)[1]
    assert "visualMotionTravelFeedMmMin = 1200.0" in runner
    assert "maximumCommandCapMm = 30.0" in content

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
    assert "resetCalibrationSetup()" in content
    assert 'post(path: "calibration/setup/reset"' in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    assert "Visual Field Setup" in wizard
    assert "Paper Homography" not in wizard
    assert "Paper homography" not in content
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


def test_visual_field_setup_uses_four_stage_binding_workflow_without_tip_click() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    server = _read(BRIDGE_SERVER)
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")

    assert 'title: "Fiducials"' in wizard
    assert 'title: "Green Cap"' in wizard
    assert 'title: "Motion Calibration"' in wizard
    assert 'title: "Drawing Calibration"' in wizard
    assert 'title: "Visual Field"' not in wizard
    assert 'title: "Tool"' not in wizard
    assert "Draw/Verify" not in wizard
    assert "Click Pen Tip" not in wizard
    assert "Move Field" not in wizard
    assert "onSelect" not in support
    assert "Button {" not in support.split("struct CalibrationWizardStepRow", 1)[1].split("struct PlotterViewportTransform", 1)[0]

    assert "private func startManualPenTipClick" not in content
    assert "private func recordConfirmedPenTip" not in content
    assert "manualPenTipMode" not in content
    assert "confirmedPenTipPoint" not in content
    assert "rollbackCalibrationWizardToStep" not in content
    assert "Click Green Cap" in content
    assert "Confirm Green Cap" in content
    assert "Run Motion Calibration" in content
    assert "Run Drawing Calibration" in content
    assert "runWizardDrawingCalibration()" in content
    assert "previewBindingMarks(pointSet: \"five\")" in content
    assert "runVisualRelativeFivePointTest()" in content
    assert "pen tip not confirmed" not in content
    assert "estimateToolOffset(" not in content + model
    assert "BridgeToolEstimateRequest" not in client
    assert 'post(path: "calibration/tool/estimate"' not in client
    assert "ToolEstimateRequest" not in server
    assert "estimate_tool_offset" not in server
    assert '"/calibration/tool/estimate"' not in server
    assert "@Published var bindingExtraPaddingMm = 40.0" in model
    assert "learnedCapToTipModel" in model
    assert "toolCapToTipModel" not in content + model
    assert "Need binding mark observations" in model


def test_visual_machine_setup_uses_clearance_aware_motion() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "visualMachineCalibrationProbeDistances" in content
    assert "visualMachineCalibrationBoundedDistance" in content
    assert "No safe X/Y calibration travel from current machine position" in content
    assert "boundedMachineTravelDistance" in model
    assert "availableMachineTravelMm" in model
    assert "visualCapReacquireCommands" in content
    assert "x_field_recovery_prompted" not in content
    assert "Move X into camera field?" not in content
    assert "previewBootstrapAdaptiveProbe(" not in content
    assert "runBootstrapAdaptiveProbe(" not in content
    assert "previewBootstrapAdaptiveProbe(" not in model
    assert "runBootstrapAdaptiveProbe(" not in model


def test_plotter_view_focus_is_persisted_ui_state_and_click_safe() -> None:
    models = _read(SWIFT_DIR / "Models.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    plotter_panel = _read(SWIFT_DIR / "PlotterVideoPanel.swift")
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

    assert "panelSectionTitle(\"Viewport\")" in plotter_panel
    assert "Original Video" in plotter_panel
    assert "Fit Field" in plotter_panel
    assert "Zoom In" not in plotter_panel
    assert "Zoom Out" not in plotter_panel
    assert "Reset FOV" not in plotter_panel
    assert "togglePlotterFocusMode()" in viewport_intent
    assert "focusPlotterVideoOnPaper(source: \"wizard_fiducials_solved\")" in content
    assert "focusPlotterVideoOnPaper(source: \"wizard_confirm_setup\")" in content

    assert "func captureOutput(" in camera_model
    assert "try self.analyzer.analyze(pixelBuffer: pixelBuffer" in camera_model
    assert "zoomScale" not in camera_model


def test_confirmed_cap_overlay_is_not_persistent_video_annotation() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")

    assert "ConfirmedCapOverlay(point: confirmedCapPoint, isActive: manualPenMode)" in content
    assert "confirmedCapPoint: confirmedCapPoint" not in content
    assert "draw(confirmedCapPoint" not in overlay
    assert "CONF CAP" in _read(SWIFT_DIR / "Models.swift")


def test_visual_move_intent_is_projected_on_video() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")
    viewport_intent = _read(SWIFT_DIR / "ContentViewViewportIntent.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")
    models = _read(SWIFT_DIR / "Models.swift")

    assert "struct VisualMoveIntent" in models
    assert "@Published var visualMoveIntent" in workspace
    assert "var visualMoveIntent: VisualMoveIntent?" in content
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
    assert "OperatorWindowID.machineControls" in app_main
    assert "OperatorWindowID.setupPanel" in app_main
    assert "OperatorWindowID.plotterVideoPanel" in app_main
    assert "OperatorWindowID.faceVideoPanel" in app_main


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
