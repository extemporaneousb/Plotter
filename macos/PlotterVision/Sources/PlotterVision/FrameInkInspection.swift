import CoreGraphics
import CoreVideo
import Foundation

enum InkProgramPrimitiveKind: String, Equatable {
    case mark
    case line
    case circle
    case arc
    case denseStroke = "dense_stroke"
}

struct InkProgramPrimitive: Equatable {
    let primitiveId: String
    let kind: InkProgramPrimitiveKind
    let expectedPointsMm: [PaperPointMmSnapshot]
    let centerMm: PaperPointMmSnapshot?
    let radiusMm: Double?
    let startAngleDeg: Double?
    let endAngleDeg: Double?
    let closed: Bool
    let sampleCountHint: Int?

    static func mark(
        primitiveId: String,
        center: PaperPointMmSnapshot,
        sampleCountHint: Int? = nil
    ) -> InkProgramPrimitive {
        InkProgramPrimitive(
            primitiveId: primitiveId,
            kind: .mark,
            expectedPointsMm: [center],
            centerMm: center,
            radiusMm: nil,
            startAngleDeg: nil,
            endAngleDeg: nil,
            closed: false,
            sampleCountHint: sampleCountHint
        )
    }

    static func line(
        primitiveId: String,
        start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot,
        sampleCountHint: Int? = nil
    ) -> InkProgramPrimitive {
        InkProgramPrimitive(
            primitiveId: primitiveId,
            kind: .line,
            expectedPointsMm: [start, end],
            centerMm: nil,
            radiusMm: nil,
            startAngleDeg: nil,
            endAngleDeg: nil,
            closed: false,
            sampleCountHint: sampleCountHint
        )
    }

    static func circle(
        primitiveId: String,
        center: PaperPointMmSnapshot,
        radiusMm: Double,
        sampleCountHint: Int? = nil
    ) -> InkProgramPrimitive {
        InkProgramPrimitive(
            primitiveId: primitiveId,
            kind: .circle,
            expectedPointsMm: [],
            centerMm: center,
            radiusMm: radiusMm,
            startAngleDeg: 0,
            endAngleDeg: 360,
            closed: true,
            sampleCountHint: sampleCountHint
        )
    }

    static func arc(
        primitiveId: String,
        center: PaperPointMmSnapshot,
        radiusMm: Double,
        startAngleDeg: Double,
        endAngleDeg: Double,
        sampleCountHint: Int? = nil
    ) -> InkProgramPrimitive {
        InkProgramPrimitive(
            primitiveId: primitiveId,
            kind: .arc,
            expectedPointsMm: [],
            centerMm: center,
            radiusMm: radiusMm,
            startAngleDeg: startAngleDeg,
            endAngleDeg: endAngleDeg,
            closed: false,
            sampleCountHint: sampleCountHint
        )
    }

    static func denseStroke(
        primitiveId: String,
        points: [PaperPointMmSnapshot],
        closed: Bool = false
    ) -> InkProgramPrimitive {
        InkProgramPrimitive(
            primitiveId: primitiveId,
            kind: .denseStroke,
            expectedPointsMm: points,
            centerMm: nil,
            radiusMm: nil,
            startAngleDeg: nil,
            endAngleDeg: nil,
            closed: closed,
            sampleCountHint: points.count
        )
    }
}

struct InkProgramObservedSample: Equatable {
    let primitiveId: String
    let sampleIndex: Int
    let expectedMm: PaperPointMmSnapshot
    let expectedCameraNorm: NormPoint?
    let observedMm: PaperPointMmSnapshot?
    let observedCameraNorm: NormPoint?
    let residualMm: Double?
    let detected: Bool
    let greenPixelCount: Int
}

struct InkProgramPrimitiveInspection: Equatable {
    let primitiveId: String
    let kind: InkProgramPrimitiveKind
    let sampleCount: Int
    let detectedSampleCount: Int
    let greenPixelCount: Int
    let coverageFraction: Double
    let rmsResidualMm: Double?
    let p95ResidualMm: Double?
    let maxResidualMm: Double?
    let observedSamples: [InkProgramObservedSample]
}

struct InkProgramInspectionResult: Equatable {
    let programId: String
    let programKind: String
    let imageSize: CGSize
    let primitives: [InkProgramPrimitiveInspection]

    var samples: [InkProgramObservedSample] {
        primitives.flatMap(\.observedSamples)
    }

    var sampleCount: Int {
        primitives.reduce(0) { $0 + $1.sampleCount }
    }

    var detectedSampleCount: Int {
        primitives.reduce(0) { $0 + $1.detectedSampleCount }
    }

    var totalGreenPixels: Int {
        primitives.reduce(0) { $0 + $1.greenPixelCount }
    }

    var coverageFraction: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(detectedSampleCount) / Double(sampleCount)
    }

    var rmsResidualMm: Double? {
        let residuals = samples.compactMap(\.residualMm)
        guard !residuals.isEmpty else { return nil }
        return sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / Double(residuals.count))
    }

    var p95ResidualMm: Double? {
        percentileResidual(0.95)
    }

    var maxResidualMm: Double? {
        samples.compactMap(\.residualMm).max()
    }

    var isUsable: Bool {
        detectedSampleCount >= 4 && coverageFraction >= 0.08
    }

    private func percentileResidual(_ percentile: Double) -> Double? {
        let residuals = samples.compactMap(\.residualMm).sorted()
        guard !residuals.isEmpty else { return nil }
        let clamped = min(1.0, max(0.0, percentile))
        let index = Int(ceil(clamped * Double(residuals.count))) - 1
        return residuals[min(max(index, 0), residuals.count - 1)]
    }
}

enum InkProgramInspector {
    static func inspect(
        pixelBuffer: CVPixelBuffer,
        primitives: [InkProgramPrimitive],
        registration: PaperRegistrationSnapshot,
        colorTarget: CapMarkerColorTarget?,
        programId: String,
        programKind: String
    ) -> InkProgramInspectionResult? {
        guard !primitives.isEmpty else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1 else { return nil }

        let inspected = primitives.map { primitive in
            inspectPrimitive(
                primitive,
                registration: registration,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                baseAddress: baseAddress,
                colorTarget: colorTarget
            )
        }
        return InkProgramInspectionResult(
            programId: programId,
            programKind: programKind,
            imageSize: CGSize(width: width, height: height),
            primitives: inspected
        )
    }

    static func isGreenFramePixel(
        red: Int,
        green: Int,
        blue: Int,
        target: CapMarkerColorTarget?
    ) -> Bool {
        if let target, isSampledGreenFramePixel(red: red, green: green, blue: blue, target: target) {
            return true
        }
        guard green >= 62 else { return false }
        let strongestNonGreen = max(red, blue)
        guard green - strongestNonGreen >= 16 else { return false }
        guard Double(green) / Double(max(strongestNonGreen, 1)) >= 1.16 else { return false }
        return red <= 215 && blue <= 215
    }

    private static func inspectPrimitive(
        _ primitive: InkProgramPrimitive,
        registration: PaperRegistrationSnapshot,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        baseAddress: UnsafeMutableRawPointer,
        colorTarget: CapMarkerColorTarget?
    ) -> InkProgramPrimitiveInspection {
        let expectedSamples = expectedSamplePoints(for: primitive, registration: registration, width: width, height: height)
        let samples = expectedSamples.enumerated().map { index, expected in
            inspectExpectedPoint(
                primitiveId: primitive.primitiveId,
                sampleIndex: index,
                expectedMm: expected,
                registration: registration,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                baseAddress: baseAddress,
                colorTarget: colorTarget
            )
        }
        let detected = samples.filter(\.detected)
        let residuals = detected.compactMap(\.residualMm).sorted()
        let rms = residuals.isEmpty
            ? nil
            : sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / Double(residuals.count))
        let p95 = percentile(residuals, 0.95)
        return InkProgramPrimitiveInspection(
            primitiveId: primitive.primitiveId,
            kind: primitive.kind,
            sampleCount: samples.count,
            detectedSampleCount: detected.count,
            greenPixelCount: samples.reduce(0) { $0 + $1.greenPixelCount },
            coverageFraction: samples.isEmpty ? 0 : Double(detected.count) / Double(samples.count),
            rmsResidualMm: rms,
            p95ResidualMm: p95,
            maxResidualMm: residuals.max(),
            observedSamples: samples
        )
    }

    private static func inspectExpectedPoint(
        primitiveId: String,
        sampleIndex: Int,
        expectedMm: PaperPointMmSnapshot,
        registration: PaperRegistrationSnapshot,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        baseAddress: UnsafeMutableRawPointer,
        colorTarget: CapMarkerColorTarget?
    ) -> InkProgramObservedSample {
        let expectedCamera = paperToCameraPoint(expectedMm, registration: registration)
        guard let expectedCamera else {
            return InkProgramObservedSample(
                primitiveId: primitiveId,
                sampleIndex: sampleIndex,
                expectedMm: expectedMm,
                expectedCameraNorm: nil,
                observedMm: nil,
                observedCameraNorm: nil,
                residualMm: nil,
                detected: false,
                greenPixelCount: 0
            )
        }

        let pixel = pixelPoint(expectedCamera, width: width, height: height)
        let searchRadiusPx = 12
        var hitX = 0.0
        var hitY = 0.0
        var hitCount = 0
        for yOffset in -searchRadiusPx...searchRadiusPx {
            let sampleY = Int(round(pixel.y)) + yOffset
            guard sampleY >= 0, sampleY < height else { continue }
            let row = baseAddress.advanced(by: sampleY * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for xOffset in -searchRadiusPx...searchRadiusPx {
                let sampleX = Int(round(pixel.x)) + xOffset
                guard sampleX >= 0, sampleX < width else { continue }
                let pixelOffset = sampleX * 4
                let blue = Int(row[pixelOffset])
                let green = Int(row[pixelOffset + 1])
                let red = Int(row[pixelOffset + 2])
                guard isGreenFramePixel(red: red, green: green, blue: blue, target: colorTarget) else {
                    continue
                }
                hitX += Double(sampleX)
                hitY += Double(sampleY)
                hitCount += 1
            }
        }

        guard hitCount > 0 else {
            return InkProgramObservedSample(
                primitiveId: primitiveId,
                sampleIndex: sampleIndex,
                expectedMm: expectedMm,
                expectedCameraNorm: NormPoint(expectedCamera),
                observedMm: nil,
                observedCameraNorm: nil,
                residualMm: nil,
                detected: false,
                greenPixelCount: 0
            )
        }

        let observedPixel = CGPoint(x: hitX / Double(hitCount), y: hitY / Double(hitCount))
        let observedCamera = cameraPoint(pixel: observedPixel, width: width, height: height)
        let observedPaper = cameraToPaperPoint(observedCamera, registration: registration)
        return InkProgramObservedSample(
            primitiveId: primitiveId,
            sampleIndex: sampleIndex,
            expectedMm: expectedMm,
            expectedCameraNorm: NormPoint(expectedCamera),
            observedMm: observedPaper,
            observedCameraNorm: NormPoint(observedCamera),
            residualMm: observedPaper.map { distance($0, expectedMm) },
            detected: observedPaper != nil,
            greenPixelCount: hitCount
        )
    }

    private static func expectedSamplePoints(
        for primitive: InkProgramPrimitive,
        registration: PaperRegistrationSnapshot,
        width: Int,
        height: Int
    ) -> [PaperPointMmSnapshot] {
        switch primitive.kind {
        case .mark:
            return Array(primitive.expectedPointsMm.prefix(1))
        case .line:
            guard primitive.expectedPointsMm.count >= 2 else { return primitive.expectedPointsMm }
            let start = primitive.expectedPointsMm[0]
            let end = primitive.expectedPointsMm[1]
            let sampleCount = primitive.sampleCountHint ?? lineSampleCount(start: start, end: end, registration: registration, width: width, height: height)
            return (0...max(sampleCount, 1)).map { index in
                let fraction = Double(index) / Double(max(sampleCount, 1))
                return PaperPointMmSnapshot(
                    x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction
                )
            }
        case .circle, .arc:
            guard let center = primitive.centerMm,
                  let radius = primitive.radiusMm,
                  radius > 0 else {
                return []
            }
            let startDeg = primitive.startAngleDeg ?? 0
            let endDeg = primitive.endAngleDeg ?? (primitive.closed ? 360 : startDeg)
            let sweep = primitive.closed ? 360.0 : endDeg - startDeg
            let sampleCount = max(primitive.sampleCountHint ?? Int(abs(sweep) / 360.0 * 128.0), 8)
            return (0...sampleCount).map { index in
                let fraction = Double(index) / Double(max(sampleCount, 1))
                let angle = (startDeg + sweep * fraction) * .pi / 180.0
                return PaperPointMmSnapshot(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius
                )
            }
        case .denseStroke:
            return primitive.expectedPointsMm
        }
    }

    private static func lineSampleCount(
        start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot,
        registration: PaperRegistrationSnapshot,
        width: Int,
        height: Int
    ) -> Int {
        guard let cameraStart = paperToCameraPoint(start, registration: registration),
              let cameraEnd = paperToCameraPoint(end, registration: registration) else {
            return 64
        }
        let pixelStart = pixelPoint(cameraStart, width: width, height: height)
        let pixelEnd = pixelPoint(cameraEnd, width: width, height: height)
        let edgeLength = hypot(pixelEnd.x - pixelStart.x, pixelEnd.y - pixelStart.y)
        return min(480, max(32, Int(edgeLength / 2.4)))
    }

    private static func paperToCameraPoint(
        _ paperMm: PaperPointMmSnapshot,
        registration: PaperRegistrationSnapshot
    ) -> CGPoint? {
        let coefficients = registration.paperToCamera.coefficients
        guard coefficients.count == 9,
              registration.paperSizeMm.width > 0,
              registration.paperSizeMm.height > 0 else {
            return nil
        }
        let x = paperMm.x / registration.paperSizeMm.width
        let y = paperMm.y / registration.paperSizeMm.height
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }
        let cameraX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let cameraY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        guard cameraX >= -0.35, cameraX <= 1.35, cameraY >= -0.35, cameraY <= 1.35 else {
            return nil
        }
        return CGPoint(x: cameraX, y: cameraY)
    }

    private static func cameraToPaperPoint(
        _ cameraPoint: CGPoint,
        registration: PaperRegistrationSnapshot
    ) -> PaperPointMmSnapshot? {
        let coefficients = registration.cameraToPaper.coefficients
        guard coefficients.count == 9 else { return nil }
        let x = Double(cameraPoint.x)
        let y = Double(cameraPoint.y)
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }
        let paperX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let paperY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        return PaperPointMmSnapshot(
            x: paperX * registration.paperSizeMm.width,
            y: paperY * registration.paperSizeMm.height
        )
    }

    private static func pixelPoint(_ cameraPoint: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: Double(cameraPoint.x) * Double(width - 1),
            y: (1.0 - Double(cameraPoint.y)) * Double(height - 1)
        )
    }

    private static func cameraPoint(pixel: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: Double(pixel.x) / Double(max(width - 1, 1)),
            y: 1.0 - Double(pixel.y) / Double(max(height - 1, 1))
        )
    }

    private static func isSampledGreenFramePixel(
        red: Int,
        green: Int,
        blue: Int,
        target: CapMarkerColorTarget
    ) -> Bool {
        let r = Double(red)
        let g = Double(green)
        let b = Double(blue)
        guard g >= r, g >= b else { return false }
        let maxChannel = max(r, max(g, b))
        let minChannel = min(r, min(g, b))
        guard maxChannel >= 38.0, maxChannel - minChannel >= 10.0 else {
            return false
        }

        let candidateSum = max(r + g + b, 1.0)
        let targetSum = max(target.red + target.green + target.blue, 1.0)
        let dr = r / candidateSum - target.red / targetSum
        let dg = g / candidateSum - target.green / targetSum
        let db = b / candidateSum - target.blue / targetSum
        let chromaDistance = sqrt(dr * dr + dg * dg + db * db)
        return chromaDistance <= max(target.tolerance, 0.16)
    }

    private static func percentile(_ residuals: [Double], _ percentile: Double) -> Double? {
        guard !residuals.isEmpty else { return nil }
        let clamped = min(1.0, max(0.0, percentile))
        let index = Int(ceil(clamped * Double(residuals.count))) - 1
        return residuals[min(max(index, 0), residuals.count - 1)]
    }

    private static func distance(_ lhs: PaperPointMmSnapshot, _ rhs: PaperPointMmSnapshot) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

struct DrawnFrameLineFit {
    let pointMm: PaperPointMmSnapshot
    let dx: Double
    let dy: Double
}

struct DrawnFrameEdgeInspection {
    let edgeIndex: Int
    let expectedStartMm: PaperPointMmSnapshot
    let expectedEndMm: PaperPointMmSnapshot
    let sampleCount: Int
    let detectedSampleCount: Int
    let greenPixelCount: Int
    let coverageFraction: Double
    let rmsExpectedResidualMm: Double?
    let maxExpectedResidualMm: Double?
    let fitRmsResidualMm: Double?
    let angleErrorDeg: Double?
    let observedStartMm: PaperPointMmSnapshot?
    let observedEndMm: PaperPointMmSnapshot?
    let lineFit: DrawnFrameLineFit?
    let observedSamples: [InkProgramObservedSample]

    var isDetected: Bool {
        lineFit != nil && detectedSampleCount >= 6 && coverageFraction >= 0.08
    }
}

struct DrawnFrameCornerInspection {
    let cornerIndex: Int
    let expectedMm: PaperPointMmSnapshot
    let observedMm: PaperPointMmSnapshot
    let residualMm: Double
}

struct DrawnFrameInspectionResult {
    let imageSize: CGSize
    let edges: [DrawnFrameEdgeInspection]
    let corners: [DrawnFrameCornerInspection]
    let totalGreenPixels: Int
    let rmsResidualMm: Double?
    let maxResidualMm: Double?
    let cornerRmsResidualMm: Double?
    let cornerMaxResidualMm: Double?
    let program: InkProgramInspectionResult

    var detectedEdgeCount: Int {
        edges.filter(\.isDetected).count
    }

    var isUsable: Bool {
        detectedEdgeCount == 4 && corners.count == 4
    }

    var summary: String {
        let edgeText = "\(detectedEdgeCount)/4 edges"
        guard let rmsResidualMm, let maxResidualMm else {
            return "green frame \(edgeText) weak"
        }
        if let cornerRmsResidualMm {
            return String(
                format: "green frame %@ edge rms %.1f max %.1f corner rms %.1f",
                edgeText,
                rmsResidualMm,
                maxResidualMm,
                cornerRmsResidualMm
            )
        }
        return String(format: "green frame %@ edge rms %.1f max %.1f", edgeText, rmsResidualMm, maxResidualMm)
    }
}

enum GreenFrameInkInspector {
    static func inspect(
        pixelBuffer: CVPixelBuffer,
        expectedCorners: [PaperPointMmSnapshot],
        registration: PaperRegistrationSnapshot,
        colorTarget: CapMarkerColorTarget?
    ) -> DrawnFrameInspectionResult? {
        guard expectedCorners.count >= 4 else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1 else { return nil }

        let corners = Array(expectedCorners.prefix(4))
        let closed = corners + [corners[0]]
        let measurements = zip(closed, closed.dropFirst()).enumerated().map { index, pair in
            inspectEdge(
                edgeIndex: index + 1,
                start: pair.0,
                end: pair.1,
                registration: registration,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                baseAddress: baseAddress,
                colorTarget: colorTarget
            )
        }

        let edges = measurements.map(\.edge)
        let residualCount = measurements.reduce(0) { $0 + $1.residualCount }
        let residualSquaredSum = measurements.reduce(0.0) { $0 + $1.residualSquaredSum }
        let maxResidual = measurements.compactMap(\.edge.maxExpectedResidualMm).max()
        let cornersMeasured = inspectCorners(expectedCorners: corners, edges: edges)
        let cornerSquaredSum = cornersMeasured.reduce(0.0) { $0 + $1.residualMm * $1.residualMm }
        let cornerMaxResidual = cornersMeasured.map(\.residualMm).max()
        let primitives = edges.map { edge in
            let residuals = edge.observedSamples.compactMap(\.residualMm).sorted()
            return InkProgramPrimitiveInspection(
                primitiveId: "frame-edge-\(edge.edgeIndex)",
                kind: .line,
                sampleCount: edge.sampleCount,
                detectedSampleCount: edge.detectedSampleCount,
                greenPixelCount: edge.greenPixelCount,
                coverageFraction: edge.coverageFraction,
                rmsResidualMm: edge.rmsExpectedResidualMm,
                p95ResidualMm: percentile(residuals, 0.95),
                maxResidualMm: edge.maxExpectedResidualMm,
                observedSamples: edge.observedSamples
            )
        }
        let program = InkProgramInspectionResult(
            programId: "setup-field-frame",
            programKind: "setup_field_frame",
            imageSize: CGSize(width: width, height: height),
            primitives: primitives
        )

        return DrawnFrameInspectionResult(
            imageSize: CGSize(width: width, height: height),
            edges: edges,
            corners: cornersMeasured,
            totalGreenPixels: edges.reduce(0) { $0 + $1.greenPixelCount },
            rmsResidualMm: residualCount > 0 ? sqrt(residualSquaredSum / Double(residualCount)) : nil,
            maxResidualMm: maxResidual,
            cornerRmsResidualMm: cornersMeasured.isEmpty ? nil : sqrt(cornerSquaredSum / Double(cornersMeasured.count)),
            cornerMaxResidualMm: cornerMaxResidual,
            program: program
        )
    }

    private static func inspectEdge(
        edgeIndex: Int,
        start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot,
        registration: PaperRegistrationSnapshot,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        baseAddress: UnsafeMutableRawPointer,
        colorTarget: CapMarkerColorTarget?
    ) -> EdgeMeasurement {
        guard let cameraStart = paperToCameraPoint(start, registration: registration),
              let cameraEnd = paperToCameraPoint(end, registration: registration) else {
            return EdgeMeasurement(
                edge: DrawnFrameEdgeInspection(
                    edgeIndex: edgeIndex,
                    expectedStartMm: start,
                    expectedEndMm: end,
                    sampleCount: 0,
                    detectedSampleCount: 0,
                    greenPixelCount: 0,
                    coverageFraction: 0,
                    rmsExpectedResidualMm: nil,
                    maxExpectedResidualMm: nil,
                    fitRmsResidualMm: nil,
                    angleErrorDeg: nil,
                    observedStartMm: nil,
                    observedEndMm: nil,
                    lineFit: nil,
                    observedSamples: []
                ),
                residualSquaredSum: 0,
                residualCount: 0
            )
        }

        let pixelStart = pixelPoint(cameraStart, width: width, height: height)
        let pixelEnd = pixelPoint(cameraEnd, width: width, height: height)
        let vx = Double(pixelEnd.x - pixelStart.x)
        let vy = Double(pixelEnd.y - pixelStart.y)
        let edgeLength = hypot(vx, vy)
        guard edgeLength >= 8 else {
            return EdgeMeasurement.empty(edgeIndex: edgeIndex, start: start, end: end)
        }

        let ux = vx / edgeLength
        let uy = vy / edgeLength
        let nx = -uy
        let ny = ux
        let bandPx = Int(max(10.0, min(70.0, edgeLength * 0.10)))
        let sampleCount = min(480, max(32, Int(edgeLength / 2.4)))
        var observedPaperPoints: [PaperPointMmSnapshot] = []
        var residuals: [Double] = []
        var observedSamples: [InkProgramObservedSample] = []
        var greenPixelCount = 0

        for sampleIndex in 0...sampleCount {
            let fraction = Double(sampleIndex) / Double(max(sampleCount, 1))
            let baseX = Double(pixelStart.x) + vx * fraction
            let baseY = Double(pixelStart.y) + vy * fraction
            let expectedPaper = PaperPointMmSnapshot(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            let expectedCamera = cameraPoint(pixel: CGPoint(x: baseX, y: baseY), width: width, height: height)
            var hitX = 0.0
            var hitY = 0.0
            var hitCount = 0

            for offset in -bandPx...bandPx {
                let sampleX = Int(round(baseX + nx * Double(offset)))
                let sampleY = Int(round(baseY + ny * Double(offset)))
                guard sampleX >= 0, sampleX < width, sampleY >= 0, sampleY < height else { continue }
                let row = baseAddress.advanced(by: sampleY * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                let pixelOffset = sampleX * 4
                let blue = Int(row[pixelOffset])
                let green = Int(row[pixelOffset + 1])
                let red = Int(row[pixelOffset + 2])
                guard isGreenFramePixel(red: red, green: green, blue: blue, target: colorTarget) else {
                    continue
                }
                hitX += Double(sampleX)
                hitY += Double(sampleY)
                hitCount += 1
            }

            guard hitCount > 0 else {
                observedSamples.append(
                    InkProgramObservedSample(
                        primitiveId: "frame-edge-\(edgeIndex)",
                        sampleIndex: sampleIndex,
                        expectedMm: expectedPaper,
                        expectedCameraNorm: NormPoint(expectedCamera),
                        observedMm: nil,
                        observedCameraNorm: nil,
                        residualMm: nil,
                        detected: false,
                        greenPixelCount: 0
                    )
                )
                continue
            }
            greenPixelCount += hitCount
            let averagePixel = CGPoint(x: hitX / Double(hitCount), y: hitY / Double(hitCount))
            let cameraPoint = cameraPoint(pixel: averagePixel, width: width, height: height)
            guard let observedPaper = cameraToPaperPoint(cameraPoint, registration: registration) else {
                observedSamples.append(
                    InkProgramObservedSample(
                        primitiveId: "frame-edge-\(edgeIndex)",
                        sampleIndex: sampleIndex,
                        expectedMm: expectedPaper,
                        expectedCameraNorm: NormPoint(expectedCamera),
                        observedMm: nil,
                        observedCameraNorm: NormPoint(cameraPoint),
                        residualMm: nil,
                        detected: false,
                        greenPixelCount: hitCount
                    )
                )
                continue
            }
            observedPaperPoints.append(observedPaper)
            residuals.append(distanceFromPoint(observedPaper, toSegmentStart: start, end: end))
            observedSamples.append(
                InkProgramObservedSample(
                    primitiveId: "frame-edge-\(edgeIndex)",
                    sampleIndex: sampleIndex,
                    expectedMm: expectedPaper,
                    expectedCameraNorm: NormPoint(expectedCamera),
                    observedMm: observedPaper,
                    observedCameraNorm: NormPoint(cameraPoint),
                    residualMm: distanceFromPoint(observedPaper, toSegmentStart: start, end: end),
                    detected: true,
                    greenPixelCount: hitCount
                )
            )
        }

        let residualSquaredSum = residuals.reduce(0.0) { $0 + $1 * $1 }
        let residualCount = residuals.count
        let line = fitLine(points: observedPaperPoints, expectedStart: start, expectedEnd: end)
        let coverage = Double(observedPaperPoints.count) / Double(max(sampleCount + 1, 1))
        let edge = DrawnFrameEdgeInspection(
            edgeIndex: edgeIndex,
            expectedStartMm: start,
            expectedEndMm: end,
            sampleCount: sampleCount + 1,
            detectedSampleCount: observedPaperPoints.count,
            greenPixelCount: greenPixelCount,
            coverageFraction: coverage,
            rmsExpectedResidualMm: residualCount > 0 ? sqrt(residualSquaredSum / Double(residualCount)) : nil,
            maxExpectedResidualMm: residuals.max(),
            fitRmsResidualMm: line?.fitRmsResidualMm,
            angleErrorDeg: line?.angleErrorDeg,
            observedStartMm: line?.observedStartMm,
            observedEndMm: line?.observedEndMm,
            lineFit: line?.lineFit,
            observedSamples: observedSamples
        )
        return EdgeMeasurement(edge: edge, residualSquaredSum: residualSquaredSum, residualCount: residualCount)
    }

    private static func inspectCorners(
        expectedCorners: [PaperPointMmSnapshot],
        edges: [DrawnFrameEdgeInspection]
    ) -> [DrawnFrameCornerInspection] {
        guard expectedCorners.count >= 4, edges.count >= 4 else { return [] }
        var corners: [DrawnFrameCornerInspection] = []
        for cornerIndex in 0..<4 {
            let previousEdge = edges[(cornerIndex + 3) % 4]
            let currentEdge = edges[cornerIndex]
            guard let previousLine = previousEdge.lineFit,
                  let currentLine = currentEdge.lineFit,
                  let observed = intersection(previousLine, currentLine) else {
                continue
            }
            let expected = expectedCorners[cornerIndex]
            corners.append(
                DrawnFrameCornerInspection(
                    cornerIndex: cornerIndex + 1,
                    expectedMm: expected,
                    observedMm: observed,
                    residualMm: distance(observed, expected)
                )
            )
        }
        return corners
    }

    private static func fitLine(
        points: [PaperPointMmSnapshot],
        expectedStart: PaperPointMmSnapshot,
        expectedEnd: PaperPointMmSnapshot
    ) -> LineMeasurement? {
        guard points.count >= 2 else { return nil }
        let count = Double(points.count)
        let meanX = points.reduce(0.0) { $0 + $1.x } / count
        let meanY = points.reduce(0.0) { $0 + $1.y } / count
        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx + syy > 0.000_001 else { return nil }

        let theta = 0.5 * atan2(2.0 * sxy, sxx - syy)
        var lineDx = cos(theta)
        var lineDy = sin(theta)
        let expectedDx = expectedEnd.x - expectedStart.x
        let expectedDy = expectedEnd.y - expectedStart.y
        let expectedLength = hypot(expectedDx, expectedDy)
        guard expectedLength > 0.000_001 else { return nil }
        let expectedUx = expectedDx / expectedLength
        let expectedUy = expectedDy / expectedLength
        if lineDx * expectedUx + lineDy * expectedUy < 0 {
            lineDx = -lineDx
            lineDy = -lineDy
        }

        var fitResidualSquaredSum = 0.0
        var minProjection = Double.infinity
        var maxProjection = -Double.infinity
        for point in points {
            let dx = point.x - meanX
            let dy = point.y - meanY
            let projection = dx * lineDx + dy * lineDy
            minProjection = min(minProjection, projection)
            maxProjection = max(maxProjection, projection)
            let perpendicular = dx * -lineDy + dy * lineDx
            fitResidualSquaredSum += perpendicular * perpendicular
        }

        let dot = min(1.0, max(-1.0, abs(lineDx * expectedUx + lineDy * expectedUy)))
        let lineFit = DrawnFrameLineFit(
            pointMm: PaperPointMmSnapshot(x: meanX, y: meanY),
            dx: lineDx,
            dy: lineDy
        )
        return LineMeasurement(
            lineFit: lineFit,
            observedStartMm: PaperPointMmSnapshot(
                x: meanX + lineDx * minProjection,
                y: meanY + lineDy * minProjection
            ),
            observedEndMm: PaperPointMmSnapshot(
                x: meanX + lineDx * maxProjection,
                y: meanY + lineDy * maxProjection
            ),
            fitRmsResidualMm: sqrt(fitResidualSquaredSum / count),
            angleErrorDeg: acos(dot) * 180.0 / .pi
        )
    }

    private static func paperToCameraPoint(
        _ paperMm: PaperPointMmSnapshot,
        registration: PaperRegistrationSnapshot
    ) -> CGPoint? {
        let coefficients = registration.paperToCamera.coefficients
        guard coefficients.count == 9,
              registration.paperSizeMm.width > 0,
              registration.paperSizeMm.height > 0 else {
            return nil
        }
        let x = paperMm.x / registration.paperSizeMm.width
        let y = paperMm.y / registration.paperSizeMm.height
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }
        let cameraX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let cameraY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        guard cameraX >= -0.35, cameraX <= 1.35, cameraY >= -0.35, cameraY <= 1.35 else {
            return nil
        }
        return CGPoint(x: cameraX, y: cameraY)
    }

    private static func cameraToPaperPoint(
        _ cameraPoint: CGPoint,
        registration: PaperRegistrationSnapshot
    ) -> PaperPointMmSnapshot? {
        let coefficients = registration.cameraToPaper.coefficients
        guard coefficients.count == 9 else { return nil }
        let x = Double(cameraPoint.x)
        let y = Double(cameraPoint.y)
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }
        let paperX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let paperY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        return PaperPointMmSnapshot(
            x: paperX * registration.paperSizeMm.width,
            y: paperY * registration.paperSizeMm.height
        )
    }

    private static func pixelPoint(_ cameraPoint: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: Double(cameraPoint.x) * Double(width - 1),
            y: (1.0 - Double(cameraPoint.y)) * Double(height - 1)
        )
    }

    private static func cameraPoint(pixel: CGPoint, width: Int, height: Int) -> CGPoint {
        CGPoint(
            x: Double(pixel.x) / Double(max(width - 1, 1)),
            y: 1.0 - Double(pixel.y) / Double(max(height - 1, 1))
        )
    }

    private static func isGreenFramePixel(
        red: Int,
        green: Int,
        blue: Int,
        target: CapMarkerColorTarget?
    ) -> Bool {
        InkProgramInspector.isGreenFramePixel(red: red, green: green, blue: blue, target: target)
    }

    private static func percentile(_ residuals: [Double], _ percentile: Double) -> Double? {
        guard !residuals.isEmpty else { return nil }
        let clamped = min(1.0, max(0.0, percentile))
        let index = Int(ceil(clamped * Double(residuals.count))) - 1
        return residuals[min(max(index, 0), residuals.count - 1)]
    }

    private static func distanceFromPoint(
        _ point: PaperPointMmSnapshot,
        toSegmentStart start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot
    ) -> Double {
        let vx = end.x - start.x
        let vy = end.y - start.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 0.000_001 else { return distance(point, start) }
        let projection = ((point.x - start.x) * vx + (point.y - start.y) * vy) / lengthSquared
        let clamped = min(1.0, max(0.0, projection))
        let closest = PaperPointMmSnapshot(x: start.x + vx * clamped, y: start.y + vy * clamped)
        return distance(point, closest)
    }

    private static func distance(_ lhs: PaperPointMmSnapshot, _ rhs: PaperPointMmSnapshot) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func intersection(
        _ lhs: DrawnFrameLineFit,
        _ rhs: DrawnFrameLineFit
    ) -> PaperPointMmSnapshot? {
        let det = lhs.dx * rhs.dy - lhs.dy * rhs.dx
        guard abs(det) > 0.000_001 else { return nil }
        let dx = rhs.pointMm.x - lhs.pointMm.x
        let dy = rhs.pointMm.y - lhs.pointMm.y
        let t = (dx * rhs.dy - dy * rhs.dx) / det
        return PaperPointMmSnapshot(
            x: lhs.pointMm.x + lhs.dx * t,
            y: lhs.pointMm.y + lhs.dy * t
        )
    }
}

private struct EdgeMeasurement {
    let edge: DrawnFrameEdgeInspection
    let residualSquaredSum: Double
    let residualCount: Int

    static func empty(
        edgeIndex: Int,
        start: PaperPointMmSnapshot,
        end: PaperPointMmSnapshot
    ) -> EdgeMeasurement {
        EdgeMeasurement(
            edge: DrawnFrameEdgeInspection(
                edgeIndex: edgeIndex,
                expectedStartMm: start,
                expectedEndMm: end,
                sampleCount: 0,
                detectedSampleCount: 0,
                greenPixelCount: 0,
                coverageFraction: 0,
                rmsExpectedResidualMm: nil,
                maxExpectedResidualMm: nil,
                fitRmsResidualMm: nil,
                angleErrorDeg: nil,
                observedStartMm: nil,
                observedEndMm: nil,
                lineFit: nil,
                observedSamples: []
            ),
            residualSquaredSum: 0,
            residualCount: 0
        )
    }
}

private struct LineMeasurement {
    let lineFit: DrawnFrameLineFit
    let observedStartMm: PaperPointMmSnapshot
    let observedEndMm: PaperPointMmSnapshot
    let fitRmsResidualMm: Double
    let angleErrorDeg: Double
}
