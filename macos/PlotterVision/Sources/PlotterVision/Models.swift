import CoreGraphics
import Foundation

struct AnalyzerSettings: Equatable {
    var enabled = true
    var sensitivity = 0.68
    var minAreaRatio = 0.0008
    var maxSegments = 54
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
        "PlotterVision.\(rawValue).selectedCameraID"
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

struct ConfirmedCapPoint: Identifiable, Equatable {
    let id = UUID()
    var point: CGPoint
    var cameraPoint: CGPoint
    var paperMm: PaperPointMmSnapshot?

    var label: String {
        guard let paperMm else { return "CONF CAP PAPER ?" }
        return String(format: "CONF CAP %.1f,%.1f mm", paperMm.x, paperMm.y)
    }
}

struct VisionAnalysisResult {
    let segments: [VisionSegment]
    let carriageMarker: CarriageMarker?
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
    var opacity = 0.38

    enum CodingKeys: String, CodingKey {
        case enabled
        case opacity
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.38
    }
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
    var videoFilter = PlotterVideoFilter.normal

    enum CodingKeys: String, CodingKey {
        case previewMode
        case rotationDegrees
        case videoFilter
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previewMode = try container.decodeIfPresent(CameraPreviewMode.self, forKey: .previewMode) ?? .fit
        rotationDegrees = try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0.0
        videoFilter = try container.decodeIfPresent(PlotterVideoFilter.self, forKey: .videoFilter) ?? .normal
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
