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

private func cleanBridgeMetadata(_ value: String?) -> String? {
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

private func currentAppBuildId() -> String? {
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

private func currentRequiredBridgeApiVersion() -> Int {
    if let value = Bundle.main.object(forInfoDictionaryKey: "PlotterRequiredBridgeAPIVersion") as? Int {
        return value
    }
    if let value = Bundle.main.object(forInfoDictionaryKey: "PlotterRequiredBridgeAPIVersion") as? String,
       let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return parsed
    }
    return 3
}

private func normalizedBuildId(_ value: String?) -> String? {
    cleanBridgeMetadata(value)?.lowercased()
}

private func shortBuildId(_ value: String?) -> String? {
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

struct CalibrationStartRequest: Encodable {
    let marginMm: Double
    let travelFeedMmMin: Double
    let includeHoming: Bool
    let simulateObservations: Bool
    let syntheticNoiseNorm: Double
}

struct CalibrationSessionResponse: Decodable {
    let sessionId: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let observedCount: Int
    let model: CalibrationModelSnapshot
    let sessionFile: String
    let error: String?
}

struct CalibrationModelSnapshot: Decodable {
    let observationCount: Int?
    let rmsErrorNorm: Double?
    let maxErrorNorm: Double?
    let drawingSurfaceNorm: [String: Double]?
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

    func startCalibration(_ request: CalibrationStartRequest) async throws -> CalibrationSessionResponse {
        try await post(path: "calibration/start", request: request)
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
            if let failure = try? decoder.decode(CalibrationSessionResponse.self, from: data),
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

@MainActor
final class PlotterBridgeModel: ObservableObject {
    @Published var statusText = "Bridge not checked"
    @Published var shortStatus = "OFF"
    @Published var isOnline = false
    @Published var isRunning = false
    @Published var isDryRun = true
    @Published var bridgeController = "unconfigured"
    @Published var bridgeApiVersion: String?
    @Published var lifecycleMode: String?
    @Published var lifecycleLabel: String?
    @Published var bridgeBuildId: String?
    @Published var bridgeSourceRoot: String?
    @Published var bridgePid: Int?
    @Published var bridgeStartedAt: String?
    @Published var canRestartSafely: Bool?
    @Published var armMotion = false
    @Published var armPen = false
    @Published var armHoming = false
    @Published var armUnlock = false
    @Published var modelStatus = "MODEL --"
    @Published var paperTransformStatus = "PAPER --"
    @Published var paperRegistrationSnapshot: PaperRegistrationSnapshot?
    @Published var isCalibrating = false
    @Published var machineState = "--"
    @Published var machinePins = "-"
    @Published var machineMPos = "M --"
    @Published var machineWPos = "W --"
    @Published var machineFeedSpindle = "FS --"
    @Published var machineStatus = "Machine not sampled"
    @Published var machineHomingTrusted = false
    @Published var machineAxisModelTrusted = false
    @Published var previewStatus = "SIM --"
    @Published var imagePreviewStatus = "IMG --"
    @Published var imagePreviewDetail = "VISUAL ONLY"
    @Published var imagePreviewContourCount = 0
    @Published var imagePreviewEligibleForBridgePreview = false
    @Published var expectedPathSegments: [ExpectedPathSegment] = []
    @Published var dotTestPreviewStatus = "DOT --"
    @Published var adaptiveProbeStatus = "PROBE --"
    @Published var visualCenterDotStatus = "VIS --"
    @Published var latestAdaptiveProbePlan: BridgeAdaptiveVisualProbePlan?
    @Published var visualProbeEvidenceRunId = "swift-probe-\(UUID().uuidString.lowercased())"
    @Published var dotTestPreviewPoints: [DotTestPreviewPoint] = []
    @Published var dotTestPreviewSegments: [DotTestPreviewSegment] = []
    @Published var dotTestPreviewPlanHash = ""
    @Published var dotTestPreviewPattern = ""
    @Published var workspaceXMm = 533.4
    @Published var workspaceYMm = 215.9
    @Published var shapeSideMm = 35.0
    @Published var shapeCenterXNorm = 0.5
    @Published var shapeCenterYNorm = 0.5
    @Published var shapeDrawFeedMmMin = 180.0
    @Published var pathRevealProgress = 1.0
    @Published var pathAnimationStatus = "IDLE"
    @Published var isMachineBusy = false
    @Published var isMachineAlarm = false
    @Published var activeAction = ""
    @Published var manualStepMm = 1.0
    @Published var manualFeedMmMin = 500.0

    private let client = PlotterBridgeClient()
    private let diagnostics = AppDiagnostics.shared
    private let appBuildId = currentAppBuildId()
    private let requiredBridgeApiVersion = currentRequiredBridgeApiVersion()
    private var animationTask: Task<Void, Never>?
    private var isRefreshingMachineStatus = false
    private var lastDiagnosticsHealthSummary = ""
    private var lastDiagnosticsMachineSummary = ""
    private var lastDiagnosticsPaperSummary = ""

    init() {
        diagnosticsEvent("app_model_initialized", snapshot: true)
    }

    var isLiveMotionMode: Bool {
        isOnline && !isDryRun
    }

    func startVisualProbeEvidenceRun(prefix: String = "swift-probe") -> String {
        let runId = "\(prefix)-\(UUID().uuidString.lowercased())"
        visualProbeEvidenceRunId = runId
        return runId
    }

    var isMockBridge: Bool {
        bridgeController == "mock"
    }

    var hasControllerPort: Bool {
        bridgeController.hasPrefix("serial:")
    }

    var bridgeLifecycleTitle: String {
        if !isOnline { return "Offline" }
        if let title = Self.lifecycleTitle(for: lifecycleLabel) {
            return title
        }
        if let title = Self.lifecycleTitle(for: lifecycleMode) {
            return title
        }
        if isMockBridge { return "Preview Bridge" }
        if isLiveMotionMode { return "Live Bridge" }
        return "Hardware Standby"
    }

    var bridgeLifecycleLampValue: String {
        if hasBridgeApiMismatch { return "API" }
        if hasLifecycleBuildMismatch { return "STALE" }
        switch bridgeLifecycleTitle {
        case "Offline":
            return "OFF"
        case "Preview Bridge":
            return "PREVIEW"
        case "Hardware Standby":
            return "STBY"
        case "Live Bridge":
            return "LIVE"
        default:
            return String(bridgeLifecycleTitle.uppercased().prefix(8))
        }
    }

    var hasLifecycleBuildMismatch: Bool {
        guard isOnline,
              let appBuild = normalizedBuildId(appBuildId),
              let bridgeBuild = normalizedBuildId(bridgeBuildId) else {
            return false
        }
        return appBuild != bridgeBuild
    }

    var hasBridgeApiMismatch: Bool {
        guard isOnline,
              let rawVersion = cleanBridgeMetadata(bridgeApiVersion),
              let apiVersion = Int(rawVersion) else {
            return false
        }
        return apiVersion < requiredBridgeApiVersion
    }

    var bridgeLifecycleStatusLine: String {
        if !isOnline { return "Offline" }

        var parts = [bridgeLifecycleTitle]
        if hasBridgeApiMismatch,
           let apiVersion = cleanBridgeMetadata(bridgeApiVersion) {
            parts.append("API MISMATCH app \(requiredBridgeApiVersion) bridge \(apiVersion)")
        } else if hasLifecycleBuildMismatch,
           let appBuild = shortBuildId(appBuildId),
           let bridgeBuild = shortBuildId(bridgeBuildId) {
            parts.append("STALE app \(appBuild) bridge \(bridgeBuild)")
        } else if let build = shortBuildId(bridgeBuildId) {
            parts.append("build \(build)")
        }
        if let apiVersion = cleanBridgeMetadata(bridgeApiVersion) {
            parts.append("api \(apiVersion)")
        }
        return parts.joined(separator: " ")
    }

    var bridgeLifecycleHelp: String {
        if !isOnline {
            return "Offline\nStart a preview or hardware-standby bridge."
        }

        var lines = [bridgeLifecycleStatusLine]
        lines.append("Controller: \(bridgeController)")
        lines.append("Motion: \(motionModeLabel)")
        lines.append(motionGateMessage)
        if let pid = bridgePid {
            lines.append("PID: \(pid)")
        }
        if let startedAt = cleanBridgeMetadata(bridgeStartedAt) {
            lines.append("Started: \(startedAt)")
        }
        if let sourceRoot = cleanBridgeMetadata(bridgeSourceRoot) {
            lines.append("Source: \(sourceRoot)")
        }
        if let canRestartSafely {
            lines.append("Bridge-reported safe restart: \(canRestartSafely ? "yes" : "no")")
        }
        return lines.joined(separator: "\n")
    }

    var canConnectHardware: Bool {
        isOnline && !isMockBridge && !isRunning && !isMachineBusy
    }

    var canArmHardware: Bool {
        isOnline && !hasBridgeApiMismatch && !isMockBridge && isDryRun && !isRunning && !isMachineBusy
    }

    var canUsePlotterConnectionControl: Bool {
        isLiveMotionMode || canArmHardware
    }

    var canDisarmHardware: Bool {
        isOnline && !isDryRun && !isRunning && !isMachineBusy
    }

    var plotterConnectionTitle: String {
        if isRunning || isMachineBusy {
            return activeAction == "arm" ? "Connecting" : "Busy"
        }
        if hasBridgeApiMismatch { return "Bridge API Mismatch" }
        if hasLifecycleBuildMismatch { return "Stale Bridge" }
        return bridgeLifecycleTitle
    }

    var plotterConnectionSubtitle: String {
        if hasBridgeApiMismatch { return "Update Bridge" }
        if hasLifecycleBuildMismatch { return "Build Mismatch" }
        if !isOnline { return "Offline" }
        if isLiveMotionMode { return "Live Gated" }
        if isMockBridge { return "Preview Only" }
        return "Dry Run"
    }

    var plotterConnectionSystemName: String {
        if isRunning || isMachineBusy { return "hourglass" }
        if hasBridgeApiMismatch || hasLifecycleBuildMismatch { return "exclamationmark.triangle.fill" }
        if !isOnline { return "bolt.slash" }
        if isMockBridge { return "eye" }
        if isLiveMotionMode { return "checkmark.seal.fill" }
        return "cable.connector"
    }

    var plotterConnectionHelp: String {
        if hasBridgeApiMismatch {
            return "\(bridgeLifecycleHelp)\nBridge API is older than this app requires; restart the safe bridge from current code before live operation."
        }
        if hasLifecycleBuildMismatch {
            return "\(bridgeLifecycleHelp)\nApp and bridge build IDs differ; treat this bridge as stale until both come from the same checkout."
        }
        if !isOnline { return "Bridge is offline; start the Plotter bridge before connecting." }
        if isMockBridge { return "Mock preview bridge cannot connect to physical plotter hardware." }
        if isLiveMotionMode { return "Connected to plotter. Machine controls are live-gated." }
        if isRunning || isMachineBusy { return "Machine is busy; connection change is blocked." }
        return "\(bridgeLifecycleHelp)\nConnect to the physical plotter and leave dry-run mode. This probes status but does not move, home, unlock, or actuate the pen."
    }

    var hasPaperLock: Bool {
        paperRegistrationSnapshot != nil || paperTransformStatus.contains("LOCK")
    }

    var canRunAbsoluteDrawing: Bool {
        isLiveMotionMode
            && !hasBridgeApiMismatch
            && hasPaperLock
            && machineAxisModelTrusted
            && machineHomingTrusted
            && !isCalibrating
            && !isRunning
            && !isMachineBusy
            && !isMachineAlarm
    }

    var canRunCenterDotMotion: Bool {
        canRunAbsoluteDrawing
            && dotTestPreviewPattern == "center"
            && !dotTestPreviewPlanHash.isEmpty
    }

    var canRunVisualRelativeMotion: Bool {
        isLiveMotionMode
            && !hasBridgeApiMismatch
            && hasPaperLock
            && dotTestPreviewPattern == "center"
            && !dotTestPreviewPoints.isEmpty
            && !isCalibrating
            && !isRunning
            && !isMachineBusy
            && !isMachineAlarm
    }

    var motionModeLabel: String {
        if !isOnline { return "OFF" }
        if isMockBridge { return isDryRun ? "MOCK" : "MOCK LIVE" }
        if !hasControllerPort { return "STANDBY" }
        if isDryRun { return "DRY" }
        if isMachineAlarm { return "ALARM" }
        if isMachineBusy || isRunning { return "BUSY" }
        return "LIVE"
    }

    var armStatusLabel: String {
        let enabled = [
            armMotion ? "M" : nil,
            armPen ? "P" : nil,
            armHoming ? "H" : nil,
            armUnlock ? "U" : nil
        ].compactMap { $0 }
        return enabled.isEmpty ? "--" : enabled.joined(separator: "")
    }

    var motionGateMessage: String {
        if !isOnline { return "Motion blocked: bridge offline" }
        if hasBridgeApiMismatch { return "Motion blocked: bridge API mismatch; restart safe bridge" }
        if isMockBridge { return "Preview bridge only; start hardware standby to connect" }
        if !hasControllerPort { return "Controller not connected; connect or arm to auto-detect" }
        if isDryRun { return "Motion blocked: dry-run bridge; arm hardware to enable live controls" }
        if isMachineAlarm { return "Motion blocked: machine alarm" }
        if isMachineBusy || isRunning { return "Motion busy: \(activeAction)" }
        if !hasPaperLock { return "Bridge-run drawing blocked: paper homography missing" }
        if !machineAxisModelTrusted { return "Bridge-run drawing blocked: axis geometry not trusted" }
        if !machineHomingTrusted { return "Bridge-run drawing blocked: absolute position not trusted" }
        return "Live motion enabled"
    }

    var drawPreflightMessage: String {
        if !isOnline { return "Bridge offline" }
        if hasBridgeApiMismatch { return "Bridge API mismatch" }
        if isDryRun { return "Bridge-run dry-run only" }
        if !hasPaperLock { return "Paper homography missing" }
        if !machineAxisModelTrusted { return "Axis geometry not trusted" }
        if !machineHomingTrusted { return "Absolute position not trusted" }
        if isMachineAlarm { return "Machine alarm" }
        if isMachineBusy || isRunning { return "Machine busy" }
        return "Bridge-run drawing armed"
    }

    private static func lifecycleTitle(for rawValue: String?) -> String? {
        guard let rawValue = cleanBridgeMetadata(rawValue) else { return nil }
        let normalized = rawValue
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "preview", "preview_bridge", "mock", "mock_preview", "dry_run_preview":
            return "Preview Bridge"
        case "standby", "hardware_standby", "hardware_standby_bridge", "serial_standby", "dry_run", "dry_run_serial":
            return "Hardware Standby"
        case "live", "live_bridge", "hardware_live", "live_hardware":
            return "Live Bridge"
        case "offline", "off":
            return "Offline"
        default:
            return rawValue
        }
    }

    func recordOperatorEvent(_ name: String, details: [String: Any] = [:]) {
        diagnosticsEvent("operator.\(name)", details, snapshot: true)
    }

    private func diagnosticsEvent(
        _ name: String,
        _ details: [String: Any] = [:],
        snapshot: Bool = false
    ) {
        var payload = diagnosticsContext()
        for (key, value) in details {
            payload[key] = value
        }
        diagnostics.recordEvent(name, payload: payload)
        if snapshot {
            writeDiagnosticsState(reason: name)
        }
    }

    private func writeDiagnosticsState(reason: String) {
        diagnostics.writeState(diagnosticsState(reason: reason))
    }

    private func diagnosticsContext() -> [String: Any] {
        [
            "reason": activeAction.isEmpty ? "idle" : activeAction,
            "short_status": shortStatus,
            "status_text": statusText,
            "bridge_online": isOnline,
            "dry_run": isDryRun,
            "controller_kind": sanitizedControllerKind,
            "machine_state": machineState,
            "machine_busy": isMachineBusy || isRunning,
            "machine_alarm": isMachineAlarm,
            "motion_mode": motionModeLabel,
            "arm": armStatusLabel,
            "motion_gate": motionGateMessage,
            "draw_preflight": drawPreflightMessage
        ]
    }

    private func diagnosticsState(reason: String) -> [String: Any] {
        [
            "reason": reason,
            "app": [
                "build_id": appBuildId ?? "",
                "required_bridge_api_version": requiredBridgeApiVersion
            ],
            "bridge": [
                "online": isOnline,
                "status_text": statusText,
                "short_status": shortStatus,
                "dry_run": isDryRun,
                "controller_kind": sanitizedControllerKind,
                "api_version": bridgeApiVersion ?? "",
                "lifecycle_mode": lifecycleMode ?? "",
                "lifecycle_label": lifecycleLabel ?? "",
                "lifecycle_title": bridgeLifecycleTitle,
                "lifecycle_lamp": bridgeLifecycleLampValue,
                "build_id": bridgeBuildId ?? "",
                "pid": bridgePid ?? 0,
                "can_restart_safely": canRestartSafely ?? false,
                "api_mismatch": hasBridgeApiMismatch,
                "build_mismatch": hasLifecycleBuildMismatch
            ],
            "machine": [
                "state": machineState,
                "pins": machinePins,
                "mpos": machineMPos,
                "wpos": machineWPos,
                "feed_spindle": machineFeedSpindle,
                "status": machineStatus,
                "busy": isMachineBusy || isRunning,
                "alarm": isMachineAlarm,
                "active_action": activeAction,
                "homing_trusted": machineHomingTrusted,
                "axis_model_trusted": machineAxisModelTrusted
            ],
            "paper": [
                "status": paperTransformStatus,
                "locked": hasPaperLock,
                "registration_id": paperRegistrationSnapshot?.registrationId ?? "",
                "workspace_x_mm": workspaceXMm,
                "workspace_y_mm": workspaceYMm
            ],
            "previews": [
                "shape": previewStatus,
                "image": imagePreviewStatus,
                "image_detail": imagePreviewDetail,
                "image_contours": imagePreviewContourCount,
                "image_bridge_preview_eligible": imagePreviewEligibleForBridgePreview,
                "expected_path_segments": expectedPathSegments.count,
                "dot": dotTestPreviewStatus,
                "dot_pattern": dotTestPreviewPattern,
                "dot_points": dotTestPreviewPoints.count,
                "dot_segments": dotTestPreviewSegments.count,
                "adaptive_probe": adaptiveProbeStatus,
                "visual_center_dot": visualCenterDotStatus,
                "path_animation": pathAnimationStatus,
                "path_reveal_progress": pathRevealProgress
            ],
            "gates": [
                "connection_title": plotterConnectionTitle,
                "connection_subtitle": plotterConnectionSubtitle,
                "connection_help": plotterConnectionHelp,
                "motion_mode": motionModeLabel,
                "arm": armStatusLabel,
                "motion_gate": motionGateMessage,
                "draw_preflight": drawPreflightMessage,
                "can_connect_hardware": canConnectHardware,
                "can_arm_hardware": canArmHardware,
                "can_disarm_hardware": canDisarmHardware,
                "can_run_absolute_drawing": canRunAbsoluteDrawing,
                "can_run_center_dot_motion": canRunCenterDotMotion,
                "can_run_visual_relative_motion": canRunVisualRelativeMotion
            ]
        ]
    }

    private var sanitizedControllerKind: String {
        if bridgeController == "mock" { return "mock" }
        if bridgeController == "offline" { return "offline" }
        if bridgeController.hasPrefix("serial:") { return "serial" }
        if bridgeController.isEmpty { return "unknown" }
        return bridgeController
    }

    private func recordHealthIfChanged() {
        let summary = [
            bridgeLifecycleTitle,
            bridgeLifecycleLampValue,
            sanitizedControllerKind,
            isDryRun ? "dry" : "live",
            armStatusLabel,
            bridgeApiVersion ?? "",
            bridgeBuildId ?? ""
        ].joined(separator: "|")
        guard summary != lastDiagnosticsHealthSummary else { return }
        lastDiagnosticsHealthSummary = summary
        diagnosticsEvent(
            "bridge_health_changed",
            [
                "lifecycle_title": bridgeLifecycleTitle,
                "lifecycle_lamp": bridgeLifecycleLampValue,
                "controller_kind": sanitizedControllerKind,
                "api_version": bridgeApiVersion ?? "",
                "bridge_build_id": bridgeBuildId ?? "",
                "arm": armStatusLabel
            ],
            snapshot: true
        )
    }

    private func recordMachineIfChanged() {
        let summary = [
            sanitizedControllerKind,
            isDryRun ? "dry" : "live",
            machineState,
            machinePins,
            machineMPos,
            machineWPos,
            isMachineBusy ? "busy" : "idle",
            isMachineAlarm ? "alarm" : "ok",
            machineHomingTrusted ? "home_trusted" : "home_untrusted",
            machineAxisModelTrusted ? "axis_trusted" : "axis_untrusted",
            activeAction
        ].joined(separator: "|")
        guard summary != lastDiagnosticsMachineSummary else { return }
        lastDiagnosticsMachineSummary = summary
        diagnosticsEvent(
            "machine_status_changed",
            [
                "state": machineState,
                "pins": machinePins,
                "mpos": machineMPos,
                "wpos": machineWPos,
                "busy": isMachineBusy,
                "alarm": isMachineAlarm,
                "active_action": activeAction,
                "homing_trusted": machineHomingTrusted,
                "axis_model_trusted": machineAxisModelTrusted
            ],
            snapshot: true
        )
    }

    private func recordPaperIfChanged() {
        let summary = [
            paperTransformStatus,
            paperRegistrationSnapshot?.registrationId ?? "",
            hasPaperLock ? "locked" : "unlocked"
        ].joined(separator: "|")
        guard summary != lastDiagnosticsPaperSummary else { return }
        lastDiagnosticsPaperSummary = summary
        diagnosticsEvent(
            "paper_status_changed",
            [
                "paper_status": paperTransformStatus,
                "paper_locked": hasPaperLock,
                "registration_id": paperRegistrationSnapshot?.registrationId ?? ""
            ],
            snapshot: true
        )
    }

    private func commandPayload(_ response: MachineCommandResponse) -> [String: Any] {
        [
            "command_id": response.commandId,
            "action": response.action,
            "status": response.status,
            "dry_run": response.dryRun,
            "planned_command_count": response.plannedCommands.count,
            "has_machine_status": response.machineStatus != nil,
            "error": response.error ?? ""
        ]
    }

    private func errorPayload(_ error: Error) -> [String: Any] {
        ["error": error.localizedDescription]
    }

    func refreshHealth() async {
        do {
            let health = try await client.health()
            isOnline = true
            isDryRun = health.dryRun
            bridgeController = health.controller
            armMotion = health.armMotion
            armPen = health.armPen
            armHoming = health.armHoming
            armUnlock = health.armUnlock
            workspaceXMm = health.workspaceXMm ?? workspaceXMm
            workspaceYMm = health.workspaceYMm ?? workspaceYMm
            bridgeApiVersion = health.bridgeApiVersion
            lifecycleMode = health.lifecycleMode
            lifecycleLabel = health.lifecycleLabel
            bridgeBuildId = health.bridgeBuildId
            bridgeSourceRoot = health.bridgeSourceRoot
            bridgePid = health.bridgePid
            bridgeStartedAt = health.bridgeStartedAt
            canRestartSafely = health.canRestartSafely
            shortStatus = motionModeLabel
            statusText = "\(bridgeLifecycleTitle) \(health.status)"
            recordHealthIfChanged()
            await refreshPaperStatus()
        } catch {
            isOnline = false
            shortStatus = "OFF"
            statusText = "Bridge offline"
            paperTransformStatus = "PAPER --"
            paperRegistrationSnapshot = nil
            machineHomingTrusted = false
            machineAxisModelTrusted = false
            bridgeController = "offline"
            armMotion = false
            armPen = false
            armHoming = false
            armUnlock = false
            clearBridgeLifecycleMetadata()
            diagnosticsEvent("bridge_health_failed", errorPayload(error), snapshot: true)
        }
    }

    func refreshPaperStatus() async {
        guard isOnline, !isCalibrating else { return }
        do {
            let response = try await client.paperStatus()
            applyPaperRegistrationStatus(response)
            recordPaperIfChanged()
        } catch {
            paperTransformStatus = "PAPER ?"
            diagnosticsEvent("paper_status_failed", errorPayload(error), snapshot: true)
        }
    }

    func refreshMachineStatus() async {
        guard !isRefreshingMachineStatus else { return }
        isRefreshingMachineStatus = true
        defer { isRefreshingMachineStatus = false }

        do {
            let response = try await client.machineStatus()
            applyMachineStatus(response)
            isOnline = response.status != "offline" && response.status != "failed"
            isDryRun = response.dryRun
            if !isRunning {
                shortStatus = response.isAlarm ? "ALM" : motionModeLabel
            }
            recordMachineIfChanged()
        } catch {
            isOnline = false
            shortStatus = "OFF"
            bridgeController = "offline"
            machineState = "OFF"
            machinePins = "-"
            machineMPos = "M --"
            machineWPos = "W --"
            machineFeedSpindle = "FS --"
            machineStatus = error.localizedDescription
            machineHomingTrusted = false
            machineAxisModelTrusted = false
            paperRegistrationSnapshot = nil
            isMachineBusy = false
            isMachineAlarm = true
            armMotion = false
            armPen = false
            armHoming = false
            armUnlock = false
            diagnosticsEvent("machine_status_failed", errorPayload(error), snapshot: true)
        }
    }

    private func clearBridgeLifecycleMetadata() {
        bridgeApiVersion = nil
        lifecycleMode = nil
        lifecycleLabel = nil
        bridgeBuildId = nil
        bridgeSourceRoot = nil
        bridgePid = nil
        bridgeStartedAt = nil
        canRestartSafely = nil
    }

    func reconnectMachine() async {
        guard !isRunning && !isMachineBusy else { return }
        isRunning = true
        isMachineBusy = true
        activeAction = "reconnect"
        shortStatus = "CONN"
        statusText = "Reconnecting controller"
        diagnosticsEvent("machine_reconnect_started", snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.reconnect(MachineReconnectRequest())
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? (hasControllerPort ? "DRY" : "STBY") : (isMachineAlarm ? "ALM" : "LIVE")
            statusText = "\(response.action) \(response.status)"
            diagnosticsEvent("machine_reconnect_completed", commandPayload(response), snapshot: true)
        } catch {
            isOnline = false
            shortStatus = "OFF"
            bridgeController = "offline"
            machineState = "OFF"
            machinePins = "-"
            machineMPos = "M --"
            machineWPos = "W --"
            machineFeedSpindle = "FS --"
            machineStatus = error.localizedDescription
            machineHomingTrusted = false
            machineAxisModelTrusted = false
            paperRegistrationSnapshot = nil
            statusText = "Reconnect failed"
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("machine_reconnect_failed", errorPayload(error), snapshot: true)
        }
    }

    func armHardware() async {
        await setHardwareArmed(true)
    }

    func connectPlotter() async {
        guard !isLiveMotionMode else {
            statusText = "Plotter already connected"
            diagnosticsEvent("plotter_connect_skipped", ["reason": "already_live"], snapshot: true)
            return
        }
        await armHardware()
    }

    func disarmHardware() async {
        await setHardwareArmed(false)
    }

    private func setHardwareArmed(_ live: Bool) async {
        guard !isRunning && !isMachineBusy else { return }
        guard isOnline else {
            statusText = "Bridge offline"
            machineStatus = "Bridge offline"
            return
        }
        guard !isMockBridge else {
            statusText = "Mock bridge cannot arm hardware"
            machineStatus = "Start hardware standby bridge to connect a controller"
            return
        }

        isRunning = true
        isMachineBusy = true
        activeAction = live ? "arm" : "disarm"
        shortStatus = live ? "ARM" : "SAFE"
        statusText = live ? "Arming hardware" : "Disarming hardware"
        diagnosticsEvent(live ? "hardware_arm_started" : "hardware_disarm_started", snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.arm(
                MachineArmRequest(
                    live: live,
                    autoConnect: true,
                    armMotion: true,
                    armPen: true,
                    armHoming: true,
                    armUnlock: true
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? (hasControllerPort ? "DRY" : "STBY") : (isMachineAlarm ? "ALM" : "LIVE")
            statusText = live ? "Hardware armed" : "Hardware disarmed"
            diagnosticsEvent(
                live ? "hardware_arm_completed" : "hardware_disarm_completed",
                commandPayload(response),
                snapshot: true
            )
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            if live {
                isMachineAlarm = true
            }
            diagnosticsEvent(
                live ? "hardware_arm_failed" : "hardware_disarm_failed",
                errorPayload(error),
                snapshot: true
            )
        }
    }

    func previewShapeOverlay(pattern: String) async -> Bool {
        guard !isRunning && !isMachineBusy else { return false }
        guard isOnline else {
            previewStatus = "SIM OFF"
            statusText = "Bridge offline"
            diagnosticsEvent("shape_preview_blocked", ["pattern": pattern, "reason": "bridge_offline"], snapshot: true)
            return false
        }

        isCalibrating = true
        activeAction = "shape-preview"
        previewStatus = "SIM PREVIEW"
        statusText = "Previewing \(pattern) overlay"
        diagnosticsEvent("shape_preview_started", ["pattern": pattern], snapshot: true)
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewShape(
                BridgeShapeExecutionRequest(
                    pattern: pattern,
                    includeHoming: false,
                    includeCentering: true,
                    sideMm: shapeSideMm,
                    centerXMm: shapeCenterXNorm * workspaceXMm,
                    centerYMm: shapeCenterYNorm * workspaceYMm,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0
                )
            )
            expectedPathSegments = response.simulation?.previewSegments ?? []
            previewStatus = "SIM \(pattern.uppercased()) \(response.evaluation?.status.uppercased() ?? response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? 0.0
            animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: shapeDrawFeedMmMin)
            statusText = "\(response.commandId) \(Int(shapeSideMm))mm \(pattern) preview"
            diagnosticsEvent(
                "shape_preview_completed",
                [
                    "pattern": pattern,
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "evaluation": response.evaluation?.status ?? "",
                    "preview_segments": expectedPathSegments.count,
                    "drawn_length_mm": drawnLength
                ],
                snapshot: true
            )
            return response.status == "ready" || response.status == "completed"
        } catch {
            expectedPathSegments = []
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("shape_preview_failed", ["pattern": pattern, "error": error.localizedDescription], snapshot: true)
            return false
        }
    }

    func drawTriangle(centerXMm: Double? = nil, centerYMm: Double? = nil) async -> Bool {
        guard !isRunning && !isMachineBusy && !isMachineAlarm else { return false }
        isRunning = true
        isMachineBusy = true
        activeAction = "draw"
        shortStatus = "RUN"
        statusText = "Planning triangle"
        diagnosticsEvent("shape_draw_started", ["pattern": "triangle"], snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.drawShape(
                BridgeShapeExecutionRequest(
                    pattern: "triangle",
                    includeHoming: false,
                    includeCentering: true,
                    sideMm: shapeSideMm,
                    centerXMm: centerXMm ?? shapeCenterXNorm * workspaceXMm,
                    centerYMm: centerYMm ?? shapeCenterYNorm * workspaceYMm,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0
                )
            )
            shortStatus = response.dryRun ? "DRY" : "DONE"
            expectedPathSegments = response.simulation?.previewSegments ?? []
            previewStatus = "SIM \(response.evaluation?.status.uppercased() ?? response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? 0.0
            animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: shapeDrawFeedMmMin)
            statusText = "\(response.commandId) \(Int(shapeSideMm))mm triangle \(previewStatus)"
            isOnline = true
            await refreshMachineStatus()
            diagnosticsEvent(
                "shape_draw_completed",
                [
                    "pattern": "triangle",
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "evaluation": response.evaluation?.status ?? "",
                    "preview_segments": expectedPathSegments.count,
                    "drawn_length_mm": drawnLength
                ],
                snapshot: true
            )
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("shape_draw_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func drawFaceRaster(
        _ raster: FaceRasterSample,
        frame: BridgeDrawingFrameRequest
    ) async -> Bool {
        guard !isRunning && !isMachineBusy && !isMachineAlarm else { return false }
        isRunning = true
        isMachineBusy = true
        activeAction = "face"
        shortStatus = "RUN"
        statusText = "Planning face raster"
        diagnosticsEvent(
            "face_raster_draw_started",
            [
                "raster_rows": raster.samples.count,
                "raster_columns": raster.samples.first?.count ?? 0,
                "frame_width_mm": frame.widthMm,
                "frame_height_mm": frame.heightMm
            ],
            snapshot: true
        )
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.drawFaceRaster(
                BridgeFaceRasterDrawRequest(
                    raster: BridgeLuminanceRasterRequest(samples: raster.samples),
                    frame: frame,
                    options: BridgeRasterPolygonOptionsRequest(
                        darknessThreshold: 0.16,
                        gamma: 1.05,
                        autoContrast: true,
                        triangulate: true,
                        outline: false,
                        hatchAngleDeg: 35.0,
                        minHatchSpacingMm: 1.8,
                        maxHatchSpacingMm: 8.5,
                        maxHatchSegments: 1600,
                        maxPolygons: 900
                    ),
                    includeHoming: false,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0,
                    maxSegmentMm: 25.0
                )
            )
            shortStatus = response.dryRun ? "DRY" : "DONE"
            expectedPathSegments = response.simulation?.previewSegments ?? []
            previewStatus = "SIM \(response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? response.summary?.drawnLengthMm ?? 0.0
            animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: shapeDrawFeedMmMin)
            let polygons = response.rasterSummary?.polygonCount ?? 0
            let segments = response.summary?.drawSegmentCount ?? 0
            statusText = "\(response.commandId) face \(polygons)p \(segments)s"
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            diagnosticsEvent(
                "face_raster_draw_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "polygons": polygons,
                    "segments": segments,
                    "preview_segments": expectedPathSegments.count,
                    "drawn_length_mm": drawnLength
                ],
                snapshot: true
            )
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("face_raster_draw_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func previewImageContours(
        _ raster: FaceRasterSample,
        frame: BridgeDrawingFrameRequest
    ) async -> Bool {
        guard !isRunning && !isMachineBusy else { return false }
        guard isOnline else {
            imagePreviewStatus = "IMG OFF"
            imagePreviewDetail = "BRIDGE OFFLINE"
            statusText = "Bridge offline"
            diagnosticsEvent("image_preview_blocked", ["reason": "bridge_offline"], snapshot: true)
            return false
        }

        isCalibrating = true
        activeAction = "image-preview"
        imagePreviewStatus = "IMG PREVIEW"
        imagePreviewDetail = "BRIDGE PREVIEW"
        statusText = "Previewing image contours"
        diagnosticsEvent(
            "image_preview_started",
            [
                "raster_rows": raster.samples.count,
                "raster_columns": raster.samples.first?.count ?? 0,
                "frame_width_mm": frame.widthMm,
                "frame_height_mm": frame.heightMm
            ],
            snapshot: true
        )
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewImageShape(
                BridgeImageShapePreviewRequest(
                    raster: BridgeLuminanceRasterRequest(samples: raster.samples),
                    frame: frame,
                    options: BridgeRasterContourOptionsRequest(
                        darknessThreshold: 0.38,
                        autoContrast: true,
                        maxContours: 900
                    ),
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0,
                    maxSegmentMm: 25.0
                )
            )
            expectedPathSegments = response.simulation?.previewSegments ?? []
            let contours = response.rasterSummary?.contourCount ?? 0
            let segments = response.summary?.drawSegmentCount ?? 0
            imagePreviewContourCount = contours
            imagePreviewEligibleForBridgePreview = response.eligibleForBridgePreview
            imagePreviewStatus = String(format: "IMG %dC %dS", contours, segments)
            imagePreviewDetail = response.previewOnly ? "PREVIEW ONLY" : "EXECUTION"
            previewStatus = "SIM IMAGE \(response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? response.summary?.drawnLengthMm ?? 0.0
            animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: shapeDrawFeedMmMin)
            statusText = "\(response.commandId) image contour preview"
            diagnosticsEvent(
                "image_preview_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "preview_only": response.previewOnly,
                    "eligible_for_bridge_preview": response.eligibleForBridgePreview,
                    "contours": contours,
                    "segments": segments,
                    "preview_segments": expectedPathSegments.count,
                    "drawn_length_mm": drawnLength
                ],
                snapshot: true
            )
            return response.status == "ready"
        } catch {
            expectedPathSegments = []
            imagePreviewContourCount = 0
            imagePreviewEligibleForBridgePreview = false
            imagePreviewStatus = "IMG ERR"
            imagePreviewDetail = "VISUAL ONLY"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("image_preview_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func replayExpectedPath() {
        let length = expectedPathSegments.reduce(0.0) { partial, segment in
            partial + segment.lengthMm
        }
        animateExpectedPath(drawnLengthMm: length, feedMmMin: shapeDrawFeedMmMin)
        diagnosticsEvent("expected_path_replayed", ["length_mm": length, "segments": expectedPathSegments.count], snapshot: true)
    }

    func jog(axis: String, distanceMm: Double) async {
        await runMachineCommand(action: "jog") {
            try await client.jog(
                MachineJogRequest(
                    axis: axis,
                    distanceMm: distanceMm,
                    feedMmMin: manualFeedMmMin
                )
            )
        }
    }

    func learningJog(axis: String, distanceMm: Double, feedMmMin: Double) async -> MachineCommandResponse? {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent(
                "learning_jog_blocked",
                ["axis": axis, "distance_mm": distanceMm, "reason": motionGateMessage],
                snapshot: true
            )
            return nil
        }

        guard await waitUntilMachineReadyForLearning(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for learning move"
            return nil
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks learning move"
            return nil
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "learn"
        shortStatus = "RUN"
        statusText = String(format: "Learn %@ %.1fmm", axis, distanceMm)
        diagnosticsEvent(
            "learning_jog_started",
            ["axis": axis, "distance_mm": distanceMm, "feed_mm_min": feedMmMin],
            snapshot: true
        )
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.jog(
                MachineJogRequest(
                    axis: axis,
                    distanceMm: distanceMm,
                    feedMmMin: feedMmMin
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            statusText = "\(response.action) \(response.status)"
            await refreshMachineStatus()
            diagnosticsEvent(
                "learning_jog_completed",
                commandPayload(response).merging(["axis": axis, "distance_mm": distanceMm]) { current, _ in current },
                snapshot: true
            )
            return response
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent(
                "learning_jog_failed",
                errorPayload(error).merging(["axis": axis, "distance_mm": distanceMm]) { current, _ in current },
                snapshot: true
            )
            return nil
        }
    }

    func observeVisualCapForProbe(
        cameraPoint: CGPoint,
        paperMm: PaperPointMmSnapshot,
        confidence: Double,
        safeZoneInsetXMm: Double,
        safeZoneInsetYMm: Double
    ) async -> Bool {
        let paperNorm = NormPoint(
            CGPoint(
                x: min(1.0, max(0.0, paperMm.x / max(workspaceXMm, 0.000_001))),
                y: min(1.0, max(0.0, paperMm.y / max(workspaceYMm, 0.000_001)))
            )
        )
        do {
            let response = try await client.observeVisualCap(
                BridgeVisualCapObservationRequest(
                    observedNorm: NormPoint(cameraPoint),
                    observedPaperNorm: paperNorm,
                    observedLogicalMm: paperMm,
                    source: "camera_detection",
                    confidence: confidence,
                    cameraId: "plotter-camera",
                    cameraName: "Plotter Camera",
                    safeZoneInsetXMm: safeZoneInsetXMm,
                    safeZoneInsetYMm: safeZoneInsetYMm
                )
            )
            isOnline = true
            adaptiveProbeStatus = response.status == "ready" ? "PROBE CAP SAFE" : "PROBE CAP OBS"
            statusText = response.readiness?.blockers.joined(separator: ", ") ?? adaptiveProbeStatus
            diagnosticsEvent(
                "visual_cap_observed",
                [
                    "status": response.status,
                    "confidence": confidence,
                    "paper_x_mm": paperMm.x,
                    "paper_y_mm": paperMm.y,
                    "blockers": response.readiness?.blockers ?? []
                ],
                snapshot: true
            )
            return response.status != "failed"
        } catch {
            shortStatus = "ERR"
            adaptiveProbeStatus = "PROBE OBS ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("visual_cap_observe_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func previewBootstrapAdaptiveProbe(
        requestId: String,
        safeZoneInsetXMm: Double,
        safeZoneInsetYMm: Double,
        maxXProbeMm: Double,
        maxYProbeMm: Double,
        minProbeMm: Double,
        bootstrapTargetXMm: Double,
        bootstrapBottomAllowanceMm: Double,
        bootstrapTopAllowanceMm: Double,
        feedMmMin: Double
    ) async -> BridgeAdaptiveProbeResponse? {
        do {
            let response = try await client.previewAdaptiveProbe(
                BridgeAdaptiveProbePreviewRequest(
                    requestId: requestId,
                    safeZoneInsetXMm: safeZoneInsetXMm,
                    safeZoneInsetYMm: safeZoneInsetYMm,
                    maxXProbeMm: maxXProbeMm,
                    maxYProbeMm: maxYProbeMm,
                    minProbeMm: minProbeMm,
                    clearanceMm: 2.0,
                    bootstrapOnly: true,
                    bootstrapTargetXMm: bootstrapTargetXMm,
                    bootstrapBottomAllowanceMm: bootstrapBottomAllowanceMm,
                    bootstrapTopAllowanceMm: bootstrapTopAllowanceMm,
                    feedMmMin: feedMmMin
                )
            )
            isOnline = true
            latestAdaptiveProbePlan = response.plan
            adaptiveProbeStatus = response.status == "ready" ? "PROBE BOOT PREVIEW" : "PROBE BOOT BLOCK"
            statusText = response.error ?? adaptiveProbeStatus
            diagnosticsEvent(
                "adaptive_probe_preview_completed",
                [
                    "request_id": requestId,
                    "status": response.status,
                    "plan_id": response.plan?.planId ?? "",
                    "move_count": response.plan?.moves.count ?? 0,
                    "blockers": response.plan?.blockers ?? []
                ],
                snapshot: true
            )
            return response
        } catch {
            shortStatus = "ERR"
            adaptiveProbeStatus = "PROBE PREVIEW ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("adaptive_probe_preview_failed", ["request_id": requestId, "error": error.localizedDescription], snapshot: true)
            return nil
        }
    }

    func runBootstrapAdaptiveProbe(
        requestId: String,
        expectedPlanId: String,
        safeZoneInsetXMm: Double,
        safeZoneInsetYMm: Double,
        maxXProbeMm: Double,
        maxYProbeMm: Double,
        minProbeMm: Double,
        bootstrapTargetXMm: Double,
        bootstrapBottomAllowanceMm: Double,
        bootstrapTopAllowanceMm: Double,
        feedMmMin: Double
    ) async -> BridgeAdaptiveProbeResponse? {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            adaptiveProbeStatus = "PROBE LIVE BLOCK"
            statusText = motionGateMessage
            diagnosticsEvent("adaptive_probe_run_blocked", ["request_id": requestId, "reason": motionGateMessage], snapshot: true)
            return nil
        }
        guard await waitUntilMachineReadyForLearning(timeoutSeconds: 18.0) else {
            adaptiveProbeStatus = "PROBE BUSY"
            statusText = "Machine did not become ready for bootstrap probe"
            return nil
        }
        guard !isMachineAlarm else {
            adaptiveProbeStatus = "PROBE ALARM"
            statusText = "Machine alarm blocks bootstrap probe"
            return nil
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "probe-bootstrap"
        shortStatus = "RUN"
        adaptiveProbeStatus = "PROBE BOOT RUN"
        diagnosticsEvent("adaptive_probe_run_started", ["request_id": requestId, "expected_plan_id": expectedPlanId], snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.runAdaptiveProbe(
                BridgeAdaptiveProbeRunRequest(
                    requestId: requestId,
                    safeZoneInsetXMm: safeZoneInsetXMm,
                    safeZoneInsetYMm: safeZoneInsetYMm,
                    maxXProbeMm: maxXProbeMm,
                    maxYProbeMm: maxYProbeMm,
                    minProbeMm: minProbeMm,
                    clearanceMm: 2.0,
                    bootstrapOnly: true,
                    bootstrapTargetXMm: bootstrapTargetXMm,
                    bootstrapBottomAllowanceMm: bootstrapBottomAllowanceMm,
                    bootstrapTopAllowanceMm: bootstrapTopAllowanceMm,
                    feedMmMin: feedMmMin,
                    expectedPlanId: expectedPlanId
                )
            )
            isOnline = true
            latestAdaptiveProbePlan = response.plan
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            adaptiveProbeStatus = response.status == "completed" ? "PROBE BOOT DONE" : "PROBE BOOT FAIL"
            shortStatus = response.dryRun ? "DRY" : (response.status == "completed" ? "DONE" : "ERR")
            statusText = response.error ?? adaptiveProbeStatus
            diagnosticsEvent(
                "adaptive_probe_run_completed",
                [
                    "request_id": requestId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "command_id": response.commandId,
                    "plan_id": response.plan?.planId ?? "",
                    "move_count": response.plan?.moves.count ?? 0
                ],
                snapshot: true
            )
            return response
        } catch {
            shortStatus = "ERR"
            adaptiveProbeStatus = "PROBE RUN ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("adaptive_probe_run_failed", ["request_id": requestId, "error": error.localizedDescription], snapshot: true)
            return nil
        }
    }

    func observeVisualProbeSample(_ request: BridgeVisualProbeSampleRequest) async -> Bool {
        do {
            let response = try await client.observeVisualProbeSample(request)
            isOnline = true
            adaptiveProbeStatus = response.status == "accepted" ? "PROBE EVID OK" : "PROBE EVID \(response.status.uppercased())"
            if let error = response.error {
                statusText = error
            } else if let blockers = response.readiness?.blockers, !blockers.isEmpty {
                statusText = blockers.joined(separator: ", ")
            } else {
                statusText = adaptiveProbeStatus
            }
            diagnosticsEvent(
                "visual_probe_sample_observed",
                [
                    "run_id": request.runId,
                    "sample_id": request.sampleId,
                    "source": request.source,
                    "axis": request.axis ?? "",
                    "status": response.status,
                    "readiness_status": response.readiness?.visualReadyToPlot == true ? "ready" : "blocked"
                ],
                snapshot: true
            )
            return response.status != "failed"
        } catch {
            shortStatus = "ERR"
            adaptiveProbeStatus = "PROBE EVID ERR"
            statusText = error.localizedDescription
            diagnosticsEvent(
                "visual_probe_sample_failed",
                [
                    "run_id": request.runId,
                    "sample_id": request.sampleId,
                    "source": request.source,
                    "error": error.localizedDescription
                ],
                snapshot: true
            )
            return false
        }
    }

    func visualRelativeMove(xMm: Double, yMm: Double, feedMmMin: Double) async -> MachineCommandResponse? {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("visual_relative_move_blocked", ["x_mm": xMm, "y_mm": yMm, "reason": motionGateMessage], snapshot: true)
            return nil
        }

        guard await waitUntilMachineReadyForLearning(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for visual move"
            return nil
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks visual move"
            return nil
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "visual-rel"
        shortStatus = "RUN"
        visualCenterDotStatus = String(format: "VIS MOVE X%.1f Y%.1f", xMm, yMm)
        statusText = String(format: "Visual relative move X%.2f Y%.2f", xMm, yMm)
        diagnosticsEvent("visual_relative_move_started", ["x_mm": xMm, "y_mm": yMm, "feed_mm_min": feedMmMin], snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.relativeMove(
                MachineRelativeMoveRequest(
                    xMm: xMm,
                    yMm: yMm,
                    feedMmMin: feedMmMin,
                    ensurePenUp: true
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            statusText = "\(response.action) \(response.status)"
            await refreshMachineStatus()
            diagnosticsEvent("visual_relative_move_completed", commandPayload(response), snapshot: true)
            return response
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("visual_relative_move_failed", errorPayload(error), snapshot: true)
            return nil
        }
    }

    func dotMarkCurrentPosition() async -> Bool {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("dot_mark_blocked", ["reason": motionGateMessage], snapshot: true)
            return false
        }

        guard await waitUntilMachineReadyForLearning(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for dot mark"
            return false
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks dot mark"
            return false
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "dot-mark"
        shortStatus = "RUN"
        visualCenterDotStatus = "VIS MARK"
        statusText = "Marking current visual dot position"
        diagnosticsEvent("dot_mark_started", snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.dotMark(MachineDotMarkRequest())
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            visualCenterDotStatus = response.status == "completed" ? "VIS MARKED" : "VIS MARK FAIL"
            statusText = "\(response.action) \(response.status)"
            await refreshMachineStatus()
            diagnosticsEvent("dot_mark_completed", commandPayload(response), snapshot: true)
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("dot_mark_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func relativeMarkCurrentPosition(markSizeMm: Double, drawFeedMmMin: Double) async -> Bool {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("relative_mark_blocked", ["reason": motionGateMessage], snapshot: true)
            return false
        }

        guard await waitUntilMachineReadyForLearning(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for visual mark"
            return false
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks visual mark"
            return false
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "relative-mark"
        shortStatus = "RUN"
        visualCenterDotStatus = String(format: "VIS MARK %.1f", markSizeMm)
        statusText = String(format: "Drawing relative visual mark %.1fmm", markSizeMm)
        diagnosticsEvent(
            "relative_mark_started",
            ["mark_size_mm": markSizeMm, "draw_feed_mm_min": drawFeedMmMin],
            snapshot: true
        )
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.relativeMark(
                MachineRelativeMarkRequest(
                    markSizeMm: markSizeMm,
                    drawFeedMmMin: drawFeedMmMin,
                    travelFeedMmMin: min(300.0, manualFeedMmMin)
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            visualCenterDotStatus = response.status == "completed" ? "VIS MARKED" : "VIS MARK FAIL"
            statusText = "\(response.action) \(response.status)"
            await refreshMachineStatus()
            diagnosticsEvent("relative_mark_completed", commandPayload(response), snapshot: true)
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("relative_mark_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func waitUntilMachineReadyForLearning(timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !isRunning && !isMachineBusy {
                await refreshMachineStatus()
                if !isMachineBusy {
                    return true
                }
            } else {
                await refreshMachineStatus()
                if !isRunning && !isMachineBusy {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await refreshMachineStatus()
        return !isRunning && !isMachineBusy
    }

    func homeMachine() async {
        await runMachineCommand(action: "home") {
            try await client.home(
                MachineHomeRequest(
                    centerAfter: true,
                    centerFeedMmMin: manualFeedMmMin
                )
            )
        }
    }

    func centerMachine() async {
        await runMachineCommand(action: "center") {
            try await client.center(MachineCenterRequest(feedMmMin: manualFeedMmMin))
        }
    }

    func penUpMachine() async {
        await runMachineCommand(action: "pen up") {
            try await client.penUp(MachinePenRequest())
        }
    }

    func penDownMachine() async {
        await runMachineCommand(action: "pen down") {
            try await client.penDown(MachinePenRequest())
        }
    }

    func stopMachine() async {
        guard isLiveMotionMode else {
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("machine_stop_blocked", ["reason": motionGateMessage], snapshot: true)
            return
        }

        activeAction = "stop"
        shortStatus = "STOP"
        statusText = "Sending stop"
        diagnosticsEvent("machine_stop_started", snapshot: true)

        do {
            let response = try await client.stop(MachineStopRequest())
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "STOP"
            statusText = "\(response.action) \(response.status)"
            diagnosticsEvent("machine_stop_completed", commandPayload(response), snapshot: true)
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineAlarm = true
            diagnosticsEvent("machine_stop_failed", errorPayload(error), snapshot: true)
        }
    }

    func resumeMachine() async {
        guard isLiveMotionMode else {
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("machine_resume_blocked", ["reason": motionGateMessage], snapshot: true)
            return
        }
        guard !isRunning, machineState.hasPrefix("Hold") else { return }
        isRunning = true
        activeAction = "resume"
        shortStatus = "RUN"
        statusText = "Sending resume"
        diagnosticsEvent("machine_resume_started", snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.resume(MachineResumeRequest())
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            statusText = "\(response.action) \(response.status)"
            diagnosticsEvent("machine_resume_completed", commandPayload(response), snapshot: true)
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineAlarm = true
            diagnosticsEvent("machine_resume_failed", errorPayload(error), snapshot: true)
        }
    }

    func clearAlarmMachine() async {
        guard isLiveMotionMode else {
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            return
        }

        await runMachineCommand(action: "unlock") {
            try await client.unlock(MachineUnlockRequest())
        }
    }

    func trustAxisModelFromVisualProbe(
        samples: [FrameLearningSample],
        rmsResidualMm: Double,
        maxResidualMm: Double,
        minObservedDistanceMm: Double,
        commandDistanceMm: Double
    ) async -> Bool {
        guard isOnline else {
            statusText = "Bridge offline"
            return false
        }

        do {
            let response = try await client.trustAxisModel(
                AxisModelTrustRequest(
                    source: "green_cap_visual_probe",
                    sampleCount: samples.count,
                    rmsResidualMm: rmsResidualMm,
                    maxResidualMm: maxResidualMm,
                    minObservedDistanceMm: minObservedDistanceMm,
                    commandDistanceMm: commandDistanceMm,
                    samples: samples.map {
                        AxisModelTrustSampleRequest(
                            axis: $0.axis,
                            commandedDistanceMm: $0.distanceMm,
                            observedDxMm: $0.observedDxMm,
                            observedDyMm: $0.observedDyMm,
                            observedDistanceMm: $0.observedDistanceMm
                        )
                    }
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            statusText = "\(response.action) \(response.status)"
            return response.status == "completed"
        } catch {
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            await refreshMachineStatus()
            return false
        }
    }

    func startMachineModelCalibration() async {
        guard !isCalibrating else { return }
        isCalibrating = true
        isMachineBusy = true
        activeAction = "model"
        modelStatus = "MODEL RUN"
        diagnosticsEvent("machine_model_calibration_started", snapshot: true)
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.startCalibration(
                CalibrationStartRequest(
                    marginMm: 25.0,
                    travelFeedMmMin: 500.0,
                    includeHoming: false,
                    simulateObservations: isDryRun,
                    syntheticNoiseNorm: 0.0
                )
            )
            isOnline = true
            if response.status == "solved" {
                let rms = response.model.rmsErrorNorm ?? 0.0
                modelStatus = String(format: "MODEL %.4f", rms)
            } else {
                modelStatus = "MODEL \(response.observedCount)/5"
            }
            statusText = "\(response.sessionId) \(response.status)"
            await refreshMachineStatus()
            diagnosticsEvent(
                "machine_model_calibration_completed",
                [
                    "session_id": response.sessionId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "observed_count": response.observedCount,
                    "rms_error_norm": response.model.rmsErrorNorm ?? 0.0,
                    "max_error_norm": response.model.maxErrorNorm ?? 0.0
                ],
                snapshot: true
            )
        } catch {
            modelStatus = "MODEL ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("machine_model_calibration_failed", errorPayload(error), snapshot: true)
        }
    }

    func registerPaperHomography(
        fiducials: [ManualFiducialPoint],
        paperWidthMm: Double,
        paperHeightMm: Double
    ) async -> PaperRegistrationResponse? {
        guard !isCalibrating else { return nil }
        guard isOnline else {
            paperTransformStatus = "PAPER OFF"
            statusText = "Bridge offline"
            return nil
        }
        guard fiducials.count >= 4 else {
            paperTransformStatus = "PAPER NEED 4"
            statusText = "Need four manual fiducials"
            return nil
        }

        let ordered = Array(fiducials.prefix(4))
        let cornerNames = ["bottom_left", "bottom_right", "top_right", "top_left"]
        isCalibrating = true
        activeAction = "paper"
        paperTransformStatus = "PAPER SOLVE"
        statusText = "Solving paper homography"
        diagnosticsEvent(
            "paper_registration_started",
            [
                "fiducial_count": fiducials.count,
                "paper_width_mm": paperWidthMm,
                "paper_height_mm": paperHeightMm
            ],
            snapshot: true
        )
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.registerPaper(
                PaperRegistrationRequest(
                    paperWidthMm: paperWidthMm,
                    paperHeightMm: paperHeightMm,
                    corners: zip(cornerNames, ordered).map { cornerName, fiducial in
                        PaperRegistrationCornerRequest(
                            corner: cornerName,
                            observedNorm: NormPoint(fiducial.cameraPoint),
                            strength: 1.0
                        )
                    }
                )
            )
            isOnline = true
            if let registration = response.registration {
                statusText = "Paper \(registration.registrationId) locked"
            } else {
                statusText = response.error ?? response.status
            }
            applyPaperRegistrationStatus(response)
            diagnosticsEvent(
                "paper_registration_completed",
                [
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "registration_id": response.registration?.registrationId ?? "",
                    "rms_error_norm": response.registration?.rmsErrorNorm ?? 0.0,
                    "max_error_norm": response.registration?.maxErrorNorm ?? 0.0
                ],
                snapshot: true
            )
            return response
        } catch {
            paperTransformStatus = "PAPER ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("paper_registration_failed", errorPayload(error), snapshot: true)
            return nil
        }
    }

    func previewDotTestOverlay(pattern: String = "center") async -> DotTestPreviewResponse? {
        guard !isCalibrating else { return nil }
        guard isOnline else {
            dotTestPreviewStatus = "DOT OFF"
            statusText = "Bridge offline"
            diagnosticsEvent("dot_preview_blocked", ["pattern": pattern, "reason": "bridge_offline"], snapshot: true)
            return nil
        }
        if !hasPaperLock {
            await refreshPaperStatus()
            if !hasPaperLock {
                dotTestPreviewStatus = "DOT NEED PAPER"
                statusText = "Paper homography required"
                diagnosticsEvent("dot_preview_blocked", ["pattern": pattern, "reason": "paper_homography_required"], snapshot: true)
                return nil
            }
        }

        isCalibrating = true
        activeAction = "dot-preview"
        dotTestPreviewStatus = "DOT PREVIEW"
        statusText = "Previewing dot-test overlay"
        diagnosticsEvent("dot_preview_started", ["pattern": pattern], snapshot: true)
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewDotTest(
                DotTestPreviewRequest(
                    pattern: pattern,
                    marginMm: pattern == "center" ? 35.0 : 40.0,
                    markSizeMm: 6.0,
                    includeHoming: false,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0,
                    maxSegmentMm: 25.0
                )
            )
            dotTestPreviewPoints = response.points
            dotTestPreviewSegments = response.cameraSegments
            dotTestPreviewPlanHash = response.planHash
            dotTestPreviewPattern = response.pattern
            expectedPathSegments = []
            dotTestPreviewStatus = String(
                format: "DOT %@ %dP %dS %@",
                response.pattern.uppercased(),
                response.pointCount,
                response.cameraSegments.count,
                String(response.planHash.prefix(6))
            )
            statusText = "\(response.commandId) preview \(response.pattern)"
            diagnosticsEvent(
                "dot_preview_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "pattern": response.pattern,
                    "point_count": response.pointCount,
                    "segment_count": response.cameraSegments.count,
                    "plan_hash_prefix": String(response.planHash.prefix(8))
                ],
                snapshot: true
            )
            return response
        } catch {
            dotTestPreviewPoints = []
            dotTestPreviewSegments = []
            dotTestPreviewPlanHash = ""
            dotTestPreviewPattern = ""
            dotTestPreviewStatus = "DOT ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("dot_preview_failed", ["pattern": pattern, "error": error.localizedDescription], snapshot: true)
            return nil
        }
    }

    func clearDotTestOverlay() {
        dotTestPreviewPoints = []
        dotTestPreviewSegments = []
        dotTestPreviewPlanHash = ""
        dotTestPreviewPattern = ""
        dotTestPreviewStatus = "DOT --"
        diagnosticsEvent("dot_preview_cleared", snapshot: true)
    }

    func paperPointMm(cameraPoint: CGPoint) -> PaperPointMmSnapshot? {
        guard let registration = paperRegistrationSnapshot else { return nil }
        let coefficients = registration.cameraToPaper.coefficients
        guard coefficients.count == 9 else { return nil }

        let x = Double(cameraPoint.x)
        let y = Double(cameraPoint.y)
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }

        let paperNormX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let paperNormY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        return PaperPointMmSnapshot(
            x: paperNormX * registration.paperSizeMm.width,
            y: paperNormY * registration.paperSizeMm.height
        )
    }

    func runCenterDotTestMotion() async -> Bool {
        guard dotTestPreviewPattern == "center", !dotTestPreviewPlanHash.isEmpty else {
            dotTestPreviewStatus = "DOT PREVIEW FIRST"
            statusText = "Preview center dot before motion"
            diagnosticsEvent("dot_run_blocked", ["reason": "preview_required"], snapshot: true)
            return false
        }
        guard hasPaperLock else {
            dotTestPreviewStatus = "DOT NEED PAPER"
            statusText = "Paper homography required"
            diagnosticsEvent("dot_run_blocked", ["reason": "paper_homography_required"], snapshot: true)
            return false
        }
        guard isLiveMotionMode else {
            dotTestPreviewStatus = isOnline ? "DOT DRY" : "DOT OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("dot_run_blocked", ["reason": motionGateMessage], snapshot: true)
            return false
        }
        guard machineAxisModelTrusted else {
            dotTestPreviewStatus = "DOT AXIS BLOCK"
            statusText = "Axis geometry is not trusted"
            machineStatus = drawPreflightMessage
            diagnosticsEvent("dot_run_blocked", ["reason": "axis_geometry_not_trusted"], snapshot: true)
            return false
        }
        guard machineHomingTrusted else {
            dotTestPreviewStatus = "DOT POSITION BLOCK"
            statusText = "Absolute position is not trusted"
            machineStatus = drawPreflightMessage
            diagnosticsEvent("dot_run_blocked", ["reason": "absolute_position_not_trusted"], snapshot: true)
            return false
        }
        guard !isRunning && !isMachineBusy && !isMachineAlarm else {
            dotTestPreviewStatus = "DOT BUSY"
            statusText = motionGateMessage
            diagnosticsEvent("dot_run_blocked", ["reason": "machine_busy_or_alarm"], snapshot: true)
            return false
        }

        let expectedHash = dotTestPreviewPlanHash
        isRunning = true
        isMachineBusy = true
        activeAction = "dot"
        shortStatus = "RUN"
        dotTestPreviewStatus = "DOT RUN"
        statusText = "Running center dot motion"
        diagnosticsEvent("dot_run_started", ["plan_hash_prefix": String(expectedHash.prefix(8))], snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.runDotTest(
                DotTestRunRequest(
                    pattern: "center",
                    marginMm: 35.0,
                    markSizeMm: 6.0,
                    includeHoming: false,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: 500.0,
                    maxSegmentMm: 25.0,
                    expectedPlanHash: expectedHash
                )
            )
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            dotTestPreviewStatus = String(format: "DOT RUN %@", String(expectedHash.prefix(6)))
            statusText = "\(response.action) \(response.status)"
            diagnosticsEvent("dot_run_completed", commandPayload(response), snapshot: true)
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            dotTestPreviewStatus = "DOT ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            await refreshMachineStatus()
            diagnosticsEvent("dot_run_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    private func applyPaperRegistrationStatus(_ response: PaperRegistrationResponse) {
        if let registration = response.registration {
            paperRegistrationSnapshot = registration
            paperTransformStatus = String(
                format: "PAPER LOCK rms %.5f max %.5f",
                registration.rmsErrorNorm,
                registration.maxErrorNorm
            )
            return
        }
        paperRegistrationSnapshot = nil
        if response.status == "missing" {
            paperTransformStatus = "PAPER --"
        } else if response.status == "failed" {
            paperTransformStatus = "PAPER ERR"
        } else {
            paperTransformStatus = "PAPER \(response.status.uppercased())"
        }
    }

    private func runMachineCommand(
        action: String,
        operation: () async throws -> MachineCommandResponse
    ) async {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            diagnosticsEvent("machine_command_blocked", ["action": action, "reason": motionGateMessage], snapshot: true)
            return
        }

        guard !isRunning && !isMachineBusy else { return }
        isRunning = true
        isMachineBusy = true
        activeAction = action
        shortStatus = "RUN"
        statusText = "Machine \(action) running"
        diagnosticsEvent("machine_command_started", ["action": action], snapshot: true)
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await operation()
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            isDryRun = response.dryRun
            shortStatus = response.dryRun ? "DRY" : "DONE"
            statusText = "\(response.action) \(response.status)"
            diagnosticsEvent("machine_command_completed", commandPayload(response), snapshot: true)
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent(
                "machine_command_failed",
                errorPayload(error).merging(["action": action]) { current, _ in current },
                snapshot: true
            )
        }
    }

    private func applyMachineStatus(_ response: MachineStatusResponse) {
        bridgeController = response.controller
        isDryRun = response.dryRun
        armMotion = response.armMotion
        armPen = response.armPen
        armHoming = response.armHoming
        armUnlock = response.armUnlock
        machineState = response.state
        machinePins = response.pins.isEmpty ? "-" : response.pins
        machineMPos = "M \(formatPosition(response.mposMm))"
        machineWPos = "W \(formatPosition(response.wposMm))"
        machineFeedSpindle = "FS \(formatTuple(response.feedSpindle))"
        machineHomingTrusted = response.homingTrusted
        machineAxisModelTrusted = response.axisModelTrusted
        isMachineBusy = response.isBusy
        isMachineAlarm = response.isAlarm || response.status == "failed"
        activeAction = response.activeAction ?? activeAction
        machineStatus = response.error
            ?? "\(response.controller) \(response.status)"
    }

    private func animateExpectedPath(drawnLengthMm: Double, feedMmMin: Double) {
        animationTask?.cancel()
        guard drawnLengthMm > 0, feedMmMin > 0 else {
            pathRevealProgress = 1.0
            pathAnimationStatus = "IDLE"
            return
        }

        let durationSeconds = max(0.25, drawnLengthMm / (feedMmMin / 60.0))
        pathRevealProgress = 0.0
        pathAnimationStatus = String(format: "%.1fs", durationSeconds)

        animationTask = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let elapsed = start.duration(to: ContinuousClock.now)
                let elapsedSeconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
                let progress = min(1.0, elapsedSeconds / durationSeconds)
                await MainActor.run {
                    self?.pathRevealProgress = progress
                    if progress >= 1.0 {
                        self?.pathAnimationStatus = "DONE"
                    }
                }
                if progress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    private func formatPosition(_ values: [Double]?) -> String {
        guard let values, values.count >= 2 else { return "--" }
        return String(format: "%.1f, %.1f", values[0], values[1])
    }

    private func formatTuple(_ values: [Double]?) -> String {
        guard let values, !values.isEmpty else { return "--" }
        return values
            .prefix(3)
            .map { String(format: "%.0f", $0) }
            .joined(separator: ", ")
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
