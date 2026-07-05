import Combine
import Foundation

struct BridgeHealthResponse: Decodable {
    let status: String
    let dryRun: Bool
    let controller: String
    let armMotion: Bool
    let armPen: Bool
    let armHoming: Bool
    let armUnlock: Bool
    let eventLog: String
    let workspaceXMm: Double?
    let workspaceYMm: Double?
    let maxFeedMmMin: Double?
    let maxJogMm: Double?
    let bridgeApiVersion: String?
    let lifecycleMode: String?
    let lifecycleLabel: String?
    let bridgeBuildId: String?
    let bridgeSourceRoot: String?
    let bridgePid: Int?
    let bridgeStartedAt: String?
    let canRestartSafely: Bool?

    enum CodingKeys: String, CodingKey {
        case status
        case dryRun
        case controller
        case armMotion
        case armPen
        case armHoming
        case armUnlock
        case eventLog
        case workspaceXMm
        case workspaceYMm
        case maxFeedMmMin
        case maxJogMm
        case bridgeApiVersion
        case lifecycleMode
        case lifecycleLabel
        case bridgeBuildId
        case bridgeSourceRoot
        case bridgePid
        case bridgeStartedAt
        case canRestartSafely
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ready"
        dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? true
        controller = try container.decodeIfPresent(String.self, forKey: .controller) ?? "unknown"
        armMotion = try container.decodeIfPresent(Bool.self, forKey: .armMotion) ?? false
        armPen = try container.decodeIfPresent(Bool.self, forKey: .armPen) ?? false
        armHoming = try container.decodeIfPresent(Bool.self, forKey: .armHoming) ?? false
        armUnlock = try container.decodeIfPresent(Bool.self, forKey: .armUnlock) ?? false
        eventLog = try container.decodeIfPresent(String.self, forKey: .eventLog) ?? ""
        workspaceXMm = container.decodeFlexibleDoubleIfPresent(forKey: .workspaceXMm)
        workspaceYMm = container.decodeFlexibleDoubleIfPresent(forKey: .workspaceYMm)
        maxFeedMmMin = container.decodeFlexibleDoubleIfPresent(forKey: .maxFeedMmMin)
        maxJogMm = container.decodeFlexibleDoubleIfPresent(forKey: .maxJogMm)
        bridgeApiVersion = container.decodeFlexibleStringIfPresent(forKey: .bridgeApiVersion)
        lifecycleMode = container.decodeFlexibleStringIfPresent(forKey: .lifecycleMode)
        lifecycleLabel = container.decodeFlexibleStringIfPresent(forKey: .lifecycleLabel)
        bridgeBuildId = container.decodeFlexibleStringIfPresent(forKey: .bridgeBuildId)
        bridgeSourceRoot = container.decodeFlexibleStringIfPresent(forKey: .bridgeSourceRoot)
        bridgePid = container.decodeFlexibleIntIfPresent(forKey: .bridgePid)
        bridgeStartedAt = container.decodeFlexibleStringIfPresent(forKey: .bridgeStartedAt)
        canRestartSafely = container.decodeFlexibleBoolIfPresent(forKey: .canRestartSafely)
    }
}

enum BridgeClientError: LocalizedError {
    case httpStatus(Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "Bridge returned HTTP \(status)."
        case .server(let message):
            return message
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return cleanBridgeMetadata(value)
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decode(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        guard let value = try? decode(String.self, forKey: key) else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return nil
        }
    }
}

func cleanBridgeMetadata(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    switch trimmed.lowercased() {
    case "unknown", "none", "null", "--":
        return nil
    default:
        return trimmed
    }
}

func currentAppBuildId() -> String? {
    let environment = ProcessInfo.processInfo.environment
    for key in ["PLOTTER_APP_BUILD_ID", "PLOTTER_BUILD_ID"] {
        if let value = cleanBridgeMetadata(environment[key]) {
            return value
        }
    }

    for key in ["PlotterAppBuildID", "PlotterBuildID", "PLOTTER_APP_BUILD_ID"] {
        if let value = cleanBridgeMetadata(Bundle.main.object(forInfoDictionaryKey: key) as? String) {
            return value
        }
    }

    return nil
}

func currentRequiredBridgeApiVersion() -> Int {
    if let value = Bundle.main.object(forInfoDictionaryKey: "PlotterRequiredBridgeAPIVersion") as? Int {
        return value
    }
    if let value = Bundle.main.object(forInfoDictionaryKey: "PlotterRequiredBridgeAPIVersion") as? String,
       let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return parsed
    }
    return 4
}

func normalizedBuildId(_ value: String?) -> String? {
    cleanBridgeMetadata(value)?.lowercased()
}

func shortBuildId(_ value: String?) -> String? {
    guard let value = cleanBridgeMetadata(value) else { return nil }
    return String(value.prefix(10))
}

struct BridgeShapeSimulation: Decodable {
    let status: String
    let previewSegments: [ExpectedPathSegment]
    let drawnLengthMm: Double
    let errors: [String]
}

struct BridgeShapeEvaluation: Decodable {
    let status: String
    let message: String
    let checks: [BridgeShapeEvaluationCheck]
}

struct BridgeShapeEvaluationCheck: Decodable {
    let name: String
    let status: String
    let actual: Double
    let expected: Double
    let tolerance: Double
}

struct ExpectedPathSegment: Decodable, Equatable {
    let startNorm: [Double]
    let endNorm: [Double]
    let startMachineMm: [Double]
    let endMachineMm: [Double]
    let lengthMm: Double
}

struct BridgePreviewOverlay: Decodable, Equatable {
    let overlayId: String
    let commandId: String
    let coordinateSpace: String
    let projected: Bool
    let paperRegistrationId: String?
    let visualPositionBindingId: String?
    let primitives: [BridgePreviewOverlayPrimitive]
}

struct BridgePreviewOverlayPrimitive: Decodable, Equatable {
    let primitiveId: String
    let commandId: String
    let segmentIndex: Int
    let startPaperMm: PaperPointMmSnapshot
    let endPaperMm: PaperPointMmSnapshot
    let startCameraNorm: NormPoint?
    let endCameraNorm: NormPoint?
    let lengthMm: Double
}

struct BridgeDrawingFrameRequest: Encodable {
    let originXMm: Double
    let originYMm: Double
    let widthMm: Double
    let heightMm: Double
    let flipY: Bool
}

struct BridgePaperPointNormRequest: Encodable {
    let x: Double
    let y: Double
}

struct BridgePolylinePrimitiveRequest: Encodable {
    let points: [BridgePaperPointNormRequest]
    let role: String
    let closed: Bool
}

struct BridgeDrawingProgramRequest: Encodable {
    let polylines: [BridgePolylinePrimitiveRequest]
}

struct BridgeDrawProgramRequest: Encodable {
    let program: BridgeDrawingProgramRequest
    let frame: BridgeDrawingFrameRequest?
    let includeHoming: Bool
    let visualPositionTrusted: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let maxPolylineCount: Int
    let requestId: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeLuminanceRasterRequest: Encodable {
    let samples: [[Double]]
}

struct BridgeRasterPolygonOptionsRequest: Encodable {
    let darknessThreshold: Double
    let gamma: Double
    let autoContrast: Bool
    let triangulate: Bool
    let outline: Bool
    let hatchAngleDeg: Double
    let minHatchSpacingMm: Double
    let maxHatchSpacingMm: Double
    let maxHatchSegments: Int
    let maxPolygons: Int
}

struct BridgeRasterContourOptionsRequest: Encodable {
    let darknessThreshold: Double
    let autoContrast: Bool
    let maxContours: Int
}

struct BridgePortraitContourOptionsRequest: Encodable {
    let technique: String
    let contourLevels: Int
    let lowQuantile: Double
    let highQuantile: Double
    let autoContrast: Bool
    let illuminationRadius: Int
    let illuminationStrength: Double
    let smoothingRadius: Int
    let simplificationEpsilonNorm: Double
    let minContourLengthNorm: Double
    let minPointsPerContour: Int
    let maxContours: Int
    let maxPoints: Int
}

struct BridgeImageShapePreviewRequest: Encodable {
    let raster: BridgeLuminanceRasterRequest
    let frame: BridgeDrawingFrameRequest
    let options: BridgeRasterContourOptionsRequest
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgePortraitContourPreviewRequest: Encodable {
    let raster: BridgeLuminanceRasterRequest
    let frame: BridgeDrawingFrameRequest
    let options: BridgePortraitContourOptionsRequest
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeDrawProgramSummary: Decodable {
    let coordinateFrame: String
    let polylineCount: Int
    let outlinePolylineCount: Int
    let hatchPolylineCount: Int
    let drawSegmentCount: Int
    let commandCount: Int
    let drawnLengthMm: Double
    let boundsLogicalMm: [String: Double]
}

struct BridgeRasterPolygonSummary: Decodable {
    let rasterWidth: Int
    let rasterHeight: Int
    let cellCount: Int
    let selectedCellCount: Int
    let polygonCount: Int
    let minLuminance: Double
    let maxLuminance: Double
    let minShade: Double?
    let maxShade: Double?
}

struct BridgeRasterContourSummary: Decodable {
    let rasterWidth: Int
    let rasterHeight: Int
    let cellCount: Int
    let selectedCellCount: Int
    let contourCount: Int
    let minLuminance: Double
    let maxLuminance: Double
}

struct BridgePortraitContourSummary: Decodable {
    let rasterWidth: Int
    let rasterHeight: Int
    let cellCount: Int
    let contourCount: Int
    let rawContourCount: Int
    let rawPointCount: Int
    let keptPointCount: Int
    let minLuminance: Double
    let maxLuminance: Double
    let minNormalizedValue: Double
    let maxNormalizedValue: Double
    let levels: [Double]
    let illuminationRadius: Int
    let illuminationStrength: Double
    let smoothingRadius: Int
    let simplificationEpsilonNorm: Double
}

struct BridgePortraitContourPolyline: Decodable {
    let points: [NormPoint]
    let closed: Bool
}

struct BridgePortraitContourOverlay: Decodable {
    let coordinateSpace: String
    let rasterWidth: Int
    let rasterHeight: Int
    let contours: [BridgePortraitContourPolyline]
}

struct BridgeDrawProgramResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let drawingCorrection: BridgeDrawingCorrectionSummary?
    let simulation: BridgeShapeSimulation?
    let summary: BridgeDrawProgramSummary?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
    let error: String?
}

struct BridgeDrawingCorrectionPoint: Decodable, Equatable {
    let desiredMm: PaperPointMmSnapshot
    let commandedMm: PaperPointMmSnapshot
    let primitiveId: String?
    let strokeId: String?
    let semanticRole: String?
    let uncertaintyMm: Double?
    let correctionNormMm: Double
}

struct BridgeDrawingCorrectionSummary: Decodable, Equatable {
    let status: String
    let modelId: String?
    let modelFamily: String?
    let solverKind: String?
    let correctedPointCount: Int
    let maxCorrectionMm: Double
    let maxUncertaintyMm: Double?
    let blockers: [String]
    let points: [BridgeDrawingCorrectionPoint]
}

struct BridgeDrawingCalibrationProgramResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let programKind: String
    let planHash: String
    let plannedCommands: [String]
    let drawingCorrection: BridgeDrawingCorrectionSummary?
    let simulation: BridgeShapeSimulation?
    let summary: BridgeDrawProgramSummary?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
    let error: String?
}

struct BridgeImageShapePreviewResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let eligibleForBridgePreview: Bool
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let summary: BridgeDrawProgramSummary?
    let rasterSummary: BridgeRasterContourSummary?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let error: String?
}

struct BridgePortraitContourPreviewResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let eligibleForBridgePreview: Bool
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let summary: BridgeDrawProgramSummary?
    let portraitSummary: BridgePortraitContourSummary?
    let portraitOverlay: BridgePortraitContourOverlay?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let error: String?
}

struct BridgeCapabilityTestRequest: Encodable {
    let requestId: String?
    let kind: String
    let frame: BridgeDrawingFrameRequest?
    let includeHoming: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let expectedPlanHash: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeCapabilityTestResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let kind: String
    let label: String
    let residualRoles: [String]
    let planHash: String
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let summary: BridgeDrawProgramSummary?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
    let error: String?
}

struct PaperRegistrationCornerRequest: Encodable {
    let corner: String
    let observedNorm: NormPoint
    let strength: Double
}

struct PaperRegistrationRequest: Encodable {
    let paperWidthMm: Double
    let paperHeightMm: Double
    let corners: [PaperRegistrationCornerRequest]
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct PaperRegistrationResponse: Decodable {
    let status: String
    let dryRun: Bool
    let registration: PaperRegistrationSnapshot?
    let registrationFile: String
    let error: String?
}

struct BridgeSetupResetRequest: Encodable {
    let requestId: String?
    let scope: String
    let confirmed: Bool
    let preserveHistory: Bool
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil

    init(scope: String, confirmed: Bool, requestId: String? = nil, preserveHistory: Bool = true) {
        self.requestId = requestId
        self.scope = scope
        self.confirmed = confirmed
        self.preserveHistory = preserveHistory
    }
}

struct BridgeSetupResetResponse: Decodable {
    let status: String
    let dryRun: Bool
    let scope: String
    let confirmed: Bool
    let preserveHistory: Bool
    let clearedFiles: [String]
    let missingFiles: [String]
    let eventLog: String
    let error: String?
}

struct BridgeCapToTipModel: Decodable, Equatable {
    let modelType: String
    let offsetXMm: Double
    let offsetYMm: Double
    let source: String
}

struct BridgeSafeZoneMargins: Decodable, Equatable {
    let left: Double
    let right: Double
    let bottom: Double
    let top: Double
}

struct BridgeDrawingSafeZone: Decodable, Equatable {
    let schemaVersion: Int
    let artifactType: String
    let marginsMm: BridgeSafeZoneMargins
    let extraPaddingMm: Double
    let markClearanceMm: Double
    let parkClearanceMm: Double
    let observationClearanceMm: Double
    let capToTipOffsetXMm: Double
    let capToTipOffsetYMm: Double
    let logicalMinXMm: Double
    let logicalMaxXMm: Double
    let logicalMinYMm: Double
    let logicalMaxYMm: Double
    let paperMinXNorm: Double
    let paperMaxXNorm: Double
    let paperMinYNorm: Double
    let paperMaxYNorm: Double
}

struct PaperRegistrationSnapshot: Decodable {
    let registrationId: String
    let status: String
    let paperSizeMm: PaperSizeSnapshot
    let paperToCamera: HomographySnapshot
    let cameraToPaper: HomographySnapshot
    let rmsErrorNorm: Double
    let maxErrorNorm: Double
}

struct PaperSizeSnapshot: Decodable {
    let width: Double
    let height: Double
}

struct HomographySnapshot: Decodable, Equatable {
    let coefficients: [Double]
}

struct BindingMarkPreviewRequest: Encodable {
    let pointSet: String
    let marginMm: Double?
    let markSizeMm: Double
    let maxMarkSizeMm: Double
    let extraPaddingMm: Double
    let parkClearanceMm: Double
    let observationClearanceMm: Double
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BindingMarkPreviewResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let registrationId: String
    let pointSet: String
    let pointCount: Int
    let markSizeMm: Double
    let safeZone: BridgeDrawingSafeZone?
    let planHash: String
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let points: [BindingMarkPreviewPoint]
    let cameraSegments: [BindingMarkPreviewSegment]
    let eventLog: String
    let error: String?
}

struct BindingMarkPreviewPoint: Decodable, Equatable {
    let pointId: String
    let paperMm: PaperPointMmSnapshot
    let cameraNorm: NormPoint
}

struct BindingMarkPreviewSegment: Decodable, Equatable {
    let pointId: String
    let startPaperMm: PaperPointMmSnapshot
    let endPaperMm: PaperPointMmSnapshot
    let startNorm: NormPoint
    let endNorm: NormPoint
    let lengthMm: Double
}

struct PaperPointMmSnapshot: Codable, Equatable {
    let x: Double
    let y: Double
}

struct MachineStatusResponse: Decodable {
    let status: String
    let dryRun: Bool
    let controller: String
    let armMotion: Bool
    let armPen: Bool
    let armHoming: Bool
    let armUnlock: Bool
    let state: String
    let homingTrusted: Bool
    let axisModelTrusted: Bool
    let mposMm: [Double]?
    let wposMm: [Double]?
    let pins: String
    let feedSpindle: [Double]?
    let fields: [String: String]
    let isBusy: Bool
    let isAlarm: Bool
    let activeCommandId: String?
    let activeAction: String?
    let error: String?
}

struct MachineJogRequest: Encodable {
    let axis: String
    let distanceMm: Double
    let feedMmMin: Double
    let bypassWorkspaceProjection: Bool
    let requestId: String?
    let traceId: String?
    let spanId: String?
    let parentSpanId: String?

    init(
        axis: String,
        distanceMm: Double,
        feedMmMin: Double,
        bypassWorkspaceProjection: Bool = false,
        requestId: String? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        parentSpanId: String? = nil
    ) {
        self.axis = axis
        self.distanceMm = distanceMm
        self.feedMmMin = feedMmMin
        self.bypassWorkspaceProjection = bypassWorkspaceProjection
        self.requestId = requestId
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
    }
}

struct MachineRelativeMoveRequest: Encodable {
    let xMm: Double
    let yMm: Double
    let feedMmMin: Double
    let ensurePenUp: Bool
    let bypassWorkspaceProjection: Bool
    let requestId: String?
    let traceId: String?
    let spanId: String?
    let parentSpanId: String?

    init(
        xMm: Double,
        yMm: Double,
        feedMmMin: Double,
        ensurePenUp: Bool,
        bypassWorkspaceProjection: Bool = false,
        requestId: String? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        parentSpanId: String? = nil
    ) {
        self.xMm = xMm
        self.yMm = yMm
        self.feedMmMin = feedMmMin
        self.ensurePenUp = ensurePenUp
        self.bypassWorkspaceProjection = bypassWorkspaceProjection
        self.requestId = requestId
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
    }
}

struct MachineRelativeMarkRequest: Encodable {
    let markSizeMm: Double
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineReconnectRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineHomeRequest: Encodable {
    let centerAfter: Bool
    let centerFeedMmMin: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineCenterRequest: Encodable {
    let feedMmMin: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachinePenRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineDotMarkRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineStopRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineResumeRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineUnlockRequest: Encodable {
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct MachineArmRequest: Encodable {
    let live: Bool
    let autoConnect: Bool
    let armMotion: Bool
    let armPen: Bool
    let armHoming: Bool
    let armUnlock: Bool
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct AxisModelTrustSampleRequest: Codable {
    let axis: String
    let commandedDistanceMm: Double
    let observedDxMm: Double
    let observedDyMm: Double
    let observedDistanceMm: Double
}

struct AxisModelTrustRequest: Encodable {
    let source: String
    let sampleCount: Int
    let rmsResidualMm: Double
    let maxResidualMm: Double
    let minObservedDistanceMm: Double
    let commandDistanceMm: Double
    let samples: [AxisModelTrustSampleRequest]
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeVisualCapObservationRequest: Encodable {
    let observedNorm: NormPoint
    let observedPaperNorm: NormPoint?
    let observedLogicalMm: PaperPointMmSnapshot?
    let source: String
    let confidence: Double
    let cameraId: String?
    let cameraName: String?
    let safeZoneInsetXMm: Double
    let safeZoneInsetYMm: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeCalibrationCapConfirmationRequest: Encodable {
    let observedNorm: NormPoint
    let source: String
    let confidence: Double
    let cameraId: String?
    let cameraName: String?
    let requestId: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeVisualProbeCapSnapshotRequest: Encodable {
    let cameraNorm: NormPoint
    let paperNorm: NormPoint
    let logicalMm: PaperPointMmSnapshot
    let frameId: Int
    let confidence: Double
}

struct BridgeVisualProbeSampleRequest: Encodable {
    let runId: String
    let sampleId: String
    let requestId: String?
    let planId: String?
    let commandId: String?
    let cameraId: String?
    let cameraName: String?
    let source: String
    let axis: String?
    let commandedDxMm: Double
    let commandedDyMm: Double
    let before: BridgeVisualProbeCapSnapshotRequest
    let after: BridgeVisualProbeCapSnapshotRequest
    let predictedDxMm: Double?
    let predictedDyMm: Double?
    let residualMm: Double?
    let residualLimitMm: Double?
    let status: String
    let blockers: [String]
    let rejectionReason: String?
    let controllerTranscript: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeVisualReadinessResponse: Decodable {
    let status: String
    let dryRun: Bool
    let readiness: BridgeVisualReadinessState?
    let workflow: BridgeCalibrationWorkflow?
    let readinessFile: String
    let error: String?
}

struct BridgeCalibrationWorkflow: Decodable, Equatable {
    let phase: String
    let activity: String
    let health: String
    let isStale: Bool
    let isBlocked: Bool
    let readyToDraw: Bool
    let steps: [BridgeCalibrationWorkflowStep]
    let currentBlocker: String?
    let nextPrimaryAction: BridgeCalibrationWorkflowAction
    let safeAutoActions: [String]
    let resetActions: [BridgeCalibrationWorkflowResetAction]
    let freshness: BridgeCalibrationWorkflowFreshness
    let overlayBadge: BridgeCalibrationWorkflowBadge
}

struct BridgeCalibrationWorkflowStep: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let state: String
    let detail: String
}

struct BridgeCalibrationWorkflowAction: Decodable, Equatable {
    let id: String
    let label: String
    let enabled: Bool
    let requiresMotion: Bool
    let requiresDrawing: Bool
}

struct BridgeCalibrationWorkflowResetAction: Decodable, Equatable, Identifiable {
    let id: String
    let label: String
    let role: String
    let enabled: Bool
    let scope: String
    let help: String
    let confirmationTitle: String
    let confirmationMessage: String
    let requestedStatus: String
    let canceledStatus: String
    let completedStatus: String
}

struct BridgeCalibrationWorkflowFreshness: Decodable, Equatable {
    let paperRegistrationId: String?
    let cameraId: String?
    let capConfirmationId: String?
    let capConfirmed: Bool
    let visualReadinessStateId: String?
    let latestVisualProbeRunId: String?
    let probeStaleSampleCount: Int
    let drawingSessionId: String?
    let drawingModelId: String?
    let penReadyConfirmed: Bool
    let staleReasons: [String]
}

struct BridgeCalibrationWorkflowBadge: Decodable, Equatable {
    let state: String
    let label: String
    let color: String
}

struct BridgeVisualBindingObservationRequest: Encodable {
    let commandId: String
    let pointId: String?
    let kind: String
    let observedNorm: NormPoint?
    let observedPaperMm: PaperPointMmSnapshot?
    let expectedPaperMm: PaperPointMmSnapshot?
    let cameraId: String?
    let cameraName: String?
    let confidence: Double
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeVisualBindingSolveRequest: Encodable {
    let requestId: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeVisualPositionBindingResponse: Decodable {
    let status: String
    let dryRun: Bool
    let binding: BridgeVisualPositionBinding?
    let bindingFile: String
    let observationId: String?
    let error: String?
}

struct BridgeVisualPositionBinding: Decodable {
    let bindingId: String
    let paperRegistrationId: String
    let camera: BridgeBindingCameraIdentity
    let safeZone: BridgeDrawingSafeZone?
    let capToTipModel: BridgeCapToTipModel
    let commandIds: [String]
    let expectedSimulatedGeometry: [BridgeExpectedGeometrySample]
    let observedGeometry: [BridgeObservedGeometrySample]
    let residuals: BridgeBindingResidualSummary
    let validationStatus: String
    let blockers: [String]
}

struct BridgeBindingCameraIdentity: Decodable {
    let cameraId: String?
    let cameraName: String?
}

struct BridgeExpectedGeometrySample: Decodable {
    let sampleId: String
    let commandId: String
    let pointId: String
    let segmentIndex: Int
    let role: String
    let expectedPaperMm: PaperPointMmSnapshot
    let expectedCameraNorm: NormPoint?
}

struct BridgeObservedGeometrySample: Decodable {
    let observationId: String
    let commandId: String
    let pointId: String
    let kind: String
    let expectedPaperMm: PaperPointMmSnapshot
    let observedPaperMm: PaperPointMmSnapshot
    let observedCameraNorm: NormPoint?
    let cameraId: String?
    let cameraName: String?
    let paperRegistrationId: String
}

struct BridgeBindingResidualSummary: Decodable {
    let observationCount: Int
    let rmsResidualMm: Double?
    let maxResidualMm: Double?
    let axesRepresented: [String]
    let nonCollinear: Bool
}

struct BridgeDrawingFrameEdgeObservationRequest: Encodable {
    let edgeIndex: Int
    let expectedStartMm: PaperPointMmSnapshot
    let expectedEndMm: PaperPointMmSnapshot
    let observedStartMm: PaperPointMmSnapshot?
    let observedEndMm: PaperPointMmSnapshot?
    let sampleCount: Int
    let detectedSampleCount: Int
    let greenPixelCount: Int
    let coverageFraction: Double
    let rmsExpectedResidualMm: Double?
    let maxExpectedResidualMm: Double?
    let fitRmsResidualMm: Double?
    let angleErrorDeg: Double?
}

struct BridgeDrawingFrameCornerObservationRequest: Encodable {
    let cornerIndex: Int
    let expectedMm: PaperPointMmSnapshot
    let observedMm: PaperPointMmSnapshot
    let residualMm: Double
}

struct BridgeDrawingFrameObservationRequest: Encodable {
    let commandId: String?
    let paperRegistrationId: String?
    let cameraId: String?
    let cameraName: String?
    let expectedCornersMm: [PaperPointMmSnapshot]
    let edges: [BridgeDrawingFrameEdgeObservationRequest]
    let corners: [BridgeDrawingFrameCornerObservationRequest]
    let totalGreenPixels: Int
    let detectedEdgeCount: Int
    let rmsResidualMm: Double?
    let maxResidualMm: Double?
    let cornerRmsResidualMm: Double?
    let cornerMaxResidualMm: Double?
    let usable: Bool
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeDrawingProgramSampleObservationRequest: Encodable {
    let primitiveId: String
    let strokeId: String? = nil
    let sampleIndex: Int
    let expectedMm: PaperPointMmSnapshot
    let desiredMm: PaperPointMmSnapshot? = nil
    let commandedMm: PaperPointMmSnapshot? = nil
    let predictedObservedMm: PaperPointMmSnapshot? = nil
    let expectedCameraNorm: NormPoint?
    let observedMm: PaperPointMmSnapshot?
    let observedCameraNorm: NormPoint?
    let residualMm: Double?
    let detected: Bool
    let greenPixelCount: Int
}

struct BridgeDrawingProgramPrimitiveObservationRequest: Encodable {
    let primitiveId: String
    let primitiveKind: String
    let sampleCount: Int
    let detectedSampleCount: Int
    let greenPixelCount: Int
    let coverageFraction: Double
    let rmsResidualMm: Double?
    let p95ResidualMm: Double?
    let maxResidualMm: Double?
}

struct BridgeDrawingProgramObservationRequest: Encodable {
    let schemaVersion: Int = 1
    let commandId: String?
    let paperRegistrationId: String?
    let cameraId: String?
    let cameraName: String?
    let programId: String
    let programKind: String
    let sessionId: String?
    let batchId: String?
    let runId: String?
    let planHash: String?
    let correctionMode: String
    let modelIdUsed: String?
    let expectedFrameCornersMm: [PaperPointMmSnapshot]?
    let primitives: [BridgeDrawingProgramPrimitiveObservationRequest]
    let samples: [BridgeDrawingProgramSampleObservationRequest]
    let sampleCount: Int
    let detectedSampleCount: Int
    let totalGreenPixels: Int
    let coverageFraction: Double
    let rmsResidualMm: Double?
    let p95ResidualMm: Double?
    let maxResidualMm: Double?
    let usable: Bool
    let blockers: [String]
    let requestId: String? = nil
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil

    init(
        commandId: String?,
        paperRegistrationId: String?,
        cameraId: String?,
        cameraName: String?,
        programId: String,
        programKind: String,
        sessionId: String? = nil,
        batchId: String? = nil,
        runId: String? = nil,
        planHash: String? = nil,
        correctionMode: String = "uncorrected",
        modelIdUsed: String? = nil,
        expectedFrameCornersMm: [PaperPointMmSnapshot]?,
        primitives: [BridgeDrawingProgramPrimitiveObservationRequest],
        samples: [BridgeDrawingProgramSampleObservationRequest],
        sampleCount: Int,
        detectedSampleCount: Int,
        totalGreenPixels: Int,
        coverageFraction: Double,
        rmsResidualMm: Double?,
        p95ResidualMm: Double?,
        maxResidualMm: Double?,
        usable: Bool,
        blockers: [String] = []
    ) {
        self.commandId = commandId
        self.paperRegistrationId = paperRegistrationId
        self.cameraId = cameraId
        self.cameraName = cameraName
        self.programId = programId
        self.programKind = programKind
        self.sessionId = sessionId
        self.batchId = batchId
        self.runId = runId
        self.planHash = planHash
        self.correctionMode = correctionMode
        self.modelIdUsed = modelIdUsed
        self.expectedFrameCornersMm = expectedFrameCornersMm
        self.primitives = primitives
        self.samples = samples
        self.sampleCount = sampleCount
        self.detectedSampleCount = detectedSampleCount
        self.totalGreenPixels = totalGreenPixels
        self.coverageFraction = coverageFraction
        self.rmsResidualMm = rmsResidualMm
        self.p95ResidualMm = p95ResidualMm
        self.maxResidualMm = maxResidualMm
        self.usable = usable
        self.blockers = blockers
    }
}

struct BridgeDrawingCalibrationResponse: Decodable {
    let status: String
    let dryRun: Bool
    let calibration: BridgeDrawingCalibrationModel?
    let calibrationFile: String
    let observationId: String?
    let error: String?
}

struct BridgeDrawingCalibrationModel: Decodable, Equatable {
    let modelId: String
    let modelVersion: String?
    let paperRegistrationId: String
    let cameraId: String?
    let cameraName: String?
    let fieldWidthMm: Double
    let fieldHeightMm: Double
    let modelFamily: String
    let solverKind: String
    let globalModelKind: String?
    let validationStatus: String
    let observationCount: Int
    let usableObservationCount: Int
    let gridControlCount: Int?
    let sampleCount: Int?
    let fitSampleCount: Int?
    let acceptedFitSampleCount: Int?
    let rejectedSampleCount: Int?
    let holdoutSampleCount: Int?
    let coverageFraction: Double?
    let latestObservationId: String?
    let expectedToObserved: HomographySnapshot?
    let observedToExpected: HomographySnapshot?
    let residualGrid: BridgeDrawingResidualGrid?
    let actionModelKind: String?
    let actionFeatureNames: [String]?
    let actionRegularization: Double?
    let actionMaxCorrectionMm: Double?
    let actionModelBlockers: [String]?
    let coverage: BridgeDrawingCalibrationCoverage?
    let fitMetrics: BridgeDrawingCalibrationMetrics?
    let holdoutMetrics: BridgeDrawingCalibrationMetrics?
    let validationMetrics: BridgeDrawingCalibrationMetrics?
    let rmsResidualMm: Double?
    let p95ResidualMm: Double?
    let maxResidualMm: Double?
    let cornerRmsResidualMm: Double?
    let cornerMaxResidualMm: Double?
    let holdoutRmsResidualMm: Double?
    let holdoutMaxResidualMm: Double?
    let blockers: [String]
    let staleReasons: [String]?

    var statusLabel: String {
        validationStatus.uppercased().replacingOccurrences(of: "_", with: " ")
    }
}

struct BridgeDrawingResidualGrid: Decodable, Equatable {
    let modelVersion: String?
    let columns: Int
    let rows: Int
    let coverageRadiusMm: Double?
    let uncertaintyLimitMm: Double?
    let maxCorrectionMm: Double?
    let nodes: [BridgeDrawingResidualGridNode]
}

struct BridgeDrawingResidualGridNode: Decodable, Equatable {
    let indexX: Int
    let indexY: Int
    let xMm: Double
    let yMm: Double
    let residualXMm: Double
    let residualYMm: Double
    let sourceSampleCount: Int
    let nearestSampleDistanceMm: Double?
    let uncertaintyMm: Double
}

struct BridgeDrawingCalibrationCoverage: Decodable, Equatable {
    let sampleCount: Int
    let acceptedSampleCount: Int
    let holdoutSampleCount: Int
    let totalNodeCount: Int
    let coveredNodeCount: Int
    let coverageFraction: Double
    let coverageRadiusMm: Double?
    let maxNodeUncertaintyMm: Double?
}

struct BridgeDrawingCalibrationMetrics: Decodable, Equatable {
    let sampleCount: Int
    let rmsMm: Double?
    let p95Mm: Double?
    let maxMm: Double?
}

struct BridgeDrawingCalibrationSessionStartRequest: Encodable {
    let resume: Bool
    let penReadyConfirmed: Bool
    let penReadyConfirmation: [String: String]
    let requestId: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil

    init(
        resume: Bool = true,
        penReadyConfirmed: Bool,
        penReadyConfirmation: [String: String],
        requestId: String? = nil
    ) {
        self.resume = resume
        self.penReadyConfirmed = penReadyConfirmed
        self.penReadyConfirmation = penReadyConfirmation
        self.requestId = requestId
    }
}

struct BridgeDrawingCalibrationSessionBatchRequest: Encodable {
    let sessionId: String?
    let batchId: String?
    let correctionMode: String?
    let expectedPlanHash: String?
    let requestId: String?
    let traceId: String? = nil
    let spanId: String? = nil
    let parentSpanId: String? = nil
}

struct BridgeDrawingCalibrationCompletionCriteria: Decodable, Equatable {
    let minSampleCount: Int
    let minCoverageFraction: Double
    let maxNodeUncertaintyMm: Double
    let fitRmsLimitMm: Double
    let fitP95LimitMm: Double
    let fitMaxLimitMm: Double
    let validationRmsLimitMm: Double
    let validationP95LimitMm: Double
    let validationMaxLimitMm: Double
    let maxRetriesPerBatch: Int
}

struct BridgeDrawingCalibrationBatch: Decodable, Equatable {
    let batchId: String
    let batchIndex: Int
    let purpose: String
    let programKind: String
    let correctionMode: String
    let modelIdUsed: String?
    let commandId: String?
    let planHash: String?
    let retryCount: Int
    let maxRetries: Int
    let status: String
    let fitMetrics: BridgeDrawingCalibrationMetrics?
    let validationMetrics: BridgeDrawingCalibrationMetrics?
    let blockers: [String]
}

struct BridgeDrawingCalibrationObservationRecord: Decodable, Equatable {
    let observationId: String
    let batchId: String?
    let disposition: String
    let reasons: [String]
}

struct BridgeDrawingCalibrationSession: Decodable, Equatable {
    let sessionId: String
    let schemaVersion: Int
    let status: String
    let paperRegistrationId: String
    let cameraId: String?
    let cameraName: String?
    let fieldWidthMm: Double
    let fieldHeightMm: Double
    let penReadyConfirmed: Bool
    let penReadyConfirmedAt: String?
    let startedAt: String
    let updatedAt: String
    let latestModelId: String?
    let currentBatchId: String?
    let batches: [BridgeDrawingCalibrationBatch]
    let observations: [BridgeDrawingCalibrationObservationRecord]
    let blockers: [String]
    let completionCriteria: BridgeDrawingCalibrationCompletionCriteria?
    let promotionStatus: String
}

struct BridgeDrawingCalibrationSessionStatusResponse: Decodable {
    let status: String
    let dryRun: Bool
    let session: BridgeDrawingCalibrationSession?
    let sessionFile: String
    let calibration: BridgeDrawingCalibrationModel?
    let calibrationFile: String
    let error: String?
}

struct BridgeDrawingCalibrationSessionActionResponse: Decodable {
    let status: String
    let dryRun: Bool
    let session: BridgeDrawingCalibrationSession?
    let sessionFile: String
    let calibration: BridgeDrawingCalibrationModel?
    let calibrationFile: String
    let batch: BridgeDrawingCalibrationBatch?
    let preview: BridgeDrawingCalibrationProgramResponse?
    let run: BridgeDrawingCalibrationProgramResponse?
    let observationId: String?
    let retryScheduled: Bool
    let error: String?
}

struct BridgeVisualProbeSampleResponse: Decodable {
    let status: String
    let dryRun: Bool
    let readiness: BridgeVisualReadinessState?
    let readinessFile: String
    let error: String?
}

struct BridgeVisualReadinessState: Decodable, Equatable {
    let schemaVersion: Int
    let artifactType: String
    let stateId: String
    let updatedAt: String
    let paperRegistered: Bool
    let paperRegistrationId: String?
    let capLocalized: Bool
    let capInsideSafeZone: Bool
    let latestCapObservation: BridgeVisualCapObservation?
    let safeZoneEvaluation: BridgeSafeZoneEvaluation?
    let probeRawSampleCount: Int?
    let probeObservationCount: Int
    let probeRejectedSampleCount: Int?
    let probeStaleSampleCount: Int?
    let probeAxesRepresented: [String]?
    let probeAdaptiveSampleCount: Int?
    let probeCenterTargetSampleCount: Int?
    let probeRmsResidualMm: Double?
    let probeMaxResidualMm: Double?
    let motionModelValid: Bool?
    let relativeMotionModel: BridgeRelativeMotionModel?
    let motionModelBlockers: [String]?
    let visualReadyToPlot: Bool
    let blockers: [String]
}

struct BridgeRelativeMotionModel: Decodable, Equatable {
    let schemaVersion: Int?
    let artifactType: String?
    let machineToFieldMatrix: [[Double]]
    let fieldToMachineMatrix: [[Double]]
    let determinant: Double
    let sampleCount: Int
    let rmsResidualMm: Double
    let p95ResidualMm: Double?
    let maxResidualMm: Double

    var visualMotionModel: VisualMotionModel? {
        guard machineToFieldMatrix.count == 2,
              machineToFieldMatrix[0].count == 2,
              machineToFieldMatrix[1].count == 2 else {
            return nil
        }
        let model = VisualMotionModel(
            xBasisDx: machineToFieldMatrix[0][0],
            xBasisDy: machineToFieldMatrix[1][0],
            yBasisDx: machineToFieldMatrix[0][1],
            yBasisDy: machineToFieldMatrix[1][1],
            rmsResidualMm: rmsResidualMm,
            maxResidualMm: maxResidualMm,
            sampleCount: sampleCount
        )
        return model.isUsable ? model : nil
    }
}

struct BridgeVisualCapObservation: Decodable, Equatable {
    let schemaVersion: Int
    let observationId: String
    let target: String
    let timestamp: String
    let cameraNorm: NormPoint
    let paperNorm: NormPoint
    let logicalMm: PaperPointMmSnapshot?
    let cameraId: String?
    let cameraName: String?
    let paperRegistrationId: String?
    let confidence: Double
    let source: String
}

struct BridgeSafeZoneEvaluation: Decodable, Equatable {
    let capObservationId: String
    let target: String
    let inside: Bool
    let logicalMm: PaperPointMmSnapshot
    let abortReasons: [BridgeSafeZoneAbortReason]
}

struct BridgeSafeZoneAbortReason: Decodable, Equatable {
    let code: String
    let message: String
}

struct MachineCommandResponse: Decodable {
    let commandId: String
    let action: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
    let error: String?
}

final class PlotterBridgeClient {
    let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.baseURL = baseURL
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    func health() async throws -> BridgeHealthResponse {
        try await get(path: "health")
    }

    func drawProgram(_ request: BridgeDrawProgramRequest) async throws -> BridgeDrawProgramResponse {
        try await post(path: "draw/program", request: request)
    }

    func previewImageShape(_ request: BridgeImageShapePreviewRequest) async throws -> BridgeImageShapePreviewResponse {
        let url = baseURL.appendingPathComponent("draw/image/preview")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeImageShapePreviewResponse.self, from: data)
    }

    func previewPortraitContours(
        _ request: BridgePortraitContourPreviewRequest
    ) async throws -> BridgePortraitContourPreviewResponse {
        try await post(path: "draw/portrait/preview", request: request)
    }

    func previewCapabilityTest(_ request: BridgeCapabilityTestRequest) async throws -> BridgeCapabilityTestResponse {
        try await post(path: "capabilities/tests/preview", request: request)
    }

    func runCapabilityTest(_ request: BridgeCapabilityTestRequest) async throws -> BridgeCapabilityTestResponse {
        try await post(path: "capabilities/tests/run", request: request)
    }

    func registerPaper(_ request: PaperRegistrationRequest) async throws -> PaperRegistrationResponse {
        try await post(path: "paper/register", request: request)
    }

    func paperStatus() async throws -> PaperRegistrationResponse {
        let url = baseURL.appendingPathComponent("paper/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           http.statusCode == 404,
           let missing = try? decoder.decode(PaperRegistrationResponse.self, from: data),
           missing.status == "missing" {
            return missing
        }
        try validate(response: response, data: data)
        return try decoder.decode(PaperRegistrationResponse.self, from: data)
    }

    func resetCalibrationSetup(_ request: BridgeSetupResetRequest) async throws -> BridgeSetupResetResponse {
        try await post(path: "calibration/setup/reset", request: request)
    }

    func previewBindingMarks(_ request: BindingMarkPreviewRequest) async throws -> BindingMarkPreviewResponse {
        try await post(path: "calibration/binding/preview", request: request)
    }

    func machineStatus() async throws -> MachineStatusResponse {
        try await get(path: "machine/status")
    }

    func arm(_ request: MachineArmRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/arm", request: request)
    }

    func jog(_ request: MachineJogRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/jog", request: request)
    }

    func relativeMove(_ request: MachineRelativeMoveRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/relative-move", request: request)
    }

    func relativeMark(_ request: MachineRelativeMarkRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/relative-mark", request: request)
    }

    func reconnect(_ request: MachineReconnectRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/reconnect", request: request)
    }

    func home(_ request: MachineHomeRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/home", request: request)
    }

    func center(_ request: MachineCenterRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/center", request: request)
    }

    func penUp(_ request: MachinePenRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/pen-up", request: request)
    }

    func penDown(_ request: MachinePenRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/pen-down", request: request)
    }

    func dotMark(_ request: MachineDotMarkRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/dot-mark", request: request)
    }

    func stop(_ request: MachineStopRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/stop", request: request)
    }

    func resume(_ request: MachineResumeRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/resume", request: request)
    }

    func unlock(_ request: MachineUnlockRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/unlock", request: request)
    }

    func trustAxisModel(_ request: AxisModelTrustRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "machine/axis-model/trust", request: request)
    }

    func visualReadinessStatus() async throws -> BridgeVisualReadinessResponse {
        try await get(path: "calibration/workflow/status")
    }

    func confirmCalibrationCap(
        _ request: BridgeCalibrationCapConfirmationRequest
    ) async throws -> BridgeVisualReadinessResponse {
        try await post(path: "calibration/workflow/cap/confirm", request: request)
    }

    func visualPositionBindingStatus() async throws -> BridgeVisualPositionBindingResponse {
        try await get(path: "calibration/binding/status")
    }

    func drawingCalibrationStatus() async throws -> BridgeDrawingCalibrationResponse {
        try await get(path: "calibration/drawing/status")
    }

    func drawingCalibrationSessionStatus() async throws -> BridgeDrawingCalibrationSessionStatusResponse {
        try await get(path: "calibration/drawing/session/status")
    }

    func startDrawingCalibrationSession(
        _ request: BridgeDrawingCalibrationSessionStartRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/start", request: request)
    }

    func previewNextDrawingCalibrationBatch(
        _ request: BridgeDrawingCalibrationSessionBatchRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/preview-next-batch", request: request)
    }

    func runDrawingCalibrationBatch(
        _ request: BridgeDrawingCalibrationSessionBatchRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/run-batch", request: request)
    }

    func observeDrawingCalibrationBatch(
        _ request: BridgeDrawingProgramObservationRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/observe-batch", request: request)
    }

    func fitDrawingCalibrationSession(
        _ request: BridgeDrawingCalibrationSessionBatchRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/fit", request: request)
    }

    func validateDrawingCalibrationSession(
        _ request: BridgeDrawingCalibrationSessionBatchRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/validate", request: request)
    }

    func finishDrawingCalibrationSession(
        _ request: BridgeDrawingCalibrationSessionBatchRequest
    ) async throws -> BridgeDrawingCalibrationSessionActionResponse {
        try await post(path: "calibration/drawing/session/finish", request: request)
    }

    func observeVisualCap(_ request: BridgeVisualCapObservationRequest) async throws -> BridgeVisualReadinessResponse {
        try await post(path: "calibration/pen/observe", request: request)
    }

    func observeVisualBinding(_ request: BridgeVisualBindingObservationRequest) async throws -> BridgeVisualPositionBindingResponse {
        try await post(path: "calibration/binding/observe", request: request)
    }

    func solveVisualBinding(_ request: BridgeVisualBindingSolveRequest) async throws -> BridgeVisualPositionBindingResponse {
        try await post(path: "calibration/binding/solve", request: request)
    }

    func observeDrawingFrame(
        _ request: BridgeDrawingFrameObservationRequest
    ) async throws -> BridgeDrawingCalibrationResponse {
        try await post(path: "calibration/drawing/frame-observation", request: request)
    }

    func observeDrawingProgram(
        _ request: BridgeDrawingProgramObservationRequest
    ) async throws -> BridgeDrawingCalibrationResponse {
        try await post(path: "calibration/drawing/program-observation", request: request)
    }

    func observeVisualProbeSample(_ request: BridgeVisualProbeSampleRequest) async throws -> BridgeVisualProbeSampleResponse {
        try await post(path: "calibration/probe/observe", request: request)
    }

    private func postMachineCommand<Request: Encodable>(
        path: String,
        request: Request
    ) async throws -> MachineCommandResponse {
        try await post(path: path, request: request)
    }

    private func get<Response: Decodable>(path: String) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        request: Request
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(BridgeImageShapePreviewResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgePortraitContourPreviewResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeCapabilityTestResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(PaperRegistrationResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BindingMarkPreviewResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(MachineCommandResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(MachineStatusResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeVisualReadinessResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeVisualPositionBindingResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeDrawingCalibrationResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            throw BridgeClientError.httpStatus(http.statusCode)
        }
    }
}
