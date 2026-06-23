import SwiftUI

struct VisualControlsMenu: View {
    @ObservedObject var plotterCamera: CameraModel
    @ObservedObject var faceCamera: CameraModel
    @Binding var plotterOverlay: PlotterOverlaySettings
    @Binding var plotterViewport: PlotterViewportSettings
    @Binding var showImageProcessingPanel: Bool
    let sampleCapColor: () -> Void
    let resetCapColor: () -> Void
    let reset: () -> Void

    var body: some View {
        Menu {
            Section("Overlays") {
                Toggle("Calibrated Grid", isOn: $plotterCamera.showGrid)
                Toggle("Measurements", isOn: $plotterCamera.showMeasurements)
                Toggle("Segmentation", isOn: $plotterCamera.segmentationEnabled)
                Toggle("Motion Detection", isOn: $plotterCamera.changeDetectionEnabled)
                MenuSliderControl(
                    label: "Overlay Alpha",
                    value: $plotterOverlay.opacity,
                    range: 0.05...1.0,
                    step: 0.01,
                    display: String(format: "%.2f", plotterOverlay.opacity)
                )
            }

            Section("Video Filter") {
                Picker("Filter", selection: $plotterViewport.videoFilter) {
                    ForEach(PlotterVideoFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            }

            Section("Plotter View") {
                Button {
                    plotterViewport.resetFOV()
                } label: {
                    Label("Original Video", systemImage: "viewfinder")
                }
                Text("Viewport \(plotterViewport.focusLabel) \(plotterViewport.zoomLabel)")
            }

            Section("Cap Marker") {
                Button("Sample Cap Color", action: sampleCapColor)
                Button("Reset Cap Color", action: resetCapColor)
            }

            Section("Image Baseline") {
                Toggle("Face Contours", isOn: $faceCamera.segmentationEnabled)
                Toggle("Image Panel", isOn: $showImageProcessingPanel)
            }

            Section("Reset") {
                Button("Reset Visual Controls", action: reset)
            }
        } label: {
            OperatorToolbarMenuLabel(
                systemName: "slider.horizontal.3",
                label: "Visuals",
                isActive: plotterViewport.videoFilter != .normal
                    || plotterViewport.focusMode == .focused
                    || plotterCamera.showGrid
                    || plotterCamera.segmentationEnabled
                    || plotterCamera.changeDetectionEnabled
                    || faceCamera.segmentationEnabled
                    || showImageProcessingPanel
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Visual overlays, calibrated paper grid, and video filters")
    }
}
