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
                "corner_count": corners.count,
                "max_jog_mm": bridge.machineMaxJogMm,
                "max_machine_segment_mm": frameMachineSegmentLimitMm()
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
        var completionDetails: [String: Any] = [
            "status": status,
            "draw_segment_count": segmentCount,
            "field_width_mm": bridge.visualFieldWidthMm,
            "field_height_mm": bridge.visualFieldHeightMm,
            "inset_mm": visualFieldFrameInsetMm,
            "model_rms_residual_mm": model.rmsResidualMm,
            "model_max_residual_mm": model.maxResidualMm
        ]
        if status == "DONE" {
            if let residual = await measureValidatedFieldFrameClosureResidual(
                expected: startCorner,
                model: model,
                segmentCount: segmentCount
            ) {
                completionDetails["closure_residual_mm"] = residual
            } else {
                completionDetails["closure_residual_unavailable"] = true
            }
        } else {
            bridge.drawVerifyDetail = "Frame draw finished with machine error"
            calibrationStatusText = "FIELD frame draw ended with machine error"
        }
        bridge.recordOperatorEvent(
            "setup_field_frame_completed",
            details: completionDetails
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
        guard let edgeMachineDelta = model.machineDelta(forPaperDx: paperDx, paperDy: paperDy) else {
            bridge.drawVerifyStatus = "DRAW ERR"
            bridge.drawVerifyDetail = "Frame edge \(edgeIndex) solve failed"
            calibrationStatusText = "FIELD frame draw stopped: edge solve failed"
            return nil
        }
        let machineDistance = hypot(edgeMachineDelta.xMm, edgeMachineDelta.yMm)
        let paperStepCount = Int(ceil(paperDistance / visualFieldFrameMaxSegmentMm))
        let machineStepCount = Int(ceil(machineDistance / frameMachineSegmentLimitMm()))
        let stepCount = max(1, max(paperStepCount, machineStepCount))
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

    @MainActor
    private func frameMachineSegmentLimitMm() -> Double {
        guard bridge.machineMaxJogMm.isFinite, bridge.machineMaxJogMm > 0 else {
            return visualFieldFrameMaxSegmentMm
        }
        return max(1.0, bridge.machineMaxJogMm * 0.80)
    }

    @MainActor
    private func measureValidatedFieldFrameClosureResidual(
        expected: PaperPointMmSnapshot,
        model: VisualMotionModel,
        segmentCount: Int
    ) async -> Double? {
        guard let observed = await waitForGreenCapPaperObservation(timeoutSeconds: 2.0) else {
            bridge.drawVerifyDetail = "Validated Drawing Border drawn \(segmentCount)s; closure residual unavailable"
            calibrationStatusText = "FIELD frame drawn; closure residual unavailable"
            bridge.recordOperatorEvent(
                "setup_field_frame_residual_unavailable",
                details: [
                    "draw_segment_count": segmentCount,
                    "model_rms_residual_mm": model.rmsResidualMm,
                    "model_max_residual_mm": model.maxResidualMm
                ]
            )
            return nil
        }

        let residualMm = paperDistance(from: observed.paperMm, to: expected)
        bridge.drawVerifyDetail = String(
            format: "Validated Drawing Border drawn %ds closure %.1fmm",
            segmentCount,
            residualMm
        )
        calibrationStatusText = String(format: "FIELD frame drawn closure residual %.1fmm", residualMm)
        bridge.recordOperatorEvent(
            "setup_field_frame_residual_measured",
            details: [
                "draw_segment_count": segmentCount,
                "expected_x_mm": expected.x,
                "expected_y_mm": expected.y,
                "observed_x_mm": observed.paperMm.x,
                "observed_y_mm": observed.paperMm.y,
                "closure_residual_mm": residualMm,
                "model_rms_residual_mm": model.rmsResidualMm,
                "model_max_residual_mm": model.maxResidualMm,
                "sample_count": model.sampleCount
            ]
        )
        return residualMm
    }
}
