import Foundation

let visualCalibrationMarkSizeMm = 6.0
let visualCalibrationRetryMarkSizeMm = 10.0
let visualCalibrationMaxMarkAttempts = 4
let visualCalibrationMaxMarkSizeMm = 14.0
let visualCalibrationInitialMarkDrawFeedMmMin = 240.0
let visualCalibrationRetryMarkDrawFeedMmMin = 200.0
let visualCalibrationMinimumMarkDrawFeedMmMin = 160.0
let visualCalibrationTravelFeedMmMin = 600.0
let visualCalibrationParkOffsetsMm = [32.0, -32.0, 44.0, -44.0]

extension ContentView {
    @MainActor
    func runVisualBindingPoint(
        pattern: String,
        point: DotTestPreviewPoint,
        index: Int,
        total: Int,
        bindingCommandId: String
    ) async -> Bool {
        var lastInkSummary = "no ink sample"
        for attempt in 1...visualCalibrationMaxMarkAttempts {
            let label = attempt == 1 ? point.pointId : "\(point.pointId)-try\(attempt)"
            let markSizeMm = visualCalibrationMarkSize(forAttempt: attempt)
            let drawFeedMmMin = visualCalibrationMarkDrawFeedMmMin(forAttempt: attempt)
            let parkDxMm = visualCalibrationParkDx(for: point.paperMm, attemptIndex: attempt)
            bridge.visualCenterDotStatus = String(
                format: "VIS %@ TRY %d/%d",
                point.pointId,
                attempt,
                visualCalibrationMaxMarkAttempts
            )
            calibrationStatusText = String(
                format: "CAL visual %@ %@ %d/%d try %d mark %.0fmm park %.0fmm",
                pattern,
                point.pointId,
                index + 1,
                total,
                attempt,
                markSizeMm,
                parkDxMm
            )

            guard let final = await approachVisualTarget(
                point.paperMm,
                label: label,
                targetIndex: index + 1
            ) else {
                recordVisualBindingMarkAttempt(
                    pattern: pattern,
                    point: point,
                    attempt: attempt,
                    accepted: false,
                    reason: "approach_failed",
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    parkDxMm: parkDxMm,
                    inkResult: nil
                )
                return false
            }
            let finalDistance = paperDistance(from: final.paperMm, to: point.paperMm)
            guard finalDistance <= 4.0 else {
                recordVisualBindingMarkAttempt(
                    pattern: pattern,
                    point: point,
                    attempt: attempt,
                    accepted: false,
                    reason: "approach_off_target",
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    parkDxMm: parkDxMm,
                    inkResult: nil,
                    finalDistanceMm: finalDistance
                )
                bridge.visualCenterDotStatus = String(format: "VIS OFF %.1f", finalDistance)
                calibrationStatusText = String(
                    format: "CAL visual %@ %.1fmm from %@; retrying target approach",
                    pattern,
                    finalDistance,
                    point.pointId
                )
                continue
            }

            guard await bridge.relativeMarkCurrentPosition(
                markSizeMm: markSizeMm,
                drawFeedMmMin: drawFeedMmMin
            ) else {
                recordVisualBindingMarkAttempt(
                    pattern: pattern,
                    point: point,
                    attempt: attempt,
                    accepted: false,
                    reason: "mark_failed",
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    parkDxMm: parkDxMm,
                    inkResult: nil,
                    finalDistanceMm: finalDistance
                )
                calibrationStatusText = "CAL visual \(pattern) \(point.pointId) mark failed; retrying"
                continue
            }

            guard await parkAwayFromMark(
                markPaperPoint: point.paperMm,
                label: label,
                attemptIndex: attempt
            ) else {
                recordVisualBindingMarkAttempt(
                    pattern: pattern,
                    point: point,
                    attempt: attempt,
                    accepted: false,
                    reason: "park_failed",
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    parkDxMm: parkDxMm,
                    inkResult: nil,
                    finalDistanceMm: finalDistance
                )
                continue
            }

            let inkResult = await inspectInkAt(point, radiusPx: visualCalibrationInkRadiusPx(forAttempt: attempt))
            let accepted = inkResult?.isVisible == true
            recordVisualBindingMarkAttempt(
                pattern: pattern,
                point: point,
                attempt: attempt,
                accepted: accepted,
                reason: accepted ? "accepted" : "ink_weak",
                markSizeMm: markSizeMm,
                drawFeedMmMin: drawFeedMmMin,
                parkDxMm: parkDxMm,
                inkResult: inkResult,
                finalDistanceMm: finalDistance
            )
            if accepted {
                guard await recordVisualBindingInkObservation(
                    point: point,
                    commandId: bindingCommandId,
                    inkResult: inkResult
                ) else { return false }
                bridge.visualCenterDotStatus = attempt == 1
                    ? String(format: "VIS %@ OK", point.pointId)
                    : String(format: "VIS %@ OK%d", point.pointId, attempt)
                return true
            }

            lastInkSummary = inkResult?.summary ?? "ink check unavailable"
            bridge.visualCenterDotStatus = String(format: "VIS %@ WEAK%d", point.pointId, attempt)
            calibrationStatusText = "CAL \(point.pointId) \(lastInkSummary); retrying away from mark"
        }

        bridge.visualCenterDotStatus = String(format: "VIS %@ MISS", point.pointId)
        calibrationStatusText = "CAL visual \(pattern) \(point.pointId) failed after \(visualCalibrationMaxMarkAttempts) attempts; \(lastInkSummary)"
        return false
    }

    func visualCalibrationMarkSize(forAttempt attempt: Int) -> Double {
        if attempt <= 1 { return visualCalibrationMarkSizeMm }
        let retryGrowthMm = Double(max(0, attempt - 2)) * 2.0
        return min(visualCalibrationMaxMarkSizeMm, visualCalibrationRetryMarkSizeMm + retryGrowthMm)
    }

    func visualCalibrationMarkDrawFeedMmMin(forAttempt attempt: Int) -> Double {
        if attempt <= 1 { return visualCalibrationInitialMarkDrawFeedMmMin }
        let retryFeed = visualCalibrationRetryMarkDrawFeedMmMin - Double(max(0, attempt - 2)) * 20.0
        return max(visualCalibrationMinimumMarkDrawFeedMmMin, retryFeed)
    }

    func visualCalibrationInkRadiusPx(forAttempt attempt: Int) -> Int {
        attempt <= 1 ? 14 : 18
    }

    func visualCalibrationParkDx(for markPaperPoint: PaperPointMmSnapshot, attemptIndex: Int) -> Double {
        let clearanceMm = 2.0
        let requested = visualCalibrationParkOffsetsMm[
            max(0, attemptIndex - 1) % visualCalibrationParkOffsetsMm.count
        ]
        if markPaperPoint.x + requested >= clearanceMm,
           markPaperPoint.x + requested <= bridge.workspaceXMm - clearanceMm {
            return requested
        }

        let opposite = -requested
        if markPaperPoint.x + opposite >= clearanceMm,
           markPaperPoint.x + opposite <= bridge.workspaceXMm - clearanceMm {
            return opposite
        }

        let positiveRoom = max(0.0, bridge.workspaceXMm - clearanceMm - markPaperPoint.x)
        let negativeRoom = max(0.0, markPaperPoint.x - clearanceMm)
        return positiveRoom >= negativeRoom ? min(requested.magnitude, positiveRoom) : -min(requested.magnitude, negativeRoom)
    }

    @MainActor
    func recordVisualBindingMarkAttempt(
        pattern: String,
        point: DotTestPreviewPoint,
        attempt: Int,
        accepted: Bool,
        reason: String,
        markSizeMm: Double,
        drawFeedMmMin: Double,
        parkDxMm: Double,
        inkResult: InkInspectionResult?,
        finalDistanceMm: Double? = nil
    ) {
        var details: [String: Any] = [
            "pattern": pattern,
            "point_id": point.pointId,
            "attempt": attempt,
            "accepted": accepted,
            "reason": reason,
            "mark_size_mm": markSizeMm,
            "draw_feed_mm_min": drawFeedMmMin,
            "park_dx_mm": parkDxMm,
            "expected_paper_x_mm": point.paperMm.x,
            "expected_paper_y_mm": point.paperMm.y
        ]
        if let finalDistanceMm {
            details["final_distance_mm"] = finalDistanceMm
        }
        if let inkResult {
            details["ink_visible"] = inkResult.isVisible
            details["ink_contrast"] = inkResult.contrast
            details["ink_dark_fraction"] = inkResult.darkFraction
            details["ink_horizontal_dark_fraction"] = inkResult.horizontalDarkFraction
            details["ink_vertical_dark_fraction"] = inkResult.verticalDarkFraction
            details["ink_cross_dark_fraction"] = inkResult.crossDarkFraction
            details["ink_summary"] = inkResult.summary
        }
        bridge.recordOperatorEvent("visual_binding_mark_attempt", details: details)
    }
}
