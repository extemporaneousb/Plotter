import SwiftUI

enum CalibrationWizardStepStatus {
    case pending
    case active
    case done
    case blocked

    var label: String {
        switch self {
        case .pending:
            return "--"
        case .active:
            return "DO"
        case .done:
            return "OK"
        case .blocked:
            return "BLOCK"
        }
    }

    var color: Color {
        switch self {
        case .pending:
            return .white.opacity(0.42)
        case .active:
            return .yellow.opacity(0.95)
        case .done:
            return .green.opacity(0.95)
        case .blocked:
            return .red.opacity(0.95)
        }
    }

    var symbolName: String {
        switch self {
        case .pending:
            return "circle"
        case .active:
            return "arrow.right.circle.fill"
        case .done:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct CalibrationWizardStepRow: View {
    let index: Int
    let title: String
    let detail: String
    let status: CalibrationWizardStepStatus

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 18, height: 18)
                .background(status.color, in: Circle())
            Image(systemName: status.symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(status.color)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(status.label)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(status.color)
                }
                Text(detail)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 32)
    }
}

struct PlotterViewportTransform<Content: View>: View {
    let settings: PlotterViewportSettings
    let content: Content

    init(settings: PlotterViewportSettings, @ViewBuilder content: () -> Content) {
        self.settings = settings
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .rotationEffect(.degrees(settings.rotationDegrees))
                .scaleEffect(rotationFitScale(size: geometry.size, degrees: settings.rotationDegrees))
                .scaleEffect(plotterViewportZoomScale(settings))
                .offset(plotterViewportZoomOffset(size: geometry.size, settings: settings))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
    }
}

struct ConfirmedCapOverlay: View {
    let point: ConfirmedCapPoint?
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            if isActive {
                let label = Text("CLICK CAP POSITION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.96))
                context.draw(label, at: CGPoint(x: size.width - 12, y: 32), anchor: .topTrailing)
            }

            guard let point else { return }

            let center = CGPoint(
                x: point.point.x * size.width,
                y: point.point.y * size.height
            )
            let outer = CGRect(x: center.x - 25, y: center.y - 25, width: 50, height: 50)
            let middle = CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)
            let inner = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)

            context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.86)), lineWidth: 7.0)
            context.stroke(Path(ellipseIn: middle), with: .color(.green.opacity(0.98)), lineWidth: 4.0)
            context.fill(Path(ellipseIn: inner), with: .color(.white.opacity(0.98)))

            var cross = Path()
            cross.move(to: CGPoint(x: center.x - 35, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 35, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 35))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 35))
            context.stroke(cross, with: .color(.black.opacity(0.82)), lineWidth: 7.0)
            context.stroke(cross, with: .color(.green.opacity(0.98)), lineWidth: 3.2)

            let label = Text(point.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.98))
            context.draw(label, at: CGPoint(x: center.x + 16, y: center.y - 16), anchor: .leading)
        }
        .allowsHitTesting(false)
    }
}

struct CapColorPickOverlay: View {
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            guard isActive else { return }

            let label = Text("CLICK CAP COLOR")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.96))
            context.draw(label, at: CGPoint(x: size.width - 12, y: 50), anchor: .topTrailing)
        }
        .allowsHitTesting(false)
    }
}

struct ManualPenClickLayer: View {
    let settings: PlotterViewportSettings
    let videoSize: CGSize
    let onMark: (CGPoint, CGPoint) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let width = max(geometry.size.width, 1)
                            let height = max(geometry.size.height, 1)
                            let viewPoint = CGPoint(
                                x: value.location.x / width,
                                y: value.location.y / height
                            )
                            let cameraPoint = plotterCameraNormFromViewPoint(
                                value.location,
                                viewSize: geometry.size,
                                videoSize: videoSize,
                                settings: settings
                            )
                            onMark(viewPoint, cameraPoint)
                        }
                )
        }
    }
}

struct VisualFieldEditLayer: View {
    let settings: PlotterViewportSettings
    let videoSize: CGSize
    let corners: [ManualFiducialPoint]
    let fieldWidthMm: Double
    let fieldHeightMm: Double
    let isVisible: Bool
    let isActive: Bool
    let onUpdate: ([ManualFiducialPoint], Bool) -> Void

    @State private var dragStartCorners: [ManualFiducialPoint]?

    private var orderedCorners: [ManualFiducialPoint] {
        Array(corners.sorted { $0.id < $1.id }.prefix(4))
    }

    var body: some View {
        GeometryReader { geometry in
            if isVisible, orderedCorners.count == 4 {
                let viewCorners = orderedCorners.map {
                    plotterViewportPointFromCameraNorm(
                        $0.cameraPoint,
                        viewSize: geometry.size,
                        videoSize: videoSize,
                        settings: settings
                    )
                }
                ZStack {
                    if isActive {
                        editableFieldPolygon(points: viewCorners)
                            .fill(Color.cyan.opacity(0.001))
                            .contentShape(editableFieldPolygon(points: viewCorners))
                            .gesture(moveGesture(in: geometry.size))
                    } else {
                        editableFieldPolygon(points: viewCorners)
                            .fill(Color.cyan.opacity(0.001))
                            .allowsHitTesting(false)
                    }

                    Canvas { context, _ in
                        var path = editableFieldPolygon(points: viewCorners).path(in: .zero)
                        path.closeSubpath()
                        context.fill(path, with: .color(.cyan.opacity(0.10)))
                        context.stroke(path, with: .color(.cyan.opacity(0.92)), lineWidth: 3.0)
                        context.stroke(path, with: .color(.black.opacity(0.75)), lineWidth: 1.0)

                        let interaction = isActive ? "DRAG BOX / DRAG ANY CORNER; RELEASE RE-LOCKS" : "LIVE MACHINE-VIDEO ESTIMATE"
                        let label = Text(String(format: "FIELD %.0fx%.0f mm  %@", fieldWidthMm, fieldHeightMm, interaction))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.96))
                        if let topLeft = viewCorners.min(by: { $0.y < $1.y }) {
                            context.draw(
                                label,
                                at: CGPoint(x: topLeft.x + 8, y: max(18, topLeft.y - 16)),
                                anchor: .leading
                            )
                        }
                    }
                    .allowsHitTesting(false)

                    if isActive {
                        ForEach(Array(viewCorners.enumerated()), id: \.offset) { index, point in
                            Circle()
                                .fill(Color.black.opacity(0.68))
                                .overlay(Circle().stroke(Color.cyan.opacity(0.98), lineWidth: 3))
                                .overlay(Circle().fill(Color.white.opacity(0.92)).frame(width: 6, height: 6))
                                .frame(width: 26, height: 26)
                                .position(point)
                                .contentShape(Circle())
                                .gesture(cornerResizeGesture(cornerID: index + 1, in: geometry.size))
                                .help("Drag any field corner to resize; release to re-lock")
                        }
                    }
                }
            }
        }
    }

    private func editableFieldPolygon(points: [CGPoint]) -> VisualFieldEditPolygonShape {
        VisualFieldEditPolygonShape(points: points)
    }

    private func moveGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragStartCorners ?? orderedCorners
                dragStartCorners = base
                let start = plotterCameraNormFromViewPoint(
                    value.startLocation,
                    viewSize: viewSize,
                    videoSize: videoSize,
                    settings: settings
                )
                let current = plotterCameraNormFromViewPoint(
                    value.location,
                    viewSize: viewSize,
                    videoSize: videoSize,
                    settings: settings
                )
                let dx = current.x - start.x
                let dy = current.y - start.y
                onUpdate(visualFieldRectangleMoved(base, cameraDelta: CGPoint(x: dx, y: dy)), false)
            }
            .onEnded { value in
                let base = dragStartCorners ?? orderedCorners
                dragStartCorners = nil
                let start = plotterCameraNormFromViewPoint(
                    value.startLocation,
                    viewSize: viewSize,
                    videoSize: videoSize,
                    settings: settings
                )
                let current = plotterCameraNormFromViewPoint(
                    value.location,
                    viewSize: viewSize,
                    videoSize: videoSize,
                    settings: settings
                )
                let dx = current.x - start.x
                let dy = current.y - start.y
                onUpdate(visualFieldRectangleMoved(base, cameraDelta: CGPoint(x: dx, y: dy)), true)
            }
    }

    private func cornerResizeGesture(cornerID: Int, in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragStartCorners ?? orderedCorners
                dragStartCorners = base
                onUpdate(resizedRectangle(base, cornerID: cornerID, value: value.location, viewSize: viewSize), false)
            }
            .onEnded { value in
                let base = dragStartCorners ?? orderedCorners
                dragStartCorners = nil
                onUpdate(resizedRectangle(base, cornerID: cornerID, value: value.location, viewSize: viewSize), true)
            }
    }

    private func resizedRectangle(
        _ base: [ManualFiducialPoint],
        cornerID: Int,
        value: CGPoint,
        viewSize: CGSize
    ) -> [ManualFiducialPoint] {
        let cameraPoint = plotterCameraNormFromViewPoint(
            value,
            viewSize: viewSize,
            videoSize: videoSize,
            settings: settings
        )
        return visualFieldRectangleResized(base, cornerID: cornerID, cameraPoint: cameraPoint)
    }
}

struct VisualFieldEditPolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

func visualFieldCornersAreConvex(_ corners: [ManualFiducialPoint]) -> Bool {
    let ordered = Array(corners.sorted { $0.id < $1.id }.prefix(4))
    guard ordered.count == 4 else { return false }
    let points = ordered.map(\.cameraPoint)
    let turns = points.indices.map { index in
        visualFieldCornerTurn(
            points[index],
            points[(index + 1) % points.count],
            points[(index + 2) % points.count]
        )
    }
    guard turns.allSatisfy({ abs($0) >= 0.000_001 }) else { return false }
    return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
}

private func visualFieldCornerTurn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
    (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
}

private let minimumVisualFieldRectangleSpanNorm: CGFloat = 0.01

func visualFieldRectangleCornersFromCurrentBounds(_ corners: [ManualFiducialPoint]) -> [ManualFiducialPoint] {
    let ordered = orderedVisualFieldCorners(corners)
    guard let bounds = visualFieldCameraBounds(ordered) else { return corners }
    return visualFieldRectangleCorners(
        matching: ordered,
        minX: bounds.minX,
        minY: bounds.minY,
        maxX: bounds.maxX,
        maxY: bounds.maxY
    )
}

func visualFieldRectangleMoved(
    _ corners: [ManualFiducialPoint],
    cameraDelta: CGPoint
) -> [ManualFiducialPoint] {
    let ordered = orderedVisualFieldCorners(corners)
    guard let bounds = visualFieldCameraBounds(ordered) else { return corners }
    let dx = clampCGFloat(cameraDelta.x, min: -bounds.minX, max: 1.0 - bounds.maxX)
    let dy = clampCGFloat(cameraDelta.y, min: -bounds.minY, max: 1.0 - bounds.maxY)
    return visualFieldRectangleCorners(
        matching: ordered,
        minX: bounds.minX + dx,
        minY: bounds.minY + dy,
        maxX: bounds.maxX + dx,
        maxY: bounds.maxY + dy
    )
}

func visualFieldRectangleResized(
    _ corners: [ManualFiducialPoint],
    cornerID: Int,
    cameraPoint: CGPoint
) -> [ManualFiducialPoint] {
    let ordered = orderedVisualFieldCorners(corners)
    guard let bounds = visualFieldCameraBounds(ordered) else { return corners }

    var minX = bounds.minX
    var minY = bounds.minY
    var maxX = bounds.maxX
    var maxY = bounds.maxY

    switch cornerID {
    case 1:
        minX = clampCGFloat(cameraPoint.x, min: 0.0, max: bounds.maxX - minimumVisualFieldRectangleSpanNorm)
        minY = clampCGFloat(cameraPoint.y, min: 0.0, max: bounds.maxY - minimumVisualFieldRectangleSpanNorm)
    case 2:
        maxX = clampCGFloat(cameraPoint.x, min: bounds.minX + minimumVisualFieldRectangleSpanNorm, max: 1.0)
        minY = clampCGFloat(cameraPoint.y, min: 0.0, max: bounds.maxY - minimumVisualFieldRectangleSpanNorm)
    case 3:
        maxX = clampCGFloat(cameraPoint.x, min: bounds.minX + minimumVisualFieldRectangleSpanNorm, max: 1.0)
        maxY = clampCGFloat(cameraPoint.y, min: bounds.minY + minimumVisualFieldRectangleSpanNorm, max: 1.0)
    case 4:
        minX = clampCGFloat(cameraPoint.x, min: 0.0, max: bounds.maxX - minimumVisualFieldRectangleSpanNorm)
        maxY = clampCGFloat(cameraPoint.y, min: bounds.minY + minimumVisualFieldRectangleSpanNorm, max: 1.0)
    default:
        return corners
    }

    return visualFieldRectangleCorners(
        matching: ordered,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY
    )
}

private func orderedVisualFieldCorners(_ corners: [ManualFiducialPoint]) -> [ManualFiducialPoint] {
    Array(corners.sorted { $0.id < $1.id }.prefix(4))
}

private func visualFieldCameraBounds(_ corners: [ManualFiducialPoint]) -> CGRect? {
    let ordered = orderedVisualFieldCorners(corners)
    guard ordered.count == 4,
          let minX = ordered.map(\.cameraPoint.x).min(),
          let maxX = ordered.map(\.cameraPoint.x).max(),
          let minY = ordered.map(\.cameraPoint.y).min(),
          let maxY = ordered.map(\.cameraPoint.y).max() else {
        return nil
    }
    guard maxX - minX >= 0.0, maxY - minY >= 0.0 else { return nil }
    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    )
}

private func visualFieldRectangleCorners(
    matching orderedCorners: [ManualFiducialPoint],
    minX: CGFloat,
    minY: CGFloat,
    maxX: CGFloat,
    maxY: CGFloat
) -> [ManualFiducialPoint] {
    guard orderedCorners.count == 4 else { return orderedCorners }
    let clampedMinX = clampCGFloat(minX, min: 0.0, max: 1.0 - minimumVisualFieldRectangleSpanNorm)
    let clampedMaxX = clampCGFloat(maxX, min: clampedMinX + minimumVisualFieldRectangleSpanNorm, max: 1.0)
    let clampedMinY = clampCGFloat(minY, min: 0.0, max: 1.0 - minimumVisualFieldRectangleSpanNorm)
    let clampedMaxY = clampCGFloat(maxY, min: clampedMinY + minimumVisualFieldRectangleSpanNorm, max: 1.0)
    let cameraPoints = [
        CGPoint(x: clampedMinX, y: clampedMinY),
        CGPoint(x: clampedMaxX, y: clampedMinY),
        CGPoint(x: clampedMaxX, y: clampedMaxY),
        CGPoint(x: clampedMinX, y: clampedMaxY)
    ]
    return zip(orderedCorners, cameraPoints).map { corner, cameraPoint in
        visualFieldPoint(corner, cameraPoint: cameraPoint)
    }
}

private func visualFieldPoint(
    _ corner: ManualFiducialPoint,
    cameraPoint: CGPoint
) -> ManualFiducialPoint {
    let clamped = CGPoint(
        x: clampDouble(Double(cameraPoint.x), min: 0.0, max: 1.0),
        y: clampDouble(Double(cameraPoint.y), min: 0.0, max: 1.0)
    )
    return ManualFiducialPoint(
        id: corner.id,
        point: CGPoint(x: clamped.x, y: 1.0 - clamped.y),
        cameraPoint: clamped
    )
}

private func clampCGFloat(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
    Swift.min(maximum, Swift.max(minimum, value))
}

struct CameraPlaceholder: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: camera.role == .plotter ? "rectangle.dashed" : "person.crop.rectangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
            Text(camera.role.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            Text(camera.statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FaceContourOverlay: View {
    let segments: [VisionSegment]
    let videoSize: CGSize
    let previewMode: CameraPreviewMode

    var body: some View {
        Canvas { context, size in
            let displayRect = videoDisplayRect(
                viewSize: size,
                videoSize: videoSize,
                previewMode: previewMode
            )
            for (index, segment) in segments.prefix(80).enumerated() {
                let color = faceContourColor(for: segment.kind, index: index)
                if segment.points.count > 1 {
                    var path = Path()
                    path.move(to: faceOverlayPoint(segment.points[0], displayRect: displayRect))
                    for point in segment.points.dropFirst() {
                        path.addLine(to: faceOverlayPoint(point, displayRect: displayRect))
                    }
                    if segment.points.count > 2 {
                        path.closeSubpath()
                        context.fill(path, with: .color(color.opacity(0.10)))
                    }
                    context.stroke(path, with: .color(.black.opacity(0.68)), lineWidth: 3.4)
                    context.stroke(path, with: .color(color.opacity(0.90)), lineWidth: 1.5)
                }

                let rect = faceOverlayRect(segment.boundingBox, displayRect: displayRect)
                context.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(color.opacity(0.70)),
                    lineWidth: 0.9
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct PortraitContourPreviewOverlay: View {
    let overlay: FaceContourPreviewOverlay?
    let videoSize: CGSize
    let previewMode: CameraPreviewMode

    var body: some View {
        Canvas { context, size in
            guard let overlay, !overlay.contours.isEmpty else { return }

            let displayRect = videoDisplayRect(
                viewSize: size,
                videoSize: videoSize,
                previewMode: previewMode
            )
            let cropRect = faceOverlayRect(overlay.faceBounds, displayRect: displayRect)
            context.stroke(
                Path(roundedRect: cropRect, cornerRadius: 3),
                with: .color(.mint.opacity(0.50)),
                lineWidth: 1.1
            )

            for (index, contour) in overlay.contours.prefix(900).enumerated() {
                guard contour.points.count > 1 else { continue }
                var path = Path()
                path.move(to: faceOverlayPoint(contour.points[0], displayRect: displayRect))
                for point in contour.points.dropFirst() {
                    path.addLine(to: faceOverlayPoint(point, displayRect: displayRect))
                }
                if contour.closed {
                    path.closeSubpath()
                }

                context.stroke(path, with: .color(.black.opacity(0.82)), lineWidth: 3.2)
                context.stroke(
                    path,
                    with: .color(portraitContourPreviewColor(for: index).opacity(0.96)),
                    lineWidth: 1.25
                )
            }
        }
        .allowsHitTesting(false)
    }
}

struct ImageProcessingPanel: View {
    @ObservedObject var bridge: PlotterBridgeModel
    let visualContourCount: Int
    let isBridgeOnline: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text("IMAGE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.74))
                        Text(bridge.imagePreviewStatus)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(String(format: "VIS %dC", visualContourCount))
                        Text(bridge.imagePreviewDetail)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                }
                .frame(minWidth: 158, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
            }
            .padding(.top, 68)
            .padding(.horizontal, 18)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var statusColor: Color {
        if !isBridgeOnline { return .gray }
        if bridge.imagePreviewStatus.contains("ERR") { return .red }
        if bridge.imagePreviewEligibleForBridgePreview { return .green }
        return .yellow
    }
}

struct CameraPaneBadge: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(cameraBadgeColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(camera.role.shortTitle)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                            Text(camera.selectedCameraName)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.64))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(camera.statusText)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 82)
        }
        .allowsHitTesting(false)
    }

    private var cameraBadgeColor: Color {
        if camera.isRunning && camera.isReceivingFrames { return .green }
        if camera.isRunning { return .yellow }
        return .gray
    }
}

struct CameraSelector: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        Menu {
            Button {
                camera.refreshCameraDevices(reconnect: true)
            } label: {
                Label("Refresh & Reconnect", systemImage: "arrow.clockwise")
            }

            Button {
                camera.reconnectSelectedCamera()
            } label: {
                Label("Reconnect Selected", systemImage: "video.badge.checkmark")
            }

            Divider()

            if camera.availableCameras.isEmpty {
                Text("No cameras")
            } else {
                ForEach(camera.availableCameras) { option in
                    Button {
                        camera.selectCamera(option.id)
                    } label: {
                        Label(
                            option.displayName,
                            systemImage: option.id == camera.selectedCameraID ? "checkmark.circle.fill" : "video"
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "video.badge.ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text(camera.role.shortTitle)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                    Text(camera.selectedCameraName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Select \(camera.role.title)")
    }
}

struct StatusLamp: View {
    let title: String
    let value: String
    let color: Color
    let help: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white.opacity(0.30), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.50))
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(help)
    }
}

func faceOverlayPoint(_ normalized: CGPoint, displayRect: CGRect) -> CGPoint {
    CGPoint(
        x: displayRect.minX + normalized.x * displayRect.width,
        y: displayRect.minY + (1.0 - normalized.y) * displayRect.height
    )
}

func faceOverlayRect(_ normalized: CGRect, displayRect: CGRect) -> CGRect {
    CGRect(
        x: displayRect.minX + normalized.minX * displayRect.width,
        y: displayRect.minY + (1.0 - normalized.maxY) * displayRect.height,
        width: normalized.width * displayRect.width,
        height: normalized.height * displayRect.height
    )
}

func faceContourColor(for kind: SegmentKind, index: Int) -> Color {
    switch kind {
    case .line:
        return .cyan
    case .shape:
        return .mint
    case .mark:
        return .yellow
    case .contour:
        return index.isMultiple(of: 2) ? .orange : .pink
    }
}

func portraitContourPreviewColor(for index: Int) -> Color {
    switch index % 3 {
    case 0:
        return .mint
    case 1:
        return .cyan
    default:
        return .white
    }
}

func plotterCameraNormFromViewPoint(
    _ point: CGPoint,
    viewSize: CGSize,
    videoSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let unrotated = inversePlotterViewportPoint(point, viewSize: viewSize, settings: settings)
    let displayRect = videoDisplayRect(
        viewSize: viewSize,
        videoSize: videoSize,
        previewMode: settings.previewMode
    )
    guard displayRect.width > 0, displayRect.height > 0 else {
        return CGPoint(x: 0.5, y: 0.5)
    }
    let x = (unrotated.x - displayRect.minX) / displayRect.width
    let y = 1.0 - ((unrotated.y - displayRect.minY) / displayRect.height)
    return CGPoint(
        x: clampDouble(Double(x), min: 0.0, max: 1.0),
        y: clampDouble(Double(y), min: 0.0, max: 1.0)
    )
}

func plotterViewportPointFromCameraNorm(
    _ point: CGPoint,
    viewSize: CGSize,
    videoSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let displayRect = videoDisplayRect(
        viewSize: viewSize,
        videoSize: videoSize,
        previewMode: settings.previewMode
    )
    let untransformed = CGPoint(
        x: displayRect.minX + point.x * displayRect.width,
        y: displayRect.minY + (1.0 - point.y) * displayRect.height
    )
    return plotterViewportPoint(untransformed, viewSize: viewSize, settings: settings)
}

func plotterViewportPoint(
    _ point: CGPoint,
    viewSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    let radians = CGFloat(settings.rotationDegrees) * .pi / 180.0
    let cosTheta = cos(radians)
    let sinTheta = sin(radians)
    let translated = CGPoint(x: point.x - center.x, y: point.y - center.y)
    let rotated = CGPoint(
        x: center.x + translated.x * cosTheta - translated.y * sinTheta,
        y: center.y + translated.x * sinTheta + translated.y * cosTheta
    )
    let fitScale = rotationFitScale(size: viewSize, degrees: settings.rotationDegrees)
    let zoomScale = plotterViewportZoomScale(settings)
    let scaled = CGPoint(
        x: center.x + (rotated.x - center.x) * fitScale * zoomScale,
        y: center.y + (rotated.y - center.y) * fitScale * zoomScale
    )
    let zoomOffset = plotterViewportZoomOffset(size: viewSize, settings: settings)
    return CGPoint(x: scaled.x + zoomOffset.width, y: scaled.y + zoomOffset.height)
}

func inversePlotterViewportPoint(
    _ point: CGPoint,
    viewSize: CGSize,
    settings: PlotterViewportSettings
) -> CGPoint {
    let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    let zoomScale = max(plotterViewportZoomScale(settings), 0.0001)
    let zoomOffset = plotterViewportZoomOffset(size: viewSize, settings: settings)
    let unzoomed = CGPoint(
        x: center.x + (point.x - zoomOffset.width - center.x) / zoomScale,
        y: center.y + (point.y - zoomOffset.height - center.y) / zoomScale
    )
    let scale = max(rotationFitScale(size: viewSize, degrees: settings.rotationDegrees), 0.0001)
    let translated = CGPoint(
        x: (unzoomed.x - center.x) / scale,
        y: (unzoomed.y - center.y) / scale
    )
    let radians = -CGFloat(settings.rotationDegrees) * .pi / 180.0
    let cosTheta = cos(radians)
    let sinTheta = sin(radians)
    return CGPoint(
        x: center.x + translated.x * cosTheta - translated.y * sinTheta,
        y: center.y + translated.x * sinTheta + translated.y * cosTheta
    )
}

func plotterViewportZoomScale(_ settings: PlotterViewportSettings) -> CGFloat {
    CGFloat(clampDouble(
        settings.zoomScale,
        min: PlotterViewportSettings.minZoomScale,
        max: PlotterViewportSettings.maxZoomScale
    ))
}

func plotterViewportZoomOffset(size: CGSize, settings: PlotterViewportSettings) -> CGSize {
    let zoom = Double(plotterViewportZoomScale(settings))
    guard zoom > 1.0001 else { return .zero }
    let centerX = clampDouble(settings.zoomCenterX, min: 0.0, max: 1.0)
    let centerY = clampDouble(settings.zoomCenterY, min: 0.0, max: 1.0)
    return CGSize(
        width: (0.5 - centerX) * Double(size.width) * (zoom - 1.0),
        height: (centerY - 0.5) * Double(size.height) * (zoom - 1.0)
    )
}

func videoDisplayRect(
    viewSize: CGSize,
    videoSize: CGSize,
    previewMode: CameraPreviewMode
) -> CGRect {
    let sourceSize = videoSize.width > 0 && videoSize.height > 0
        ? videoSize
        : CGSize(width: 1280, height: 720)
    let imageAspect = sourceSize.width / sourceSize.height
    let viewAspect = max(viewSize.width, 1) / max(viewSize.height, 1)
    let displaySize: CGSize
    let offset: CGPoint

    switch previewMode {
    case .fill:
        if viewAspect > imageAspect {
            let width = viewSize.width
            let height = width / imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: 0, y: (viewSize.height - height) / 2)
        } else {
            let height = viewSize.height
            let width = height * imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: (viewSize.width - width) / 2, y: 0)
        }
    case .fit:
        if viewAspect > imageAspect {
            let height = viewSize.height
            let width = height * imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: (viewSize.width - width) / 2, y: 0)
        } else {
            let width = viewSize.width
            let height = width / imageAspect
            displaySize = CGSize(width: width, height: height)
            offset = CGPoint(x: 0, y: (viewSize.height - height) / 2)
        }
    }

    return CGRect(origin: offset, size: displaySize)
}

func rotationFitScale(size: CGSize, degrees: Double) -> CGFloat {
    let normalized = Int(abs(degrees).rounded()) % 180
    guard normalized == 90 else { return 1.0 }
    let width = max(size.width, 1)
    let height = max(size.height, 1)
    return min(width / height, height / width)
}

func nextQuarterTurn(after degrees: Double) -> Double {
    let turns = [0.0, 90.0, 180.0, 270.0]
    let normalized = degrees.truncatingRemainder(dividingBy: 360.0)
    let positive = normalized < 0 ? normalized + 360.0 : normalized
    let currentIndex = turns.enumerated().min { lhs, rhs in
        abs(lhs.element - positive) < abs(rhs.element - positive)
    }?.offset ?? 0
    return turns[(currentIndex + 1) % turns.count]
}

func clampDouble(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
    Swift.min(maximum, Swift.max(minimum, value))
}

func normalizedDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

func visualFieldCameraCorners(from registration: PaperRegistrationSnapshot) -> [CGPoint]? {
    let paperCorners = [
        CGPoint(x: 0.0, y: 0.0),
        CGPoint(x: 1.0, y: 0.0),
        CGPoint(x: 1.0, y: 1.0),
        CGPoint(x: 0.0, y: 1.0)
    ]
    let cameraCorners = paperCorners.compactMap {
        visualFieldCameraPoint(paperNorm: $0, registration: registration)
    }
    return cameraCorners.count == 4 ? cameraCorners : nil
}

func visualFieldCameraPoint(
    paperNorm: CGPoint,
    registration: PaperRegistrationSnapshot
) -> CGPoint? {
    let coefficients = registration.paperToCamera.coefficients
    guard coefficients.count == 9 else { return nil }
    let x = Double(paperNorm.x)
    let y = Double(paperNorm.y)
    let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
    guard abs(denominator) > 0.000_000_001 else { return nil }

    let cameraX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
    let cameraY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
    guard cameraX.isFinite, cameraY.isFinite else { return nil }
    return CGPoint(
        x: clampDouble(cameraX, min: 0.0, max: 1.0),
        y: clampDouble(cameraY, min: 0.0, max: 1.0)
    )
}

struct PlotterVideoFilterModifier: ViewModifier {
    let filter: PlotterVideoFilter

    @ViewBuilder
    func body(content: Content) -> some View {
        switch filter {
        case .normal:
            content
        case .monochrome:
            content
                .saturation(0.0)
                .contrast(1.18)
        case .highContrast:
            content
                .contrast(1.75)
                .saturation(1.08)
        case .inverted:
            content
                .colorInvert()
                .contrast(1.10)
        case .inkCheck:
            content
                .saturation(0.0)
                .contrast(2.10)
                .brightness(-0.08)
        }
    }
}

struct MenuSliderControl: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                Spacer(minLength: 8)
                Text(display)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .frame(width: 220)
    }
}
