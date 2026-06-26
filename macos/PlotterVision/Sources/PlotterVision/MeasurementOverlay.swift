import SwiftUI

struct MeasurementOverlay: View {
    let segments: [VisionSegment]
    let carriageMarker: CarriageMarker?
    let visualMoveIntent: VisualMoveIntent?
    let motionTracks: [MotionTrack]
    let expectedPathSegments: [ExpectedPathSegment]
    let bindingMarkPreviewSegments: [BindingMarkPreviewSegment]
    let bindingMarkPreviewPoints: [BindingMarkPreviewPoint]
    let paperTransform: PaperRegistrationSnapshot?
    let plotterOverlay: PlotterOverlaySettings
    let pathRevealProgress: Double
    let videoSize: CGSize
    let previewMode: CameraPreviewMode
    let showMeasurements: Bool

    var body: some View {
        Canvas { context, size in
            let mapper = OverlayMapper(viewSize: size, videoSize: videoSize, previewMode: previewMode)

            if let paperTransform {
                drawDrawingBorder(paperTransform, mapper: mapper, in: &context)
                drawExpectedPath(registration: paperTransform, mapper: mapper, in: &context)
                drawVisualMoveIntent(registration: paperTransform, mapper: mapper, in: &context)
            }

            drawBindingMarkPreview(mapper: mapper, in: &context)

            if let carriageMarker {
                draw(carriageMarker: carriageMarker, mapper: mapper, in: &context)
            }

            for (index, segment) in segments.enumerated() {
                draw(segment: segment, index: index, mapper: mapper, in: &context)
            }

            for track in motionTracks {
                draw(track: track, mapper: mapper, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawDrawingBorder(
        _ registration: PaperRegistrationSnapshot,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        let paperCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ]
        let cameraCorners = paperCorners.compactMap { paperToCameraPoint($0, registration: registration) }
        guard cameraCorners.count == paperCorners.count else { return }

        var region = Path()
        region.move(to: mapper.point(cameraCorners[0]))
        for corner in cameraCorners.dropFirst() {
            region.addLine(to: mapper.point(corner))
        }
        region.closeSubpath()

        let color = Color(red: 0.12, green: 0.70, blue: 1.0)
        context.fill(region, with: .color(color.opacity(0.08)))
        context.stroke(
            region,
            with: .color(.black.opacity(0.86)),
            style: StrokeStyle(lineWidth: 6.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            region,
            with: .color(color.opacity(0.96)),
            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
        )

        for cameraCorner in cameraCorners {
            let center = mapper.point(cameraCorner)
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)),
                with: .color(color.opacity(0.95))
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
                with: .color(.black.opacity(0.76)),
                lineWidth: 2.0
            )
        }

        guard showMeasurements else { return }

        drawOverlayLabel(
            String(
                format: "DRAWING BORDER %.0f x %.0f mm",
                registration.paperSizeMm.width,
                registration.paperSizeMm.height
            ),
            at: mapper.point(cameraCorners[3]),
            anchor: .bottomLeading,
            foreground: color.opacity(0.98),
            in: &context
        )

        drawFieldAxis(
            start: mapper.point(cameraCorners[0]),
            end: mapper.point(cameraCorners[1]),
            label: String(format: "+X %.0fmm", registration.paperSizeMm.width),
            color: .cyan,
            in: &context
        )
        drawFieldAxis(
            start: mapper.point(cameraCorners[0]),
            end: mapper.point(cameraCorners[3]),
            label: String(format: "+Y %.0fmm", registration.paperSizeMm.height),
            color: .green,
            in: &context
        )
        drawOverlayLabel(
            "0,0",
            at: mapper.point(cameraCorners[0]),
            anchor: .topTrailing,
            foreground: .white.opacity(0.98),
            font: .system(size: 11, weight: .black, design: .monospaced),
            in: &context
        )
    }

    private func drawFieldAxis(
        start: CGPoint,
        end: CGPoint,
        label: String,
        color: Color,
        in context: inout GraphicsContext
    ) {
        let vector = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let axisLength = hypot(vector.x, vector.y)
        guard axisLength > 12 else { return }
        let scale = min(0.32, 54.0 / axisLength)
        let axisEnd = CGPoint(x: start.x + vector.x * scale, y: start.y + vector.y * scale)
        var axis = Path()
        axis.move(to: start)
        axis.addLine(to: axisEnd)
        context.stroke(
            axis,
            with: .color(.black.opacity(0.86)),
            style: StrokeStyle(lineWidth: 9.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            axis,
            with: .color(color.opacity(0.96)),
            style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
        )
        drawArrowHead(start: start, end: axisEnd, color: color, in: &context)
        drawOverlayLabel(
            label,
            at: axisEnd,
            anchor: .bottomLeading,
            foreground: color.opacity(0.98),
            font: .system(size: 10, weight: .black, design: .monospaced),
            in: &context
        )
    }

    private func drawExpectedPath(
        registration: PaperRegistrationSnapshot,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        guard plotterOverlay.enabled else { return }
        guard !expectedPathSegments.isEmpty else { return }

        var path = Path()
        let revealLength = revealedLengthMm
        var consumedLength = 0.0

        for segment in expectedPathSegments {
            guard let start = normalizedPoint(segment.startNorm),
                  let end = normalizedPoint(segment.endNorm) else {
                continue
            }
            guard consumedLength < revealLength else { break }

            let remaining = revealLength - consumedLength
            let segmentFraction = min(1.0, remaining / max(segment.lengthMm, 0.000_001))
            let visibleEnd = interpolate(start: start, end: end, fraction: segmentFraction)
            guard let cameraStart = paperToCameraPoint(start, registration: registration),
                  let cameraEnd = paperToCameraPoint(visibleEnd, registration: registration) else {
                consumedLength += segment.lengthMm
                continue
            }
            path.move(to: mapper.point(cameraStart))
            path.addLine(to: mapper.point(cameraEnd))
            consumedLength += segment.lengthMm
        }

        context.stroke(
            path,
            with: .color(.yellow.opacity(0.92 * plotterOverlay.opacity)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [8, 5])
        )

        for segment in expectedPathSegments {
            guard let start = normalizedPoint(segment.startNorm),
                  let end = normalizedPoint(segment.endNorm) else {
                continue
            }
            guard let cameraStart = paperToCameraPoint(start, registration: registration),
                  let cameraEnd = paperToCameraPoint(end, registration: registration) else {
                continue
            }
            let startPoint = mapper.point(cameraStart)
            let endPoint = mapper.point(cameraEnd)
            context.fill(
                Path(ellipseIn: CGRect(x: startPoint.x - 3, y: startPoint.y - 3, width: 6, height: 6)),
                with: .color(.cyan.opacity(0.9 * plotterOverlay.opacity))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: endPoint.x - 3, y: endPoint.y - 3, width: 6, height: 6)),
                with: .color(.yellow.opacity(0.9 * plotterOverlay.opacity))
            )
        }

        guard showMeasurements, let first = expectedPathSegments.first,
              let start = normalizedPoint(first.startNorm),
              let cameraStart = paperToCameraPoint(start, registration: registration) else {
            return
        }

        let point = mapper.point(cameraStart)
        drawOverlayLabel(
            "EXPECTED",
            at: CGPoint(x: point.x + 8, y: point.y - 10),
            foreground: .yellow.opacity(0.9 * plotterOverlay.opacity),
            in: &context
        )
    }

    private func drawBindingMarkPreview(mapper: OverlayMapper, in context: inout GraphicsContext) {
        guard !bindingMarkPreviewSegments.isEmpty || !bindingMarkPreviewPoints.isEmpty else { return }

        let pathColor = Color(red: 0.15, green: 0.95, blue: 1.0)
        let pointColor = Color(red: 1.0, green: 0.18, blue: 0.72)
        var hiddenProjectionCount = 0

        if !bindingMarkPreviewSegments.isEmpty {
            for segment in bindingMarkPreviewSegments {
                guard let startNorm = visibleNormalizedPoint(segment.startNorm),
                      let endNorm = visibleNormalizedPoint(segment.endNorm) else {
                    hiddenProjectionCount += 1
                    continue
                }
                let start = mapper.point(startNorm)
                let end = mapper.point(endNorm)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(
                    path,
                    with: .color(.black.opacity(0.84)),
                    style: StrokeStyle(lineWidth: 14.0, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    path,
                    with: .color(pathColor.opacity(1.0)),
                    style: StrokeStyle(lineWidth: 9.0, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.90)),
                    style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
                )
            }
        }

        for point in bindingMarkPreviewPoints {
            guard let cameraNorm = visibleNormalizedPoint(point.cameraNorm) else {
                hiddenProjectionCount += 1
                continue
            }
            let center = mapper.point(cameraNorm)
            let outer = CGRect(x: center.x - 27, y: center.y - 27, width: 54, height: 54)
            let middle = CGRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34)
            let inner = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
            context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.84)), lineWidth: 7.0)
            context.stroke(Path(ellipseIn: middle), with: .color(pointColor.opacity(1.0)), lineWidth: 4.0)
            context.fill(Path(ellipseIn: inner), with: .color(pointColor.opacity(0.98)))

            var tick = Path()
            tick.move(to: CGPoint(x: center.x - 34, y: center.y))
            tick.addLine(to: CGPoint(x: center.x + 34, y: center.y))
            tick.move(to: CGPoint(x: center.x, y: center.y - 34))
            tick.addLine(to: CGPoint(x: center.x, y: center.y + 34))
            context.stroke(tick, with: .color(.black.opacity(0.82)), lineWidth: 7.0)
            context.stroke(tick, with: .color(.white.opacity(0.96)), lineWidth: 3.0)

            guard showMeasurements else { continue }

            drawOverlayLabel(
                String(
                    format: "%@ %.0f,%.0f",
                    point.pointId,
                    point.paperMm.x,
                    point.paperMm.y
                ),
                at: CGPoint(x: center.x + 14, y: center.y - 13),
                foreground: pointColor.opacity(0.96),
                in: &context
            )
        }

        guard showMeasurements, let first = bindingMarkPreviewPoints.first else { return }
        let anchor = mapper.point(normalizedPoint(first.cameraNorm))
        let suffix = hiddenProjectionCount > 0 ? String(format: "  HIDDEN:%d", hiddenProjectionCount) : ""
        drawOverlayLabel(
            "BIND MARKS\(suffix)",
            at: CGPoint(x: anchor.x + 14, y: anchor.y + 14),
            foreground: pathColor.opacity(0.96),
            in: &context
        )
    }

    private var revealedLengthMm: Double {
        let totalLength = expectedPathSegments.reduce(0.0) { partial, segment in
            partial + segment.lengthMm
        }
        return totalLength * min(1.0, max(0.0, pathRevealProgress))
    }

    private func drawVisualMoveIntent(
        registration: PaperRegistrationSnapshot,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        guard let visualMoveIntent else { return }
        let widthMm = max(registration.paperSizeMm.width, 0.000_001)
        let heightMm = max(registration.paperSizeMm.height, 0.000_001)
        let startNorm = CGPoint(
            x: visualMoveIntent.startPaperMm.x / widthMm,
            y: visualMoveIntent.startPaperMm.y / heightMm
        )
        guard let cameraStart = paperToCameraPoint(startNorm, registration: registration) else {
            return
        }

        let start = mapper.point(cameraStart)
        guard let endPaperMm = visualMoveIntent.endPaperMm else {
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16)),
                with: .color(.black.opacity(0.82))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)),
                with: .color(.orange.opacity(0.98))
            )
            guard showMeasurements else { return }
            drawOverlayLabel(
                "\(visualMoveIntent.label) \(visualMoveIntent.detail)",
                at: CGPoint(x: start.x + 14, y: start.y - 12),
                foreground: .orange.opacity(0.98),
                font: .system(size: 11, weight: .bold, design: .monospaced),
                in: &context
            )
            return
        }
        let endNorm = CGPoint(
            x: endPaperMm.x / widthMm,
            y: endPaperMm.y / heightMm
        )
        guard let cameraEnd = paperToCameraPoint(endNorm, registration: registration) else {
            return
        }
        let end = mapper.point(cameraEnd)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
            path,
            with: .color(.black.opacity(0.88)),
            style: StrokeStyle(lineWidth: 13.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(.orange.opacity(0.98)),
            style: StrokeStyle(lineWidth: 8.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(.white.opacity(0.92)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )

        drawArrowHead(start: start, end: end, color: .orange, in: &context)
        context.fill(
            Path(ellipseIn: CGRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)),
            with: .color(.white.opacity(0.96))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)),
            with: .color(.orange.opacity(0.98))
        )

        guard showMeasurements else { return }
        drawOverlayLabel(
            "\(visualMoveIntent.label) \(visualMoveIntent.detail)",
            at: CGPoint(x: end.x + 14, y: end.y - 12),
            foreground: .orange.opacity(0.98),
            font: .system(size: 11, weight: .bold, design: .monospaced),
            in: &context
        )
    }

    private func drawArrowHead(
        start: CGPoint,
        end: CGPoint,
        color: Color,
        in context: inout GraphicsContext
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 8 else { return }
        let angle = atan2(dy, dx)
        let wing: CGFloat = 15
        let spread: CGFloat = .pi / 7
        var head = Path()
        head.move(to: end)
        head.addLine(
            to: CGPoint(
                x: end.x - wing * cos(angle - spread),
                y: end.y - wing * sin(angle - spread)
            )
        )
        head.move(to: end)
        head.addLine(
            to: CGPoint(
                x: end.x - wing * cos(angle + spread),
                y: end.y - wing * sin(angle + spread)
            )
        )
        context.stroke(
            head,
            with: .color(.black.opacity(0.88)),
            style: StrokeStyle(lineWidth: 9.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            head,
            with: .color(color.opacity(0.98)),
            style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
        )
    }

    private func draw(
        segment: VisionSegment,
        index: Int,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        let color = overlayColor(for: segment.kind, index: index)
        let rect = mapper.rect(segment.boundingBox)

        if segment.points.count > 1 {
            var contour = Path()
            contour.move(to: mapper.point(segment.points[0]))
            for point in segment.points.dropFirst() {
                contour.addLine(to: mapper.point(point))
            }
            if segment.points.count > 2 {
                contour.closeSubpath()
                context.fill(contour, with: .color(color.opacity(0.10)))
            }
            context.stroke(contour, with: .color(color.opacity(0.92)), lineWidth: segment.kind == .line ? 2.2 : 1.35)
        }

        let box = Path(roundedRect: rect, cornerRadius: 2)
        context.stroke(box, with: .color(color.opacity(0.72)), lineWidth: 1.0)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        var tick = Path()
        tick.move(to: CGPoint(x: center.x - 5, y: center.y))
        tick.addLine(to: CGPoint(x: center.x + 5, y: center.y))
        tick.move(to: CGPoint(x: center.x, y: center.y - 5))
        tick.addLine(to: CGPoint(x: center.x, y: center.y + 5))
        context.stroke(tick, with: .color(color.opacity(0.8)), lineWidth: 1.0)

        guard showMeasurements else { return }

        let labelPoint = CGPoint(x: max(8, rect.minX + 4), y: max(14, rect.minY - 9))
        drawOverlayLabel(
            String(format: "#%02d %@", index + 1, segment.label),
            at: labelPoint,
            foreground: color,
            font: .system(size: 10, weight: .semibold, design: .monospaced),
            in: &context
        )
    }

    private func draw(carriageMarker: CarriageMarker, mapper: OverlayMapper, in context: inout GraphicsContext) {
        let rect = mapper.rect(carriageMarker.boundingBox).insetBy(dx: -8, dy: -8)
        let center = mapper.point(carriageMarker.center)
        let color = carriageMarker.colorName.contains("BLUE")
            ? Color(red: 0.15, green: 0.56, blue: 1.0)
            : Color(red: 0.18, green: 1.0, blue: 0.22)

        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.86)), lineWidth: 7.0)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.98)), lineWidth: 3.2)

        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 30, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 30, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 30))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 30))
        context.stroke(cross, with: .color(.black.opacity(0.84)), lineWidth: 7.0)
        context.stroke(cross, with: .color(color.opacity(0.98)), lineWidth: 3.0)

        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
            with: .color(.white.opacity(0.98))
        )

        guard showMeasurements else { return }

        drawOverlayLabel(
            carriageMarker.label,
            at: CGPoint(x: center.x + 14, y: center.y + 12),
            foreground: color.opacity(0.98),
            in: &context
        )
    }

    private func draw(track: MotionTrack, mapper: OverlayMapper, in context: inout GraphicsContext) {
        let rect = mapper.rect(track.boundingBox).insetBy(dx: -3, dy: -3)
        let center = mapper.point(track.center)
        let vectorEnd = mapper.point(
            CGPoint(
                x: clamp(track.center.x + track.velocity.x * 4.0),
                y: clamp(track.center.y + track.velocity.y * 4.0)
            )
        )
        let color = Color(red: 0.40, green: 1.0, blue: 0.62)
        let hotColor = Color(red: 1.0, green: 0.27, blue: 0.50)

        context.fill(
            Path(roundedRect: rect, cornerRadius: 4),
            with: .color(color.opacity(0.08 + 0.14 * track.strength))
        )

        let outline = Path(roundedRect: rect, cornerRadius: 4)
        context.stroke(
            outline,
            with: .color(track.strength > 0.45 ? hotColor.opacity(0.9) : color.opacity(0.88)),
            style: StrokeStyle(lineWidth: 1.8, dash: [7, 4])
        )

        var vector = Path()
        vector.move(to: center)
        vector.addLine(to: vectorEnd)
        context.stroke(vector, with: .color(.white.opacity(0.86)), lineWidth: 1.3)

        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
            with: .color(color.opacity(0.95))
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
            with: .color(color.opacity(0.34)),
            lineWidth: 1.0
        )

        guard showMeasurements else { return }

        let labelPoint = CGPoint(x: max(10, rect.minX + 5), y: min(rect.maxY + 13, mapper.viewBottom - 18))
        drawOverlayLabel(
            track.label,
            at: labelPoint,
            foreground: color,
            font: .system(size: 11, weight: .bold, design: .monospaced),
            in: &context
        )

        drawOverlayLabel(
            String(format: "cells:%03d age:%02d", track.changedCells, track.ageReports),
            at: CGPoint(x: labelPoint.x, y: labelPoint.y + 13),
            foreground: .white.opacity(0.74),
            font: .system(size: 9, weight: .semibold, design: .monospaced),
            in: &context
        )
    }

    private func overlayColor(for kind: SegmentKind, index: Int) -> Color {
        switch kind {
        case .line:
            return index.isMultiple(of: 2) ? .cyan : .mint
        case .shape:
            return .yellow
        case .mark:
            return .pink
        case .contour:
            return .orange
        }
    }

    private func drawOverlayLabel(
        _ text: String,
        at point: CGPoint,
        anchor: OverlayLabelAnchor = .leading,
        foreground: Color,
        font: Font = .system(size: 10, weight: .bold, design: .monospaced),
        in context: inout GraphicsContext
    ) {
        let rect = overlayLabelRect(text, at: point, anchor: anchor)
        context.fill(
            Path(roundedRect: rect, cornerRadius: rect.height / 2),
            with: .color(.black.opacity(0.68))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: rect.height / 2),
            with: .color(.white.opacity(0.18)),
            lineWidth: 0.8
        )
        let label = Text(text)
            .font(font)
            .foregroundStyle(foreground)
        context.draw(label, at: point, anchor: anchor.unitPoint)
    }

    private func overlayLabelRect(
        _ text: String,
        at point: CGPoint,
        anchor: OverlayLabelAnchor
    ) -> CGRect {
        let width = max(28.0, CGFloat(text.count) * 6.5 + 14.0)
        let height = 18.0
        switch anchor {
        case .leading:
            return CGRect(x: point.x - 7.0, y: point.y - height / 2, width: width, height: height)
        case .bottomLeading:
            return CGRect(x: point.x - 7.0, y: point.y - height, width: width, height: height)
        case .topTrailing:
            return CGRect(x: point.x - width + 7.0, y: point.y, width: width, height: height)
        }
    }
}

private enum OverlayLabelAnchor {
    case leading
    case bottomLeading
    case topTrailing

    var unitPoint: UnitPoint {
        switch self {
        case .leading:
            return .leading
        case .bottomLeading:
            return .bottomLeading
        case .topTrailing:
            return .topTrailing
        }
    }
}

private struct OverlayMapper {
    let offset: CGPoint
    let displaySize: CGSize
    let viewBottom: CGFloat

    init(viewSize: CGSize, videoSize: CGSize, previewMode: CameraPreviewMode) {
        let sourceSize = videoSize.width > 0 && videoSize.height > 0
            ? videoSize
            : CGSize(width: 1280, height: 720)
        let imageAspect = sourceSize.width / sourceSize.height
        let viewAspect = max(viewSize.width, 1) / max(viewSize.height, 1)

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
        viewBottom = viewSize.height
    }

    func point(_ normalized: CGPoint) -> CGPoint {
        CGPoint(
            x: offset.x + normalized.x * displaySize.width,
            y: offset.y + (1.0 - normalized.y) * displaySize.height
        )
    }

    func rect(_ normalized: CGRect) -> CGRect {
        CGRect(
            x: offset.x + normalized.minX * displaySize.width,
            y: offset.y + (1.0 - normalized.maxY) * displaySize.height,
            width: normalized.width * displaySize.width,
            height: normalized.height * displaySize.height
        )
    }
}

private func clamp(_ value: CGFloat) -> CGFloat {
    min(1.0, max(0.0, value))
}

private func normalizedPoint(_ values: [Double]) -> CGPoint? {
    guard values.count >= 2 else { return nil }
    return CGPoint(x: clamp(CGFloat(values[0])), y: clamp(CGFloat(values[1])))
}

private func normalizedPoint(_ point: NormPoint) -> CGPoint {
    CGPoint(x: clamp(CGFloat(point.x)), y: clamp(CGFloat(point.y)))
}

private func paperToCameraPoint(
    _ paperNorm: CGPoint,
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
    guard cameraX >= -0.35, cameraX <= 1.35, cameraY >= -0.35, cameraY <= 1.35 else {
        return nil
    }
    return CGPoint(x: CGFloat(cameraX), y: CGFloat(cameraY))
}

private func visibleNormalizedPoint(_ point: NormPoint) -> CGPoint? {
    let x = CGFloat(point.x)
    let y = CGFloat(point.y)
    guard x >= 0.0, x <= 1.0, y >= 0.0, y <= 1.0 else { return nil }
    return CGPoint(x: x, y: y)
}

private func interpolate(start: CGPoint, end: CGPoint, fraction: Double) -> CGPoint {
    let clamped = min(1.0, max(0.0, fraction))
    return CGPoint(
        x: start.x + (end.x - start.x) * CGFloat(clamped),
        y: start.y + (end.y - start.y) * CGFloat(clamped)
    )
}
