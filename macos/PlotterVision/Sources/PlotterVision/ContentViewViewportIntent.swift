import CoreGraphics
import Foundation
import SwiftUI

extension ContentView {
    func togglePlotterFocusMode() {
        if plotterViewport.focusMode == .focused {
            useOriginalPlotterVideo(source: "toolbar")
        } else {
            focusPlotterVideoOnPaper(source: "toolbar")
        }
    }

    func useOriginalPlotterVideo(source: String) {
        plotterViewport.resetFOV()
        bridge.recordOperatorEvent(
            "plotter_viewport_original_selected",
            details: ["source": source]
        )
    }

    func focusPlotterVideoOnPaper(source: String) {
        guard let registration = bridge.paperRegistrationSnapshot,
              let bounds = paperCameraBounds(registration) else {
            plotterViewport.resetFOV()
            calibrationStatusText = "VIEW focus needs visual field"
            bridge.recordOperatorEvent(
                "plotter_viewport_focus_blocked",
                details: ["source": source, "reason": "paper_registration_missing"]
            )
            return
        }
        plotterViewport.focusOnCameraBounds(bounds)
        bridge.recordOperatorEvent(
            "plotter_viewport_focused",
            details: [
                "source": source,
                "registration_id": registration.registrationId,
                "bounds_min_x": Double(bounds.minX),
                "bounds_min_y": Double(bounds.minY),
                "bounds_max_x": Double(bounds.maxX),
                "bounds_max_y": Double(bounds.maxY),
                "zoom_scale": plotterViewport.clampedZoomScale,
                "zoom_center_x": plotterViewport.zoomCenterX,
                "zoom_center_y": plotterViewport.zoomCenterY
            ]
        )
    }

    func setVisualMoveIntent(
        start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot?,
        label: String,
        detail: String
    ) {
        visualMoveIntent = VisualMoveIntent(
            startPaperMm: start,
            endPaperMm: end,
            label: label,
            detail: detail
        )
        var details: [String: Any] = [
            "label": label,
            "detail": detail,
            "start_x_mm": start.x,
            "start_y_mm": start.y,
            "has_projected_end": end != nil
        ]
        if let end {
            details["end_x_mm"] = end.x
            details["end_y_mm"] = end.y
        }
        bridge.recordOperatorEvent(
            "visual_move_intent_set",
            details: details
        )
    }

    func clearVisualMoveIntent(reason: String) {
        guard visualMoveIntent != nil else { return }
        visualMoveIntent = nil
        bridge.recordOperatorEvent("visual_move_intent_cleared", details: ["reason": reason])
    }

    func controlButton(
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

private func paperCameraBounds(_ registration: PaperRegistrationSnapshot) -> CGRect? {
    let corners = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 1.0, y: 0.0),
        CGPoint(x: 1.0, y: 1.0),
        CGPoint(x: 0.0, y: 1.0)
    ].compactMap { paperNorm in
        cameraPointForPaperNorm(paperNorm, registration: registration)
    }
    guard corners.count == 4 else { return nil }
    let minX = corners.map(\.x).min() ?? 0
    let maxX = corners.map(\.x).max() ?? 1
    let minY = corners.map(\.y).min() ?? 0
    let maxY = corners.map(\.y).max() ?? 1
    return CGRect(x: minX, y: minY, width: max(0.0, maxX - minX), height: max(0.0, maxY - minY))
}

private func cameraPointForPaperNorm(
    _ paperNorm: CGPoint,
    registration: PaperRegistrationSnapshot
) -> CGPoint? {
    let coefficients = registration.paperToCamera.coefficients
    guard coefficients.count == 9 else { return nil }
    let x = Double(paperNorm.x)
    let y = Double(paperNorm.y)
    let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
    guard abs(denominator) > 0.000_000_001 else { return nil }
    let cameraX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
    let cameraY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
    guard cameraX >= -0.35, cameraX <= 1.35, cameraY >= -0.35, cameraY <= 1.35 else {
        return nil
    }
    return CGPoint(x: cameraX, y: cameraY)
}
