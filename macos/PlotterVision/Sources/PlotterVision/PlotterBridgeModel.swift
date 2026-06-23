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
    @Published var bindingMarkPreviewStatus = "BIND --"
    @Published var adaptiveProbeStatus = "PROBE --"
    @Published var visualCenterDotStatus = "VIS --"
    @Published var visualBindingStatus = "BIND --"
    @Published var visualBindingDetail = "No binding observations"
    @Published var visualBindingObservationCount = 0
    @Published var visualBindingValid = false
    @Published var visualProbeEvidenceRunId = "swift-probe-\(UUID().uuidString.lowercased())"
    @Published var bindingMarkPreviewPoints: [BindingMarkPreviewPoint] = []
    @Published var bindingMarkPreviewSegments: [BindingMarkPreviewSegment] = []
    @Published var bindingMarkPreviewCommandId = ""
    @Published var bindingMarkPreviewPlanHash = ""
    @Published var bindingMarkPreviewPointSet = ""
    @Published var drawVerifyStatus = "DRAW --"
    @Published var drawVerifyDetail = "Preview a capability check before running"
    @Published var drawVerifyKind = ""
    @Published var drawVerifyLabel = ""
    @Published var drawVerifyCommandId = ""
    @Published var drawVerifyPlanHash = ""
    @Published var workspaceXMm = 533.4
    @Published var workspaceYMm = 215.9
    @Published var machineMaxFeedMmMin = 1200.0
    @Published var machineMaxJogMm = 50.0
    @Published var shapeSideMm = 35.0
    @Published var shapeCenterXNorm = 0.5
    @Published var shapeCenterYNorm = 0.5
    @Published var shapeDrawFeedMmMin = 240.0
    @Published var pathRevealProgress = 1.0
    @Published var pathAnimationStatus = "IDLE"
    @Published var isMachineBusy = false
    @Published var isMachineAlarm = false
    @Published var activeAction = ""
    @Published var manualStepMm = 1.0
    @Published var manualFeedMmMin = 1200.0
    @Published var machineMPosMm: [Double] = []
    @Published var machineWPosMm: [Double] = []

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
        visualBindingDetail = "Run motion probe, preview binding marks, then collect ink observations"
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
        if visualBindingValid { return "VisualPositionBinding validated" }
        return "axis model or VisualPositionBinding required"
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
        if !hasPaperLock { return "Bridge-run drawing blocked: visual field missing" }
        if !machineAxisModelTrusted { return "Bridge-run drawing blocked: axis geometry not trusted" }
        if !machineHomingTrusted { return "Bridge-run drawing blocked: absolute position not trusted" }
        return "Live motion enabled"
    }

    var drawPreflightMessage: String {
        if !isOnline { return "Bridge offline" }
        if hasBridgeApiMismatch { return "Bridge API mismatch" }
        if hasLifecycleBuildMismatch { return "App/bridge build mismatch" }
        if isDryRun { return "Bridge-run dry-run only" }
        if !hasPaperLock { return "Paper homography missing" }
        if !hasDrawingAuthority { return drawingAuthorityDetail }
        if isMachineAlarm { return "Machine alarm" }
        if isMachineBusy || isRunning { return "Machine busy" }
        return "Bridge-run drawing armed"
    }

    var drawVerifyStatusLine: String {
        guard !drawVerifyPlanHash.isEmpty else { return drawVerifyStatus }
        let label = drawVerifyLabel.isEmpty ? DrawVerifyCoordinator.title(for: drawVerifyKind) : drawVerifyLabel
        return "\(drawVerifyStatus) \(label) \(DrawVerifyCoordinator.shortPlanHash(drawVerifyPlanHash))"
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
                "can_run_visual_relative_motion": isLiveMotionMode && hasPaperLock && !bindingMarkPreviewPoints.isEmpty
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

    private func applyVisualBindingStatus(_ response: BridgeVisualPositionBindingResponse) {
        if let binding = response.binding {
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
                visualBindingDetail = "Need ink or pen-tip observations"
            }
            return
        }

        visualBindingObservationCount = 0
        visualBindingValid = false
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

    func previewDrawVerifyCapability(kind: String) async -> Bool {
        guard !isRunning && !isMachineBusy else { return false }
        guard isOnline else {
            drawVerifyStatus = "DRAW OFF"
            drawVerifyDetail = "Bridge offline"
            statusText = "Bridge offline"
            diagnosticsEvent("draw_verify_preview_blocked", ["kind": kind, "reason": "bridge_offline"], snapshot: true)
            return false
        }
        guard hasPaperLock else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = "Paper homography required"
            statusText = "Paper homography required"
            diagnosticsEvent("draw_verify_preview_blocked", ["kind": kind, "reason": "paper_homography_required"], snapshot: true)
            return false
        }

        isCalibrating = true
        activeAction = "draw-verify-preview"
        let title = DrawVerifyCoordinator.title(for: kind)
        drawVerifyStatus = "DRAW PREVIEW"
        drawVerifyDetail = "Previewing \(title)"
        statusText = drawVerifyDetail
        diagnosticsEvent("draw_verify_preview_started", ["kind": kind], snapshot: true)
        defer {
            isCalibrating = false
            activeAction = ""
        }

        do {
            let response = try await client.previewCapabilityTest(
                DrawVerifyCoordinator.request(
                    kind: kind,
                    requestId: "draw-verify-preview-\(kind)",
                    drawFeedMmMin: shapeDrawFeedMmMin
                )
            )
            applyDrawVerifyResponse(response, running: false)
            diagnosticsEvent(
                "draw_verify_preview_completed",
                [
                    "kind": response.kind,
                    "command_id": response.commandId,
                    "plan_hash": response.planHash,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "preview_segments": expectedPathSegments.count
                ],
                snapshot: true
            )
            return response.status == "ready" || response.status == "completed"
        } catch {
            expectedPathSegments = []
            drawVerifyStatus = "DRAW ERR"
            drawVerifyDetail = error.localizedDescription
            statusText = error.localizedDescription
            diagnosticsEvent("draw_verify_preview_failed", ["kind": kind, "error": error.localizedDescription], snapshot: true)
            return false
        }
    }

    func runVerifiedDrawVerifyCapability() async -> Bool {
        guard !drawVerifyKind.isEmpty, !drawVerifyPlanHash.isEmpty else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = "Preview a capability check before running"
            statusText = drawVerifyDetail
            diagnosticsEvent("draw_verify_run_blocked", ["reason": "preview_required"], snapshot: true)
            return false
        }
        guard canRunAbsoluteDrawing else {
            drawVerifyStatus = "DRAW BLOCK"
            drawVerifyDetail = drawPreflightMessage
            statusText = drawPreflightMessage
            diagnosticsEvent(
                "draw_verify_run_blocked",
                [
                    "kind": drawVerifyKind,
                    "reason": drawPreflightMessage,
                    "plan_hash": drawVerifyPlanHash
                ],
                snapshot: true
            )
            return false
        }

        isRunning = true
        isMachineBusy = true
        activeAction = "draw-verify-run"
        shortStatus = isDryRun ? "DRY" : "RUN"
        drawVerifyStatus = "DRAW RUN"
        drawVerifyDetail = "Running \(drawVerifyLabel.isEmpty ? DrawVerifyCoordinator.title(for: drawVerifyKind) : drawVerifyLabel)"
        statusText = drawVerifyDetail
        let kind = drawVerifyKind
        let expectedHash = drawVerifyPlanHash
        diagnosticsEvent(
            "draw_verify_run_started",
            ["kind": kind, "expected_plan_hash": expectedHash],
            snapshot: true
        )
        defer {
            isRunning = false
            activeAction = ""
        }

        do {
            let response = try await client.runCapabilityTest(
                DrawVerifyCoordinator.request(
                    kind: kind,
                    requestId: "draw-verify-run-\(kind)",
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    expectedPlanHash: expectedHash
                )
            )
            shortStatus = response.dryRun ? "DRY" : (response.status == "completed" ? "DONE" : "ERR")
            applyDrawVerifyResponse(response, running: true)
            isOnline = true
            await refreshMachineStatus()
            diagnosticsEvent(
                "draw_verify_run_completed",
                [
                    "kind": response.kind,
                    "command_id": response.commandId,
                    "plan_hash": response.planHash,
                    "status": response.status,
                    "dry_run": response.dryRun,
                    "preview_segments": expectedPathSegments.count
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
            diagnosticsEvent("draw_verify_run_failed", ["kind": kind, "error": error.localizedDescription], snapshot: true)
            return false
        }
    }

    func clearDrawVerifyOverlay() {
        expectedPathSegments = []
        drawVerifyStatus = "DRAW --"
        drawVerifyDetail = "Preview a capability check before running"
        drawVerifyKind = ""
        drawVerifyLabel = ""
        drawVerifyCommandId = ""
        drawVerifyPlanHash = ""
        previewStatus = "SIM --"
        diagnosticsEvent("draw_verify_overlay_cleared", snapshot: true)
    }

    private func applyDrawVerifyResponse(_ response: BridgeCapabilityTestResponse, running: Bool) {
        drawVerifyKind = response.kind
        drawVerifyLabel = response.label.isEmpty ? DrawVerifyCoordinator.title(for: response.kind) : response.label
        drawVerifyCommandId = response.commandId
        drawVerifyPlanHash = response.planHash
        expectedPathSegments = response.simulation?.previewSegments ?? []
        let drawnLength = response.simulation?.drawnLengthMm ?? response.summary?.drawnLengthMm ?? 0.0
        animateExpectedPath(drawnLengthMm: drawnLength, feedMmMin: shapeDrawFeedMmMin)
        let status = response.status.uppercased()
        drawVerifyStatus = running ? "DRAW \(status)" : "VERIFY \(status)"
        drawVerifyDetail = "\(response.commandId) \(drawVerifyLabel) plan \(DrawVerifyCoordinator.shortPlanHash(response.planHash))"
        previewStatus = "SIM \(status)"
        statusText = drawVerifyDetail
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
                    travelFeedMmMin: fastTravelFeedMmMin
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
                    travelFeedMmMin: fastTravelFeedMmMin
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
                    travelFeedMmMin: fastTravelFeedMmMin,
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

    func previewPortraitContours(
        _ raster: FaceRasterSample,
        frame: BridgeDrawingFrameRequest
    ) async -> Bool {
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
                        contourLevels: 8,
                        lowQuantile: 0.18,
                        highQuantile: 0.92,
                        autoContrast: true,
                        illuminationRadius: 5,
                        illuminationStrength: 0.72,
                        smoothingRadius: 1,
                        simplificationEpsilonNorm: 0.004,
                        minContourLengthNorm: 0.035,
                        minPointsPerContour: 4,
                        maxContours: 700,
                        maxPoints: 8000
                    ),
                    drawFeedMmMin: shapeDrawFeedMmMin,
                    travelFeedMmMin: fastTravelFeedMmMin,
                    maxSegmentMm: 25.0
                )
            )
            expectedPathSegments = response.simulation?.previewSegments ?? []
            let contours = response.portraitSummary?.contourCount ?? 0
            let keptPoints = response.portraitSummary?.keptPointCount ?? 0
            let segments = response.summary?.drawSegmentCount ?? 0
            imagePreviewContourCount = contours
            imagePreviewEligibleForBridgePreview = response.eligibleForBridgePreview
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
            expectedPathSegments = []
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
            isMachineAlarm = error.localizedDescription.localizedCaseInsensitiveContains("alarm")
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
                bindingMarkPreviewStatus = "BIND NEED PAPER"
                statusText = "Paper homography required"
                diagnosticsEvent("binding_mark_preview_blocked", ["point_set": pointSet, "reason": "paper_homography_required"], snapshot: true)
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
                    marginMm: 40.0,
                    markSizeMm: 6.0,
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
            expectedPathSegments = []
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
                snapshot: true
            )
        } catch {
            visualBindingStatus = "BIND ERR"
            visualBindingDetail = error.localizedDescription
            visualBindingValid = false
            diagnosticsEvent("visual_binding_status_failed", errorPayload(error), snapshot: true)
        }
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
