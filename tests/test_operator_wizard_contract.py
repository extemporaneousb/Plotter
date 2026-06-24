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
    assert "Drawing Checkout" not in setup_panel
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


def test_machine_panel_has_explicit_manual_jog_boundary_override() -> None:
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    panel = _read(SWIFT_DIR / "MachineControlPanel.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    contract = _read(ROOT / "codex_prompts" / "04_PROJECT_CONTRACT.md")

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
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    setup_panel = _read(SWIFT_DIR / "SetupPanel.swift")

    assert "CalibrationWizardView(" in setup_panel
    assert "Visual Field Setup" in wizard
    assert 'title: "Confirm Green Cap"' in wizard
    assert 'title: "Machine-Video Agreement"' in wizard
    assert 'title: "Define Drawing Field"' in wizard
    assert 'title: "Validate Motion"' in wizard
    assert "Confirm Green Cap" in content
    assert "Run Machine-Video Probe" in content
    assert "runMachineVideoAgreementProbe" in content
    assert "measureMachineVideoAgreementNoise" in content
    assert "machineVideoAgreementProbeVectors" in content
    assert "runMachineVideoAgreementVectorJog" in content
    assert "machineVideoAgreementMaxSamples" in content
    assert "isPrecisionConverged" in content + _read(SWIFT_DIR / "Models.swift")
    assert "fieldCornerPrecisionMm" in content + _read(SWIFT_DIR / "Models.swift")
    assert "seedAndLockFieldFromMachineVideoAgreement" in content
    assert "currentGreenCapCameraObservation" in content
    assert "MachineVideoAgreementModel" in content + _read(SWIFT_DIR / "Models.swift")
    assert "Validate Motion" in content
    assert "runFrameLearning()" in content
    assert "runWizardMotionValidation" in content
    assert "approachVisualTarget(target, label: \"VALIDATE\", targetIndex: 1)" in content
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
    active_setup = content.split("private var wizardFiducialStatus", 1)[1].split(
        "private var topStatusLights",
        1,
    )[0]
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


def test_wizard_uses_single_machine_video_setup_path_without_stored_field_reuse() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    setup_panel = _read(SWIFT_DIR / "SetupPanel.swift")
    workspace = _read(SWIFT_DIR / "OperatorWorkspaceState.swift")

    assert "Confirm Setup" not in wizard
    assert "confirmSetup" not in wizard
    assert "canConfirmSetup" not in content
    assert "canConfirmSetup" not in setup_panel
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
    assert "resetCalibrationSetup()" in content
    assert 'post(path: "calibration/setup/reset"' in _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    assert "Visual Field Setup" in wizard
    assert "Paper Homography" not in wizard
    assert "Paper homography" not in content
    assert "Stored visual field in use" not in content
    assert "FIELD run machine-video agreement before drawing field box" in content
    assert "FIELD 200x150 locked from machine-video agreement" in content
    assert "200x150 field registered from agreement" in content


def test_visual_field_setup_uses_four_stage_motion_workflow_without_tip_click() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    client = _read(SWIFT_DIR / "PlotterBridgeClient.swift")
    model = _read(SWIFT_DIR / "PlotterBridgeModel.swift")
    server = _read(BRIDGE_SERVER)
    wizard = _read(SWIFT_DIR / "CalibrationWizardView.swift")
    support = _read(SWIFT_DIR / "CameraOverlaySupportViews.swift")

    assert 'title: "Confirm Green Cap"' in wizard
    assert 'title: "Machine-Video Agreement"' in wizard
    assert 'title: "Define Drawing Field"' in wizard
    assert 'title: "Validate Motion"' in wizard
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


def test_machine_video_agreement_is_precision_driven_before_field_overlay() -> None:
    content = _read(SWIFT_DIR / "ContentView.swift")
    models = _read(SWIFT_DIR / "Models.swift")
    readme = _read(ROOT / "README.md")
    contract = _read(ROOT / "codex_prompts" / "04_PROJECT_CONTRACT.md")
    plan = _read(ROOT / "docs" / "REPOSITORY_PLAN.md")

    assert "private var visualFieldOverlayTransform: PaperRegistrationSnapshot?" in content
    overlay_gate = content.split("private var visualFieldOverlayTransform", 1)[1].split(
        "private var plotterCameraPane",
        1,
    )[0]
    assert "workspace.setupWindowActive" in overlay_gate
    assert "machineVideoAgreementModel?.isPrecisionConverged != true" in overlay_gate
    assert "return nil" in overlay_gate
    assert "paperTransform: visualFieldOverlayTransform" in content

    agreement_probe = content.split("private func runMachineVideoAgreementProbe", 1)[1].split(
        "@MainActor\n    private func measureMachineVideoAgreementNoise",
        1,
    )[0]
    assert "while samples.count < machineVideoAgreementMaxSamples" in agreement_probe
    assert "model.isPrecisionConverged" in agreement_probe
    assert "samples.count >= machineVideoAgreementMinSamples" in agreement_probe
    assert "magnitudeMm = min(machineVideoAgreementMaxMoveMm" in agreement_probe
    assert "machineVideoAgreementMaxSamples = 32" in content
    assert "machineVideoAgreementMinSamples = 8" in content
    assert "fieldCornerPrecisionMm <= 2.0" in models
    assert "conditionNumber <= 30.0" in models
    assert "maxResidualNorm <= max(0.004, observationNoiseNorm * 8.0)" in models

    field_seed = content.split("private func seededFieldCorners", 1)[1].split(
        "private func pointInsideCameraBounds",
        1,
    )[0]
    assert "model.xBasisDxNorm * 200.0" in field_seed
    assert "model.xBasisDyNorm * 200.0" in field_seed
    assert "model.yBasisDxNorm * 150.0" in field_seed
    assert "model.yBasisDyNorm * 150.0" in field_seed
    assert "fitFieldCenter" in field_seed
    assert "halfWidth *= 0.92" not in content
    assert "halfHeight = halfWidth * 0.75" not in content

    assert "before drawing any field box or grid" in readme
    assert "loop increases move size only when the observed video signal is too weak" in readme
    assert "converged 2x2 machine-video transform" in readme
    assert "There is no manual field-corner setup branch" in readme
    assert "before drawing any field box or grid" in contract
    assert "stops on precision convergence, not on a fixed sample count" in contract
    assert "must not expose a manual" in contract
    assert "before drawing any field box or grid" in plan
    assert "stops on precision" in plan
    assert "fixed four-move script" in plan
    assert "does not expose a manual" in plan


def test_operator_log_replaces_bottom_status_bar() -> None:
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
    assert "workspace.appendOperatorLog(newValue" in content
    assert "workspace.appendOperatorLog(status, source: \"Bridge\"" in content
    assert "Operator Log" in log_panel
    assert "textSelection(.enabled)" in log_panel


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
    assert "focusPlotterVideoOnPaper(source: \"machine_video_agreement_field_seeded\")" in content
    assert "focusPlotterVideoOnPaper(source: \"wizard_confirm_setup\")" not in content

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
    assert "setVisualMoveIntent(" in content
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
