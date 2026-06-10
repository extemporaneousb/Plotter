import SwiftUI

struct MeasurementOverlay: View {
    let segments: [VisionSegment]
    let fiducials: [FiducialMark]
    let carriageMarker: CarriageMarker?
    let paperRegistration: PaperRegistration?
    let observedPenPoint: ObservedPenPoint?
    let motionTracks: [MotionTrack]
    let expectedPathSegments: [ExpectedPathSegment]
    let dotTestPreviewSegments: [DotTestPreviewSegment]
    let dotTestPreviewPoints: [DotTestPreviewPoint]
    let paperTransform: PaperRegistrationSnapshot?
    let plotterOverlay: PlotterOverlaySettings
    let drawingFrame: DrawingFrameSettings
    let pathRevealProgress: Double
    let workspaceXMm: Double
    let workspaceYMm: Double
    let videoSize: CGSize
    let previewMode: CameraPreviewMode
    let showGrid: Bool
    let showMeasurements: Bool

    var body: some View {
        Canvas { context, size in
            let mapper = OverlayMapper(viewSize: size, videoSize: videoSize, previewMode: previewMode)

            if showGrid {
                drawCameraCoordinateGrid(mapper: mapper, in: &context)
                if let paperTransform {
                    drawPaperCoordinateGrid(paperTransform, mapper: mapper, in: &context)
                }
                drawCenterReticle(mapper: mapper, in: &context)
            }

            let plotterMapper = PlotterPlaneMapper(
                mapper: mapper,
                aspectRatio: workspaceXMm / max(workspaceYMm, 1),
                settings: plotterOverlay
            )
            drawExpectedPath(mapper: plotterMapper, in: &context)

            if let paperRegistration {
                draw(paperRegistration: paperRegistration, mapper: mapper, in: &context)
            }

            drawDotTestPreview(mapper: mapper, in: &context)

            for fiducial in fiducials {
                draw(fiducial: fiducial, mapper: mapper, in: &context)
            }

            if let carriageMarker {
                draw(carriageMarker: carriageMarker, mapper: mapper, in: &context)
            }

            if let observedPenPoint {
                draw(observedPenPoint: observedPenPoint, mapper: mapper, in: &context)
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

    private func drawCameraCoordinateGrid(mapper: OverlayMapper, in context: inout GraphicsContext) {
        let minorValues = stride(from: 0.0, through: 1.000_1, by: 0.1).map { CGFloat(min($0, 1.0)) }
        var minorGrid = Path()
        for value in minorValues {
            minorGrid.move(to: mapper.point(CGPoint(x: value, y: 0)))
            minorGrid.addLine(to: mapper.point(CGPoint(x: value, y: 1)))
            minorGrid.move(to: mapper.point(CGPoint(x: 0, y: value)))
            minorGrid.addLine(to: mapper.point(CGPoint(x: 1, y: value)))
        }
        context.stroke(minorGrid, with: .color(.black.opacity(0.48)), lineWidth: 1.5)
        context.stroke(minorGrid, with: .color(.white.opacity(0.13)), lineWidth: 0.7)

        let majorValues: [CGFloat] = [0.0, 0.25, 0.5, 0.75, 1.0]
        var majorGrid = Path()
        for value in majorValues {
            majorGrid.move(to: mapper.point(CGPoint(x: value, y: 0)))
            majorGrid.addLine(to: mapper.point(CGPoint(x: value, y: 1)))
            majorGrid.move(to: mapper.point(CGPoint(x: 0, y: value)))
            majorGrid.addLine(to: mapper.point(CGPoint(x: 1, y: value)))
        }
        context.stroke(majorGrid, with: .color(.black.opacity(0.62)), lineWidth: 3.0)
        context.stroke(majorGrid, with: .color(.cyan.opacity(0.44)), lineWidth: 1.0)

        guard showMeasurements else { return }

        for value in majorValues {
            let xLabel = Text(String(format: "cam x%.2f", Double(value)))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.86))
            context.draw(
                xLabel,
                at: mapper.point(CGPoint(x: value, y: 0.015)),
                anchor: .bottom
            )

            let yLabel = Text(String(format: "y%.2f", Double(value)))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan.opacity(0.86))
            context.draw(
                yLabel,
                at: mapper.point(CGPoint(x: 0.012, y: value)),
                anchor: .leading
            )
        }
    }

    private func drawPaperCoordinateGrid(
        _ registration: PaperRegistrationSnapshot,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        let widthMm = registration.paperSizeMm.width
        let heightMm = registration.paperSizeMm.height
        guard widthMm > 0, heightMm > 0 else { return }

        let stepMm = majorPaperGridStep(widthMm: widthMm, heightMm: heightMm)
        let color = Color(red: 1.0, green: 0.25, blue: 0.72)
        var grid = Path()

        var xMm = 0.0
        while xMm <= widthMm + 0.001 {
            let xNorm = CGFloat(xMm / widthMm)
            if let start = paperToCameraPoint(CGPoint(x: xNorm, y: 0), registration: registration),
               let end = paperToCameraPoint(CGPoint(x: xNorm, y: 1), registration: registration) {
                grid.move(to: mapper.point(start))
                grid.addLine(to: mapper.point(end))
            }
            xMm += stepMm
        }

        var yMm = 0.0
        while yMm <= heightMm + 0.001 {
            let yNorm = CGFloat(yMm / heightMm)
            if let start = paperToCameraPoint(CGPoint(x: 0, y: yNorm), registration: registration),
               let end = paperToCameraPoint(CGPoint(x: 1, y: yNorm), registration: registration) {
                grid.move(to: mapper.point(start))
                grid.addLine(to: mapper.point(end))
            }
            yMm += stepMm
        }

        context.stroke(grid, with: .color(.black.opacity(0.70)), lineWidth: 4.0)
        context.stroke(grid, with: .color(color.opacity(0.74)), lineWidth: 1.25)

        guard showMeasurements else { return }

        if let origin = paperToCameraPoint(CGPoint(x: 0, y: 0), registration: registration) {
            let label = Text(String(format: "PAPER mm grid %.0fmm", stepMm))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.96))
            context.draw(label, at: mapper.point(origin), anchor: .bottomLeading)
        }
    }

    private func drawCenterReticle(mapper: OverlayMapper, in context: inout GraphicsContext) {
        let center = mapper.point(CGPoint(x: 0.5, y: 0.5))
        var reticle = Path()
        reticle.move(to: CGPoint(x: center.x - 34, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x - 10, y: center.y))
        reticle.move(to: CGPoint(x: center.x + 10, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x + 34, y: center.y))
        reticle.move(to: CGPoint(x: center.x, y: center.y - 34))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y - 10))
        reticle.move(to: CGPoint(x: center.x, y: center.y + 10))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y + 34))

        context.stroke(reticle, with: .color(.cyan.opacity(0.52)), lineWidth: 1.2)
        context.stroke(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                       with: .color(.yellow.opacity(0.72)),
                       lineWidth: 1.1)
    }

    private func drawPlotterPlane(mapper: PlotterPlaneMapper, in context: inout GraphicsContext) {
        guard plotterOverlay.enabled else { return }

        let opacity = plotterOverlay.opacity
        let bed = mapper.path(for: [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1),
        ], closed: true)

        context.fill(bed, with: .color(.cyan.opacity(0.28 * opacity)))
        context.stroke(bed, with: .color(.cyan.opacity(0.94 * opacity)), lineWidth: 2.2)

        var grid = Path()
        for column in 1..<8 {
            let x = CGFloat(column) / 8.0
            grid.move(to: mapper.point(CGPoint(x: x, y: 0)))
            grid.addLine(to: mapper.point(CGPoint(x: x, y: 1)))
        }
        for row in 1..<4 {
            let y = CGFloat(row) / 4.0
            grid.move(to: mapper.point(CGPoint(x: 0, y: y)))
            grid.addLine(to: mapper.point(CGPoint(x: 1, y: y)))
        }
        context.stroke(grid, with: .color(.cyan.opacity(0.34 * opacity)), lineWidth: 0.9)

        var rails = Path()
        rails.move(to: mapper.point(CGPoint(x: 0, y: 1)))
        rails.addLine(to: mapper.point(CGPoint(x: 1, y: 1)))
        rails.move(to: mapper.point(CGPoint(x: 0, y: 0)))
        rails.addLine(to: mapper.point(CGPoint(x: 1, y: 0)))
        context.stroke(rails, with: .color(.white.opacity(0.32 * opacity)), lineWidth: 2.2)

        let pen = virtualPenPoint
        var gantry = Path()
        gantry.move(to: mapper.point(CGPoint(x: pen.x, y: 0)))
        gantry.addLine(to: mapper.point(CGPoint(x: pen.x, y: 1)))
        context.stroke(gantry, with: .color(.mint.opacity(0.58 * opacity)), lineWidth: 1.5)

        let penPoint = mapper.point(pen)
        context.fill(
            Path(ellipseIn: CGRect(x: penPoint.x - 5, y: penPoint.y - 5, width: 10, height: 10)),
            with: .color(.yellow.opacity(0.92 * opacity))
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: penPoint.x - 12, y: penPoint.y - 12, width: 24, height: 24)),
            with: .color(.yellow.opacity(0.45 * opacity)),
            lineWidth: 1.2
        )

        guard showMeasurements else { return }

        let label = Text(String(format: "%.0f x %.0f mm", workspaceXMm, workspaceYMm))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.cyan.opacity(0.86))
        context.draw(label, at: mapper.point(CGPoint(x: 0, y: 1)), anchor: .bottomLeading)
    }

    private func drawDrawingFrame(mapper: PlotterPlaneMapper, in context: inout GraphicsContext) {
        guard plotterOverlay.enabled else { return }

        let opacity = plotterOverlay.opacity
        let rect = drawingFrame.rect(workspaceXMm: workspaceXMm, workspaceYMm: workspaceYMm)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let framePath = mapper.path(for: corners, closed: true)

        context.fill(framePath, with: .color(.yellow.opacity(0.10 * opacity)))
        context.stroke(
            framePath,
            with: .color(.yellow.opacity(0.95 * opacity)),
            style: StrokeStyle(lineWidth: 2.0, dash: [10, 5])
        )

        var cross = Path()
        cross.move(to: mapper.point(CGPoint(x: rect.midX, y: rect.minY)))
        cross.addLine(to: mapper.point(CGPoint(x: rect.midX, y: rect.maxY)))
        cross.move(to: mapper.point(CGPoint(x: rect.minX, y: rect.midY)))
        cross.addLine(to: mapper.point(CGPoint(x: rect.maxX, y: rect.midY)))
        context.stroke(cross, with: .color(.yellow.opacity(0.28 * opacity)), lineWidth: 0.9)

        guard showMeasurements else { return }

        let widthMm = rect.width * workspaceXMm
        let heightMm = rect.height * workspaceYMm
        let label = Text(String(format: "FRAME %.0f x %.0f mm", widthMm, heightMm))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow.opacity(0.88))
        context.draw(label, at: mapper.point(CGPoint(x: rect.minX, y: rect.maxY)), anchor: .bottomLeading)
    }

    private func drawExpectedPath(mapper: PlotterPlaneMapper, in context: inout GraphicsContext) {
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
            path.move(to: mapper.point(start))
            path.addLine(to: mapper.point(visibleEnd))
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
            let startPoint = mapper.point(start)
            let endPoint = mapper.point(end)
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
              let start = normalizedPoint(first.startNorm) else {
            return
        }

        let label = Text("EXPECTED")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.yellow.opacity(0.9 * plotterOverlay.opacity))
        let point = mapper.point(start)
        context.draw(label, at: CGPoint(x: point.x + 8, y: point.y - 10), anchor: .leading)
    }

    private func drawDotTestPreview(mapper: OverlayMapper, in context: inout GraphicsContext) {
        guard !dotTestPreviewSegments.isEmpty || !dotTestPreviewPoints.isEmpty else { return }

        let pathColor = Color(red: 0.15, green: 0.95, blue: 1.0)
        let pointColor = Color(red: 1.0, green: 0.18, blue: 0.72)
        var hiddenProjectionCount = 0

        if !dotTestPreviewSegments.isEmpty {
            for segment in dotTestPreviewSegments {
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

        for point in dotTestPreviewPoints {
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

            let label = Text(
                String(
                    format: "%@ %.0f,%.0f",
                    point.pointId,
                    point.paperMm.x,
                    point.paperMm.y
                )
            )
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(pointColor.opacity(0.96))
            context.draw(label, at: CGPoint(x: center.x + 14, y: center.y - 13), anchor: .leading)
        }

        guard showMeasurements, let first = dotTestPreviewPoints.first else { return }
        let anchor = mapper.point(normalizedPoint(first.cameraNorm))
        let suffix = hiddenProjectionCount > 0 ? String(format: "  HIDDEN:%d", hiddenProjectionCount) : ""
        let label = Text("DOT PREVIEW\(suffix)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(pathColor.opacity(0.96))
        context.draw(label, at: CGPoint(x: anchor.x + 14, y: anchor.y + 14), anchor: .leading)
    }

    private var virtualPenPoint: CGPoint {
        guard !expectedPathSegments.isEmpty else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let revealLength = revealedLengthMm
        var consumedLength = 0.0
        for segment in expectedPathSegments {
            guard let start = normalizedPoint(segment.startNorm),
                  let end = normalizedPoint(segment.endNorm) else {
                continue
            }
            if revealLength <= consumedLength + segment.lengthMm {
                let fraction = (revealLength - consumedLength) / max(segment.lengthMm, 0.000_001)
                return interpolate(start: start, end: end, fraction: fraction)
            }
            consumedLength += segment.lengthMm
        }

        guard let last = expectedPathSegments.last,
              let end = normalizedPoint(last.endNorm) else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return end
    }

    private var revealedLengthMm: Double {
        let totalLength = expectedPathSegments.reduce(0.0) { partial, segment in
            partial + segment.lengthMm
        }
        return totalLength * min(1.0, max(0.0, pathRevealProgress))
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

        let label = Text(String(format: "#%02d %@", index + 1, segment.label))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
        let labelPoint = CGPoint(x: max(8, rect.minX + 4), y: max(14, rect.minY - 9))
        context.draw(label, at: labelPoint, anchor: .leading)
    }

    private func draw(
        paperRegistration: PaperRegistration,
        mapper: OverlayMapper,
        in context: inout GraphicsContext
    ) {
        guard paperRegistration.quad.count >= 3 else { return }

        var paperPath = Path()
        paperPath.move(to: mapper.point(paperRegistration.quad[0]))
        for point in paperRegistration.quad.dropFirst() {
            paperPath.addLine(to: mapper.point(point))
        }
        paperPath.closeSubpath()

        let color = Color(red: 1.0, green: 0.10, blue: 0.08)
        context.fill(paperPath, with: .color(color.opacity(0.06)))
        context.stroke(
            paperPath,
            with: .color(color.opacity(paperRegistration.status == "LOCK" ? 0.95 : 0.68)),
            style: StrokeStyle(lineWidth: 2.1, dash: paperRegistration.status == "LOCK" ? [] : [7, 5])
        )

        guard showMeasurements else { return }

        let label = Text(
            String(format: "PAPER %@  FID:%d  %.0f%%",
                   paperRegistration.status,
                   paperRegistration.fiducialCount,
                   paperRegistration.confidence * 100)
        )
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundStyle(color.opacity(0.95))
        context.draw(
            label,
            at: mapper.point(CGPoint(x: paperRegistration.boundingBox.minX, y: paperRegistration.boundingBox.maxY)),
            anchor: .bottomLeading
        )
    }

    private func draw(fiducial: FiducialMark, mapper: OverlayMapper, in context: inout GraphicsContext) {
        let rect = mapper.rect(fiducial.boundingBox).insetBy(dx: -4, dy: -4)
        let center = mapper.point(fiducial.center)
        let color = Color(red: 1.0, green: 0.08, blue: 0.07)

        context.stroke(
            Path(ellipseIn: rect),
            with: .color(color.opacity(0.96)),
            lineWidth: 2.0
        )
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
            with: .color(color.opacity(0.98))
        )

        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 10, y: center.y))
        cross.addLine(to: CGPoint(x: center.x + 10, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 10))
        cross.addLine(to: CGPoint(x: center.x, y: center.y + 10))
        context.stroke(cross, with: .color(.white.opacity(0.78)), lineWidth: 1.0)

        guard showMeasurements else { return }

        let label = Text(fiducial.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
        context.draw(label, at: CGPoint(x: rect.maxX + 4, y: rect.midY), anchor: .leading)
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

        let label = Text(carriageMarker.label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color.opacity(0.98))
        context.draw(label, at: CGPoint(x: center.x + 14, y: center.y + 12), anchor: .leading)
    }

    private func draw(observedPenPoint: ObservedPenPoint, mapper: OverlayMapper, in context: inout GraphicsContext) {
        let center = mapper.point(observedPenPoint.cameraPoint)
        let color = Color(red: 0.62, green: 1.0, blue: 0.30)
        let outer = CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)
        let middle = CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)

        context.stroke(Path(ellipseIn: outer), with: .color(.black.opacity(0.86)), lineWidth: 7.0)
        context.stroke(Path(ellipseIn: middle), with: .color(color.opacity(0.98)), lineWidth: 3.4)

        var tick = Path()
        tick.move(to: CGPoint(x: center.x - 36, y: center.y))
        tick.addLine(to: CGPoint(x: center.x + 36, y: center.y))
        tick.move(to: CGPoint(x: center.x, y: center.y - 36))
        tick.addLine(to: CGPoint(x: center.x, y: center.y + 36))
        context.stroke(tick, with: .color(.black.opacity(0.82)), lineWidth: 7.0)
        context.stroke(tick, with: .color(.white.opacity(0.96)), lineWidth: 2.8)

        guard showMeasurements else { return }

        let label = Text(observedPenPoint.label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color.opacity(0.98))
        context.draw(label, at: CGPoint(x: center.x + 15, y: center.y - 16), anchor: .leading)
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

        let label = Text(track.label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
        let labelPoint = CGPoint(x: max(10, rect.minX + 5), y: min(rect.maxY + 13, mapper.viewBottom - 18))
        context.draw(label, at: labelPoint, anchor: .leading)

        let detail = Text(String(format: "cells:%03d age:%02d", track.changedCells, track.ageReports))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.74))
        context.draw(detail, at: CGPoint(x: labelPoint.x, y: labelPoint.y + 13), anchor: .leading)
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

private struct PlotterPlaneMapper {
    private let center: CGPoint
    private let width: CGFloat
    private let height: CGFloat
    private let rotationRadians: CGFloat

    init(mapper: OverlayMapper, aspectRatio: Double, settings: PlotterOverlaySettings) {
        let displaySize = mapper.displaySize
        let displayCenter = CGPoint(
            x: mapper.offset.x + displaySize.width / 2,
            y: mapper.offset.y + displaySize.height / 2
        )
        let targetAspect = max(CGFloat(aspectRatio), 0.1)
        let maxWidth = displaySize.width * 0.84
        let maxHeight = displaySize.height * 0.72
        let fitWidth = min(maxWidth, maxHeight * targetAspect)
        let fitHeight = fitWidth / targetAspect
        let clampedScale = max(0.15, min(1.6, CGFloat(settings.scale)))

        center = CGPoint(
            x: displayCenter.x + CGFloat(settings.offsetX) * displaySize.width,
            y: displayCenter.y + CGFloat(settings.offsetY) * displaySize.height
        )
        width = fitWidth * clampedScale
        height = fitHeight * clampedScale
        rotationRadians = CGFloat(settings.rotationDegrees) * .pi / 180.0
    }

    func point(_ normalized: CGPoint) -> CGPoint {
        let local = CGPoint(
            x: (normalized.x - 0.5) * width,
            y: (0.5 - normalized.y) * height
        )
        let cosTheta = cos(rotationRadians)
        let sinTheta = sin(rotationRadians)
        return CGPoint(
            x: center.x + local.x * cosTheta - local.y * sinTheta,
            y: center.y + local.x * sinTheta + local.y * cosTheta
        )
    }

    func path(for normalizedPoints: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = normalizedPoints.first else { return path }
        path.move(to: point(first))
        for normalized in normalizedPoints.dropFirst() {
            path.addLine(to: point(normalized))
        }
        if closed {
            path.closeSubpath()
        }
        return path
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

private func majorPaperGridStep(widthMm: Double, heightMm: Double) -> Double {
    let maxDimension = max(widthMm, heightMm)
    if maxDimension >= 450 { return 50.0 }
    if maxDimension >= 220 { return 25.0 }
    return 10.0
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
