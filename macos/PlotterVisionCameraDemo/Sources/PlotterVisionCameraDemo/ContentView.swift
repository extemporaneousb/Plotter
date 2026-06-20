import SwiftUI

private let visualProbeMinimumObservedMm = 8.0
private let visualCapSafeZoneMarginMm = 8.0
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
    @State private var observedPenPoint: ObservedPenPoint?
    @State private var visualMotionModel: VisualMotionModel?
    @State private var visualMotionSamples: [VisualMotionSample] = []
    @State private var visualCenterDotTaskActive = false

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
        }
        .task {
            await bridge.refreshHealth()
            await bridge.refreshMachineStatus()
            await bridge.refreshPaperStatus()
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
            plotterCamera.stop()
            faceCamera.stop()
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
                        fiducials: plotterCamera.fiducials,
                        carriageMarker: (manualPenMode || manualCapColorMode) ? nil : plotterCamera.carriageMarker,
                        paperRegistration: plotterCamera.paperRegistration,
                        observedPenPoint: observedPenPoint,
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

            ObservedPenOverlay(point: manualPenMode ? observedPenPoint : nil, isActive: manualPenMode)
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
                    onMark: recordObservedPen
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
        }
    }

    @MainActor
    private func previewImageFromCurrentFrame() async {
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
                ? "TEST \(bridge.imagePreviewStatus) \(bridge.imagePreviewDetail)"
                : "TEST \(bridge.imagePreviewStatus)"
        } catch {
            faceCamera.statusText = error.localizedDescription
            bridge.statusText = error.localizedDescription
            bridge.imagePreviewStatus = "IMG ERR"
            bridge.imagePreviewDetail = "VISUAL ONLY"
            bridge.previewStatus = "SIM ERR"
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

        guard let initialObservation = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            calibrationStatusText = "CAL cap-marker probe blocked: cap not detected"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: "Cap marker not detected",
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }
        guard isGreenCapInsideSafeZone(initialObservation.paperMm) else {
            calibrationStatusText = "CAL cap-marker probe blocked: \(greenCapSafeZoneDetail)"
            frameLearning = FrameLearningState(
                status: "BLOCK",
                detail: greenCapSafeZoneDetail,
                sampleCount: 0,
                xPixelsPerMm: 0,
                yPixelsPerMm: 0,
                lastPins: bridge.machinePins
            )
            return
        }

        observedPenPoint = ObservedPenPoint(
            point: CGPoint(x: initialObservation.cameraPoint.x, y: 1.0 - initialObservation.cameraPoint.y),
            cameraPoint: initialObservation.cameraPoint,
            paperMm: initialObservation.paperMm
        )
        visualMotionModel = nil
        visualMotionSamples = []
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
        guard let before = await waitForGreenCapPaperObservation(timeoutSeconds: 3.0) else {
            updateLearningSummary(
                samples: [],
                status: "STOP",
                detail: "Cap marker lost before move"
            )
            calibrationStatusText = "CAL cap-marker probe stopped: cap lost before move"
            return nil
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
            feedMmMin: min(300.0, bridge.manualFeedMmMin)
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
        guard let after = await waitForGreenCapPaperObservation(
            afterFrame: before.frameNumber,
            timeoutSeconds: 4.0
        ) else {
            updateLearningSummary(
                samples: [],
                status: "STOP",
                detail: "Cap marker lost after move"
            )
            calibrationStatusText = "CAL cap-marker probe stopped: cap lost after move"
            return nil
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
        calibrationStatusText = String(
            format: "CAL cap-marker probe: sample %d %@ %.0f observed %.1fmm",
            sampleIndex,
            axis,
            distanceMm,
            observedDistance
        )
        updateObservedPenPoint(after)
        try? await Task.sleep(nanoseconds: 250_000_000)
        return sample
    }

    @MainActor
    private func updateLearningSummary(
        samples: [FrameLearningSample],
        status: String,
        detail: String
    ) {
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
    }

    private func averageObservedMmPerCommandMm(samples: [FrameLearningSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0.0) { partial, sample in
            partial + sample.observedDistanceMm / abs(sample.distanceMm)
        }
        return total / Double(samples.count)
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
        timeoutSeconds: Double
    ) async -> GreenCapPaperObservation? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var latest: GreenCapPaperObservation?
        while Date() < deadline {
            if let observation = currentGreenCapPaperObservation() {
                latest = observation
                if afterFrame == nil || observation.frameNumber > afterFrame! {
                    return observation
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return latest
    }

    @MainActor
    private func currentGreenCapPaperObservation() -> GreenCapPaperObservation? {
        guard let marker = plotterCamera.carriageMarker else { return nil }
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

    private func isGreenCapInsideSafeZone(_ paperMm: PaperPointMmSnapshot) -> Bool {
        paperMm.x >= visualCapSafeZoneMarginMm
            && paperMm.y >= visualCapSafeZoneMarginMm
            && paperMm.x <= bridge.workspaceXMm - visualCapSafeZoneMarginMm
            && paperMm.y <= bridge.workspaceYMm - visualCapSafeZoneMarginMm
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
            && bridge.hasPaperLock
            && currentGreenCapSafeZoneReady
            && frameLearning.status == "MEASURED"
            && visualMotionModel?.isUsable == true
            && plotterCamera.carriageMarker != nil
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
        if visualSessionReadyToPlot { return "Ready to plot in visual session" }
        guard let model = visualMotionModel else { return "Run motion probe first" }
        if !model.isUsable { return "Motion basis is degenerate" }
        if !currentGreenCapSafeZoneReady { return greenCapSafeZoneDetail }
        if bridge.dotTestPreviewPattern != "center" || bridge.dotTestPreviewPoints.isEmpty {
            return "Preview center dot before visual run"
        }
        if plotterCamera.carriageMarker == nil { return "Cap marker not detected" }
        return bridge.visualCenterDotStatus
    }

    private var visualCenterDotMarked: Bool {
        bridge.visualCenterDotStatus == "VIS MARKED"
            || bridge.visualCenterDotStatus.hasPrefix("VIS MARK ")
    }

    private var visualSessionReadyToPlot: Bool {
        bridge.hasPaperLock
            && currentGreenCapSafeZoneReady
            && frameLearning.status == "MEASURED"
            && visualMotionModel?.isUsable == true
            && bridge.dotTestPreviewPattern == "center"
            && !bridge.dotTestPreviewPoints.isEmpty
    }

    private var visualSessionBlockerText: String {
        var blockers: [String] = []
        if !bridge.hasPaperLock { blockers.append("paper homography") }
        if !currentGreenCapSafeZoneReady { blockers.append(greenCapSafeZoneDetail) }
        if frameLearning.status != "MEASURED" { blockers.append("adaptive probe") }
        if visualMotionModel?.isUsable != true { blockers.append("visual motion model") }
        if bridge.dotTestPreviewPattern != "center" || bridge.dotTestPreviewPoints.isEmpty {
            blockers.append("center target preview")
        }
        return blockers.isEmpty ? "none" : blockers.joined(separator: ", ")
    }

    private var currentGreenCapSafeZoneReady: Bool {
        guard let observation = currentGreenCapPaperObservation() else { return false }
        return isGreenCapInsideSafeZone(observation.paperMm)
    }

    private var confirmedCapSafeZoneReady: Bool {
        guard let paperMm = observedPenPoint?.paperMm else { return false }
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

    private var confirmedCapSafeZoneDetail: String {
        guard bridge.hasPaperLock else { return "Paper homography required" }
        guard let paperMm = observedPenPoint?.paperMm else { return "Cap position not observed" }
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
            && observedPenPoint?.paperMm != nil
            && plotterCamera.carriageMarker != nil
            && currentGreenCapSafeZoneReady
            && !bridge.isMachineBusy
            && !bridge.isRunning
            && !bridge.isMachineAlarm
    }

    private var canRunBridgeCenterDotMotion: Bool {
        bridge.canRunCenterDotMotion && currentGreenCapSafeZoneReady
    }

    @MainActor
    private func runVisualRelativeCenterDot() async {
        await runVisualRelativeDotTest(pattern: "center")
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
            if await inspectInkAt(point)?.isVisible == true {
                visibleCount += 1
                bridge.visualCenterDotStatus = String(format: "VIS %@ OK+", point.pointId)
            } else {
                bridge.visualCenterDotStatus = String(format: "VIS %@ WEAK", point.pointId)
                calibrationStatusText = "CAL visual \(pattern) \(point.pointId) ink still weak after larger mark"
                if pattern == "center" { return }
            }
        }

        bridge.visualCenterDotStatus = String(format: "VIS MARK %d/%d", visibleCount, targets.count)
        calibrationStatusText = String(format: "CAL visual %@ complete; ink visible %d/%d", pattern, visibleCount, targets.count)
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

        updateObservedPenPoint(current)
        let targetToleranceMm = 4.0
        let maxSegments = 30
        let feedMmMin = min(300.0, bridge.manualFeedMmMin)
        var goodSegments = 0
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

            let commandCapMm = goodSegments >= 2 ? 18.0 : (goodSegments == 1 ? 12.0 : 6.0)
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
                bridge.visualCenterDotStatus = "VIS NO NEW FRAME"
                calibrationStatusText = "CAL visual target stopped: no new cap observation"
                return nil
            }

            let observedDx = after.paperMm.x - before.paperMm.x
            let observedDy = after.paperMm.y - before.paperMm.y
            let observedDistance = hypot(observedDx, observedDy)
            let residualMm = hypot(observedDx - predicted.dx, observedDy - predicted.dy)
            let residualLimitMm = max(3.5, predictedDistance * 0.45)
            guard observedDistance >= predictedDistance * 0.35, residualMm <= residualLimitMm else {
                bridge.visualCenterDotStatus = String(format: "VIS RESID %.1f", residualMm)
                calibrationStatusText = String(
                    format: "CAL visual target stopped: residual %.1fmm predicted %.1f observed %.1f",
                    residualMm,
                    predictedDistance,
                    observedDistance
                )
                updateObservedPenPoint(after)
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
            current = after
            updateObservedPenPoint(after)
        }

        guard let final = await waitForGreenCapPaperObservation(timeoutSeconds: 2.0) else {
            bridge.visualCenterDotStatus = "VIS NO FINAL"
            calibrationStatusText = "CAL visual target stopped: no final cap observation"
            return nil
        }
        updateObservedPenPoint(final)
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
        if let after = await waitForGreenCapPaperObservation(afterFrame: current.frameNumber, timeoutSeconds: 3.0) {
            updateObservedPenPoint(after)
        }
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

    private func updateObservedPenPoint(_ observation: GreenCapPaperObservation) {
        observedPenPoint = ObservedPenPoint(
            point: CGPoint(x: observation.cameraPoint.x, y: 1.0 - observation.cameraPoint.y),
            cameraPoint: observation.cameraPoint,
            paperMm: observation.paperMm
        )
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
                    Text("Plotter Vision Camera")
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

                visualControlsMenu

                drawingTestsMenu

                calibrationMenu

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

            Text("BRIDGE \(bridge.bridgeLifecycleStatusLine)  PAPER \(bridge.hasPaperLock ? "LOCK" : "--")  \(plotterViewport.previewMode.title.uppercased()) \(Int(plotterViewport.rotationDegrees))deg  \(plotterCamera.changeReport.summary)  \(bridge.statusText)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Text("\(calibrationStatusText)  FID auto:\(plotterCamera.stats.fiducialCount) manual:\(manualFiducials.count)/4")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.78))
                .lineLimit(1)
            Text(observedPenStatusText)
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
        VStack {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.cyan)
                        Text("Calibration Wizard")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button {
                            hideCalibrationWizard()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.72))
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Hide calibration wizard")
                    }

                    Text(wizardInstructionText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 5) {
                        CalibrationWizardStepRow(
                            index: 1,
                            title: "Fiducials",
                            detail: wizardFiducialDetail,
                            status: wizardFiducialStatus
                        )
                        CalibrationWizardStepRow(
                            index: 2,
                            title: "Paper Homography",
                            detail: bridge.paperTransformStatus,
                            status: wizardPaperStatus
                        )
                        CalibrationWizardStepRow(
                            index: 3,
                            title: "Green Cap",
                            detail: wizardGreenCapDetail,
                            status: wizardGreenCapStatus
                        )
                        CalibrationWizardStepRow(
                            index: 4,
                            title: "Cap Position",
                            detail: observedPenStatusText,
                            status: wizardObservedPenStatus
                        )
                        CalibrationWizardStepRow(
                            index: 5,
                            title: "Adaptive Probe",
                            detail: frameLearning.detail,
                            status: wizardMotionProbeStatus
                        )
                        CalibrationWizardStepRow(
                            index: 6,
                            title: "Ready to Plot",
                            detail: visualCenterDotDetail,
                            status: wizardDrawPreflightStatus
                        )
                    }

                    HStack(spacing: 8) {
                        Button {
                            runCalibrationWizardPrimaryAction()
                        } label: {
                            Label(
                                wizardPrimaryActionTitle,
                                systemImage: wizardPrimaryActionEnabled
                                    ? "arrow.right.circle.fill"
                                    : "lock.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(wizardPrimaryActionEnabled ? .cyan : .gray)
                        .disabled(!wizardPrimaryActionEnabled)
                        .help(wizardPrimaryActionDisabledReason ?? wizardPrimaryActionTitle)

                        Button("Reset") {
                            resetCalibrationWizard()
                        }
                        .buttonStyle(.bordered)

                        Button("Click Cap") {
                            startManualPenClick()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!bridge.hasPaperLock)

                        Button("Pick Region") {
                            startCapColorPick()
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)

                    if let disabledReason = wizardPrimaryActionDisabledReason {
                        Text("Blocked: \(disabledReason)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.86))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Label(plotterCamera.carriageMarker == nil ? "cap not detected" : "cap detected", systemImage: "circle.fill")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(plotterCamera.carriageMarker == nil ? .yellow.opacity(0.86) : .green.opacity(0.92))
                        Text(String(format: "FID %d/4  PAPER %@  CAP %@  LIVE %@",
                                    manualFiducials.count,
                                    bridge.hasPaperLock ? "LOCK" : "--",
                                    wizardCapStateLabel,
                                    bridge.isLiveMotionMode ? "YES" : "NO"))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                }
                .frame(width: 390, alignment: .leading)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
            }
            .padding(.top, 84)
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
    }

    private var wizardFiducialStatus: CalibrationWizardStepStatus {
        manualFiducials.count >= 4 ? .done : .active
    }

    private var wizardPaperStatus: CalibrationWizardStepStatus {
        if bridge.hasPaperLock { return .done }
        return manualFiducials.count >= 4 ? .active : .pending
    }

    private var wizardGreenCapStatus: CalibrationWizardStepStatus {
        if observedPenPoint?.paperMm != nil { return .done }
        if plotterCamera.carriageMarker != nil { return .done }
        return bridge.hasPaperLock ? .active : .pending
    }

    private var wizardObservedPenStatus: CalibrationWizardStepStatus {
        if observedPenPoint?.paperMm != nil { return .done }
        return bridge.hasPaperLock ? .active : .pending
    }

    private var wizardMotionProbeStatus: CalibrationWizardStepStatus {
        if frameLearning.status == "MEASURED" { return .done }
        if observedPenPoint?.paperMm != nil {
            return canRunWizardMotionProbe ? .active : .blocked
        }
        return .pending
    }

    private var wizardDrawPreflightStatus: CalibrationWizardStepStatus {
        if visualSessionReadyToPlot || visualCenterDotMarked { return .done }
        if visualCenterDotIsActive { return .active }
        if canRunVisualCenterDot { return .active }
        return frameLearning.status == "MEASURED" ? .blocked : .pending
    }

    private var wizardFiducialDetail: String {
        if manualFiducials.count >= 4 { return "BL, BR, TR, TL captured" }
        return "Click \(nextFiducialLabel)  \(manualFiducials.count)/4"
    }

    private var wizardGreenCapDetail: String {
        guard let marker = plotterCamera.carriageMarker else {
            if observedPenPoint?.paperMm != nil {
                return "Manual cap position accepted"
            }
            return "Waiting for bright cap marker"
        }
        return String(format: "%@ cam x%.3f y%.3f %.0f%%", marker.colorName, marker.center.x, marker.center.y, marker.strength * 100)
    }

    private var wizardCapStateLabel: String {
        if currentGreenCapSafeZoneReady { return "LIVE-SAFE" }
        if confirmedCapSafeZoneReady { return "CONF-SAFE" }
        if observedPenPoint?.paperMm != nil { return "CONF-OUT" }
        return "--"
    }

    private var wizardInstructionText: String {
        if manualFiducials.count < 4 {
            return "Click fiducials in order: bottom-left, bottom-right, top-right, top-left."
        }
        if !bridge.hasPaperLock {
            return "Fiducials are captured. Solve paper homography to create the paper-mm frame."
        }
        if observedPenPoint?.paperMm == nil {
            if plotterCamera.carriageMarker == nil {
                return "Cap marker is not detected. Pick the cap region or click the cap position."
            }
            if currentGreenCapPaperObservation() == nil {
                return "Cap marker is detected but not mapped to paper. Click the cap position or re-solve paper."
            }
            return "Green cap is detected in paper coordinates. Confirm it as the carriage position."
        }
        if frameLearning.status != "MEASURED" {
            if plotterCamera.carriageMarker == nil {
                return "Adaptive probe needs a live cap marker. \(confirmedCapSafeZoneDetail)."
            }
            if !currentGreenCapSafeZoneReady { return greenCapSafeZoneDetail }
            return "Cap position is in paper mm. Run the adaptive probe only when the nearby path is clear."
        }
        if visualCenterDotIsActive {
            return "Visual center dot is running watched relative motion. Do not start another move."
        }
        if bridge.dotTestPreviewPattern != "center" || bridge.dotTestPreviewPoints.isEmpty {
            return "Adaptive probe is measured. Preview the center target overlay before visual-relative motion."
        }
        if canRunVisualCenterDot {
            return "Run visual center dot. It approaches in watched relative segments and marks only after residuals pass."
        }
        if !visualSessionReadyToPlot {
            return "Ready-to-plot blocked: \(visualSessionBlockerText)."
        }
        return "Ready to plot in this visual session. This does not verify absolute bridge-run drawing."
    }

    private var wizardPrimaryActionTitle: String {
        if manualFiducials.count < 4 {
            return manualFiducialMode ? "Click \(nextFiducialLabel)" : "Start Fiducial Clicks"
        }
        if !bridge.hasPaperLock { return "Solve Homography" }
        if observedPenPoint?.paperMm == nil {
            return currentGreenCapPaperObservation() == nil ? "Click Cap Position" : "Confirm Cap"
        }
        if frameLearning.status != "MEASURED" { return "Run Adaptive Probe" }
        if visualSessionReadyToPlot || visualCenterDotMarked { return "Ready to Plot" }
        if bridge.dotTestPreviewPlanHash.isEmpty { return "Preview Center Dot" }
        if canRunVisualCenterDot { return "Run Visual Center Dot" }
        return "Blocked"
    }

    private var wizardPrimaryActionEnabled: Bool {
        if manualFiducials.count < 4 { return true }
        if !bridge.hasPaperLock {
            return bridge.isOnline && manualFiducials.count >= 4 && !bridge.isCalibrating
        }
        if observedPenPoint?.paperMm == nil {
            return true
        }
        if frameLearning.status != "MEASURED" {
            return canRunWizardMotionProbe
        }
        if bridge.dotTestPreviewPlanHash.isEmpty {
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
        if observedPenPoint?.paperMm == nil {
            return "cap position not observed"
        }
        if frameLearning.status != "MEASURED" {
            if !bridge.isLiveMotionMode { return bridge.motionGateMessage }
            if bridge.isMachineAlarm { return "machine alarm" }
            if bridge.isMachineBusy || bridge.isRunning { return "machine busy" }
            if plotterCamera.carriageMarker == nil { return "cap marker not detected for live probe" }
            if !currentGreenCapSafeZoneReady { return greenCapSafeZoneDetail }
            return "adaptive probe blocked"
        }
        if bridge.dotTestPreviewPlanHash.isEmpty {
            if !bridge.isOnline { return "bridge offline" }
            if bridge.isCalibrating { return "bridge busy" }
            return "center preview blocked"
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
        if manualFiducials.count < 4 {
            startCalibrationWizard()
            return
        }

        if !bridge.hasPaperLock {
            solvePaperHomographyFromWizard()
            return
        }

        if observedPenPoint?.paperMm == nil {
            if currentGreenCapPaperObservation() != nil {
                useDetectedCarriageMarker()
            } else {
                startManualPenClick()
            }
            return
        }

        if frameLearning.status != "MEASURED" {
            guard canRunWizardMotionProbe else {
                calibrationStatusText = "WIZ adaptive probe blocked: \(wizardPrimaryActionDisabledReason ?? greenCapSafeZoneDetail)"
                return
            }
            calibrationStatusText = "WIZ motion probe requested"
            Task {
                await runFrameLearning()
            }
            return
        }

        if bridge.dotTestPreviewPlanHash.isEmpty {
            calibrationStatusText = "WIZ preview center dot"
            Task {
                _ = await bridge.previewDotTestOverlay(pattern: "center")
                calibrationStatusText = "WIZ \(bridge.dotTestPreviewStatus)"
            }
            return
        }

        if canRunVisualCenterDot {
            calibrationStatusText = "WIZ visual center dot"
            Task {
                await runVisualRelativeCenterDot()
            }
        }
    }

    private func startCalibrationWizard() {
        showCalibrationWizard = true
        cameraLayout = .plotter
        showLiveVideo = true
        plotterCamera.fiducialDetectionEnabled = true
        startVisibleCameras()

        if manualFiducials.count < 4 {
            manualFiducialMode = true
            manualPenMode = false
            manualCapColorMode = false
            calibrationStatusText = "WIZ click \(nextFiducialLabel)"
            return
        }

        manualFiducialMode = false
        if !bridge.hasPaperLock {
            solvePaperHomographyFromWizard()
            return
        }

        calibrationStatusText = "WIZ paper locked"
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
        observedPenPoint = nil
        visualMotionModel = nil
        visualMotionSamples = []
        visualCenterDotTaskActive = false
        frameLearning = .idle
        bridge.clearDotTestOverlay()
        bridge.visualCenterDotStatus = "VIS --"
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
                value: "\(plotterCamera.stats.fiducialCount)+\(manualFiducials.count)",
                color: fiducialLampColor,
                help: "Detected fiducials plus manually clicked fiducials"
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
                help: observedPenStatusText
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
        if plotterCamera.stats.fiducialCount >= 4 || manualFiducials.count >= 4 {
            return .green
        }
        if plotterCamera.stats.fiducialCount + manualFiducials.count >= 4 {
            return .yellow
        }
        return .red
    }

    private var paperLampValue: String {
        if bridge.paperTransformStatus.contains("LOCK") { return "LOCK" }
        if bridge.paperTransformStatus.contains("SOLVE") { return "SOLVE" }
        if bridge.paperTransformStatus.contains("ERR") { return "ERR" }
        return "--"
    }

    private var penLampValue: String {
        guard let observedPenPoint else { return "--" }
        return observedPenPoint.paperMm == nil ? "CAM" : "MM"
    }

    private var penLampColor: Color {
        guard let observedPenPoint else { return .white.opacity(0.45) }
        guard let paperMm = observedPenPoint.paperMm else { return .yellow }
        return isGreenCapInsideSafeZone(paperMm) ? .green : .red
    }

    private var observedPenStatusText: String {
        guard let observedPenPoint else { return "Cap position not observed" }
        if let paperMm = observedPenPoint.paperMm {
            return String(
                format: "CAP cam x%.3f y%.3f paper x%.1f y%.1f mm %@",
                observedPenPoint.cameraPoint.x,
                observedPenPoint.cameraPoint.y,
                paperMm.x,
                paperMm.y,
                isGreenCapInsideSafeZone(paperMm) ? "SAFE" : "OUTSIDE"
            )
        }
        return String(
            format: "CAP cam x%.3f y%.3f, no paper homography",
            observedPenPoint.cameraPoint.x,
            observedPenPoint.cameraPoint.y
        )
    }

    private var paperLampColor: Color {
        if bridge.paperTransformStatus.contains("LOCK") { return .green }
        if bridge.paperTransformStatus.contains("SOLVE") { return .yellow }
        if bridge.paperTransformStatus.contains("ERR") { return .red }
        return .white.opacity(0.45)
    }

    private var visualControlsMenu: some View {
        Menu {
            Section("Overlays") {
                Toggle("Calibrated Grid", isOn: $plotterCamera.showGrid)
                Toggle("Measurements", isOn: $plotterCamera.showMeasurements)
                Toggle("Fiducials", isOn: $plotterCamera.fiducialDetectionEnabled)
                Toggle("Segmentation", isOn: $plotterCamera.segmentationEnabled)
                Toggle("Motion Detection", isOn: $plotterCamera.changeDetectionEnabled)
                MenuSliderControl(
                    label: "Overlay Alpha",
                    value: $plotterOverlay.opacity,
                    range: 0.05...1.0,
                    step: 0.01,
                    display: String(format: "%.2f", plotterOverlay.opacity)
                )
            }

            Section("Video Filter") {
                Picker("Filter", selection: $plotterViewport.videoFilter) {
                    ForEach(PlotterVideoFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            }

            Section("Image Baseline") {
                Toggle("Face Contours", isOn: $faceCamera.segmentationEnabled)
                Toggle("Image Panel", isOn: $showImageProcessingPanel)
            }

            Section("Reset") {
                Button("Reset Visual Controls") {
                    resetVisualControls()
                }
            }
        } label: {
            toolbarMenuLabel(
                systemName: "slider.horizontal.3",
                label: "Visuals",
                isActive: plotterViewport.videoFilter != .normal
                    || plotterCamera.showGrid
                    || plotterCamera.segmentationEnabled
                    || plotterCamera.changeDetectionEnabled
                    || faceCamera.segmentationEnabled
                    || showImageProcessingPanel
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Visual overlays, calibrated paper grid, and video filters")
    }

    private var drawingTestsMenu: some View {
        Menu {
            Section("Advanced Mark Tests") {
                Button("Preview Center Mark") {
                    calibrationStatusText = "TEST center mark preview"
                    Task {
                        _ = await bridge.previewDotTestOverlay(pattern: "center")
                        calibrationStatusText = "TEST \(bridge.dotTestPreviewStatus)"
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating)

                Button("Run Visual Center Mark") {
                    calibrationStatusText = "TEST visual center mark"
                    Task {
                        await runVisualRelativeCenterDot()
                    }
                }
                .disabled(!canRunVisualCenterDot)

                Button("Preview 5-Point Marks") {
                    calibrationStatusText = "TEST five-point preview"
                    Task {
                        _ = await bridge.previewDotTestOverlay(pattern: "five")
                        calibrationStatusText = "TEST \(bridge.dotTestPreviewStatus)"
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating)

                Button("Run Visual 5-Point Marks") {
                    calibrationStatusText = "TEST visual five-point marks"
                    Task {
                        await runVisualRelativeFivePointTest()
                    }
                }
                .disabled(!canRunVisualCenterDot)
            }

            Section("Advanced Shape Previews") {
                Button("Preview Triangle Overlay") {
                    calibrationStatusText = "TEST triangle preview"
                    Task {
                        if await bridge.previewShapeOverlay(pattern: "triangle") {
                            calibrationStatusText = "TEST \(bridge.previewStatus)"
                        } else {
                            calibrationStatusText = "TEST \(bridge.previewStatus)"
                        }
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating || bridge.isRunning)

                Button("Preview Square Overlay") {
                    calibrationStatusText = "TEST square preview"
                    Task {
                        if await bridge.previewShapeOverlay(pattern: "square") {
                            calibrationStatusText = "TEST \(bridge.previewStatus)"
                        } else {
                            calibrationStatusText = "TEST \(bridge.previewStatus)"
                        }
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating || bridge.isRunning)
            }

            Section("Advanced Image Baseline") {
                Button("Preview Image Contours") {
                    calibrationStatusText = "TEST image contour preview"
                    Task {
                        await previewImageFromCurrentFrame()
                    }
                }
                .disabled(!bridge.isOnline || bridge.isCalibrating || bridge.isRunning || bridge.isMachineBusy)
            }

            Section("Advanced Shape Residuals") {
                Button("Triangle Residual Runner Pending") {
                    calibrationStatusText = "TEST triangle residual runner needs visual-relative execution"
                }
                .disabled(true)
                Button("Square Residual Runner Pending") {
                    calibrationStatusText = "TEST square residual runner needs visual-relative execution"
                }
                .disabled(true)
                Button("Circle Residual Runner Pending") {
                    calibrationStatusText = "TEST circle planner is not implemented yet"
                }
                .disabled(true)
            }

            Section("Overlay") {
                Button("Replay Expected Path") {
                    bridge.replayExpectedPath()
                    calibrationStatusText = "TEST expected path replay"
                }
                .disabled(bridge.expectedPathSegments.isEmpty || !bridge.hasPaperLock)
                Button("Clear Test Overlays") {
                    bridge.clearDotTestOverlay()
                    bridge.expectedPathSegments = []
                    bridge.previewStatus = "SIM --"
                    bridge.imagePreviewStatus = "IMG --"
                    bridge.imagePreviewDetail = "VISUAL ONLY"
                    bridge.imagePreviewContourCount = 0
                    bridge.imagePreviewEligibleForBridgePreview = false
                    calibrationStatusText = "TEST overlays cleared"
                }
                .disabled(
                    bridge.expectedPathSegments.isEmpty
                        && bridge.dotTestPreviewPoints.isEmpty
                        && bridge.dotTestPreviewSegments.isEmpty
                        && bridge.imagePreviewContourCount == 0
                )
            }
        } label: {
            toolbarMenuLabel(
                systemName: "testtube.2",
                label: "Tests",
                isActive: !bridge.expectedPathSegments.isEmpty
                    || !bridge.dotTestPreviewPoints.isEmpty
                    || visualCenterDotIsActive
                    || bridge.imagePreviewContourCount > 0
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Drawing previews and visual mark tests")
    }

    private var calibrationMenu: some View {
        Menu {
            Section("Wizard") {
                Button("Open Calibration Wizard") {
                    startCalibrationWizard()
                }
            }

            Section("Advanced Observation") {
                Button("Scan Plotter Frame") {
                    calibrationStatusText = "CAL scan: analyzing plotter frame"
                    plotterCamera.scanCurrentFrame()
                }
                Button("Reset Change Baseline") {
                    calibrationStatusText = "CAL baseline reset"
                    plotterCamera.resetChangeBaseline()
                }
                Button(plotterCamera.fiducialDetectionEnabled ? "Hide Fiducials" : "Show Fiducials") {
                    plotterCamera.fiducialDetectionEnabled.toggle()
                    calibrationStatusText = plotterCamera.fiducialDetectionEnabled ? "CAL auto fiducials enabled" : "CAL auto fiducials hidden"
                }
            }

            Section("Advanced Fiducials") {
                Button(manualFiducialMode ? "Stop Clicking Fiducials" : "Click Fiducials") {
                    manualFiducialMode.toggle()
                    if manualFiducialMode {
                        manualPenMode = false
                        manualCapColorMode = false
                        calibrationStatusText = "CAL click visible fiducials on plotter view"
                    } else {
                        calibrationStatusText = "CAL manual fiducials stopped"
                    }
                }
                Button("Clear Manual Fiducials") {
                    manualFiducials = []
                    calibrationStatusText = "CAL manual fiducials cleared"
                }
                Button("Register Paper Homography") {
                    calibrationStatusText = "CAL paper homography solving"
                    Task {
                        if await bridge.registerPaperHomography(
                            fiducials: manualFiducials,
                            paperWidthMm: bridge.workspaceXMm,
                            paperHeightMm: bridge.workspaceYMm
                        ) != nil {
                            calibrationStatusText = bridge.paperTransformStatus
                        } else {
                            calibrationStatusText = bridge.paperTransformStatus
                        }
                    }
                }
                .disabled(!bridge.isOnline || manualFiducials.count < 4 || bridge.isCalibrating)
            }

            Section("Advanced Cap/Pen") {
                Button(manualPenMode ? "Stop Clicking Cap/Pen" : "Click Cap/Pen Position") {
                    manualPenMode.toggle()
                    if manualPenMode {
                        manualFiducialMode = false
                        manualCapColorMode = false
                        observedPenPoint = nil
                        calibrationStatusText = bridge.hasPaperLock
                            ? "CAL click cap/pen position on plotter view"
                            : "CAL click cap/pen position; paper homography not locked"
                    } else {
                        calibrationStatusText = "CAL cap/pen click stopped"
                    }
                }
                Button(manualCapColorMode ? "Stop Cap Color Pick" : "Pick Cap Color") {
                    if manualCapColorMode {
                        manualCapColorMode = false
                        calibrationStatusText = "CAL cap color pick stopped"
                    } else {
                        startCapColorPick()
                    }
                }
                Button("Default Green Cap") {
                    manualCapColorMode = false
                    manualPenMode = false
                    observedPenPoint = nil
                    plotterCamera.resetCapMarkerColorTarget()
                    calibrationStatusText = "CAL cap marker reset to default green"
                }
                Button("Clear Cap Position") {
                    observedPenPoint = nil
                    calibrationStatusText = "CAL cap position cleared"
                }
                .disabled(observedPenPoint == nil)
            }

            Section("Advanced Dot Tests") {
                Button("Preview Center Dot Overlay") {
                    calibrationStatusText = "CAL center dot preview"
                    Task {
                        if await bridge.previewDotTestOverlay(pattern: "center") != nil {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        } else {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        }
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating)
                Button("Run Center Dot Motion") {
                    calibrationStatusText = "CAL center dot motion"
                    Task {
                        if await bridge.runCenterDotTestMotion() {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        } else {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        }
                    }
                }
                .disabled(!canRunBridgeCenterDotMotion)
                Button("Run Visual Center Mark") {
                    calibrationStatusText = "CAL visual center dot"
                    Task {
                        await runVisualRelativeCenterDot()
                    }
                }
                .disabled(!canRunVisualCenterDot)
                Button("Preview 5-Point Dot Overlay") {
                    calibrationStatusText = "CAL five-point dot preview"
                    Task {
                        if await bridge.previewDotTestOverlay(pattern: "five") != nil {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        } else {
                            calibrationStatusText = bridge.dotTestPreviewStatus
                        }
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating)
                Button("Run Visual 5-Point Marks") {
                    calibrationStatusText = "CAL visual five-point marks"
                    Task {
                        await runVisualRelativeFivePointTest()
                    }
                }
                .disabled(!canRunVisualCenterDot)
                Button("Clear Dot Test Overlay") {
                    bridge.clearDotTestOverlay()
                    calibrationStatusText = "CAL dot-test overlay cleared"
                }
                .disabled(bridge.dotTestPreviewPoints.isEmpty && bridge.dotTestPreviewSegments.isEmpty)
            }

            Section("Advanced Bridge") {
                Button("Reconnect Bridge") {
                    calibrationStatusText = "CAL bridge reconnecting"
                    Task {
                        await bridge.refreshHealth()
                        await bridge.reconnectMachine()
                        calibrationStatusText = "CAL bridge \(bridge.shortStatus) \(bridge.statusText)"
                    }
                }
                Button("Start Model Session") {
                    calibrationStatusText = "CAL model session starting"
                    Task {
                        await bridge.startMachineModelCalibration()
                        calibrationStatusText = "CAL \(bridge.modelStatus) \(bridge.statusText)"
                    }
                }
                .disabled(!bridge.isOnline || bridge.isRunning || bridge.isMachineBusy)
                Button("Run Adaptive Probe") {
                    calibrationStatusText = "CAL motion probe requested"
                    Task {
                        await runFrameLearning()
                    }
                }
                .disabled(
                    bridge.isRunning
                        || bridge.isMachineBusy
                        || !bridge.isLiveMotionMode
                        || bridge.isMachineAlarm
                        || !currentGreenCapSafeZoneReady
                )
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "scope")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                Text("OPTIONS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: 58)
            }
            .frame(width: 60)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Calibration options and diagnostic actions")
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
        observedPenPoint = nil
        calibrationStatusText = bridge.hasPaperLock
            ? "WIZ click cap position on plotter view"
            : "WIZ paper homography required before cap click"
    }

    private func startCapColorPick() {
        manualCapColorMode = true
        manualPenMode = false
        manualFiducialMode = false
        observedPenPoint = nil
        plotterCamera.clearCarriageMarkerObservation()
        calibrationStatusText = "CAL click the cap color on the plotter view"
    }

    private func useDetectedCarriageMarker() {
        guard let marker = plotterCamera.carriageMarker else {
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
        observedPenPoint = ObservedPenPoint(
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

    private func recordObservedPen(viewPoint: CGPoint, cameraPoint: CGPoint) {
        let normalizedView = CGPoint(
            x: clampDouble(Double(viewPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(viewPoint.y), min: 0.0, max: 1.0)
        )
        let normalizedCamera = CGPoint(
            x: clampDouble(Double(cameraPoint.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(cameraPoint.y), min: 0.0, max: 1.0)
        )
        let paperMm = bridge.paperPointMm(cameraPoint: normalizedCamera)
        observedPenPoint = ObservedPenPoint(
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
        observedPenPoint = nil
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
        plotterOverlay.opacity = 0.38
        plotterCamera.showGrid = true
        plotterCamera.showMeasurements = true
        plotterCamera.fiducialDetectionEnabled = true
        plotterCamera.segmentationEnabled = true
        plotterCamera.changeDetectionEnabled = true
        faceCamera.segmentationEnabled = true
        showImageProcessingPanel = true
        calibrationStatusText = "VIS controls reset"
    }

    private func toolbarMenuLabel(systemName: String, label: String, isActive: Bool) -> some View {
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
                .frame(width: 58)
        }
        .frame(width: 60)
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

private enum CalibrationWizardStepStatus {
    case pending
    case active
    case done
    case blocked

    var label: String {
        switch self {
        case .pending:
            return "--"
        case .active:
            return "DO"
        case .done:
            return "OK"
        case .blocked:
            return "BLOCK"
        }
    }

    var color: Color {
        switch self {
        case .pending:
            return .white.opacity(0.42)
        case .active:
            return .yellow.opacity(0.95)
        case .done:
            return .green.opacity(0.95)
        case .blocked:
            return .red.opacity(0.95)
        }
    }

    var symbolName: String {
        switch self {
        case .pending:
            return "circle"
        case .active:
            return "arrow.right.circle.fill"
        case .done:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct CalibrationWizardStepRow: View {
    let index: Int
    let title: String
    let detail: String
    let status: CalibrationWizardStepStatus

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 18, height: 18)
                .background(status.color, in: Circle())
            Image(systemName: status.symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(status.color)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(status.label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(status.color)
                }
                Text(detail)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }
}

private enum CameraLayoutMode: String, CaseIterable, Identifiable {
    case both
    case plotter
    case face

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both:
            return "Both"
        case .plotter:
            return "Plotter"
        case .face:
            return "Face"
        }
    }

    var icon: String {
        switch self {
        case .both:
            return "rectangle.split.2x1"
        case .plotter:
            return "rectangle.dashed"
        case .face:
            return "person.crop.rectangle"
        }
    }
}

private struct CameraLayoutControl: View {
    @Binding var selection: CameraLayoutMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CameraLayoutMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selection == mode ? Color.black : Color.white.opacity(0.84))
                        .frame(width: 30, height: 30)
                        .background(selection == mode ? Color.cyan : Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Show \(mode.title.lowercased()) camera view")
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct PlotterViewportTransform<Content: View>: View {
    let settings: PlotterViewportSettings
    let content: Content

    init(settings: PlotterViewportSettings, @ViewBuilder content: () -> Content) {
        self.settings = settings
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .rotationEffect(.degrees(settings.rotationDegrees))
                .scaleEffect(rotationFitScale(size: geometry.size, degrees: settings.rotationDegrees))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }
}

private struct ManualFiducialOverlay: View {
    let points: [ManualFiducialPoint]
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty || isActive else { return }

            if isActive {
                let label = Text("CLICK FIDUCIALS \(min(points.count, 4))/4")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.yellow.opacity(0.95))
                context.draw(label, at: CGPoint(x: size.width - 12, y: 14), anchor: .topTrailing)
            }

            for point in points {
                let center = CGPoint(
                    x: point.point.x * size.width,
                    y: point.point.y * size.height
                )
                let color = Color.yellow
                let outer = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
                context.stroke(Path(ellipseIn: outer), with: .color(color.opacity(0.96)), lineWidth: 2.2)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                    with: .color(color.opacity(0.98))
                )

                var cross = Path()
                cross.move(to: CGPoint(x: center.x - 15, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + 15, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - 15))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + 15))
                context.stroke(cross, with: .color(.black.opacity(0.78)), lineWidth: 1.0)

                let label = Text(point.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color.opacity(0.95))
                context.draw(label, at: CGPoint(x: center.x + 12, y: center.y), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ObservedPenOverlay: View {
    let point: ObservedPenPoint?
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            if isActive {
                let label = Text("CLICK CAP POSITION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.96))
                context.draw(label, at: CGPoint(x: size.width - 12, y: 32), anchor: .topTrailing)
            }

            guard let point else { return }

            let center = CGPoint(
                x: point.point.x * size.width,
                y: point.point.y * size.height
            )
            let outer = CGRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50)
            let middle = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
            let inner = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)

            context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.86)), lineWidth: 7.0)
            context.stroke(Path(ellipseIn: middle), with: .color(.green.opacity(0.98)), lineWidth: 4.0)
            context.fill(Path(ellipseIn: inner), with: .color(.white.opacity(0.98)))

            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 35, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 35, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 35))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 35))
            context.stroke(cross, with: .color(.black.opacity(0.82)), lineWidth: 7.0)
            context.stroke(cross, with: .color(.green.opacity(0.98)), lineWidth: 3.2)

            let label = Text(point.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.98))
            context.draw(label, at: CGPoint(x: center.x + 16, y: center.y - 16), anchor: .leading)
        }
        .allowsHitTesting(false)
    }
}

private struct CapColorPickOverlay: View {
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            guard isActive else { return }

            let label = Text("CLICK CAP COLOR")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.96))
            context.draw(label, at: CGPoint(x: size.width - 12, y: 50), anchor: .topTrailing)
        }
        .allowsHitTesting(false)
    }
}

private struct ManualFiducialClickLayer: View {
    let settings: PlotterViewportSettings
    let videoSize: CGSize
    let onMark: (CGPoint, CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let width = max(geometry.size.width, 1)
                            let height = max(geometry.size.height, 1)
                            let viewPoint = CGPoint(
                                x: value.location.x / width,
                                y: value.location.y / height
                            )
                            let cameraPoint = plotterCameraNormFromViewPoint(
                                value.location,
                                viewSize: geometry.size,
                                videoSize: videoSize,
                                settings: settings
                            )
                            onMark(
                                viewPoint,
                                cameraPoint
                            )
                        }
                )
        }
    }
}

private struct ManualPenClickLayer: View {
    let settings: PlotterViewportSettings
    let videoSize: CGSize
    let onMark: (CGPoint, CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let width = max(geometry.size.width, 1)
                            let height = max(geometry.size.height, 1)
                            let viewPoint = CGPoint(
                                x: value.location.x / width,
                                y: value.location.y / height
                            )
                            let cameraPoint = plotterCameraNormFromViewPoint(
                                value.location,
                                viewSize: geometry.size,
                                videoSize: videoSize,
                                settings: settings
                            )
                            onMark(viewPoint, cameraPoint)
                        }
                )
        }
    }
}

private struct CameraPlaceholder: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: camera.role == .plotter ? "rectangle.dashed" : "person.crop.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
            Text(camera.role.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            Text(camera.statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FaceContourOverlay: View {
    let segments: [VisionSegment]
    let videoSize: CGSize
    let previewMode: CameraPreviewMode

    var body: some View {
        Canvas { context, size in
            let displayRect = videoDisplayRect(
                viewSize: size,
                videoSize: videoSize,
                previewMode: previewMode
            )
            for (index, segment) in segments.prefix(80).enumerated() {
                let color = faceContourColor(for: segment.kind, index: index)
                if segment.points.count > 1 {
                    var path = Path()
                    path.move(to: faceOverlayPoint(segment.points[0], displayRect: displayRect))
                    for point in segment.points.dropFirst() {
                        path.addLine(to: faceOverlayPoint(point, displayRect: displayRect))
                    }
                    if segment.points.count > 2 {
                        path.closeSubpath()
                        context.fill(path, with: .color(color.opacity(0.10)))
                    }
                    context.stroke(path, with: .color(.black.opacity(0.68)), lineWidth: 3.4)
                    context.stroke(path, with: .color(color.opacity(0.90)), lineWidth: 1.5)
                }

                let rect = faceOverlayRect(segment.boundingBox, displayRect: displayRect)
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(color.opacity(0.70)),
                    lineWidth: 0.9
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ImageProcessingPanel: View {
    @ObservedObject var bridge: PlotterBridgeModel
    let visualContourCount: Int
    let isBridgeOnline: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text("IMAGE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.74))
                        Text(bridge.imagePreviewStatus)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(String(format: "VIS %dC", visualContourCount))
                        Text(bridge.imagePreviewDetail)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                .frame(minWidth: 158, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            }
            .padding(.top, 68)
            .padding(.horizontal, 18)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var statusColor: Color {
        if !isBridgeOnline { return .gray }
        if bridge.imagePreviewStatus.contains("ERR") { return .red }
        if bridge.imagePreviewEligibleForBridgePreview { return .green }
        return .yellow
    }
}

private struct CameraPaneBadge: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(cameraBadgeColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(camera.role.shortTitle)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                            Text(camera.selectedCameraName)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.64))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(camera.statusText)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 82)
        }
        .allowsHitTesting(false)
    }

    private var cameraBadgeColor: Color {
        if camera.isRunning && camera.isReceivingFrames { return .green }
        if camera.isRunning { return .yellow }
        return .gray
    }
}

private struct CameraSelector: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        Menu {
            Button {
                camera.refreshCameraDevices(reconnect: true)
            } label: {
                Label("Refresh & Reconnect", systemImage: "arrow.clockwise")
            }

            Button {
                camera.reconnectSelectedCamera()
            } label: {
                Label("Reconnect Selected", systemImage: "video.badge.checkmark")
            }

            Divider()

            if camera.availableCameras.isEmpty {
                Text("No cameras")
            } else {
                ForEach(camera.availableCameras) { option in
                    Button {
                        camera.selectCamera(option.id)
                    } label: {
                        Label(
                            option.displayName,
                            systemImage: option.id == camera.selectedCameraID ? "checkmark.circle.fill" : "video"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "video.badge.ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(camera.role.shortTitle)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                    Text(camera.selectedCameraName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Select \(camera.role.title)")
    }
}

private struct StatusLamp: View {
    let title: String
    let value: String
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help)
    }
}

private func faceOverlayPoint(_ normalized: CGPoint, displayRect: CGRect) -> CGPoint {
    CGPoint(
        x: displayRect.minX + normalized.x * displayRect.width,
        y: displayRect.minY + (1.0 - normalized.y) * displayRect.height
    )
}

private func faceOverlayRect(_ normalized: CGRect, displayRect: CGRect) -> CGRect {
    CGRect(
        x: displayRect.minX + normalized.minX * displayRect.width,
        y: displayRect.minY + (1.0 - normalized.maxY) * displayRect.height,
        width: normalized.width * displayRect.width,
        height: normalized.height * displayRect.height
    )
}

private func faceContourColor(for kind: SegmentKind, index: Int) -> Color {
    switch kind {
    case .line:
        return .cyan
    case .shape:
        return .mint
    case .mark:
        return .yellow
    case .contour:
        return index.isMultiple(of: 2) ? .orange : .pink
    }
}

private func plotterCameraNormFromViewPoint(
    _ point: CGPoint,
    viewSize: CGSize,
    videoSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let unrotated = inversePlotterViewportPoint(point, viewSize: viewSize, settings: settings)
    let displayRect = videoDisplayRect(
        viewSize: viewSize,
        videoSize: videoSize,
        previewMode: settings.previewMode
    )
    guard displayRect.width > 0, displayRect.height > 0 else {
        return CGPoint(x: 0.5, y: 0.5)
    }
    let x = (unrotated.x - displayRect.minX) / displayRect.width
    let y = 1.0 - ((unrotated.y - displayRect.minY) / displayRect.height)
    return CGPoint(
        x: clampDouble(Double(x), min: 0.0, max: 1.0),
        y: clampDouble(Double(y), min: 0.0, max: 1.0)
    )
}

private func inversePlotterViewportPoint(
    _ point: CGPoint,
    viewSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    let scale = max(rotationFitScale(size: viewSize, degrees: settings.rotationDegrees), 0.0001)
    let translated = CGPoint(
        x: (point.x - center.x) / scale,
        y: (point.y - center.y) / scale
    )
    let radians = -CGFloat(settings.rotationDegrees) * .pi / 180.0
    let cosTheta = cos(radians)
    let sinTheta = sin(radians)
    return CGPoint(
        x: center.x + translated.x * cosTheta - translated.y * sinTheta,
        y: center.y + translated.x * sinTheta + translated.y * cosTheta
    )
}

private func videoDisplayRect(
    viewSize: CGSize,
    videoSize: CGSize,
    previewMode: CameraPreviewMode
) -> CGRect {
    let sourceSize = videoSize.width > 0 && videoSize.height > 0
        ? videoSize
        : CGSize(width: 1280, height: 720)
    let imageAspect = sourceSize.width / sourceSize.height
    let viewAspect = max(viewSize.width, 1) / max(viewSize.height, 1)
    let displaySize: CGSize
    let offset: CGPoint

    switch previewMode {
    case .fill:
        if viewAspect > imageAspect {
            let width = viewSize.width
            let height = width / imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: 0, y: (viewSize.height - height) / 2)
        } else {
            let height = viewSize.height
            let width = height * imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: (viewSize.width - width) / 2, y: 0)
        }
    case .fit:
        if viewAspect > imageAspect {
            let height = viewSize.height
            let width = height * imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: (viewSize.width - width) / 2, y: 0)
        } else {
            let width = viewSize.width
            let height = width / imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: 0, y: (viewSize.height - height) / 2)
        }
    }

    return CGRect(origin: offset, size: displaySize)
}

private func rotationFitScale(size: CGSize, degrees: Double) -> CGFloat {
    let normalized = Int(abs(degrees).rounded()) % 180
    guard normalized == 90 else { return 1.0 }
    let width = max(size.width, 1)
    let height = max(size.height, 1)
    return min(width / height, height / width)
}

private func nextQuarterTurn(after degrees: Double) -> Double {
    let turns = [0.0, 90.0, 180.0, 270.0]
    let normalized = degrees.truncatingRemainder(dividingBy: 360.0)
    let positive = normalized < 0 ? normalized + 360.0 : normalized
    let currentIndex = turns.enumerated().min { lhs, rhs in
        abs(lhs.element - positive) < abs(rhs.element - positive)
    }?.offset ?? 0
    return turns[(currentIndex + 1) % turns.count]
}

private func clampDouble(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
    Swift.min(maximum, Swift.max(minimum, value))
}

private func normalizedDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private struct PlotterVideoFilterModifier: ViewModifier {
    let filter: PlotterVideoFilter

    @ViewBuilder
    func body(content: Content) -> some View {
        switch filter {
        case .normal:
            content
        case .monochrome:
            content
                .saturation(0.0)
                .contrast(1.18)
        case .highContrast:
            content
                .contrast(1.75)
                .saturation(1.08)
        case .inverted:
            content
                .colorInvert()
                .contrast(1.10)
        case .inkCheck:
            content
                .saturation(0.0)
                .contrast(2.10)
                .brightness(-0.08)
        }
    }
}

private struct MenuSliderControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer(minLength: 8)
                Text(display)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .frame(width: 220)
    }
}
