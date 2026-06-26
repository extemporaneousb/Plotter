import SwiftUI

private let visualProbeMinimumObservedMm = 1.5
private let machineVideoAgreementMinimumObservedNorm = 0.0015
private let machineVideoAgreementInitialMoveMm = 10.0
private let machineVideoAgreementMaxMoveMm = 50.0
private let machineVideoAgreementMinSamples = 8
private let machineVideoAgreementMaxSamples = 64
private let machineVideoAgreementConvergedUpdateNorm = 0.015
private let machineVideoAgreementNoiseSampleCount = 18
private let machineVideoAgreementSignalToNoise = 8.0
private let visualMotionInitialProbeMoveMm = 8.0
private let visualCapSafeZoneMarginMm = 8.0
let visualFieldFrameInsetMm = visualCapSafeZoneMarginMm
let visualFieldFrameMaxSegmentMm = 25.0
let visualMotionTravelFeedMmMin = 1200.0
private let visualCapReacquireStepXMm = 10.0
private let visualCapReacquireMaxTotalXMm = 40.0
private let visualCapReacquireMaxAttempts = 2
private let visualCapFreshFrameAdvance = 3

struct ContentView: View {
    @ObservedObject var bridge: PlotterBridgeModel
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject private var plotterCamera: CameraModel
    @ObservedObject private var faceCamera: CameraModel
    @Environment(\.openWindow) private var openWindow
    @State private var showLiveVideo = true
    @State private var didLoadSavedFrameState = false
    @State private var fieldRelockTask: Task<Void, Never>?

    init(bridge: PlotterBridgeModel, workspace: OperatorWorkspaceState) {
        self.bridge = bridge
        self.workspace = workspace
        self.plotterCamera = workspace.plotterCamera
        self.faceCamera = workspace.faceCamera
    }

    var plotterOverlay: PlotterOverlaySettings {
        get { workspace.plotterOverlay }
        nonmutating set { workspace.plotterOverlay = newValue }
    }

    var plotterViewport: PlotterViewportSettings {
        get { workspace.plotterViewport }
        nonmutating set { workspace.plotterViewport = newValue }
    }

    var drawingFrame: DrawingFrameSettings {
        get { workspace.drawingFrame }
        nonmutating set { workspace.drawingFrame = newValue }
    }

    var calibrationStatusText: String {
        get { workspace.calibrationStatusText }
        nonmutating set {
            workspace.calibrationStatusText = newValue
            workspace.appendOperatorLog(newValue, source: "Setup", level: logLevel(for: newValue))
        }
    }

    var visualMoveIntent: VisualMoveIntent? {
        get { workspace.visualMoveIntent }
        nonmutating set { workspace.visualMoveIntent = newValue }
    }

    private var frameLearning: FrameLearningState {
        get { workspace.frameLearning }
        nonmutating set { workspace.frameLearning = newValue }
    }

    private var showImageProcessingPanel: Bool {
        get { workspace.showImageProcessingPanel }
        nonmutating set { workspace.showImageProcessingPanel = newValue }
    }

    private var portraitContourMonitorEnabled: Bool {
        get { workspace.portraitContourMonitorEnabled }
        nonmutating set { workspace.portraitContourMonitorEnabled = newValue }
    }

    private var portraitContourMonitorStatus: String {
        get { workspace.portraitContourMonitorStatus }
        nonmutating set { workspace.portraitContourMonitorStatus = newValue }
    }

    private var portraitCaptures: [PortraitCaptureItem] {
        get { workspace.portraitCaptures }
        nonmutating set { workspace.portraitCaptures = newValue }
    }

    private var selectedPortraitCaptureID: UUID? {
        get { workspace.selectedPortraitCaptureID }
        nonmutating set { workspace.selectedPortraitCaptureID = newValue }
    }

    private var manualFiducials: [ManualFiducialPoint] {
        get { workspace.manualFiducials }
        nonmutating set { workspace.manualFiducials = newValue }
    }

    private var manualFiducialMode: Bool {
        get { workspace.manualFiducialMode }
        nonmutating set { workspace.manualFiducialMode = newValue }
    }

    private var manualPenMode: Bool {
        get { workspace.manualPenMode }
        nonmutating set { workspace.manualPenMode = newValue }
    }

    private var manualCapColorMode: Bool {
        get { workspace.manualCapColorMode }
        nonmutating set { workspace.manualCapColorMode = newValue }
    }

    private var confirmedCapPoint: ConfirmedCapPoint? {
        get { workspace.confirmedCapPoint }
        nonmutating set { workspace.confirmedCapPoint = newValue }
    }

    private var machineVideoAgreementModel: MachineVideoAgreementModel? {
        get { workspace.machineVideoAgreementModel }
        nonmutating set { workspace.machineVideoAgreementModel = newValue }
    }

    private var machineVideoAgreementSamples: [MachineVideoAgreementSample] {
        get { workspace.machineVideoAgreementSamples }
        nonmutating set { workspace.machineVideoAgreementSamples = newValue }
    }

    private var visualMotionModel: VisualMotionModel? {
        get { workspace.visualMotionModel }
        nonmutating set { workspace.visualMotionModel = newValue }
    }

    private var visualMotionSamples: [VisualMotionSample] {
        get { workspace.visualMotionSamples }
        nonmutating set { workspace.visualMotionSamples = newValue }
    }

    private var visualCenterDotTaskActive: Bool {
        get { workspace.visualCenterDotTaskActive }
        nonmutating set { workspace.visualCenterDotTaskActive = newValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraWorkspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
            }
            .padding(18)

        }
        .background(Color.black)
        .onAppear {
            guard !didLoadSavedFrameState else { return }
            didLoadSavedFrameState = true
            loadSavedFrameState()
            publishOperatorUIState(reason: "operator_ui_main_window_appeared")
            bridge.recordOperatorEvent("content_view_appeared")
        }
        .task {
            bridge.startOwnedBridgeIfNeeded()
            await bridge.waitForOwnedBridgeStartup()
            await bridge.refreshMachineStatus()
            await bridge.refreshPaperStatus()
            applyPersistedVisualReadiness(await bridge.refreshVisualReadinessStatus())
            var pollIteration = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                pollIteration += 1
                let refreshedHealth = pollIteration.isMultiple(of: 4)
                if refreshedHealth {
                    await bridge.refreshHealth()
                }
                await bridge.refreshMachineStatus()
                if !refreshedHealth {
                    await bridge.refreshPaperStatus()
                }
            }
        }
        .task(id: portraitContourMonitorEnabled) {
            await runPortraitContourMonitor()
        }
        .task {
            while !Task.isCancelled {
                refreshSetupSnapshot()
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
        .onChange(of: workspace.pendingSetupCommand) { _, request in
            guard let request else { return }
            handleSetupCommand(request.command)
            workspace.pendingSetupCommand = nil
        }
        .onChange(of: workspace.pendingPanelCommand) { _, request in
            guard let request else { return }
            handlePanelCommand(request.command)
            workspace.pendingPanelCommand = nil
        }
        .onChange(of: plotterOverlay) { _, _ in
            saveFrameState()
        }
        .onChange(of: plotterViewport) { _, _ in
            saveFrameState()
        }
        .onChange(of: bridge.paperRegistrationSnapshot?.registrationId) { _, _ in
            if plotterViewport.focusMode == .focused {
                focusPlotterVideoOnPaper(source: "paper_registration_changed")
            }
        }
        .onChange(of: workspace.visualFieldWidthMm) { _, _ in
            scheduleEditableVisualFieldRelock(source: "field_width_changed")
        }
        .onChange(of: workspace.visualFieldHeightMm) { _, _ in
            scheduleEditableVisualFieldRelock(source: "field_height_changed")
        }
        .onChange(of: bridge.statusText) { _, status in
            workspace.appendOperatorLog(status, source: "Bridge", level: logLevel(for: status))
        }
        .onChange(of: drawingFrame) { _, _ in
            saveFrameState()
        }
        .onDisappear {
            bridge.recordOperatorEvent("content_view_disappeared")
            plotterCamera.stop()
            faceCamera.stop()
        }
    }

    @ViewBuilder
    private var cameraWorkspace: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width >= geometry.size.height
            cameraWorkspaceContent(horizontal: horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func cameraWorkspaceContent(horizontal: Bool) -> some View {
        if workspace.plotterCameraVisible && workspace.faceCameraVisible {
            if horizontal {
                HStack(spacing: 1) { plotterCameraPane; faceCameraPane }
            } else {
                VStack(spacing: 1) { plotterCameraPane; faceCameraPane }
            }
        } else if workspace.plotterCameraVisible {
            plotterCameraPane
        } else if workspace.faceCameraVisible {
            faceCameraPane
        } else {
            emptyCameraWorkspace
        }
    }

    private var emptyCameraWorkspace: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.28))
                Text("NO CAMERA SELECTED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
    }

    private var visualFieldOverlayTransform: PaperRegistrationSnapshot? {
        guard let registration = bridge.paperRegistrationSnapshot else { return nil }
        if workspace.setupWindowActive,
           machineVideoAgreementModel == nil,
           !visualMotionValidated {
            return nil
        }
        return registration
    }

    private var plotterCameraPane: some View {
        ZStack {
            Color.black

            PlotterViewportTransform(settings: plotterViewport) {
                ZStack {
                    if showLiveVideo && plotterCamera.isRunning {
                        CameraPreview(
                            session: plotterCamera.session,
                            videoGravity: plotterViewport.previewMode.videoGravity
                        )
                        .modifier(PlotterVideoFilterModifier(filter: plotterViewport.videoFilter))
                    } else {
                        CameraPlaceholder(camera: plotterCamera)
                    }

                    MeasurementOverlay(
                        segments: plotterCamera.segments,
                        carriageMarker: (manualPenMode || manualCapColorMode) ? nil : currentCarriageMarker,
                        visualMoveIntent: visualMoveIntent,
                        motionTracks: plotterCamera.motionTracks,
                        expectedPathSegments: bridge.expectedPathSegments,
                        bindingMarkPreviewSegments: bridge.bindingMarkPreviewSegments,
                        bindingMarkPreviewPoints: bridge.bindingMarkPreviewPoints,
                        paperTransform: visualFieldOverlayTransform,
                        plotterOverlay: plotterOverlay,
                        pathRevealProgress: bridge.pathRevealProgress,
                        videoSize: plotterCamera.videoSize,
                        previewMode: plotterViewport.previewMode,
                        showMeasurements: plotterCamera.showMeasurements
                    )

                }
            }

            ConfirmedCapOverlay(point: confirmedCapPoint, isActive: manualPenMode)
            CapColorPickOverlay(isActive: manualCapColorMode)

            if manualCapColorMode {
                ManualPenClickLayer(
                    settings: plotterViewport,
                    videoSize: plotterCamera.videoSize,
                    onMark: recordCapMarkerColor
                )
            } else if manualPenMode {
                ManualPenClickLayer(
                    settings: plotterViewport,
                    videoSize: plotterCamera.videoSize,
                    onMark: recordConfirmedCap
                )
            }

            VisualFieldEditLayer(
                settings: plotterViewport,
                videoSize: plotterCamera.videoSize,
                corners: editableVisualFieldCorners,
                fieldWidthMm: desiredVisualFieldWidthMm,
                fieldHeightMm: desiredVisualFieldHeightMm,
                isVisible: workspace.setupWindowActive && editableVisualFieldCorners.count == 4,
                isActive: canEditVisualFieldBox,
                onUpdate: updateEditableVisualFieldCorners
            )

            CameraPaneBadge(camera: plotterCamera)
        }
        .clipped()
        .overlay(Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var faceCameraPane: some View {
        ZStack {
            Color.black

            if portraitContourMonitorEnabled {
                Color.black
            } else if showLiveVideo && faceCamera.isRunning {
                CameraPreview(session: faceCamera.session)
            } else {
                CameraPlaceholder(camera: faceCamera)
            }

            if faceCamera.segmentationEnabled && !portraitContourMonitorEnabled {
                FaceContourOverlay(
                    segments: faceCamera.segments,
                    videoSize: faceCamera.videoSize,
                    previewMode: .fill
                )
            }

            PortraitContourPreviewOverlay(
                overlay: bridge.faceContourPreviewOverlay,
                videoSize: faceCamera.videoSize,
                previewMode: .fill
            )

            if showImageProcessingPanel {
                ImageProcessingPanel(
                    bridge: bridge,
                    visualContourCount: faceCamera.segments.count,
                    isBridgeOnline: bridge.isOnline
                )
            }

            CameraPaneBadge(camera: faceCamera)
        }
        .clipped()
        .overlay(Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private func loadSavedFrameState() {
        guard let state = FrameStateStore.load() else { return }
        plotterOverlay = state.plotterOverlay
        plotterViewport = state.plotterViewport ?? PlotterViewportSettings()
        drawingFrame = state.drawingFrame
    }

    private func saveFrameState() {
        FrameStateStore.save(
            plotterOverlay: plotterOverlay,
            drawingFrame: drawingFrame,
            plotterViewport: plotterViewport
        )
    }

    private func publishOperatorUIState(reason: String) {
        bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: reason)
    }

    private func setCameraVisibility(_ camera: CameraModel, visible: Bool, source: String) {
        let role = camera.role == .plotter ? "plotter" : "face"
        if camera.role == .plotter {
            workspace.plotterCameraVisible = visible
        } else {
            workspace.faceCameraVisible = visible
        }
        if visible {
            if !camera.isRunning { camera.start() }
        } else {
            camera.stop()
        }
        bridge.recordOperatorEvent(
            "camera_visibility_changed",
            details: [
                "camera": role,
                "visible": visible,
                "source": source
            ]
        )
        publishOperatorUIState(reason: "operator_ui_camera_visibility_changed")
    }

    private func toggleCameraVisibility(_ camera: CameraModel, source: String) {
        let visible = camera.role == .plotter ? workspace.plotterCameraVisible : workspace.faceCameraVisible
        setCameraVisibility(camera, visible: !visible, source: source)
    }

    private func showPlotterCameraForSetup(source: String) {
        setCameraVisibility(plotterCamera, visible: true, source: source)
        showLiveVideo = true
    }

    private func toggleOperatorWindow(id: String, title: String, source: String, beforeOpen: (() -> Void)? = nil) {
        let didClose = OperatorWindowSupport.closeWindow(title: title, identifier: id)
        if didClose {
            bridge.recordOperatorEvent(
                "window_toggled",
                details: ["window_id": id, "visible": false, "source": source]
            )
            if id == OperatorWindowID.setupPanel {
                hideCalibrationWizard()
            }
            publishOperatorUIState(reason: "operator_ui_window_toggled")
            return
        }

        beforeOpen?()
        openWindow(id: id)
        bridge.recordOperatorEvent(
            "window_toggled",
            details: ["window_id": id, "visible": true, "source": source]
        )
        publishOperatorUIState(reason: "operator_ui_window_toggled")
    }

    private func handleSetupCommand(_ command: SetupPanelCommand) {
        switch command {
        case .primary:
            runCalibrationWizardPrimaryAction()
        case .drawFrame:
            drawValidatedFieldFrame()
        case .reset:
            resetCalibrationWizard()
        case .hide:
            hideCalibrationWizard()
        }
    }

    private func handlePanelCommand(_ command: OperatorPanelCommand) {
        switch command {
        case .useOriginalPlotterVideo:
            useOriginalPlotterVideo(source: "plotter_video_panel")
        case .togglePlotterFocus:
            togglePlotterFocusMode()
        case .sampleCapColor:
            startCapColorPick()
        case .resetCapColor:
            resetCapMarkerColor()
        case .resetVisualControls:
            resetVisualControls()
        case .createPortraitDrawing:
            Task { await createPortraitContourDrawing() }
        case .selectPortraitCapture(let id):
            if let item = portraitCaptures.first(where: { $0.id == id }) {
                selectPortraitCapture(item)
            }
        }
    }

    private func refreshSetupSnapshot() {
        workspace.setupSnapshot = SetupPanelSnapshot(
            instructionText: wizardInstructionText,
            fiducialDetail: wizardFiducialDetail,
            fiducialStatus: wizardFiducialStatus,
            greenCapDetail: wizardGreenCapDetail,
            greenCapStatus: wizardGreenCapStatus,
            visualCalibrationDetail: frameLearning.detail,
            visualCalibrationStatus: wizardMotionProbeStatus,
            bindingDetail: wizardMotionValidationDetail,
            bindingStatus: wizardMotionValidationStatus,
            primaryActionTitle: wizardPrimaryActionTitle,
            primaryActionEnabled: wizardPrimaryActionEnabled,
            primaryActionDisabledReason: wizardPrimaryActionDisabledReason,
            drawFrameVisible: wizardDrawFrameVisible,
            drawFrameEnabled: wizardDrawFrameEnabled,
            drawFrameDisabledReason: wizardDrawFrameDisabledReason,
            hasPaperLock: bridge.hasPaperLock,
            capStateLabel: wizardCapStateLabel,
            isLiveMotionMode: bridge.isLiveMotionMode,
            capDetected: currentCarriageMarker != nil
        )
    }

    @MainActor
    private func previewImageFromCurrentFrame() async -> Bool {
        bridge.recordOperatorEvent("portrait_preview_capture_started")
        do {
            faceCamera.segmentationEnabled = true
            let raster = try await faceCamera.captureFaceRasterBurst(columns: 28, rows: 36)
            let settings = bridge.portraitContourSettings
            let rect = drawingFrame.rect(workspaceXMm: bridge.workspaceXMm, workspaceYMm: bridge.workspaceYMm)
            let frame = BridgeDrawingFrameRequest(
                originXMm: Double(rect.minX) * bridge.workspaceXMm, originYMm: Double(rect.minY) * bridge.workspaceYMm,
                widthMm: Double(rect.width) * bridge.workspaceXMm, heightMm: Double(rect.height) * bridge.workspaceYMm,
                flipY: false
            )
            let bridgeCanPreview = settings.technique == .contours && bridge.isOnline && !bridge.isRunning && !bridge.isMachineBusy && !bridge.isCalibrating
            if bridgeCanPreview {
                _ = await bridge.previewPortraitContours(raster, frame: frame, settings: settings)
                if bridge.faceContourPreviewOverlay != nil {
                    calibrationStatusText = "VERIFY \(bridge.imagePreviewStatus) \(bridge.imagePreviewDetail)"
                    return true
                }
            }

            bridge.expectedPathSegments = []
            let updated = bridge.updateLivePortraitContourPreview(from: raster, commandId: "portrait-capture-\(UUID().uuidString.lowercased())", settings: settings)
            calibrationStatusText = updated
                ? "PORTRAIT \(bridge.imagePreviewStatus) \(bridge.imagePreviewDetail)"
                : "PORTRAIT IMG NO DRAWING"
            return updated
        } catch {
            faceCamera.statusText = error.localizedDescription
            bridge.statusText = error.localizedDescription
            bridge.imagePreviewStatus = "IMG ERR"
            bridge.imagePreviewDetail = "VISUAL ONLY"
            bridge.previewStatus = "SIM ERR"
            bridge.recordOperatorEvent(
                "portrait_preview_capture_failed",
                details: ["error": error.localizedDescription]
            )
            return false
        }
    }

    @MainActor
    private func createPortraitContourDrawing() async {
        let technique = bridge.portraitContourSettings.technique
        let completed = await previewImageFromCurrentFrame()
        guard completed, let overlay = bridge.faceContourPreviewOverlay else {
            return
        }
        let item = PortraitCaptureItem(
            id: UUID(),
            createdAt: Date(),
            technique: technique,
            status: bridge.imagePreviewStatus,
            detail: bridge.imagePreviewDetail,
            contourCount: overlay.contours.count,
            expectedPathSegments: bridge.expectedPathSegments,
            overlay: overlay
        )
        selectedPortraitCaptureID = item.id
        portraitCaptures.insert(item, at: 0)
        portraitContourMonitorEnabled = false
        if portraitCaptures.count > 12 {
            portraitCaptures.removeLast(portraitCaptures.count - 12)
        }
        calibrationStatusText = "PORTRAIT saved \(technique.captureLabel.lowercased()) \(item.contourCount)"
        bridge.recordOperatorEvent(
            "portrait_capture_saved",
            details: [
                "capture_id": item.id.uuidString,
                "technique": technique.rawValue,
                "contours": item.contourCount,
                "preview_segments": item.expectedPathSegments.count
            ]
        )
    }

    @MainActor
    private func selectPortraitCapture(_ item: PortraitCaptureItem) {
        selectedPortraitCaptureID = item.id
        portraitContourMonitorEnabled = false
        bridge.restorePortraitCapture(item)
        calibrationStatusText = "PORTRAIT selected \(item.technique.captureLabel.lowercased()) \(item.contourCount)"
    }

    @MainActor
    private func runPortraitContourMonitor() async {
        while portraitContourMonitorEnabled && !Task.isCancelled {
            if !faceCamera.isRunning {
                portraitContourMonitorStatus = "LIVE CAMERA OFF"
            } else {
                do {
                    let sample = try await faceCamera.captureFaceRaster(
                        columns: 28,
                        rows: 36,
                        updatesStatus: false
                    )
                    let updated = bridge.updateLivePortraitContourPreview(
                        from: sample,
                        settings: bridge.portraitContourSettings
                    )
                    portraitContourMonitorStatus = updated
                        ? "LIVE \(bridge.imagePreviewContourCount)C"
                        : "LIVE NO CONTOUR"
                } catch {
                    portraitContourMonitorStatus = "LIVE \(shortPortraitMonitorError(error))"
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func shortPortraitMonitorError(_ error: Error) -> String {
        let message = error.localizedDescription.uppercased()
        if message.contains("FACE") { return "NO FACE" }
        if message.contains("FRAME") { return "NO FRAME" }
        return "WAIT"
    }

    private func logLevel(for message: String) -> OperatorLogLevel {
        let normalized = message.uppercased()
        if normalized.contains("ERROR")
            || normalized.contains("ERR")
            || normalized.contains("FAILED")
            || normalized.contains("ALARM") {
            return .error
        }
        if normalized.contains("BLOCK")
            || normalized.contains("STOP")
            || normalized.contains("WEAK")
            || normalized.contains("PIN")
            || normalized.contains("LOST") {
            return .warning
        }
        return .info
    }

    @MainActor
    private func runFrameLearning() async {
        guard bridge.isLiveMotionMode else {
            calibrationStatusText = "CAL machine-video probe blocked: \(bridge.motionGateMessage)"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: bridge.motionGateMessage,
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }

        guard bridge.isOnline else {
            calibrationStatusText = "CAL machine-video probe blocked: bridge offline"
            frameLearning = FrameLearningState(
                status: "ERROR",
                detail: "Bridge offline",
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: "-"
            )
            return
        }

        guard await waitForGreenCapCameraObservation(timeoutSeconds: 3.0) != nil else {
            calibrationStatusText = "CAL machine-video probe blocked: cap not detected"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: "Green cap detection required before machine-video agreement",
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }

        if bridge.hasPaperLock, let agreement = machineVideoAgreementModel {
            visualMotionModel = nil
            visualMotionSamples = []
            _ = bridge.resetVisualCalibrationSession(prefix: "swift-probe")
            manualPenMode = false
            manualFiducialMode = false
            manualCapColorMode = false

            await bridge.refreshMachineStatus()
            calibrationStatusText = "CAL motion calibration using adjusted drawing border"
            frameLearning = FrameLearningState(
                status: "LEARN",
                detail: "Sampling motion in adjusted drawing border",
                sampleCount: 0,
                xPixelsPerMm: agreement.xBasisLengthNorm,
                yPixelsPerMm: agreement.yBasisLengthNorm,
                lastPins: bridge.machinePins
            )

            await bridge.penUpMachine()
            guard !bridge.isMachineAlarm else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Pen-up failed or machine alarm"
                calibrationStatusText = "CAL motion calibration stopped: pen-up failed"
                return
            }

            await runFieldMotionCalibration(using: agreement)
            return
        }

        machineVideoAgreementModel = nil
        machineVideoAgreementSamples = []
        visualMotionModel = nil
        visualMotionSamples = []
        _ = bridge.resetVisualCalibrationSession(prefix: "swift-probe")
        manualFiducials = []
        manualPenMode = false
        manualFiducialMode = false
        manualCapColorMode = false

        await bridge.refreshMachineStatus()

        calibrationStatusText = "CAL machine-video agreement starting"
        frameLearning = FrameLearningState(
            status: "LEARN",
            detail: "Learning machine +X/+Y in camera space",
            sampleCount: 0,
            xPixelsPerMm: 0,
            yPixelsPerMm: 0,
            lastPins: bridge.machinePins
        )

        await bridge.penUpMachine()
        guard !bridge.isMachineAlarm else {
            frameLearning.status = "STOP"
            frameLearning.detail = "Pen-up failed or machine alarm"
            calibrationStatusText = "CAL machine-video probe stopped: pen-up failed"
            return
        }

        guard let agreement = await runMachineVideoAgreementProbe() else {
            return
        }
        machineVideoAgreementModel = agreement

        guard await seedAndLockFieldFromMachineVideoAgreement(agreement) else {
            return
        }

        await runFieldMotionCalibration(using: agreement)
    }

    @MainActor
    private func runFieldMotionCalibration(using agreement: MachineVideoAgreementModel) async {
        guard let initialObservation = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            calibrationStatusText = "CAL motion calibration blocked: cap is not mapped into the field"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: "Field locked, but cap is not mapped into field millimeters",
                sampleCount: machineVideoAgreementSamples.count,
                xPixelsPerMm: agreement.xBasisLengthNorm,
                yPixelsPerMm: agreement.yBasisLengthNorm,
                lastPins: bridge.machinePins
            )
            return
        }
        if let confirmedCapPoint {
            self.confirmedCapPoint = ConfirmedCapPoint(
                point: confirmedCapPoint.point,
                cameraPoint: initialObservation.cameraPoint,
                paperMm: initialObservation.paperMm
            )
        }

        guard await bridge.observeVisualCapForProbe(
            cameraPoint: initialObservation.cameraPoint,
            paperMm: initialObservation.paperMm,
            confidence: initialObservation.strength,
            safeZoneInsetXMm: visualCapSafeZoneMarginMm,
            safeZoneInsetYMm: visualCapSafeZoneMarginMm
        ) else {
            frameLearning.status = "STOP"
            frameLearning.detail = "Bridge rejected cap observation"
            calibrationStatusText = "CAL motion calibration stopped: bridge cap observation failed"
            return
        }

        calibrationStatusText = "CAL motion calibration sampling field-mm X/Y moves"

        let commandDistanceMm = visualMotionInitialProbeMoveMm
        let probeCommands: [(axis: String, distance: Double)] = [
            ("X", commandDistanceMm),
            ("X", -commandDistanceMm),
            ("Y", commandDistanceMm),
            ("Y", -commandDistanceMm)
        ]
        var samples: [FrameLearningSample] = []

        for command in probeCommands {
            guard let sample = await runVisualAxisProbeMove(
                axis: command.axis,
                distanceMm: command.distance,
                projectedPaperDelta: visualProbeProjectedPaperDelta(
                    axis: command.axis,
                    distanceMm: command.distance,
                    samples: samples
                ),
                sampleIndex: samples.count + 1
            ) else {
                return
            }
            samples.append(sample)
            updateLearningSummary(
                samples: samples,
                status: "LEARN",
                detail: String(
                    format: "%@ %.0f observed %.1fmm",
                    sample.axis,
                    sample.distanceMm,
                    sample.observedDistanceMm
                )
            )
        }

        let evaluation = evaluateVisualAxisProbe(samples: samples)
        let evaluatedSamples = applyResiduals(to: samples)
        updateLearningSummary(
            samples: evaluatedSamples,
            status: evaluation.passed ? "MEASURED" : "WEAK",
            detail: evaluation.detail
        )

        guard evaluation.passed else {
            visualMotionModel = nil
            visualMotionSamples = []
            calibrationStatusText = "CAL motion calibration weak: \(evaluation.detail)"
            return
        }

        let usableSamples = evaluatedSamples.filter {
            $0.observedDistanceMm >= visualProbeMinimumObservedMm
        }
        let fittedSamples = usableSamples.map { visualMotionSample(from: $0) }
        guard let fittedModel = VisualMotionModel.solve(samples: fittedSamples) else {
            visualMotionModel = nil
            visualMotionSamples = []
            updateLearningSummary(
                samples: evaluatedSamples,
                status: "WEAK",
                detail: "Motion basis solve failed"
            )
            calibrationStatusText = "CAL motion calibration weak: basis solve failed"
            return
        }
        visualMotionSamples = fittedSamples
        visualMotionModel = fittedModel
        updateLearningSummary(
            samples: evaluatedSamples,
            status: "MEASURED",
            detail: String(
                format: "Motion measured rms %.1f max %.1f samples %d; validate target next",
                fittedModel.rmsResidualMm,
                fittedModel.maxResidualMm,
                fittedModel.sampleCount
            )
        )
        calibrationStatusText = "CAL motion calibration measured; validate target next"
    }

    @MainActor
    private func runMachineVideoAgreementProbe() async -> MachineVideoAgreementModel? {
        guard let noise = await measureMachineVideoAgreementNoise() else {
            frameLearning.status = "STOP"
            frameLearning.detail = "Could not measure cap jitter before agreement"
            calibrationStatusText = "CAL machine-video probe stopped: cap jitter measurement failed"
            return nil
        }

        let minimumSignalNorm = max(
            machineVideoAgreementMinimumObservedNorm,
            noise.rmsNorm * machineVideoAgreementSignalToNoise,
            noise.maxDeviationNorm * 3.0
        )
        var samples: [MachineVideoAgreementSample] = []
        var magnitudeMm = machineVideoAgreementInitialMoveMm
        var bestModel: MachineVideoAgreementModel?
        var latestUpdateMagnitude: Double?
        var cycle = 0

        frameLearning = FrameLearningState(
            status: "NOISE",
            detail: String(
                format: "Cap jitter rms %.4f max %.4f; need signal %.4f",
                noise.rmsNorm,
                noise.maxDeviationNorm,
                minimumSignalNorm
            ),
            sampleCount: 0,
            xPixelsPerMm: 0,
            yPixelsPerMm: 0,
            lastPins: bridge.machinePins
        )
        calibrationStatusText = String(
            format: "CAL machine-video jitter rms %.4f; adaptive agreement starting",
            noise.rmsNorm
        )
        bridge.recordOperatorEvent(
            "machine_video_agreement_noise_measured",
            details: [
                "sample_count": noise.sampleCount,
                "rms_norm": noise.rmsNorm,
                "max_deviation_norm": noise.maxDeviationNorm,
                "minimum_signal_norm": minimumSignalNorm
            ]
        )

        while samples.count < machineVideoAgreementMaxSamples {
            cycle += 1
            let vectors = machineVideoAgreementProbeVectors(magnitudeMm: magnitudeMm, model: bestModel)
            for vector in vectors {
                guard samples.count < machineVideoAgreementMaxSamples else { break }
                guard let sample = await runMachineVideoAgreementMove(
                    label: vector.label,
                    machineDxMm: vector.xMm,
                    machineDyMm: vector.yMm,
                    minimumSignalNorm: minimumSignalNorm,
                    sampleIndex: samples.count + 1
                ) else {
                    return nil
                }
                samples.append(sample)
                machineVideoAgreementSamples = samples

                if let model = MachineVideoAgreementModel.solve(
                    samples: samples,
                    observationNoiseNorm: noise.rmsNorm
                ) {
                    latestUpdateMagnitude = model.relativeUpdateMagnitude(from: bestModel)
                    bestModel = model
                    machineVideoAgreementModel = model
                    updateLiveMachineVideoFieldFrame(from: model, center: sample.afterCameraPoint)
                }
                updateMachineVideoAgreementSummary(
                    samples: samples,
                    status: machineVideoAgreementStatus(
                        for: bestModel,
                        updateMagnitude: latestUpdateMagnitude
                    ),
                    noise: noise,
                    minimumSignalNorm: minimumSignalNorm,
                    bestModel: bestModel,
                    updateMagnitude: latestUpdateMagnitude
                )
            }

            if let model = bestModel,
               samples.count >= machineVideoAgreementMinSamples,
               let latestUpdateMagnitude,
               latestUpdateMagnitude <= machineVideoAgreementConvergedUpdateNorm {
                machineVideoAgreementModel = model
                frameLearning = FrameLearningState(
                    status: "AGREE",
                    detail: String(
                        format: "Agreement update %.4f rms %.4f max %.4f cond %.1f samples %d",
                        latestUpdateMagnitude,
                        model.rmsResidualNorm,
                        model.maxResidualNorm,
                        model.conditionNumber,
                        model.sampleCount
                    ),
                    sampleCount: model.sampleCount,
                    xPixelsPerMm: model.xBasisLengthNorm,
                    yPixelsPerMm: model.yBasisLengthNorm,
                    lastPins: bridge.machinePins
                )
                calibrationStatusText = "CAL machine-video update converged; seeding \(desiredVisualFieldSizeLabel) field"
                recordMachineVideoAgreementModel(
                    model,
                    noise: noise,
                    minimumSignalNorm: minimumSignalNorm,
                    updateMagnitude: latestUpdateMagnitude
                )
                return model
            }

            if bestModel != nil {
                magnitudeMm = min(machineVideoAgreementMaxMoveMm, max(magnitudeMm * 1.65, magnitudeMm + 4.0))
            } else {
                magnitudeMm = min(machineVideoAgreementMaxMoveMm, max(magnitudeMm * 1.45, magnitudeMm + 2.0))
            }
            calibrationStatusText = String(
                format: "CAL machine-video agreement refining cycle %d samples %d next %.1fmm",
                cycle,
                samples.count,
                magnitudeMm
            )
        }

        guard let model = bestModel else {
            frameLearning.status = "WEAK"
            frameLearning.detail = "Machine-video basis solve failed"
            frameLearning.sampleCount = samples.count
            calibrationStatusText = "CAL machine-video agreement weak: basis solve failed"
            return nil
        }
        machineVideoAgreementModel = model
        frameLearning = FrameLearningState(
            status: "ESTIMATE",
            detail: String(
                format: "Using latest estimate update %@ rms %.4f max %.4f cond %.1f samples %d",
                latestUpdateMagnitude.map { String(format: "%.4f", $0) } ?? "--",
                model.rmsResidualNorm,
                model.maxResidualNorm,
                model.conditionNumber,
                model.sampleCount
            ),
            sampleCount: model.sampleCount,
            xPixelsPerMm: model.xBasisLengthNorm,
            yPixelsPerMm: model.yBasisLengthNorm,
            lastPins: bridge.machinePins
        )
        calibrationStatusText = "CAL machine-video using latest estimate; seeding provisional \(desiredVisualFieldSizeLabel) field"
        recordMachineVideoAgreementModel(
            model,
            noise: noise,
            minimumSignalNorm: minimumSignalNorm,
            updateMagnitude: latestUpdateMagnitude
        )
        return model
    }

    @MainActor
    private func measureMachineVideoAgreementNoise() async -> MachineVideoAgreementNoise? {
        var observations: [GreenCapCameraObservation] = []
        var lastFrame: Int?
        let deadline = Date().addingTimeInterval(4.0)

        while observations.count < machineVideoAgreementNoiseSampleCount && Date() < deadline {
            guard let observation = await waitForGreenCapCameraObservation(
                afterFrame: lastFrame,
                timeoutSeconds: 0.7
            ) else {
                continue
            }
            observations.append(observation)
            lastFrame = observation.frameNumber
        }

        guard observations.count >= 6 else { return nil }
        let centerX = observations.reduce(0.0) { $0 + Double($1.cameraPoint.x) } / Double(observations.count)
        let centerY = observations.reduce(0.0) { $0 + Double($1.cameraPoint.y) } / Double(observations.count)
        let deviations = observations.map {
            hypot(Double($0.cameraPoint.x) - centerX, Double($0.cameraPoint.y) - centerY)
        }
        let rms = sqrt(deviations.reduce(0.0) { $0 + $1 * $1 } / Double(observations.count))
        return MachineVideoAgreementNoise(
            sampleCount: observations.count,
            centerXNorm: centerX,
            centerYNorm: centerY,
            rmsNorm: max(rms, 0.000_25),
            maxDeviationNorm: max(deviations.max() ?? 0.0, 0.000_5)
        )
    }

    private func machineVideoAgreementProbeVectors(
        magnitudeMm: Double,
        model: MachineVideoAgreementModel? = nil
    ) -> [(label: String, xMm: Double, yMm: Double)] {
        let magnitude = min(machineVideoAgreementMaxMoveMm, max(1.0, magnitudeMm))
        let diagonal = magnitude / sqrt(2.0)
        let xMoves: [(label: String, xMm: Double, yMm: Double)] = [
            ("X+", magnitude, 0.0),
            ("X-", -magnitude, 0.0)
        ]
        let yMoves: [(label: String, xMm: Double, yMm: Double)] = [
            ("Y+", 0.0, magnitude),
            ("Y-", 0.0, -magnitude)
        ]
        let bootstrapMoves: [(label: String, xMm: Double, yMm: Double)] = [
            ("X+", magnitude, 0.0),
            ("Y+", 0.0, magnitude),
            ("X-", -magnitude, 0.0),
            ("Y-", 0.0, -magnitude)
        ]
        let diagonalMoves: [(label: String, xMm: Double, yMm: Double)] = [
            ("D++", diagonal, diagonal),
            ("D--", -diagonal, -diagonal),
            ("D+-", diagonal, -diagonal),
            ("D-+", -diagonal, diagonal)
        ]
        guard let model else {
            return bootstrapMoves
        }
        if model.xBasisLengthNorm <= model.yBasisLengthNorm {
            return xMoves + yMoves + diagonalMoves
        }
        return yMoves + xMoves + diagonalMoves
    }

    private func machineVideoAgreementStatus(for model: MachineVideoAgreementModel?) -> String {
        machineVideoAgreementStatus(for: model, updateMagnitude: nil)
    }

    private func machineVideoAgreementStatus(
        for model: MachineVideoAgreementModel?,
        updateMagnitude: Double?
    ) -> String {
        guard model != nil else { return "LEARN" }
        if let updateMagnitude,
           updateMagnitude <= machineVideoAgreementConvergedUpdateNorm {
            return "AGREE"
        }
        return "ESTIMATE"
    }

    @MainActor
    private func runMachineVideoAgreementMove(
        label: String,
        machineDxMm: Double,
        machineDyMm: Double,
        minimumSignalNorm: Double,
        sampleIndex: Int
    ) async -> MachineVideoAgreementSample? {
        let feedMmMin = min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin)
        let baseLength = max(hypot(machineDxMm, machineDyMm), 0.000_001)
        let expansionScales = [1.0, 1.6, 2.4, 3.2]

        for (attemptIndex, scale) in expansionScales.enumerated() {
            let requestedLength = min(machineVideoAgreementMaxMoveMm, baseLength * scale)
            let commandScale = requestedLength / baseLength
            let commandX = machineDxMm * commandScale
            let commandY = machineDyMm * commandScale
            guard let before = await waitForGreenCapCameraObservation(timeoutSeconds: 3.0) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Cap marker lost before machine-video move"
                calibrationStatusText = "CAL machine-video probe stopped: cap lost before move"
                return nil
            }

            frameLearning.detail = String(
                format: "Machine-video %@ X%+.1f Y%+.1f attempt %d",
                label,
                commandX,
                commandY,
                attemptIndex + 1
            )
            calibrationStatusText = String(
                format: "CAL machine-video probe: %@ X%+.1f Y%+.1f",
                label,
                commandX,
                commandY
            )

            guard let response = await runSetupVectorJog(
                xMm: commandX,
                yMm: commandY,
                feedMmMin: feedMmMin
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = bridge.statusText.isEmpty ? "Learning move failed" : bridge.statusText
                calibrationStatusText = "CAL machine-video probe stopped: \(frameLearning.detail)"
                return nil
            }

            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                frameLearning.status = "STOP"
                frameLearning.detail = "Pin active after \(label) move: \(pins)"
                frameLearning.lastPins = pins
                calibrationStatusText = "CAL machine-video probe stopped: pin active \(pins)"
                return nil
            }

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let after = await waitForFreshGreenCapCameraObservation(
                afterFrame: before.frameNumber,
                timeoutSeconds: 3.0
            ) else {
                if attemptIndex + 1 < expansionScales.count {
                    calibrationStatusText = String(
                        format: "CAL machine-video probe: no fresh cap after %@; retrying",
                        label
                    )
                    continue
                }
                frameLearning.status = "STOP"
                frameLearning.detail = "No fresh cap observation after \(label) move"
                calibrationStatusText = "CAL machine-video probe stopped: no fresh cap observation"
                return nil
            }

            let dx = Double(after.cameraPoint.x - before.cameraPoint.x)
            let dy = Double(after.cameraPoint.y - before.cameraPoint.y)
            let observedDistance = hypot(dx, dy)
            if observedDistance < minimumSignalNorm,
               attemptIndex + 1 < expansionScales.count {
                bridge.recordOperatorEvent(
                    "machine_video_agreement_weak_signal",
                    details: [
                        "sample_index": sampleIndex,
                        "attempt_index": attemptIndex + 1,
                        "label": label,
                        "command_x_mm": commandX,
                        "command_y_mm": commandY,
                        "observed_distance_norm": observedDistance,
                        "minimum_signal_norm": minimumSignalNorm
                    ]
                )
                calibrationStatusText = String(
                    format: "CAL machine-video %@ signal %.4f < %.4f; expanding move",
                    label,
                    observedDistance,
                    minimumSignalNorm
                )
                continue
            }

            let sample = MachineVideoAgreementSample(
                label: label,
                machineDxMm: commandX,
                machineDyMm: commandY,
                observedDxNorm: dx,
                observedDyNorm: dy,
                observedDistanceNorm: observedDistance,
                afterCameraPoint: after.cameraPoint,
                strength: min(before.strength, after.strength)
            )
            bridge.recordOperatorEvent(
                "machine_video_agreement_sample",
                details: [
                    "sample_index": sampleIndex,
                    "attempt_index": attemptIndex + 1,
                    "label": label,
                    "command_x_mm": commandX,
                    "command_y_mm": commandY,
                    "before_frame": before.frameNumber,
                    "after_frame": after.frameNumber,
                    "before_camera_x": before.cameraPoint.x,
                    "before_camera_y": before.cameraPoint.y,
                    "after_camera_x": after.cameraPoint.x,
                    "after_camera_y": after.cameraPoint.y,
                    "observed_dx_norm": dx,
                    "observed_dy_norm": dy,
                    "observed_distance_norm": observedDistance
                ]
            )
            calibrationStatusText = String(
                format: "CAL machine-video sample %d %@ X%+.1f Y%+.1f cam d%.4f %.4f",
                sampleIndex,
                label,
                commandX,
                commandY,
                dx,
                dy
            )
            return sample
        }

        return nil
    }

    @MainActor
    private func runSetupVectorJog(
        xMm: Double,
        yMm: Double,
        feedMmMin: Double
    ) async -> MachineCommandResponse? {
        var latestResponse: MachineCommandResponse?
        if abs(xMm) >= 0.000_001 {
            guard let response = await bridge.learningJog(axis: "X", distanceMm: xMm, feedMmMin: feedMmMin) else {
                return nil
            }
            latestResponse = response
            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                return response
            }
        }
        if abs(yMm) >= 0.000_001 {
            guard let response = await bridge.learningJog(axis: "Y", distanceMm: yMm, feedMmMin: feedMmMin) else {
                return nil
            }
            latestResponse = response
        }
        return latestResponse
    }

    private func updateMachineVideoAgreementSummary(
        samples: [MachineVideoAgreementSample],
        status: String,
        noise: MachineVideoAgreementNoise,
        minimumSignalNorm: Double,
        bestModel: MachineVideoAgreementModel?,
        updateMagnitude: Double?
    ) {
        let xBasis = bestModel?.xBasisLengthNorm ?? averageCameraNormPerCommandMm(
            samples: samples.filter { abs($0.machineDxMm) > abs($0.machineDyMm) }
        )
        let yBasis = bestModel?.yBasisLengthNorm ?? averageCameraNormPerCommandMm(
            samples: samples.filter { abs($0.machineDyMm) > abs($0.machineDxMm) }
        )
        let detail: String
        if let bestModel {
            detail = String(
                format: "Agreement samples %d update %@ corner %.1fmm rms %.4f signal %.4f",
                samples.count,
                formatAgreementUpdate(updateMagnitude),
                bestModel.fieldCornerPrecisionMm,
                bestModel.rmsResidualNorm,
                minimumSignalNorm
            )
        } else {
            detail = String(
                format: "Agreement samples %d; jitter %.4f signal %.4f",
                samples.count,
                noise.rmsNorm,
                minimumSignalNorm
            )
        }
        frameLearning = FrameLearningState(
            status: status,
            detail: detail,
            sampleCount: samples.count,
            xPixelsPerMm: xBasis,
            yPixelsPerMm: yBasis,
            lastPins: bridge.machinePins
        )
    }

    private func formatAgreementUpdate(_ update: Double?) -> String {
        guard let update, update.isFinite else { return "--" }
        return String(format: "%.4f", update)
    }

    private func averageCameraNormPerCommandMm(samples: [MachineVideoAgreementSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { partial, sample in
            partial + sample.observedDistanceNorm / max(sample.commandDistanceMm, 0.000_001)
        }
        return total / Double(samples.count)
    }

    private func recordMachineVideoAgreementModel(
        _ model: MachineVideoAgreementModel,
        noise: MachineVideoAgreementNoise,
        minimumSignalNorm: Double,
        updateMagnitude: Double?
    ) {
        bridge.recordOperatorEvent(
            "machine_video_agreement_measured",
            details: [
                "sample_count": model.sampleCount,
                "x_basis_dx_norm": model.xBasisDxNorm,
                "x_basis_dy_norm": model.xBasisDyNorm,
                "y_basis_dx_norm": model.yBasisDxNorm,
                "y_basis_dy_norm": model.yBasisDyNorm,
                "determinant": model.determinant,
                "condition_number": model.conditionNumber,
                "rms_residual_norm": model.rmsResidualNorm,
                "max_residual_norm": model.maxResidualNorm,
                "observation_noise_norm": noise.rmsNorm,
                "minimum_signal_norm": minimumSignalNorm,
                "field_corner_precision_mm": model.fieldCornerPrecisionMm,
                "model_update_norm": updateMagnitude as Any,
                "model_update_converged": updateMagnitude.map { $0 <= machineVideoAgreementConvergedUpdateNorm } ?? false,
                "precision_converged": model.isPrecisionConverged
            ]
        )
    }

    @MainActor
    private func seedAndLockFieldFromMachineVideoAgreement(_ model: MachineVideoAgreementModel) async -> Bool {
        let fieldWidthMm = desiredVisualFieldWidthMm
        let fieldHeightMm = desiredVisualFieldHeightMm
        guard let cap = await waitForGreenCapCameraObservation(timeoutSeconds: 2.0),
              let corners = seededFieldCorners(
                  from: model,
                  center: cap.cameraPoint,
                  fieldWidthMm: fieldWidthMm,
                  fieldHeightMm: fieldHeightMm
              ) else {
            frameLearning.status = "BLOCK"
            frameLearning.detail = "Could not seed the selected field from machine-video agreement"
            calibrationStatusText = "FIELD seed blocked: machine-video basis did not fit in camera"
            return false
        }

        manualFiducials = corners
        manualFiducialMode = false
        calibrationStatusText = "BORDER seeded from machine-video agreement; locking \(desiredVisualFieldSizeLabel)"
        guard let response = await bridge.registerPaperHomography(
            fiducials: corners,
            paperWidthMm: fieldWidthMm,
            paperHeightMm: fieldHeightMm
        ), response.registration != nil else {
            frameLearning.status = "BLOCK"
            frameLearning.detail = bridge.statusText.isEmpty ? "Field registration failed" : bridge.statusText
            calibrationStatusText = "FIELD seed failed: \(frameLearning.detail)"
            return false
        }

        focusPlotterVideoOnPaper(source: "machine_video_agreement_field_seeded")
        calibrationStatusText = "BORDER \(desiredVisualFieldSizeLabel) locked from machine-video agreement"
        bridge.recordOperatorEvent(
            "field_seeded_from_machine_video_agreement",
            details: [
                "field_width_mm": fieldWidthMm,
                "field_height_mm": fieldHeightMm,
                "corner_count": corners.count,
                "paper_registration_id": bridge.paperRegistrationSnapshot?.registrationId ?? ""
            ]
        )
        return true
    }

    @MainActor
    private func updateLiveMachineVideoFieldFrame(
        from model: MachineVideoAgreementModel,
        center: CGPoint
    ) {
        guard workspace.setupWindowActive, !bridge.hasPaperLock else { return }
        guard let corners = seededFieldCorners(
            from: model,
            center: center,
            fieldWidthMm: desiredVisualFieldWidthMm,
            fieldHeightMm: desiredVisualFieldHeightMm
        ) else {
            return
        }
        manualFiducials = corners
    }

    private var desiredVisualFieldWidthMm: Double {
        min(400.0, max(40.0, workspace.visualFieldWidthMm))
    }

    private var desiredVisualFieldHeightMm: Double {
        min(desiredVisualFieldWidthMm, min(300.0, max(30.0, workspace.visualFieldHeightMm)))
    }

    private var desiredVisualFieldSizeLabel: String {
        String(format: "%.0fx%.0f", desiredVisualFieldWidthMm, desiredVisualFieldHeightMm)
    }

    @MainActor
    private func applyPersistedVisualReadiness(_ readiness: BridgeVisualReadinessState?) {
        guard let readiness,
              readiness.motionModelValid == true,
              readiness.paperRegistrationId == bridge.paperRegistrationSnapshot?.registrationId,
              let persistedModel = readiness.relativeMotionModel?.visualMotionModel else {
            return
        }
        guard frameLearning.status == "IDLE" || frameLearning.status == "AGREE" || frameLearning.status == "BLOCK" else {
            return
        }
        guard visualMotionModel != persistedModel else { return }

        visualMotionModel = persistedModel
        visualMotionSamples = []
        frameLearning = FrameLearningState(
            status: "VALIDATED",
            detail: "Loaded saved drawing-border motion model",
            sampleCount: persistedModel.sampleCount,
            xPixelsPerMm: hypot(persistedModel.xBasisDx, persistedModel.xBasisDy),
            yPixelsPerMm: hypot(persistedModel.yBasisDx, persistedModel.yBasisDy),
            lastPins: bridge.machinePins
        )
        calibrationStatusText = "BORDER loaded saved motion transform"
        bridge.recordOperatorEvent(
            "drawing_border_motion_model_loaded",
            details: [
                "registration_id": readiness.paperRegistrationId ?? "",
                "sample_count": persistedModel.sampleCount,
                "rms_residual_mm": persistedModel.rmsResidualMm,
                "max_residual_mm": persistedModel.maxResidualMm
            ]
        )
    }

    private var editableVisualFieldCorners: [ManualFiducialPoint] {
        let ordered = orderedManualFieldCorners(manualFiducials)
        if ordered.count == 4 { return ordered }
        if let registration = bridge.paperRegistrationSnapshot,
           let cameraCorners = visualFieldCameraCorners(from: registration) {
            return manualFieldPoints(cameraCorners: cameraCorners)
        }
        return []
    }

    private var canEditVisualFieldBox: Bool {
        workspace.setupWindowActive
            && editableVisualFieldCorners.count == 4
            && !manualPenMode
            && !manualCapColorMode
            && !bridge.isCalibrating
            && !bridge.isRunning
            && !bridge.isMachineBusy
    }

    private func blockInvalidVisualFieldCorners(source: String) {
        fieldRelockTask?.cancel()
        bridge.clearBindingMarkPreviewOverlay()
        frameLearning.status = "BLOCK"
        frameLearning.detail = "Adjusted drawing border is concave"
        calibrationStatusText = "BORDER edit blocked: corners must form a convex rectangle"
        bridge.recordOperatorEvent(
            "drawing_border_adjusted_blocked",
            details: ["source": source, "reason": "concave_corners"]
        )
    }

    @MainActor
    private func updateEditableVisualFieldCorners(_ corners: [ManualFiducialPoint], commit: Bool) {
        let ordered = orderedManualFieldCorners(corners)
        guard ordered.count == 4 else { return }
        manualFiducials = ordered
        if commit {
            guard visualFieldCornersAreConvex(ordered) else {
                blockInvalidVisualFieldCorners(source: "field_box_drag_released")
                return
            }
            scheduleEditableVisualFieldRelock(source: "field_box_drag_released", delayNanoseconds: 0)
        }
    }

    private func scheduleEditableVisualFieldRelock(
        source: String,
        delayNanoseconds: UInt64 = 220_000_000
    ) {
        guard workspace.setupWindowActive, editableVisualFieldCorners.count == 4 else { return }
        guard visualFieldCornersAreConvex(editableVisualFieldCorners) else {
            blockInvalidVisualFieldCorners(source: source)
            return
        }
        fieldRelockTask?.cancel()
        let corners = editableVisualFieldCorners
        let widthMm = desiredVisualFieldWidthMm
        let heightMm = desiredVisualFieldHeightMm
        fieldRelockTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await relockEditableVisualField(
                corners: corners,
                fieldWidthMm: widthMm,
                fieldHeightMm: heightMm,
                source: source
            )
        }
    }

    @MainActor
    private func relockEditableVisualField(
        corners: [ManualFiducialPoint],
        fieldWidthMm: Double,
        fieldHeightMm: Double,
        source: String
    ) async {
        let ordered = orderedManualFieldCorners(corners)
        guard ordered.count == 4 else { return }
        guard visualFieldCornersAreConvex(ordered) else {
            blockInvalidVisualFieldCorners(source: source)
            return
        }

        visualMotionModel = nil
        visualMotionSamples = []
        if frameLearning.status == "MEASURED" || frameLearning.status == "VALIDATED" {
            frameLearning = FrameLearningState(
                status: "AGREE",
                detail: "Drawing border edited; run motion calibration against the adjusted border",
                sampleCount: machineVideoAgreementSamples.count,
                xPixelsPerMm: machineVideoAgreementModel?.xBasisLengthNorm ?? frameLearning.xPixelsPerMm,
                yPixelsPerMm: machineVideoAgreementModel?.yBasisLengthNorm ?? frameLearning.yPixelsPerMm,
                lastPins: bridge.machinePins
            )
        }

        manualFiducials = ordered
        calibrationStatusText = "BORDER re-locking adjusted \(Int(fieldWidthMm))x\(Int(fieldHeightMm)) drawing border"
        guard let response = await bridge.registerPaperHomography(
            fiducials: ordered,
            paperWidthMm: fieldWidthMm,
            paperHeightMm: fieldHeightMm
        ), response.registration != nil else {
            frameLearning.status = "BLOCK"
            frameLearning.detail = bridge.statusText.isEmpty ? "Adjusted drawing border registration failed" : bridge.statusText
            calibrationStatusText = "BORDER edit blocked: \(frameLearning.detail)"
            return
        }

        if let confirmedCapPoint {
            self.confirmedCapPoint = ConfirmedCapPoint(
                point: confirmedCapPoint.point,
                cameraPoint: confirmedCapPoint.cameraPoint,
                paperMm: bridge.paperPointMm(cameraPoint: confirmedCapPoint.cameraPoint)
            )
        }

        calibrationStatusText = "BORDER adjusted \(Int(fieldWidthMm))x\(Int(fieldHeightMm)) drawing border locked"
        bridge.recordOperatorEvent(
            "drawing_border_adjusted",
            details: [
                "source": source,
                "field_width_mm": fieldWidthMm,
                "field_height_mm": fieldHeightMm,
                "corner_count": ordered.count,
                "paper_registration_id": bridge.paperRegistrationSnapshot?.registrationId ?? ""
            ]
        )
    }

    @MainActor
    private func runVisualAxisProbeMove(
        axis: String,
        distanceMm: Double,
        projectedPaperDelta: (dx: Double, dy: Double)? = nil,
        sampleIndex: Int
    ) async -> FrameLearningSample? {
        let commandDx = axis == "X" ? distanceMm : 0.0
        let commandDy = axis == "Y" ? distanceMm : 0.0
        let feedMmMin = min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin)
        var attempt = 0

        while attempt <= visualCapReacquireMaxAttempts {
            guard let before = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
                guard attempt < visualCapReacquireMaxAttempts,
                      let recovered = await reacquireGreenCapByXAxis(
                          afterFrame: plotterCamera.stats.frameNumber,
                          source: "probe_before_move",
                          label: "\(axis)-\(sampleIndex)",
                          preferredDirection: preferredXReacquireDirection(opposingCommandX: commandDx),
                          feedMmMin: min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin),
                          moveX: { commandMm, feedMmMin in
                              await bridge.learningJog(axis: "X", distanceMm: commandMm, feedMmMin: feedMmMin)
                          }
                      ) else {
                    updateLearningSummary(
                        samples: [],
                        status: "STOP",
                        detail: "Cap marker lost before move"
                    )
                    calibrationStatusText = "CAL cap-marker probe stopped: cap lost before move"
                    return nil
                }
                attempt += 1
                calibrationStatusText = String(
                    format: "CAL cap-marker probe reacquired cap x%.1f y%.1f; retry %@ %.0f",
                    recovered.paperMm.x,
                    recovered.paperMm.y,
                    axis,
                    distanceMm
                )
                continue
            }

            frameLearning.detail = String(format: "Move %@ %.0f mm", axis, distanceMm)
            calibrationStatusText = String(
                format: "CAL cap-marker probe: move %@ %.0f mm",
                axis,
                distanceMm
            )
            setVisualMoveIntent(
                start: before.paperMm,
                end: projectedPaperDelta.map {
                    PaperPointMmSnapshot(
                        x: before.paperMm.x + $0.dx,
                        y: before.paperMm.y + $0.dy
                    )
                },
                label: "PROBE \(axis)",
                detail: projectedPaperDelta == nil
                    ? String(format: "cmd X%+.0f Y%+.0f basis?", commandDx, commandDy)
                    : String(format: "cmd X%+.0f Y%+.0f", commandDx, commandDy)
            )

            guard let response = await bridge.learningJog(
                axis: axis,
                distanceMm: distanceMm,
                feedMmMin: feedMmMin
            ) else {
                clearVisualMoveIntent(reason: "probe_move_failed")
                let moveFailure = bridge.statusText.isEmpty
                    ? "Move failed or machine busy"
                    : bridge.statusText
                frameLearning.status = "STOP"
                frameLearning.detail = moveFailure
                calibrationStatusText = "CAL cap-marker probe stopped: \(moveFailure)"
                return nil
            }

            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                clearVisualMoveIntent(reason: "probe_pin_active")
                frameLearning.status = "STOP"
                frameLearning.detail = "Pin active after move"
                frameLearning.lastPins = pins
                calibrationStatusText = "CAL cap-marker probe stopped: pin active \(pins)"
                return nil
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let after = await waitForFreshGreenCapPaperObservation(
                afterFrame: before.frameNumber,
                timeoutSeconds: 4.0
            ) else {
                guard attempt < visualCapReacquireMaxAttempts,
                      let recovered = await reacquireGreenCapByXAxis(
                          afterFrame: before.frameNumber,
                          source: "probe_after_move",
                          label: "\(axis)-\(sampleIndex)",
                          preferredDirection: preferredXReacquireDirection(opposingCommandX: commandDx),
                          feedMmMin: min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin),
                          moveX: { commandMm, feedMmMin in
                              await bridge.learningJog(axis: "X", distanceMm: commandMm, feedMmMin: feedMmMin)
                          }
                      ) else {
                    clearVisualMoveIntent(reason: "probe_cap_lost_after_move")
                    updateLearningSummary(
                        samples: [],
                        status: "STOP",
                        detail: "Cap marker lost after move"
                    )
                    calibrationStatusText = "CAL cap-marker probe stopped: cap lost after move"
                    return nil
                }
                attempt += 1
                calibrationStatusText = String(
                    format: "CAL cap-marker probe reacquired cap x%.1f y%.1f; retry %@ %.0f",
                    recovered.paperMm.x,
                    recovered.paperMm.y,
                    axis,
                    distanceMm
                )
                continue
            }
            clearVisualMoveIntent(reason: "probe_observed")

            let dx = after.paperMm.x - before.paperMm.x
            let dy = after.paperMm.y - before.paperMm.y
            let observedDistance = hypot(dx, dy)
            let sample = FrameLearningSample(
                axis: axis,
                distanceMm: distanceMm,
                observedDxMm: dx,
                observedDyMm: dy,
                observedDistanceMm: observedDistance,
                strength: min(before.strength, after.strength)
            )
            guard await bridge.observeVisualProbeSample(
                visualProbeSampleRequest(
                    source: "motion_probe",
                    axis: axis,
                    commandedDxMm: commandDx,
                    commandedDyMm: commandDy,
                    before: before,
                    after: after,
                    commandId: response.commandId,
                    controllerTranscript: response.controllerTranscript,
                    status: "accepted",
                    sampleIdSuffix: "axis-\(sampleIndex)"
                )
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Bridge failed to persist probe evidence"
                calibrationStatusText = "CAL cap-marker probe stopped: evidence persistence failed"
                return nil
            }
            recordVisualMotionProbeSample(
                sample,
                sampleIndex: sampleIndex,
                before: before,
                after: after
            )
            calibrationStatusText = String(
                format: "CAL cap-marker probe: sample %d %@ %.0f observed %.1fmm",
                sampleIndex,
                axis,
                distanceMm,
                observedDistance
            )
            try? await Task.sleep(nanoseconds: 250_000_000)
            return sample
        }

        updateLearningSummary(
            samples: [],
            status: "STOP",
            detail: "Cap marker reacquire exhausted"
        )
        calibrationStatusText = "CAL cap-marker probe stopped: cap reacquire exhausted"
        return nil
    }

    @MainActor
    private func updateLearningSummary(
        samples: [FrameLearningSample],
        status: String,
        detail: String
    ) {
        let previousStatus = frameLearning.status
        let xSamples = samples.filter { $0.axis == "X" && abs($0.distanceMm) > 0 }
        let ySamples = samples.filter { $0.axis == "Y" && abs($0.distanceMm) > 0 }
        let xScale = averageObservedMmPerCommandMm(samples: xSamples)
        let yScale = averageObservedMmPerCommandMm(samples: ySamples)
        frameLearning = FrameLearningState(
            status: status,
            detail: detail,
            sampleCount: samples.count,
            xPixelsPerMm: xScale,
            yPixelsPerMm: yScale,
            lastPins: bridge.machinePins
        )
        if status != previousStatus || status != "LEARN" {
            bridge.recordOperatorEvent(
                "frame_learning_status",
                details: [
                    "status": status,
                    "detail": detail,
                    "sample_count": samples.count,
                    "x_observed_mm_per_command_mm": xScale,
                    "y_observed_mm_per_command_mm": yScale,
                    "last_pins": bridge.machinePins
                ]
            )
        }
    }

    private func averageObservedMmPerCommandMm(samples: [FrameLearningSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { partial, sample in
            partial + sample.observedDistanceMm / abs(sample.distanceMm)
        }
        return total / Double(samples.count)
    }

    private func recordVisualMotionProbeSample(
        _ sample: FrameLearningSample,
        sampleIndex: Int,
        before: GreenCapPaperObservation,
        after: GreenCapPaperObservation
    ) {
        bridge.recordOperatorEvent(
            "visual_motion_probe_sample",
            details: [
                "sample_index": sampleIndex,
                "axis": sample.axis,
                "command_mm": sample.distanceMm,
                "before_frame": before.frameNumber,
                "after_frame": after.frameNumber,
                "before_paper_x_mm": before.paperMm.x,
                "before_paper_y_mm": before.paperMm.y,
                "after_paper_x_mm": after.paperMm.x,
                "after_paper_y_mm": after.paperMm.y,
                "observed_dx_mm": sample.observedDxMm,
                "observed_dy_mm": sample.observedDyMm,
                "observed_distance_mm": sample.observedDistanceMm,
                "strength": sample.strength
            ]
        )
    }

    private func visualProbeSampleRequest(
        source: String,
        axis: String?,
        commandedDxMm: Double,
        commandedDyMm: Double,
        before: GreenCapPaperObservation,
        after: GreenCapPaperObservation,
        requestId: String? = nil,
        planId: String? = nil,
        commandId: String? = nil,
        predictedDxMm: Double? = nil,
        predictedDyMm: Double? = nil,
        residualMm: Double? = nil,
        residualLimitMm: Double? = nil,
        controllerTranscript: String? = nil,
        status: String,
        blockers: [String] = [],
        rejectionReason: String? = nil,
        sampleIdSuffix: String
    ) -> BridgeVisualProbeSampleRequest {
        let runId = bridge.visualProbeEvidenceRunId
        return BridgeVisualProbeSampleRequest(
            runId: runId,
            sampleId: "\(runId)-\(sampleIdSuffix)-\(before.frameNumber)-\(after.frameNumber)",
            requestId: requestId,
            planId: planId,
            commandId: commandId,
            cameraId: "plotter-camera",
            cameraName: "Plotter Camera",
            source: source,
            axis: axis,
            commandedDxMm: commandedDxMm,
            commandedDyMm: commandedDyMm,
            before: visualProbeCapSnapshot(before),
            after: visualProbeCapSnapshot(after),
            predictedDxMm: predictedDxMm,
            predictedDyMm: predictedDyMm,
            residualMm: residualMm,
            residualLimitMm: residualLimitMm,
            status: status,
            blockers: blockers,
            rejectionReason: rejectionReason,
            controllerTranscript: controllerTranscript
        )
    }

    private func visualProbeCapSnapshot(
        _ observation: GreenCapPaperObservation
    ) -> BridgeVisualProbeCapSnapshotRequest {
        BridgeVisualProbeCapSnapshotRequest(
            cameraNorm: NormPoint(observation.cameraPoint),
            paperNorm: NormPoint(
                CGPoint(
                    x: min(1.0, max(0.0, observation.paperMm.x / max(bridge.visualFieldWidthMm, 0.000_001))),
                    y: min(1.0, max(0.0, observation.paperMm.y / max(bridge.visualFieldHeightMm, 0.000_001)))
                )
            ),
            logicalMm: observation.paperMm,
            frameId: observation.frameNumber,
            confidence: observation.strength
        )
    }

    private func visualMotionSample(from sample: FrameLearningSample) -> VisualMotionSample {
        VisualMotionSample(
            machineDxMm: sample.axis == "X" ? sample.distanceMm : 0.0,
            machineDyMm: sample.axis == "Y" ? sample.distanceMm : 0.0,
            observedDxMm: sample.observedDxMm,
            observedDyMm: sample.observedDyMm,
            observedDistanceMm: sample.observedDistanceMm,
            strength: sample.strength
        )
    }

    @MainActor
    private func appendAcceptedVisualMotionSample(
        machineDxMm: Double,
        machineDyMm: Double,
        observedDxMm: Double,
        observedDyMm: Double,
        observedDistanceMm: Double,
        strength: Double
    ) -> VisualMotionModel? {
        guard observedDistanceMm >= visualProbeMinimumObservedMm * 0.35 else {
            return visualMotionModel
        }

        let sample = VisualMotionSample(
            machineDxMm: machineDxMm,
            machineDyMm: machineDyMm,
            observedDxMm: observedDxMm,
            observedDyMm: observedDyMm,
            observedDistanceMm: observedDistanceMm,
            strength: strength
        )
        var updatedSamples = visualMotionSamples
        updatedSamples.append(sample)
        if updatedSamples.count > 80 {
            updatedSamples.removeFirst(updatedSamples.count - 80)
        }

        let usableSamples = updatedSamples.filter {
            $0.observedDistanceMm >= visualProbeMinimumObservedMm * 0.35
        }
        guard let updatedModel = VisualMotionModel.solve(samples: usableSamples) else {
            return visualMotionModel
        }
        if let currentModel = visualMotionModel {
            let maxAllowedRMS = max(8.0, currentModel.rmsResidualMm * 1.8)
            let maxAllowedResidual = max(16.0, currentModel.maxResidualMm * 2.0)
            guard updatedModel.rmsResidualMm <= maxAllowedRMS,
                  updatedModel.maxResidualMm <= maxAllowedResidual else {
                return currentModel
            }
        }

        visualMotionSamples = updatedSamples
        visualMotionModel = updatedModel
        frameLearning = FrameLearningState(
            status: "MEASURED",
            detail: String(
                format: "Motion updated rms %.1f max %.1f samples %d",
                updatedModel.rmsResidualMm,
                updatedModel.maxResidualMm,
                updatedModel.sampleCount
            ),
            sampleCount: updatedModel.sampleCount,
            xPixelsPerMm: hypot(updatedModel.xBasisDx, updatedModel.xBasisDy),
            yPixelsPerMm: hypot(updatedModel.yBasisDx, updatedModel.yBasisDy),
            lastPins: bridge.machinePins
        )
        return updatedModel
    }

    @MainActor
    func waitForGreenCapPaperObservation(
        afterFrame: Int? = nil,
        minimumFrameAdvance: Int = 1,
        timeoutSeconds: Double
    ) async -> GreenCapPaperObservation? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latest: GreenCapPaperObservation?
        while Date() < deadline {
            if let observation = currentGreenCapPaperObservation() {
                latest = observation
                if afterFrame == nil || observation.frameNumber >= afterFrame! + minimumFrameAdvance {
                    return observation
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return latest
    }

    @MainActor
    private func waitForGreenCapCameraObservation(
        afterFrame: Int? = nil,
        minimumFrameAdvance: Int = 1,
        timeoutSeconds: Double
    ) async -> GreenCapCameraObservation? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latest: GreenCapCameraObservation?
        while Date() < deadline {
            if let observation = currentGreenCapCameraObservation() {
                latest = observation
                if afterFrame == nil || observation.frameNumber >= afterFrame! + minimumFrameAdvance {
                    return observation
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return latest
    }

    @MainActor
    private func waitForFreshGreenCapPaperObservation(
        afterFrame: Int,
        timeoutSeconds: Double
    ) async -> GreenCapPaperObservation? {
        guard let observation = await waitForGreenCapPaperObservation(
            afterFrame: afterFrame,
            minimumFrameAdvance: visualCapFreshFrameAdvance,
            timeoutSeconds: timeoutSeconds
        ), observation.frameNumber >= afterFrame + visualCapFreshFrameAdvance else {
            return nil
        }
        return observation
    }

    @MainActor
    private func waitForFreshGreenCapCameraObservation(
        afterFrame: Int,
        timeoutSeconds: Double
    ) async -> GreenCapCameraObservation? {
        guard let observation = await waitForGreenCapCameraObservation(
            afterFrame: afterFrame,
            minimumFrameAdvance: visualCapFreshFrameAdvance,
            timeoutSeconds: timeoutSeconds
        ), observation.frameNumber >= afterFrame + visualCapFreshFrameAdvance else {
            return nil
        }
        return observation
    }

    private func preferredXReacquireDirection(opposingCommandX commandX: Double) -> Double {
        if commandX > 0.2 { return -1.0 }
        if commandX < -0.2 { return 1.0 }
        return 1.0
    }

    private func visualCapReacquireCommands(firstDirection: Double) -> [Double] {
        let direction = firstDirection < 0 ? -1.0 : 1.0
        let step = visualCapReacquireStepXMm
        let returnStep = min(visualCapReacquireMaxTotalXMm, step * 2.0)
        return [
            direction * step,
            direction * step,
            -direction * returnStep,
            -direction * returnStep
        ]
    }

    @MainActor
    private func reacquireGreenCapByXAxis(
        afterFrame: Int,
        source: String,
        label: String,
        preferredDirection: Double,
        feedMmMin: Double,
        moveX: (Double, Double) async -> MachineCommandResponse?
    ) async -> GreenCapPaperObservation? {
        let commands = visualCapReacquireCommands(firstDirection: preferredDirection)
        var moveIndex = 0
        var totalCommandedMm = 0.0
        bridge.visualCenterDotStatus = "VIS SEEK X"
        calibrationStatusText = "CAL cap reacquire \(label): scanning X"
        bridge.recordOperatorEvent(
            "visual_cap_reacquire_started",
            details: [
                "source": source,
                "label": label,
                "after_frame": afterFrame,
                "step_x_mm": visualCapReacquireStepXMm,
                "max_total_x_mm": visualCapReacquireMaxTotalXMm,
                "preferred_direction": preferredDirection < 0 ? -1 : 1,
                "feed_mm_min": feedMmMin
            ]
        )

        for commandMm in commands {
            let remainingBudget = visualCapReacquireMaxTotalXMm - totalCommandedMm
            guard remainingBudget > 0 else { break }
            let boundedCommandMm = commandMm.sign == .minus
                ? -min(abs(commandMm), remainingBudget)
                : min(abs(commandMm), remainingBudget)
            guard abs(boundedCommandMm) >= 0.5 else { break }

            moveIndex += 1
            bridge.visualCenterDotStatus = String(format: "VIS SEEK X%+.0f", boundedCommandMm)
            calibrationStatusText = String(
                format: "CAL cap reacquire %@: X%+.0f chunk %d",
                label,
                boundedCommandMm,
                moveIndex
            )
            guard let response = await moveX(boundedCommandMm, feedMmMin) else {
                bridge.recordOperatorEvent(
                    "visual_cap_reacquire_failed",
                    details: [
                        "source": source,
                        "label": label,
                        "reason": "move_failed",
                        "move_index": moveIndex,
                        "command_x_mm": boundedCommandMm,
                        "total_commanded_x_mm": totalCommandedMm
                    ]
                )
                bridge.visualCenterDotStatus = "VIS SEEK FAIL"
                calibrationStatusText = "CAL cap reacquire stopped: X move failed"
                return nil
            }

            totalCommandedMm += abs(boundedCommandMm)
            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                bridge.recordOperatorEvent(
                    "visual_cap_reacquire_failed",
                    details: [
                        "source": source,
                        "label": label,
                        "reason": "pin_active",
                        "pins": pins,
                        "move_index": moveIndex,
                        "command_x_mm": boundedCommandMm,
                        "total_commanded_x_mm": totalCommandedMm
                    ]
                )
                bridge.visualCenterDotStatus = "VIS PIN \(pins)"
                calibrationStatusText = "CAL cap reacquire stopped: pin active \(pins)"
                return nil
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            if let observation = await waitForFreshGreenCapPaperObservation(
                afterFrame: afterFrame,
                timeoutSeconds: 2.5
            ) {
                bridge.recordOperatorEvent(
                    "visual_cap_reacquired",
                    details: [
                        "source": source,
                        "label": label,
                        "move_count": moveIndex,
                        "last_command_x_mm": boundedCommandMm,
                        "total_commanded_x_mm": totalCommandedMm,
                        "frame": observation.frameNumber,
                        "paper_x_mm": observation.paperMm.x,
                        "paper_y_mm": observation.paperMm.y,
                        "strength": observation.strength
                    ]
                )
                bridge.visualCenterDotStatus = String(
                    format: "VIS FOUND X%.1f Y%.1f",
                    observation.paperMm.x,
                    observation.paperMm.y
                )
                return observation
            }
        }

        bridge.recordOperatorEvent(
            "visual_cap_reacquire_failed",
            details: [
                "source": source,
                "label": label,
                "reason": "no_cap",
                "move_count": moveIndex,
                "total_commanded_x_mm": totalCommandedMm
            ]
        )
        bridge.visualCenterDotStatus = "VIS NO NEW FRAME"
        calibrationStatusText = "CAL cap reacquire stopped: no fresh cap observation"
        return nil
    }

    @MainActor
    private func currentGreenCapPaperObservation() -> GreenCapPaperObservation? {
        guard let cameraObservation = currentGreenCapCameraObservation() else { return nil }
        let cameraPoint = cameraObservation.cameraPoint
        guard let paperMm = bridge.paperPointMm(cameraPoint: cameraPoint) else { return nil }
        return GreenCapPaperObservation(
            frameNumber: cameraObservation.frameNumber,
            cameraPoint: cameraPoint,
            paperMm: paperMm,
            strength: cameraObservation.strength
        )
    }

    @MainActor
    private func currentGreenCapCameraObservation() -> GreenCapCameraObservation? {
        guard let marker = currentCarriageMarker else { return nil }
        let cameraPoint = CGPoint(
            x: clampDouble(Double(marker.center.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(marker.center.y), min: 0.0, max: 1.0)
        )
        return GreenCapCameraObservation(
            frameNumber: marker.id,
            cameraPoint: cameraPoint,
            strength: marker.strength
        )
    }

    private var currentCarriageMarker: CarriageMarker? {
        plotterCamera.stabilizedCarriageMarker ?? plotterCamera.carriageMarker
    }

    private func isGreenCapInsideSafeZone(_ paperMm: PaperPointMmSnapshot) -> Bool {
        paperMm.x >= visualCapSafeZoneMarginMm
            && paperMm.y >= visualCapSafeZoneMarginMm
            && paperMm.x <= bridge.visualFieldWidthMm - visualCapSafeZoneMarginMm
            && paperMm.y <= bridge.visualFieldHeightMm - visualCapSafeZoneMarginMm
    }

    private func evaluateVisualAxisProbe(samples: [FrameLearningSample]) -> VisualAxisProbeEvaluation {
        guard samples.count >= 4 else {
            return VisualAxisProbeEvaluation(
                passed: false,
                detail: "Need four cap-marker jog samples",
                rmsResidualMm: .infinity,
                maxResidualMm: .infinity,
                minObservedDistanceMm: 0,
                xScale: 0,
                yScale: 0
            )
        }
        let weakSamples = samples.filter {
            $0.observedDistanceMm < visualProbeMinimumObservedMm
        }
        let usableSamples = samples.filter {
            $0.observedDistanceMm >= visualProbeMinimumObservedMm
        }
        let xSamples = usableSamples.filter { $0.axis == "X" }
        let ySamples = usableSamples.filter { $0.axis == "Y" }
        guard xSamples.count >= 2, ySamples.count >= 2 else {
            return VisualAxisProbeEvaluation(
                passed: false,
                detail: "Need 2 usable X/Y samples; weak \(weakProbeSampleSummary(samples: weakSamples))",
                rmsResidualMm: .infinity,
                maxResidualMm: .infinity,
                minObservedDistanceMm: samples.map(\.observedDistanceMm).min() ?? 0,
                xScale: 0,
                yScale: 0
            )
        }

        let xBasis = averageBasis(samples: xSamples)
        let yBasis = averageBasis(samples: ySamples)
        let xScale = hypot(xBasis.dx, xBasis.dy)
        let yScale = hypot(yBasis.dx, yBasis.dy)
        let minObserved = usableSamples.map(\.observedDistanceMm).min() ?? 0
        let residuals = usableSamples.map { sample in
            let basis = sample.axis == "X" ? xBasis : yBasis
            let predictedDx = basis.dx * sample.distanceMm
            let predictedDy = basis.dy * sample.distanceMm
            return hypot(sample.observedDxMm - predictedDx, sample.observedDyMm - predictedDy)
        }
        let maxResidual = residuals.max() ?? .infinity
        let rmsResidual = sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / Double(max(residuals.count, 1)))
        let dot = xBasis.dx * yBasis.dx + xBasis.dy * yBasis.dy
        let axisCosine = abs(dot / max(xScale * yScale, 0.000_001))

        if rmsResidual > 6.0 || maxResidual > 10.0 {
            return VisualAxisProbeEvaluation(
                passed: false,
                detail: String(format: "Residual too high rms %.1f max %.1f", rmsResidual, maxResidual),
                rmsResidualMm: rmsResidual,
                maxResidualMm: maxResidual,
                minObservedDistanceMm: minObserved,
                xScale: xScale,
                yScale: yScale
            )
        }
        if axisCosine > 0.72 {
            return VisualAxisProbeEvaluation(
                passed: false,
                detail: String(format: "Axes too collinear cos %.2f", axisCosine),
                rmsResidualMm: rmsResidual,
                maxResidualMm: maxResidual,
                minObservedDistanceMm: minObserved,
                xScale: xScale,
                yScale: yScale
            )
        }

        let detail = weakSamples.isEmpty
            ? String(format: "Cap-marker basis rms %.1f max %.1f", rmsResidual, maxResidual)
            : String(
                format: "Cap-marker basis rms %.1f max %.1f; weak %@",
                rmsResidual,
                maxResidual,
                weakProbeSampleSummary(samples: weakSamples)
            )
        return VisualAxisProbeEvaluation(
            passed: true,
            detail: detail,
            rmsResidualMm: rmsResidual,
            maxResidualMm: maxResidual,
            minObservedDistanceMm: minObserved,
            xScale: xScale,
            yScale: yScale
        )
    }

    private func applyResiduals(
        to samples: [FrameLearningSample]
    ) -> [FrameLearningSample] {
        let xBasis = averageBasis(samples: samples.filter { $0.axis == "X" })
        let yBasis = averageBasis(samples: samples.filter { $0.axis == "Y" })
        return samples.map { sample in
            let basis = sample.axis == "X" ? xBasis : yBasis
            let predictedDx = basis.dx * sample.distanceMm
            let predictedDy = basis.dy * sample.distanceMm
            var copy = sample
            copy.residualMm = hypot(sample.observedDxMm - predictedDx, sample.observedDyMm - predictedDy)
            return copy
        }
    }

    private func visualProbeProjectedPaperDelta(
        axis: String,
        distanceMm: Double,
        samples: [FrameLearningSample]
    ) -> (dx: Double, dy: Double)? {
        let axisSamples = samples.filter {
            $0.axis == axis
                && abs($0.distanceMm) > 0.000_001
                && $0.observedDistanceMm >= visualProbeMinimumObservedMm
        }
        guard !axisSamples.isEmpty else { return nil }
        let basis = averageBasis(samples: axisSamples)
        let dx = basis.dx * distanceMm
        let dy = basis.dy * distanceMm
        guard dx.isFinite, dy.isFinite, hypot(dx, dy) >= 0.5 else { return nil }
        return (dx, dy)
    }

    private func averageBasis(samples: [FrameLearningSample]) -> (dx: Double, dy: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        let total = samples.reduce((dx: 0.0, dy: 0.0)) { partial, sample in
            (
                dx: partial.dx + sample.observedDxMm / sample.distanceMm,
                dy: partial.dy + sample.observedDyMm / sample.distanceMm
            )
        }
        return (
            dx: total.dx / Double(samples.count),
            dy: total.dy / Double(samples.count)
        )
    }

    private func weakProbeSampleSummary(samples: [FrameLearningSample]) -> String {
        let sorted = samples.sorted { $0.observedDistanceMm < $1.observedDistanceMm }
        guard !sorted.isEmpty else { return "none" }
        return sorted.prefix(3).map { sample in
            String(
                format: "%@ %.0f %.1fmm",
                sample.axis,
                sample.distanceMm,
                sample.observedDistanceMm
            )
        }
        .joined(separator: ", ")
    }

    private var currentGreenCapFieldMappedReady: Bool {
        guard bridge.hasPaperLock else { return currentGreenCapCameraObservation() != nil }
        return currentGreenCapPaperObservation() != nil
    }

    private var confirmedCapFieldMappedReady: Bool {
        guard bridge.hasPaperLock else { return confirmedCapPoint != nil }
        return confirmedCapPoint?.paperMm != nil
    }

    private var greenCapFieldMappingDetail: String {
        guard bridge.hasPaperLock else { return "Machine-video agreement must run before field bounds exist" }
        guard let observation = currentGreenCapPaperObservation() else { return "Cap marker not detected" }
        return String(format: "Cap mapped to field x%.1f y%.1f mm", observation.paperMm.x, observation.paperMm.y)
    }

    private var greenCapProbeReadinessDetail: String {
        guard bridge.hasPaperLock else {
            return currentGreenCapCameraObservation() == nil
                ? "Cap marker not detected"
                : "Cap marker ready for machine-video agreement"
        }
        guard let observation = currentGreenCapPaperObservation() else { return "Cap marker not detected" }
        return String(format: "Cap mapped to field x%.1f y%.1f mm", observation.paperMm.x, observation.paperMm.y)
    }

    private var confirmedCapFieldMappingDetail: String {
        guard bridge.hasPaperLock else { return "Confirmed cap ready for machine-video agreement" }
        guard let paperMm = confirmedCapPoint?.paperMm else { return "Cap marker not confirmed" }
        return String(format: "Confirmed cap mapped x%.1f y%.1f mm", paperMm.x, paperMm.y)
    }

    private var visualMotionValidated: Bool {
        frameLearning.status == "VALIDATED" && visualMotionModel?.isUsable == true
    }

    private var wizardDrawFrameVisible: Bool {
        visualMotionValidated
    }

    private var wizardDrawFrameEnabled: Bool {
        wizardDrawFrameVisible && wizardDrawFrameDisabledReason == nil
    }

    private var wizardDrawFrameDisabledReason: String? {
        guard visualMotionValidated else { return "motion validation required" }
        guard bridge.hasPaperLock else { return "visual field missing" }
        guard visualMotionModel?.isUsable == true else { return "motion model not usable" }
        guard currentGreenCapFieldMappedReady else { return greenCapFieldMappingDetail }
        guard validatedFieldFrameCorners != nil else { return "Drawing Border is too small" }
        if !bridge.canRunSetupRelativeMotionCommand { return bridge.motionGateMessage }
        if bridge.isMachineAlarm { return "machine alarm" }
        if bridge.isMachineBusy || bridge.isRunning { return "machine busy" }
        return nil
    }

    private var validatedFieldFrameCorners: [PaperPointMmSnapshot]? {
        let width = bridge.visualFieldWidthMm
        let height = bridge.visualFieldHeightMm
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let inset = min(visualFieldFrameInsetMm, max(0.0, min(width, height) / 4.0))
        let minX = inset
        let minY = inset
        let maxX = width - inset
        let maxY = height - inset
        guard maxX - minX > 1.0, maxY - minY > 1.0 else { return nil }
        return [
            PaperPointMmSnapshot(x: minX, y: minY),
            PaperPointMmSnapshot(x: maxX, y: minY),
            PaperPointMmSnapshot(x: maxX, y: maxY),
            PaperPointMmSnapshot(x: minX, y: maxY),
        ]
    }

    private var canValidateWizardMotion: Bool {
        bridge.hasPaperLock
            && confirmedCapPoint?.paperMm != nil
            && currentGreenCapFieldMappedReady
            && frameLearning.status == "MEASURED"
            && visualMotionModel?.isUsable == true
            && !bridge.isMachineBusy
            && !bridge.isRunning
            && !bridge.isMachineAlarm
    }

    private var canRunWizardMotionProbe: Bool {
        bridge.canRunSetupRelativeMotionCommand
            && confirmedCapPoint != nil
            && currentCarriageMarker != nil
            && !bridge.isMachineBusy
            && !bridge.isRunning
            && !bridge.isMachineAlarm
    }

    @MainActor
    func approachVisualTarget(
        _ target: PaperPointMmSnapshot,
        label: String,
        targetIndex: Int
    ) async -> GreenCapPaperObservation? {
        guard var model = visualMotionModel, model.isUsable else {
            bridge.visualCenterDotStatus = "VIS NO BASIS"
            calibrationStatusText = "CAL visual target blocked: no usable motion basis"
            return nil
        }
        guard var current = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            calibrationStatusText = "CAL visual target blocked: cap not detected"
            bridge.visualCenterDotStatus = "VIS NO CAP"
            return nil
        }
        let targetToleranceMm = 4.0
        let maxSegments = 30
        let maxResidualRetries = 6
        let minimumCommandCapMm = 3.0
        let maximumCommandCapMm = 30.0
        let feedMmMin = min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin)
        var goodSegments = 0
        var residualRetries = 0
        var noNewFrameReacquires = 0
        var adaptiveCommandCapMm = maximumCommandCapMm
        let initialDistance = paperDistance(from: current.paperMm, to: target)

        for segmentIndex in 1...maxSegments {
            let remainingDx = target.x - current.paperMm.x
            let remainingDy = target.y - current.paperMm.y
            let remainingDistance = hypot(remainingDx, remainingDy)
            if remainingDistance <= targetToleranceMm {
                bridge.visualCenterDotStatus = String(format: "VIS %@ %.1fmm", label, remainingDistance)
                break
            }

            guard let machineDelta = model.machineDelta(forPaperDx: remainingDx, paperDy: remainingDy) else {
                bridge.visualCenterDotStatus = "VIS SOLVE FAIL"
                calibrationStatusText = "CAL visual target blocked: basis solve failed"
                return nil
            }

            let commandLength = hypot(machineDelta.xMm, machineDelta.yMm)
            guard commandLength >= 0.2 else {
                bridge.visualCenterDotStatus = "VIS TINY MOVE"
                calibrationStatusText = "CAL visual target stopped: command too small"
                return nil
            }

            let rampCommandCapMm = goodSegments >= 2 ? 30.0 : (goodSegments == 1 ? 18.0 : 10.0)
            let commandCapMm = min(rampCommandCapMm, adaptiveCommandCapMm)
            let scale = min(1.0, commandCapMm / commandLength)
            let commandX = machineDelta.xMm * scale
            let commandY = machineDelta.yMm * scale
            let predicted = model.paperDelta(forMachineX: commandX, yMm: commandY)
            let predictedDistance = hypot(predicted.dx, predicted.dy)
            guard predictedDistance >= 0.5 else {
                bridge.visualCenterDotStatus = "VIS WEAK PRED"
                calibrationStatusText = "CAL visual target stopped: weak predicted movement"
                return nil
            }

            guard let before = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
                bridge.visualCenterDotStatus = "VIS CAP LOST"
                calibrationStatusText = "CAL visual target stopped: cap lost before move"
                return nil
            }

            bridge.visualCenterDotStatus = String(
                format: "VIS %@ %02d %.1f",
                label,
                segmentIndex,
                remainingDistance
            )
            calibrationStatusText = String(
                format: "CAL visual %@ target %d move %02d rem %.1f cmd X%.1f Y%.1f",
                label,
                targetIndex,
                segmentIndex,
                remainingDistance,
                commandX,
                commandY
            )
            setVisualMoveIntent(
                start: before.paperMm,
                end: PaperPointMmSnapshot(
                    x: before.paperMm.x + predicted.dx,
                    y: before.paperMm.y + predicted.dy
                ),
                label: "MOVE \(label)",
                detail: String(format: "cmd X%+.1f Y%+.1f", commandX, commandY)
            )

            guard let response = await runSetupVectorJog(
                xMm: commandX,
                yMm: commandY,
                feedMmMin: feedMmMin
            ) else {
                clearVisualMoveIntent(reason: "visual_target_move_failed")
                calibrationStatusText = "CAL visual target stopped: move failed"
                return nil
            }
            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                clearVisualMoveIntent(reason: "visual_target_pin_active")
                bridge.visualCenterDotStatus = "VIS PIN \(pins)"
                calibrationStatusText = "CAL visual target stopped: pin active \(pins)"
                return nil
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let after = await waitForGreenCapPaperObservation(
                afterFrame: before.frameNumber,
                timeoutSeconds: 4.0
            ), after.frameNumber > before.frameNumber else {
                guard noNewFrameReacquires < visualCapReacquireMaxAttempts,
                      let recovered = await reacquireGreenCapByXAxis(
                          afterFrame: before.frameNumber,
                          source: "visual_target_no_new_frame",
                          label: label,
                          preferredDirection: preferredXReacquireDirection(opposingCommandX: commandX),
                          feedMmMin: min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin),
                          moveX: { commandMm, feedMmMin in
                              await bridge.learningJog(axis: "X", distanceMm: commandMm, feedMmMin: feedMmMin)
                          }
                      ) else {
                    clearVisualMoveIntent(reason: "visual_target_no_new_frame")
                    bridge.visualCenterDotStatus = "VIS NO NEW FRAME"
                    calibrationStatusText = "CAL visual target stopped: no new cap observation"
                    return nil
                }
                noNewFrameReacquires += 1
                adaptiveCommandCapMm = max(minimumCommandCapMm, commandCapMm * 0.5)
                current = recovered
                calibrationStatusText = String(
                    format: "CAL visual %@ reacquired cap; retrying target move from x%.1f y%.1f",
                    label,
                    recovered.paperMm.x,
                    recovered.paperMm.y
                )
                continue
            }
            clearVisualMoveIntent(reason: "visual_target_observed")

            let observedDx = after.paperMm.x - before.paperMm.x
            let observedDy = after.paperMm.y - before.paperMm.y
            let observedDistance = hypot(observedDx, observedDy)
            let residualMm = hypot(observedDx - predicted.dx, observedDy - predicted.dy)
            let residualLimitMm = max(10.0, predictedDistance * 0.80)
            let observedTooSmall = observedDistance < predictedDistance * 0.20
            let residualRejected = residualMm > residualLimitMm
            if observedTooSmall || residualRejected {
                residualRetries += 1
                let failureReason = observedTooSmall ? "short_observed_move" : "residual"
                let nextCommandCapMm = max(minimumCommandCapMm, commandCapMm * 0.5)
                var details = visualTargetResidualDetails(
                    label: label,
                    targetIndex: targetIndex,
                    segmentIndex: segmentIndex,
                    target: target,
                    commandX: commandX,
                    commandY: commandY,
                    before: before,
                    after: after,
                    predicted: predicted,
                    predictedDistance: predictedDistance,
                    observedDx: observedDx,
                    observedDy: observedDy,
                    observedDistance: observedDistance,
                    residualMm: residualMm,
                    residualLimitMm: residualLimitMm
                )
                details["failure_reason"] = failureReason
                details["retry_count"] = residualRetries
                details["max_retries"] = maxResidualRetries
                details["next_command_cap_mm"] = nextCommandCapMm
                guard await bridge.observeVisualProbeSample(
                    visualProbeSampleRequest(
                        source: "center_target_residual",
                        axis: nil,
                        commandedDxMm: commandX,
                        commandedDyMm: commandY,
                        before: before,
                        after: after,
                        commandId: response.commandId,
                        predictedDxMm: predicted.dx,
                        predictedDyMm: predicted.dy,
                        residualMm: residualMm,
                        residualLimitMm: residualLimitMm,
                        controllerTranscript: response.controllerTranscript,
                        status: "rejected",
                        blockers: [failureReason],
                        rejectionReason: failureReason,
                        sampleIdSuffix: "target-\(targetIndex)-segment-\(segmentIndex)-rejected-\(residualRetries)"
                    )
                ) else {
                    bridge.visualCenterDotStatus = "VIS EVID ERR"
                    calibrationStatusText = "CAL visual target stopped: evidence persistence failed"
                    return nil
                }

                guard residualRetries <= maxResidualRetries else {
                    bridge.visualCenterDotStatus = String(format: "VIS RESID %.1f", residualMm)
                    bridge.recordOperatorEvent("visual_target_residual_rejected", details: details)
                    calibrationStatusText = String(
                        format: "CAL visual target stopped: residual %.1fmm predicted %.1f observed %.1f after %d retries",
                        residualMm,
                        predictedDistance,
                        observedDistance,
                        maxResidualRetries
                    )
                    return nil
                }

                bridge.visualCenterDotStatus = String(
                    format: "VIS RETRY %d %.1f",
                    residualRetries,
                    residualMm
                )
                bridge.recordOperatorEvent(
                    "visual_target_residual_retry",
                    details: details
                )
                calibrationStatusText = String(
                    format: "CAL visual %@ retry %d: residual %.1fmm predicted %.1f observed %.1f; backing out to verified point",
                    label,
                    residualRetries,
                    residualMm,
                    predictedDistance,
                    observedDistance
                )
                guard let rollback = await rollbackRejectedVisualMove(
                    commandX: commandX,
                    commandY: commandY,
                    before: before,
                    after: after,
                    label: label,
                    targetIndex: targetIndex,
                    segmentIndex: segmentIndex,
                    residualMm: residualMm,
                    residualLimitMm: residualLimitMm,
                    feedMmMin: feedMmMin
                ) else {
                    adaptiveCommandCapMm = nextCommandCapMm
                    return nil
                }
                adaptiveCommandCapMm = nextCommandCapMm
                current = rollback
                continue
            }

            guard await bridge.observeVisualProbeSample(
                visualProbeSampleRequest(
                    source: "center_target_segment",
                    axis: nil,
                    commandedDxMm: commandX,
                    commandedDyMm: commandY,
                    before: before,
                    after: after,
                    commandId: response.commandId,
                    predictedDxMm: predicted.dx,
                    predictedDyMm: predicted.dy,
                    residualMm: residualMm,
                    residualLimitMm: residualLimitMm,
                    controllerTranscript: response.controllerTranscript,
                    status: "accepted",
                    sampleIdSuffix: "target-\(targetIndex)-segment-\(segmentIndex)-accepted"
                )
            ) else {
                bridge.visualCenterDotStatus = "VIS EVID ERR"
                calibrationStatusText = "CAL visual target stopped: evidence persistence failed"
                return nil
            }
            if let updatedModel = appendAcceptedVisualMotionSample(
                machineDxMm: commandX,
                machineDyMm: commandY,
                observedDxMm: observedDx,
                observedDyMm: observedDy,
                observedDistanceMm: observedDistance,
                strength: min(before.strength, after.strength)
            ) {
                model = updatedModel
            }
            goodSegments += 1
            noNewFrameReacquires = 0
            if commandCapMm < maximumCommandCapMm && residualMm <= residualLimitMm * 0.5 {
                adaptiveCommandCapMm = min(maximumCommandCapMm, adaptiveCommandCapMm * 1.5)
            }
            current = after
        }

        guard let final = await waitForGreenCapPaperObservation(timeoutSeconds: 2.0) else {
            bridge.visualCenterDotStatus = "VIS NO FINAL"
            calibrationStatusText = "CAL visual target stopped: no final cap observation"
            return nil
        }
        let finalDistance = paperDistance(from: final.paperMm, to: target)
        guard finalDistance <= targetToleranceMm else {
            bridge.visualCenterDotStatus = String(format: "VIS OFF %.1fmm", finalDistance)
            calibrationStatusText = String(format: "CAL visual target stopped %.1fmm from target", finalDistance)
            return nil
        }
        guard goodSegments > 0 || initialDistance <= targetToleranceMm else {
            bridge.visualCenterDotStatus = "VIS NO VERIFY"
            calibrationStatusText = "CAL visual target stopped: no verified segment"
            return nil
        }
        return final
    }

    private func visualTargetResidualDetails(
        label: String,
        targetIndex: Int,
        segmentIndex: Int,
        target: PaperPointMmSnapshot,
        commandX: Double,
        commandY: Double,
        before: GreenCapPaperObservation,
        after: GreenCapPaperObservation,
        predicted: (dx: Double, dy: Double),
        predictedDistance: Double,
        observedDx: Double,
        observedDy: Double,
        observedDistance: Double,
        residualMm: Double,
        residualLimitMm: Double
    ) -> [String: Any] {
        [
            "label": label,
            "target_index": targetIndex,
            "segment_index": segmentIndex,
            "target_paper_x_mm": target.x,
            "target_paper_y_mm": target.y,
            "command_x_mm": commandX,
            "command_y_mm": commandY,
            "before_frame": before.frameNumber,
            "after_frame": after.frameNumber,
            "before_paper_x_mm": before.paperMm.x,
            "before_paper_y_mm": before.paperMm.y,
            "after_paper_x_mm": after.paperMm.x,
            "after_paper_y_mm": after.paperMm.y,
            "predicted_dx_mm": predicted.dx,
            "predicted_dy_mm": predicted.dy,
            "predicted_distance_mm": predictedDistance,
            "observed_dx_mm": observedDx,
            "observed_dy_mm": observedDy,
            "observed_distance_mm": observedDistance,
            "residual_mm": residualMm,
            "residual_limit_mm": residualLimitMm
        ]
    }

    @MainActor
    private func rollbackRejectedVisualMove(
        commandX: Double,
        commandY: Double,
        before: GreenCapPaperObservation,
        after: GreenCapPaperObservation,
        label: String,
        targetIndex: Int,
        segmentIndex: Int,
        residualMm: Double,
        residualLimitMm: Double,
        feedMmMin: Double
    ) async -> GreenCapPaperObservation? {
        let rollbackToleranceMm = max(15.0, residualLimitMm * 1.5)
        let displacedDistanceMm = paperDistance(from: after.paperMm, to: before.paperMm)
        bridge.visualCenterDotStatus = String(format: "VIS BACK %@ %02d", label, segmentIndex)
        calibrationStatusText = String(
            format: "CAL visual %@ rollback after residual %.1fmm",
            label,
            residualMm
        )
        setVisualMoveIntent(
            start: after.paperMm,
            end: PaperPointMmSnapshot(
                x: after.paperMm.x - (after.paperMm.x - before.paperMm.x),
                y: after.paperMm.y - (after.paperMm.y - before.paperMm.y)
            ),
            label: "BACK \(label)",
            detail: String(format: "cmd X%+.1f Y%+.1f", -commandX, -commandY)
        )

        guard let response = await runSetupVectorJog(
            xMm: -commandX,
            yMm: -commandY,
            feedMmMin: feedMmMin
        ) else {
            clearVisualMoveIntent(reason: "rollback_move_failed")
            bridge.recordOperatorEvent(
                "visual_target_rollback_failed",
                details: [
                    "label": label,
                    "target_index": targetIndex,
                    "segment_index": segmentIndex,
                    "reason": "move_failed",
                    "residual_mm": residualMm,
                    "residual_limit_mm": residualLimitMm,
                    "rollback_command_x_mm": -commandX,
                    "rollback_command_y_mm": -commandY
                ]
            )
            calibrationStatusText = "CAL visual target stopped: rollback move failed"
            bridge.visualCenterDotStatus = "VIS BACK FAIL"
            return nil
        }
        if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
            clearVisualMoveIntent(reason: "rollback_pin_active")
            bridge.visualCenterDotStatus = "VIS PIN \(pins)"
            bridge.recordOperatorEvent(
                "visual_target_rollback_failed",
                details: [
                    "label": label,
                    "target_index": targetIndex,
                    "segment_index": segmentIndex,
                    "reason": "pin_active",
                    "pins": pins,
                    "residual_mm": residualMm,
                    "residual_limit_mm": residualLimitMm
                ]
            )
            calibrationStatusText = "CAL visual target stopped: rollback pin active \(pins)"
            return nil
        }

        try? await Task.sleep(nanoseconds: 450_000_000)
        guard let rollback = await waitForGreenCapPaperObservation(
            afterFrame: after.frameNumber,
            timeoutSeconds: 4.0
        ), rollback.frameNumber > after.frameNumber else {
            clearVisualMoveIntent(reason: "rollback_no_new_frame")
            bridge.recordOperatorEvent(
                "visual_target_rollback_failed",
                details: [
                    "label": label,
                    "target_index": targetIndex,
                    "segment_index": segmentIndex,
                    "reason": "no_new_frame",
                    "residual_mm": residualMm,
                    "residual_limit_mm": residualLimitMm,
                    "rollback_command_x_mm": -commandX,
                    "rollback_command_y_mm": -commandY
                ]
            )
            bridge.visualCenterDotStatus = "VIS BACK NO FRAME"
            calibrationStatusText = "CAL visual target stopped: rollback produced no new cap observation"
            return nil
        }
        clearVisualMoveIntent(reason: "rollback_observed")

        let rollbackDistanceMm = paperDistance(from: rollback.paperMm, to: before.paperMm)
        let rollbackImprovementMm = displacedDistanceMm - rollbackDistanceMm
        let details: [String: Any] = [
            "label": label,
            "target_index": targetIndex,
            "segment_index": segmentIndex,
            "before_frame": before.frameNumber,
            "after_frame": after.frameNumber,
            "rollback_frame": rollback.frameNumber,
            "before_paper_x_mm": before.paperMm.x,
            "before_paper_y_mm": before.paperMm.y,
            "after_paper_x_mm": after.paperMm.x,
            "after_paper_y_mm": after.paperMm.y,
            "rollback_paper_x_mm": rollback.paperMm.x,
            "rollback_paper_y_mm": rollback.paperMm.y,
            "rollback_command_x_mm": -commandX,
            "rollback_command_y_mm": -commandY,
            "rollback_distance_mm": rollbackDistanceMm,
            "rollback_tolerance_mm": rollbackToleranceMm,
            "rollback_improvement_mm": rollbackImprovementMm,
            "residual_mm": residualMm,
            "residual_limit_mm": residualLimitMm
        ]
        bridge.recordOperatorEvent("visual_target_rollback_completed", details: details)
        guard rollbackDistanceMm <= rollbackToleranceMm else {
            bridge.visualCenterDotStatus = String(format: "VIS BACK %.1f", rollbackDistanceMm)
            bridge.recordOperatorEvent("visual_target_rollback_rejected", details: details)
            calibrationStatusText = String(
                format: "CAL visual target stopped: rollback %.1fmm from verified point",
                rollbackDistanceMm
            )
            return nil
        }

        return rollback
    }

    func paperDistance(from point: PaperPointMmSnapshot, to target: PaperPointMmSnapshot) -> Double {
        hypot(target.x - point.x, target.y - point.y)
    }

    private var topBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("Plotter Vision")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }

                Divider()
                    .frame(height: 22)
                    .overlay(Color.white.opacity(0.22))

                plotterConnectionButton

                controlButton(
                    systemName: "slider.horizontal.3",
                    label: "Machine",
                    help: "Open or close machine controls",
                    isActive: bridge.isOnline
                ) {
                    toggleOperatorWindow(
                        id: OperatorWindowID.machineControls,
                        title: "Machine",
                        source: "top_bar"
                    )
                }

                CameraSelector(camera: plotterCamera)
                    .frame(width: 166)

                controlButton(
                    systemName: workspace.plotterCameraVisible ? "video.fill" : "video.slash",
                    label: "Plotter",
                    help: "Show or hide the plotter camera pane",
                    isActive: workspace.plotterCameraVisible
                ) {
                    toggleCameraVisibility(plotterCamera, source: "top_bar")
                }

                controlButton(
                    systemName: "rectangle.dashed",
                    label: "Plot Vid",
                    help: "Open or close plotter video controls",
                    isActive: plotterViewport.videoFilter != .normal || plotterViewport.focusMode == .focused || plotterViewport.rotationDegrees != 0
                ) {
                    toggleOperatorWindow(
                        id: OperatorWindowID.plotterVideoPanel,
                        title: "Plotter Video",
                        source: "top_bar"
                    )
                }

                CameraSelector(camera: faceCamera)
                    .frame(width: 150)

                controlButton(
                    systemName: workspace.faceCameraVisible ? "video.fill" : "video.slash",
                    label: "Face",
                    help: "Show or hide the face camera pane",
                    isActive: workspace.faceCameraVisible
                ) {
                    toggleCameraVisibility(faceCamera, source: "top_bar")
                }

                controlButton(
                    systemName: "person.crop.rectangle",
                    label: "Face Vid",
                    help: "Open or close face video and portrait controls",
                    isActive: portraitContourMonitorEnabled || bridge.faceContourPreviewOverlay != nil
                ) {
                    toggleOperatorWindow(
                        id: OperatorWindowID.faceVideoPanel,
                        title: "Face Video",
                        source: "top_bar"
                    )
                }

                controlButton(
                    systemName: "checklist.checked",
                    label: "Setup",
                    help: "Open or close setup",
                    isActive: workspace.setupWindowActive || manualFiducialMode
                ) {
                    toggleOperatorWindow(
                        id: OperatorWindowID.setupPanel,
                        title: "Setup",
                        source: "top_bar",
                        beforeOpen: startCalibrationWizard
                    )
                }

                controlButton(
                    systemName: "list.bullet.rectangle",
                    label: "Log",
                    help: "Open or close the operator log",
                    isActive: OperatorWindowSupport.isWindowOpen(title: "Log", identifier: OperatorWindowID.operatorLog)
                ) {
                    toggleOperatorWindow(
                        id: OperatorWindowID.operatorLog,
                        title: "Log",
                        source: "top_bar"
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var plotterConnectionButton: some View {
        let isActive = bridge.isLiveMotionMode
        let isDisabled = !bridge.canUsePlotterConnectionControl
        let isWarning = bridge.hasBridgeApiMismatch || bridge.hasLifecycleBuildMismatch
        let fillColor = isWarning
            ? Color.yellow.opacity(0.20)
            : isActive
            ? Color.green.opacity(0.30)
            : Color.white.opacity(isDisabled ? 0.06 : 0.14)
        let strokeColor = isWarning
            ? Color.yellow.opacity(0.56)
            : isActive
            ? Color.green.opacity(0.58)
            : Color.white.opacity(isDisabled ? 0.12 : 0.22)

        return Button {
            Task { await bridge.connectPlotter() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: bridge.plotterConnectionSystemName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(
                        isDisabled
                            ? .white.opacity(0.34)
                            : isWarning ? .yellow.opacity(0.94) : isActive ? .green.opacity(0.96) : .white.opacity(0.92)
                    )
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bridge.plotterConnectionTitle.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isDisabled ? .white.opacity(0.36) : .white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(bridge.plotterConnectionSubtitle.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            isActive
                                ? .green.opacity(0.88)
                                : isWarning ? .yellow.opacity(0.88) : isDisabled ? .white.opacity(0.30) : .orange.opacity(0.86)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 156, height: 38)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(bridge.plotterConnectionHelp)
    }

    private var calibrationWizardOverlay: some View {
        CalibrationWizardView(
            instructionText: wizardInstructionText,
            fiducialDetail: wizardFiducialDetail,
            fiducialStatus: wizardFiducialStatus,
            greenCapDetail: wizardGreenCapDetail,
            greenCapStatus: wizardGreenCapStatus,
            visualCalibrationDetail: frameLearning.detail,
            visualCalibrationStatus: wizardMotionProbeStatus,
            bindingDetail: wizardMotionValidationDetail,
            bindingStatus: wizardMotionValidationStatus,
            primaryActionTitle: wizardPrimaryActionTitle,
            primaryActionEnabled: wizardPrimaryActionEnabled,
            primaryActionDisabledReason: wizardPrimaryActionDisabledReason,
            drawFrameVisible: wizardDrawFrameVisible,
            drawFrameEnabled: wizardDrawFrameEnabled,
            drawFrameDisabledReason: wizardDrawFrameDisabledReason,
            hasPaperLock: bridge.hasPaperLock,
            capStateLabel: wizardCapStateLabel,
            isLiveMotionMode: bridge.isLiveMotionMode,
            capDetected: currentCarriageMarker != nil,
            fieldWidthMm: $workspace.visualFieldWidthMm,
            fieldHeightMm: $workspace.visualFieldHeightMm,
            primaryAction: runCalibrationWizardPrimaryAction,
            drawFrame: drawValidatedFieldFrame,
            reset: resetCalibrationWizard,
            hide: hideCalibrationWizard
        )
    }

    private var wizardFiducialStatus: CalibrationWizardStepStatus {
        if bridge.hasPaperLock { return .done }
        if machineVideoAgreementModel != nil { return .active }
        return .pending
    }

    private var wizardGreenCapStatus: CalibrationWizardStepStatus {
        if confirmedCapPoint != nil { return .done }
        return currentCarriageMarker == nil ? .blocked : .active
    }

    private var wizardMotionProbeStatus: CalibrationWizardStepStatus {
        if frameLearning.status == "AGREE" || frameLearning.status == "ESTIMATE" || frameLearning.status == "MEASURED" || frameLearning.status == "VALIDATE" || visualMotionValidated {
            return .done
        }
        if confirmedCapPoint != nil {
            return canRunWizardMotionProbe ? .active : .blocked
        }
        return .pending
    }

    private var wizardMotionValidationStatus: CalibrationWizardStepStatus {
        if visualMotionValidated { return .done }
        if frameLearning.status == "VALIDATE" { return .active }
        if frameLearning.status == "MEASURED" {
            return canValidateWizardMotion ? .active : .blocked
        }
        if frameLearning.status == "WEAK" || frameLearning.status == "BLOCK" || frameLearning.status == "STOP" {
            return .blocked
        }
        return .pending
    }

    private var wizardFiducialDetail: String {
        if bridge.hasPaperLock { return "Field \(Int(bridge.visualFieldWidthMm))x\(Int(bridge.visualFieldHeightMm)) locked; drag box/top-right resize in video to re-lock" }
        if machineVideoAgreementModel != nil { return "Registering provisional \(desiredVisualFieldSizeLabel) field from current estimate" }
        return "Hidden until first machine-video estimate exists"
    }

    private var wizardFieldDetail: String {
        if bridge.hasPaperLock { return "Field locked; video box remains editable while setup is open" }
        if machineVideoAgreementModel != nil { return "Waiting for field registration from current estimate" }
        return "Waiting for first machine-video estimate"
    }

    private var wizardGreenCapDetail: String {
        if let confirmedCapPoint, let paperMm = confirmedCapPoint.paperMm {
            return String(format: "Confirmed field x%.1f y%.1f mm", paperMm.x, paperMm.y)
        }
        if let confirmedCapPoint {
            return String(
                format: "Confirmed camera x%.3f y%.3f",
                confirmedCapPoint.cameraPoint.x,
                confirmedCapPoint.cameraPoint.y
            )
        }
        guard let marker = currentCarriageMarker else {
            return "Waiting for bright cap marker"
        }
        return String(format: "%@ detected x%.3f y%.3f %.0f%%; confirm", marker.colorName, marker.center.x, marker.center.y, marker.strength * 100)
    }

    private var wizardCapStateLabel: String {
        if currentGreenCapFieldMappedReady { return bridge.hasPaperLock ? "LIVE-MM" : "LIVE-CAM" }
        if confirmedCapFieldMappedReady { return "CONF-MM" }
        if confirmedCapPoint != nil { return "CONF-CAM" }
        return "--"
    }

    private var wizardMotionValidationDetail: String {
        if visualMotionValidated {
            if let model = visualMotionModel {
                return String(
                    format: "Motion valid rms %.1f max %.1f",
                    model.rmsResidualMm,
                    model.maxResidualMm
                )
            }
            return "Motion model valid"
        }
        if frameLearning.status == "MEASURED" {
            guard let model = visualMotionModel, model.isUsable else {
                return "Measured samples did not produce a usable model"
            }
            if !currentGreenCapFieldMappedReady { return greenCapFieldMappingDetail }
            return String(
                format: "Ready to validate rms %.1f max %.1f",
                model.rmsResidualMm,
                model.maxResidualMm
            )
        }
        if frameLearning.status == "WEAK" || frameLearning.status == "BLOCK" || frameLearning.status == "STOP" {
            return frameLearning.detail
        }
        if frameLearning.status == "VALIDATE" {
            return frameLearning.detail
        }
        if let model = machineVideoAgreementModel, model.isUsable {
            return String(
                format: "Online agreement X %.4f Y %.4f corner %.1fmm",
                model.xBasisLengthNorm,
                model.yBasisLengthNorm,
                model.fieldCornerPrecisionMm
            )
        }
        return "Run machine-video agreement first"
    }

    private var wizardInstructionText: String {
        if confirmedCapPoint == nil {
            return currentCarriageMarker == nil
                ? "Show the green cap in the plotter camera before setup movement."
                : "Confirm the detected green cap before machine-video agreement."
        }
        if frameLearning.status != "MEASURED" && !visualMotionValidated {
            if !bridge.hasPaperLock {
                return "Run machine-video agreement. The Drawing Border is hidden until the online +X/+Y estimate is usable."
            }
            return "Drag the Drawing Border or its top-right resize handle if needed, then run non-homed relative motion calibration in that border."
        }
        if visualMotionValidated {
            return "Motion calibration is validated for green-cap movement inside the field."
        }
        if !visualMotionValidated {
            return "Motion calibration is measured. Validate the relative motion model before leaving setup."
        }
        return "Motion calibration is validated for green-cap movement inside the field."
    }

    private var wizardPrimaryActionTitle: String {
        if confirmedCapPoint == nil {
            return currentCarriageMarker == nil ? "Click Green Cap" : "Confirm Green Cap"
        }
        if frameLearning.status == "VALIDATE" { return "Validating Motion" }
        if visualMotionValidated { return "Motion Validated" }
        if frameLearning.status != "MEASURED" {
            return bridge.hasPaperLock && machineVideoAgreementModel != nil
                ? "Run Motion Calibration"
                : "Run Machine-Video Probe"
        }
        if frameLearning.status == "MEASURED" { return "Validate Motion" }
        return "Blocked"
    }

    private var wizardPrimaryActionEnabled: Bool {
        if confirmedCapPoint == nil {
            return true
        }
        if frameLearning.status == "VALIDATE" { return false }
        if visualMotionValidated {
            return false
        }
        if frameLearning.status != "MEASURED" {
            return canRunWizardMotionProbe
        }
        return canValidateWizardMotion
    }

    private var wizardPrimaryActionDisabledReason: String? {
        guard !wizardPrimaryActionEnabled else { return nil }
        if confirmedCapPoint == nil {
            return "cap marker not confirmed"
        }
        if frameLearning.status == "VALIDATE" { return "motion validation running" }
        if visualMotionValidated { return nil }
        if frameLearning.status != "MEASURED" {
            if !bridge.isLiveMotionMode { return bridge.motionGateMessage }
            if bridge.isMachineAlarm { return "machine alarm" }
            if bridge.isMachineBusy || bridge.isRunning { return "machine busy" }
            if currentCarriageMarker == nil { return "green cap not detected" }
            return "machine-video agreement blocked"
        }
        if visualMotionModel?.isUsable != true { return "motion model not usable" }
        if currentCarriageMarker == nil { return "green cap not detected" }
        if !currentGreenCapFieldMappedReady { return greenCapFieldMappingDetail }
        if bridge.isMachineAlarm { return "machine alarm" }
        if bridge.isMachineBusy || bridge.isRunning { return "machine busy" }
        return "motion validation blocked"
    }

    private func runCalibrationWizardPrimaryAction() {
        if confirmedCapPoint == nil {
            if currentCarriageMarker != nil {
                useDetectedCarriageMarker()
            } else {
                startManualPenClick()
            }
            return
        }

        if visualMotionValidated {
            calibrationStatusText = "FIELD motion validated; draw frame is available"
            return
        }

        if frameLearning.status != "MEASURED" {
            guard canRunWizardMotionProbe else {
                calibrationStatusText = "FIELD motion calibration blocked: \(wizardPrimaryActionDisabledReason ?? greenCapFieldMappingDetail)"
                return
            }
            calibrationStatusText = bridge.hasPaperLock && machineVideoAgreementModel != nil
                ? "FIELD adjusted-box motion calibration requested"
                : "FIELD machine-video agreement requested"
            Task {
                await runFrameLearning()
            }
            return
        }

        validateWizardMotion()
    }

    private func validateWizardMotion() {
        guard canValidateWizardMotion, let model = visualMotionModel else {
            calibrationStatusText = "FIELD motion validation blocked: \(wizardPrimaryActionDisabledReason ?? wizardMotionValidationDetail)"
            return
        }
        calibrationStatusText = "FIELD motion validation requested"
        frameLearning.status = "VALIDATE"
        frameLearning.detail = "Moving cap to a field target"
        Task {
            await runWizardMotionValidation(model: model)
        }
    }

    private func drawValidatedFieldFrame() {
        guard wizardDrawFrameVisible else {
            calibrationStatusText = "FIELD frame draw blocked: validate motion first"
            return
        }
        guard wizardDrawFrameEnabled else {
            calibrationStatusText = "FIELD frame draw blocked: \(wizardDrawFrameDisabledReason ?? "setup not ready")"
            return
        }
        guard let model = visualMotionModel, model.isUsable else {
            calibrationStatusText = "FIELD frame draw blocked: motion model not usable"
            return
        }
        guard let corners = validatedFieldFrameCorners else {
            calibrationStatusText = "BORDER draw blocked: Drawing Border is too small"
            return
        }
        Task {
            await runValidatedFieldFrameDraw(model: model, corners: corners)
        }
    }

    @MainActor
    private func runWizardMotionValidation(model: VisualMotionModel) async {
        guard let current = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            frameLearning.status = "BLOCK"
            frameLearning.detail = "Cap marker not visible for validation"
            calibrationStatusText = "FIELD motion validation blocked: cap not visible"
            return
        }
        let target = wizardMotionValidationTarget(from: current.paperMm)
        visualCenterDotTaskActive = true
        defer {
            visualCenterDotTaskActive = false
        }
        calibrationStatusText = String(
            format: "FIELD validating motion to x%.1f y%.1f",
            target.x,
            target.y
        )
        guard let observed = await approachVisualTarget(target, label: "VALIDATE", targetIndex: 1) else {
            frameLearning = FrameLearningState(
                status: "MEASURED",
                detail: "Motion validation failed; fix blocker and retry validation",
                sampleCount: model.sampleCount,
                xPixelsPerMm: hypot(model.xBasisDx, model.xBasisDy),
                yPixelsPerMm: hypot(model.yBasisDx, model.yBasisDy),
                lastPins: bridge.machinePins
            )
            return
        }
        let residualMm = paperDistance(from: observed.paperMm, to: target)
        frameLearning = FrameLearningState(
            status: "VALIDATED",
            detail: String(
                format: "Motion valid target residual %.1fmm rms %.1f max %.1f samples %d",
                residualMm,
                model.rmsResidualMm,
                model.maxResidualMm,
                model.sampleCount
            ),
            sampleCount: model.sampleCount,
            xPixelsPerMm: hypot(model.xBasisDx, model.xBasisDy),
            yPixelsPerMm: hypot(model.yBasisDx, model.yBasisDy),
            lastPins: bridge.machinePins
        )
        calibrationStatusText = "FIELD motion validated"
        bridge.recordOperatorEvent(
            "wizard_motion_validated",
            details: [
                "sample_count": model.sampleCount,
                "rms_residual_mm": model.rmsResidualMm,
                "max_residual_mm": model.maxResidualMm,
                "determinant": model.determinant,
                "target_x_mm": target.x,
                "target_y_mm": target.y,
                "observed_x_mm": observed.paperMm.x,
                "observed_y_mm": observed.paperMm.y,
                "target_residual_mm": residualMm
            ]
        )
    }

    private func wizardMotionValidationTarget(from current: PaperPointMmSnapshot) -> PaperPointMmSnapshot {
        let inset = visualCapSafeZoneMarginMm
        let minX = inset
        let maxX = max(inset, bridge.visualFieldWidthMm - inset)
        let minY = inset
        let maxY = max(inset, bridge.visualFieldHeightMm - inset)
        let step = 20.0
        let positiveX = current.x + step
        let targetX = positiveX <= maxX ? positiveX : max(minX, current.x - step)
        if abs(targetX - current.x) >= 5.0 {
            return PaperPointMmSnapshot(x: targetX, y: min(max(current.y, minY), maxY))
        }
        let positiveY = current.y + step
        let targetY = positiveY <= maxY ? positiveY : max(minY, current.y - step)
        return PaperPointMmSnapshot(x: min(max(current.x, minX), maxX), y: targetY)
    }

    private func startCalibrationWizard() {
        workspace.setupWindowActive = true
        showPlotterCameraForSetup(source: "setup")
        refreshSetupSnapshot()

        manualFiducialMode = false
        manualPenMode = false
        manualCapColorMode = false
        if confirmedCapPoint == nil {
            calibrationStatusText = currentCarriageMarker == nil
                ? "FIELD show green cap in camera"
                : "FIELD confirm green cap"
        } else if frameLearning.status != "MEASURED" {
            calibrationStatusText = "BORDER run machine-video agreement before drawing border"
        } else {
            calibrationStatusText = "FIELD motion measured; validate motion"
        }
    }

    private func hideCalibrationWizard() {
        workspace.setupWindowActive = false
        _ = OperatorWindowSupport.closeWindow(title: "Setup", identifier: OperatorWindowID.setupPanel)
        manualFiducialMode = false
        manualPenMode = false
        manualCapColorMode = false
        calibrationStatusText = "FIELD hidden"
        publishOperatorUIState(reason: "operator_ui_setup_hidden")
    }

    private func resetCalibrationWizard() {
        clearWizardLocalState(resetFiducials: true)
        calibrationStatusText = "FIELD reset requested"
        Task {
            _ = await bridge.resetCalibrationSetup()
            clearWizardLocalState(resetFiducials: true)
            calibrationStatusText = "FIELD reset; confirm green cap"
        }
    }

    private func clearWizardLocalState(resetFiducials: Bool) {
        workspace.setupWindowActive = true
        manualFiducialMode = false
        manualPenMode = false
        manualCapColorMode = false
        if resetFiducials {
            manualFiducials = []
        }
        confirmedCapPoint = nil
        machineVideoAgreementModel = nil
        machineVideoAgreementSamples = []
        visualMotionModel = nil
        visualMotionSamples = []
        visualCenterDotTaskActive = false
        frameLearning = .idle
        bridge.learnedCapToTipModel = nil
        bridge.drawableSafeZone = nil
        _ = bridge.resetVisualCalibrationSession(prefix: "swift-probe")
    }

    private var topStatusLights: some View {
        HStack(spacing: 7) {
            StatusLamp(
                title: "BRIDGE",
                value: bridge.bridgeLifecycleLampValue,
                color: bridgeLifecycleLampColor,
                help: bridge.bridgeLifecycleHelp
            )
            StatusLamp(
                title: "MOTION",
                value: bridge.motionModeLabel,
                color: motionLampColor,
                help: bridge.motionGateMessage
            )
            StatusLamp(
                title: "MODEL",
                value: machineVideoAgreementModel == nil
                    ? "--"
                    : (frameLearning.status == "AGREE" ? "2X2" : "EST"),
                color: frameLearning.status == "AGREE"
                    ? .green
                    : (machineVideoAgreementModel != nil ? .yellow : .white.opacity(0.45)),
                help: wizardFiducialDetail
            )
            StatusLamp(
                title: "FIELD",
                value: paperLampValue,
                color: paperLampColor,
                help: wizardFieldDetail
            )
            StatusLamp(
                title: "CAP",
                value: penLampValue,
                color: penLampColor,
                help: confirmedCapStatusText
            )
            StatusLamp(
                title: "STATE",
                value: bridge.machineState,
                color: bridge.isMachineAlarm ? .red : (bridge.isMachineBusy || bridge.isRunning ? .yellow : .white.opacity(0.72)),
                help: bridge.machineStatus
            )
        }
    }

    private var bridgeLifecycleLampColor: Color {
        if !bridge.isOnline { return .red }
        if bridge.hasBridgeApiMismatch || bridge.hasLifecycleBuildMismatch { return .yellow }
        switch bridge.bridgeLifecycleTitle {
        case "Preview Bridge":
            return .cyan
        case "Live Bridge":
            return .green
        case "Hardware Standby":
            return .orange
        default:
            return .white.opacity(0.72)
        }
    }

    private var motionLampColor: Color {
        if !bridge.isOnline || bridge.isMachineAlarm { return .red }
        if bridge.isMachineBusy || bridge.isRunning { return .yellow }
        if bridge.isLiveMotionMode { return .green }
        return .orange
    }

    private var paperLampValue: String {
        if bridge.paperTransformStatus.contains("LOCK") { return "LOCK" }
        if bridge.paperTransformStatus.contains("SOLVE") { return "SOLVE" }
        if bridge.paperTransformStatus.contains("ERR") { return "ERR" }
        return "--"
    }

    private var penLampValue: String {
        if bridge.learnedCapToTipModel != nil { return "OFFSET" }
        guard let confirmedCapPoint else { return "--" }
        return confirmedCapPoint.paperMm == nil ? "CAM" : "MM"
    }

    private var penLampColor: Color {
        guard let confirmedCapPoint else { return .white.opacity(0.45) }
        guard confirmedCapPoint.paperMm != nil else { return .yellow }
        return visualMotionValidated ? .green : .yellow
    }

    private var confirmedCapStatusText: String {
        guard let confirmedCapPoint else { return "Cap marker not confirmed" }
        if let paperMm = confirmedCapPoint.paperMm {
            let toolSuffix: String
            if let model = bridge.learnedCapToTipModel {
                toolSuffix = String(format: " OFFSET dx%.1f dy%.1f", model.offsetXMm, model.offsetYMm)
            } else {
                toolSuffix = " OFFSET --"
            }
            return String(
                format: "CAP cam x%.3f y%.3f paper x%.1f y%.1f mm %@%@",
                confirmedCapPoint.cameraPoint.x,
                confirmedCapPoint.cameraPoint.y,
                paperMm.x,
                paperMm.y,
                "MAPPED",
                toolSuffix
            )
        }
        return String(
            format: "CAP cam x%.3f y%.3f, visual field not locked",
            confirmedCapPoint.cameraPoint.x,
            confirmedCapPoint.cameraPoint.y
        )
    }

    private var paperLampColor: Color {
        if bridge.paperTransformStatus.contains("LOCK") { return .green }
        if bridge.paperTransformStatus.contains("SOLVE") { return .yellow }
        if bridge.paperTransformStatus.contains("ERR") { return .red }
        return .white.opacity(0.45)
    }

    private func startManualPenClick() {
        manualPenMode = true
        manualFiducialMode = false
        manualCapColorMode = false
        confirmedCapPoint = nil
        bridge.learnedCapToTipModel = nil
        bridge.drawableSafeZone = nil
        calibrationStatusText = "FIELD click cap marker on plotter view"
    }

    private func startCapColorPick() {
        manualCapColorMode = true
        manualPenMode = false
        manualFiducialMode = false
        confirmedCapPoint = nil
        plotterCamera.clearCarriageMarkerObservation()
        calibrationStatusText = "CAL click the cap color on the plotter view"
    }

    private func useDetectedCarriageMarker() {
        guard let marker = currentCarriageMarker else {
            startManualPenClick()
            return
        }
        let cameraPoint = CGPoint(
            x: clampDouble(Double(marker.center.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(marker.center.y), min: 0.0, max: 1.0)
        )
        let approximateViewPoint = CGPoint(
            x: cameraPoint.x,
            y: 1.0 - cameraPoint.y
        )
        let paperMm = bridge.paperPointMm(cameraPoint: cameraPoint)
        confirmedCapPoint = ConfirmedCapPoint(
            point: approximateViewPoint,
            cameraPoint: cameraPoint,
            paperMm: paperMm
        )
        bridge.learnedCapToTipModel = nil
        bridge.drawableSafeZone = nil
        manualPenMode = false
        manualFiducialMode = false
        manualCapColorMode = false

        if let paperMm {
            calibrationStatusText = String(
                format: "FIELD %@ cap accepted field x%.1f y%.1f mm",
                marker.colorName.lowercased(),
                paperMm.x,
                paperMm.y
            )
        } else {
            calibrationStatusText = String(
                format: "FIELD %@ cap cam x%.3f y%.3f; lock visual field first",
                marker.colorName.lowercased(),
                cameraPoint.x,
                cameraPoint.y
            )
        }
    }

    private func recordConfirmedCap(viewPoint: CGPoint, cameraPoint: CGPoint) {
        let normalizedView = CGPoint(
            x: clampDouble(Double(viewPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(viewPoint.y), min: 0.0, max: 1.0)
        )
        let normalizedCamera = CGPoint(
            x: clampDouble(Double(cameraPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(cameraPoint.y), min: 0.0, max: 1.0)
        )
        let paperMm = bridge.paperPointMm(cameraPoint: normalizedCamera)
        confirmedCapPoint = ConfirmedCapPoint(
            point: normalizedView,
            cameraPoint: normalizedCamera,
            paperMm: paperMm
        )
        bridge.learnedCapToTipModel = nil
        bridge.drawableSafeZone = nil

        if let paperMm {
            calibrationStatusText = String(
                format: "CAL cap marker observed field x%.1f y%.1f mm",
                paperMm.x,
                paperMm.y
            )
        } else {
            calibrationStatusText = String(
                format: "CAL cap marker observed cam x%.3f y%.3f; lock visual field first",
                normalizedCamera.x,
                normalizedCamera.y
            )
        }

        if workspace.setupWindowActive {
            manualPenMode = false
        }
    }

    private func recordCapMarkerColor(viewPoint: CGPoint, cameraPoint: CGPoint) {
        _ = viewPoint
        let normalizedCamera = CGPoint(
            x: clampDouble(Double(cameraPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(cameraPoint.y), min: 0.0, max: 1.0)
        )
        confirmedCapPoint = nil
        plotterCamera.clearCarriageMarkerObservation()
        if let target = plotterCamera.pickCapMarkerColor(cameraPoint: normalizedCamera) {
            calibrationStatusText = String(
                format: "CAL cap color sampled %@ rgb %.0f %.0f %.0f; detecting",
                target.label,
                target.red,
                target.green,
                target.blue
            )
            manualCapColorMode = false
        } else {
            calibrationStatusText = "CAL cap color sample failed; click a saturated cap pixel"
        }
    }

    private func resetVisualControls() {
        plotterViewport.videoFilter = .normal
        plotterViewport.resetFOV()
        plotterOverlay.opacity = 0.38
        plotterCamera.showMeasurements = true
        plotterCamera.segmentationEnabled = false
        plotterCamera.changeDetectionEnabled = false
        faceCamera.segmentationEnabled = false
        showImageProcessingPanel = true
        calibrationStatusText = "VIS controls reset"
    }

    private func resetCapMarkerColor() {
        manualCapColorMode = false
        plotterCamera.resetCapMarkerColorTarget()
        calibrationStatusText = "VIS cap color reset"
    }

}
