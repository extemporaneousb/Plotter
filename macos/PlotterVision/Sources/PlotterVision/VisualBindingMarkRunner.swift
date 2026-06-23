import Foundation

let visualBindingMarkSizeMm = 6.0
let visualBindingRetryMarkSizeMm = 10.0
let visualBindingMaxMarkAttempts = 4
let visualBindingMaxMarkSizeMm = 14.0
let visualBindingInitialMarkDrawFeedMmMin = 240.0
let visualBindingRetryMarkDrawFeedMmMin = 200.0
let visualBindingMinimumMarkDrawFeedMmMin = 160.0
let visualMotionTravelFeedMmMin = 1200.0
let visualBindingParkOffsetsMm = [32.0, -32.0, 44.0, -44.0]

struct VisualBindingMarkClearance {
    let canDrawAndPark: Bool
    let blocker: String?
    let xMm: Double?
    let yMm: Double?
    let leftMm: Double?
    let rightMm: Double?
    let bottomMm: Double?
    let topMm: Double?
    let parkTargetXMm: Double?

    var eventPayload: [String: Any] {
        var payload: [String: Any] = [
            "clearance_ok": canDrawAndPark,
            "clearance_blocker": blocker ?? ""
        ]
        if let xMm { payload["machine_x_mm"] = xMm }
        if let yMm { payload["machine_y_mm"] = yMm }
        if let leftMm { payload["clearance_left_mm"] = leftMm }
        if let rightMm { payload["clearance_right_mm"] = rightMm }
        if let bottomMm { payload["clearance_bottom_mm"] = bottomMm }
        if let topMm { payload["clearance_top_mm"] = topMm }
        if let parkTargetXMm { payload["park_target_x_mm"] = parkTargetXMm }
        return payload
    }
}

extension ContentView {
    @MainActor
    func runVisualBindingPoint(
        pattern: String,
        point: BindingMarkPreviewPoint,
        index: Int,
        total: Int,
        bindingCommandId: String
    ) async -> Bool {
        var lastInkSummary = "no ink sample"
        for attempt in 1...visualBindingMaxMarkAttempts {
            let label = attempt == 1 ? point.pointId : "\(point.pointId)-try\(attempt)"
            let markSizeMm = visualBindingMarkSize(forAttempt: attempt)
            let drawFeedMmMin = visualBindingMarkDrawFeedMmMin(forAttempt: attempt)
            let parkDxMm = visualBindingParkDx(for: point.paperMm, attemptIndex: attempt)
            bridge.visualCenterDotStatus = String(
                format: "VIS %@ TRY %d/%d",
                point.pointId,
                attempt,
                visualBindingMaxMarkAttempts
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

            await bridge.refreshMachineStatus()
            let clearance = visualBindingMarkClearance(
                markSizeMm: markSizeMm,
                parkDxMm: parkDxMm
            )
            guard clearance.canDrawAndPark else {
                recordVisualBindingMarkAttempt(
                    pattern: pattern,
                    point: point,
                    attempt: attempt,
                    accepted: false,
                    reason: "clearance_failed",
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    parkDxMm: parkDxMm,
                    inkResult: nil,
                    finalDistanceMm: finalDistance,
                    clearance: clearance
                )
                bridge.visualCenterDotStatus = "VIS CLEARANCE"
                calibrationStatusText = "CAL visual \(pattern) \(point.pointId) clearance blocked: \(clearance.blocker ?? "unknown")"
                return false
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
                    finalDistanceMm: finalDistance,
                    clearance: clearance
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
                    finalDistanceMm: finalDistance,
                    clearance: clearance
                )
                continue
            }

            let inkResult = await inspectInkAt(point, radiusPx: visualBindingInkRadiusPx(forAttempt: attempt))
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
                finalDistanceMm: finalDistance,
                clearance: clearance
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
        calibrationStatusText = "CAL visual \(pattern) \(point.pointId) failed after \(visualBindingMaxMarkAttempts) attempts; \(lastInkSummary)"
        return false
    }

    func visualBindingMarkSize(forAttempt attempt: Int) -> Double {
        if attempt <= 1 { return visualBindingMarkSizeMm }
        let retryGrowthMm = Double(max(0, attempt - 2)) * 2.0
        return min(visualBindingMaxMarkSizeMm, visualBindingRetryMarkSizeMm + retryGrowthMm)
    }

    func visualBindingMarkDrawFeedMmMin(forAttempt attempt: Int) -> Double {
        if attempt <= 1 { return visualBindingInitialMarkDrawFeedMmMin }
        let retryFeed = visualBindingRetryMarkDrawFeedMmMin - Double(max(0, attempt - 2)) * 20.0
        return max(visualBindingMinimumMarkDrawFeedMmMin, retryFeed)
    }

    func visualBindingInkRadiusPx(forAttempt attempt: Int) -> Int {
        attempt <= 1 ? 14 : 18
    }

    func visualBindingParkDx(for markPaperPoint: PaperPointMmSnapshot, attemptIndex: Int) -> Double {
        let clearanceMm = 2.0
        let requested = visualBindingParkOffsetsMm[
            max(0, attemptIndex - 1) % visualBindingParkOffsetsMm.count
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

    func visualBindingMarkClearance(markSizeMm: Double, parkDxMm: Double) -> VisualBindingMarkClearance {
        guard bridge.machineMPosMm.count >= 2 else {
            return VisualBindingMarkClearance(
                canDrawAndPark: false,
                blocker: "machine position unavailable",
                xMm: nil,
                yMm: nil,
                leftMm: nil,
                rightMm: nil,
                bottomMm: nil,
                topMm: nil,
                parkTargetXMm: nil
            )
        }
        let xMm = bridge.machineMPosMm[0]
        let yMm = bridge.machineMPosMm[1]
        let half = max(0.0, markSizeMm / 2.0)
        let left = xMm - half
        let right = bridge.workspaceXMm - xMm - half
        let bottom = yMm - half
        let top = bridge.workspaceYMm - yMm - half
        let parkTargetX = xMm + parkDxMm
        var blockers: [String] = []
        if left < 0 { blockers.append(String(format: "mark exceeds X- by %.1fmm", -left)) }
        if right < 0 { blockers.append(String(format: "mark exceeds X+ by %.1fmm", -right)) }
        if bottom < 0 { blockers.append(String(format: "mark exceeds Y- by %.1fmm", -bottom)) }
        if top < 0 { blockers.append(String(format: "mark exceeds Y+ by %.1fmm", -top)) }
        if parkTargetX < 2.0 || parkTargetX > bridge.workspaceXMm - 2.0 {
            blockers.append(String(format: "park target X %.1f outside clearance", parkTargetX))
        }
        return VisualBindingMarkClearance(
            canDrawAndPark: blockers.isEmpty,
            blocker: blockers.isEmpty ? nil : blockers.joined(separator: "; "),
            xMm: xMm,
            yMm: yMm,
            leftMm: left,
            rightMm: right,
            bottomMm: bottom,
            topMm: top,
            parkTargetXMm: parkTargetX
        )
    }

    @MainActor
    func recordVisualBindingMarkAttempt(
        pattern: String,
        point: BindingMarkPreviewPoint,
        attempt: Int,
        accepted: Bool,
        reason: String,
        markSizeMm: Double,
        drawFeedMmMin: Double,
        parkDxMm: Double,
        inkResult: InkInspectionResult?,
        finalDistanceMm: Double? = nil,
        clearance: VisualBindingMarkClearance? = nil
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
        if let clearance {
            details.merge(clearance.eventPayload) { current, _ in current }
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
