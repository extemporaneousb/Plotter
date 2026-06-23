import SwiftUI

struct DrawVerifyMenu: View {
    @ObservedObject var bridge: PlotterBridgeModel
    @Binding var workflowStatusText: String
    let visualMotionActive: Bool
    let previewImageContours: () -> Void

    var body: some View {
        Menu {
            Section("Capability Checks") {
                ForEach(DrawVerifyCoordinator.capabilities) { capability in
                    Button {
                        workflowStatusText = "VERIFY \(capability.title) preview"
                        Task {
                            let ok = await bridge.previewDrawVerifyCapability(kind: capability.id)
                            workflowStatusText = ok
                                ? "VERIFY \(bridge.drawVerifyStatusLine)"
                                : "VERIFY \(bridge.drawVerifyStatus) \(bridge.drawVerifyDetail)"
                        }
                    } label: {
                        Label("Preview \(capability.title)", systemImage: capability.systemImage)
                    }
                    .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating || bridge.isRunning)
                    .help(capability.detail)
                }

                Button {
                    workflowStatusText = "DRAW verified capability"
                    Task {
                        let ok = await bridge.runVerifiedDrawVerifyCapability()
                        workflowStatusText = ok
                            ? "DRAW \(bridge.drawVerifyStatusLine)"
                            : "DRAW \(bridge.drawVerifyStatus) \(bridge.drawVerifyDetail)"
                    }
                } label: {
                    Label("Run Verified Capability", systemImage: "play.circle.fill")
                }
                .disabled(bridge.drawVerifyPlanHash.isEmpty || !bridge.canRunAbsoluteDrawing)
                .help(bridge.drawVerifyPlanHash.isEmpty ? "Preview a capability check first" : bridge.drawPreflightMessage)
            }

            Section("Verified Plan") {
                Text(bridge.drawVerifyLabel.isEmpty ? "No capability preview" : bridge.drawVerifyLabel)
                Text("Command \(bridge.drawVerifyCommandId.isEmpty ? "--" : bridge.drawVerifyCommandId)")
                Text("Plan \(DrawVerifyCoordinator.shortPlanHash(bridge.drawVerifyPlanHash))")
            }

            Section("Shape And Image Preview") {
                Button("Preview Triangle Shape") {
                    workflowStatusText = "VERIFY triangle preview"
                    Task {
                        _ = await bridge.previewShapeOverlay(pattern: "triangle")
                        workflowStatusText = "VERIFY \(bridge.previewStatus)"
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating || bridge.isRunning)

                Button("Preview Square Shape") {
                    workflowStatusText = "VERIFY square preview"
                    Task {
                        _ = await bridge.previewShapeOverlay(pattern: "square")
                        workflowStatusText = "VERIFY \(bridge.previewStatus)"
                    }
                }
                .disabled(!bridge.isOnline || !bridge.hasPaperLock || bridge.isCalibrating || bridge.isRunning)

                Button("Preview Portrait Contours") {
                    workflowStatusText = "VERIFY portrait contour preview"
                    previewImageContours()
                }
                .disabled(!bridge.isOnline || bridge.isCalibrating || bridge.isRunning || bridge.isMachineBusy)
            }

            Section("Overlay") {
                Button("Replay Expected Path") {
                    bridge.replayExpectedPath()
                    workflowStatusText = "VERIFY expected path replay"
                }
                .disabled(bridge.expectedPathSegments.isEmpty || !bridge.hasPaperLock)

                Button("Clear Draw/Verify Overlays") {
                    bridge.clearDrawVerifyOverlay()
                    bridge.clearBindingMarkPreviewOverlay()
                    bridge.imagePreviewStatus = "IMG --"
                    bridge.imagePreviewDetail = "VISUAL ONLY"
                    bridge.imagePreviewContourCount = 0
                    bridge.imagePreviewEligibleForBridgePreview = false
                    workflowStatusText = "DRAW overlays cleared"
                }
                .disabled(
                    bridge.expectedPathSegments.isEmpty
                        && bridge.bindingMarkPreviewPoints.isEmpty
                        && bridge.bindingMarkPreviewSegments.isEmpty
                        && bridge.imagePreviewContourCount == 0
                        && bridge.drawVerifyPlanHash.isEmpty
                )
            }
        } label: {
            OperatorToolbarMenuLabel(
                systemName: "checkmark.seal",
                label: "Draw/Verify",
                isActive: !bridge.expectedPathSegments.isEmpty
                    || !bridge.bindingMarkPreviewPoints.isEmpty
                    || visualMotionActive
                    || bridge.imagePreviewContourCount > 0
                    || !bridge.drawVerifyPlanHash.isEmpty
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Capability checks, drawing previews, verified plan execution, and expected-path overlays")
    }
}
