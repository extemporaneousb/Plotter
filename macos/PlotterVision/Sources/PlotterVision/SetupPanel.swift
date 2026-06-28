import SwiftUI

struct SetupPanel: View {
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CalibrationWizardView(
                instructionText: workspace.setupSnapshot.instructionText,
                fiducialDetail: workspace.setupSnapshot.fiducialDetail,
                fiducialStatus: workspace.setupSnapshot.fiducialStatus,
                greenCapDetail: workspace.setupSnapshot.greenCapDetail,
                greenCapStatus: workspace.setupSnapshot.greenCapStatus,
                visualCalibrationDetail: workspace.setupSnapshot.visualCalibrationDetail,
                visualCalibrationStatus: workspace.setupSnapshot.visualCalibrationStatus,
                bindingDetail: workspace.setupSnapshot.bindingDetail,
                bindingStatus: workspace.setupSnapshot.bindingStatus,
                drawingCalibrationDetail: workspace.setupSnapshot.drawingCalibrationDetail,
                drawingCalibrationStatus: workspace.setupSnapshot.drawingCalibrationStatus,
                primaryActionTitle: workspace.setupSnapshot.primaryActionTitle,
                primaryActionEnabled: workspace.setupSnapshot.primaryActionEnabled,
                primaryActionDisabledReason: workspace.setupSnapshot.primaryActionDisabledReason,
                drawFrameVisible: workspace.setupSnapshot.drawFrameVisible,
                drawFrameEnabled: workspace.setupSnapshot.drawFrameEnabled,
                drawFrameDisabledReason: workspace.setupSnapshot.drawFrameDisabledReason,
                hasPaperLock: workspace.setupSnapshot.hasPaperLock,
                capStateLabel: workspace.setupSnapshot.capStateLabel,
                isLiveMotionMode: workspace.setupSnapshot.isLiveMotionMode,
                capDetected: workspace.setupSnapshot.capDetected,
                fieldWidthMm: $workspace.visualFieldWidthMm,
                fieldHeightMm: $workspace.visualFieldHeightMm,
                primaryAction: { workspace.requestSetupCommand(.primary) },
                drawFrame: { workspace.requestSetupCommand(.drawFrame) },
                reset: { workspace.requestSetupCommand(.reset) },
                hide: { workspace.requestSetupCommand(.hide) }
            )
            ProgressiveDrawingCalibrationControls(workspace: workspace, bridge: bridge)
            SetupLogDisclosure(workspace: workspace)
            SetupModelEstimatesDisclosure(workspace: workspace, bridge: bridge)
        }
        .frame(width: 430, alignment: .topLeading)
        .padding(14)
    }
}

private struct ProgressiveDrawingCalibrationControls: View {
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Progressive Drawing Calibration", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text(bridge.drawingCalibrationSessionStatus)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(bridge.drawingCalibrationSessionDetail)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button {
                    workspace.requestSetupCommand(.startDrawingSession)
                } label: {
                    Label("Start", systemImage: "play.circle")
                }
                Button {
                    workspace.requestSetupCommand(.previewDrawingBatch)
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                Button {
                    workspace.requestSetupCommand(.runDrawingBatch)
                } label: {
                    Label("Run", systemImage: "paperplane")
                }
                Button {
                    workspace.requestSetupCommand(.observeDrawingBatch)
                } label: {
                    Label("Observe / Retry", systemImage: "camera.metering.center.weighted")
                }
            }
            .controlSize(.mini)
            HStack(spacing: 6) {
                Button {
                    workspace.requestSetupCommand(.fitDrawingSession)
                } label: {
                    Label("Fit", systemImage: "function")
                }
                Button {
                    workspace.requestSetupCommand(.validateDrawingSession)
                } label: {
                    Label("Validate", systemImage: "checkmark.seal")
                }
                Button {
                    workspace.requestSetupCommand(.finishDrawingSession)
                } label: {
                    Label("Finish", systemImage: "flag.checkered")
                }
            }
            .controlSize(.mini)
            .disabled(bridge.latestDrawingCalibrationSession == nil)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SetupLogDisclosure: View {
    @ObservedObject var workspace: OperatorWorkspaceState

    var body: some View {
        DisclosureGroup(isExpanded: $workspace.setupLogExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(workspace.operatorLog.count) entries")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        workspace.operatorLog = []
                        workspace.appendOperatorLog("Log cleared", source: "Setup")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .disabled(workspace.operatorLog.isEmpty)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(workspace.operatorLog.suffix(80)) { entry in
                            SetupLogRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 190)
            }
            .padding(.top, 8)
        } label: {
            Label("Setup Log", systemImage: "list.bullet.rectangle")
                .font(.system(size: 12, weight: .bold))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SetupModelEstimatesDisclosure: View {
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        DisclosureGroup(isExpanded: $workspace.setupModelEstimatesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                estimateRow("Paper homography", paperHomographySummary)
                estimateRow("Motion 2x2", motionMatrixSummary)
                estimateRow("Motion samples", motionSampleSummary)
                estimateRow("Session id", bridge.latestDrawingCalibrationSession?.sessionId ?? "--")
                estimateRow("Batch id/index", drawingBatchSummary)
                estimateRow("Correction mode", bridge.currentDrawingCalibrationBatch?.correctionMode ?? "--")
                estimateRow("Model id used", bridge.currentDrawingCalibrationBatch?.modelIdUsed ?? "--")
                estimateRow("Drawing model family", drawingModelFamilySummary)
                estimateRow("Solver kind", drawingSolverSummary)
                estimateRow("Action model kind", bridge.latestDrawingCalibration?.actionModelKind ?? "--")
                estimateRow("Grid/control count", drawingControlSummary)
                estimateRow("Sample count", drawingSampleSummary)
                estimateRow("Coverage", drawingCoverageSummary)
                estimateRow("RMS/p95/max", drawingResidualSummary)
                estimateRow("Holdout error", drawingHoldoutSummary)
                estimateRow("Validation error", drawingHoldoutSummary)
                estimateRow("Retry count", drawingRetrySummary)
                estimateRow("Blockers", drawingBlockerSummary)
                estimateRow("Model id", bridge.latestDrawingCalibration?.modelId ?? "--")
            }
            .padding(.top, 8)
            .textSelection(.enabled)
        } label: {
            Label("Model Estimates", systemImage: "function")
                .font(.system(size: 12, weight: .bold))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func estimateRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 122, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private var paperHomographySummary: String {
        guard let registration = bridge.paperRegistrationSnapshot else {
            return "--"
        }
        return "\(registration.registrationId) \(formatHomography(registration.paperToCamera)) \(formatResidualPair(registration.rmsErrorNorm, registration.maxErrorNorm, suffix: "norm"))"
    }

    private var motionModel: VisualMotionModel? {
        workspace.visualMotionModel ?? bridge.latestVisualReadiness?.relativeMotionModel?.visualMotionModel
    }

    private var motionMatrixSummary: String {
        guard let model = motionModel else {
            return "--"
        }
        return String(
            format: "[%.3f %.3f; %.3f %.3f]",
            model.xBasisDx,
            model.yBasisDx,
            model.xBasisDy,
            model.yBasisDy
        )
    }

    private var motionSampleSummary: String {
        guard let model = motionModel else {
            return "--"
        }
        let p95 = bridge.latestVisualReadiness?.relativeMotionModel?.p95ResidualMm
            .map { String(format: " p95 %.1fmm", $0) } ?? ""
        return String(
            format: "%d samples rms %.1fmm%@ max %.1fmm",
            model.sampleCount,
            model.rmsResidualMm,
            p95,
            model.maxResidualMm
        )
    }

    private var drawingModelFamilySummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        let version = calibration.modelVersion.map { " \($0)" } ?? ""
        return "\(calibration.modelFamily)\(version)"
    }

    private var drawingBatchSummary: String {
        guard let batch = bridge.currentDrawingCalibrationBatch else {
            return "--"
        }
        return "\(batch.batchId) #\(batch.batchIndex) \(batch.purpose)"
    }

    private var drawingSolverSummary: String {
        bridge.latestDrawingCalibration?.solverKind ?? "--"
    }

    private var drawingControlSummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        if let grid = calibration.residualGrid {
            let fitCount = calibration.acceptedFitSampleCount ?? calibration.fitSampleCount ?? 0
            return "\(grid.columns)x\(grid.rows) grid; \(grid.nodes.count) node(s); \(fitCount) fit control(s)"
        }
        let count = calibration.gridControlCount ?? (calibration.expectedToObserved == nil ? 0 : 4)
        return "\(count) control(s)"
    }

    private var drawingSampleSummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        let sampleCount = calibration.sampleCount ?? calibration.observationCount
        let holdout = calibration.holdoutSampleCount.map { "; \($0) holdout" } ?? ""
        let rejected = calibration.rejectedSampleCount.map { "; \($0) rejected" } ?? ""
        return "\(sampleCount) sample(s); \(calibration.usableObservationCount) usable observation(s)\(holdout)\(rejected)"
    }

    private var drawingCoverageSummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        if let coverage = calibration.coverage {
            return String(
                format: "%.0f%% grid %d/%d nodes radius %.1fmm",
                coverage.coverageFraction * 100.0,
                coverage.coveredNodeCount,
                coverage.totalNodeCount,
                coverage.coverageRadiusMm ?? 0.0
            )
        }
        if let coverage = calibration.coverageFraction {
            return String(format: "%.0f%%", coverage * 100.0)
        }
        guard calibration.observationCount > 0 else {
            return "0%"
        }
        let coverage = Double(calibration.usableObservationCount) / Double(calibration.observationCount)
        return String(format: "%.0f%% usable observations", coverage * 100.0)
    }

    private var drawingResidualSummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        let rms = calibration.fitMetrics?.rmsMm ?? calibration.rmsResidualMm
        let p95 = calibration.fitMetrics?.p95Mm ?? calibration.p95ResidualMm
        let max = calibration.fitMetrics?.maxMm ?? calibration.maxResidualMm
        return [
            rms.map { String(format: "rms %.1fmm", $0) } ?? "rms --",
            p95.map { String(format: "p95 %.1fmm", $0) } ?? "p95 --",
            max.map { String(format: "max %.1fmm", $0) } ?? "max --"
        ].joined(separator: " ")
    }

    private var drawingHoldoutSummary: String {
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        let metrics = calibration.validationMetrics ?? calibration.holdoutMetrics
        if metrics == nil && calibration.holdoutSampleCount == 0 {
            return "0 validation samples"
        }
        let rms = (metrics?.rmsMm ?? calibration.holdoutRmsResidualMm)
            .map { String(format: "rms %.1fmm", $0) } ?? "rms --"
        let p95 = metrics?.p95Mm.map { String(format: "p95 %.1fmm", $0) } ?? "p95 --"
        let max = (metrics?.maxMm ?? calibration.holdoutMaxResidualMm)
            .map { String(format: "max %.1fmm", $0) } ?? "max --"
        return "\(rms) \(p95) \(max)"
    }

    private var drawingRetrySummary: String {
        guard let batch = bridge.currentDrawingCalibrationBatch else {
            return "--"
        }
        return "\(batch.retryCount)/\(batch.maxRetries)"
    }

    private var drawingBlockerSummary: String {
        if let session = bridge.latestDrawingCalibrationSession, !session.blockers.isEmpty {
            return session.blockers.prefix(2).joined(separator: " | ")
        }
        if let batch = bridge.currentDrawingCalibrationBatch, !batch.blockers.isEmpty {
            return batch.blockers.prefix(2).joined(separator: " | ")
        }
        guard let calibration = bridge.latestDrawingCalibration else {
            return "--"
        }
        if let actionBlockers = calibration.actionModelBlockers, !actionBlockers.isEmpty {
            return actionBlockers.prefix(2).joined(separator: " | ")
        }
        guard !calibration.blockers.isEmpty else {
            guard let stale = calibration.staleReasons, !stale.isEmpty else {
                return "none"
            }
            return stale.prefix(2).joined(separator: " | ")
        }
        return calibration.blockers.prefix(2).joined(separator: " | ")
    }

    private func formatHomography(_ homography: HomographySnapshot) -> String {
        let coefficients = homography.coefficients
        guard coefficients.count == 9 else {
            return "H --"
        }
        return String(
            format: "H[%.3f %.3f %.3f; %.3f %.3f %.3f; %.3f %.3f %.3f]",
            coefficients[0],
            coefficients[1],
            coefficients[2],
            coefficients[3],
            coefficients[4],
            coefficients[5],
            coefficients[6],
            coefficients[7],
            coefficients[8]
        )
    }

    private func formatResidualPair(_ rms: Double?, _ max: Double?, suffix: String) -> String {
        let rmsText = rms.map { String(format: "rms %.3f%@", $0, suffix) } ?? "rms --"
        let maxText = max.map { String(format: "max %.3f%@", $0, suffix) } ?? "max --"
        return "\(rmsText) \(maxText)"
    }
}

private struct SetupLogRow: View {
    let entry: OperatorLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(entry.source)
                .foregroundStyle(sourceColor)
                .frame(width: 54, alignment: .leading)
            Text(entry.message)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
    }

    private var sourceColor: Color {
        switch entry.level {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
