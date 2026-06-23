import SwiftUI

struct PortraitPanel: View {
    @ObservedObject var bridge: PlotterBridgeModel
    @Binding var monitorEnabled: Bool
    let monitorStatus: String
    let captures: [PortraitCaptureItem]
    let selectedCaptureID: UUID?
    let canCreateContourDrawing: Bool
    let createContourDrawing: () -> Void
    let selectCapture: (PortraitCaptureItem) -> Void

    var body: some View {
        panelContent
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.mint.opacity(0.96))
                Text("PORTRAIT")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 0)
                Text(monitorStatus)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.mint.opacity(0.92))
            }

            Button {
                createContourDrawing()
            } label: {
                Label("Create \(bridge.portraitContourSettings.technique.captureLabel) Drawing", systemImage: "camera.aperture")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreateContourDrawing)
            .help("Capture a burst portrait and create a portrait drawing preview")

            Toggle("Live Monitor", isOn: $monitorEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            parameterControls

            captureStrip
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
    }

    private var parameterControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Mode", selection: settingsTechniqueBinding()) {
                ForEach(PortraitRenderTechnique.allCases) { technique in
                    Text(technique.title).tag(technique)
                }
            }
            .pickerStyle(.segmented)
            .font(.system(size: 10, weight: .semibold, design: .rounded))

            HStack(spacing: 10) {
                Stepper("Levels \(bridge.portraitContourSettings.contourLevels)", value: settingsIntBinding(\.contourLevels), in: 2...16)
                Stepper("Smooth \(bridge.portraitContourSettings.smoothingRadius)", value: settingsIntBinding(\.smoothingRadius), in: 0...4)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.82))

            PortraitSliderControl(
                label: "Low",
                value: settingsDoubleBinding(\.lowQuantile, clamp: 0.02...0.42),
                range: 0.02...0.42,
                step: 0.01,
                display: String(format: "%.2f", bridge.portraitContourSettings.lowQuantile)
            )
            PortraitSliderControl(
                label: "High",
                value: settingsDoubleBinding(\.highQuantile, clamp: 0.58...0.98),
                range: 0.58...0.98,
                step: 0.01,
                display: String(format: "%.2f", bridge.portraitContourSettings.highQuantile)
            )
            PortraitSliderControl(
                label: "Min Len",
                value: settingsDoubleBinding(\.minContourLengthNorm, clamp: 0.01...0.12),
                range: 0.01...0.12,
                step: 0.005,
                display: String(format: "%.3f", bridge.portraitContourSettings.minContourLengthNorm)
            )
            PortraitSliderControl(
                label: "Light",
                value: settingsDoubleBinding(\.illuminationStrength, clamp: 0.0...1.0),
                range: 0.0...1.0,
                step: 0.02,
                display: String(format: "%.2f", bridge.portraitContourSettings.illuminationStrength)
            )
        }
    }

    private var captureStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAPTURES")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))

            if captures.isEmpty {
                Text("NO PORTRAITS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.36))
                    .frame(height: 52, alignment: .center)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(captures) { item in
                            Button {
                                selectCapture(item)
                            } label: {
                                PortraitCaptureThumbnail(
                                    item: item,
                                    selected: item.id == selectedCaptureID
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Restore this portrait preview")
                        }
                    }
                }
                .frame(height: 74)
            }
        }
    }

    private func settingsTechniqueBinding() -> Binding<PortraitRenderTechnique> {
        Binding {
            bridge.portraitContourSettings.technique
        } set: { value in
            bridge.portraitContourSettings.technique = value
        }
    }

    private func settingsDoubleBinding(
        _ keyPath: WritableKeyPath<PortraitContourSettings, Double>,
        clamp range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding {
            bridge.portraitContourSettings[keyPath: keyPath]
        } set: { value in
            bridge.portraitContourSettings[keyPath: keyPath] = clampDouble(value, min: range.lowerBound, max: range.upperBound)
        }
    }

    private func settingsIntBinding(
        _ keyPath: WritableKeyPath<PortraitContourSettings, Int>
    ) -> Binding<Int> {
        Binding {
            bridge.portraitContourSettings[keyPath: keyPath]
        } set: { value in
            bridge.portraitContourSettings[keyPath: keyPath] = value
        }
    }
}

private struct PortraitSliderControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 42, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text(display)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.70))
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct PortraitCaptureThumbnail: View {
    let item: PortraitCaptureItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.96)))
                guard let overlay = item.overlay else { return }
                let bounds = overlay.faceBounds
                let insetRect = CGRect(x: 5, y: 4, width: size.width - 10, height: size.height - 16)
                context.stroke(
                    Path(roundedRect: insetRect, cornerRadius: 2),
                    with: .color(.mint.opacity(0.30)),
                    lineWidth: 0.8
                )
                for contour in overlay.contours.prefix(80) {
                    guard contour.points.count > 1 else { continue }
                    var path = Path()
                    path.move(to: thumbnailPoint(contour.points[0], bounds: bounds, rect: insetRect))
                    for point in contour.points.dropFirst() {
                        path.addLine(to: thumbnailPoint(point, bounds: bounds, rect: insetRect))
                    }
                    if contour.closed {
                        path.closeSubpath()
                    }
                    context.stroke(path, with: .color(.mint.opacity(0.86)), lineWidth: 0.75)
                }
            }
            .frame(width: 62, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.18), lineWidth: selected ? 2 : 1)
            )

            Text("\(item.technique.title) \(item.contourCount)")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(selected ? .cyan.opacity(0.95) : .white.opacity(0.56))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 62)
        }
    }

    private func thumbnailPoint(_ point: CGPoint, bounds: CGRect, rect: CGRect) -> CGPoint {
        let localX = bounds.width > 0 ? (point.x - bounds.minX) / bounds.width : 0.5
        let localY = bounds.height > 0 ? (point.y - bounds.minY) / bounds.height : 0.5
        let clampedX = CGFloat(clampDouble(Double(localX), min: 0.0, max: 1.0))
        let clampedY = CGFloat(clampDouble(Double(localY), min: 0.0, max: 1.0))
        return CGPoint(
            x: rect.minX + clampedX * rect.width,
            y: rect.minY + (1.0 - clampedY) * rect.height
        )
    }
}
