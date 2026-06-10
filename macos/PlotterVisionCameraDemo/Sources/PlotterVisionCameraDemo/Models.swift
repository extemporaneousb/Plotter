import CoreGraphics
import Foundation

struct AnalyzerSettings: Equatable {
    var enabled = true
    var sensitivity = 0.68
    var minAreaRatio = 0.0008
    var maxSegments = 54
    var redFiducialsEnabled = true
    var greenMarkerEnabled = true
    var capMarkerColorTarget: CapMarkerColorTarget?
    var changeEnabled = true
    var changeSensitivity = 0.56
    var changeReportInterval = 1.25
    var minChangedCells = 5
}

struct CapMarkerColorTarget: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let tolerance: Double
    let label: String
}

struct InkInspectionResult: Equatable {
    let centerLuma: Double
    let surroundLuma: Double
    let contrast: Double
    let darkFraction: Double

    var isVisible: Bool {
        contrast >= 0.05 && darkFraction >= 0.10
    }

    var summary: String {
        String(
            format: "ink %@ contrast %.2f dark %.0f%%",
            isVisible ? "visible" : "weak",
            contrast,
            darkFraction * 100
        )
    }
}

enum CameraRole: String, CaseIterable, Identifiable {
    case plotter
    case face

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plotter:
            return "Plotter Camera"
        case .face:
            return "Face Camera"
        }
    }

    var shortTitle: String {
        switch self {
        case .plotter:
            return "PLOTTER"
        case .face:
            return "FACE"
        }
    }

    var defaultsKey: String {
        "PlotterVisionCamera.\(rawValue).selectedCameraID"
    }

    var statusPrefix: String {
        switch self {
        case .plotter:
            return "Plotter"
        case .face:
            return "Face"
        }
    }
}

struct CameraDeviceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let modelID: String
    let isExternal: Bool

    var displayName: String {
        isExternal ? "\(name) USB" : name
    }
}

enum SegmentKind: String, Equatable {
    case line = "LINE"
    case shape = "SHAPE"
    case mark = "MARK"
    case contour = "TRACE"
}

struct VisionSegment: Identifiable, Equatable {
    let id: Int
    let kind: SegmentKind
    let boundingBox: CGRect
    let points: [CGPoint]
    let pixelLength: CGFloat
    let pixelArea: CGFloat
    let confidence: Double

    var label: String {
        "\(kind.rawValue) \(Int(pixelLength))px"
    }
}

struct FiducialMark: Identifiable, Equatable {
    let id: Int
    let boundingBox: CGRect
    let center: CGPoint
    let pixelArea: CGFloat
    let strength: Double

    var label: String {
        String(format: "FID-%02d %.0f%%", id, strength * 100)
    }
}

struct CarriageMarker: Identifiable, Equatable {
    let id: Int
    let boundingBox: CGRect
    let center: CGPoint
    let pixelArea: CGFloat
    let strength: Double
    let colorName: String

    var label: String {
        String(format: "%@ CAP %.0f%% x%.3f y%.3f", colorName, strength * 100, center.x, center.y)
    }
}

struct ManualFiducialPoint: Identifiable, Equatable {
    let id: Int
    var point: CGPoint
    var cameraPoint: CGPoint

    var label: String {
        switch id {
        case 1:
            return "FID-BL"
        case 2:
            return "FID-BR"
        case 3:
            return "FID-TR"
        case 4:
            return "FID-TL"
        default:
            return String(format: "FID-%02d", id)
        }
    }
}

struct ObservedPenPoint: Identifiable, Equatable {
    let id = UUID()
    var point: CGPoint
    var cameraPoint: CGPoint
    var paperMm: PaperPointMmSnapshot?

    var label: String {
        guard let paperMm else { return "PEN PAPER ?" }
        return String(format: "PEN %.1f,%.1f mm", paperMm.x, paperMm.y)
    }
}

struct PaperRegistration: Identifiable, Equatable {
    let id: Int
    let frameNumber: Int
    let fiducialCount: Int
    let quad: [CGPoint]
    let boundingBox: CGRect
    let confidence: Double

    var status: String {
        if fiducialCount >= 4 { return "LOCK" }
        if fiducialCount >= 3 { return "WEAK" }
        return "SEEK"
    }
}

struct VisionAnalysisResult {
    let segments: [VisionSegment]
    let fiducials: [FiducialMark]
    let carriageMarker: CarriageMarker?
    let paperRegistration: PaperRegistration?
    let elapsedMilliseconds: Double
}

struct FaceRasterSample: Equatable {
    let columns: Int
    let rows: Int
    let samples: [[Double]]
    let faceBounds: CGRect
    let frameNumber: Int
    let confidence: Double
}

struct PaperCalibrationObservation: Codable, Equatable {
    var type = "paper.registration"
    var schema = 1
    let cameraID: String
    let cameraName: String
    let frameNumber: Int
    let videoSize: NormSize
    let fiducials: [PaperFiducialSample]
    let paperQuadNorm: [NormPoint]
    let confidence: Double
}

struct PaperFiducialSample: Codable, Equatable {
    let id: Int
    let centerNorm: NormPoint
    let bboxNorm: NormRect
    let strength: Double
    let pixelArea: Double
}

struct NormPoint: Codable, Equatable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

struct NormRect: Codable, Equatable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX)
        y = Double(rect.minY)
        w = Double(rect.width)
        h = Double(rect.height)
    }
}

struct NormSize: Codable, Equatable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        width = Double(size.width)
        height = Double(size.height)
    }
}

struct AnalysisStats: Equatable {
    var frameNumber = 0
    var segmentCount = 0
    var fiducialCount = 0
    var paperStatus = "SEEK"
    var motionCount = 0
    var carriageMarkerStatus = "CAP --"
    var reportNumber = 0
    var analysisMilliseconds = 0.0
    var changeMilliseconds = 0.0
    var fps = 0.0
    var cameraName = "Camera"
}

struct MotionTrack: Identifiable, Equatable {
    let id: Int
    let boundingBox: CGRect
    let center: CGPoint
    let velocity: CGPoint
    let changedCells: Int
    let pixelArea: CGFloat
    let strength: Double
    let ageReports: Int

    var label: String {
        String(format: "OBJ-%02d x%.3f y%.3f", id, center.x, center.y)
    }

    var vectorLengthPixels: CGFloat {
        hypot(velocity.x, velocity.y)
    }
}

struct ChangeReport: Equatable {
    var sequence = 0
    var frameNumber = 0
    var objectCount = 0
    var changedCells = 0
    var elapsedMilliseconds = 0.0
    var strongestTrackID: Int?
    var strongestTrackStrength = 0.0

    static let idle = ChangeReport()

    var summary: String {
        guard sequence > 0 else { return "Δ waiting for baseline" }
        guard objectCount > 0 else { return String(format: "Δ%03d no visible change", sequence) }

        let strongest = strongestTrackID.map { String(format: " OBJ-%02d", $0) } ?? ""
        return String(
            format: "Δ%03d %d objects%@ %.0f%%",
            sequence,
            objectCount,
            strongest,
            strongestTrackStrength * 100
        )
    }
}

struct PlotterOverlaySettings: Equatable, Codable {
    var enabled = true
    var locked = false
    var opacity = 0.38
    var scale = 0.82
    var offsetX = 0.0
    var offsetY = 0.02
    var rotationDegrees = 0.0
}

enum CameraPreviewMode: String, CaseIterable, Codable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit:
            return "Fit"
        case .fill:
            return "Fill"
        }
    }
}

enum PlotterViewportBoxColor: String, CaseIterable, Codable, Identifiable {
    case cyan
    case yellow
    case magenta
    case green
    case white
    case red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyan:
            return "Cyan"
        case .yellow:
            return "Yellow"
        case .magenta:
            return "Magenta"
        case .green:
            return "Green"
        case .white:
            return "White"
        case .red:
            return "Red"
        }
    }
}

enum PlotterVideoFilter: String, CaseIterable, Codable, Identifiable {
    case normal
    case monochrome
    case highContrast
    case inverted
    case inkCheck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal:
            return "Normal"
        case .monochrome:
            return "Black & White"
        case .highContrast:
            return "High Contrast"
        case .inverted:
            return "Invert"
        case .inkCheck:
            return "Ink Check"
        }
    }
}

struct PlotterViewportSettings: Equatable, Codable {
    var previewMode = CameraPreviewMode.fit
    var rotationDegrees = 0.0
    var boxEnabled = true
    var boxLocked = false
    var boxOpacity = 0.62
    var boxStrokeWidth = 2.0
    var boxColor = PlotterViewportBoxColor.cyan
    var videoFilter = PlotterVideoFilter.normal
    var boxWidthNorm = 0.84
    var boxAspectRatio = 1.45
    var boxCenterXNorm = 0.5
    var boxCenterYNorm = 0.5

    enum CodingKeys: String, CodingKey {
        case previewMode
        case rotationDegrees
        case boxEnabled
        case boxLocked
        case boxOpacity
        case boxStrokeWidth
        case boxColor
        case videoFilter
        case boxWidthNorm
        case boxAspectRatio
        case boxCenterXNorm
        case boxCenterYNorm
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previewMode = try container.decodeIfPresent(CameraPreviewMode.self, forKey: .previewMode) ?? .fit
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0.0
        boxEnabled = try container.decodeIfPresent(Bool.self, forKey: .boxEnabled) ?? true
        boxLocked = try container.decodeIfPresent(Bool.self, forKey: .boxLocked) ?? false
        boxOpacity = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? 0.62,
            min: 0.05,
            max: 1.0
        )
        boxStrokeWidth = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxStrokeWidth) ?? 2.0,
            min: 1.0,
            max: 10.0
        )
        boxColor = try container.decodeIfPresent(PlotterViewportBoxColor.self, forKey: .boxColor) ?? .cyan
        videoFilter = try container.decodeIfPresent(PlotterVideoFilter.self, forKey: .videoFilter) ?? .normal
        boxWidthNorm = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxWidthNorm) ?? 0.84,
            min: 0.05,
            max: 1.0
        )
        boxAspectRatio = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxAspectRatio) ?? 1.45,
            min: 0.2,
            max: 5.0
        )
        boxCenterXNorm = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxCenterXNorm) ?? 0.5,
            min: 0.0,
            max: 1.0
        )
        boxCenterYNorm = clampDouble(
            try container.decodeIfPresent(Double.self, forKey: .boxCenterYNorm) ?? 0.5,
            min: 0.0,
            max: 1.0
        )
    }

    private func clampDouble(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.min(maximum, Swift.max(minimum, value))
    }
}

struct DrawingFrameSettings: Equatable, Codable {
    var widthNorm = 0.82
    var aspectRatio = 1.45
    var centerXNorm = 0.5
    var centerYNorm = 0.5

    func rect(workspaceXMm: Double, workspaceYMm: Double) -> CGRect {
        let workspaceAspect = workspaceXMm / max(workspaceYMm, 1)
        let heightNorm = min(0.96, widthNorm * workspaceAspect / max(aspectRatio, 0.05))
        let clampedWidth = min(0.98, max(0.05, widthNorm))
        let clampedHeight = min(0.98, max(0.05, heightNorm))
        let x = min(1.0 - clampedWidth, max(0.0, centerXNorm - clampedWidth / 2))
        let y = min(1.0 - clampedHeight, max(0.0, centerYNorm - clampedHeight / 2))
        return CGRect(x: x, y: y, width: clampedWidth, height: clampedHeight)
    }

    func pointInWorkspace(
        localXNorm: Double,
        localYNorm: Double,
        workspaceXMm: Double,
        workspaceYMm: Double
    ) -> CGPoint {
        let frame = rect(workspaceXMm: workspaceXMm, workspaceYMm: workspaceYMm)
        return CGPoint(
            x: (frame.minX + frame.width * localXNorm) * workspaceXMm,
            y: (frame.minY + frame.height * localYNorm) * workspaceYMm
        )
    }
}

struct ShapeAssessmentState: Equatable {
    var status = "WAIT"
    var detail = "No draw assessed"
    var changedObjects = 0
    var changedCells = 0
    var strength = 0.0

    static let idle = ShapeAssessmentState()
}

struct FrameLearningState: Equatable {
    var status = "IDLE"
    var detail = "No projection learned"
    var sampleCount = 0
    var xPixelsPerMm = 0.0
    var yPixelsPerMm = 0.0
    var lastPins = "-"

    static let idle = FrameLearningState()
}

struct FrameLearningSample: Equatable {
    let axis: String
    let distanceMm: Double
    let observedDxMm: Double
    let observedDyMm: Double
    let observedDistanceMm: Double
    var residualMm: Double = 0.0
    let strength: Double
}

struct VisualMotionSample: Equatable {
    let machineDxMm: Double
    let machineDyMm: Double
    let observedDxMm: Double
    let observedDyMm: Double
    let observedDistanceMm: Double
    let strength: Double
}

struct GreenCapPaperObservation: Equatable {
    let frameNumber: Int
    let cameraPoint: CGPoint
    let paperMm: PaperPointMmSnapshot
    let strength: Double
}

struct VisualAxisProbeEvaluation: Equatable {
    let passed: Bool
    let detail: String
    let rmsResidualMm: Double
    let maxResidualMm: Double
    let minObservedDistanceMm: Double
    let xScale: Double
    let yScale: Double
}

struct VisualMotionModel: Equatable {
    let xBasisDx: Double
    let xBasisDy: Double
    let yBasisDx: Double
    let yBasisDy: Double
    let rmsResidualMm: Double
    let maxResidualMm: Double
    let sampleCount: Int

    static func solve(samples: [VisualMotionSample]) -> VisualMotionModel? {
        guard samples.count >= 4 else { return nil }

        var sxx = 0.0
        var sxy = 0.0
        var syy = 0.0
        var tx = 0.0
        var ty = 0.0
        var ux = 0.0
        var uy = 0.0

        for sample in samples {
            let x = sample.machineDxMm
            let y = sample.machineDyMm
            guard x.isFinite, y.isFinite else { return nil }
            sxx += x * x
            sxy += x * y
            syy += y * y
            tx += x * sample.observedDxMm
            ty += y * sample.observedDxMm
            ux += x * sample.observedDyMm
            uy += y * sample.observedDyMm
        }

        let normalDeterminant = sxx * syy - sxy * sxy
        guard abs(normalDeterminant) > 1.0 else { return nil }

        let xBasisDx = (tx * syy - ty * sxy) / normalDeterminant
        let yBasisDx = (sxx * ty - sxy * tx) / normalDeterminant
        let xBasisDy = (ux * syy - uy * sxy) / normalDeterminant
        let yBasisDy = (sxx * uy - sxy * ux) / normalDeterminant

        let residuals = samples.map { sample in
            let predictedDx = xBasisDx * sample.machineDxMm + yBasisDx * sample.machineDyMm
            let predictedDy = xBasisDy * sample.machineDxMm + yBasisDy * sample.machineDyMm
            return hypot(sample.observedDxMm - predictedDx, sample.observedDyMm - predictedDy)
        }
        let rmsResidual = sqrt(residuals.reduce(0.0) { $0 + $1 * $1 } / Double(max(residuals.count, 1)))
        let maxResidual = residuals.max() ?? .infinity

        let model = VisualMotionModel(
            xBasisDx: xBasisDx,
            xBasisDy: xBasisDy,
            yBasisDx: yBasisDx,
            yBasisDy: yBasisDy,
            rmsResidualMm: rmsResidual,
            maxResidualMm: maxResidual,
            sampleCount: samples.count
        )
        return model.isUsable ? model : nil
    }

    var determinant: Double {
        xBasisDx * yBasisDy - yBasisDx * xBasisDy
    }

    var isUsable: Bool {
        abs(determinant) > 0.05
            && rmsResidualMm.isFinite
            && maxResidualMm.isFinite
            && sampleCount >= 4
    }

    func machineDelta(forPaperDx paperDx: Double, paperDy: Double) -> (xMm: Double, yMm: Double)? {
        let det = determinant
        guard abs(det) > 0.05 else { return nil }
        let x = (paperDx * yBasisDy - yBasisDx * paperDy) / det
        let y = (xBasisDx * paperDy - paperDx * xBasisDy) / det
        guard x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    func paperDelta(forMachineX xMm: Double, yMm: Double) -> (dx: Double, dy: Double) {
        (
            dx: xBasisDx * xMm + yBasisDx * yMm,
            dy: xBasisDy * xMm + yBasisDy * yMm
        )
    }
}
