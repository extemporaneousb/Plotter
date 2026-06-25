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
        }
        .frame(width: 430, alignment: .topLeading)
        .padding(14)
    }
}
