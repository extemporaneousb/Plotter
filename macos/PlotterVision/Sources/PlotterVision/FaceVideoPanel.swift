import SwiftUI

struct FaceVideoPanel: View {
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Toggle("Face Contours", isOn: Binding(
                get: { workspace.faceCamera.segmentationEnabled },
                set: { workspace.faceCamera.segmentationEnabled = $0 }
            ))
                .toggleStyle(.switch)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Toggle("Image Panel", isOn: $workspace.showImageProcessingPanel)
                .toggleStyle(.switch)
                .font(.system(size: 11, weight: .semibold, design: .rounded))

            PortraitPanel(
                bridge: bridge,
                monitorEnabled: $workspace.portraitContourMonitorEnabled,
                monitorStatus: workspace.portraitContourMonitorStatus,
                captures: workspace.portraitCaptures,
                selectedCaptureID: workspace.selectedPortraitCaptureID,
                canCreateContourDrawing: workspace.faceCamera.isRunning && !bridge.isCalibrating,
                createContourDrawing: {
                    workspace.requestPanelCommand(.createPortraitDrawing)
                },
                selectCapture: { item in
                    workspace.requestPanelCommand(.selectPortraitCapture(item.id))
                }
            )
        }
        .padding(14)
        .frame(width: 360, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.rectangle")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("FACE VIDEO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text(workspace.faceCamera.statusText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
