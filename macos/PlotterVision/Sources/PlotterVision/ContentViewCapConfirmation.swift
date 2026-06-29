import CoreGraphics
import Foundation

extension ContentView {
    func startManualPenClick() {
        manualPenMode = true
        manualFiducialMode = false
        manualCapColorMode = false
        confirmedCapPoint = nil
        bridge.learnedCapToTipModel = nil
        bridge.drawableSafeZone = nil
        calibrationStatusText = "FIELD click cap marker on plotter view"
    }

    func startCapColorPick() {
        manualCapColorMode = true
        manualPenMode = false
        manualFiducialMode = false
        confirmedCapPoint = nil
        plotterCamera.clearCarriageMarkerObservation()
        calibrationStatusText = "CAL click the cap color on the plotter view"
    }

    func useDetectedCarriageMarker() {
        guard let marker = currentCarriageMarker else {
            startManualPenClick()
            return
        }
        let cameraPoint = CGPoint(
            x: clampDouble(Double(marker.center.x), min: 0.0, max: 1.0),
            y: clampDouble(Double(marker.center.y), min: 0.0, max: 1.0)
        )
        let approximateViewPoint = CGPoint(x: cameraPoint.x, y: 1.0 - cameraPoint.y)
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
        Task {
            await confirmWorkflowCap(
                cameraPoint: cameraPoint,
                source: "camera_detection",
                confidence: marker.strength
            )
        }

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

    func recordConfirmedCap(viewPoint: CGPoint, cameraPoint: CGPoint) {
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

        if workspace.calibrationWizardActive {
            manualPenMode = false
        }
        Task {
            await confirmWorkflowCap(
                cameraPoint: normalizedCamera,
                source: "manual_click",
                confidence: 1.0
            )
        }
    }

    @MainActor
    func confirmWorkflowCap(
        cameraPoint: CGPoint,
        source: String,
        confidence: Double
    ) async {
        applyPersistedVisualReadiness(
            await bridge.confirmCalibrationCap(
                cameraPoint: cameraPoint,
                source: source,
                confidence: confidence
            )
        )
        refreshSetupSnapshot()
    }

    func recordCapMarkerColor(viewPoint: CGPoint, cameraPoint: CGPoint) {
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

    func resetCapMarkerColor() {
        manualCapColorMode = false
        plotterCamera.resetCapMarkerColorTarget()
        calibrationStatusText = "VIS cap color reset"
    }
}
