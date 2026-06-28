import Foundation

extension ContentView {
    func handleProgressiveDrawingCalibrationCommand(_ command: SetupPanelCommand) {
        switch command {
        case .startDrawingSession:
            Task { await bridge.startProgressiveDrawingCalibrationSession(); refreshSetupSnapshot() }
        case .previewDrawingBatch:
            Task { await bridge.previewNextProgressiveDrawingCalibrationBatch(); refreshSetupSnapshot() }
        case .runDrawingBatch:
            Task { await bridge.runProgressiveDrawingCalibrationBatch(); refreshSetupSnapshot() }
        case .observeDrawingBatch:
            observeProgressiveDrawingCalibrationBatch()
        case .fitDrawingSession:
            Task { await bridge.fitProgressiveDrawingCalibrationSession(); refreshSetupSnapshot() }
        case .validateDrawingSession:
            Task { await bridge.validateProgressiveDrawingCalibrationSession(); refreshSetupSnapshot() }
        case .finishDrawingSession:
            Task { await bridge.finishProgressiveDrawingCalibrationSession(); refreshSetupSnapshot() }
        default:
            break
        }
    }

    func observeProgressiveDrawingCalibrationBatch() {
        Task {
            guard let registration = bridge.paperRegistrationSnapshot else {
                await bridge.recordWeakProgressiveDrawingCalibrationObservation(reason: "stale registration")
                refreshSetupSnapshot()
                return
            }
            let primitives = bridge.activeDrawingCalibrationInkPrimitives()
            guard !primitives.isEmpty else {
                await bridge.recordWeakProgressiveDrawingCalibrationObservation(reason: "no planned batch overlay")
                refreshSetupSnapshot()
                return
            }
            guard let result = plotterCamera.inspectInkProgram(
                primitives: primitives,
                registration: registration,
                programId: bridge.currentDrawingCalibrationBatch?.batchId ?? "progressive-drawing-batch",
                programKind: bridge.currentDrawingCalibrationBatch?.programKind ?? "progressive_drawing_calibration_batch"
            ) else {
                await bridge.recordWeakProgressiveDrawingCalibrationObservation(reason: "no frame")
                refreshSetupSnapshot()
                return
            }
            await bridge.recordProgressiveDrawingCalibrationObservation(result)
            refreshSetupSnapshot()
        }
    }
}
