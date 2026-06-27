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
            SetupLogDisclosure(workspace: workspace)
        }
        .frame(width: 430, alignment: .topLeading)
        .padding(14)
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
