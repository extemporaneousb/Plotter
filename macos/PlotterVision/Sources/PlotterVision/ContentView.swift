import SwiftUI

private let visualProbeMinimumObservedMm = 8.0
private let visualCapSafeZoneMarginMm = 8.0
private let visualProbeBootstrapStepXMm = 100.0
private let visualProbeBootstrapMaxTotalXMm = 300.0
private let visualProbeBootstrapMinStepXMm = 15.0
private let visualProbeBootstrapTargetXMm = 200.0
private let visualProbeBootstrapMinProgressXMm = 4.0
private let visualProbeFieldRecoveryStepXMm = 50.0
private let visualProbeFieldRecoveryMaxTotalXMm = 150.0
private let visualCapReacquireStepXMm = 25.0
private let visualCapReacquireMaxTotalXMm = 150.0
private let visualCapReacquireMaxAttempts = 2
private let visualCapFreshFrameAdvance = 3
private let visualCapProjectionBottomAllowanceMm = 180.0
private let visualCapProjectionTopAllowanceMm = 12.0
private let visualCalibrationMarkSizeMm = 6.0
private let visualCalibrationRetryMarkSizeMm = 10.0
private let visualCalibrationParkMm = 24.0

struct ContentView: View {
    @StateObject private var plotterCamera = CameraModel(role: .plotter)
    @StateObject private var faceCamera = CameraModel(role: .face)
    @ObservedObject var bridge: PlotterBridgeModel
    @Environment(\.openWindow) private var openWindow
    @State private var showLiveVideo = true
    @State private var cameraLayout = CameraLayoutMode.both
    @State private var plotterOverlay = PlotterOverlaySettings()
    @State private var plotterViewport = PlotterViewportSettings()
    @State private var drawingFrame = DrawingFrameSettings()
    @State private var shapeAssessment = ShapeAssessmentState.idle
    @State private var frameLearning = FrameLearningState.idle
    @State private var awaitingAssessment = false
    @State private var didLoadSavedFrameState = false
    @State private var calibrationStatusText = "CAL idle"
    @State private var showCalibrationWizard = false
    @State private var showImageProcessingPanel = true
    @State private var manualFiducialMode = false
    @State private var manualFiducials: [ManualFiducialPoint] = []
    @State private var manualPenMode = false
    @State private var manualCapColorMode = false
    @State private var confirmedCapPoint: ConfirmedCapPoint?
    @State private var visualMotionModel: VisualMotionModel?
    @State private var visualMotionSamples: [VisualMotionSample] = []
    @State private var visualCenterDotTaskActive = false
    @State private var showXFieldMovePrompt = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraWorkspace
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                statusBar
            }
            .padding(18)

            if showCalibrationWizard {
                calibrationWizardOverlay
            }

        }
        .background(Color.black)
        .onAppear {
            guard !didLoadSavedFrameState else { return }
            didLoadSavedFrameState = true
            loadSavedFrameState()
            bridge.recordOperatorEvent("content_view_appeared")
        }
        .task {
            await bridge.refreshHealth()
            await bridge.refreshMachineStatus()
            await bridge.refreshPaperStatus()
            await bridge.refreshVisualBindingStatus()
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
                if pollIteration.isMultiple(of: 4) {
                    await bridge.refreshVisualBindingStatus()
                }
            }
        }
        .onChange(of: plotterCamera.changeReport.sequence) { _, _ in
            updateShapeAssessmentFromCamera()
        }
        .onChange(of: plotterOverlay) { _, _ in
            saveFrameState()
        }
        .onChange(of: plotterViewport) { _, _ in
            saveFrameState()
        }
        .onChange(of: drawingFrame) { _, _ in
            saveFrameState()
        }
        .onDisappear {
            bridge.recordOperatorEvent("content_view_disappeared")
            plotterCamera.stop()
            faceCamera.stop()
        }
        .alert("Move X into camera field?", isPresented: $showXFieldMovePrompt) {
            Button(String(format: "Move +X up to %.0fmm", visualProbeFieldRecoveryMaxTotalXMm)) {
                Task {
                    await moveXIntoCameraFieldForProbe(source: "prompt")
                }
            }
            .disabled(!canMoveXIntoCameraFieldForProbe)

            Button("Cancel", role: .cancel) {
                calibrationStatusText = "CAL visual calibration startup canceled"
            }
        } message: {
            Text("Use this only when the carriage path is clear and power-off gravity left X outside the camera view. This is a live +X jog for visibility; it does not home or trust axes.")
        }
    }

    @ViewBuilder
    private var cameraWorkspace: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width >= geometry.size.height
            switch cameraLayout {
            case .both:
                if horizontal {
                    HStack(spacing: 1) {
                        plotterCameraPane
                        faceCameraPane
                    }
                } else {
                    VStack(spacing: 1) {
                        plotterCameraPane
                        faceCameraPane
                    }
                }
            case .plotter:
                plotterCameraPane
            case .face:
                faceCameraPane
            }
        }
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
                        confirmedCapPoint: confirmedCapPoint,
                        motionTracks: plotterCamera.motionTracks,
                        expectedPathSegments: bridge.expectedPathSegments,
                        dotTestPreviewSegments: bridge.dotTestPreviewSegments,
                        dotTestPreviewPoints: bridge.dotTestPreviewPoints,
                        paperTransform: bridge.paperRegistrationSnapshot,
                        plotterOverlay: plotterOverlay,
                        pathRevealProgress: bridge.pathRevealProgress,
                        videoSize: plotterCamera.videoSize,
                        previewMode: plotterViewport.previewMode,
                        showGrid: plotterCamera.showGrid,
                        showMeasurements: plotterCamera.showMeasurements
                    )

                }
            }

            ManualFiducialOverlay(points: manualFiducials, isActive: manualFiducialMode)

            ConfirmedCapOverlay(point: manualPenMode ? confirmedCapPoint : nil, isActive: manualPenMode)
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
            } else if manualFiducialMode {
                ManualFiducialClickLayer(
                    settings: plotterViewport,
                    videoSize: plotterCamera.videoSize,
                    onMark: recordManualFiducial
                )
            }

            CameraPaneBadge(camera: plotterCamera)
        }
        .clipped()
        .overlay(Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1))
    }

    private var faceCameraPane: some View {
        ZStack {
            Color.black

            if showLiveVideo && faceCamera.isRunning {
                CameraPreview(session: faceCamera.session)
            } else {
                CameraPlaceholder(camera: faceCamera)
            }

            if faceCamera.segmentationEnabled {
                FaceContourOverlay(
                    segments: faceCamera.segments,
                    videoSize: faceCamera.videoSize,
                    previewMode: .fill
                )
            }

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

    private func beginShapeAssessment() {
        awaitingAssessment = true
        shapeAssessment = ShapeAssessmentState(
            status: "ARMED",
            detail: "Waiting for new ink change",
            changedObjects: 0,
            changedCells: 0,
            strength: 0
        )
        plotterCamera.resetChangeBaseline(updateStatus: false)
    }

    @MainActor
    private func drawFaceFromCurrentFrame() async {
        bridge.recordOperatorEvent("face_draw_capture_started")
        do {
            let raster = try await faceCamera.captureFaceRaster(columns: 14, rows: 18)
            let rect = drawingFrame.rect(
                workspaceXMm: bridge.workspaceXMm,
                workspaceYMm: bridge.workspaceYMm
            )
            let frame = BridgeDrawingFrameRequest(
                originXMm: Double(rect.minX) * bridge.workspaceXMm,
                originYMm: Double(rect.minY) * bridge.workspaceYMm,
                widthMm: Double(rect.width) * bridge.workspaceXMm,
                heightMm: Double(rect.height) * bridge.workspaceYMm,
                flipY: false
            )
            let completed = await bridge.drawFaceRaster(raster, frame: frame)
            if !completed {
                awaitingAssessment = false
            }
        } catch {
            awaitingAssessment = false
            faceCamera.statusText = error.localizedDescription
            bridge.statusText = error.localizedDescription
            bridge.previewStatus = "SIM ERR"
            bridge.recordOperatorEvent(
                "face_draw_capture_failed",
                details: ["error": error.localizedDescription]
            )
        }
    }

    @MainActor
    private func previewImageFromCurrentFrame() async {
        bridge.recordOperatorEvent("image_preview_capture_started")
        do {
            faceCamera.segmentationEnabled = true
            let raster = try await faceCamera.captureFaceRaster(columns: 16, rows: 20)
            let rect = drawingFrame.rect(
                workspaceXMm: bridge.workspaceXMm,
                workspaceYMm: bridge.workspaceYMm
            )
            let frame = BridgeDrawingFrameRequest(
                originXMm: Double(rect.minX) * bridge.workspaceXMm,
                originYMm: Double(rect.minY) * bridge.workspaceYMm,
                widthMm: Double(rect.width) * bridge.workspaceXMm,
                heightMm: Double(rect.height) * bridge.workspaceYMm,
                flipY: false
            )
            let completed = await bridge.previewImageContours(raster, frame: frame)
            calibrationStatusText = completed
                ? "VERIFY \(bridge.imagePreviewStatus) \(bridge.imagePreviewDetail)"
                : "VERIFY \(bridge.imagePreviewStatus)"
        } catch {
            faceCamera.statusText = error.localizedDescription
            bridge.statusText = error.localizedDescription
            bridge.imagePreviewStatus = "IMG ERR"
            bridge.imagePreviewDetail = "VISUAL ONLY"
            bridge.previewStatus = "SIM ERR"
            bridge.recordOperatorEvent(
                "image_preview_capture_failed",
                details: ["error": error.localizedDescription]
            )
        }
    }

    private func updateShapeAssessmentFromCamera() {
        guard awaitingAssessment else { return }
        let report = plotterCamera.changeReport
        guard report.sequence > 0 else { return }

        let status: String
        let detail: String
        if report.objectCount == 1 && report.changedCells >= 5 {
            status = "PASS"
            detail = "Single changed region detected"
        } else if report.objectCount > 1 {
            status = "REVIEW"
            detail = "Multiple changed regions detected"
        } else if report.changedCells > 0 {
            status = "WEAK"
            detail = "Small change detected"
        } else {
            status = "WAIT"
            detail = "No new ink region yet"
        }

        shapeAssessment = ShapeAssessmentState(
            status: status,
            detail: detail,
            changedObjects: report.objectCount,
            changedCells: report.changedCells,
            strength: report.strongestTrackStrength
        )

        if status != "WAIT" {
            awaitingAssessment = false
            bridge.recordOperatorEvent(
                "shape_assessment_completed",
                details: [
                    "status": status,
                    "changed_objects": report.objectCount,
                    "changed_cells": report.changedCells,
                    "strength": report.strongestTrackStrength
                ]
            )
        }
    }

    @MainActor
    private func runFrameLearning() async {
        guard bridge.isLiveMotionMode else {
            calibrationStatusText = "CAL cap-marker probe blocked: \(bridge.motionGateMessage)"
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
            calibrationStatusText = "CAL cap-marker probe blocked: bridge offline"
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

        guard bridge.hasPaperLock else {
            calibrationStatusText = "CAL cap-marker probe blocked: paper homography required"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: "Paper homography required",
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }

        guard var initialObservation = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            calibrationStatusText = "CAL cap-marker probe blocked: cap not detected; move X into field"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: "Move X into camera field, then rerun visual calibration",
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            requestXFieldMovePrompt(source: "probe_start_no_cap")
            return
        }
        visualMotionModel = nil
        visualMotionSamples = []
        _ = bridge.resetVisualCalibrationSession(prefix: "swift-probe")
        manualPenMode = false
        manualFiducialMode = false
        manualCapColorMode = false

        calibrationStatusText = "CAL cap-marker probe starting"
        frameLearning = FrameLearningState(
            status: "LEARN",
            detail: "Starting cap-marker visual jog probe",
            sampleCount: 0,
            xPixelsPerMm: 0,
            yPixelsPerMm: 0,
            lastPins: bridge.machinePins
        )

        await bridge.penUpMachine()
        guard !bridge.isMachineAlarm else {
            frameLearning.status = "STOP"
            frameLearning.detail = "Pen-up failed or machine alarm"
            calibrationStatusText = "CAL cap-marker probe stopped: pen-up failed"
            return
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
            calibrationStatusText = "CAL cap-marker probe stopped: bridge cap observation failed"
            return
        }

        if shouldBootstrapFromXMinimum(initialObservation.paperMm) {
            guard let bootstrapped = await bootstrapVisualProbeFromXMinimum(startingAt: initialObservation) else {
                return
            }
            initialObservation = bootstrapped
        }

        guard isGreenCapInsideProbeStartZone(initialObservation.paperMm) else {
            calibrationStatusText = "CAL cap-marker probe blocked: \(greenCapProbeReadinessDetail)"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: greenCapProbeReadinessDetail,
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }
        calibrationStatusText = "CAL cap-marker probe sampling from probe zone"

        let commandDistanceMm = 25.0
        let reinforcementDistanceMm = 40.0
        var samples: [FrameLearningSample] = []

        for axis in ["X", "Y"] {
            let axisStartIndex = samples.count
            for distance in [commandDistanceMm, -commandDistanceMm] {
                guard let sample = await runVisualAxisProbeMove(
                    axis: axis,
                    distanceMm: distance,
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

            let axisSamples = Array(samples[axisStartIndex...])
            let strongSamples = axisSamples.filter {
                $0.observedDistanceMm >= visualProbeMinimumObservedMm
            }
            let weakSamples = axisSamples.filter {
                $0.observedDistanceMm < visualProbeMinimumObservedMm
            }
            if strongSamples.count == 1, weakSamples.count == 1, let strong = strongSamples.first {
                let direction = strong.distanceMm >= 0 ? 1.0 : -1.0
                let distance = reinforcementDistanceMm * direction
                updateLearningSummary(
                    samples: samples,
                    status: "LEARN",
                    detail: String(
                        format: "%@ asymmetric; reinforce %.0f mm",
                        axis,
                        distance
                    )
                )
                calibrationStatusText = String(
                    format: "CAL cap-marker probe: %@ weak %@; trying %.0fmm",
                    axis,
                    weakProbeSampleSummary(samples: weakSamples),
                    distance
                )
                guard let sample = await runVisualAxisProbeMove(
                    axis: axis,
                    distanceMm: distance,
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
            } else if strongSamples.isEmpty {
                updateLearningSummary(
                    samples: samples,
                    status: "WEAK",
                    detail: "\(axis) no visible direction: \(weakProbeSampleSummary(samples: weakSamples))"
                )
                calibrationStatusText = "CAL cap-marker probe weak: \(axis) no visible direction"
                return
            }
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
            calibrationStatusText = "CAL cap-marker probe weak: \(evaluation.detail)"
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
            calibrationStatusText = "CAL cap-marker probe weak: basis solve failed"
            return
        }
        visualMotionSamples = fittedSamples
        visualMotionModel = fittedModel
        updateLearningSummary(
            samples: evaluatedSamples,
            status: "MEASURED",
            detail: String(
                format: "Motion measured rms %.1f max %.1f samples %d; preview target next",
                fittedModel.rmsResidualMm,
                fittedModel.maxResidualMm,
                fittedModel.sampleCount
            )
        )
        calibrationStatusText = "CAL cap-marker probe measured; preview target next"
    }

    @MainActor
    private func runVisualAxisProbeMove(
        axis: String,
        distanceMm: Double,
        sampleIndex: Int
    ) async -> FrameLearningSample? {
        let commandDx = axis == "X" ? distanceMm : 0.0
        let commandDy = axis == "Y" ? distanceMm : 0.0
        let feedMmMin = min(300.0, bridge.manualFeedMmMin)
        var attempt = 0

        while attempt <= visualCapReacquireMaxAttempts {
            guard let before = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
                guard attempt < visualCapReacquireMaxAttempts,
                      let recovered = await reacquireGreenCapByXAxis(
                          afterFrame: plotterCamera.stats.frameNumber,
                          source: "probe_before_move",
                          label: "\(axis)-\(sampleIndex)",
                          preferredDirection: preferredXReacquireDirection(opposingCommandX: commandDx),
                          feedMmMin: min(240.0, bridge.manualFeedMmMin),
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

            guard let response = await bridge.learningJog(
                axis: axis,
                distanceMm: distanceMm,
                feedMmMin: feedMmMin
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Move failed or machine busy"
                calibrationStatusText = "CAL cap-marker probe stopped: move failed"
                return nil
            }

            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
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
                          feedMmMin: min(240.0, bridge.manualFeedMmMin),
                          moveX: { commandMm, feedMmMin in
                              await bridge.learningJog(axis: "X", distanceMm: commandMm, feedMmMin: feedMmMin)
                          }
                      ) else {
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
    private func bootstrapVisualProbeFromXMinimum(
        startingAt start: GreenCapPaperObservation
    ) async -> GreenCapPaperObservation? {
        var current = start
        var totalCommandedMm = 0.0
        var moveIndex = 1
        updateLearningSummary(
            samples: [],
            status: "BOOT-X",
            detail: String(
                format: "X-min bootstrap to paper x%.0fmm",
                visualProbeBootstrapTargetXForWorkspace
            )
        )
        calibrationStatusText = String(
            format: "CAL cap-marker bootstrap +X only from x%.1f",
            current.paperMm.x
        )

        while shouldBootstrapFromXMinimum(current.paperMm) {
            guard isGreenCapInsideBootstrapYBand(current.paperMm) else {
                updateLearningSummary(
                    samples: [],
                    status: "STOP",
                    detail: greenCapProbeReadinessDetail
                )
                calibrationStatusText = "CAL cap-marker bootstrap stopped: \(greenCapProbeReadinessDetail)"
                return nil
            }

            let remainingToTarget = visualProbeBootstrapTargetXForWorkspace - current.paperMm.x
            var maxCommandMm = min(visualProbeBootstrapStepXMm, max(visualProbeBootstrapMinStepXMm, remainingToTarget))
            let remainingBudget = visualProbeBootstrapMaxTotalXMm - totalCommandedMm
            guard remainingBudget >= visualProbeBootstrapMinStepXMm else {
                updateLearningSummary(
                    samples: [],
                    status: "STOP",
                    detail: "X-min bootstrap travel limit reached"
                )
                calibrationStatusText = "CAL cap-marker bootstrap stopped: +X travel limit"
                return nil
            }
            maxCommandMm = min(maxCommandMm, remainingBudget)

            guard await bridge.observeVisualCapForProbe(
                cameraPoint: current.cameraPoint,
                paperMm: current.paperMm,
                confidence: current.strength,
                safeZoneInsetXMm: visualCapSafeZoneMarginMm,
                safeZoneInsetYMm: visualCapSafeZoneMarginMm
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Bridge rejected cap observation"
                calibrationStatusText = "CAL cap-marker bootstrap stopped: bridge cap observation failed"
                return nil
            }

            let requestSuffix = String(format: "%02d", moveIndex)
            guard let preview = await bridge.previewBootstrapAdaptiveProbe(
                requestId: "swift-xmin-bootstrap-preview-\(requestSuffix)",
                safeZoneInsetXMm: visualCapSafeZoneMarginMm,
                safeZoneInsetYMm: visualCapSafeZoneMarginMm,
                maxXProbeMm: maxCommandMm,
                maxYProbeMm: 50.0,
                minProbeMm: visualProbeBootstrapMinStepXMm,
                bootstrapTargetXMm: visualProbeBootstrapTargetXForWorkspace,
                bootstrapBottomAllowanceMm: visualCapProjectionBottomAllowanceMm,
                bootstrapTopAllowanceMm: visualCapProjectionTopAllowanceMm,
                feedMmMin: min(300.0, bridge.manualFeedMmMin)
            ), preview.status == "ready",
               let plan = preview.plan,
               plan.planMode == "x_min_bootstrap",
               let plannedMove = plan.moves.first,
               plan.moves.count == 1,
               plannedMove.axis == "X",
               plannedMove.direction == 1,
               plannedMove.relativeXMm > 0.0,
               abs(plannedMove.relativeYMm) < 0.000_001 else {
                frameLearning.status = "STOP"
                frameLearning.detail = bridge.adaptiveProbeStatus
                calibrationStatusText = "CAL cap-marker bootstrap stopped: bridge did not plan +X bootstrap"
                return nil
            }

            let commandMm = plannedMove.relativeXMm

            calibrationStatusText = String(
                format: "CAL cap-marker bootstrap: move +X %.0f mm",
                commandMm
            )
            frameLearning.detail = String(
                format: "Bootstrap +X %.0fmm (total %.0f/%.0f)",
                commandMm,
                totalCommandedMm + commandMm,
                visualProbeBootstrapMaxTotalXMm
            )

            guard let response = await bridge.runBootstrapAdaptiveProbe(
                requestId: "swift-xmin-bootstrap-run-\(requestSuffix)",
                expectedPlanId: plan.planId,
                safeZoneInsetXMm: visualCapSafeZoneMarginMm,
                safeZoneInsetYMm: visualCapSafeZoneMarginMm,
                maxXProbeMm: maxCommandMm,
                maxYProbeMm: 50.0,
                minProbeMm: visualProbeBootstrapMinStepXMm,
                bootstrapTargetXMm: visualProbeBootstrapTargetXForWorkspace,
                bootstrapBottomAllowanceMm: visualCapProjectionBottomAllowanceMm,
                bootstrapTopAllowanceMm: visualCapProjectionTopAllowanceMm,
                feedMmMin: min(300.0, bridge.manualFeedMmMin)
            ), response.status == "completed" else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Bootstrap move failed or machine busy"
                calibrationStatusText = "CAL cap-marker bootstrap stopped: move failed"
                return nil
            }

            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                frameLearning.status = "STOP"
                frameLearning.detail = "Pin active after bootstrap"
                frameLearning.lastPins = pins
                calibrationStatusText = "CAL cap-marker bootstrap stopped: pin active \(pins)"
                return nil
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let after = await waitForGreenCapPaperObservation(
                afterFrame: current.frameNumber,
                timeoutSeconds: 4.0
            ) else {
                updateLearningSummary(
                    samples: [],
                    status: "STOP",
                    detail: "Cap marker lost after bootstrap"
                )
                calibrationStatusText = "CAL cap-marker bootstrap stopped: cap lost"
                return nil
            }

            let observedDx = after.paperMm.x - current.paperMm.x
            let observedDy = after.paperMm.y - current.paperMm.y
            let observedDistance = hypot(observedDx, observedDy)
            let bootstrapAccepted = observedDx >= visualProbeBootstrapMinProgressXMm
            guard await bridge.observeVisualProbeSample(
                visualProbeSampleRequest(
                    source: "x_min_bootstrap",
                    axis: "X",
                    commandedDxMm: commandMm,
                    commandedDyMm: 0.0,
                    before: current,
                    after: after,
                    requestId: "swift-xmin-bootstrap-run-\(requestSuffix)",
                    planId: plan.planId,
                    commandId: response.commandId,
                    controllerTranscript: response.controllerTranscript,
                    status: bootstrapAccepted ? "accepted" : "rejected",
                    blockers: bootstrapAccepted ? [] : ["X-min bootstrap did not meet minimum positive-X progress."],
                    rejectionReason: bootstrapAccepted ? nil : "bootstrap_min_progress_not_met",
                    sampleIdSuffix: "bootstrap-\(moveIndex)"
                )
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Bridge failed to persist bootstrap evidence"
                calibrationStatusText = "CAL cap-marker bootstrap stopped: evidence persistence failed"
                return nil
            }
            bridge.recordOperatorEvent(
                "visual_motion_probe_bootstrap_sample",
                details: [
                    "move_index": moveIndex,
                    "command_x_mm": commandMm,
                    "total_commanded_x_mm": totalCommandedMm + commandMm,
                    "before_frame": current.frameNumber,
                    "after_frame": after.frameNumber,
                    "before_paper_x_mm": current.paperMm.x,
                    "before_paper_y_mm": current.paperMm.y,
                    "after_paper_x_mm": after.paperMm.x,
                    "after_paper_y_mm": after.paperMm.y,
                    "observed_dx_mm": observedDx,
                    "observed_dy_mm": observedDy,
                    "observed_distance_mm": observedDistance,
                    "strength": min(current.strength, after.strength)
                ]
            )
            guard bootstrapAccepted else {
                updateLearningSummary(
                    samples: [],
                    status: "STOP",
                    detail: String(
                        format: "Bootstrap +X saw dx %.1f dy %.1f",
                        observedDx,
                        observedDy
                    )
                )
                calibrationStatusText = String(
                    format: "CAL cap-marker bootstrap stopped: +X saw dx %.1f dy %.1f",
                    observedDx,
                    observedDy
                )
                return nil
            }

            totalCommandedMm += commandMm
            current = after
            guard await bridge.observeVisualCapForProbe(
                cameraPoint: after.cameraPoint,
                paperMm: after.paperMm,
                confidence: after.strength,
                safeZoneInsetXMm: visualCapSafeZoneMarginMm,
                safeZoneInsetYMm: visualCapSafeZoneMarginMm
            ) else {
                frameLearning.status = "STOP"
                frameLearning.detail = "Bridge rejected post-bootstrap cap observation"
                calibrationStatusText = "CAL cap-marker bootstrap stopped: bridge post-observation failed"
                return nil
            }
            updateLearningSummary(
                samples: [
                    FrameLearningSample(
                        axis: "X",
                        distanceMm: totalCommandedMm,
                        observedDxMm: after.paperMm.x - start.paperMm.x,
                        observedDyMm: after.paperMm.y - start.paperMm.y,
                        observedDistanceMm: hypot(after.paperMm.x - start.paperMm.x, after.paperMm.y - start.paperMm.y),
                        strength: min(start.strength, after.strength)
                    )
                ],
                status: "BOOT-X",
                detail: String(
                    format: "Bootstrap x%.1f observed %.1fmm",
                    current.paperMm.x,
                    observedDistance
                )
            )
            try? await Task.sleep(nanoseconds: 250_000_000)
            moveIndex += 1
        }

        return current
    }

    @MainActor
    private var canMoveXIntoCameraFieldForProbe: Bool {
        bridge.isLiveMotionMode
            && !bridge.isRunning
            && !bridge.isMachineBusy
            && !bridge.isMachineAlarm
    }

    @MainActor
    private func requestXFieldMovePrompt(source: String) {
        bridge.recordOperatorEvent(
            "x_field_recovery_prompted",
            details: [
                "source": source,
                "step_x_mm": visualProbeFieldRecoveryStepXMm,
                "max_total_x_mm": visualProbeFieldRecoveryMaxTotalXMm,
                "can_move": canMoveXIntoCameraFieldForProbe,
                "reason": canMoveXIntoCameraFieldForProbe ? "operator_confirmation_required" : bridge.motionGateMessage
            ]
        )
        guard canMoveXIntoCameraFieldForProbe else { return }
        showXFieldMovePrompt = true
    }

    @MainActor
    private func moveXIntoCameraFieldForProbe(source: String) async {
        guard canMoveXIntoCameraFieldForProbe else {
            calibrationStatusText = "CAL move-X blocked: \(bridge.motionGateMessage)"
            bridge.recordOperatorEvent(
                "x_field_recovery_blocked",
                details: ["source": source, "reason": bridge.motionGateMessage]
            )
            return
        }

        calibrationStatusText = String(
            format: "CAL move-X: live +X up to %.0fmm for camera field",
            visualProbeFieldRecoveryMaxTotalXMm
        )
        frameLearning = FrameLearningState(
            status: "MOVE-X",
            detail: String(
                format: "Live +X chunks %.0f/%.0fmm camera-field recovery",
                visualProbeFieldRecoveryStepXMm,
                visualProbeFieldRecoveryMaxTotalXMm
            ),
            sampleCount: visualMotionSamples.count,
            xPixelsPerMm: visualMotionModel.map { hypot($0.xBasisDx, $0.xBasisDy) } ?? 0,
            yPixelsPerMm: visualMotionModel.map { hypot($0.yBasisDx, $0.yBasisDy) } ?? 0,
            lastPins: bridge.machinePins
        )
        bridge.recordOperatorEvent(
            "x_field_recovery_started",
            details: [
                "source": source,
                "step_x_mm": visualProbeFieldRecoveryStepXMm,
                "max_total_x_mm": visualProbeFieldRecoveryMaxTotalXMm,
                "feed_mm_min": min(240.0, bridge.manualFeedMmMin)
            ]
        )

        var totalCommanded = 0.0
        var moveIndex = 0
        while totalCommanded < visualProbeFieldRecoveryMaxTotalXMm {
            moveIndex += 1
            let commandMm = min(
                visualProbeFieldRecoveryStepXMm,
                visualProbeFieldRecoveryMaxTotalXMm - totalCommanded
            )
            guard commandMm > 0 else { break }

            calibrationStatusText = String(
                format: "CAL move-X: chunk %d +X %.0fmm",
                moveIndex,
                commandMm
            )
            guard let response = await bridge.learningJog(
                axis: "X",
                distanceMm: commandMm,
                feedMmMin: min(240.0, bridge.manualFeedMmMin)
            ) else {
                calibrationStatusText = "CAL move-X stopped: move failed"
                frameLearning.detail = "Move-X recovery failed"
                return
            }

            totalCommanded += commandMm

            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                calibrationStatusText = "CAL move-X stopped: pin active \(pins)"
                frameLearning.lastPins = pins
                return
            }

            try? await Task.sleep(nanoseconds: 450_000_000)
            if let observation = await waitForGreenCapPaperObservation(timeoutSeconds: 2.5) {
                calibrationStatusText = String(
                    format: "CAL move-X done; cap paper x%.1f y%.1f, rerun visual calibration",
                    observation.paperMm.x,
                    observation.paperMm.y
                )
                frameLearning.detail = "Cap visible; rerun visual calibration"
                bridge.recordOperatorEvent(
                    "x_field_recovery_completed",
                    details: [
                        "source": source,
                        "status": response.status,
                        "cap_detected": true,
                        "move_count": moveIndex,
                        "total_commanded_x_mm": totalCommanded,
                        "paper_x_mm": observation.paperMm.x,
                        "paper_y_mm": observation.paperMm.y,
                        "frame": observation.frameNumber
                    ]
                )
                return
            }
        }

        calibrationStatusText = "CAL move-X done; cap still not detected"
        frameLearning.detail = "Move-X complete; cap still not detected"
        bridge.recordOperatorEvent(
            "x_field_recovery_completed",
            details: [
                "source": source,
                "cap_detected": false,
                "move_count": moveIndex,
                "total_commanded_x_mm": totalCommanded
            ]
        )
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
                    x: min(1.0, max(0.0, observation.paperMm.x / max(bridge.workspaceXMm, 0.000_001))),
                    y: min(1.0, max(0.0, observation.paperMm.y / max(bridge.workspaceYMm, 0.000_001)))
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
    private func waitForGreenCapPaperObservation(
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

    private func preferredXReacquireDirection(opposingCommandX commandX: Double) -> Double {
        if commandX > 0.2 { return -1.0 }
        if commandX < -0.2 { return 1.0 }
        return 1.0
    }

    private func visualCapReacquireCommands(firstDirection: Double) -> [Double] {
        let direction = firstDirection < 0 ? -1.0 : 1.0
        let step = min(visualCapReacquireStepXMm, visualProbeFieldRecoveryStepXMm)
        return [
            direction * step,
            direction * step,
            -direction * min(visualProbeFieldRecoveryStepXMm, step * 2.0),
            -direction * min(visualProbeFieldRecoveryStepXMm, step * 2.0)
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
        guard let marker = currentCarriageMarker else { return nil }
        let cameraPoint = CGPoint(
            x: clampDouble(Double(marker.center.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(marker.center.y), min: 0.0, max: 1.0)
        )
        guard let paperMm = bridge.paperPointMm(cameraPoint: cameraPoint) else { return nil }
        return GreenCapPaperObservation(
            frameNumber: marker.id,
            cameraPoint: cameraPoint,
            paperMm: paperMm,
            strength: marker.strength
        )
    }

    private var currentCarriageMarker: CarriageMarker? {
        plotterCamera.stabilizedCarriageMarker ?? plotterCamera.carriageMarker
    }

    private func isGreenCapInsideSafeZone(_ paperMm: PaperPointMmSnapshot) -> Bool {
        paperMm.x >= visualCapSafeZoneMarginMm
            && paperMm.y >= visualCapSafeZoneMarginMm
            && paperMm.x <= bridge.workspaceXMm - visualCapSafeZoneMarginMm
            && paperMm.y <= bridge.workspaceYMm - visualCapSafeZoneMarginMm
    }

    private var visualProbeBootstrapTargetXForWorkspace: Double {
        let safeMaximum = max(visualCapSafeZoneMarginMm, bridge.workspaceXMm - visualCapSafeZoneMarginMm)
        let preferred = min(visualProbeBootstrapTargetXMm, bridge.workspaceXMm * 0.40)
        return clampDouble(
            preferred,
            min: visualCapSafeZoneMarginMm + visualProbeBootstrapMinStepXMm,
            max: safeMaximum
        )
    }

    private func isGreenCapInsideBootstrapYBand(_ paperMm: PaperPointMmSnapshot) -> Bool {
        paperMm.y >= -visualCapProjectionBottomAllowanceMm
            && paperMm.y <= bridge.workspaceYMm + visualCapProjectionTopAllowanceMm
    }

    private func isGreenCapInsideProbeStartZone(_ paperMm: PaperPointMmSnapshot) -> Bool {
        paperMm.x >= visualCapSafeZoneMarginMm
            && paperMm.x <= bridge.workspaceXMm - visualCapSafeZoneMarginMm
            && isGreenCapInsideBootstrapYBand(paperMm)
    }

    private func shouldBootstrapFromXMinimum(_ paperMm: PaperPointMmSnapshot) -> Bool {
        isGreenCapInsideBootstrapYBand(paperMm)
            && paperMm.x < visualProbeBootstrapTargetXForWorkspace - visualProbeBootstrapMinStepXMm
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

    private var canRunVisualCenterDot: Bool {
        bridge.isLiveMotionMode
            && !bridge.hasBridgeContractMismatch
            && bridge.hasPaperLock
            && currentGreenCapSafeZoneReady
            && frameLearning.status == "MEASURED"
            && visualMotionModel?.isUsable == true
            && currentCarriageMarker != nil
            && !bridge.isRunning
            && !bridge.isMachineBusy
            && !bridge.isMachineAlarm
    }

    private var visualCenterDotIsActive: Bool {
        visualCenterDotTaskActive
            || bridge.activeAction == "visual-rel"
            || bridge.activeAction == "dot-mark"
            || bridge.activeAction == "relative-mark"
    }

    private var visualCenterDotDetail: String {
        if visualCenterDotIsActive { return bridge.visualCenterDotStatus }
        if isTerminalVisualCenterDotStatus(bridge.visualCenterDotStatus) { return bridge.visualCenterDotStatus }
        if visualSessionReadyToPlot { return "VisualPositionBinding validated" }
        guard let model = visualMotionModel else { return "Run visual calibration first" }
        if !model.isUsable { return "Motion basis is degenerate" }
        if !currentGreenCapSafeZoneReady { return greenCapSafeZoneDetail }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            return "Preview five binding marks before visual run"
        }
        if currentCarriageMarker == nil { return "Cap marker not detected" }
        return bridge.visualBindingDetail
    }

    private func isTerminalVisualCenterDotStatus(_ status: String) -> Bool {
        status.hasPrefix("VIS RESID")
            || status.hasPrefix("VIS OFF")
            || status == "VIS NO NEW FRAME"
            || status == "VIS NO FINAL"
            || status == "VIS NO VERIFY"
            || status == "VIS CAP LOST"
            || status == "VIS SOLVE FAIL"
            || status == "VIS TINY MOVE"
            || status == "VIS WEAK PRED"
            || status == "VIS SEEK FAIL"
            || status.hasPrefix("VIS BACK")
            || status.hasPrefix("VIS PIN")
    }

    private var visualSessionReadyToPlot: Bool {
        bridge.visualBindingValid
    }

    private var visualSessionBlockerText: String {
        var blockers: [String] = []
        if !bridge.hasPaperLock { blockers.append("paper homography") }
        if !currentGreenCapSafeZoneReady { blockers.append(greenCapSafeZoneDetail) }
        if frameLearning.status != "MEASURED" { blockers.append("adaptive probe") }
        if visualMotionModel?.isUsable != true { blockers.append("visual motion model") }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            blockers.append("five binding mark preview")
        }
        if !bridge.visualBindingValid {
            blockers.append(bridge.visualBindingDetail)
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: ", ")
    }

    private var currentGreenCapSafeZoneReady: Bool {
        guard let observation = currentGreenCapPaperObservation() else { return false }
        return isGreenCapInsideSafeZone(observation.paperMm)
    }

    private var currentGreenCapProbeStartReady: Bool {
        guard let observation = currentGreenCapPaperObservation() else { return false }
        return isGreenCapInsideProbeStartZone(observation.paperMm)
    }

    private var currentGreenCapBootstrapReady: Bool {
        guard let observation = currentGreenCapPaperObservation() else { return false }
        return shouldBootstrapFromXMinimum(observation.paperMm)
    }

    private var currentGreenCapCanStartProbe: Bool {
        guard let observation = currentGreenCapPaperObservation() else { return false }
        return isGreenCapInsideProbeStartZone(observation.paperMm)
            || shouldBootstrapFromXMinimum(observation.paperMm)
    }

    private var confirmedCapSafeZoneReady: Bool {
        guard let paperMm = confirmedCapPoint?.paperMm else { return false }
        return isGreenCapInsideSafeZone(paperMm)
    }

    private var greenCapSafeZoneDetail: String {
        guard bridge.hasPaperLock else { return "Paper homography required" }
        guard let observation = currentGreenCapPaperObservation() else { return "Cap marker not detected" }
        guard isGreenCapInsideSafeZone(observation.paperMm) else {
            return String(
                format: "Cap outside %.0fmm paper safe zone",
                visualCapSafeZoneMarginMm
            )
        }
        return "Cap inside paper safe zone"
    }

    private var greenCapProbeReadinessDetail: String {
        guard bridge.hasPaperLock else { return "Paper homography required" }
        guard let observation = currentGreenCapPaperObservation() else { return "Cap marker not detected" }
        let paperMm = observation.paperMm
        if shouldBootstrapFromXMinimum(paperMm) {
            return String(
                format: "X-min bootstrap ready: +X only from x%.1f toward x%.0f",
                paperMm.x,
                visualProbeBootstrapTargetXForWorkspace
            )
        }
        if isGreenCapInsideSafeZone(paperMm) {
            return "Cap inside paper safe zone"
        }
        if isGreenCapInsideProbeStartZone(paperMm) {
            return String(
                format: "Cap projection is outside drawing inset but inside probe band y %.1f",
                paperMm.y
            )
        }
        if !isGreenCapInsideBootstrapYBand(paperMm) {
            return String(
                format: "Cap projection y %.1f outside probe band %.0f..%.0f",
                paperMm.y,
                -visualCapProjectionBottomAllowanceMm,
                bridge.workspaceYMm + visualCapProjectionTopAllowanceMm
            )
        }
        return String(
            format: "Cap x %.1f outside +X bootstrap/probe range",
            paperMm.x
        )
    }

    private var confirmedCapSafeZoneDetail: String {
        guard bridge.hasPaperLock else { return "Paper homography required" }
        guard let paperMm = confirmedCapPoint?.paperMm else { return "Cap position not observed" }
        guard isGreenCapInsideSafeZone(paperMm) else {
            return String(
                format: "Confirmed cap outside %.0fmm motion-safe inset",
                visualCapSafeZoneMarginMm
            )
        }
        return "Confirmed cap inside motion-safe inset"
    }

    private var canRunWizardMotionProbe: Bool {
        bridge.isLiveMotionMode
            && !bridge.hasBridgeContractMismatch
            && confirmedCapPoint?.paperMm != nil
            && currentCarriageMarker != nil
            && currentGreenCapCanStartProbe
            && !bridge.isMachineBusy
            && !bridge.isRunning
            && !bridge.isMachineAlarm
    }

    @MainActor
    private func runVisualRelativeFivePointTest() async {
        await runVisualRelativeDotTest(pattern: "five")
    }

    @MainActor
    private func runVisualRelativeDotTest(pattern: String) async {
        guard canRunVisualCenterDot else {
            calibrationStatusText = "CAL visual \(pattern) blocked: \(visualCenterDotDetail)"
            bridge.visualCenterDotStatus = "VIS BLOCK"
            return
        }
        guard visualMotionModel?.isUsable == true else {
            calibrationStatusText = "CAL visual \(pattern) blocked: no usable motion basis"
            bridge.visualCenterDotStatus = "VIS NO BASIS"
            return
        }
        visualCenterDotTaskActive = true
        defer {
            visualCenterDotTaskActive = false
        }

        if bridge.dotTestPreviewPattern != pattern || bridge.dotTestPreviewPoints.isEmpty {
            calibrationStatusText = "CAL visual \(pattern) previewing targets"
            guard await bridge.previewDotTestOverlay(pattern: pattern) != nil else {
                bridge.visualCenterDotStatus = "VIS NO PREVIEW"
                calibrationStatusText = "CAL visual \(pattern) blocked: preview failed"
                return
            }
        }

        let targets = bridge.dotTestPreviewPoints.sorted { $0.pointId < $1.pointId }
        guard !targets.isEmpty else {
            calibrationStatusText = "CAL visual \(pattern) blocked: no targets"
            bridge.visualCenterDotStatus = "VIS NO TARGET"
            return
        }

        let bindingCommandId = bridge.dotTestPreviewCommandId
        var visibleCount = 0
        for (index, point) in targets.enumerated() {
            bridge.visualCenterDotStatus = String(format: "VIS %@ %d/%d", point.pointId, index + 1, targets.count)
            guard let final = await approachVisualTarget(
                point.paperMm,
                label: point.pointId,
                targetIndex: index + 1
            ) else {
                return
            }
            let finalDistance = paperDistance(from: final.paperMm, to: point.paperMm)
            guard finalDistance <= 4.0 else {
                bridge.visualCenterDotStatus = String(format: "VIS OFF %.1f", finalDistance)
                calibrationStatusText = String(
                    format: "CAL visual %@ stopped %.1fmm from %@; no mark",
                    pattern,
                    finalDistance,
                    point.pointId
                )
                return
            }

            guard await bridge.relativeMarkCurrentPosition(
                markSizeMm: visualCalibrationMarkSizeMm,
                drawFeedMmMin: min(140.0, bridge.shapeDrawFeedMmMin)
            ) else {
                calibrationStatusText = "CAL visual \(pattern) reached \(point.pointId); mark failed"
                return
            }

            let parked = await parkAwayFromMark(
                markPaperPoint: point.paperMm,
                label: point.pointId
            )
            guard parked else { return }
            let inkResult = await inspectInkAt(point)
            if inkResult?.isVisible == true {
                guard await recordVisualBindingInkObservation(
                    point: point,
                    commandId: bindingCommandId,
                    inkResult: inkResult
                ) else { return }
                visibleCount += 1
                bridge.visualCenterDotStatus = String(format: "VIS %@ OK", point.pointId)
                continue
            }

            calibrationStatusText = "CAL \(point.pointId) weak ink; retrying larger mark"
            guard await approachVisualTarget(point.paperMm, label: "\(point.pointId)-retry", targetIndex: index + 1) != nil else {
                return
            }
            guard await bridge.relativeMarkCurrentPosition(
                markSizeMm: visualCalibrationRetryMarkSizeMm,
                drawFeedMmMin: min(120.0, bridge.shapeDrawFeedMmMin)
            ) else {
                calibrationStatusText = "CAL visual \(pattern) retry mark failed"
                return
            }
            guard await parkAwayFromMark(markPaperPoint: point.paperMm, label: "\(point.pointId)-retry") else {
                return
            }
            let retryInkResult = await inspectInkAt(point)
            if retryInkResult?.isVisible == true {
                guard await recordVisualBindingInkObservation(
                    point: point,
                    commandId: bindingCommandId,
                    inkResult: retryInkResult
                ) else { return }
                visibleCount += 1
                bridge.visualCenterDotStatus = String(format: "VIS %@ OK+", point.pointId)
            } else {
                bridge.visualCenterDotStatus = String(format: "VIS %@ WEAK", point.pointId)
                calibrationStatusText = "CAL visual \(pattern) \(point.pointId) ink still weak after larger mark"
                if pattern == "center" { return }
            }
        }

        bridge.visualCenterDotStatus = String(format: "VIS MARK %d/%d", visibleCount, targets.count)
        let solved = await bridge.solveVisualBinding(requestId: "wizard-binding-\(pattern)")
        calibrationStatusText = solved
            ? String(format: "CAL visual %@ complete; binding validated %d/%d", pattern, visibleCount, targets.count)
            : String(format: "CAL visual %@ complete; ink visible %d/%d; %@", pattern, visibleCount, targets.count, bridge.visualBindingStatus)
    }

    @MainActor
    private func recordVisualBindingInkObservation(
        point: DotTestPreviewPoint,
        commandId: String,
        inkResult: InkInspectionResult?
    ) async -> Bool {
        guard !commandId.isEmpty else {
            calibrationStatusText = "CAL binding observation blocked: preview command missing"
            bridge.visualBindingStatus = "BIND NO CMD"
            bridge.visualBindingDetail = "Preview expected geometry before binding observation"
            return false
        }
        let confidence = min(1.0, max(0.25, inkResult?.darkFraction ?? 0.5))
        guard await bridge.observeVisualBindingPoint(
            commandId: commandId,
            point: point,
            observedPaperMm: point.paperMm,
            observedCameraNorm: point.cameraNorm,
            kind: "ink",
            confidence: confidence
        ) else {
            calibrationStatusText = "CAL binding observation failed: \(bridge.visualBindingDetail)"
            return false
        }
        calibrationStatusText = "CAL binding \(point.pointId) \(bridge.visualBindingStatus)"
        return true
    }

    @MainActor
    private func approachVisualTarget(
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
        let maximumCommandCapMm = 18.0
        let feedMmMin = min(300.0, bridge.manualFeedMmMin)
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

            let rampCommandCapMm = goodSegments >= 2 ? 18.0 : (goodSegments == 1 ? 12.0 : 6.0)
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

            guard let response = await bridge.visualRelativeMove(
                xMm: commandX,
                yMm: commandY,
                feedMmMin: feedMmMin
            ) else {
                calibrationStatusText = "CAL visual target stopped: move failed"
                return nil
            }
            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
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
                          feedMmMin: min(240.0, bridge.manualFeedMmMin),
                          moveX: { commandMm, feedMmMin in
                              await bridge.visualRelativeMove(xMm: commandMm, yMm: 0.0, feedMmMin: feedMmMin)
                          }
                      ) else {
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

        guard let response = await bridge.visualRelativeMove(
            xMm: -commandX,
            yMm: -commandY,
            feedMmMin: feedMmMin
        ) else {
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

    @MainActor
    private func parkAwayFromMark(markPaperPoint: PaperPointMmSnapshot, label: String) async -> Bool {
        guard let current = await waitForGreenCapPaperObservation(timeoutSeconds: 2.0),
              let model = visualMotionModel,
              model.isUsable else {
            bridge.visualCenterDotStatus = "VIS PARK BLOCK"
            calibrationStatusText = "CAL visual \(label) park blocked: no cap/model"
            return false
        }

        let parkDx = markPaperPoint.x + visualCalibrationParkMm <= bridge.workspaceXMm - 2.0
            ? visualCalibrationParkMm
            : -visualCalibrationParkMm
        let parkDy = 0.0
        guard let machineDelta = model.machineDelta(forPaperDx: parkDx, paperDy: parkDy) else {
            bridge.visualCenterDotStatus = "VIS PARK SOLVE"
            calibrationStatusText = "CAL visual \(label) park solve failed"
            return false
        }
        bridge.visualCenterDotStatus = String(format: "VIS PARK %@", label)
        guard await bridge.visualRelativeMove(
            xMm: machineDelta.xMm,
            yMm: machineDelta.yMm,
            feedMmMin: min(300.0, bridge.manualFeedMmMin)
        ) != nil else {
            calibrationStatusText = "CAL visual \(label) park move failed"
            return false
        }
        try? await Task.sleep(nanoseconds: 650_000_000)
        _ = await waitForGreenCapPaperObservation(afterFrame: current.frameNumber, timeoutSeconds: 3.0)
        return true
    }

    @MainActor
    private func inspectInkAt(_ point: DotTestPreviewPoint) async -> InkInspectionResult? {
        try? await Task.sleep(nanoseconds: 300_000_000)
        let cameraPoint = CGPoint(x: point.cameraNorm.x, y: point.cameraNorm.y)
        let result = plotterCamera.inspectInk(cameraPoint: cameraPoint)
        calibrationStatusText = result.map {
            "CAL \(point.pointId) \($0.summary)"
        } ?? "CAL \(point.pointId) ink check unavailable"
        return result
    }

    private func paperDistance(from point: PaperPointMmSnapshot, to target: PaperPointMmSnapshot) -> Double {
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

                CameraLayoutControl(selection: $cameraLayout)

                CameraSelector(camera: plotterCamera)
                    .frame(width: 166)

                CameraSelector(camera: faceCamera)
                    .frame(width: 150)

                controlButton(
                    systemName: "camera.badge.ellipsis",
                    label: "Cameras",
                    help: "Start visible camera streams",
                    isActive: plotterCamera.isRunning && faceCamera.isRunning
                ) {
                    startVisibleCameras()
                }

                plotterConnectionButton

                controlButton(
                    systemName: "rotate.right",
                    label: "Rotate",
                    help: "Rotate plotter camera display by 90 degrees",
                    isActive: plotterViewport.rotationDegrees != 0
                ) {
                    plotterViewport.rotationDegrees = nextQuarterTurn(after: plotterViewport.rotationDegrees)
                }

                controlButton(
                    systemName: plotterViewport.previewMode == .fit ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: plotterViewport.previewMode.title,
                    help: "Toggle plotter camera fit/fill display",
                    isActive: plotterViewport.previewMode == .fit
                ) {
                    plotterViewport.previewMode = plotterViewport.previewMode == .fit ? .fill : .fit
                }

                controlButton(
                    systemName: "checklist.checked",
                    label: "Wizard",
                    help: "Open Calibration Wizard",
                    isActive: showCalibrationWizard || manualFiducialMode
                ) {
                    startCalibrationWizard()
                }

                VisualControlsMenu(
                    plotterCamera: plotterCamera,
                    faceCamera: faceCamera,
                    plotterOverlay: $plotterOverlay,
                    plotterViewport: $plotterViewport,
                    showImageProcessingPanel: $showImageProcessingPanel,
                    reset: resetVisualControls
                )

                DrawVerifyMenu(
                    bridge: bridge,
                    workflowStatusText: $calibrationStatusText,
                    visualMotionActive: visualCenterDotIsActive
                ) {
                    Task {
                        await previewImageFromCurrentFrame()
                    }
                }

                controlButton(
                    systemName: "slider.horizontal.3",
                    label: "Machine",
                    help: "Open machine controls window",
                    isActive: bridge.isOnline
                ) {
                    openWindow(id: "machine-controls")
                }

                topStatusLights
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(plotterCamera.statusText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .frame(minWidth: 210, alignment: .leading)

            Text(faceCamera.statusText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .frame(minWidth: 180, alignment: .leading)

            Divider()
                .frame(height: 24)
                .overlay(Color.white.opacity(0.18))

            Text("BRIDGE \(bridge.bridgeLifecycleStatusLine)  PAPER \(bridge.hasPaperLock ? "LOCK" : "--")  \(plotterViewport.previewMode.title.uppercased()) \(Int(plotterViewport.rotationDegrees))deg \(plotterViewport.zoomLabel)  \(plotterCamera.changeReport.summary)  \(bridge.statusText)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text("\(calibrationStatusText)  FID manual:\(manualFiducials.count)/4  BIND \(bridge.visualBindingStatus)  DRAW \(bridge.drawVerifyStatusLine)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.78))
                .lineLimit(1)
            Text(confirmedCapStatusText)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.78))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
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
            paperDetail: bridge.paperTransformStatus,
            paperStatus: wizardPaperStatus,
            greenCapDetail: wizardGreenCapDetail,
            greenCapStatus: wizardGreenCapStatus,
            capPositionDetail: confirmedCapStatusText,
            capPositionStatus: wizardObservedPenStatus,
            visualCalibrationDetail: frameLearning.detail,
            visualCalibrationStatus: wizardMotionProbeStatus,
            bindingDetail: bridge.visualBindingDetail,
            bindingStatus: wizardDrawPreflightStatus,
            primaryActionTitle: wizardPrimaryActionTitle,
            primaryActionEnabled: wizardPrimaryActionEnabled,
            primaryActionDisabledReason: wizardPrimaryActionDisabledReason,
            manualFiducialCount: manualFiducials.count,
            hasPaperLock: bridge.hasPaperLock,
            capStateLabel: wizardCapStateLabel,
            isLiveMotionMode: bridge.isLiveMotionMode,
            capDetected: currentCarriageMarker != nil,
            canMoveXIntoCameraField: canMoveXIntoCameraFieldForProbe,
            canConfirmSetup: bridge.hasPaperLock,
            primaryAction: runCalibrationWizardPrimaryAction,
            confirmSetup: confirmWizardSetupFromExistingRegistration,
            reset: resetCalibrationWizard,
            clickCap: startManualPenClick,
            pickRegion: startCapColorPick,
            moveXIntoCameraField: { requestXFieldMovePrompt(source: "wizard_button") },
            hide: hideCalibrationWizard
        )
    }

    private var wizardFiducialStatus: CalibrationWizardStepStatus {
        if bridge.hasPaperLock { return .done }
        return manualFiducials.count >= 4 ? .done : .active
    }

    private var wizardPaperStatus: CalibrationWizardStepStatus {
        if bridge.hasPaperLock { return .done }
        return manualFiducials.count >= 4 ? .active : .pending
    }

    private var wizardGreenCapStatus: CalibrationWizardStepStatus {
        if confirmedCapPoint?.paperMm != nil { return .done }
        if currentCarriageMarker != nil { return .done }
        return bridge.hasPaperLock ? .active : .pending
    }

    private var wizardObservedPenStatus: CalibrationWizardStepStatus {
        if confirmedCapPoint?.paperMm != nil { return .done }
        return bridge.hasPaperLock ? .active : .pending
    }

    private var wizardMotionProbeStatus: CalibrationWizardStepStatus {
        if frameLearning.status == "MEASURED" { return .done }
        if confirmedCapPoint?.paperMm != nil {
            return canRunWizardMotionProbe ? .active : .blocked
        }
        return .pending
    }

    private var wizardDrawPreflightStatus: CalibrationWizardStepStatus {
        if visualSessionReadyToPlot { return .done }
        if isTerminalVisualCenterDotStatus(bridge.visualCenterDotStatus) { return .blocked }
        if visualCenterDotIsActive { return .active }
        if canRunVisualCenterDot { return .active }
        return frameLearning.status == "MEASURED" ? .blocked : .pending
    }

    private var wizardFiducialDetail: String {
        if bridge.hasPaperLock && manualFiducials.count < 4 {
            return "Stored paper homography in use"
        }
        if manualFiducials.count >= 4 { return "BL, BR, TR, TL captured" }
        return "Click \(nextFiducialLabel)  \(manualFiducials.count)/4"
    }

    private var wizardGreenCapDetail: String {
        guard let marker = currentCarriageMarker else {
            if confirmedCapPoint?.paperMm != nil {
                return "Manual cap position accepted"
            }
            return "Waiting for bright cap marker"
        }
        return String(format: "%@ cam x%.3f y%.3f %.0f%%", marker.colorName, marker.center.x, marker.center.y, marker.strength * 100)
    }

    private var wizardCapStateLabel: String {
        if currentGreenCapSafeZoneReady { return "LIVE-SAFE" }
        if currentGreenCapBootstrapReady { return "BOOT-X" }
        if currentGreenCapProbeStartReady { return "PROBE" }
        if confirmedCapSafeZoneReady { return "CONF-SAFE" }
        if confirmedCapPoint?.paperMm != nil { return "CONF-OUT" }
        return "--"
    }

    private var wizardInstructionText: String {
        if !bridge.hasPaperLock {
            if manualFiducials.count < 4 {
                return "Click fiducials in order: bottom-left, bottom-right, top-right, top-left."
            }
            return "Fiducials are captured. Solve paper homography to create the paper-mm frame."
        }
        if confirmedCapPoint?.paperMm == nil {
            if currentCarriageMarker == nil {
                return "Stored paper homography is locked. Confirm setup if the grid still aligns, then pick the cap region or click the cap position."
            }
            if currentGreenCapPaperObservation() == nil {
                return "Cap marker is detected but not mapped to paper. Click the cap position or re-solve paper."
            }
            return "Stored paper homography is locked. Confirm setup if the grid still aligns, then confirm the detected carriage cap."
        }
        if frameLearning.status != "MEASURED" {
            if currentCarriageMarker == nil {
                return "Visual calibration needs a live cap marker. If power-off gravity parked X off-camera, move X into the camera field first."
            }
            if currentGreenCapBootstrapReady {
                return "X-min bootstrap will move +X only until the cap reaches the probe zone, then sample X/Y motion."
            }
            if !currentGreenCapCanStartProbe { return greenCapProbeReadinessDetail }
            return "Cap position is in paper mm. Run visual calibration only when the nearby path is clear."
        }
        if visualCenterDotIsActive {
            return "Binding marks are running watched relative motion. Do not start another move."
        }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            return "Adaptive probe is measured. Preview the five binding marks before visual-relative motion."
        }
        if canRunVisualCenterDot {
            return "Run binding marks. The app approaches each expected point, marks only after residuals pass, posts ink observations, and solves the binding."
        }
        if !visualSessionReadyToPlot {
            return "Ready-to-plot blocked: \(visualSessionBlockerText)."
        }
        return "VisualPositionBinding is validated."
    }

    private var wizardPrimaryActionTitle: String {
        if !bridge.hasPaperLock {
            if manualFiducials.count < 4 {
                return manualFiducialMode ? "Click \(nextFiducialLabel)" : "Start Fiducial Clicks"
            }
            return "Solve Homography"
        }
        if confirmedCapPoint?.paperMm == nil {
            return currentGreenCapPaperObservation() == nil ? "Click Cap Position" : "Confirm Cap"
        }
        if frameLearning.status != "MEASURED" { return "Run Visual Calibration" }
        if visualSessionReadyToPlot { return "Ready to Plot" }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty { return "Preview Binding Marks" }
        if canRunVisualCenterDot { return "Run Binding Marks" }
        return "Blocked"
    }

    private var wizardPrimaryActionEnabled: Bool {
        if !bridge.hasPaperLock {
            if manualFiducials.count < 4 { return true }
            return bridge.isOnline && manualFiducials.count >= 4 && !bridge.isCalibrating
        }
        if confirmedCapPoint?.paperMm == nil {
            return true
        }
        if frameLearning.status != "MEASURED" {
            return canRunWizardMotionProbe
        }
        if visualSessionReadyToPlot {
            return false
        }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            return bridge.isOnline && bridge.hasPaperLock && !bridge.isCalibrating
        }
        return canRunVisualCenterDot
    }

    private var wizardPrimaryActionDisabledReason: String? {
        guard !wizardPrimaryActionEnabled else { return nil }
        if !bridge.hasPaperLock {
            if !bridge.isOnline { return "bridge offline" }
            if bridge.isCalibrating { return "paper solve already running" }
            return "paper homography not locked"
        }
        if confirmedCapPoint?.paperMm == nil {
            return "cap position not observed"
        }
        if frameLearning.status != "MEASURED" {
            if !bridge.isLiveMotionMode { return bridge.motionGateMessage }
            if bridge.isMachineAlarm { return "machine alarm" }
            if bridge.isMachineBusy || bridge.isRunning { return "machine busy" }
            if currentCarriageMarker == nil { return "cap marker not detected; move X into field if parked off-camera" }
            if !currentGreenCapCanStartProbe { return greenCapProbeReadinessDetail }
            return "visual calibration blocked"
        }
        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            if !bridge.isOnline { return "bridge offline" }
            if bridge.isCalibrating { return "bridge busy" }
            return "binding mark preview blocked"
        }
        return visualCenterDotDetail
    }

    private var nextFiducialLabel: String {
        switch manualFiducials.count {
        case 0:
            return "FID-BL"
        case 1:
            return "FID-BR"
        case 2:
            return "FID-TR"
        default:
            return "FID-TL"
        }
    }

    private func runCalibrationWizardPrimaryAction() {
        if !bridge.hasPaperLock {
            if manualFiducials.count < 4 {
                startCalibrationWizard()
                return
            }
            solvePaperHomographyFromWizard()
            return
        }

        if confirmedCapPoint?.paperMm == nil {
            if currentGreenCapPaperObservation() != nil {
                useDetectedCarriageMarker()
            } else {
                startManualPenClick()
            }
            return
        }

        if frameLearning.status != "MEASURED" {
            guard canRunWizardMotionProbe else {
                calibrationStatusText = "WIZ visual calibration blocked: \(wizardPrimaryActionDisabledReason ?? greenCapSafeZoneDetail)"
                if currentCarriageMarker == nil, canMoveXIntoCameraFieldForProbe {
                    requestXFieldMovePrompt(source: "wizard_probe_blocked_no_cap")
                }
                return
            }
            calibrationStatusText = "WIZ visual calibration requested"
            Task {
                await runFrameLearning()
            }
            return
        }

        if visualSessionReadyToPlot {
            calibrationStatusText = "WIZ \(bridge.visualBindingStatus)"
            return
        }

        if bridge.dotTestPreviewPattern != "five" || bridge.dotTestPreviewPoints.isEmpty {
            calibrationStatusText = "WIZ preview binding marks"
            Task {
                _ = await bridge.previewDotTestOverlay(pattern: "five")
                await bridge.refreshVisualBindingStatus()
                calibrationStatusText = "WIZ \(bridge.dotTestPreviewStatus)"
            }
            return
        }

        if canRunVisualCenterDot {
            calibrationStatusText = "WIZ binding marks"
            Task {
                await runVisualRelativeFivePointTest()
            }
        }
    }

    private func startCalibrationWizard() {
        showCalibrationWizard = true
        cameraLayout = .plotter
        showLiveVideo = true
        startVisibleCameras()

        if bridge.hasPaperLock {
            manualFiducialMode = false
            manualPenMode = false
            manualCapColorMode = false
            calibrationStatusText = "WIZ paper lock ready; confirm setup if grid aligns"
            return
        }

        if manualFiducials.count < 4 {
            manualFiducialMode = true
            manualPenMode = false
            manualCapColorMode = false
            calibrationStatusText = "WIZ click \(nextFiducialLabel)"
            return
        }

        manualFiducialMode = false
        solvePaperHomographyFromWizard()
    }

    private func confirmWizardSetupFromExistingRegistration() {
        showCalibrationWizard = true
        cameraLayout = .plotter
        showLiveVideo = true
        startVisibleCameras()

        guard bridge.hasPaperLock else {
            calibrationStatusText = "WIZ no stored paper homography; click FID-BL"
            manualFiducialMode = true
            manualPenMode = false
            manualCapColorMode = false
            return
        }

        manualFiducialMode = false
        manualPenMode = false
        manualCapColorMode = false
        calibrationStatusText = "WIZ setup confirmed from stored paper homography"
        bridge.recordOperatorEvent(
            "wizard_setup_confirmed",
            details: [
                "paper_status": bridge.paperTransformStatus,
                "paper_registration_id": bridge.paperRegistrationSnapshot?.registrationId ?? ""
            ]
        )
    }

    private func hideCalibrationWizard() {
        showCalibrationWizard = false
        manualFiducialMode = false
        manualPenMode = false
        manualCapColorMode = false
        calibrationStatusText = "WIZ hidden"
    }

    private func solvePaperHomographyFromWizard() {
        guard manualFiducials.count >= 4 else {
            startCalibrationWizard()
            return
        }
        guard bridge.isOnline else {
            calibrationStatusText = "WIZ connect plotter to solve homography"
            return
        }
        guard !bridge.isCalibrating else { return }

        manualFiducialMode = false
        calibrationStatusText = "WIZ solving paper homography"
        Task {
            _ = await bridge.registerPaperHomography(
                fiducials: manualFiducials,
                paperWidthMm: bridge.workspaceXMm,
                paperHeightMm: bridge.workspaceYMm
            )
            calibrationStatusText = "WIZ \(bridge.paperTransformStatus)"
        }
    }

    private func resetCalibrationWizard() {
        showCalibrationWizard = true
        manualFiducialMode = true
        manualPenMode = false
        manualCapColorMode = false
        manualFiducials = []
        confirmedCapPoint = nil
        visualMotionModel = nil
        visualMotionSamples = []
        visualCenterDotTaskActive = false
        frameLearning = .idle
        _ = bridge.resetVisualCalibrationSession(prefix: "swift-probe")
        calibrationStatusText = "WIZ reset; click FID-BL"
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
                title: "FID",
                value: "\(manualFiducials.count)/4",
                color: fiducialLampColor,
                help: "Manual wizard fiducials"
            )
            StatusLamp(
                title: "PAPER",
                value: paperLampValue,
                color: paperLampColor,
                help: bridge.paperTransformStatus
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

    private var fiducialLampColor: Color {
        manualFiducials.count >= 4 ? .green : .red
    }

    private var paperLampValue: String {
        if bridge.paperTransformStatus.contains("LOCK") { return "LOCK" }
        if bridge.paperTransformStatus.contains("SOLVE") { return "SOLVE" }
        if bridge.paperTransformStatus.contains("ERR") { return "ERR" }
        return "--"
    }

    private var penLampValue: String {
        guard let confirmedCapPoint else { return "--" }
        return confirmedCapPoint.paperMm == nil ? "CAM" : "MM"
    }

    private var penLampColor: Color {
        guard let confirmedCapPoint else { return .white.opacity(0.45) }
        guard let paperMm = confirmedCapPoint.paperMm else { return .yellow }
        return isGreenCapInsideSafeZone(paperMm) ? .green : .red
    }

    private var confirmedCapStatusText: String {
        guard let confirmedCapPoint else { return "Cap position not observed" }
        if let paperMm = confirmedCapPoint.paperMm {
            return String(
                format: "CAP cam x%.3f y%.3f paper x%.1f y%.1f mm %@",
                confirmedCapPoint.cameraPoint.x,
                confirmedCapPoint.cameraPoint.y,
                paperMm.x,
                paperMm.y,
                isGreenCapInsideSafeZone(paperMm) ? "SAFE" : "OUTSIDE"
            )
        }
        return String(
            format: "CAP cam x%.3f y%.3f, no paper homography",
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

    private func recordManualFiducial(viewPoint: CGPoint, cameraPoint: CGPoint) {
        let normalizedView = CGPoint(
            x: clampDouble(Double(viewPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(viewPoint.y), min: 0.0, max: 1.0)
        )
        let normalizedCamera = CGPoint(
            x: clampDouble(Double(cameraPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(cameraPoint.y), min: 0.0, max: 1.0)
        )

        if manualFiducials.count < 4 {
            manualFiducials.append(
                ManualFiducialPoint(
                    id: manualFiducials.count + 1,
                    point: normalizedView,
                    cameraPoint: normalizedCamera
                )
            )
        } else if let nearestIndex = manualFiducials.indices.min(by: { lhs, rhs in
            normalizedDistance(manualFiducials[lhs].point, normalizedView) < normalizedDistance(manualFiducials[rhs].point, normalizedView)
        }) {
            manualFiducials[nearestIndex].point = normalizedView
            manualFiducials[nearestIndex].cameraPoint = normalizedCamera
        }

        calibrationStatusText = String(
            format: "CAL manual fiducial %d/4 cam x%.3f y%.3f",
            manualFiducials.count,
            normalizedCamera.x,
            normalizedCamera.y
        )
        if showCalibrationWizard {
            if manualFiducials.count >= 4 {
                calibrationStatusText = "WIZ fiducials captured"
                solvePaperHomographyFromWizard()
            } else {
                calibrationStatusText = "WIZ click \(nextFiducialLabel)"
            }
        }
    }

    private func startManualPenClick() {
        manualPenMode = true
        manualFiducialMode = false
        manualCapColorMode = false
        confirmedCapPoint = nil
        calibrationStatusText = bridge.hasPaperLock
            ? "WIZ click cap position on plotter view"
            : "WIZ paper homography required before cap click"
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
        manualPenMode = false
        manualFiducialMode = false
        manualCapColorMode = false

        if let paperMm {
            calibrationStatusText = String(
                format: "WIZ %@ cap accepted paper x%.1f y%.1f mm",
                marker.colorName.lowercased(),
                paperMm.x,
                paperMm.y
            )
        } else {
            calibrationStatusText = String(
                format: "WIZ %@ cap cam x%.3f y%.3f; solve homography first",
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

        if let paperMm {
            calibrationStatusText = String(
                format: "CAL cap position observed paper x%.1f y%.1f mm",
                paperMm.x,
                paperMm.y
            )
        } else {
            calibrationStatusText = String(
                format: "CAL cap position observed cam x%.3f y%.3f; lock paper first",
                normalizedCamera.x,
                normalizedCamera.y
            )
        }

        if showCalibrationWizard, paperMm != nil {
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

    private func startVisibleCameras() {
        switch cameraLayout {
        case .both:
            if !plotterCamera.isRunning { plotterCamera.start() }
            if !faceCamera.isRunning { faceCamera.start() }
        case .plotter:
            if !plotterCamera.isRunning { plotterCamera.start() }
        case .face:
            if !faceCamera.isRunning { faceCamera.start() }
        }
    }

    private func resetVisualControls() {
        plotterViewport.videoFilter = .normal
        plotterViewport.resetFOV()
        plotterOverlay.opacity = 0.38
        plotterCamera.showGrid = true
        plotterCamera.showMeasurements = true
        plotterCamera.segmentationEnabled = true
        plotterCamera.changeDetectionEnabled = true
        faceCamera.segmentationEnabled = true
        showImageProcessingPanel = true
        calibrationStatusText = "VIS controls reset"
    }

    private func controlButton(
        systemName: String,
        label: String,
        help: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.9))
                    .frame(width: 32, height: 32)
                    .background(isActive ? Color.cyan : Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(isActive ? 0.0 : 0.18), lineWidth: 1)
                    )
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? Color.cyan.opacity(0.9) : Color.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 52)
            }
            .frame(width: 54)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
