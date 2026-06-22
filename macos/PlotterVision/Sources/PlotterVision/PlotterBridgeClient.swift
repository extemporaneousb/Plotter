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
    return 3
}

func normalizedBuildId(_ value: String?) -> String? {
    cleanBridgeMetadata(value)?.lowercased()
}

func shortBuildId(_ value: String?) -> String? {
    guard let value = cleanBridgeMetadata(value) else { return nil }
    return String(value.prefix(10))
}

struct BridgeShapeExecutionRequest: Encodable {
    let pattern: String
    let includeHoming: Bool
    let includeCentering: Bool
    let sideMm: Double
    let centerXMm: Double
    let centerYMm: Double
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
}

struct BridgeShapeExecutionResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let pattern: String
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let evaluation: BridgeShapeEvaluation?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let error: String?
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

struct BridgePolygonDrawRequest: Encodable {
    let program: BridgeDrawingProgramRequest
    let frame: BridgeDrawingFrameRequest?
    let includeHoming: Bool
    let visualPositionTrusted: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let maxPolylineCount: Int
    let requestId: String?
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

struct BridgeFaceRasterDrawRequest: Encodable {
    let raster: BridgeLuminanceRasterRequest
    let frame: BridgeDrawingFrameRequest
    let options: BridgeRasterPolygonOptionsRequest
    let includeHoming: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
}

struct BridgeImageShapePreviewRequest: Encodable {
    let raster: BridgeLuminanceRasterRequest
    let frame: BridgeDrawingFrameRequest
    let options: BridgeRasterContourOptionsRequest
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
}

struct BridgePolygonDrawSummary: Decodable {
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

struct BridgeFaceRasterDrawResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let summary: BridgePolygonDrawSummary?
    let rasterSummary: BridgeRasterPolygonSummary?
    let previewOverlay: BridgePreviewOverlay?
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
    let error: String?
}

struct BridgePolygonDrawResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let summary: BridgePolygonDrawSummary?
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
    let summary: BridgePolygonDrawSummary?
    let rasterSummary: BridgeRasterContourSummary?
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
    let summary: BridgePolygonDrawSummary?
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
}

struct PaperRegistrationResponse: Decodable {
    let status: String
    let dryRun: Bool
    let registration: PaperRegistrationSnapshot?
    let registrationFile: String
    let error: String?
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

struct HomographySnapshot: Decodable {
    let coefficients: [Double]
}

struct DotTestPreviewRequest: Encodable {
    let pattern: String
    let marginMm: Double
    let markSizeMm: Double
    let includeHoming: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
}

struct DotTestRunRequest: Encodable {
    let pattern: String
    let marginMm: Double
    let markSizeMm: Double
    let includeHoming: Bool
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
    let maxSegmentMm: Double
    let expectedPlanHash: String
}

struct DotTestPreviewResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let registrationId: String
    let pattern: String
    let pointCount: Int
    let markSizeMm: Double
    let planHash: String
    let plannedCommands: [String]
    let simulation: BridgeShapeSimulation?
    let points: [DotTestPreviewPoint]
    let cameraSegments: [DotTestPreviewSegment]
    let eventLog: String
    let error: String?
}

struct DotTestPreviewPoint: Decodable, Equatable {
    let pointId: String
    let paperMm: PaperPointMmSnapshot
    let cameraNorm: NormPoint
}

struct DotTestPreviewSegment: Decodable, Equatable {
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
}

struct MachineRelativeMoveRequest: Encodable {
    let xMm: Double
    let yMm: Double
    let feedMmMin: Double
    let ensurePenUp: Bool
}

struct MachineRelativeMarkRequest: Encodable {
    let markSizeMm: Double
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
}

struct MachineReconnectRequest: Encodable {
}

struct MachineHomeRequest: Encodable {
    let centerAfter: Bool
    let centerFeedMmMin: Double
}

struct MachineCenterRequest: Encodable {
    let feedMmMin: Double
}

struct MachinePenRequest: Encodable {
}

struct MachineDotMarkRequest: Encodable {
}

struct MachineStopRequest: Encodable {
}

struct MachineResumeRequest: Encodable {
}

struct MachineUnlockRequest: Encodable {
}

struct MachineArmRequest: Encodable {
    let live: Bool
    let autoConnect: Bool
    let armMotion: Bool
    let armPen: Bool
    let armHoming: Bool
    let armUnlock: Bool
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
}

struct BridgeAdaptiveProbePreviewRequest: Encodable {
    let requestId: String?
    let safeZoneInsetXMm: Double
    let safeZoneInsetYMm: Double
    let maxXProbeMm: Double
    let maxYProbeMm: Double
    let minProbeMm: Double
    let clearanceMm: Double
    let bootstrapOnly: Bool
    let bootstrapTargetXMm: Double?
    let bootstrapBottomAllowanceMm: Double
    let bootstrapTopAllowanceMm: Double
    let feedMmMin: Double
}

struct BridgeAdaptiveProbeRunRequest: Encodable {
    let requestId: String?
    let safeZoneInsetXMm: Double
    let safeZoneInsetYMm: Double
    let maxXProbeMm: Double
    let maxYProbeMm: Double
    let minProbeMm: Double
    let clearanceMm: Double
    let bootstrapOnly: Bool
    let bootstrapTargetXMm: Double?
    let bootstrapBottomAllowanceMm: Double
    let bootstrapTopAllowanceMm: Double
    let feedMmMin: Double
    let expectedPlanId: String?
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
}

struct BridgeVisualReadinessResponse: Decodable {
    let status: String
    let dryRun: Bool
    let readiness: BridgeVisualReadinessState?
    let readinessFile: String
    let error: String?
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
}

struct BridgeVisualBindingSolveRequest: Encodable {
    let requestId: String?
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

struct BridgeAdaptiveProbeResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let previewOnly: Bool
    let plan: BridgeAdaptiveVisualProbePlan?
    let readiness: BridgeVisualReadinessState?
    let readinessFile: String
    let plannedCommands: [String]
    let eventLog: String
    let controllerTranscript: String?
    let machineStatus: MachineStatusResponse?
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
    let latestProbePlan: BridgeAdaptiveVisualProbePlan?
    let probeObservationCount: Int
    let probeRmsResidualMm: Double?
    let probeMaxResidualMm: Double?
    let visualReadyToPlot: Bool
    let blockers: [String]
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

struct BridgeAdaptiveVisualProbePlan: Decodable, Equatable {
    let schemaVersion: Int
    let artifactType: String
    let planMode: String?
    let planId: String
    let target: String
    let status: String
    let previewOnly: Bool
    let requiresHoming: Bool
    let capObservationId: String
    let safeZoneEvaluation: BridgeSafeZoneEvaluation
    let moves: [BridgeVisualProbeMove]
    let blockers: [String]
    let feedMmMin: Double
}

struct BridgeVisualProbeMove: Decodable, Equatable {
    let axis: String
    let direction: Int
    let stepMm: Double
    let relativeXMm: Double
    let relativeYMm: Double
    let availableNegativeMm: Double
    let availablePositiveMm: Double
    let maxStepMm: Double
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
    private let baseURL: URL
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

    func drawShape(_ request: BridgeShapeExecutionRequest) async throws -> BridgeShapeExecutionResponse {
        try await post(path: "draw/shape", request: request)
    }

    func previewShape(_ request: BridgeShapeExecutionRequest) async throws -> BridgeShapeExecutionResponse {
        try await post(path: "draw/shape/preview", request: request)
    }

    func drawPolygon(_ request: BridgePolygonDrawRequest) async throws -> BridgePolygonDrawResponse {
        try await post(path: "draw/polygon", request: request)
    }

    func drawFaceRaster(_ request: BridgeFaceRasterDrawRequest) async throws -> BridgeFaceRasterDrawResponse {
        try await post(path: "draw/face", request: request)
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

    func previewDotTest(_ request: DotTestPreviewRequest) async throws -> DotTestPreviewResponse {
        try await post(path: "dot-test/preview", request: request)
    }

    func runDotTest(_ request: DotTestRunRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "dot-test/run", request: request)
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

    func visualPositionBindingStatus() async throws -> BridgeVisualPositionBindingResponse {
        try await get(path: "calibration/binding/status")
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

    func previewAdaptiveProbe(_ request: BridgeAdaptiveProbePreviewRequest) async throws -> BridgeAdaptiveProbeResponse {
        try await post(path: "calibration/probe/preview", request: request)
    }

    func runAdaptiveProbe(_ request: BridgeAdaptiveProbeRunRequest) async throws -> BridgeAdaptiveProbeResponse {
        try await post(path: "calibration/probe/run", request: request)
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
            if let failure = try? decoder.decode(BridgeShapeExecutionResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeFaceRasterDrawResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeImageShapePreviewResponse.self, from: data),
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
            if let failure = try? decoder.decode(DotTestPreviewResponse.self, from: data),
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
            if let failure = try? decoder.decode(BridgeAdaptiveProbeResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            throw BridgeClientError.httpStatus(http.statusCode)
        }
    }
}
