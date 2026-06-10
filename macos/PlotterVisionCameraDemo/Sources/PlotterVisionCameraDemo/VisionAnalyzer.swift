import CoreGraphics
import CoreVideo
import Foundation
import Vision

final class VisionAnalyzer {
    func analyze(
        pixelBuffer: CVPixelBuffer,
        settings: AnalyzerSettings,
        frameNumber: Int
    ) throws -> VisionAnalysisResult {
        let start = CFAbsoluteTimeGetCurrent()
        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        var segments: [VisionSegment] = []

        if settings.enabled {
            let request = VNDetectContoursRequest()
            request.contrastAdjustment = Float(0.65 + settings.sensitivity * 1.35)
            request.detectsDarkOnLight = true
            request.maximumImageDimension = 960

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            try handler.perform([request])

            if let observation = request.results?.first {
                let contours = observation.topLevelContours
                var candidates: [(segment: VisionSegment, area: CGFloat)] = []

                for (index, contour) in contours.enumerated() {
                    let simplified = (try? contour.polygonApproximation(epsilon: 0.006)) ?? contour
                    let path = simplified.normalizedPath
                    let points = path.plotterDemoPoints(maxPoints: 180)
                    let bounds = points.normalizedBounds ?? path.boundingBoxOfPath

                    guard bounds.isUsable else { continue }

                    let areaRatio = bounds.width * bounds.height
                    guard areaRatio >= settings.minAreaRatio else { continue }

                    let pixelWidth = bounds.width * imageWidth
                    let pixelHeight = bounds.height * imageHeight
                    let pixelLength = max(pixelWidth, pixelHeight)
                    guard pixelLength >= 12 else { continue }

                    let pixelArea = areaRatio * imageWidth * imageHeight
                    let kind = classify(bounds: bounds, areaRatio: areaRatio, pixelLength: pixelLength)
                    let confidence = min(1.0, Double(areaRatio / 0.04))
                    let segment = VisionSegment(
                        id: frameNumber * 1000 + index,
                        kind: kind,
                        boundingBox: bounds,
                        points: points,
                        pixelLength: pixelLength,
                        pixelArea: pixelArea,
                        confidence: confidence
                    )
                    candidates.append((segment, areaRatio))
                }

                segments = candidates
                    .sorted { $0.area > $1.area }
                    .prefix(settings.maxSegments)
                    .map(\.segment)
            }
        }

        let fiducials = settings.redFiducialsEnabled
            ? detectRedFiducials(pixelBuffer: pixelBuffer, frameNumber: frameNumber)
            : []
        let carriageMarker = settings.greenMarkerEnabled
            ? detectCarriageMarker(
                pixelBuffer: pixelBuffer,
                colorTarget: settings.capMarkerColorTarget,
                frameNumber: frameNumber
            )
            : nil
        let paperRegistration = buildPaperRegistration(
            fiducials: fiducials,
            frameNumber: frameNumber
        )

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return VisionAnalysisResult(
            segments: segments,
            fiducials: fiducials,
            carriageMarker: carriageMarker,
            paperRegistration: paperRegistration,
            elapsedMilliseconds: elapsed
        )
    }

    private func classify(bounds: CGRect, areaRatio: CGFloat, pixelLength: CGFloat) -> SegmentKind {
        let aspect = bounds.width / max(bounds.height, 0.0001)

        if aspect > 7.0 || aspect < 1.0 / 7.0 {
            return .line
        }

        if areaRatio < 0.0035 || pixelLength < 42 {
            return .mark
        }

        if aspect > 0.68 && aspect < 1.42 {
            return .shape
        }

        return .contour
    }

    private func detectRedFiducials(
        pixelBuffer: CVPixelBuffer,
        frameNumber: Int
    ) -> [FiducialMark] {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return []
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = max(2, min(6, width / 320))
        let gridWidth = max(1, (width + stride - 1) / stride)
        let gridHeight = max(1, (height + stride - 1) / stride)
        var redMask = [UInt8](repeating: 0, count: gridWidth * gridHeight)

        for gy in 0..<gridHeight {
            let py = min(height - 1, gy * stride)
            let row = baseAddress.advanced(by: py * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for gx in 0..<gridWidth {
                let px = min(width - 1, gx * stride)
                let offset = px * 4
                let blue = Int(row[offset])
                let green = Int(row[offset + 1])
                let red = Int(row[offset + 2])
                if isFiducialRed(red: red, green: green, blue: blue) {
                    redMask[gy * gridWidth + gx] = 1
                }
            }
        }

        var components: [ColorComponent] = []
        var stack: [Int] = []
        let minSamples = 6
        let maxSamples = max(minSamples, gridWidth * gridHeight / 18)

        for index in redMask.indices where redMask[index] == 1 {
            redMask[index] = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(index)

            var component = ColorComponent(index: index, gridWidth: gridWidth)
            while let current = stack.popLast() {
                let gx = current % gridWidth
                let gy = current / gridWidth
                component.add(gx: gx, gy: gy)

                if gx > 0 {
                    enqueueMask(index: current - 1, mask: &redMask, stack: &stack)
                }
                if gx + 1 < gridWidth {
                    enqueueMask(index: current + 1, mask: &redMask, stack: &stack)
                }
                if gy > 0 {
                    enqueueMask(index: current - gridWidth, mask: &redMask, stack: &stack)
                }
                if gy + 1 < gridHeight {
                    enqueueMask(index: current + gridWidth, mask: &redMask, stack: &stack)
                }
            }

            guard component.count >= minSamples, component.count <= maxSamples else { continue }
            components.append(component)
        }

        let imageArea = CGFloat(width * height)
        let marks = components.compactMap { component -> FiducialMark? in
            let minX = CGFloat(component.minGX * stride)
            let maxX = CGFloat(min(width, (component.maxGX + 1) * stride))
            let minY = CGFloat(component.minGY * stride)
            let maxY = CGFloat(min(height, (component.maxGY + 1) * stride))
            let pixelWidth = maxX - minX
            let pixelHeight = maxY - minY
            let pixelArea = CGFloat(component.count * stride * stride)
            let areaRatio = pixelArea / max(imageArea, 1)
            let aspect = pixelWidth / max(pixelHeight, 1)

            guard pixelWidth >= 8, pixelHeight >= 8 else { return nil }
            guard areaRatio >= 0.00004, areaRatio <= 0.035 else { return nil }
            guard aspect >= 0.32, aspect <= 3.1 else { return nil }

            let rect = CGRect(
                x: minX / CGFloat(width),
                y: 1.0 - maxY / CGFloat(height),
                width: pixelWidth / CGFloat(width),
                height: pixelHeight / CGFloat(height)
            )
            let center = CGPoint(
                x: (minX + pixelWidth / 2) / CGFloat(width),
                y: 1.0 - (minY + pixelHeight / 2) / CGFloat(height)
            )
            let strength = min(1.0, Double(areaRatio / 0.003))
            return FiducialMark(
                id: frameNumber * 100 + component.count,
                boundingBox: rect,
                center: center,
                pixelArea: pixelArea,
                strength: strength
            )
        }

        return marks
            .sorted { $0.pixelArea > $1.pixelArea }
            .prefix(8)
            .enumerated()
            .map { offset, mark in
                FiducialMark(
                    id: offset + 1,
                    boundingBox: mark.boundingBox,
                    center: mark.center,
                    pixelArea: mark.pixelArea,
                    strength: mark.strength
                )
            }
    }

    private func isFiducialRed(red: Int, green: Int, blue: Int) -> Bool {
        guard red >= 115 else { return false }
        let strongestNonRed = max(green, blue)
        guard red - strongestNonRed >= 42 else { return false }
        guard Double(red) / Double(max(strongestNonRed, 1)) >= 1.42 else { return false }
        return green <= 175 && blue <= 175
    }

    private func detectCarriageMarker(
        pixelBuffer: CVPixelBuffer,
        colorTarget: CapMarkerColorTarget?,
        frameNumber: Int
    ) -> CarriageMarker? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stride = max(2, min(6, width / 320))
        let gridWidth = max(1, (width + stride - 1) / stride)
        let gridHeight = max(1, (height + stride - 1) / stride)
        var markerMask = [UInt8](repeating: 0, count: gridWidth * gridHeight)

        for gy in 0..<gridHeight {
            let py = min(height - 1, gy * stride)
            let row = baseAddress.advanced(by: py * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for gx in 0..<gridWidth {
                let px = min(width - 1, gx * stride)
                let offset = px * 4
                let blue = Int(row[offset])
                let green = Int(row[offset + 1])
                let red = Int(row[offset + 2])
                if isCarriageMarkerColor(red: red, green: green, blue: blue, target: colorTarget) {
                    markerMask[gy * gridWidth + gx] = 1
                }
            }
        }

        var components: [ColorComponent] = []
        var stack: [Int] = []
        let minSamples = 5
        let maxSamples = max(minSamples, gridWidth * gridHeight / 10)

        for index in markerMask.indices where markerMask[index] == 1 {
            markerMask[index] = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(index)

            var component = ColorComponent(index: index, gridWidth: gridWidth)
            while let current = stack.popLast() {
                let gx = current % gridWidth
                let gy = current / gridWidth
                component.add(gx: gx, gy: gy)

                if gx > 0 {
                    enqueueMask(index: current - 1, mask: &markerMask, stack: &stack)
                }
                if gx + 1 < gridWidth {
                    enqueueMask(index: current + 1, mask: &markerMask, stack: &stack)
                }
                if gy > 0 {
                    enqueueMask(index: current - gridWidth, mask: &markerMask, stack: &stack)
                }
                if gy + 1 < gridHeight {
                    enqueueMask(index: current + gridWidth, mask: &markerMask, stack: &stack)
                }
            }

            guard component.count >= minSamples, component.count <= maxSamples else { continue }
            components.append(component)
        }

        let imageArea = CGFloat(width * height)
        return components.compactMap { component -> CarriageMarker? in
            let minX = CGFloat(component.minGX * stride)
            let maxX = CGFloat(min(width, (component.maxGX + 1) * stride))
            let minY = CGFloat(component.minGY * stride)
            let maxY = CGFloat(min(height, (component.maxGY + 1) * stride))
            let pixelWidth = maxX - minX
            let pixelHeight = maxY - minY
            let pixelArea = CGFloat(component.count * stride * stride)
            let areaRatio = pixelArea / max(imageArea, 1)
            let aspect = pixelWidth / max(pixelHeight, 1)

            guard pixelWidth >= 8, pixelHeight >= 8 else { return nil }
            guard areaRatio >= 0.00003, areaRatio <= 0.065 else { return nil }
            guard aspect >= 0.22, aspect <= 4.6 else { return nil }

            let rect = CGRect(
                x: minX / CGFloat(width),
                y: 1.0 - maxY / CGFloat(height),
                width: pixelWidth / CGFloat(width),
                height: pixelHeight / CGFloat(height)
            )
            let center = CGPoint(
                x: (minX + pixelWidth / 2) / CGFloat(width),
                y: 1.0 - (minY + pixelHeight / 2) / CGFloat(height)
            )
            let strength = min(1.0, Double(areaRatio / 0.0025))
            return CarriageMarker(
                id: frameNumber,
                boundingBox: rect,
                center: center,
                pixelArea: pixelArea,
                strength: strength,
                colorName: colorTarget?.label ?? "GREEN"
            )
        }
        .max { $0.pixelArea < $1.pixelArea }
    }

    private func isCarriageMarkerColor(
        red: Int,
        green: Int,
        blue: Int,
        target: CapMarkerColorTarget?
    ) -> Bool {
        guard let target else {
            return isCarriageGreen(red: red, green: green, blue: blue)
        }
        return isSampledCarriageColor(red: red, green: green, blue: blue, target: target)
    }

    private func isCarriageGreen(red: Int, green: Int, blue: Int) -> Bool {
        guard green >= 105 else { return false }
        let strongestNonGreen = max(red, blue)
        guard green - strongestNonGreen >= 34 else { return false }
        guard Double(green) / Double(max(strongestNonGreen, 1)) >= 1.32 else { return false }
        return red <= 190 && blue <= 195
    }

    private func isSampledCarriageColor(
        red: Int,
        green: Int,
        blue: Int,
        target: CapMarkerColorTarget
    ) -> Bool {
        let r = Double(red)
        let g = Double(green)
        let b = Double(blue)
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        guard maxChannel >= 45.0, maxChannel - minChannel >= 12.0 else {
            return false
        }

        let candidateSum = max(r + g + b, 1.0)
        let targetSum = max(target.red + target.green + target.blue, 1.0)
        let dr = r / candidateSum - target.red / targetSum
        let dg = g / candidateSum - target.green / targetSum
        let db = b / candidateSum - target.blue / targetSum
        let chromaDistance = sqrt(dr * dr + dg * dg + db * db)

        let targetMax = max(target.red, max(target.green, target.blue))
        let valueRatio = maxChannel / max(targetMax, 1.0)
        guard valueRatio >= 0.35, valueRatio <= 2.7 else {
            return false
        }

        return chromaDistance <= target.tolerance
    }

    private func enqueueMask(index: Int, mask: inout [UInt8], stack: inout [Int]) {
        guard mask[index] == 1 else { return }
        mask[index] = 0
        stack.append(index)
    }

    private func buildPaperRegistration(
        fiducials: [FiducialMark],
        frameNumber: Int
    ) -> PaperRegistration? {
        guard fiducials.count >= 3 else { return nil }

        let selectedMarks = Array(fiducials.prefix(4))
        let orderedQuad = orderPaperQuad(selectedMarks.map(\.center))
        guard let bounds = orderedQuad.normalizedBounds, bounds.isUsable else { return nil }

        let averageStrength = selectedMarks.reduce(0.0) { $0 + $1.strength } / Double(selectedMarks.count)
        let countConfidence = min(1.0, Double(selectedMarks.count) / 4.0)
        return PaperRegistration(
            id: frameNumber,
            frameNumber: frameNumber,
            fiducialCount: fiducials.count,
            quad: orderedQuad,
            boundingBox: bounds,
            confidence: min(1.0, averageStrength * countConfidence)
        )
    }

    private func orderPaperQuad(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let center = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        let centroid = CGPoint(
            x: center.x / CGFloat(points.count),
            y: center.y / CGFloat(points.count)
        )
        let sorted = points.sorted {
            atan2($0.y - centroid.y, $0.x - centroid.x)
                < atan2($1.y - centroid.y, $1.x - centroid.x)
        }
        guard let startIndex = sorted.indices.min(by: {
            (sorted[$0].x + sorted[$0].y) < (sorted[$1].x + sorted[$1].y)
        }) else {
            return sorted
        }
        return Array(sorted[startIndex...]) + Array(sorted[..<startIndex])
    }
}

private struct ColorComponent {
    private(set) var minGX: Int
    private(set) var maxGX: Int
    private(set) var minGY: Int
    private(set) var maxGY: Int
    private(set) var count = 0

    init(index: Int, gridWidth: Int) {
        let gx = index % gridWidth
        let gy = index / gridWidth
        minGX = gx
        maxGX = gx
        minGY = gy
        maxGY = gy
    }

    mutating func add(gx: Int, gy: Int) {
        minGX = Swift.min(minGX, gx)
        maxGX = Swift.max(maxGX, gx)
        minGY = Swift.min(minGY, gy)
        maxGY = Swift.max(maxGY, gy)
        count += 1
    }
}

private extension CGRect {
    var isUsable: Bool {
        !isNull && !isInfinite && width > 0.00001 && height > 0.00001
    }
}

private extension Array where Element == CGPoint {
    var normalizedBounds: CGRect? {
        guard let first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in dropFirst() {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension CGPath {
    func plotterDemoPoints(maxPoints: Int) -> [CGPoint] {
        var points: [CGPoint] = []

        applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.points[0])
            case .addQuadCurveToPoint:
                points.append(element.points[1])
            case .addCurveToPoint:
                points.append(element.points[2])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }

        guard points.count > maxPoints, maxPoints > 1 else {
            return points
        }

        let strideSize = max(1, points.count / maxPoints)
        return points.enumerated().compactMap { index, point in
            index.isMultiple(of: strideSize) ? point : nil
        }
    }
}
