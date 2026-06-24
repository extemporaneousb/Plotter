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
                manualFiducialCount: workspace.setupSnapshot.manualFiducialCount,
                hasPaperLock: workspace.setupSnapshot.hasPaperLock,
                capStateLabel: workspace.setupSnapshot.capStateLabel,
                isLiveMotionMode: workspace.setupSnapshot.isLiveMotionMode,
                capDetected: workspace.setupSnapshot.capDetected,
                canConfirmSetup: workspace.setupSnapshot.canConfirmSetup,
                primaryAction: { workspace.requestSetupCommand(.primary) },
                confirmSetup: { workspace.requestSetupCommand(.confirm) },
                reset: { workspace.requestSetupCommand(.reset) },
                hide: { workspace.requestSetupCommand(.hide) }
            )
        }
        .frame(width: 430, alignment: .topLeading)
        .padding(14)
    }
}
