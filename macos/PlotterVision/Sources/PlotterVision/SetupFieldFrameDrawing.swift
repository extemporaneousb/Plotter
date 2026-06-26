import Foundation

extension ContentView {
    @MainActor
    func runValidatedFieldFrameDraw(
        model: VisualMotionModel,
        corners: [PaperPointMmSnapshot]
    ) async {
        guard model.isUsable else {
            calibrationStatusText = "FIELD frame draw blocked: motion model not usable"
            return
        }
        guard let startCorner = corners.first else {
            calibrationStatusText = "BORDER draw blocked: Drawing Border is too small"
            return
        }

        bridge.showSetupFieldFrameExpectedPath(corners: corners)
        bridge.drawVerifyStatus = "DRAW RUN"
        bridge.drawVerifyKind = "setup_field_frame"
        bridge.drawVerifyLabel = "Draw Frame"
        bridge.drawVerifyCommandId = ""
        bridge.drawVerifyPlanHash = ""
        bridge.drawVerifyDetail = "Drawing validated Drawing Border"
        bridge.recordOperatorEvent(
            "setup_field_frame_started",
            details: [
                "field_width_mm": bridge.visualFieldWidthMm,
                "field_height_mm": bridge.visualFieldHeightMm,
                "inset_mm": visualFieldFrameInsetMm,
                "corner_count": corners.count
            ]
        )
        calibrationStatusText = "FIELD moving to frame start"

        guard let startObservation = await approachVisualTarget(startCorner, label: "FRAME START", targetIndex: 1) else {
            bridge.drawVerifyStatus = "DRAW BLOCK"
            bridge.drawVerifyDetail = "Could not move to frame start"
            calibrationStatusText = "FIELD frame draw blocked: could not move to start"
            return
        }

        await bridge.penDownMachine()
        guard !bridge.isMachineAlarm, bridge.shortStatus != "ERR" else {
            bridge.drawVerifyStatus = "DRAW ERR"
            bridge.drawVerifyDetail = "Pen down failed before frame draw"
            calibrationStatusText = "FIELD frame draw stopped: pen down failed"
            await bridge.penUpMachine()
            return
        }

        var current = startObservation.paperMm
        var segmentCount = 0
        let targets = Array(corners.dropFirst()) + [startCorner]
        for (edgeIndex, target) in targets.enumerated() {
            guard let drawn = await drawValidatedFieldFrameEdge(
                from: current,
                to: target,
                edgeIndex: edgeIndex + 1,
                model: model
            ) else {
                await bridge.penUpMachine()
                return
            }
            segmentCount += drawn
            current = target
        }

        await bridge.penUpMachine()
        let status = bridge.isMachineAlarm || bridge.shortStatus == "ERR" ? "ERR" : "DONE"
        bridge.drawVerifyStatus = status == "DONE" ? "DRAW DONE" : "DRAW ERR"
        bridge.drawVerifyDetail = status == "DONE"
            ? "Validated Drawing Border drawn \(segmentCount)s"
            : "Frame draw finished with machine error"
        calibrationStatusText = status == "DONE"
            ? "FIELD frame drawn"
            : "FIELD frame draw ended with machine error"
        bridge.recordOperatorEvent(
            "setup_field_frame_completed",
            details: [
                "status": status,
                "draw_segment_count": segmentCount,
                "field_width_mm": bridge.visualFieldWidthMm,
                "field_height_mm": bridge.visualFieldHeightMm,
                "inset_mm": visualFieldFrameInsetMm
            ]
        )
    }

    @MainActor
    private func drawValidatedFieldFrameEdge(
        from start: PaperPointMmSnapshot,
        to target: PaperPointMmSnapshot,
        edgeIndex: Int,
        model: VisualMotionModel
    ) async -> Int? {
        let paperDx = target.x - start.x
        let paperDy = target.y - start.y
        let paperDistance = hypot(paperDx, paperDy)
        let stepCount = max(1, Int(ceil(paperDistance / visualFieldFrameMaxSegmentMm)))
        let feedMmMin = min(visualMotionTravelFeedMmMin, bridge.manualFeedMmMin)
        var previous = start
        var drawnSegments = 0

        for stepIndex in 1...stepCount {
            let fraction = Double(stepIndex) / Double(stepCount)
            let next = PaperPointMmSnapshot(
                x: start.x + paperDx * fraction,
                y: start.y + paperDy * fraction
            )
            let segmentDx = next.x - previous.x
            let segmentDy = next.y - previous.y
            guard let machineDelta = model.machineDelta(forPaperDx: segmentDx, paperDy: segmentDy) else {
                bridge.drawVerifyStatus = "DRAW ERR"
                bridge.drawVerifyDetail = "Frame edge \(edgeIndex) solve failed"
                calibrationStatusText = "FIELD frame draw stopped: edge solve failed"
                return nil
            }
            let machineDistance = hypot(machineDelta.xMm, machineDelta.yMm)
            guard machineDistance >= 0.001 else {
                previous = next
                continue
            }

            setVisualMoveIntent(
                start: previous,
                end: next,
                label: "FRAME",
                detail: String(format: "edge %d/%d cmd X%+.1f Y%+.1f", edgeIndex, stepIndex, machineDelta.xMm, machineDelta.yMm)
            )
            calibrationStatusText = String(
                format: "FIELD drawing frame edge %d segment %d/%d",
                edgeIndex,
                stepIndex,
                stepCount
            )
            guard let response = await bridge.setupRelativeMove(
                xMm: machineDelta.xMm,
                yMm: machineDelta.yMm,
                feedMmMin: feedMmMin,
                ensurePenUp: false,
                actionLabel: "field-frame"
            ) else {
                clearVisualMoveIntent(reason: "field_frame_move_failed")
                bridge.drawVerifyStatus = "DRAW ERR"
                bridge.drawVerifyDetail = "Frame edge \(edgeIndex) move failed"
                calibrationStatusText = "FIELD frame draw stopped: move failed"
                return nil
            }
            clearVisualMoveIntent(reason: "field_frame_segment_completed")
            if response.status != "completed" {
                bridge.drawVerifyStatus = "DRAW ERR"
                bridge.drawVerifyDetail = "Frame edge \(edgeIndex) \(response.status)"
                calibrationStatusText = "FIELD frame draw stopped: \(response.status)"
                return nil
            }
            if let pins = response.machineStatus?.pins, !pins.isEmpty, pins != "-" {
                bridge.drawVerifyStatus = "DRAW ERR"
                bridge.drawVerifyDetail = "Frame edge \(edgeIndex) pin active \(pins)"
                calibrationStatusText = "FIELD frame draw stopped: pin active \(pins)"
                return nil
            }

            previous = next
            drawnSegments += 1
        }

        return drawnSegments
    }
}
