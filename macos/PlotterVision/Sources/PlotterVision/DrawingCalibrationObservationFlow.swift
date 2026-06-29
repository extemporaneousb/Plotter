import Foundation

extension ContentView {
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
            if bridge.currentDrawingCalibrationBatch?.status == "accepted" {
                await bridge.fitProgressiveDrawingCalibrationSession()
                await bridge.validateProgressiveDrawingCalibrationSession()
                await bridge.finishProgressiveDrawingCalibrationSession()
            }
            _ = await bridge.refreshVisualReadinessStatus()
            refreshSetupSnapshot()
        }
    }
}
