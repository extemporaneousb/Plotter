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
}

struct BridgeDemoRequest: Encodable {
    let pattern: String
    let includeHoming: Bool
    let includeCentering: Bool
    let sideMm: Double
    let centerXMm: Double
    let centerYMm: Double
    let drawFeedMmMin: Double
    let travelFeedMmMin: Double
}

struct BridgeDemoResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let pattern: String
    let plannedCommands: [String]
    let simulation: BridgeDemoSimulation?
    let evaluation: BridgeDemoEvaluation?
    let eventLog: String
    let controllerTranscript: String?
    let error: String?
}

struct BridgeDemoSimulation: Decodable {
    let status: String
    let previewSegments: [ExpectedPathSegment]
    let drawnLengthMm: Double
    let errors: [String]
}

struct BridgeDemoEvaluation: Decodable {
    let status: String
    let message: String
    let checks: [BridgeDemoEvaluationCheck]
}

struct BridgeDemoEvaluationCheck: Decodable {
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

struct BridgeFaceRasterDrawRequest: Encodable {
    let raster: BridgeLuminanceRasterRequest
    let frame: BridgeDrawingFrameRequest
    let options: BridgeRasterPolygonOptionsRequest
    let includeHoming: Bool
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

struct BridgeFaceRasterDrawResponse: Decodable {
    let commandId: String
    let status: String
    let dryRun: Bool
    let plannedCommands: [String]
    let simulation: BridgeDemoSimulation?
    let summary: BridgePolygonDrawSummary?
    let rasterSummary: BridgeRasterPolygonSummary?
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
    let simulation: BridgeDemoSimulation?
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

struct PaperPointMmSnapshot: Decodable, Equatable {
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

struct AxisModelTrustSampleRequest: Encodable {
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
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeHealthResponse.self, from: data)
    }

    func drawShape(_ request: BridgeDemoRequest) async throws -> BridgeDemoResponse {
        let url = baseURL.appendingPathComponent("draw/shape")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeDemoResponse.self, from: data)
    }

    func previewShape(_ request: BridgeDemoRequest) async throws -> BridgeDemoResponse {
        let url = baseURL.appendingPathComponent("draw/shape/preview")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeDemoResponse.self, from: data)
    }

    func drawFaceRaster(_ request: BridgeFaceRasterDrawRequest) async throws -> BridgeFaceRasterDrawResponse {
        let url = baseURL.appendingPathComponent("draw/face")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(BridgeFaceRasterDrawResponse.self, from: data)
    }

    func startCalibration(_ request: CalibrationStartRequest) async throws -> CalibrationSessionResponse {
        let url = baseURL.appendingPathComponent("calibration/start")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(CalibrationSessionResponse.self, from: data)
    }

    func registerPaper(_ request: PaperRegistrationRequest) async throws -> PaperRegistrationResponse {
        let url = baseURL.appendingPathComponent("paper/register")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(PaperRegistrationResponse.self, from: data)
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
        let url = baseURL.appendingPathComponent("dot-test/preview")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(DotTestPreviewResponse.self, from: data)
    }

    func runDotTest(_ request: DotTestRunRequest) async throws -> MachineCommandResponse {
        try await postMachineCommand(path: "dot-test/run", request: request)
    }

    func machineStatus() async throws -> MachineStatusResponse {
        let url = baseURL.appendingPathComponent("machine/status")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, data: data)
        return try decoder.decode(MachineStatusResponse.self, from: data)
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

    private func postMachineCommand<Request: Encodable>(
        path: String,
        request: Request
    ) async throws -> MachineCommandResponse {
        let url = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validate(response: response, data: data)
        return try decoder.decode(MachineCommandResponse.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let failure = try? decoder.decode(BridgeDemoResponse.self, from: data),
               let error = failure.error {
                throw BridgeClientError.server(error)
            }
            if let failure = try? decoder.decode(BridgeFaceRasterDrawResponse.self, from: data),
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
    @Published var expectedPathSegments: [ExpectedPathSegment] = []
    @Published var dotTestPreviewStatus = "DOT --"
    @Published var visualCenterDotStatus = "VIS --"
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
    private var animationTask: Task<Void, Never>?
    private var isRefreshingMachineStatus = false

    var isLiveMotionMode: Bool {
        isOnline && !isDryRun
    }

    var isMockBridge: Bool {
        bridgeController == "mock"
    }

    var hasControllerPort: Bool {
        bridgeController.hasPrefix("serial:")
    }

    var canConnectHardware: Bool {
        isOnline && !isMockBridge && !isRunning && !isMachineBusy
    }

    var canArmHardware: Bool {
        isOnline && !isMockBridge && isDryRun && !isRunning && !isMachineBusy
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
        if !isOnline { return "Bridge Offline" }
        if isMockBridge { return "Preview Only" }
        if isLiveMotionMode { return "Connected to Plotter" }
        return "Connect to Plotter"
    }

    var plotterConnectionSubtitle: String {
        if isLiveMotionMode { return "Live" }
        if !isOnline { return "Offline" }
        if isMockBridge { return "Mock" }
        if hasControllerPort { return "Dry Run" }
        return "Dry Run"
    }

    var plotterConnectionSystemName: String {
        if isRunning || isMachineBusy { return "hourglass" }
        if !isOnline { return "bolt.slash" }
        if isMockBridge { return "eye" }
        if isLiveMotionMode { return "checkmark.seal.fill" }
        return "cable.connector"
    }

    var plotterConnectionHelp: String {
        if !isOnline { return "Bridge is offline; start the Plotter bridge before connecting." }
        if isMockBridge { return "Mock preview bridge cannot connect to physical plotter hardware." }
        if isLiveMotionMode { return "Connected to plotter. Machine controls are live-gated." }
        if isRunning || isMachineBusy { return "Machine is busy; connection change is blocked." }
        return "Connect to the physical plotter and leave dry-run mode. This probes status but does not move, home, unlock, or actuate the pen."
    }

    var hasPaperLock: Bool {
        paperRegistrationSnapshot != nil || paperTransformStatus.contains("LOCK")
    }

    var canRunAbsoluteDrawing: Bool {
        isLiveMotionMode
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
        if isMockBridge { return "Preview bridge only; start hardware standby to connect" }
        if !hasControllerPort { return "Controller not connected; connect or arm to auto-detect" }
        if isDryRun { return "Motion blocked: dry-run bridge; arm hardware to enable live controls" }
        if isMachineAlarm { return "Motion blocked: machine alarm" }
        if isMachineBusy || isRunning { return "Motion busy: \(activeAction)" }
        if !hasPaperLock { return "Drawing blocked: paper homography missing" }
        if !machineAxisModelTrusted { return "Drawing blocked: axis geometry not trusted" }
        if !machineHomingTrusted { return "Drawing blocked: absolute position not trusted" }
        return "Live motion enabled"
    }

    var drawPreflightMessage: String {
        if !isOnline { return "Bridge offline" }
        if isDryRun { return "Dry-run only" }
        if !hasPaperLock { return "Paper homography missing" }
        if !machineAxisModelTrusted { return "Axis geometry not trusted" }
        if !machineHomingTrusted { return "Absolute position not trusted" }
        if isMachineAlarm { return "Machine alarm" }
        if isMachineBusy || isRunning { return "Machine busy" }
        return "Absolute drawing armed"
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
            shortStatus = motionModeLabel
            statusText = "\(health.controller) \(health.status)"
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
        }
    }

    func refreshPaperStatus() async {
        guard isOnline, !isCalibrating else { return }
        do {
            let response = try await client.paperStatus()
            applyPaperRegistrationStatus(response)
        } catch {
            paperTransformStatus = "PAPER ?"
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
        }
    }

    func reconnectMachine() async {
        guard !isRunning && !isMachineBusy else { return }
        isRunning = true
        isMachineBusy = true
        activeAction = "reconnect"
        shortStatus = "CONN"
        statusText = "Reconnecting controller"
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
        }
    }

    func armHardware() async {
        await setHardwareArmed(true)
    }

    func connectPlotter() async {
        guard !isLiveMotionMode else {
            statusText = "Plotter already connected"
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
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            if live {
                isMachineAlarm = true
            }
        }
    }

    func previewShapeOverlay(pattern: String) async -> Bool {
        guard !isRunning && !isMachineBusy else { return false }
        guard isOnline else {
            previewStatus = "SIM OFF"
            statusText = "Bridge offline"
            return false
        }

        isCalibrating = true
        activeAction = "shape-preview"
        previewStatus = "SIM PREVIEW"
        statusText = "Previewing \(pattern) overlay"
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewShape(
                BridgeDemoRequest(
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
            return response.status == "ready" || response.status == "completed"
        } catch {
            expectedPathSegments = []
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
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
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.drawShape(
                BridgeDemoRequest(
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
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
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
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            return false
        }
    }

    func replayExpectedPath() {
        let length = expectedPathSegments.reduce(0.0) { partial, segment in
            partial + segment.lengthMm
        }
        animateExpectedPath(drawnLengthMm: length, feedMmMin: shapeDrawFeedMmMin)
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
            return response
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            return nil
        }
    }

    func visualRelativeMove(xMm: Double, yMm: Double, feedMmMin: Double) async -> MachineCommandResponse? {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
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
            return response
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            return nil
        }
    }

    func dotMarkCurrentPosition() async -> Bool {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
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
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            return false
        }
    }

    func relativeMarkCurrentPosition(markSizeMm: Double, drawFeedMmMin: Double) async -> Bool {
        guard isLiveMotionMode else {
            shortStatus = isOnline ? "DRY" : "OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
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
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            visualCenterDotStatus = "VIS ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
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
            return
        }

        activeAction = "stop"
        shortStatus = "STOP"
        statusText = "Sending stop"

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
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineAlarm = true
        }
    }

    func resumeMachine() async {
        guard isLiveMotionMode else {
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            return
        }
        guard !isRunning, machineState.hasPrefix("Hold") else { return }
        isRunning = true
        activeAction = "resume"
        shortStatus = "RUN"
        statusText = "Sending resume"
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
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineAlarm = true
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
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.startCalibration(
                CalibrationStartRequest(
                    marginMm: 25.0,
                    travelFeedMmMin: 500.0,
                    includeHoming: true,
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
        } catch {
            modelStatus = "MODEL ERR"
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
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
            return response
        } catch {
            paperTransformStatus = "PAPER ERR"
            statusText = error.localizedDescription
            return nil
        }
    }

    func previewDotTestOverlay(pattern: String = "center") async -> DotTestPreviewResponse? {
        guard !isCalibrating else { return nil }
        guard isOnline else {
            dotTestPreviewStatus = "DOT OFF"
            statusText = "Bridge offline"
            return nil
        }
        if !hasPaperLock {
            await refreshPaperStatus()
            if !hasPaperLock {
                dotTestPreviewStatus = "DOT NEED PAPER"
                statusText = "Paper homography required"
                return nil
            }
        }

        isCalibrating = true
        activeAction = "dot-preview"
        dotTestPreviewStatus = "DOT PREVIEW"
        statusText = "Previewing dot-test overlay"
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
            return response
        } catch {
            dotTestPreviewPoints = []
            dotTestPreviewSegments = []
            dotTestPreviewPlanHash = ""
            dotTestPreviewPattern = ""
            dotTestPreviewStatus = "DOT ERR"
            statusText = error.localizedDescription
            return nil
        }
    }

    func clearDotTestOverlay() {
        dotTestPreviewPoints = []
        dotTestPreviewSegments = []
        dotTestPreviewPlanHash = ""
        dotTestPreviewPattern = ""
        dotTestPreviewStatus = "DOT --"
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
            return false
        }
        guard hasPaperLock else {
            dotTestPreviewStatus = "DOT NEED PAPER"
            statusText = "Paper homography required"
            return false
        }
        guard isLiveMotionMode else {
            dotTestPreviewStatus = isOnline ? "DOT DRY" : "DOT OFF"
            statusText = motionGateMessage
            machineStatus = motionGateMessage
            return false
        }
        guard machineAxisModelTrusted else {
            dotTestPreviewStatus = "DOT AXIS BLOCK"
            statusText = "Axis geometry is not trusted"
            machineStatus = drawPreflightMessage
            return false
        }
        guard machineHomingTrusted else {
            dotTestPreviewStatus = "DOT POSITION BLOCK"
            statusText = "Absolute position is not trusted"
            machineStatus = drawPreflightMessage
            return false
        }
        guard !isRunning && !isMachineBusy && !isMachineAlarm else {
            dotTestPreviewStatus = "DOT BUSY"
            statusText = motionGateMessage
            return false
        }

        let expectedHash = dotTestPreviewPlanHash
        isRunning = true
        isMachineBusy = true
        activeAction = "dot"
        shortStatus = "RUN"
        dotTestPreviewStatus = "DOT RUN"
        statusText = "Running center dot motion"
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
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            dotTestPreviewStatus = "DOT ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            await refreshMachineStatus()
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
            return
        }

        guard !isRunning && !isMachineBusy else { return }
        isRunning = true
        isMachineBusy = true
        activeAction = action
        shortStatus = "RUN"
        statusText = "Machine \(action) running"
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
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
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
