import Combine
import Foundation

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
    @Published var paperTransformStatus = "FIELD --"
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
    @Published var faceContourPreviewOverlay: FaceContourPreviewOverlay?
    @Published var portraitContourSettings = PortraitContourSettings()
    @Published var expectedPathSegments: [ExpectedPathSegment] = []
    @Published var expectedPathRole = ""
    @Published var expectedPathLabel = "EXPECTED"
    @Published var predictedPathSegments: [ExpectedPathSegment] = []
    @Published var predictedPathLabel = "Model-corrected frame"
    @Published var observedDrawingFrameOverlay: DrawingFrameOverlay?
    @Published var drawingCalibrationStatus = "DRAW CAL --"
    @Published var drawingCalibrationDetail = "No drawing calibration"
    @Published var latestDrawingCalibration: BridgeDrawingCalibrationModel?
    @Published var drawingCalibrationSessionStatus = "SESSION --"
    @Published var drawingCalibrationSessionDetail = "No drawing calibration session"
    @Published var latestDrawingCalibrationSession: BridgeDrawingCalibrationSession?
    @Published var currentDrawingCalibrationBatch: BridgeDrawingCalibrationBatch?
    @Published var latestDrawingCalibrationBatchPreview: BridgeDrawingCalibrationProgramResponse?
    @Published var latestDrawingCalibrationBatchRun: BridgeDrawingCalibrationProgramResponse?
    @Published var bindingMarkPreviewStatus = "BIND --"
    @Published var adaptiveProbeStatus = "PROBE --"
    @Published var latestVisualReadiness: BridgeVisualReadinessState?
    @Published var calibrationWorkflow: BridgeCalibrationWorkflow?
    @Published var visualCenterDotStatus = "VIS --"
    @Published var visualBindingStatus = "BIND --"
    @Published var visualBindingDetail = "No binding observations"
    @Published var visualBindingObservationCount = 0
    @Published var visualBindingValid = false
    @Published var learnedCapToTipModel: BridgeCapToTipModel?
    @Published var drawableSafeZone: BridgeDrawingSafeZone?
    @Published var visualProbeEvidenceRunId = "swift-probe-\(UUID().uuidString.lowercased())"
    @Published var bindingMarkPreviewPoints: [BindingMarkPreviewPoint] = []
    @Published var bindingMarkPreviewSegments: [BindingMarkPreviewSegment] = []
    @Published var bindingMarkPreviewCommandId = ""
    @Published var bindingMarkPreviewPlanHash = ""
    @Published var bindingMarkPreviewPointSet = ""
    @Published var drawVerifyStatus = "DRAW --"
    @Published var drawVerifyDetail = "No drawing run"
    @Published var drawVerifyKind = ""
    @Published var drawVerifyLabel = ""
    @Published var drawVerifyCommandId = ""
    @Published var drawVerifyPlanHash = ""
    @Published var workspaceXMm = 533.4
    @Published var workspaceYMm = 215.9
    @Published var machineMaxFeedMmMin = 1200.0
    @Published var machineMaxJogMm = 50.0
    @Published var bindingExtraPaddingMm = 40.0
    @Published var bindingMaxMarkSizeMm = 14.0
    @Published var bindingParkClearanceMm = 44.0
    @Published var bindingObservationClearanceMm = 4.0
    @Published var shapeDrawFeedMmMin = 240.0
    @Published var pathRevealProgress = 1.0
    @Published var pathAnimationStatus = "IDLE"
    @Published var isMachineBusy = false
    @Published var isMachineAlarm = false
    @Published var activeAction = ""
    @Published var manualStepMm = 1.0
    @Published var manualFeedMmMin = 1200.0
    @Published var manualJogWorkspaceOverride = false
    @Published var machineMPosMm: [Double] = []
    @Published var machineWPosMm: [Double] = []
    @Published var operatorUIState: [String: Any] = [:]

    private let client: PlotterBridgeClient
    private let bridgeSupervisor: BridgeProcessSupervisor?
    private let diagnostics = AppDiagnostics.shared
    private let appBuildId = currentAppBuildId()
    private let requiredBridgeApiVersion = currentRequiredBridgeApiVersion()
    private var animationTask: Task<Void, Never>?
    private var isRefreshingMachineStatus = false
    private var lastDiagnosticsHealthSummary = ""

    var visualFieldWidthMm: Double {
        paperRegistrationSnapshot?.paperSizeMm.width ?? 200.0
    }

    var visualFieldHeightMm: Double {
        paperRegistrationSnapshot?.paperSizeMm.height ?? 150.0
    }

    var showDrawingBorderOverlay: Bool {
        if observedDrawingFrameOverlay?.isVisible == true {
            return false
        }
        if expectedPathRole == "setup_field_frame", !expectedPathSegments.isEmpty {
            return false
        }
        if !predictedPathSegments.isEmpty {
            return false
        }
        return true
    }
    private var lastDiagnosticsMachineSummary = ""
    private var lastDiagnosticsPaperSummary = ""

    init(
        client: PlotterBridgeClient = PlotterBridgeClient(),
        bridgeSupervisor: BridgeProcessSupervisor? = nil
    ) {
        self.client = client
        self.bridgeSupervisor = bridgeSupervisor
        diagnosticsEvent("app_model_initialized", snapshot: true)
    }

    var isLiveMotionMode: Bool {
        isOnline && !isDryRun
    }

    var canRunLiveRelativeMotionCommand: Bool {
        liveRelativeMotionBlockReason() == nil
    }

    var canRunSetupRelativeMotionCommand: Bool {
        setupRelativeMotionBlockReason() == nil
    }

    var fastTravelFeedMmMin: Double {
        min(machineMaxFeedMmMin, manualFeedMmMin)
    }

    var hasMachinePosition: Bool {
        machineMPosMm.count >= 2
    }

    func availableMachineTravelMm(axis: String, direction: Double, clearanceMm: Double = 2.0) -> Double? {
        guard hasMachinePosition else { return nil }
        let normalizedAxis = axis.uppercased()
        let index: Int
        let upper: Double
        switch normalizedAxis {
        case "X":
            index = 0
            upper = workspaceXMm
        case "Y":
            index = 1
            upper = workspaceYMm
        default:
            return nil
        }
        guard machineMPosMm.indices.contains(index) else { return nil }
        let position = machineMPosMm[index]
        if direction >= 0 {
            return max(0.0, upper - clearanceMm - position)
        }
        return max(0.0, position - clearanceMm)
    }

    func boundedMachineTravelDistance(
        axis: String,
        preferredDistanceMm: Double,
        minimumDistanceMm: Double,
        clearanceMm: Double = 2.0,
        allowOpposite: Bool = true
    ) -> Double? {
        guard abs(preferredDistanceMm) > 0.000_001 else { return nil }
        let preferredDirection = preferredDistanceMm >= 0 ? 1.0 : -1.0
        let requested = abs(preferredDistanceMm)
        if let preferredRoom = availableMachineTravelMm(
            axis: axis,
            direction: preferredDirection,
            clearanceMm: clearanceMm
        ) {
            let bounded = min(requested, preferredRoom)
            if bounded >= minimumDistanceMm {
                return preferredDirection * bounded
            }
            guard allowOpposite else { return nil }
            let oppositeRoom = availableMachineTravelMm(
                axis: axis,
                direction: -preferredDirection,
                clearanceMm: clearanceMm
            ) ?? 0.0
            let oppositeBounded = min(requested, oppositeRoom)
            if oppositeBounded >= minimumDistanceMm {
                return -preferredDirection * oppositeBounded
            }
            return nil
        }
        return preferredDistanceMm
    }

    func startVisualProbeEvidenceRun(prefix: String = "swift-probe") -> String {
        let runId = "\(prefix)-\(UUID().uuidString.lowercased())"
        visualProbeEvidenceRunId = runId
        return runId
    }

    func resetVisualCalibrationSession(prefix: String = "swift-probe") -> String {
        let runId = startVisualProbeEvidenceRun(prefix: prefix)
        clearBindingMarkPreviewOverlay()
        adaptiveProbeStatus = "PROBE --"
        visualCenterDotStatus = "VIS --"
        visualBindingStatus = "BIND --"
        visualBindingDetail = "Run motion calibration, then validate relative cap motion"
        visualBindingObservationCount = 0
        visualBindingValid = false
        diagnosticsEvent(
            "visual_calibration_session_reset",
            [
                "run_id": runId,
                "prefix": prefix
            ],
            snapshot: true
        )
        return runId
    }

    func clearVisualCalibrationScratch() {
        visualProbeEvidenceRunId = ""
        clearBindingMarkPreviewOverlay()
        adaptiveProbeStatus = "PROBE --"
        visualCenterDotStatus = "VIS --"
        visualBindingStatus = "BIND --"
        visualBindingDetail = "Run motion calibration, then validate relative cap motion"
        visualBindingObservationCount = 0
        visualBindingValid = false
    }

    func resetCalibrationSetup(scope: String = "vision_machine") async -> Bool {
        guard isOnline else {
            statusText = "Bridge offline"
            return false
        }
        do {
            let response = try await client.resetCalibrationSetup(
                BridgeSetupResetRequest(scope: scope, confirmed: true)
            )
            guard response.status == "reset" else {
                statusText = response.error ?? "Visual setup reset failed"
                diagnosticsEvent(
                    "visual_setup_reset_failed",
                    [
                        "status": response.status,
                        "scope": response.scope,
                        "confirmed": response.confirmed,
                        "error": response.error ?? ""
                    ],
                    snapshot: true
                )
                return false
            }
            latestVisualReadiness = response.readiness
            calibrationWorkflow = response.workflow
            if response.scope == "vision_machine" {
                paperRegistrationSnapshot = nil
                paperTransformStatus = "FIELD --"
                learnedCapToTipModel = nil
                drawableSafeZone = nil
                clearVisualCalibrationScratch()
            }
            drawVerifyStatus = "DRAW --"
            drawVerifyDetail = "No drawing run"
            clearExpectedPathOverlay()
            observedDrawingFrameOverlay = nil
            latestDrawingCalibration = nil
            drawingCalibrationStatus = "DRAW CAL --"
            drawingCalibrationDetail = "No drawing calibration"
            latestDrawingCalibrationSession = nil
            currentDrawingCalibrationBatch = nil
            latestDrawingCalibrationBatchPreview = nil
            latestDrawingCalibrationBatchRun = nil
            drawingCalibrationSessionStatus = "SESSION --"
            drawingCalibrationSessionDetail = "No drawing calibration session"
            statusText = "Visual setup reset"
            diagnosticsEvent(
                "visual_setup_reset",
                [
                    "status": response.status,
                    "scope": response.scope,
                    "confirmed": response.confirmed,
                    "cleared_files": response.clearedFiles,
                    "missing_files": response.missingFiles
                ],
                snapshot: true
            )
            return response.status == "reset"
        } catch {
            statusText = error.localizedDescription
            diagnosticsEvent("visual_setup_reset_failed", errorPayload(error), snapshot: true)
            return false
        }
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
        guard isOnline else { return false }
        guard let rawVersion = cleanBridgeMetadata(bridgeApiVersion),
              let apiVersion = Int(rawVersion) else {
            return true
        }
        return apiVersion < requiredBridgeApiVersion
    }

    var hasBridgeContractMismatch: Bool {
        hasBridgeApiMismatch || hasLifecycleBuildMismatch
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
        lines.append(manualMotionGateMessage)
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
        isOnline && !hasBridgeContractMismatch && !isMockBridge && isDryRun && !isRunning && !isMachineBusy
    }

    var canUsePlotterConnectionControl: Bool {
        isLiveMotionMode || canArmHardware || canDisarmHardware
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

    var hasDrawingAuthority: Bool {
        isDryRun || machineAxisModelTrusted || visualBindingValid
    }

    var drawingAuthorityDetail: String {
        if isDryRun { return "dry-run bridge" }
        if machineAxisModelTrusted { return "axis model trusted" }
        if visualBindingValid { return "future ink binding validated" }
        return "future drawing authority required"
    }

    var canRunAbsoluteDrawing: Bool {
        isOnline
            && !hasBridgeContractMismatch
            && hasPaperLock
            && hasDrawingAuthority
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
        if hasLifecycleBuildMismatch { return "Motion blocked: app/bridge build mismatch; restart both from the same checkout" }
        if isMockBridge { return "Preview bridge only; start hardware standby to connect" }
        if !hasControllerPort { return "Controller not connected; connect or arm to auto-detect" }
        if isDryRun { return "Motion blocked: dry-run bridge; arm hardware to enable live controls" }
        if isMachineAlarm { return "Motion blocked: machine alarm" }
        if isMachineBusy || isRunning { return "Motion busy: \(activeAction)" }
        return "Live motion enabled"
    }

    var manualMotionGateMessage: String {
        if let blockReason = liveMachineCommandBlockReason(allowBusy: false) {
            return blockReason
        }
        if manualJogWorkspaceOverride {
            return "Manual jog live: workspace projection override ON"
        }
        return "Manual jog live: workspace projection guard ON"
    }

    private func liveMachineCommandBlockReason(allowBusy: Bool = false) -> String? {
        if !isOnline { return "Motion blocked: bridge offline" }
        if hasBridgeApiMismatch { return "Motion blocked: bridge API mismatch; restart safe bridge" }
        if hasLifecycleBuildMismatch { return "Motion blocked: app/bridge build mismatch; restart both from the same checkout" }
        if isMockBridge { return "Preview bridge only; start hardware standby to connect" }
        if !hasControllerPort { return "Controller not connected; connect or arm to auto-detect" }
        if isDryRun { return "Motion blocked: dry-run bridge; arm hardware to enable live controls" }
        if isMachineAlarm { return "Motion blocked: machine alarm" }
        if !allowBusy && (isMachineBusy || isRunning) { return "Motion busy: \(activeAction)" }
        return nil
    }

    private func liveRelativeMotionBlockReason(allowBusy: Bool = false) -> String? {
        if let blockReason = liveMachineCommandBlockReason(allowBusy: allowBusy) {
            return blockReason
        }
        if !hasPaperLock { return "Visual relative motion blocked: visual field missing" }
        return nil
    }

    private func setupRelativeMotionBlockReason(allowBusy: Bool = false) -> String? {
        if let blockReason = liveMachineCommandBlockReason(allowBusy: allowBusy) {
            return blockReason
        }
        return nil
    }

    private func blockLiveRelativeMotionCommand(
        event: String,
        details: [String: Any] = [:]
    ) {
        let reason = liveRelativeMotionBlockReason(allowBusy: false) ?? motionGateMessage
        shortStatus = isOnline ? "BLOCK" : "OFF"
        statusText = reason
        machineStatus = reason
        var payload = details
        payload["reason"] = reason
        payload["build_mismatch"] = hasLifecycleBuildMismatch
        payload["api_mismatch"] = hasBridgeApiMismatch
        diagnosticsEvent(event, payload, snapshot: true)
    }

    private func blockSetupRelativeMotionCommand(
        event: String,
        details: [String: Any] = [:]
    ) {
        let reason = setupRelativeMotionBlockReason(allowBusy: false) ?? motionGateMessage
        shortStatus = isOnline ? "BLOCK" : "OFF"
        statusText = reason
        machineStatus = reason
        var payload = details
        payload["reason"] = reason
        payload["build_mismatch"] = hasLifecycleBuildMismatch
        payload["api_mismatch"] = hasBridgeApiMismatch
        diagnosticsEvent(event, payload, snapshot: true)
    }

    var drawPreflightMessage: String {
        if !isOnline { return "Bridge offline" }
        if hasBridgeApiMismatch { return "Bridge API mismatch" }
        if hasLifecycleBuildMismatch { return "App/bridge build mismatch" }
        if isDryRun { return "Bridge-run dry-run only" }
        if !hasPaperLock { return "Visual field missing" }
        if !hasDrawingAuthority { return drawingAuthorityDetail }
        if isMachineAlarm { return "Machine alarm" }
        if isMachineBusy || isRunning { return "Machine busy" }
        return "Bridge-run drawing armed"
    }

    var drawVerifyStatusLine: String {
        guard !drawVerifyPlanHash.isEmpty else { return drawVerifyStatus }
        let label = drawVerifyLabel.isEmpty ? drawVerifyKind : drawVerifyLabel
        return "\(drawVerifyStatus) \(label) \(Self.shortPlanHash(drawVerifyPlanHash))"
    }

    private static func shortPlanHash(_ hash: String) -> String {
        guard !hash.isEmpty else { return "--" }
        return String(hash.prefix(8))
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

    func updateOperatorUIState(_ state: [String: Any], reason: String = "operator_ui_state_changed") {
        operatorUIState = state
        diagnosticsEvent(reason, state, snapshot: true)
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
            "future_drawing_preflight": drawPreflightMessage
        ]
    }

    private func diagnosticsState(reason: String) -> [String: Any] {
        [
            "reason": reason,
            "active_workflow": activeAction.isEmpty ? reason : activeAction,
            "latest_visible_error": latestVisibleDiagnosticsError(),
            "exact_blockers": exactDiagnosticsBlockers(),
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
                "mpos_mm": machineMPosMm,
                "wpos": machineWPos,
                "wpos_mm": machineWPosMm,
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
                "workspace_y_mm": workspaceYMm,
                "max_feed_mm_min": machineMaxFeedMmMin,
                "max_jog_mm": machineMaxJogMm
            ],
            "previews": [
                "shape": previewStatus,
                "image": imagePreviewStatus,
                "image_detail": imagePreviewDetail,
                "image_contours": imagePreviewContourCount,
                "image_bridge_preview_eligible": imagePreviewEligibleForBridgePreview,
                "expected_path_segments": expectedPathSegments.count,
                "expected_path_role": expectedPathRole,
                "predicted_path_segments": predictedPathSegments.count,
                "observed_frame_visible": observedDrawingFrameOverlay?.isVisible ?? false,
                "observed_frame_edges": observedDrawingFrameOverlay?.detectedEdgeCount ?? 0,
                "drawing_calibration": drawingCalibrationStatus,
                "drawing_calibration_detail": drawingCalibrationDetail,
                "drawing_calibration_model_id": latestDrawingCalibration?.modelId ?? "",
                "binding_mark_preview": bindingMarkPreviewStatus,
                "binding_mark_point_set": bindingMarkPreviewPointSet,
                "binding_mark_points": bindingMarkPreviewPoints.count,
                "binding_mark_segments": bindingMarkPreviewSegments.count,
                "draw_verify": drawVerifyStatus,
                "draw_verify_kind": drawVerifyKind,
                "draw_verify_command_id": drawVerifyCommandId,
                "draw_verify_plan_hash": drawVerifyPlanHash,
                "adaptive_probe": adaptiveProbeStatus,
                "visual_center_dot": visualCenterDotStatus,
                "visual_binding": visualBindingStatus,
                "visual_binding_valid": visualBindingValid,
                "visual_binding_observations": visualBindingObservationCount,
                "path_animation": pathAnimationStatus,
                "path_reveal_progress": pathRevealProgress
            ],
            "ui": operatorUIState,
            "gates": [
                "connection_title": plotterConnectionTitle,
                "connection_subtitle": plotterConnectionSubtitle,
                "connection_help": plotterConnectionHelp,
                "motion_mode": motionModeLabel,
                "arm": armStatusLabel,
                "motion_gate": motionGateMessage,
                "manual_motion_gate": manualMotionGateMessage,
                "manual_jog_workspace_override": manualJogWorkspaceOverride,
                "future_drawing_preflight": drawPreflightMessage,
                "can_connect_hardware": canConnectHardware,
                "can_arm_hardware": canArmHardware,
                "can_disarm_hardware": canDisarmHardware,
                "can_run_absolute_drawing": canRunAbsoluteDrawing,
                "can_run_visual_relative_motion": canRunLiveRelativeMotionCommand
            ]
        ]
    }

    private func exactDiagnosticsBlockers() -> [String] {
        var blockers: [String] = []
        func add(_ value: String) {
            let normalized = Self.blockerId(value)
            guard !normalized.isEmpty, !blockers.contains(normalized) else { return }
            blockers.append(normalized)
        }
        if !isOnline { add("bridge_offline") }
        if hasBridgeApiMismatch { add("bridge_api_mismatch") }
        if hasLifecycleBuildMismatch { add("app_bridge_build_mismatch") }
        if isDryRun { add("bridge_dry_run") }
        if !hasPaperLock { add("paper_registration_missing") }
        if isMachineAlarm { add("machine_alarm") }
        if isMachineBusy || isRunning { add("machine_busy") }
        add(motionGateMessage)
        if isFutureDrawingAction {
            add(drawPreflightMessage)
            if !visualBindingDetail.isEmpty { add(visualBindingDetail) }
        }
        if paperTransformStatus.contains("ERR") { add(paperTransformStatus) }
        return blockers
    }

    private func latestVisibleDiagnosticsError() -> String {
        for value in [statusText, machineStatus, drawVerifyDetail] {
            let lower = value.lowercased()
            if lower.contains("error") || lower.contains("failed") || lower.contains("blocked") || lower.contains("offline") {
                return value
            }
        }
        return ""
    }

    private var isFutureDrawingAction: Bool {
        let action = activeAction.lowercased()
        return action.contains("draw")
            || action.contains("binding")
            || action.contains("portrait")
            || action.contains("image")
            || action.contains("shape")
    }

    private static func blockerId(_ value: String) -> String {
        let allowed = value.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "_"
        }
        var normalized = String(allowed)
        while normalized.contains("__") {
            normalized = normalized.replacingOccurrences(of: "__", with: "_")
        }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
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

    private func applyVisualBindingStatus(_ response: BridgeVisualPositionBindingResponse) {
        if let binding = response.binding {
            learnedCapToTipModel = binding.capToTipModel.source == "unsolved" ? nil : binding.capToTipModel
            drawableSafeZone = binding.safeZone
            let observationCount = binding.residuals.observationCount
            visualBindingObservationCount = observationCount
            visualBindingValid = binding.validationStatus == "validated" && binding.blockers.isEmpty
            visualBindingStatus = visualBindingValid
                ? "BIND READY"
                : String(format: "BIND %@ %d", binding.validationStatus.uppercased(), observationCount)
            if visualBindingValid {
                let rms = binding.residuals.rmsResidualMm.map { String(format: "rms %.2f", $0) } ?? "rms --"
                let maxResidual = binding.residuals.maxResidualMm.map { String(format: "max %.2f", $0) } ?? "max --"
                visualBindingDetail = "Binding validated \(rms) \(maxResidual)"
            } else if let blocker = binding.blockers.first {
                visualBindingDetail = blocker
            } else {
                visualBindingDetail = "Need binding mark observations"
            }
            return
        }

        visualBindingObservationCount = 0
        visualBindingValid = false
        learnedCapToTipModel = nil
        drawableSafeZone = nil
        visualBindingStatus = response.status == "missing" ? "BIND --" : "BIND ERR"
        visualBindingDetail = response.error ?? "No binding observations"
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
            machineMaxFeedMmMin = health.maxFeedMmMin ?? machineMaxFeedMmMin
            machineMaxJogMm = health.maxJogMm ?? machineMaxJogMm
            manualFeedMmMin = min(manualFeedMmMin, machineMaxFeedMmMin)
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
            paperTransformStatus = "FIELD --"
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

    func startOwnedBridgeIfNeeded() {
        guard let bridgeSupervisor else { return }
        switch bridgeSupervisor.startIfNeeded() {
        case .alreadyRunning(let url):
            statusText = "Bridge starting \(url.absoluteString)"
            shortStatus = "BOOT"
        case .started(let url, let logPath):
            statusText = "Bridge starting \(url.absoluteString)"
            shortStatus = "BOOT"
            diagnosticsEvent(
                "owned_bridge_started",
                ["base_url": url.absoluteString, "log": logPath],
                snapshot: true
            )
        case .unavailable(let reason):
            isOnline = false
            shortStatus = "OFF"
            statusText = "Bridge supervisor failed"
            machineStatus = reason
            diagnosticsEvent("owned_bridge_unavailable", ["reason": reason], snapshot: true)
        }
    }

    func waitForOwnedBridgeStartup() async {
        guard bridgeSupervisor != nil else { return }
        for _ in 0..<12 {
            await refreshHealth()
            if isOnline { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func refreshPaperStatus() async {
        guard isOnline, !isCalibrating else { return }
        do {
            let response = try await client.paperStatus()
            applyPaperRegistrationStatus(response)
            recordPaperIfChanged()
        } catch {
            paperTransformStatus = "FIELD ?"
            diagnosticsEvent("paper_status_failed", errorPayload(error), snapshot: true)
        }
    }

    func refreshVisualReadinessStatus() async -> BridgeVisualReadinessState? {
        guard isOnline, !isCalibrating else { return latestVisualReadiness }
        do {
            let response = try await client.visualReadinessStatus()
            latestVisualReadiness = response.readiness
            calibrationWorkflow = response.workflow
            adaptiveProbeStatus = response.status == "ready" ? "PROBE READY" : "PROBE BLOCK"
            statusText = visualReadinessWorkflowStatusText(
                status: response.status,
                readiness: response.readiness,
                workflow: response.workflow,
                fallback: adaptiveProbeStatus
            )
            diagnosticsEvent(
                "visual_readiness_refreshed",
                [
                    "status": response.status,
                    "workflow_phase": response.workflow?.phase ?? "",
                    "workflow_activity": response.workflow?.activity ?? "",
                    "workflow_health": response.workflow?.health ?? "",
                    "ready_to_draw": response.workflow?.readyToDraw ?? false,
                    "motion_model_valid": response.readiness?.motionModelValid ?? false,
                    "has_relative_motion_model": response.readiness?.relativeMotionModel != nil,
                    "blockers": response.readiness?.blockers ?? []
                ],
                snapshot: true
            )
            return response.readiness
        } catch {
            diagnosticsEvent("visual_readiness_refresh_failed", errorPayload(error), snapshot: true)
            return latestVisualReadiness
        }
    }

    func confirmCalibrationCap(
        cameraPoint: CGPoint,
        source: String,
        confidence: Double
    ) async -> BridgeVisualReadinessState? {
        guard isOnline else { return latestVisualReadiness }
        do {
            let response = try await client.confirmCalibrationCap(
                BridgeCalibrationCapConfirmationRequest(
                    observedNorm: NormPoint(cameraPoint),
                    source: source,
                    confidence: confidence,
                    cameraId: "plotter-camera",
                    cameraName: "Plotter Camera",
                    requestId: "swift-confirm-green-cap"
                )
            )
            latestVisualReadiness = response.readiness
            calibrationWorkflow = response.workflow
            adaptiveProbeStatus = response.status == "ready" ? "PROBE READY" : adaptiveProbeStatus
            statusText = visualReadinessWorkflowStatusText(
                status: response.status,
                readiness: response.readiness,
                workflow: response.workflow,
                fallback: adaptiveProbeStatus
            )
            diagnosticsEvent(
                "calibration_cap_confirmed",
                [
                    "status": response.status,
                    "workflow_phase": response.workflow?.phase ?? "",
                    "workflow_activity": response.workflow?.activity ?? "",
                    "workflow_health": response.workflow?.health ?? "",
                    "next_action": response.workflow?.nextPrimaryAction.id ?? "",
                    "confidence": confidence
                ],
                snapshot: true
            )
            return response.readiness
        } catch {
            diagnosticsEvent("calibration_cap_confirm_failed", errorPayload(error), snapshot: true)
            return latestVisualReadiness
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
            machineMPosMm = []
            machineWPosMm = []
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
            machineMPosMm = []
            machineWPosMm = []
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

    func drawVisualBindingBoundsFrame(points: [BindingMarkPreviewPoint]) async -> Bool {
        guard canRunAbsoluteDrawing else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = drawPreflightMessage
            statusText = drawPreflightMessage
            diagnosticsEvent("visual_binding_bounds_frame_blocked", ["reason": drawPreflightMessage], snapshot: true)
            return false
        }
        guard !points.isEmpty else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = "Binding frame requires preview points"
            statusText = drawVerifyDetail
            diagnosticsEvent("visual_binding_bounds_frame_blocked", ["reason": "missing_preview_points"], snapshot: true)
            return false
        }

        let xs = points.map { $0.paperMm.x }
        let ys = points.map { $0.paperMm.y }
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max(),
              maxX - minX > 1.0,
              maxY - minY > 1.0 else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = "Binding frame bounds are degenerate"
            statusText = drawVerifyDetail
            diagnosticsEvent("visual_binding_bounds_frame_blocked", ["reason": "degenerate_bounds"], snapshot: true)
            return false
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "binding-bounds-frame"
        shortStatus = "RUN"
        drawVerifyStatus = "DRAW RUN"
        drawVerifyKind = "visual_binding_bounds_frame"
        drawVerifyLabel = "Binding Bounds Frame"
        drawVerifyCommandId = ""
        drawVerifyPlanHash = ""
        drawVerifyDetail = "Drawing binding bounds frame"
        statusText = drawVerifyDetail
        diagnosticsEvent(
            "visual_binding_bounds_frame_started",
            [
                "point_count": points.count,
                "min_x_mm": minX,
                "max_x_mm": maxX,
                "min_y_mm": minY,
                "max_y_mm": maxY
            ],
            snapshot: true
        )
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.drawProgram(
                BridgeDrawProgramRequest(
                    program: BridgeDrawingProgramRequest(
                        polylines: [
                            BridgePolylinePrimitiveRequest(
                                points: [
                                    BridgePaperPointNormRequest(x: 0.0, y: 0.0),
                                    BridgePaperPointNormRequest(x: 1.0, y: 0.0),
                                    BridgePaperPointNormRequest(x: 1.0, y: 1.0),
                                    BridgePaperPointNormRequest(x: 0.0, y: 1.0)
                                ],
                                role: "outline",
                                closed: true
                            )
                        ]
                    ),
                    frame: BridgeDrawingFrameRequest(
                        originXMm: minX,
                        originYMm: minY,
                        widthMm: maxX - minX,
                        heightMm: maxY - minY,
                        flipY: false
                    ),
                    includeHoming: false,
                    visualPositionTrusted: visualBindingValid,
                    drawFeedMmMin: min(machineMaxFeedMmMin, max(240.0, shapeDrawFeedMmMin)),
                    travelFeedMmMin: fastTravelFeedMmMin,
                    maxSegmentMm: 50.0,
                    maxPolylineCount: 4,
                    requestId: "binding-bounds-frame-\(UUID().uuidString.lowercased())"
                )
            )
            shortStatus = response.dryRun ? "DRY" : (response.status == "completed" ? "DONE" : "ERR")
            resetExpectedPathRole()
            expectedPathSegments = response.simulation?.previewSegments ?? []
            previewStatus = "SIM \(response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? response.summary?.drawnLengthMm ?? 0.0
            animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: min(machineMaxFeedMmMin, max(240.0, shapeDrawFeedMmMin)))
            let segments = response.summary?.drawSegmentCount ?? 0
            drawVerifyStatus = "DRAW \(response.status.uppercased())"
            drawVerifyCommandId = response.commandId
            drawVerifyDetail = "\(response.commandId) binding frame \(segments)s"
            statusText = drawVerifyDetail
            if let machineStatus = response.machineStatus {
                applyMachineStatus(machineStatus)
            } else {
                await refreshMachineStatus()
            }
            isOnline = true
            diagnosticsEvent(
                "visual_binding_bounds_frame_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "drawn_length_mm": drawnLength,
                    "draw_segment_count": segments
                ],
                snapshot: true
            )
            return response.status == "completed"
        } catch {
            shortStatus = "ERR"
            drawVerifyStatus = "DRAW ERR"
            drawVerifyDetail = error.localizedDescription
            statusText = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = true
            diagnosticsEvent("visual_binding_bounds_frame_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func previewPortraitContours(
        _ raster: FaceRasterSample,
        frame: BridgeDrawingFrameRequest,
        settings: PortraitContourSettings? = nil
    ) async -> Bool {
        let settings = settings ?? portraitContourSettings
        guard !isRunning && !isMachineBusy else { return false }
        guard isOnline else {
            imagePreviewStatus = "IMG OFF"
            imagePreviewDetail = "BRIDGE OFFLINE"
            statusText = "Bridge offline"
            diagnosticsEvent("portrait_preview_blocked", ["reason": "bridge_offline"], snapshot: true)
            return false
        }

        isCalibrating = true
        activeAction = "portrait-preview"
        imagePreviewStatus = "IMG PREVIEW"
        imagePreviewDetail = "BURST PREVIEW"
        faceContourPreviewOverlay = nil
        statusText = "Previewing portrait contours"
        diagnosticsEvent(
            "portrait_preview_started",
            [
                "raster_rows": raster.samples.count,
                "raster_columns": raster.samples.first?.count ?? 0,
                "capture_frames": raster.captureFrameCount,
                "luminance_stddev": raster.luminanceStdDev,
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
            let response = try await client.previewPortraitContours(
                BridgePortraitContourPreviewRequest(
                    raster: BridgeLuminanceRasterRequest(samples: raster.samples),
                    frame: frame,
                    options: BridgePortraitContourOptionsRequest(
                        technique: settings.technique.rawValue,
                        contourLevels: settings.contourLevels,
                        lowQuantile: settings.lowQuantile,
                        highQuantile: settings.highQuantile,
                        autoContrast: settings.autoContrast,
                        illuminationRadius: settings.illuminationRadius,
                        illuminationStrength: settings.illuminationStrength,
                        smoothingRadius: settings.smoothingRadius,
                        simplificationEpsilonNorm: settings.simplificationEpsilonNorm,
                        minContourLengthNorm: settings.minContourLengthNorm,
                        minPointsPerContour: settings.minPointsPerContour,
                        maxContours: settings.maxContours,
                        maxPoints: settings.maxPoints
                    ),
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: fastTravelFeedMmMin,
                    maxSegmentMm: 25.0
                )
            )
            resetExpectedPathRole()
            expectedPathSegments = response.simulation?.previewSegments ?? []
            let contours = response.portraitSummary?.contourCount ?? 0
            let keptPoints = response.portraitSummary?.keptPointCount ?? 0
            let segments = response.summary?.drawSegmentCount ?? 0
            imagePreviewContourCount = contours
            imagePreviewEligibleForBridgePreview = response.eligibleForBridgePreview
            faceContourPreviewOverlay = makeFaceContourPreviewOverlay(
                from: response.portraitOverlay,
                sample: raster,
                commandId: response.commandId
            ) ?? makeFallbackFaceContourPreviewOverlay(
                from: raster,
                commandId: response.commandId,
                settings: settings
            )
            imagePreviewStatus = String(format: "IMG %dC %dS", contours, segments)
            imagePreviewDetail = response.previewOnly ? "PREVIEW ONLY" : "EXECUTION"
            previewStatus = "SIM IMAGE \(response.status.uppercased())"
            let drawnLength = response.simulation?.drawnLengthMm ?? response.summary?.drawnLengthMm ?? 0.0
            revealExpectedPathImmediately(status: "FULL PREVIEW")
            statusText = "\(response.commandId) portrait contour preview"
            diagnosticsEvent(
                "portrait_preview_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "preview_only": response.previewOnly,
                    "eligible_for_bridge_preview": response.eligibleForBridgePreview,
                    "contours": contours,
                    "kept_points": keptPoints,
                    "segments": segments,
                    "preview_segments": expectedPathSegments.count,
                    "drawn_length_mm": drawnLength
                ],
                snapshot: true
            )
            return response.status == "ready"
        } catch {
            clearExpectedPathOverlay()
            faceContourPreviewOverlay = nil
            imagePreviewContourCount = 0
            imagePreviewEligibleForBridgePreview = false
            imagePreviewStatus = "IMG ERR"
            imagePreviewDetail = "VISUAL ONLY"
            previewStatus = "SIM ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("portrait_preview_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func updateLivePortraitContourPreview(
        from sample: FaceRasterSample,
        commandId providedCommandId: String? = nil,
        settings: PortraitContourSettings? = nil
    ) -> Bool {
        let settings = settings ?? portraitContourSettings
        let isCapturedPreview = providedCommandId != nil
        guard let overlay = makeFallbackFaceContourPreviewOverlay(
            from: sample,
            commandId: providedCommandId ?? "portrait-live-\(sample.frameNumber)",
            settings: settings
        ) else {
            faceContourPreviewOverlay = nil
            imagePreviewStatus = "IMG LIVE --"
            imagePreviewDetail = "NO DRAWING"
            imagePreviewContourCount = 0
            return false
        }
        faceContourPreviewOverlay = overlay
        imagePreviewStatus = isCapturedPreview
            ? String(format: "IMG %dC", overlay.contours.count)
            : String(format: "IMG LIVE %dC", overlay.contours.count)
        imagePreviewDetail = "\(isCapturedPreview ? "CAPTURE" : "LIVE") \(settings.technique.captureLabel.uppercased())"
        imagePreviewContourCount = overlay.contours.count
        imagePreviewEligibleForBridgePreview = false
        return true
    }

    func restorePortraitCapture(_ item: PortraitCaptureItem) {
        portraitContourSettings.technique = item.technique
        faceContourPreviewOverlay = item.overlay
        resetExpectedPathRole()
        expectedPathSegments = item.expectedPathSegments
        imagePreviewStatus = item.status
        imagePreviewDetail = item.detail
        imagePreviewContourCount = item.contourCount
        imagePreviewEligibleForBridgePreview = !item.expectedPathSegments.isEmpty
        revealExpectedPathImmediately(status: "FULL PREVIEW")
        diagnosticsEvent(
            "portrait_capture_restored",
            [
                "capture_id": item.id.uuidString,
                "technique": item.technique.rawValue,
                "contours": item.contourCount,
                "preview_segments": item.expectedPathSegments.count
            ],
            snapshot: true
        )
    }

    private func makeFaceContourPreviewOverlay(
        from overlay: BridgePortraitContourOverlay?,
        sample: FaceRasterSample,
        commandId: String
    ) -> FaceContourPreviewOverlay? {
        guard let overlay,
              overlay.coordinateSpace == "portrait_crop_norm",
              !overlay.contours.isEmpty else {
            return nil
        }
        let bounds = sample.faceBounds
        let contours = overlay.contours.enumerated().compactMap { index, contour -> FaceContourPreviewPolyline? in
            let points = contour.points.map { point in
                CGPoint(
                    x: bounds.minX + CGFloat(point.x) * bounds.width,
                    y: bounds.minY + CGFloat(point.y) * bounds.height
                )
            }
            guard points.count >= 2 else { return nil }
            return FaceContourPreviewPolyline(id: index, points: points, closed: contour.closed)
        }
        guard !contours.isEmpty else { return nil }
        return FaceContourPreviewOverlay(commandId: commandId, faceBounds: bounds, contours: contours)
    }

    private func makeFallbackFaceContourPreviewOverlay(
        from sample: FaceRasterSample,
        commandId: String,
        settings: PortraitContourSettings
    ) -> FaceContourPreviewOverlay? {
        guard let values = normalizedFallbackRasterValues(sample.samples, settings: settings),
              values.count >= 2,
              values[0].count >= 2 else {
            return nil
        }

        let localContours: [(points: [CGPoint], closed: Bool)]
        switch settings.technique {
        case .contours:
            localContours = fallbackContourPolylines(values: values, settings: settings)
        case .hatch:
            localContours = fallbackHatchPolylines(values: values, settings: settings, crosshatch: false)
        case .crosshatch:
            localContours = fallbackHatchPolylines(values: values, settings: settings, crosshatch: true)
        case .facets:
            localContours = fallbackFacetPolylines(values: values, settings: settings)
        case .stipple:
            localContours = fallbackStipplePolylines(values: values, settings: settings)
        }

        let minLengthNorm = settings.technique == .contours
            ? CGFloat(settings.minContourLengthNorm)
            : CGFloat(0.004)
        var contours: [FaceContourPreviewPolyline] = []

        for contour in localContours {
            guard contour.points.count >= 2,
                  fallbackPolylineLength(contour.points, closed: contour.closed) >= minLengthNorm else {
                continue
            }
            let points = contour.points.map { point in
                CGPoint(
                    x: sample.faceBounds.minX + point.x * sample.faceBounds.width,
                    y: sample.faceBounds.minY + point.y * sample.faceBounds.height
                )
            }
            contours.append(
                FaceContourPreviewPolyline(
                    id: contours.count,
                    points: points,
                    closed: contour.closed
                )
            )
            if contours.count >= settings.maxContours {
                break
            }
        }

        guard !contours.isEmpty else { return nil }
        return FaceContourPreviewOverlay(commandId: commandId, faceBounds: sample.faceBounds, contours: contours)
    }

    private func fallbackContourPolylines(
        values: [[Double]],
        settings: PortraitContourSettings
    ) -> [(points: [CGPoint], closed: Bool)] {
        var contours: [(points: [CGPoint], closed: Bool)] = []
        let minLengthNorm = CGFloat(settings.minContourLengthNorm)
        for levelIndex in 0..<settings.contourLevels {
            let level = Double(levelIndex + 1) / Double(settings.contourLevels + 1)
            for contour in fallbackContours(values: values, level: level) {
                guard contour.points.count >= settings.minPointsPerContour,
                      fallbackPolylineLength(contour.points, closed: contour.closed) >= minLengthNorm else {
                    continue
                }
                contours.append(contour)
                if contours.count >= settings.maxContours {
                    return contours
                }
            }
        }
        return contours
    }

    private func fallbackHatchPolylines(
        values: [[Double]],
        settings: PortraitContourSettings,
        crosshatch: Bool
    ) -> [(points: [CGPoint], closed: Bool)] {
        let height = values.count
        let width = values[0].count
        guard height >= 2, width >= 2 else { return [] }

        let cellWidth = CGFloat(1.0 / Double(width - 1))
        let cellHeight = CGFloat(1.0 / Double(height - 1))
        var lines: [(points: [CGPoint], closed: Bool)] = []
        for rowIndex in 0..<height {
            for columnIndex in 0..<width {
                let darkness = 1.0 - values[rowIndex][columnIndex]
                guard darkness > 0.18 else { continue }

                let density = clampDouble((darkness - 0.18) / 0.82, min: 0.0, max: 1.0)
                let skip = density > 0.72 ? 1 : density > 0.44 ? 2 : 3
                guard (rowIndex + columnIndex).isMultiple(of: skip) else { continue }

                let center = fallbackGridPoint(row: rowIndex, column: columnIndex, height: height, width: width)
                let scale = CGFloat(0.28 + 0.26 * density)
                let dx = cellWidth * scale
                let dy = cellHeight * scale
                lines.append((
                    points: [
                        fallbackClampedPoint(x: center.x - dx, y: center.y + dy),
                        fallbackClampedPoint(x: center.x + dx, y: center.y - dy)
                    ],
                    closed: false
                ))

                if crosshatch, darkness > 0.42, (rowIndex * 2 + columnIndex).isMultiple(of: max(1, skip - 1)) {
                    lines.append((
                        points: [
                            fallbackClampedPoint(x: center.x - dx, y: center.y - dy),
                            fallbackClampedPoint(x: center.x + dx, y: center.y + dy)
                        ],
                        closed: false
                    ))
                }

                if lines.count >= settings.maxContours {
                    return lines
                }
            }
        }
        return lines
    }

    private func fallbackFacetPolylines(
        values: [[Double]],
        settings: PortraitContourSettings
    ) -> [(points: [CGPoint], closed: Bool)] {
        let height = values.count
        let width = values[0].count
        guard height >= 2, width >= 2 else { return [] }

        var facets: [(points: [CGPoint], closed: Bool)] = []
        for rowIndex in 0..<(height - 1) {
            for columnIndex in 0..<(width - 1) {
                let topLeft = values[rowIndex][columnIndex]
                let topRight = values[rowIndex][columnIndex + 1]
                let bottomRight = values[rowIndex + 1][columnIndex + 1]
                let bottomLeft = values[rowIndex + 1][columnIndex]
                let local = [topLeft, topRight, bottomRight, bottomLeft]
                let avgDarkness = 1.0 - (local.reduce(0.0, +) / 4.0)
                let contrast = (local.max() ?? 0.0) - (local.min() ?? 0.0)
                guard avgDarkness > 0.22 || contrast > 0.11 else { continue }

                let p0 = fallbackGridPoint(row: rowIndex, column: columnIndex, height: height, width: width)
                let p1 = fallbackGridPoint(row: rowIndex, column: columnIndex + 1, height: height, width: width)
                let p2 = fallbackGridPoint(row: rowIndex + 1, column: columnIndex + 1, height: height, width: width)
                let p3 = fallbackGridPoint(row: rowIndex + 1, column: columnIndex, height: height, width: width)
                if topLeft + bottomRight <= topRight + bottomLeft {
                    facets.append((points: [p0, p1, p2], closed: true))
                    if avgDarkness > 0.40 || contrast > 0.18 {
                        facets.append((points: [p0, p2, p3], closed: true))
                    }
                } else {
                    facets.append((points: [p0, p1, p3], closed: true))
                    if avgDarkness > 0.40 || contrast > 0.18 {
                        facets.append((points: [p1, p2, p3], closed: true))
                    }
                }

                if facets.count >= settings.maxContours {
                    return facets
                }
            }
        }
        return facets
    }

    private func fallbackStipplePolylines(
        values: [[Double]],
        settings: PortraitContourSettings
    ) -> [(points: [CGPoint], closed: Bool)] {
        let height = values.count
        let width = values[0].count
        guard height >= 2, width >= 2 else { return [] }

        let cellWidth = CGFloat(1.0 / Double(width - 1))
        let cellHeight = CGFloat(1.0 / Double(height - 1))
        let baseRadius = min(cellWidth, cellHeight)
        var marks: [(points: [CGPoint], closed: Bool)] = []
        for rowIndex in 0..<height {
            for columnIndex in 0..<width {
                let darkness = 1.0 - values[rowIndex][columnIndex]
                guard darkness > 0.24 else { continue }

                let density = clampDouble((darkness - 0.24) / 0.76, min: 0.0, max: 1.0)
                let skip = density > 0.78 ? 2 : density > 0.48 ? 3 : 4
                guard (rowIndex * 5 + columnIndex * 3).isMultiple(of: skip) else { continue }

                let center = fallbackGridPoint(row: rowIndex, column: columnIndex, height: height, width: width)
                let radius = baseRadius * CGFloat(0.16 + 0.26 * density)
                marks.append((
                    points: [
                        fallbackClampedPoint(x: center.x, y: center.y + radius),
                        fallbackClampedPoint(x: center.x + radius, y: center.y),
                        fallbackClampedPoint(x: center.x, y: center.y - radius),
                        fallbackClampedPoint(x: center.x - radius, y: center.y)
                    ],
                    closed: true
                ))

                if marks.count >= settings.maxContours {
                    return marks
                }
            }
        }
        return marks
    }

    private func fallbackGridPoint(row: Int, column: Int, height: Int, width: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(column) / CGFloat(max(width - 1, 1)),
            y: 1.0 - CGFloat(row) / CGFloat(max(height - 1, 1))
        )
    }

    private func fallbackClampedPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(
            x: CGFloat(clampDouble(Double(x), min: 0.0, max: 1.0)),
            y: CGFloat(clampDouble(Double(y), min: 0.0, max: 1.0))
        )
    }

    private func normalizedFallbackRasterValues(
        _ samples: [[Double]],
        settings: PortraitContourSettings
    ) -> [[Double]]? {
        let flat = samples.flatMap { row in row.filter(\.isFinite) }
        guard flat.count >= 4 else { return nil }
        let sorted = flat.sorted()
        let low = percentile(sorted, quantile: settings.lowQuantile)
        let high = percentile(sorted, quantile: settings.highQuantile)
        guard high - low > 0.0001 else { return nil }
        let normalized = samples.map { row in
            row.map { value in
                clampDouble((value - low) / (high - low), min: 0.0, max: 1.0)
            }
        }
        return smoothFallbackRasterValues(normalized, radius: settings.smoothingRadius)
    }

    private func smoothFallbackRasterValues(_ values: [[Double]], radius: Int) -> [[Double]] {
        guard radius > 0, !values.isEmpty, !values[0].isEmpty else { return values }
        let height = values.count
        let width = values[0].count
        return values.indices.map { rowIndex in
            values[rowIndex].indices.map { columnIndex in
                var total = 0.0
                var count = 0.0
                for sourceRow in max(0, rowIndex - radius)...min(height - 1, rowIndex + radius) {
                    for sourceColumn in max(0, columnIndex - radius)...min(width - 1, columnIndex + radius) {
                        total += values[sourceRow][sourceColumn]
                        count += 1.0
                    }
                }
                return total / max(count, 1.0)
            }
        }
    }

    private func percentile(_ sorted: [Double], quantile: Double) -> Double {
        guard let first = sorted.first else { return 0.0 }
        guard sorted.count > 1 else { return first }
        let position = clampDouble(quantile, min: 0.0, max: 1.0) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sorted[lower]
        }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private func fallbackContours(
        values: [[Double]],
        level: Double
    ) -> [(points: [CGPoint], closed: Bool)] {
        let height = values.count
        let width = values[0].count
        guard height >= 2, width >= 2 else { return [] }

        var segments: [(CGPoint, CGPoint)] = []
        for rowIndex in 0..<(height - 1) {
            for columnIndex in 0..<(width - 1) {
                let x0 = CGFloat(columnIndex) / CGFloat(width - 1)
                let x1 = CGFloat(columnIndex + 1) / CGFloat(width - 1)
                let yTop = 1.0 - CGFloat(rowIndex) / CGFloat(height - 1)
                let yBottom = 1.0 - CGFloat(rowIndex + 1) / CGFloat(height - 1)
                let corners = [
                    (CGPoint(x: x0, y: yTop), values[rowIndex][columnIndex]),
                    (CGPoint(x: x1, y: yTop), values[rowIndex][columnIndex + 1]),
                    (CGPoint(x: x1, y: yBottom), values[rowIndex + 1][columnIndex + 1]),
                    (CGPoint(x: x0, y: yBottom), values[rowIndex + 1][columnIndex])
                ]
                let edges = [
                    (corners[0], corners[1]),
                    (corners[1], corners[2]),
                    (corners[2], corners[3]),
                    (corners[3], corners[0])
                ]
                let points = fallbackDedupePoints(edges.compactMap { edge in
                    fallbackEdgeCrossing(edge.0, edge.1, level: level)
                })
                if points.count == 2 {
                    segments.append((points[0], points[1]))
                } else if points.count == 4 {
                    segments.append((points[0], points[1]))
                    segments.append((points[2], points[3]))
                }
            }
        }
        return fallbackStitchSegments(segments)
    }

    private func fallbackEdgeCrossing(
        _ start: (CGPoint, Double),
        _ end: (CGPoint, Double),
        level: Double
    ) -> CGPoint? {
        guard start.1 != end.1,
              (start.1 < level && level <= end.1) || (end.1 < level && level <= start.1) else {
            return nil
        }
        let fraction = CGFloat((level - start.1) / (end.1 - start.1))
        return CGPoint(
            x: start.0.x + fraction * (end.0.x - start.0.x),
            y: start.0.y + fraction * (end.0.y - start.0.y)
        )
    }

    private func fallbackDedupePoints(_ points: [CGPoint]) -> [CGPoint] {
        var seen: Set<String> = []
        var unique: [CGPoint] = []
        for point in points {
            let key = fallbackPointKey(point)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(point)
        }
        return unique
    }

    private func fallbackStitchSegments(_ segments: [(CGPoint, CGPoint)]) -> [(points: [CGPoint], closed: Bool)] {
        var unused = segments
        var contours: [(points: [CGPoint], closed: Bool)] = []
        while let segment = unused.popLast() {
            var points = [segment.0, segment.1]
            var changed = true
            while changed {
                changed = false
                for index in unused.indices {
                    let candidate = unused[index]
                    if fallbackSamePoint(candidate.1, points[0]) {
                        points.insert(candidate.0, at: 0)
                    } else if fallbackSamePoint(candidate.0, points[0]) {
                        points.insert(candidate.1, at: 0)
                    } else if fallbackSamePoint(candidate.0, points[points.count - 1]) {
                        points.append(candidate.1)
                    } else if fallbackSamePoint(candidate.1, points[points.count - 1]) {
                        points.append(candidate.0)
                    } else {
                        continue
                    }
                    unused.remove(at: index)
                    changed = true
                    break
                }
            }

            let closed = points.count > 2 && fallbackSamePoint(points[0], points[points.count - 1])
            if closed {
                points.removeLast()
            }
            contours.append((points: points, closed: closed))
        }
        return contours
    }

    private func fallbackSamePoint(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        fallbackPointKey(lhs) == fallbackPointKey(rhs)
    }

    private func fallbackPointKey(_ point: CGPoint) -> String {
        "\(Int((point.x * 1_000_000).rounded())):\(Int((point.y * 1_000_000).rounded()))"
    }

    private func fallbackPolylineLength(_ points: [CGPoint], closed: Bool) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var length: CGFloat = 0
        for index in 1..<points.count {
            length += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        if closed, let first = points.first, let last = points.last {
            length += hypot(first.x - last.x, first.y - last.y)
        }
        return length
    }

    func replayExpectedPath() {
        let length = expectedPathSegments.reduce(0.0) { partial, segment in
            partial + segment.lengthMm
        }
        animateExpectedPath(drawnLengthMm: length, feedMmMin: shapeDrawFeedMmMin)
        diagnosticsEvent("expected_path_replayed", ["length_mm": length, "segments": expectedPathSegments.count], snapshot: true)
    }

    func showSetupFieldFrameExpectedPath(corners: [PaperPointMmSnapshot]) {
        guard corners.count >= 4, visualFieldWidthMm > 0, visualFieldHeightMm > 0 else {
            clearExpectedPathOverlay()
            return
        }
        let closed = Array(corners.prefix(4)) + [corners[0]]
        expectedPathSegments = zip(closed, closed.dropFirst()).map { start, end in
            ExpectedPathSegment(
                startNorm: [
                    start.x / visualFieldWidthMm,
                    start.y / visualFieldHeightMm
                ],
                endNorm: [
                    end.x / visualFieldWidthMm,
                    end.y / visualFieldHeightMm
                ],
                startMachineMm: [],
                endMachineMm: [],
                lengthMm: hypot(end.x - start.x, end.y - start.y)
            )
        }
        expectedPathRole = "setup_field_frame"
        expectedPathLabel = "Expected frame"
        observedDrawingFrameOverlay = nil
        updatePredictedDrawingProgramOverlay()
        pathRevealProgress = 1.0
        pathAnimationStatus = "FRAME"
        previewStatus = "SIM FRAME"
        diagnosticsEvent(
            "setup_field_frame_expected_path_ready",
            [
                "segments": expectedPathSegments.count,
                "field_width_mm": visualFieldWidthMm,
                "field_height_mm": visualFieldHeightMm
            ],
            snapshot: true
        )
    }

    func clearExpectedPathOverlay() {
        expectedPathSegments = []
        predictedPathSegments = []
        resetExpectedPathRole()
        pathRevealProgress = 1.0
        pathAnimationStatus = "IDLE"
    }

    private func resetExpectedPathRole() {
        expectedPathRole = ""
        expectedPathLabel = "EXPECTED"
        predictedPathLabel = "Model-corrected frame"
        observedDrawingFrameOverlay = nil
    }

    func jog(axis: String, distanceMm: Double) async {
        await runMachineCommand(action: manualJogWorkspaceOverride ? "jog override" : "jog") {
            try await client.jog(
                MachineJogRequest(
                    axis: axis,
                    distanceMm: distanceMm,
                    feedMmMin: manualFeedMmMin,
                    bypassWorkspaceProjection: manualJogWorkspaceOverride
                )
            )
        }
    }

    func setManualJogWorkspaceOverride(_ enabled: Bool) {
        guard manualJogWorkspaceOverride != enabled else { return }
        manualJogWorkspaceOverride = enabled
        shortStatus = enabled ? "OVRD" : (isLiveMotionMode ? "LIVE" : shortStatus)
        statusText = enabled
            ? "Manual jog workspace projection override enabled"
            : "Manual jog workspace projection override disabled"
        diagnosticsEvent(
            "manual_jog_workspace_override_changed",
            ["enabled": enabled],
            snapshot: true
        )
    }

    func setupCalibrationJog(axis: String, distanceMm: Double, feedMmMin: Double) async -> MachineCommandResponse? {
        guard canRunSetupRelativeMotionCommand else {
            blockSetupRelativeMotionCommand(
                event: "setup_calibration_jog_blocked",
                details: ["axis": axis, "distance_mm": distanceMm]
            )
            return nil
        }

        guard await waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for calibration move"
            return nil
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks calibration move"
            return nil
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "calibrate"
        shortStatus = "RUN"
        statusText = String(format: "Calibrate %@ %.1fmm", axis, distanceMm)
        diagnosticsEvent(
            "setup_calibration_jog_started",
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
                    feedMmMin: feedMmMin,
                    bypassWorkspaceProjection: true
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
                "setup_calibration_jog_completed",
                commandPayload(response).merging(["axis": axis, "distance_mm": distanceMm]) { current, _ in current },
                snapshot: true
            )
            return response
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = error.localizedDescription.localizedCaseInsensitiveContains("alarm")
            diagnosticsEvent(
                "setup_calibration_jog_failed",
                errorPayload(error).merging(["axis": axis, "distance_mm": distanceMm]) { current, _ in current },
                snapshot: true
            )
            return nil
        }
    }

    func setupRelativeMove(
        xMm: Double,
        yMm: Double,
        feedMmMin: Double,
        ensurePenUp: Bool,
        actionLabel: String
    ) async -> MachineCommandResponse? {
        guard canRunSetupRelativeMotionCommand else {
            blockSetupRelativeMotionCommand(
                event: "setup_relative_move_blocked",
                details: ["x_mm": xMm, "y_mm": yMm, "action_label": actionLabel]
            )
            return nil
        }

        guard await waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: 18.0) else {
            statusText = "Machine did not become ready for setup move"
            return nil
        }
        guard !isMachineAlarm else {
            statusText = "Machine alarm blocks setup move"
            return nil
        }

        isRunning = true
        isMachineBusy = true
        activeAction = actionLabel
        shortStatus = "RUN"
        statusText = String(format: "Setup move X%.2f Y%.2f", xMm, yMm)
        diagnosticsEvent(
            "setup_relative_move_started",
            [
                "x_mm": xMm,
                "y_mm": yMm,
                "feed_mm_min": feedMmMin,
                "ensure_pen_up": ensurePenUp,
                "action_label": actionLabel
            ],
            snapshot: true
        )
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
                    ensurePenUp: ensurePenUp,
                    bypassWorkspaceProjection: true
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
            diagnosticsEvent("setup_relative_move_completed", commandPayload(response), snapshot: true)
            return response
        } catch {
            shortStatus = "ERR"
            statusText = error.localizedDescription
            machineStatus = error.localizedDescription
            isMachineBusy = false
            isMachineAlarm = error.localizedDescription.localizedCaseInsensitiveContains("alarm")
            diagnosticsEvent(
                "setup_relative_move_failed",
                errorPayload(error).merging(["x_mm": xMm, "y_mm": yMm, "action_label": actionLabel]) { current, _ in current },
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
                x: min(1.0, max(0.0, paperMm.x / max(visualFieldWidthMm, 0.000_001))),
                y: min(1.0, max(0.0, paperMm.y / max(visualFieldHeightMm, 0.000_001)))
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
            latestVisualReadiness = response.readiness
            statusText = visualProbeProgressStatusText(
                prefix: adaptiveProbeStatus,
                readiness: response.readiness,
                fallback: adaptiveProbeStatus
            )
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

    func observeVisualProbeSample(_ request: BridgeVisualProbeSampleRequest) async -> Bool {
        do {
            let response = try await client.observeVisualProbeSample(request)
            isOnline = true
            adaptiveProbeStatus = response.status == "accepted" ? "PROBE EVID OK" : "PROBE EVID \(response.status.uppercased())"
            latestVisualReadiness = response.readiness
            if let error = response.error {
                statusText = error
            } else if response.status == "accepted" {
                statusText = visualProbeProgressStatusText(
                    prefix: adaptiveProbeStatus,
                    readiness: response.readiness,
                    fallback: adaptiveProbeStatus
                )
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

    private func visualReadinessWorkflowStatusText(
        status: String,
        readiness: BridgeVisualReadinessState?,
        workflow: BridgeCalibrationWorkflow?,
        fallback: String
    ) -> String {
        if let workflow {
            let action = workflow.nextPrimaryAction
            if workflow.readyToDraw {
                return "READY to draw"
            }
            if let blocker = workflow.currentBlocker, !blocker.isEmpty {
                return "SETUP \(workflow.phase)/\(workflow.activity): \(action.label); \(blocker)"
            }
            return "SETUP \(workflow.phase)/\(workflow.activity): \(action.label)"
        }
        if status == "ready" || readiness?.visualReadyToPlot == true {
            return visualProbeProgressStatusText(
                prefix: "PROBE READY",
                readiness: readiness,
                fallback: "PROBE READY"
            )
        }
        if let blocker = readiness?.blockers.first {
            return blocker
        }
        return fallback
    }

    private func visualProbeProgressStatusText(
        prefix: String,
        readiness: BridgeVisualReadinessState?,
        fallback: String
    ) -> String {
        guard let readiness else { return fallback }
        if readiness.visualReadyToPlot {
            if let model = readiness.relativeMotionModel {
                return String(
                    format: "%@; motion ready rms %.1f max %.1f samples %d",
                    prefix,
                    model.rmsResidualMm,
                    model.maxResidualMm,
                    model.sampleCount
                )
            }
            return "\(prefix); motion ready"
        }

        var parts = [prefix]
        let sampleCount = readiness.probeObservationCount
        if sampleCount > 0 {
            parts.append("\(sampleCount) accepted \(sampleCount == 1 ? "sample" : "samples")")
            let axes = Set((readiness.probeAxesRepresented ?? []).map { $0.uppercased() })
            if axes.contains("X") && axes.contains("Y") {
                parts.append("axes X/Y")
            } else if axes.contains("X") {
                parts.append("axis X; collecting Y")
            } else if axes.contains("Y") {
                parts.append("axis Y; collecting X")
            } else {
                parts.append("collecting X/Y")
            }
        } else if readiness.capLocalized {
            parts.append("cap localized; collecting motion samples")
        } else if readiness.paperRegistered {
            parts.append("field locked; cap observation needed")
        } else {
            parts.append("field registration needed")
        }

        let rejectedCount = readiness.probeRejectedSampleCount ?? 0
        let staleCount = readiness.probeStaleSampleCount ?? 0
        if rejectedCount > 0 || staleCount > 0 {
            parts.append("rejected \(rejectedCount) stale \(staleCount)")
        }
        return parts.joined(separator: "; ")
    }

    func visualRelativeMove(xMm: Double, yMm: Double, feedMmMin: Double) async -> MachineCommandResponse? {
        guard canRunLiveRelativeMotionCommand else {
            blockLiveRelativeMotionCommand(
                event: "visual_relative_move_blocked",
                details: ["x_mm": xMm, "y_mm": yMm]
            )
            return nil
        }

        guard await waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: 18.0) else {
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
        guard canRunLiveRelativeMotionCommand else {
            blockLiveRelativeMotionCommand(event: "dot_mark_blocked")
            return false
        }

        guard await waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: 18.0) else {
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
        guard canRunLiveRelativeMotionCommand else {
            blockLiveRelativeMotionCommand(
                event: "relative_mark_blocked",
                details: ["mark_size_mm": markSizeMm, "draw_feed_mm_min": drawFeedMmMin]
            )
            return false
        }

        guard await waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: 18.0) else {
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
                    travelFeedMmMin: fastTravelFeedMmMin
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

    func waitUntilMachineReadyForCalibrationMotion(timeoutSeconds: Double) async -> Bool {
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
        samples: [MotionCalibrationSample],
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

    func registerPaperHomography(
        fiducials: [ManualFiducialPoint],
        paperWidthMm: Double,
        paperHeightMm: Double
    ) async -> PaperRegistrationResponse? {
        guard !isCalibrating else { return nil }
        guard isOnline else {
            paperTransformStatus = "FIELD OFF"
            statusText = "Bridge offline"
            return nil
        }
        guard fiducials.count >= 4 else {
            paperTransformStatus = "FIELD NEED 4"
            statusText = "Need generated drawing field corners"
            return nil
        }

        let ordered = Array(fiducials.prefix(4))
        let cornerNames = ["bottom_left", "bottom_right", "top_right", "top_left"]
        isCalibrating = true
        activeAction = "paper"
        paperTransformStatus = "FIELD SOLVE"
        statusText = "Locking visual field"
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
                statusText = "Field \(registration.registrationId) locked"
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
            paperTransformStatus = "FIELD ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("paper_registration_failed", errorPayload(error), snapshot: true)
            return nil
        }
    }

    func previewBindingMarks(pointSet: String = "five") async -> BindingMarkPreviewResponse? {
        guard !isCalibrating else { return nil }
        guard isOnline else {
            bindingMarkPreviewStatus = "BIND OFF"
            statusText = "Bridge offline"
            diagnosticsEvent("binding_mark_preview_blocked", ["point_set": pointSet, "reason": "bridge_offline"], snapshot: true)
            return nil
        }
        if !hasPaperLock {
            await refreshPaperStatus()
            if !hasPaperLock {
                bindingMarkPreviewStatus = "BIND NEED FIELD"
                statusText = "Visual field required"
                diagnosticsEvent("binding_mark_preview_blocked", ["point_set": pointSet, "reason": "visual_field_required"], snapshot: true)
                return nil
            }
        }

        isCalibrating = true
        activeAction = "binding-preview"
        bindingMarkPreviewStatus = "BIND MARKS"
        statusText = "Previewing binding mark overlay"
        diagnosticsEvent("binding_mark_preview_started", ["point_set": pointSet], snapshot: true)
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewBindingMarks(
                BindingMarkPreviewRequest(
                    pointSet: pointSet,
                    marginMm: nil,
                    markSizeMm: 6.0,
                    maxMarkSizeMm: bindingMaxMarkSizeMm,
                    extraPaddingMm: bindingExtraPaddingMm,
                    parkClearanceMm: bindingParkClearanceMm,
                    observationClearanceMm: bindingObservationClearanceMm,
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: fastTravelFeedMmMin,
                    maxSegmentMm: 25.0
                )
            )
            bindingMarkPreviewPoints = response.points
            bindingMarkPreviewSegments = response.cameraSegments
            bindingMarkPreviewCommandId = response.commandId
            bindingMarkPreviewPlanHash = response.planHash
            bindingMarkPreviewPointSet = response.pointSet
            drawableSafeZone = response.safeZone
            clearExpectedPathOverlay()
            bindingMarkPreviewStatus = String(
                format: "BIND %@ %dP %dS %@",
                response.pointSet.uppercased(),
                response.pointCount,
                response.cameraSegments.count,
                String(response.planHash.prefix(6))
            )
            statusText = "\(response.commandId) preview \(response.pointSet)"
            diagnosticsEvent(
                "binding_mark_preview_completed",
                [
                    "command_id": response.commandId,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "point_set": response.pointSet,
                    "point_count": response.pointCount,
                    "segment_count": response.cameraSegments.count,
                    "plan_hash_prefix": String(response.planHash.prefix(8))
                ],
                snapshot: true
            )
            return response
        } catch {
            bindingMarkPreviewPoints = []
            bindingMarkPreviewSegments = []
            bindingMarkPreviewCommandId = ""
            bindingMarkPreviewPlanHash = ""
            bindingMarkPreviewPointSet = ""
            bindingMarkPreviewStatus = "BIND ERR"
            statusText = error.localizedDescription
            diagnosticsEvent("binding_mark_preview_failed", ["point_set": pointSet, "error": error.localizedDescription], snapshot: true)
            return nil
        }
    }

    func clearBindingMarkPreviewOverlay() {
        bindingMarkPreviewPoints = []
        bindingMarkPreviewSegments = []
        bindingMarkPreviewCommandId = ""
        bindingMarkPreviewPlanHash = ""
        bindingMarkPreviewPointSet = ""
        bindingMarkPreviewStatus = "BIND --"
        diagnosticsEvent("binding_mark_preview_cleared", snapshot: true)
    }

    func refreshVisualBindingStatus() async {
        guard isOnline else {
            visualBindingStatus = "BIND OFF"
            visualBindingDetail = "Bridge offline"
            visualBindingValid = false
            return
        }
        do {
            let response = try await client.visualPositionBindingStatus()
            applyVisualBindingStatus(response)
            diagnosticsEvent(
                "visual_binding_status_refreshed",
                [
                    "status": response.status,
                    "observation_count": response.binding?.residuals.observationCount ?? 0,
                    "validation_status": response.binding?.validationStatus ?? "",
                    "valid": visualBindingValid
                ],
                snapshot: false
            )
        } catch {
            visualBindingStatus = "BIND ERR"
            visualBindingDetail = error.localizedDescription
            visualBindingValid = false
            diagnosticsEvent("visual_binding_status_failed", errorPayload(error), snapshot: false)
        }
    }

    func refreshDrawingCalibrationStatus() async -> BridgeDrawingCalibrationModel? {
        guard isOnline else {
            drawingCalibrationStatus = "DRAW CAL OFF"
            drawingCalibrationDetail = "Bridge offline"
            latestDrawingCalibration = nil
            return nil
        }
        do {
            let response = try await client.drawingCalibrationStatus()
            applyDrawingCalibrationResponse(response)
            diagnosticsEvent(
                "drawing_model_refreshed",
                [
                    "status": response.status,
                    "model_id": response.calibration?.modelId ?? "",
                    "solver_kind": response.calibration?.solverKind ?? "",
                    "usable_observations": response.calibration?.usableObservationCount ?? 0,
                    "blockers": response.calibration?.blockers ?? []
                ],
                snapshot: false
            )
            return response.calibration
        } catch {
            drawingCalibrationStatus = "DRAW CAL ERR"
            drawingCalibrationDetail = error.localizedDescription
            latestDrawingCalibration = nil
            updatePredictedDrawingProgramOverlay()
            diagnosticsEvent("drawing_model_refresh_failed", errorPayload(error), snapshot: false)
            return nil
        }
    }

    func refreshDrawingCalibrationSessionStatus() async {
        guard isOnline else {
            drawingCalibrationSessionStatus = "SESSION OFF"
            drawingCalibrationSessionDetail = "Bridge offline"
            latestDrawingCalibrationSession = nil
            currentDrawingCalibrationBatch = nil
            return
        }
        do {
            let response = try await client.drawingCalibrationSessionStatus()
            applyDrawingCalibrationSessionStatus(response)
            diagnosticsEvent(
                "drawing_calibration_session_refreshed",
                [
                    "status": response.status,
                    "session_id": response.session?.sessionId ?? "",
                    "batch_id": response.session?.currentBatchId ?? "",
                    "blockers": response.session?.blockers ?? []
                ],
                snapshot: false
            )
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_session_refresh_failed", errorPayload(error), snapshot: false)
        }
    }

    func startProgressiveDrawingCalibrationSession(penReadyConfirmed: Bool = true) async {
        guard isOnline else {
            drawingCalibrationSessionStatus = "SESSION OFF"
            drawingCalibrationSessionDetail = "Bridge offline"
            return
        }
        do {
            let response = try await client.startDrawingCalibrationSession(
                BridgeDrawingCalibrationSessionStartRequest(
                    penReadyConfirmed: penReadyConfirmed,
                    penReadyConfirmation: [
                        "source": "operator_confirmed",
                        "surface": "calibration_wizard"
                    ],
                    requestId: "swift-confirm-pen-ready"
                )
            )
            applyDrawingCalibrationSessionResponse(response)
            diagnosticsEvent("drawing_calibration_session_started", drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_session_start_failed", errorPayload(error), snapshot: true)
        }
    }

    func previewNextProgressiveDrawingCalibrationBatch() async {
        do {
            let response = try await client.previewNextDrawingCalibrationBatch(
                drawingSessionBatchRequest(requestId: "swift-preview-drawing-batch")
            )
            applyDrawingCalibrationSessionResponse(response)
            if let preview = response.preview {
                publishDrawingCalibrationBatchOverlay(preview, label: "Expected batch")
            }
            diagnosticsEvent("drawing_calibration_batch_previewed", drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_batch_preview_failed", errorPayload(error), snapshot: true)
        }
    }

    func runProgressiveDrawingCalibrationBatch() async {
        do {
            let response = try await client.runDrawingCalibrationBatch(
                drawingSessionBatchRequest(
                    expectedPlanHash: currentDrawingCalibrationBatch?.planHash
                        ?? latestDrawingCalibrationBatchPreview?.planHash,
                    requestId: "swift-run-drawing-batch"
                )
            )
            applyDrawingCalibrationSessionResponse(response)
            if let run = response.run {
                publishDrawingCalibrationBatchOverlay(run, label: "Expected batch")
            }
            diagnosticsEvent("drawing_calibration_batch_run", drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_batch_run_failed", errorPayload(error), snapshot: true)
        }
    }

    func recordProgressiveDrawingCalibrationObservation(_ result: InkProgramInspectionResult) async {
        guard let session = latestDrawingCalibrationSession,
              let batch = currentDrawingCalibrationBatch else {
            drawingCalibrationSessionStatus = "SESSION BLOCK"
            drawingCalibrationSessionDetail = "No active drawing calibration batch"
            return
        }
        do {
            let response = try await client.observeDrawingCalibrationBatch(
                BridgeDrawingProgramObservationRequest(
                    commandId: latestDrawingCalibrationBatchRun?.commandId
                        ?? latestDrawingCalibrationBatchPreview?.commandId,
                    paperRegistrationId: session.paperRegistrationId,
                    cameraId: session.cameraId,
                    cameraName: session.cameraName,
                    programId: batch.batchId,
                    programKind: batch.programKind,
                    sessionId: session.sessionId,
                    batchId: batch.batchId,
                    runId: latestDrawingCalibrationBatchRun?.commandId,
                    planHash: latestDrawingCalibrationBatchRun?.planHash
                        ?? latestDrawingCalibrationBatchPreview?.planHash,
                    correctionMode: batch.correctionMode,
                    modelIdUsed: batch.modelIdUsed,
                    expectedFrameCornersMm: nil,
                    primitives: result.primitives.map { primitive in
                        BridgeDrawingProgramPrimitiveObservationRequest(
                            primitiveId: primitive.primitiveId,
                            primitiveKind: primitive.kind.rawValue,
                            sampleCount: primitive.sampleCount,
                            detectedSampleCount: primitive.detectedSampleCount,
                            greenPixelCount: primitive.greenPixelCount,
                            coverageFraction: primitive.coverageFraction,
                            rmsResidualMm: primitive.rmsResidualMm,
                            p95ResidualMm: primitive.p95ResidualMm,
                            maxResidualMm: primitive.maxResidualMm
                        )
                    },
                    samples: result.samples.map { sample in
                        BridgeDrawingProgramSampleObservationRequest(
                            primitiveId: sample.primitiveId,
                            sampleIndex: sample.sampleIndex,
                            expectedMm: sample.expectedMm,
                            expectedCameraNorm: sample.expectedCameraNorm,
                            observedMm: sample.observedMm,
                            observedCameraNorm: sample.observedCameraNorm,
                            residualMm: sample.residualMm,
                            detected: sample.detected,
                            greenPixelCount: sample.greenPixelCount
                        )
                    },
                    sampleCount: result.sampleCount,
                    detectedSampleCount: result.detectedSampleCount,
                    totalGreenPixels: result.totalGreenPixels,
                    coverageFraction: result.coverageFraction,
                    rmsResidualMm: result.rmsResidualMm,
                    p95ResidualMm: result.p95ResidualMm,
                    maxResidualMm: result.maxResidualMm,
                    usable: result.isUsable
                )
            )
            applyDrawingCalibrationSessionResponse(response)
            diagnosticsEvent("drawing_calibration_batch_observed", drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_batch_observe_failed", errorPayload(error), snapshot: true)
        }
    }

    func recordWeakProgressiveDrawingCalibrationObservation(reason: String) async {
        guard let session = latestDrawingCalibrationSession,
              let batch = currentDrawingCalibrationBatch else {
            drawingCalibrationSessionStatus = "SESSION BLOCK"
            drawingCalibrationSessionDetail = "No active drawing calibration batch"
            return
        }
        do {
            let response = try await client.observeDrawingCalibrationBatch(
                BridgeDrawingProgramObservationRequest(
                    commandId: latestDrawingCalibrationBatchRun?.commandId
                        ?? latestDrawingCalibrationBatchPreview?.commandId,
                    paperRegistrationId: session.paperRegistrationId,
                    cameraId: session.cameraId,
                    cameraName: session.cameraName,
                    programId: batch.batchId,
                    programKind: batch.programKind,
                    sessionId: session.sessionId,
                    batchId: batch.batchId,
                    runId: latestDrawingCalibrationBatchRun?.commandId,
                    planHash: latestDrawingCalibrationBatchRun?.planHash
                        ?? latestDrawingCalibrationBatchPreview?.planHash,
                    correctionMode: batch.correctionMode,
                    modelIdUsed: batch.modelIdUsed,
                    expectedFrameCornersMm: nil,
                    primitives: [],
                    samples: [],
                    sampleCount: 0,
                    detectedSampleCount: 0,
                    totalGreenPixels: 0,
                    coverageFraction: 0,
                    rmsResidualMm: nil,
                    p95ResidualMm: nil,
                    maxResidualMm: nil,
                    usable: false,
                    blockers: [reason]
                )
            )
            applyDrawingCalibrationSessionResponse(response)
            diagnosticsEvent("drawing_calibration_batch_weak_observation", drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("drawing_calibration_batch_weak_observation_failed", errorPayload(error), snapshot: true)
        }
    }

    func fitProgressiveDrawingCalibrationSession() async {
        await runDrawingSessionAction(
            requestId: "swift-fit-drawing-session",
            eventName: "drawing_calibration_session_fit",
            action: client.fitDrawingCalibrationSession
        )
    }

    func validateProgressiveDrawingCalibrationSession() async {
        await runDrawingSessionAction(
            requestId: "swift-validate-drawing-session",
            eventName: "drawing_calibration_session_validate",
            action: client.validateDrawingCalibrationSession
        )
    }

    func finishProgressiveDrawingCalibrationSession() async {
        await runDrawingSessionAction(
            requestId: "swift-finish-drawing-session",
            eventName: "drawing_calibration_session_finish",
            action: client.finishDrawingCalibrationSession
        )
    }

    func recordDrawingFrameInspection(
        _ result: DrawnFrameInspectionResult,
        expectedCorners: [PaperPointMmSnapshot],
        registration: PaperRegistrationSnapshot,
        commandId: String?
    ) async -> BridgeDrawingCalibrationModel? {
        observedDrawingFrameOverlay = DrawingFrameOverlay(
            expectedCornersMm: expectedCorners,
            observedCornersMm: result.corners.map(\.observedMm),
            observedEdges: result.edges.compactMap { edge in
                guard let start = edge.observedStartMm,
                      let end = edge.observedEndMm else {
                    return nil
                }
                return DrawingFrameObservedEdgeOverlay(
                    edgeIndex: edge.edgeIndex,
                    observedStartMm: start,
                    observedEndMm: end
                )
            },
            detectedEdgeCount: result.detectedEdgeCount,
            rmsResidualMm: result.rmsResidualMm,
            maxResidualMm: result.maxResidualMm,
            status: result.summary
        )
        guard isOnline else {
            drawingCalibrationStatus = "DRAW CAL OFF"
            drawingCalibrationDetail = "Observed frame overlay only; bridge offline"
            return nil
        }
        do {
            let response = try await client.observeDrawingProgram(
                BridgeDrawingProgramObservationRequest(
                    commandId: commandId,
                    paperRegistrationId: registration.registrationId,
                    cameraId: "plotter-camera",
                    cameraName: "Plotter Camera",
                    programId: result.program.programId,
                    programKind: result.program.programKind,
                    expectedFrameCornersMm: expectedCorners,
                    primitives: result.program.primitives.map { primitive in
                        BridgeDrawingProgramPrimitiveObservationRequest(
                            primitiveId: primitive.primitiveId,
                            primitiveKind: primitive.kind.rawValue,
                            sampleCount: primitive.sampleCount,
                            detectedSampleCount: primitive.detectedSampleCount,
                            greenPixelCount: primitive.greenPixelCount,
                            coverageFraction: primitive.coverageFraction,
                            rmsResidualMm: primitive.rmsResidualMm,
                            p95ResidualMm: primitive.p95ResidualMm,
                            maxResidualMm: primitive.maxResidualMm
                        )
                    },
                    samples: result.program.samples.map { sample in
                        BridgeDrawingProgramSampleObservationRequest(
                            primitiveId: sample.primitiveId,
                            sampleIndex: sample.sampleIndex,
                            expectedMm: sample.expectedMm,
                            expectedCameraNorm: sample.expectedCameraNorm,
                            observedMm: sample.observedMm,
                            observedCameraNorm: sample.observedCameraNorm,
                            residualMm: sample.residualMm,
                            detected: sample.detected,
                            greenPixelCount: sample.greenPixelCount
                        )
                    },
                    sampleCount: result.program.sampleCount,
                    detectedSampleCount: result.program.detectedSampleCount,
                    totalGreenPixels: result.program.totalGreenPixels,
                    coverageFraction: result.program.coverageFraction,
                    rmsResidualMm: result.program.rmsResidualMm,
                    p95ResidualMm: result.program.p95ResidualMm,
                    maxResidualMm: result.program.maxResidualMm,
                    usable: result.isUsable
                )
            )
            applyDrawingCalibrationResponse(response)
            diagnosticsEvent(
                "drawing_program_observation_recorded",
                [
                    "status": response.status,
                    "observation_id": response.observationId ?? "",
                    "model_id": response.calibration?.modelId ?? "",
                    "solver_kind": response.calibration?.solverKind ?? "",
                    "program_id": result.program.programId,
                    "program_kind": result.program.programKind,
                    "sample_count": result.program.sampleCount,
                    "detected_samples": result.program.detectedSampleCount,
                    "detected_edges": result.detectedEdgeCount,
                    "usable": result.isUsable,
                    "blockers": response.calibration?.blockers ?? []
                ],
                snapshot: true
            )
            return response.calibration
        } catch {
            diagnosticsEvent(
                "drawing_program_observation_failed",
                errorPayload(error).merging(["fallback_route": "calibration/drawing/frame-observation"]) { current, _ in current },
                snapshot: true
            )
            return await recordLegacyDrawingFrameInspection(
                result,
                expectedCorners: expectedCorners,
                registration: registration,
                commandId: commandId
            )
        }
    }

    private func applyDrawingCalibrationResponse(_ response: BridgeDrawingCalibrationResponse) {
        latestDrawingCalibration = response.calibration
        updatePredictedDrawingProgramOverlay()
        guard let calibration = response.calibration else {
            drawingCalibrationStatus = response.status == "missing" ? "DRAW CAL --" : "DRAW CAL ERR"
            drawingCalibrationDetail = response.error ?? "No drawing calibration"
            return
        }
        drawingCalibrationStatus = "DRAW CAL \(calibration.statusLabel)"
        let residual = calibration.rmsResidualMm.map { String(format: "rms %.1fmm", $0) } ?? "rms --"
        let maxResidual = calibration.maxResidualMm.map { String(format: "max %.1fmm", $0) } ?? "max --"
        if let blocker = calibration.blockers.first {
            drawingCalibrationDetail = "\(residual) \(maxResidual); \(blocker)"
        } else {
            drawingCalibrationDetail = "\(residual) \(maxResidual); \(calibration.usableObservationCount) usable frame(s)"
        }
    }

    private func applyDrawingCalibrationSessionStatus(
        _ response: BridgeDrawingCalibrationSessionStatusResponse
    ) {
        latestDrawingCalibrationSession = response.session
        currentDrawingCalibrationBatch = response.session.flatMap { session in
            session.batches.last(where: { $0.batchId == session.currentBatchId })
                ?? session.batches.last
        }
        if let calibration = response.calibration {
            latestDrawingCalibration = calibration
        }
        guard let session = response.session else {
            drawingCalibrationSessionStatus = response.status == "missing" ? "SESSION --" : "SESSION ERR"
            drawingCalibrationSessionDetail = response.error ?? "No drawing calibration session"
            return
        }
        drawingCalibrationSessionStatus = "SESSION \(session.status.uppercased().replacingOccurrences(of: "_", with: " "))"
        drawingCalibrationSessionDetail = drawingSessionDetail(session: session, batch: currentDrawingCalibrationBatch)
    }

    private func applyDrawingCalibrationSessionResponse(
        _ response: BridgeDrawingCalibrationSessionActionResponse
    ) {
        latestDrawingCalibrationSession = response.session
        currentDrawingCalibrationBatch = response.batch ?? response.session.flatMap { session in
            session.batches.last(where: { $0.batchId == session.currentBatchId })
                ?? session.batches.last
        }
        latestDrawingCalibrationBatchPreview = response.preview ?? latestDrawingCalibrationBatchPreview
        latestDrawingCalibrationBatchRun = response.run ?? latestDrawingCalibrationBatchRun
        if let calibration = response.calibration {
            latestDrawingCalibration = calibration
            updatePredictedDrawingProgramOverlay()
        }
        guard let session = response.session else {
            drawingCalibrationSessionStatus = response.status == "missing" ? "SESSION --" : "SESSION ERR"
            drawingCalibrationSessionDetail = response.error ?? "No drawing calibration session"
            return
        }
        drawingCalibrationSessionStatus = "SESSION \(session.status.uppercased().replacingOccurrences(of: "_", with: " "))"
        drawingCalibrationSessionDetail = drawingSessionDetail(session: session, batch: currentDrawingCalibrationBatch)
        if response.retryScheduled {
            drawingCalibrationSessionDetail += "; retry scheduled"
        }
    }

    private func drawingSessionDetail(
        session: BridgeDrawingCalibrationSession,
        batch: BridgeDrawingCalibrationBatch?
    ) -> String {
        var parts = ["\(session.sessionId)"]
        if let batch {
            parts.append("#\(batch.batchIndex) \(batch.purpose) \(batch.correctionMode)")
            parts.append("retry \(batch.retryCount)/\(batch.maxRetries)")
            if let modelId = batch.modelIdUsed {
                parts.append("model \(modelId)")
            }
            if !batch.blockers.isEmpty {
                parts.append(batch.blockers.prefix(2).joined(separator: " | "))
            }
        }
        if !session.blockers.isEmpty {
            parts.append(session.blockers.prefix(2).joined(separator: " | "))
        }
        return parts.joined(separator: "; ")
    }

    private func drawingSessionBatchRequest(
        expectedPlanHash: String? = nil,
        requestId: String? = nil
    ) -> BridgeDrawingCalibrationSessionBatchRequest {
        BridgeDrawingCalibrationSessionBatchRequest(
            sessionId: latestDrawingCalibrationSession?.sessionId,
            batchId: currentDrawingCalibrationBatch?.batchId,
            correctionMode: nil,
            expectedPlanHash: expectedPlanHash,
            requestId: requestId
        )
    }

    private func runDrawingSessionAction(
        requestId: String,
        eventName: String,
        action: (BridgeDrawingCalibrationSessionBatchRequest) async throws -> BridgeDrawingCalibrationSessionActionResponse
    ) async {
        do {
            let response = try await action(drawingSessionBatchRequest(requestId: requestId))
            applyDrawingCalibrationSessionResponse(response)
            diagnosticsEvent(eventName, drawingSessionDiagnostics(response), snapshot: true)
        } catch {
            drawingCalibrationSessionStatus = "SESSION ERR"
            drawingCalibrationSessionDetail = error.localizedDescription
            diagnosticsEvent("\(eventName)_failed", errorPayload(error), snapshot: true)
        }
    }

    private func drawingSessionDiagnostics(
        _ response: BridgeDrawingCalibrationSessionActionResponse
    ) -> [String: Any] {
        [
            "status": response.status,
            "session_id": response.session?.sessionId ?? "",
            "batch_id": response.batch?.batchId ?? response.session?.currentBatchId ?? "",
            "batch_index": response.batch?.batchIndex ?? 0,
            "correction_mode": response.batch?.correctionMode ?? "",
            "model_id_used": response.batch?.modelIdUsed ?? "",
            "model_id": response.calibration?.modelId ?? "",
            "retry_count": response.batch?.retryCount ?? 0,
            "retry_scheduled": response.retryScheduled,
            "observation_id": response.observationId ?? "",
            "blockers": response.session?.blockers ?? response.batch?.blockers ?? []
        ]
    }

    private func publishDrawingCalibrationBatchOverlay(
        _ response: BridgeDrawingCalibrationProgramResponse,
        label: String
    ) {
        guard let overlay = response.previewOverlay else { return }
        expectedPathRole = "drawing_calibration_batch"
        expectedPathLabel = label
        expectedPathSegments = overlay.primitives.compactMap { primitive in
            guard visualFieldWidthMm > 0, visualFieldHeightMm > 0 else { return nil }
            return ExpectedPathSegment(
                startNorm: [
                    primitive.startPaperMm.x / visualFieldWidthMm,
                    primitive.startPaperMm.y / visualFieldHeightMm
                ],
                endNorm: [
                    primitive.endPaperMm.x / visualFieldWidthMm,
                    primitive.endPaperMm.y / visualFieldHeightMm
                ],
                startMachineMm: [],
                endMachineMm: [],
                lengthMm: primitive.lengthMm
            )
        }
        if response.drawingCorrection?.status == "applied" {
            predictedPathLabel = "Model-corrected batch"
            predictedPathSegments = expectedPathSegments
        } else {
            predictedPathSegments = []
        }
    }

    func activeDrawingCalibrationInkPrimitives() -> [InkProgramPrimitive] {
        guard let overlay = latestDrawingCalibrationBatchRun?.previewOverlay
            ?? latestDrawingCalibrationBatchPreview?.previewOverlay else {
            return []
        }
        let grouped = Dictionary(grouping: overlay.primitives, by: \.primitiveId)
        return grouped.keys.sorted().compactMap { primitiveId in
            guard let primitives = grouped[primitiveId], !primitives.isEmpty else { return nil }
            var points: [PaperPointMmSnapshot] = []
            for primitive in primitives.sorted(by: { $0.segmentIndex < $1.segmentIndex }) {
                if points.last != primitive.startPaperMm {
                    points.append(primitive.startPaperMm)
                }
                points.append(primitive.endPaperMm)
            }
            if points.count == 1 {
                return InkProgramPrimitive.mark(primitiveId: primitiveId, center: points[0])
            }
            return InkProgramPrimitive.denseStroke(primitiveId: primitiveId, points: points)
        }
    }

    private func recordLegacyDrawingFrameInspection(
        _ result: DrawnFrameInspectionResult,
        expectedCorners: [PaperPointMmSnapshot],
        registration: PaperRegistrationSnapshot,
        commandId: String?
    ) async -> BridgeDrawingCalibrationModel? {
        do {
            let response = try await client.observeDrawingFrame(
                BridgeDrawingFrameObservationRequest(
                    commandId: commandId,
                    paperRegistrationId: registration.registrationId,
                    cameraId: "plotter-camera",
                    cameraName: "Plotter Camera",
                    expectedCornersMm: expectedCorners,
                    edges: result.edges.map { edge in
                        BridgeDrawingFrameEdgeObservationRequest(
                            edgeIndex: edge.edgeIndex,
                            expectedStartMm: edge.expectedStartMm,
                            expectedEndMm: edge.expectedEndMm,
                            observedStartMm: edge.observedStartMm,
                            observedEndMm: edge.observedEndMm,
                            sampleCount: edge.sampleCount,
                            detectedSampleCount: edge.detectedSampleCount,
                            greenPixelCount: edge.greenPixelCount,
                            coverageFraction: edge.coverageFraction,
                            rmsExpectedResidualMm: edge.rmsExpectedResidualMm,
                            maxExpectedResidualMm: edge.maxExpectedResidualMm,
                            fitRmsResidualMm: edge.fitRmsResidualMm,
                            angleErrorDeg: edge.angleErrorDeg
                        )
                    },
                    corners: result.corners.map { corner in
                        BridgeDrawingFrameCornerObservationRequest(
                            cornerIndex: corner.cornerIndex,
                            expectedMm: corner.expectedMm,
                            observedMm: corner.observedMm,
                            residualMm: corner.residualMm
                        )
                    },
                    totalGreenPixels: result.totalGreenPixels,
                    detectedEdgeCount: result.detectedEdgeCount,
                    rmsResidualMm: result.rmsResidualMm,
                    maxResidualMm: result.maxResidualMm,
                    cornerRmsResidualMm: result.cornerRmsResidualMm,
                    cornerMaxResidualMm: result.cornerMaxResidualMm,
                    usable: result.isUsable
                )
            )
            applyDrawingCalibrationResponse(response)
            diagnosticsEvent(
                "drawing_frame_observation_recorded",
                [
                    "status": response.status,
                    "observation_id": response.observationId ?? "",
                    "model_id": response.calibration?.modelId ?? "",
                    "solver_kind": response.calibration?.solverKind ?? "",
                    "detected_edges": result.detectedEdgeCount,
                    "usable": result.isUsable,
                    "blockers": response.calibration?.blockers ?? []
                ],
                snapshot: true
            )
            return response.calibration
        } catch {
            drawingCalibrationStatus = "DRAW CAL ERR"
            drawingCalibrationDetail = error.localizedDescription
            diagnosticsEvent("drawing_frame_observation_failed", errorPayload(error), snapshot: true)
            return nil
        }
    }

    private func updatePredictedDrawingProgramOverlay() {
        guard expectedPathRole == "setup_field_frame",
              !expectedPathSegments.isEmpty,
              latestDrawingCalibration?.validationStatus == "ready",
              let homography = latestDrawingCalibration?.expectedToObserved else {
            predictedPathSegments = []
            return
        }
        predictedPathSegments = expectedPathSegments.compactMap { segment in
            guard let start = paperPoint(fromNorm: segment.startNorm),
                  let end = paperPoint(fromNorm: segment.endNorm),
                  let predictedStart = transformPaperPoint(start, homography: homography),
                  let predictedEnd = transformPaperPoint(end, homography: homography) else {
                return nil
            }
            return ExpectedPathSegment(
                startNorm: [
                    predictedStart.x / visualFieldWidthMm,
                    predictedStart.y / visualFieldHeightMm
                ],
                endNorm: [
                    predictedEnd.x / visualFieldWidthMm,
                    predictedEnd.y / visualFieldHeightMm
                ],
                startMachineMm: [],
                endMachineMm: [],
                lengthMm: hypot(predictedEnd.x - predictedStart.x, predictedEnd.y - predictedStart.y)
            )
        }
    }

    private func paperPoint(fromNorm values: [Double]) -> PaperPointMmSnapshot? {
        guard values.count >= 2, visualFieldWidthMm > 0, visualFieldHeightMm > 0 else { return nil }
        return PaperPointMmSnapshot(
            x: values[0] * visualFieldWidthMm,
            y: values[1] * visualFieldHeightMm
        )
    }

    private func transformPaperPoint(
        _ point: PaperPointMmSnapshot,
        homography: HomographySnapshot
    ) -> PaperPointMmSnapshot? {
        let coefficients = homography.coefficients
        guard coefficients.count == 9, visualFieldWidthMm > 0, visualFieldHeightMm > 0 else { return nil }
        let x = point.x / visualFieldWidthMm
        let y = point.y / visualFieldHeightMm
        let denominator = coefficients[6] * x + coefficients[7] * y + coefficients[8]
        guard abs(denominator) > 0.000_000_001 else { return nil }
        let correctedX = (coefficients[0] * x + coefficients[1] * y + coefficients[2]) / denominator
        let correctedY = (coefficients[3] * x + coefficients[4] * y + coefficients[5]) / denominator
        guard correctedX.isFinite, correctedY.isFinite else { return nil }
        return PaperPointMmSnapshot(
            x: correctedX * visualFieldWidthMm,
            y: correctedY * visualFieldHeightMm
        )
    }

    func observeVisualBindingPoint(
        commandId: String,
        point: BindingMarkPreviewPoint,
        observedPaperMm: PaperPointMmSnapshot,
        observedCameraNorm: NormPoint?,
        kind: String,
        confidence: Double
    ) async -> Bool {
        guard isOnline else {
            visualBindingStatus = "BIND OFF"
            visualBindingDetail = "Bridge offline"
            return false
        }
        guard !commandId.isEmpty else {
            visualBindingStatus = "BIND NO CMD"
            visualBindingDetail = "Preview expected geometry before binding observation"
            return false
        }

        do {
            let response = try await client.observeVisualBinding(
                BridgeVisualBindingObservationRequest(
                    commandId: commandId,
                    pointId: point.pointId,
                    kind: kind,
                    observedNorm: observedCameraNorm,
                    observedPaperMm: observedPaperMm,
                    expectedPaperMm: point.paperMm,
                    cameraId: "plotter-camera",
                    cameraName: "Plotter Camera",
                    confidence: confidence
                )
            )
            applyVisualBindingStatus(response)
            diagnosticsEvent(
                "visual_binding_observation_added",
                [
                    "command_id": commandId,
                    "point_id": point.pointId,
                    "kind": kind,
                    "status": response.status,
                    "observation_id": response.observationId ?? "",
                    "validation_status": response.binding?.validationStatus ?? "",
                    "observation_count": response.binding?.residuals.observationCount ?? 0
                ],
                snapshot: true
            )
            return response.status != "failed"
        } catch {
            visualBindingStatus = "BIND ERR"
            visualBindingDetail = error.localizedDescription
            diagnosticsEvent("visual_binding_observation_failed", errorPayload(error), snapshot: true)
            return false
        }
    }

    func solveVisualBinding(requestId: String? = nil) async -> Bool {
        guard isOnline else {
            visualBindingStatus = "BIND OFF"
            visualBindingDetail = "Bridge offline"
            return false
        }
        do {
            let response = try await client.solveVisualBinding(
                BridgeVisualBindingSolveRequest(requestId: requestId)
            )
            applyVisualBindingStatus(response)
            diagnosticsEvent(
                "visual_binding_solved",
                [
                    "status": response.status,
                    "validation_status": response.binding?.validationStatus ?? "",
                    "valid": visualBindingValid,
                    "observation_count": response.binding?.residuals.observationCount ?? 0
                ],
                snapshot: true
            )
            return visualBindingValid
        } catch {
            visualBindingStatus = "BIND ERR"
            visualBindingDetail = error.localizedDescription
            diagnosticsEvent("visual_binding_solve_failed", errorPayload(error), snapshot: true)
            return false
        }
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

    private func applyPaperRegistrationStatus(_ response: PaperRegistrationResponse) {
        if let registration = response.registration {
            paperRegistrationSnapshot = registration
            paperTransformStatus = String(
                format: "FIELD LOCK rms %.5f max %.5f",
                registration.rmsErrorNorm,
                registration.maxErrorNorm
            )
            return
        }
        paperRegistrationSnapshot = nil
        if response.status == "missing" {
            paperTransformStatus = "FIELD --"
        } else if response.status == "failed" {
            paperTransformStatus = "FIELD ERR"
        } else {
            paperTransformStatus = "FIELD \(response.status.uppercased())"
        }
    }

    private func runMachineCommand(
        action: String,
        operation: () async throws -> MachineCommandResponse
    ) async {
        if let blockReason = liveMachineCommandBlockReason(allowBusy: false) {
            shortStatus = isOnline ? "BLOCK" : "OFF"
            statusText = blockReason
            machineStatus = blockReason
            diagnosticsEvent(
                "machine_command_blocked",
                [
                    "action": action,
                    "reason": blockReason,
                    "build_mismatch": hasLifecycleBuildMismatch,
                    "api_mismatch": hasBridgeApiMismatch
                ],
                snapshot: true
            )
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
        machineMPosMm = response.mposMm ?? []
        machineWPosMm = response.wposMm ?? []
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

    private func revealExpectedPathImmediately(status: String) {
        animationTask?.cancel()
        pathRevealProgress = 1.0
        pathAnimationStatus = status
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
