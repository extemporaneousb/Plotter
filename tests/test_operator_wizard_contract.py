from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_DIR = ROOT / "macos" / "PlotterVision" / "Sources" / "PlotterVision"
BRIDGE_SERVER = ROOT / "plotter_vision" / "bridge" / "server.py"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_operator_ui_uses_in_main_setup_wizard_and_windowed_video_panels() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    app_main = _read(SWIFT_DIR / "AppMain.swift")
    plotter_panel = _read(SWIFT_DIR / "PlotterVideoPanel.swift")
    face_panel = _read(SWIFT_DIR / "FaceVideoPanel.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")
    window_support = _read(SWIFT_DIR / "OperatorWindowSupport.swift")
    swift_text = "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
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
    assert not (SWIFT_DIR / "SetupPanel.swift").exists()
    assert (SWIFT_DIR / "PlotterVideoPanel.swift").exists()
    assert (SWIFT_DIR / "FaceVideoPanel.swift").exists()
    assert (SWIFT_DIR / "OperatorWorkspaceState.swift").exists()
    assert (SWIFT_DIR / "OperatorWindowSupport.swift").exists()
    assert 'static let machineControls = "machine-controls"' in window_support
    assert 'static let setupPanel = "setup-panel"' not in window_support
    assert 'static let plotterVideoPanel = "plotter-video-panel"' in window_support
    assert 'static let faceVideoPanel = "face-video-panel"' in window_support
    assert "Window(PlotterWindowConfiguration.setupTitle, id: OperatorWindowID.setupPanel)" not in app_main
    assert "Window(PlotterWindowConfiguration.plotterVideoTitle, id: OperatorWindowID.plotterVideoPanel)" in app_main
    assert "Window(PlotterWindowConfiguration.faceVideoTitle, id: OperatorWindowID.faceVideoPanel)" in app_main
    assert "SetupPanel(workspace: workspace, bridge: bridge)" not in app_main
    assert "calibrationWizardOverlay" in content
    assert "if workspace.calibrationWizardActive" in content
    assert "toggleCalibrationWizard()" in content
    assert "openWindow(id: OperatorWindowID.setupPanel)" not in content
    assert "pendingSetupCommand" not in swift_text
    assert "requestSetupCommand" not in swift_text
    assert "SetupPanelCommand" not in swift_text
    assert "ProgressiveDrawingCalibrationFlow" not in swift_text
    assert "PlotterVideoPanel(workspace: workspace, bridge: bridge)" in app_main
    assert "FaceVideoPanel(workspace: workspace, bridge: bridge)" in app_main
    assert "@Published var visualFieldWidthMm = 200.0" in workspace
    assert "@Published var visualFieldHeightMm = 150.0" in workspace
    assert '"visual_field_width_mm": visualFieldWidthMm' in workspace
    assert '"visual_field_height_mm": visualFieldHeightMm' in workspace
    assert '"machine_video_agreement_estimate_present": machineVideoAgreementModel != nil' in workspace
    assert "machine_video_agreement_valid" not in workspace
    assert "CalibrationWizardView(" in content
    assert "workflow: bridge.calibrationWorkflow" in content
    assert "primaryAction: runCalibrationWizardPrimaryAction" in content
    assert ".drawFrame" not in content
    assert "ProgressiveDrawingCalibrationControls" not in content
    assert "drawFrameVisible" not in workspace
    assert "drawFrameEnabled" not in workspace
    assert "fieldAspectYPerX" in workspace
    assert '"visual_field_video_aspect_y_per_x": calibrationWizardSnapshot.fieldAspectYPerX ?? 0.0' in workspace
    assert "fieldWidthMm: $workspace.visualFieldWidthMm" in content
    assert "fieldHeightMm: $workspace.visualFieldHeightMm" in content
    assert "fieldAspectYPerX: workspace.calibrationWizardSnapshot.fieldAspectYPerX" not in content
    assert "Drawing Checkout" not in content
    assert "Sample Cap Color" in plotter_panel
    assert "Reset Cap Color" in plotter_panel
    assert "Field Grid" not in plotter_panel
    assert "Calibrated Grid" not in plotter_panel
    assert "showGrid" not in swift_text
    assert "PortraitPanel(" in face_panel
    assert "CameraLayoutMode" not in swift_text
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
    assert "Confirm Setup" not in content + _read(SWIFT_DIR / "CalibrationWizardView.swift")


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
    assert "bridge.clearExpectedPathOverlay()" in content
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
    assert len(content.splitlines()) < 3900


def test_swift_app_owns_development_bridge_process_without_serial_authority() -> None:
    app_main = _read(SWIFT_DIR / "AppMain.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    supervisor_path = SWIFT_DIR / "BridgeProcessSupervisor.swift"
    supervisor = _read(supervisor_path)

    assert supervisor_path.exists()
    assert "BridgeProcessSupervisor.shared" in app_main
    assert "PlotterBridgeClient(baseURL: supervisor.baseURL)" in app_main
    assert "stopOwnedBridge(reason: \"app_terminating\")" in app_main
    assert "private let client: PlotterBridgeClient" in model
    assert "private let bridgeSupervisor: BridgeProcessSupervisor?" in model
    assert "let baseURL: URL" in client

    assert "Process()" in supervisor
    assert "bridge-server" in supervisor
    assert "--dry-run" in supervisor
    assert "--controller-port" not in supervisor
    assert ".VE/bin/plotterctl" in supervisor
    assert ".venv/bin/plotterctl" in supervisor
    assert "PLOTTER_PARENT_PID" in supervisor
    assert "kill -0 \"$PLOTTER_PARENT_PID\"" in supervisor
    assert "save-pen-config" in supervisor


def test_macos_build_script_has_no_change_fast_path() -> None:
    build_script = _read(ROOT / "macos" / "PlotterVision" / "build.sh")

    assert "build_fingerprint()" in build_script
    assert "inputs unchanged; reusing" in build_script
    assert ".PlotterVision.build.sha256" in build_script
    assert "PLOTTER_SWIFT_BUILD_SYSTEM" in build_script
    assert "--disable-index-store" in build_script


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


def test_bridge_contract_requires_api_4_and_gates_build_mismatch() -> None:
    build_script = _read(ROOT / "macos" / "PlotterVision" / "build.sh")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert "PlotterRequiredBridgeAPIVersion integer 4" in build_script
    assert "return 4" in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
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


def test_machine_panel_has_explicit_manual_jog_boundary_override() -> None:
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    panel = _read(SWIFT_DIR / "MachineControlPanel.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    contract = _read(ROOT / "docs" / "ARCHITECTURE.md")

    assert "@Published var manualJogWorkspaceOverride = false" in model
    assert "var manualMotionGateMessage" in model
    assert "manual_jog_workspace_override" in model
    assert "func setManualJogWorkspaceOverride(_ enabled: Bool)" in model
    assert "manual_jog_workspace_override_changed" in model
    assert "bypassWorkspaceProjection: manualJogWorkspaceOverride" in model
    assert "bypassWorkspaceProjection: Bool = false" in client
    assert "Boundary Override" in panel
    assert "JOG WORKSPACE GUARD OFF" in panel
    assert "bridge.manualMotionGateMessage" in panel
    assert "bridge.motionGateMessage" not in panel
    assert "Manual Machine-panel jogs may expose an explicit operator Boundary Override" in contract


def test_wizard_drives_non_homed_visual_field_motion_setup() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    cap_flow = _read(SWIFT_DIR / "ContentViewCapConfirmation.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    app_main = _read(SWIFT_DIR / "AppMain.swift")
    frame_drawing = _read(SWIFT_DIR / "SetupFieldFrameDrawing.swift")

    assert not (SWIFT_DIR / "SetupPanel.swift").exists()
    assert "CalibrationWizardView(" in content
    assert "private var calibrationWizardOverlay" in content
    assert "SetupLogDisclosure" not in content
    assert "SetupModelEstimatesDisclosure" not in content
    assert 'static let setupTitle = "Calibrate Vision-Machine Interface"' not in app_main
    assert "Window(PlotterWindowConfiguration.setupTitle, id: OperatorWindowID.setupPanel)" not in app_main
    assert "Calibrate Vision-Machine Interface" in wizard
    assert "BridgeCalibrationWorkflow" in wizard
    assert "BridgeCalibrationCapConfirmationRequest" in client
    assert 'post(path: "calibration/workflow/cap/confirm"' in client
    assert "confirmCalibrationCap(" in model
    assert "await confirmWorkflowCap(" in cap_flow
    assert "func confirmWorkflowCap(" in cap_flow
    assert "if let action = bridge.calibrationWorkflow?.nextPrimaryAction" in content
    assert "visualMotionValidated, let action = bridge.calibrationWorkflow?.nextPrimaryAction" not in content
    assert 'title: "Confirm Green Cap"' in wizard
    assert 'title: "Machine-Video Agreement"' in wizard
    assert 'title: "Set Drawing Border"' in wizard
    assert 'title: "Validate Motion"' in wizard
    assert 'title: "Drawing Training"' in wizard
    assert 'title: "Calibrate Drawing"' not in wizard
    assert "let fieldAspectYPerX: Double?" not in wizard
    assert "@Binding var fieldWidthMm" in wizard
    assert "@Binding var fieldHeightMm" in wizard
    assert "TextField(label, value: value, formatter: Self.fieldDimensionFormatter)" in wizard
    assert "fieldDimensionControl(label: \"X\", value: fieldWidthBinding)" in wizard
    assert "fieldDimensionControl(label: \"Y\", value: fieldHeightBinding)" in wizard
    assert "fieldHeightMm > fieldWidthMm" not in wizard
    assert "fieldHeightUpperBound" not in wizard
    assert "fieldHeightMm = fieldWidthMm" not in wizard
    assert "fieldHeightMm = clampedFieldDimension(width * fieldAspectYPerX)" not in wizard
    assert "fieldWidthMm = clampedFieldDimension(newValue)" in wizard
    assert "fieldHeightMm = clampedFieldDimension(newValue)" in wizard
    assert ".disabled(hasPaperLock)" not in wizard
    assert "Confirm Green Cap" in content
    assert "Run Machine-Video Probe" in content
    assert "Run Motion Calibration" in content
    assert "runMachineVideoAgreementProbe" in content
    assert "runFieldMotionCalibration(using:" in content
    assert "measureMachineVideoAgreementNoise" in content
    assert "machineVideoAgreementProbeVectors" in content
    assert "runSetupVectorJog" in content
    assert "runMachineVideoAgreementVectorJog" not in content
    assert "private let machineVideoAgreementInitialMoveMm = 10.0" in content
    assert "private let machineVideoAgreementMaxMoveMm = 50.0" in content
    assert "machineVideoAgreementMaxSamples" in content
    assert "func relativeUpdateMagnitude(from previous:" in _read(SWIFT_DIR / "Models.swift")
    assert "model_update_norm" in content
    assert "fieldCornerPrecisionMm" in content + _read(SWIFT_DIR / "Models.swift")
    assert "seedAndLockFieldFromMachineVideoAgreement" in content
    assert "currentGreenCapCameraObservation" in content
    assert "MachineVideoAgreementModel" in content + _read(SWIFT_DIR / "Models.swift")
    assert "Validate Motion" in content
    assert "Calibrate Drawing" not in wizard
    assert "wizardDrawingCalibrationStatus" in content
    assert "wizardDrawingCalibrationDetail" in content
    assert "wizardDrawFrameVisible" not in content
    assert "wizardDrawFrameEnabled" not in content
    assert "drawValidatedFieldFrame" not in content
    assert "runDrawingWorkflowPrimaryAction" in content
    assert "Confirm Pen Ready" in content
    assert "recordDrawingFrameInspection" in frame_drawing + _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    assert "expectedPathLabel" in _read(SWIFT_DIR / "MeasurementOverlay.swift")
    assert '"Expected frame"' in _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    assert "Observed frame" in _read(SWIFT_DIR / "MeasurementOverlay.swift")
    assert "setupRelativeMove(" in frame_drawing
    assert "motion already validated" not in content
    assert "runFrameLearning()" in content
    assert "runWizardMotionValidation" in content
    assert "approachVisualTarget(target, label: \"VALIDATE\", targetIndex: 1)" in content
    validation_run = content.split("private func runWizardMotionValidation", 1)[1].split(
        "private func wizardMotionValidationTarget",
        1,
    )[0]
    validation_target_failure = validation_run.split(
        'guard let observed = await approachVisualTarget(target, label: "VALIDATE", targetIndex: 1) else',
        1,
    )[1].split("let residualMm", 1)[0]
    assert 'status: "MEASURED"' in validation_target_failure
    assert "Motion validation failed; fix blocker and retry validation" in validation_target_failure
    assert 'frameLearning.status = "BLOCK"' not in validation_target_failure
    validation_path = content.split("func approachVisualTarget", 1)[1].split(
        "private func visualTargetResidualDetails",
        1,
    )[0]
    assert "runSetupVectorJog(" in validation_path
    assert "bridge.visualRelativeMove(" not in validation_path
    assert "bridge.canRunSetupRelativeMotionCommand" in content
    assert "private func setupRelativeMotionBlockReason" in model
    setup_gate = model.split("private func setupRelativeMotionBlockReason", 1)[1].split(
        "private func blockLiveRelativeMotionCommand",
        1,
    )[0]
    assert "machineHomingTrusted" not in setup_gate
    assert "machineAxisModelTrusted" not in setup_gate
    assert "hasPaperLock" not in setup_gate
    assert "boundedMachineTravelDistance" not in content
    assert "visualMachineCalibrationBoundedDistance" not in content
    assert "visualMachineCalibrationAxesHaveTravel" not in content
    assert "Machine-video samples %d/4" not in content
    assert "reducedProbeDistances" not in content


def test_old_binding_runner_is_not_active_setup() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")

    assert not (SWIFT_DIR / "VisualBindingMarkRunner.swift").exists()
    assert "await bridge.refreshVisualBindingStatus()" not in content
    assert "visual_binding_status_refreshed" in model
    visual_binding_refresh = model.split("func refreshVisualBindingStatus", 1)[1].split(
        "func refreshDrawingCalibrationStatus",
        1,
    )[0]
    assert "snapshot: true" not in visual_binding_refresh
    assert "snapshot: false" in visual_binding_refresh
    exact_blockers = model.split("private func exactDiagnosticsBlockers", 1)[1].split(
        "private func latestVisibleDiagnosticsError",
        1,
    )[0]
    assert "binding_untrusted" not in exact_blockers
    assert "visualBindingDetail" not in exact_blockers.split("if isFutureDrawingAction", 1)[0]
    assert "drawPreflightMessage" not in exact_blockers.split("if isFutureDrawingAction", 1)[0]
    motion_gate = model.split("var motionGateMessage", 1)[1].split(
        "var manualMotionGateMessage",
        1,
    )[0]
    assert "machineAxisModelTrusted" not in motion_gate
    assert "machineHomingTrusted" not in motion_gate
    assert "Bridge-run drawing blocked" not in motion_gate
    assert "Live motion enabled" in motion_gate
    active_setup = content.split("private var wizardFiducialStatus", 1)[1].split(
        "private var topStatusLights",
        1,
    )[0]
    assert "if machineVideoAgreementModel != nil { return .active }" in active_setup
    assert "machineVideoAgreementModel?.isUsable == true" not in active_setup
    stale_terms = [
        "Run Drawing Calibration",
        "runWizardDrawingCalibration",
        "recordVisualBindingInkObservation",
        "runVisualRelativeFivePointTest",
        "previewBindingMarks",
        "solveVisualBinding",
        "observeVisualBindingPoint",
        "drawVisualBindingBoundsFrame",
        "VisualPositionBinding",
        "binding mark",
    ]
    for term in stale_terms:
        assert term not in active_setup
    assert 'post(path: "calibration/binding/observe"' in client
    assert 'post(path: "calibration/binding/solve"' in client
    assert "func drawVisualBindingBoundsFrame" in model


def test_wizard_uses_machine_video_seed_with_editable_video_field_box() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")

    assert "Confirm Setup" not in wizard
    assert "confirmSetup" not in wizard
    assert "canConfirmSetup" not in content
    assert "canConfirmSetup" not in workspace
    assert "confirmSetup: confirmWizardSetupFromExistingRegistration" not in content
    assert "private func confirmWizardSetupFromExistingRegistration" not in content
    assert "case confirm" not in workspace
    assert '"wizard_setup_confirmed"' not in content
    assert "ManualFiducialOverlay" not in _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    assert "ManualFiducialClickLayer" not in _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    assert "recordManualFiducial" not in content
    assert "solvePaperHomographyFromWizard" not in content
    assert "CLICK FIELD CORNERS" not in "\n".join(_read(path) for path in SWIFT_DIR.glob("*.swift"))
    assert "struct VisualFieldEditLayer" in support
    assert "let isVisible: Bool" in support
    assert "plotterViewportPointFromCameraNorm" in support
    assert "plotterCameraNormFromViewPoint" in support
    assert "func visualFieldVideoAspectYPerX" in support
    assert "visualFieldRectangleCornersFromCurrentBounds" in support
    assert "visualFieldRectangleMoved" in support
    assert "visualFieldRectangleResizedFromTopRight" in support
    assert "cornerResizeGesture(cornerID:" not in support
    assert "topRightResizeGesture" in support
    assert "private func topRightResizeHandle" in support
    assert "visualFieldTopRightCornerIndex" in support
    assert ".coordinateSpace(name: visualFieldEditLayerCoordinateSpace)" in support
    assert "DragGesture(minimumDistance: 0, coordinateSpace: .named(visualFieldEditLayerCoordinateSpace))" in support
    handle_section = support.split("private func topRightResizeHandle", 1)[1].split(
        "private func topRightResizeGesture",
        1,
    )[0]
    assert ".frame(width: visualFieldResizeHandleDiameter, height: visualFieldResizeHandleDiameter)" in handle_section
    assert ".contentShape(Circle())" in handle_section
    assert ".gesture(topRightResizeGesture(in: viewSize))" in handle_section
    assert ".position(point)" in handle_section
    assert handle_section.index(".contentShape(Circle())") < handle_section.index(
        ".gesture(topRightResizeGesture(in: viewSize))"
    ) < handle_section.index(".position(point)")
    assert "DRAG BORDER / TOP-RIGHT RESIZE; RELEASE RE-LOCKS" in support
    assert "LIVE MACHINE-VIDEO ESTIMATE" in support
    assert "if isVisible, orderedCorners.count == 4" in support
    assert "updatedCorners(" not in support
    assert "ForEach(Array(viewCorners.enumerated()), id: \\.offset)" not in support
    corner_order = support.split("let cameraPoints = [", 1)[1].split("]", 1)[0]
    expected_order = [
        "CGPoint(x: clampedMinX, y: clampedMinY)",
        "CGPoint(x: clampedMaxX, y: clampedMinY)",
        "CGPoint(x: clampedMaxX, y: clampedMaxY)",
        "CGPoint(x: clampedMinX, y: clampedMaxY)",
    ]
    assert [corner_order.index(point) for point in expected_order] == sorted(
        corner_order.index(point) for point in expected_order
    )
    assert "VisualFieldEditLayer(" in content
    assert "currentVisualFieldAspectYPerX" in content
    assert "fieldAspectYPerX: currentVisualFieldAspectYPerX" in content
    assert "editableVisualFieldCorners" in content
    assert "updateEditableVisualFieldCorners" in content
    assert "scheduleEditableVisualFieldRelock" in content
    assert "relockEditableVisualField" in content
    assert "visualFieldCornersAreConvex" in content
    assert "BORDER edit blocked: corners must form a convex rectangle" in content
    assert "drawing_border_adjusted_blocked" in content
    assert "drawing_border_adjusted" in content
    assert "bridge.registerPaperHomography(" in content
    assert "BORDER re-locking adjusted" in content
    assert "BORDER adjusted \\(Int(fieldWidthMm))x\\(Int(fieldHeightMm)) drawing border locked" in content
    assert "Run Motion Calibration" in content
    assert "CAL motion calibration using adjusted drawing border" in content
    assert 'resetCalibrationSetup(scope: "vision_machine")' in content
    assert 'resetCalibrationSetup(scope: "drawing_training")' in content
    assert "NSAlert" in content
    assert 'post(path: "calibration/setup/reset"' in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    assert "Calibrate Vision-Machine Interface" in wizard
    assert "Paper Homography" not in wizard
    assert "Paper homography" not in content
    assert "Stored visual field in use" not in content
    assert "BORDER run machine-video agreement before drawing border" in content
    assert 'BORDER \\(desiredVisualFieldSizeLabel) locked from machine-video agreement' in content
    assert "DRAG BORDER / TOP-RIGHT RESIZE" in support
    assert ".disabled(hasPaperLock)" not in wizard


def test_visual_field_setup_uses_four_stage_motion_workflow_without_tip_click() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    server = _read(BRIDGE_SERVER)
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")

    assert 'title: "Confirm Green Cap"' in wizard
    assert 'title: "Machine-Video Agreement"' in wizard
    assert 'title: "Set Drawing Border"' in wizard
    assert 'title: "Validate Motion"' in wizard
    assert 'title: "Drawing Training"' in wizard
    assert 'title: "Fiducials"' not in wizard
    assert 'title: "Drawing Calibration"' not in wizard
    assert 'title: "Tool"' not in wizard
    assert "Draw/Verify" not in wizard
    assert "Paper Homography" not in wizard
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
    assert "Run Machine-Video Probe" in content
    assert "Validate Motion" in content
    assert "Run Drawing Calibration" not in content
    assert "runWizardDrawingCalibration" not in content
    assert "runVisualRelativeFivePointTest" not in content
    assert "Confirm Setup" not in content + wizard
    assert "ManualFiducialOverlay" not in support
    assert "ManualFiducialClickLayer" not in support
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


def test_visual_machine_setup_uses_non_homed_relative_motion() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    models = _read(SWIFT_DIR / "Models.swift")

    assert "machineVideoAgreementProbeVectors" in content
    assert '("D++", diagonal, diagonal)' in content
    assert '("D+-", diagonal, -diagonal)' in content
    assert "let machineDxMm: Double" in models
    assert "let machineDyMm: Double" in models
    assert "observedDistanceNorm / max(sample.commandDistanceMm" in content
    assert "cameraDelta(forMachineX" in models
    assert "bridge.learningJog(" in content
    learning_jog = model.split("func learningJog", 1)[1].split("func observeVisualCapForProbe", 1)[0]
    assert "bypassWorkspaceProjection: true" in learning_jog
    setup_relative_move = model.split("func setupRelativeMove", 1)[1].split("func observeVisualCapForProbe", 1)[0]
    assert "bypassWorkspaceProjection: true" in setup_relative_move
    assert "ensurePenUp: ensurePenUp" in setup_relative_move
    assert "manualJogWorkspaceOverride" not in learning_jog
    assert "visualMachineCalibrationBoundedDistance" not in content
    assert "visualMachineCalibrationAxesHaveTravel" not in content
    setup_gate = model.split("private func setupRelativeMotionBlockReason", 1)[1].split(
        "private func blockLiveRelativeMotionCommand",
        1,
    )[0]
    assert "machineHomingTrusted" not in setup_gate
    assert "machineAxisModelTrusted" not in setup_gate
    assert "hasPaperLock" not in setup_gate
    assert "boundedMachineTravelDistance" not in setup_gate
    assert "availableMachineTravelMm" not in setup_gate
    assert "boundedMachineTravelDistance" in model
    assert "availableMachineTravelMm" in model
    assert "visualCapReacquireCommands" in content
    assert "x_field_recovery_prompted" not in content
    assert "Move X into camera field?" not in content
    assert "previewBootstrapAdaptiveProbe(" not in content
    assert "runBootstrapAdaptiveProbe(" not in content
    assert "previewBootstrapAdaptiveProbe(" not in model
    assert "runBootstrapAdaptiveProbe(" not in model


def test_machine_video_agreement_uses_online_estimate_before_field_overlay() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    field_seed_geometry = _read(SWIFT_DIR / "ContentViewFieldSeedGeometry.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    readme = _read(ROOT / "README.md")
    contract = _read(ROOT / "docs" / "ARCHITECTURE.md")
    plan = _read(ROOT / "docs" / "ARCHITECTURE.md")
    contract_flat = " ".join(contract.split())
    plan_flat = " ".join(plan.split())

    assert "private var visualFieldOverlayTransform: PaperRegistrationSnapshot?" in content
    overlay_gate = content.split("private var visualFieldOverlayTransform", 1)[1].split(
        "private var plotterCameraPane",
        1,
    )[0]
    assert "workspace.calibrationWizardActive" in overlay_gate
    assert "machineVideoAgreementModel == nil" in overlay_gate
    assert "isOnlineEstimateUsable" not in overlay_gate
    assert "return nil" in overlay_gate
    assert "paperTransform: visualFieldOverlayTransform" in content

    agreement_probe = content.split("private func runMachineVideoAgreementProbe", 1)[1].split(
        "@MainActor\n    private func measureMachineVideoAgreementNoise",
        1,
    )[0]
    assert "while samples.count < machineVideoAgreementMaxSamples" in agreement_probe
    assert "machineVideoAgreementProbeVectors(magnitudeMm: magnitudeMm, model: bestModel)" in agreement_probe
    assert "relativeUpdateMagnitude(from: bestModel)" in agreement_probe
    assert "machineVideoAgreementConvergedUpdateNorm" in agreement_probe
    assert "model.isPrecisionConverged" not in agreement_probe
    assert "model.isOnlineEstimateUsable" not in agreement_probe
    assert "machineVideoAgreementModel = model" in agreement_probe
    assert "updateLiveMachineVideoFieldFrame(from: model, center: sample.afterCameraPoint)" in agreement_probe
    assert "afterCameraPoint: after.cameraPoint" in content
    solve_block = agreement_probe.split("if let model = MachineVideoAgreementModel.solve", 1)[1].split(
        "updateMachineVideoAgreementSummary",
        1,
    )[0]
    assert "bestModel = model" in solve_block
    assert "machineVideoAgreementModel = model" in solve_block
    assert "isOnlineEstimateUsable" not in solve_block
    assert "samples.count >= machineVideoAgreementMinSamples" in agreement_probe
    assert "latestUpdateMagnitude <= machineVideoAgreementConvergedUpdateNorm" in agreement_probe
    assert "magnitudeMm = min(machineVideoAgreementMaxMoveMm" in agreement_probe
    assert "if bestModel != nil" in agreement_probe
    assert "machineVideoAgreementMaxSamples = 64" in content
    assert "machineVideoAgreementMinSamples = 8" in content
    assert "bootstrapMoves" in content
    assert '("X+", magnitude, 0.0)' in content
    assert '("Y+", 0.0, magnitude)' in content
    assert '("X-", -magnitude, 0.0)' in content
    assert '("Y-", 0.0, -magnitude)' in content
    assert "func relativeUpdateMagnitude(from previous:" in models
    assert "var isOnlineEstimateUsable" not in models
    assert "isOnlineEstimateUsable" not in content + models
    assert "conditionNumber <= 30.0" in models
    assert "maxResidualNorm <= max(0.004, observationNoiseNorm * 8.0)" in models
    assert "model_update_norm" in content
    assert "model_update_converged" in content
    assert "online_estimate_usable" not in content
    assert "Online estimate accepted" not in content
    probe_vectors = content.split("private func machineVideoAgreementProbeVectors", 1)[1].split(
        "private func machineVideoAgreementStatus",
        1,
    )[0]
    assert "guard let model else" in probe_vectors
    assert "model.isOnlineEstimateUsable" not in probe_vectors

    field_seed = field_seed_geometry.split("func seededFieldCorners", 1)[1].split(
        "func manualFieldPoints",
        1,
    )[0]
    assert "visualFieldAxisAlignedSpan" in field_seed_geometry
    assert "let horizontalScale = max(abs(model.xBasisDxNorm), abs(model.yBasisDxNorm))" in field_seed_geometry
    assert "let verticalScale = max(abs(model.xBasisDyNorm), abs(model.yBasisDyNorm))" in field_seed_geometry
    assert "horizontalScale * fieldWidthMm" in field_seed_geometry
    assert "verticalScale * fieldHeightMm" in field_seed_geometry
    assert "model.xBasisDxNorm * fieldWidthMm" not in field_seed
    assert "model.xBasisDyNorm * fieldWidthMm" not in field_seed
    assert "model.yBasisDxNorm * fieldHeightMm" not in field_seed
    assert "model.yBasisDyNorm * fieldHeightMm" not in field_seed
    assert "return manualFieldPoints(cameraCorners: corners)" in field_seed
    assert "visualFieldRectangleCornersFromCurrentBounds(manualFieldPoints(cameraCorners: corners))" not in field_seed
    assert "desiredVisualFieldWidthMm" in content
    assert "desiredVisualFieldHeightMm" in content
    assert "fitFieldCenter" in field_seed
    assert "halfWidth *= 0.92" not in content + field_seed_geometry
    assert "halfHeight = halfWidth * 0.75" not in content + field_seed_geometry
    live_update = content.split("private func updateLiveMachineVideoFieldFrame", 1)[1].split(
        "private func relockEditableVisualField",
        1,
    )[0]
    assert "workspace.calibrationWizardActive" in live_update
    assert "manualFiducials = corners" in live_update

    frame_drawing = _read(SWIFT_DIR / "SetupFieldFrameDrawing.swift")
    frame_inspection = _read(SWIFT_DIR / "FrameInkInspection.swift")
    bridge_model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    bridge_client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")
    assert "bridge.showSetupFieldFrameExpectedPath(corners: corners)" in frame_drawing
    assert "model.machineDelta(forPaperDx: paperDx, paperDy: paperDy)" in frame_drawing
    assert "let machineStepCount = Int(ceil(machineDistance / frameMachineSegmentLimitMm()))" in frame_drawing
    assert "bridge.machineMaxJogMm * 0.80" in frame_drawing
    assert '"max_machine_segment_mm": frameMachineSegmentLimitMm()' in frame_drawing
    assert '"setup_field_frame_residual_measured"' in frame_drawing
    assert '"closure_residual_mm": residualMm' in frame_drawing
    assert '"setup_field_frame_residual_unavailable"' in frame_drawing
    assert "plotterCamera.inspectGreenFrameGeometry" in frame_drawing
    assert '"setup_field_frame_ink_geometry_measured"' in frame_drawing
    assert '"setup_field_frame_ink_geometry_weak"' in frame_drawing
    assert '"setup_field_frame_ink_geometry_unavailable"' in frame_drawing
    assert '"ink_rms_residual_mm"' in frame_drawing
    assert '"ink_sample_count"' in frame_drawing
    assert '"program_sample_count"' in frame_drawing
    assert 'let prefix = "edge_\\(edge.edgeIndex)"' in frame_drawing
    assert '"\\(prefix)_detected_samples"' in frame_drawing
    assert "enum InkProgramInspector" in frame_inspection
    assert "enum InkProgramPrimitiveKind" in frame_inspection
    assert "case mark" in frame_inspection
    assert "case line" in frame_inspection
    assert "case circle" in frame_inspection
    assert "case arc" in frame_inspection
    assert "case denseStroke = \"dense_stroke\"" in frame_inspection
    assert "primitiveId: \"frame-edge-\\(edgeIndex)\"" in frame_inspection
    assert "observedSamples: [InkProgramObservedSample]" in frame_inspection
    assert "p95ResidualMm" in frame_inspection
    assert "enum GreenFrameInkInspector" in frame_inspection
    assert "static func inspect(" in frame_inspection
    assert "isGreenFramePixel" in frame_inspection
    assert "fitLine(points: observedPaperPoints" in frame_inspection
    assert "cornerRmsResidualMm" in frame_inspection
    assert "func inspectInkProgram(" in camera_model
    assert "func showSetupFieldFrameExpectedPath(corners: [PaperPointMmSnapshot])" in bridge_model
    assert '"setup_field_frame_expected_path_ready"' in bridge_model
    assert "@Published var predictedPathSegments: [ExpectedPathSegment] = []" in bridge_model
    assert '@Published var predictedPathLabel = "Model-corrected frame"' in bridge_model
    assert "if !predictedPathSegments.isEmpty" in bridge_model
    assert "func observeDrawingProgram(" in bridge_client
    assert "BridgeDrawingProgramObservationRequest" in bridge_client
    assert "BridgeDrawingProgramSampleObservationRequest" in bridge_client
    assert 'post(path: "calibration/drawing/program-observation"' in bridge_client
    assert 'post(path: "calibration/drawing/session/start"' in bridge_client
    assert 'post(path: "calibration/drawing/session/preview-next-batch"' in bridge_client
    assert 'post(path: "calibration/drawing/session/run-batch"' in bridge_client
    assert 'post(path: "calibration/drawing/session/observe-batch"' in bridge_client
    assert 'post(path: "calibration/drawing/session/fit"' in bridge_client
    assert 'post(path: "calibration/drawing/session/validate"' in bridge_client
    assert 'post(path: "calibration/drawing/session/finish"' in bridge_client
    assert 'get(path: "calibration/drawing/session/status"' in bridge_client
    assert "BridgeDrawingCalibrationSessionActionResponse" in bridge_client
    assert "sessionId" in bridge_client
    assert "batchId" in bridge_client
    assert "correctionMode" in bridge_client
    assert "modelIdUsed" in bridge_client
    assert "planHash" in bridge_client
    assert "predictedObservedMm" in bridge_client
    assert "drawing_program_observation_recorded" in bridge_model
    assert "drawing_calibration_session_started" in bridge_model
    assert "drawing_calibration_batch_observed" in bridge_model
    assert "recordWeakProgressiveDrawingCalibrationObservation" in bridge_model
    assert "fallback_route\": \"calibration/drawing/frame-observation\"" in bridge_model
    assert "drawDrawingBorder" in overlay
    assert "DRAWING BORDER %.0f x %.0f mm" in overlay
    assert "drawPredictedPath" in overlay
    assert "predictedPathLabel" in overlay
    assert "drawFieldCoordinateGrid" not in overlay
    assert "majorPaperGridStep" not in overlay
    assert "showGrid" not in overlay
    assert "relativeMotionModel: BridgeRelativeMotionModel?" in bridge_client
    assert "var visualMotionModel: VisualMotionModel?" in bridge_client
    assert "applyPersistedVisualReadiness(await bridge.refreshVisualReadinessStatus())" in content
    assert "BORDER loaded saved motion transform" in content

    assert "docs/ARCHITECTURE.md" in readme
    assert "before locking or drawing the Drawing Border" in contract_flat
    assert "Every subsequent solved estimate becomes the current online transform" in contract_flat
    assert "current 2x2 transform" in contract
    assert "The operator can type explicit X and Y millimeter values" in contract_flat
    assert "does not infer the other from video aspect" in contract_flat
    assert "estimate Y from the rectangle's video aspect" not in readme
    assert "update magnitude as the convergence signal" in contract_flat
    assert "Every later solved estimate updates the provisional" in contract_flat
    assert "seeded video border is operator-adjustable as a rectangle" in contract_flat
    assert "top-right handle to resize it while it remains rectangular" in contract_flat
    assert "Changing field dimensions re-locks" in contract_flat
    assert "cap and tip are colocated until explicit binding evidence" in contract_flat
    assert "before locking or drawing the Drawing Border" in contract_flat
    assert "There is no identity matrix as calibration evidence" in contract
    assert "reports update magnitude as the" in contract_flat
    assert "magnitude approaching zero" in contract_flat
    assert "uses every later solved estimate" in plan_flat
    assert 'cardinal `+X`, `+Y`, `-X`, `-Y` minibatch' in contract_flat
    assert "Every subsequent solved estimate becomes the current online" in contract_flat
    assert "later relative vectors are chosen from that latest estimate" in contract_flat
    assert "Every later solved estimate updates the provisional Drawing Border" in contract_flat
    assert "operator can type explicit X and Y millimeter values" in contract_flat
    assert "does not infer the other from video aspect" in contract_flat
    assert "seeded video border" in contract_flat
    assert "resize it while it remains rectangular" in contract_flat
    assert "release to re-lock border registration" in contract_flat
    assert "cap and tip are colocated until explicit binding evidence" in contract_flat
    assert "before locking or drawing the Drawing Border" in plan_flat
    assert "first empirical 2x2 machine-to-video estimate" in plan_flat
    assert "Update magnitude is the convergence signal" in plan_flat
    assert "accepted-estimate gate" in plan_flat
    assert "Every later solved estimate updates the provisional Drawing Border" in plan_flat
    assert "assign typed X/Y" in plan_flat
    assert "Editing X and Y sets" in plan_flat
    assert "aspect-ratio inference" in plan_flat
    assert "video Drawing Border remains operator-adjustable as a" in plan_flat
    assert "Plotter Video has no separate grid overlay" in plan_flat
    assert "bottom-left border corner is logical `(0,0)`" in plan_flat
    assert "correct perspective" not in readme + contract + plan


def test_drawing_calibration_docs_match_program_and_model_usage_surfaces() -> None:
    readme = _read(ROOT / "README.md")
    contract = _read(ROOT / "docs" / "ARCHITECTURE.md")
    plan = _read(ROOT / "docs" / "ROADMAP.md")
    server = _read(ROOT / "plotter_vision" / "bridge" / "server.py")
    planner = _read(ROOT / "plotter_vision" / "bridge" / "planner.py")
    capabilities = _read(ROOT / "plotter_vision" / "drawing" / "capabilities.py")
    drawing_model = _read(ROOT / "plotter_vision" / "calibration" / "drawing_model.py")
    bridge_client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    bridge_model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    content = _read(SWIFT_DIR / "ContentView.swift")
    plan_flat = " ".join(plan.split())

    assert "multi_shape_coordinate_sheet" in capabilities
    assert "program=definition.program" in server
    assert "build_polygon_draw_plan" in server
    assert "DrawingProgram" in planner
    assert "DrawingCalibrationObservation" in drawing_model
    assert "residual_grid_v1" in drawing_model
    assert "apply_drawing_calibration_model" in planner
    assert "/calibration/drawing/program-observation" in server
    assert "/calibration/drawing/program/preview" in server
    assert "/calibration/drawing/program/run" in server
    assert "BridgeDrawingCalibrationModel" in bridge_client
    assert "latestDrawingCalibration" in bridge_model
    assert "latestDrawingCalibrationSession" in bridge_model
    assert "currentDrawingCalibrationBatch" in bridge_model
    assert not (SWIFT_DIR / "SetupPanel.swift").exists()
    assert "wizardDrawingCalibrationDetail" in content

    docs = readme + contract + plan
    assert "multi_shape_coordinate_sheet" in docs
    assert "residual_grid_v1" in docs
    assert "GET /calibration/drawing/status" in contract
    assert "latest_drawing_calibration.json" in docs
    assert "runtime hits outside tests" in plan_flat
    assert "model-aware drawing planner stage" in plan_flat
    assert "Do not add SVG import" in contract
    assert "Swift may show" in contract
    assert "Python owns persistence, trust" in plan_flat


def test_operator_log_and_model_estimates_do_not_live_under_setup_wizard() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    app_main = _read(SWIFT_DIR / "AppMain.swift")
    support = _read(SWIFT_DIR / "OperatorWindowSupport.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")
    log_panel = _read(SWIFT_DIR / "OperatorLogPanel.swift")

    assert "private var statusBar" not in content
    assert "statusBar" not in content
    assert "OperatorLogPanel" in app_main
    assert 'static let operatorLog = "operator-log"' in support
    assert "appendOperatorLog" in workspace
    assert "@Published var setupLogExpanded" not in workspace
    assert "@Published var setupModelEstimatesExpanded" not in workspace
    assert '"setup_log_expanded"' not in workspace
    assert '"setup_model_estimates_expanded"' not in workspace
    assert not (SWIFT_DIR / "SetupPanel.swift").exists()
    assert "SetupLogDisclosure" not in content
    assert "SetupModelEstimatesDisclosure" not in content
    assert 'Label("Setup Log", systemImage: "list.bullet.rectangle")' not in content
    assert 'Label("Model Estimates", systemImage: "function")' not in content
    for label in [
        "Paper homography",
        "Motion 2x2",
        "Drawing model family",
        "Solver kind",
        "Grid/control count",
        "Sample count",
        "Coverage",
        "RMS/p95/max",
        "Holdout error",
        "Blockers",
        "Model id",
    ]:
        assert label not in content
    assert 'label: "Log"' not in content
    assert "OperatorWindowID.operatorLog" not in content
    assert "workspace.appendOperatorLog(newValue" in content
    assert "workspace.appendOperatorLog(status, source: \"Bridge\"" in content
    assert "Operator Log" in log_panel
    assert "textSelection(.enabled)" in log_panel


def test_plotter_video_defaults_keep_visual_processing_overlays_off() -> None:
    camera_model = _read(SWIFT_DIR / "CameraModel.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    content = _read(SWIFT_DIR / "ContentView.swift")
    measurement = _read(SWIFT_DIR / "MeasurementOverlay.swift")

    assert "@Published var segmentationEnabled = false" in camera_model
    assert "@Published var changeDetectionEnabled = false" in camera_model
    assert "showGrid" not in camera_model
    assert "var enabled = false" in models
    assert "var greenMarkerEnabled = true" in models
    assert "var changeEnabled = false" in models

    capture_output = camera_model.split("func captureOutput", 1)[1].split(
        "private func configureAndStart",
        1,
    )[0]
    assert "snapshot.enabled || snapshot.greenMarkerEnabled || snapshot.changeEnabled" in capture_output

    reset_visual_controls = content.split("private func resetVisualControls", 1)[1].split(
        "private func resetCapMarkerColor",
        1,
    )[0]
    assert "plotterCamera.showGrid" not in reset_visual_controls
    assert "plotterCamera.showMeasurements = true" in reset_visual_controls
    assert "plotterCamera.segmentationEnabled = false" in reset_visual_controls
    assert "plotterCamera.changeDetectionEnabled = false" in reset_visual_controls

    assert "private func drawOverlayLabel" in measurement
    assert "Path(roundedRect: rect, cornerRadius: rect.height / 2)" in measurement
    assert 'drawOverlayLabel(\n            "0,0"' in measurement


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
    assert "Field Grid" not in plotter_panel
    assert "Calibrated Grid" not in plotter_panel
    assert "Original Video" in plotter_panel
    assert "Fit Field" in plotter_panel
    assert "Zoom In" not in plotter_panel
    assert "Zoom Out" not in plotter_panel
    assert "Reset FOV" not in plotter_panel
    assert "togglePlotterFocusMode()" in viewport_intent
    assert "focusPlotterVideoOnPaper(source: \"machine_video_agreement_field_seeded\")" in content
    assert "focusPlotterVideoOnPaper(source: \"wizard_confirm_setup\")" not in content

    assert "func captureOutput(" in camera_model
    assert "try self.analyzer.analyze(pixelBuffer: pixelBuffer" in camera_model
    assert "zoomScale" not in camera_model


def test_confirmed_cap_overlay_is_not_persistent_video_annotation() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    cap_flow = _read(SWIFT_DIR / "ContentViewCapConfirmation.swift")
    overlay = _read(SWIFT_DIR / "MeasurementOverlay.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    click_overlay = support.split("struct CapPositionClickOverlay: View", 1)[1].split(
        "struct CapColorPickOverlay",
        1,
    )[0]
    confirmed_cap_model = models.split("struct ConfirmedCapPoint", 1)[1].split(
        "struct VisualMoveIntent",
        1,
    )[0]

    assert "CapPositionClickOverlay(isActive: manualPenMode)" in content
    assert "ConfirmedCapOverlay" not in content + support
    assert "point: confirmedCapPoint" not in content
    assert "confirmedCapPoint: confirmedCapPoint" not in content
    assert "draw(confirmedCapPoint" not in overlay
    assert "guard isActive else { return }" in click_overlay
    assert "guard let point else { return }" not in click_overlay
    assert "Text(point.label)" not in click_overlay
    assert "var point" not in confirmed_cap_model
    assert "var label" not in confirmed_cap_model
    assert "approximateViewPoint" not in cap_flow
    assert "normalizedView" not in cap_flow
    assert "CONF CAP FIELD ?" not in support + models


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
    assert "setVisualMoveIntent(" in content
    assert "MOVE \\(label)" in content
    assert "drawVisualMoveIntent" in overlay
    assert "drawArrowHead" in overlay
    assert "drawVisualMoveIntentAnchor" in overlay
    canvas_body = overlay.split("Canvas { context, size in", 1)[1].split(".allowsHitTesting", 1)[0]
    assert canvas_body.rfind("drawVisualMoveIntent") > canvas_body.find(
        "draw(carriageMarker: carriageMarker"
    )


def test_main_window_placement_only_filters_main_window_candidates() -> None:
    app_main = _read(SWIFT_DIR / "AppMain.swift")

    assert "applicationDidBecomeActive" not in app_main
    assert "isMainWindowCandidate" in app_main
    assert "window.title != PlotterWindowConfiguration.machineTitle" not in app_main
    assert "window.identifier == PlotterWindowConfiguration.mainIdentifier" in app_main
    assert "window.title == PlotterWindowConfiguration.mainTitle" in app_main
    assert "OperatorWindowID.machineControls" in app_main
    assert "OperatorWindowID.setupPanel" not in app_main
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
    assert "carriageMarkerSmoothingWindow = 7" in camera_model
    assert "carriageMarkerHoldMisses = 12" in camera_model
    assert "publishCarriageMarkerObservation(visionResult.carriageMarker)" in camera_model
    assert "averagedCarriageMarker(from: carriageMarkerHistory)" in camera_model
    assert "var currentCarriageMarker" in content
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
