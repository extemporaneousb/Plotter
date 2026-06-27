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
            if let inkGeometry = await measureValidatedFieldFrameInkGeometry(
                expectedCorners: corners,
                model: model,
                segmentCount: segmentCount
            ) {
                completionDetails["ink_edges_detected"] = inkGeometry.detectedEdgeCount
                completionDetails["ink_green_pixels"] = inkGeometry.totalGreenPixels
                completionDetails["ink_geometry_usable"] = inkGeometry.isUsable
                if let rmsResidual = inkGeometry.rmsResidualMm {
                    completionDetails["ink_rms_residual_mm"] = rmsResidual
                }
                if let maxResidual = inkGeometry.maxResidualMm {
                    completionDetails["ink_max_residual_mm"] = maxResidual
                }
                if let cornerRmsResidual = inkGeometry.cornerRmsResidualMm {
                    completionDetails["ink_corner_rms_residual_mm"] = cornerRmsResidual
                }
            } else {
                completionDetails["ink_geometry_unavailable"] = true
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

    @MainActor
    private func measureValidatedFieldFrameInkGeometry(
        expectedCorners: [PaperPointMmSnapshot],
        model: VisualMotionModel,
        segmentCount: Int
    ) async -> DrawnFrameInspectionResult? {
        guard let registration = bridge.paperRegistrationSnapshot else {
            recordValidatedFieldFrameInkGeometryUnavailable(
                reason: "missing_paper_registration",
                segmentCount: segmentCount,
                model: model
            )
            return nil
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        guard let result = plotterCamera.inspectGreenFrameGeometry(
            expectedCorners: expectedCorners,
            registration: registration
        ) else {
            recordValidatedFieldFrameInkGeometryUnavailable(
                reason: "no_frame_geometry",
                segmentCount: segmentCount,
                model: model
            )
            return nil
        }

        var details = validatedFieldFrameInkGeometryDetails(
            result,
            segmentCount: segmentCount,
            model: model
        )
        let eventName = result.isUsable
            ? "setup_field_frame_ink_geometry_measured"
            : "setup_field_frame_ink_geometry_weak"
        if !result.isUsable {
            details["weak_reason"] = "insufficient_detected_edges"
        }
        bridge.recordOperatorEvent(eventName, details: details)

        if result.isUsable, let rmsResidual = result.rmsResidualMm, let maxResidual = result.maxResidualMm {
            bridge.drawVerifyDetail = String(
                format: "Frame drawn %ds ink %.1f/%.1fmm %@",
                segmentCount,
                rmsResidual,
                maxResidual,
                result.detectedEdgeCount == 4 ? "4 edges" : "\(result.detectedEdgeCount)/4 edges"
            )
            calibrationStatusText = String(format: "FIELD frame ink residual %.1fmm", rmsResidual)
        } else {
            bridge.drawVerifyDetail = "Frame drawn \(segmentCount)s; ink geometry weak \(result.detectedEdgeCount)/4 edges"
            calibrationStatusText = "FIELD frame ink geometry weak"
        }

        return result
    }

    @MainActor
    private func recordValidatedFieldFrameInkGeometryUnavailable(
        reason: String,
        segmentCount: Int,
        model: VisualMotionModel
    ) {
        bridge.recordOperatorEvent(
            "setup_field_frame_ink_geometry_unavailable",
            details: [
                "reason": reason,
                "draw_segment_count": segmentCount,
                "model_rms_residual_mm": model.rmsResidualMm,
                "model_max_residual_mm": model.maxResidualMm
            ]
        )
    }

    @MainActor
    private func validatedFieldFrameInkGeometryDetails(
        _ result: DrawnFrameInspectionResult,
        segmentCount: Int,
        model: VisualMotionModel
    ) -> [String: Any] {
        var details: [String: Any] = [
            "draw_segment_count": segmentCount,
            "image_width_px": Int(result.imageSize.width),
            "image_height_px": Int(result.imageSize.height),
            "edges_detected": result.detectedEdgeCount,
            "edge_count": result.edges.count,
            "corner_count": result.corners.count,
            "total_green_pixels": result.totalGreenPixels,
            "usable": result.isUsable,
            "model_rms_residual_mm": model.rmsResidualMm,
            "model_max_residual_mm": model.maxResidualMm,
            "sample_count": model.sampleCount
        ]
        if let rmsResidual = result.rmsResidualMm {
            details["rms_residual_mm"] = rmsResidual
        }
        if let maxResidual = result.maxResidualMm {
            details["max_residual_mm"] = maxResidual
        }
        if let cornerRmsResidual = result.cornerRmsResidualMm {
            details["corner_rms_residual_mm"] = cornerRmsResidual
        }
        if let cornerMaxResidual = result.cornerMaxResidualMm {
            details["corner_max_residual_mm"] = cornerMaxResidual
        }

        for edge in result.edges {
            let prefix = "edge_\(edge.edgeIndex)"
            details["\(prefix)_samples"] = edge.sampleCount
            details["\(prefix)_detected_samples"] = edge.detectedSampleCount
            details["\(prefix)_green_pixels"] = edge.greenPixelCount
            details["\(prefix)_coverage"] = edge.coverageFraction
            details["\(prefix)_detected"] = edge.isDetected
            if let rmsResidual = edge.rmsExpectedResidualMm {
                details["\(prefix)_rms_residual_mm"] = rmsResidual
            }
            if let maxResidual = edge.maxExpectedResidualMm {
                details["\(prefix)_max_residual_mm"] = maxResidual
            }
            if let fitRmsResidual = edge.fitRmsResidualMm {
                details["\(prefix)_fit_rms_residual_mm"] = fitRmsResidual
            }
            if let angleError = edge.angleErrorDeg {
                details["\(prefix)_angle_error_deg"] = angleError
            }
            if let observedStart = edge.observedStartMm {
                details["\(prefix)_observed_start_x_mm"] = observedStart.x
                details["\(prefix)_observed_start_y_mm"] = observedStart.y
            }
            if let observedEnd = edge.observedEndMm {
                details["\(prefix)_observed_end_x_mm"] = observedEnd.x
                details["\(prefix)_observed_end_y_mm"] = observedEnd.y
            }
        }

        for corner in result.corners {
            let prefix = "corner_\(corner.cornerIndex)"
            details["\(prefix)_expected_x_mm"] = corner.expectedMm.x
            details["\(prefix)_expected_y_mm"] = corner.expectedMm.y
            details["\(prefix)_observed_x_mm"] = corner.observedMm.x
            details["\(prefix)_observed_y_mm"] = corner.observedMm.y
            details["\(prefix)_residual_mm"] = corner.residualMm
        }
        return details
    }
}
