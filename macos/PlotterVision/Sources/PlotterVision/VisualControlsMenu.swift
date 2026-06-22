import SwiftUI

struct VisualControlsMenu: View {
    @ObservedObject var plotterCamera: CameraModel
    @ObservedObject var faceCamera: CameraModel
    @Binding var plotterOverlay: PlotterOverlaySettings
    @Binding var plotterViewport: PlotterViewportSettings
    @Binding var showImageProcessingPanel: Bool
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

            Section("Plotter FOV") {
                Button {
                    setPlotterZoom(plotterViewport.clampedZoomScale + 0.25)
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                Button {
                    setPlotterZoom(plotterViewport.clampedZoomScale - 0.25)
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                Button {
                    resetPlotterFOV()
                } label: {
                    Label("Reset FOV", systemImage: "1.magnifyingglass")
                }
                Text("Viewport \(plotterViewport.zoomLabel)")
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
                    || plotterViewport.clampedZoomScale > 1.0001
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

    private func setPlotterZoom(_ scale: Double) {
        plotterViewport.zoomScale = clampDouble(
            scale,
            min: PlotterViewportSettings.minZoomScale,
            max: PlotterViewportSettings.maxZoomScale
        )
    }

    private func resetPlotterFOV() {
        plotterViewport.resetFOV()
    }
}
