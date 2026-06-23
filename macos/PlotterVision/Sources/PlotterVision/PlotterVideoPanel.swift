import SwiftUI

struct PlotterVideoPanel: View {
    @ObservedObject var workspace: OperatorWorkspaceState
    @ObservedObject var bridge: PlotterBridgeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelHeader
            overlayControls
            viewportControls
            capMarkerControls
            resetControls
        }
        .padding(14)
        .frame(width: 340, alignment: .topLeading)
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text("PLOTTER VIDEO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                Text("Viewport \(workspace.plotterViewport.focusLabel) \(workspace.plotterViewport.zoomLabel)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelSectionTitle("Overlays")
            Toggle("Calibrated Grid", isOn: Binding(
                get: { workspace.plotterCamera.showGrid },
                set: { workspace.plotterCamera.showGrid = $0 }
            ))
            Toggle("Measurements", isOn: Binding(
                get: { workspace.plotterCamera.showMeasurements },
                set: { workspace.plotterCamera.showMeasurements = $0 }
            ))
            Toggle("Segmentation", isOn: Binding(
                get: { workspace.plotterCamera.segmentationEnabled },
                set: { workspace.plotterCamera.segmentationEnabled = $0 }
            ))
            Toggle("Motion Detection", isOn: Binding(
                get: { workspace.plotterCamera.changeDetectionEnabled },
                set: { workspace.plotterCamera.changeDetectionEnabled = $0 }
            ))
            MenuSliderControl(
                label: "Overlay Alpha",
                value: Binding(
                    get: { workspace.plotterOverlay.opacity },
                    set: { workspace.plotterOverlay.opacity = $0 }
                ),
                range: 0.05...1.0,
                step: 0.01,
                display: String(format: "%.2f", workspace.plotterOverlay.opacity)
            )
        }
        .controlSize(.small)
    }

    private var viewportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelSectionTitle("Viewport")
            Picker("Filter", selection: Binding(
                get: { workspace.plotterViewport.videoFilter },
                set: { workspace.plotterViewport.videoFilter = $0 }
            )) {
                ForEach(PlotterVideoFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            HStack(spacing: 8) {
                Button("Rotate 90") {
                    workspace.plotterViewport.rotationDegrees = nextQuarterTurn(after: workspace.plotterViewport.rotationDegrees)
                    bridge.recordOperatorEvent(
                        "plotter_video_rotated",
                        details: ["rotation_degrees": workspace.plotterViewport.rotationDegrees]
                    )
                }
                Button("Original Video") {
                    workspace.requestPanelCommand(.useOriginalPlotterVideo)
                }
                Button("Fit Field") {
                    workspace.requestPanelCommand(.togglePlotterFocus)
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private var capMarkerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            panelSectionTitle("Cap Marker")
            HStack(spacing: 8) {
                Button("Sample Cap Color") {
                    workspace.requestPanelCommand(.sampleCapColor)
                }
                Button("Reset Cap Color") {
                    workspace.requestPanelCommand(.resetCapColor)
                }
            }
            .buttonStyle(.bordered)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
    }

    private var resetControls: some View {
        Button("Reset Visual Controls") {
            workspace.requestPanelCommand(.resetVisualControls)
        }
        .buttonStyle(.bordered)
        .font(.system(size: 11, weight: .bold, design: .rounded))
    }
}

@ViewBuilder
func panelSectionTitle(_ title: String) -> some View {
    Text(title.uppercased())
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.48))
}
