import Foundation

@MainActor
final class OperatorWorkspaceState: ObservableObject {
    static let shared = OperatorWorkspaceState()

    let plotterCamera = CameraModel(role: .plotter)
    let faceCamera = CameraModel(role: .face)

    @Published var plotterCameraVisible = false
    @Published var faceCameraVisible = false
    @Published var plotterOverlay = PlotterOverlaySettings()
    @Published var plotterViewport = PlotterViewportSettings()
    @Published var drawingFrame = DrawingFrameSettings()
    @Published var frameLearning = FrameLearningState.idle
    @Published var calibrationStatusText = "CAL idle"
    @Published var setupWindowActive = false
    @Published var showImageProcessingPanel = true
    @Published var portraitContourMonitorEnabled = true
    @Published var portraitContourMonitorStatus = "LIVE --"
    @Published var portraitCaptures: [PortraitCaptureItem] = []
    @Published var selectedPortraitCaptureID: UUID?
    @Published var manualFiducialMode = false
    @Published var manualFiducials: [ManualFiducialPoint] = []
    @Published var manualPenMode = false
    @Published var manualCapColorMode = false
    @Published var confirmedCapPoint: ConfirmedCapPoint?
    @Published var visualMoveIntent: VisualMoveIntent?
    @Published var machineVideoAgreementModel: MachineVideoAgreementModel?
    @Published var machineVideoAgreementSamples: [MachineVideoAgreementSample] = []
    @Published var visualFieldWidthMm = 200.0
    @Published var visualFieldHeightMm = 150.0
    @Published var visualMotionModel: VisualMotionModel?
    @Published var visualMotionSamples: [VisualMotionSample] = []
    @Published var visualCenterDotTaskActive = false
    @Published var operatorLog: [OperatorLogEntry] = []
    @Published var setupSnapshot = SetupPanelSnapshot.idle
    @Published var pendingSetupCommand: SetupPanelCommandRequest?
    @Published var pendingPanelCommand: OperatorPanelCommandRequest?

    private init() {}

    func appendOperatorLog(
        _ message: String,
        source: String = "App",
        level: OperatorLogLevel = .info
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = operatorLog.last,
           last.message == trimmed,
           last.source == source,
           last.level == level {
            return
        }
        operatorLog.append(
            OperatorLogEntry(
                timestamp: Date(),
                level: level,
                source: source,
                message: trimmed
            )
        )
        if operatorLog.count > 240 {
            operatorLog.removeFirst(operatorLog.count - 240)
        }
    }

    func requestSetupCommand(_ command: SetupPanelCommand) {
        pendingSetupCommand = SetupPanelCommandRequest(command: command)
    }

    func requestPanelCommand(_ command: OperatorPanelCommand) {
        pendingPanelCommand = OperatorPanelCommandRequest(command: command)
    }

    func diagnosticsState() -> [String: Any] {
        [
            "workspace": [
                "plotter_camera_visible": plotterCameraVisible,
                "face_camera_visible": faceCameraVisible,
                "split_plane": plotterCameraVisible && faceCameraVisible,
                "empty": !plotterCameraVisible && !faceCameraVisible
            ],
            "windows": [
                "machine_controls": OperatorWindowSupport.isWindowOpen(title: "Machine", identifier: OperatorWindowID.machineControls),
                "setup_panel": setupWindowActive,
                "plotter_video_panel": OperatorWindowSupport.isWindowOpen(title: "Plotter Video", identifier: OperatorWindowID.plotterVideoPanel),
                "face_video_panel": OperatorWindowSupport.isWindowOpen(title: "Face Video", identifier: OperatorWindowID.faceVideoPanel),
                "operator_log": OperatorWindowSupport.isWindowOpen(title: "Log", identifier: OperatorWindowID.operatorLog)
            ],
            "cameras": [
                "plotter": [
                    "visible": plotterCameraVisible,
                    "running": plotterCamera.isRunning,
                    "receiving_frames": plotterCamera.isReceivingFrames,
                    "selected": plotterCamera.selectedCameraName
                ],
                "face": [
                    "visible": faceCameraVisible,
                    "running": faceCamera.isRunning,
                    "receiving_frames": faceCamera.isReceivingFrames,
                    "selected": faceCamera.selectedCameraName
                ]
            ],
            "setup": [
                "manual_fiducials": manualFiducials.count,
                "manual_fiducial_mode": manualFiducialMode,
                "manual_cap_mode": manualPenMode,
                "cap_color_pick_mode": manualCapColorMode,
                "visual_field_width_mm": visualFieldWidthMm,
                "visual_field_height_mm": visualFieldHeightMm,
                "machine_video_agreement_samples": machineVideoAgreementSamples.count,
                "machine_video_agreement_estimate_present": machineVideoAgreementModel != nil,
                "operator_log_entries": operatorLog.count
            ]
        ]
    }
}

struct SetupPanelCommandRequest: Identifiable, Equatable {
    let id = UUID()
    let command: SetupPanelCommand
}

enum SetupPanelCommand: Equatable {
    case primary
    case drawFrame
    case reset
    case hide
}

struct OperatorPanelCommandRequest: Identifiable, Equatable {
    let id = UUID()
    let command: OperatorPanelCommand
}

enum OperatorPanelCommand: Equatable {
    case useOriginalPlotterVideo
    case togglePlotterFocus
    case sampleCapColor
    case resetCapColor
    case resetVisualControls
    case createPortraitDrawing
    case selectPortraitCapture(UUID)
}

struct SetupPanelSnapshot: Equatable {
    var instructionText: String
    var fiducialDetail: String
    var fiducialStatus: CalibrationWizardStepStatus
    var greenCapDetail: String
    var greenCapStatus: CalibrationWizardStepStatus
    var visualCalibrationDetail: String
    var visualCalibrationStatus: CalibrationWizardStepStatus
    var bindingDetail: String
    var bindingStatus: CalibrationWizardStepStatus
    var primaryActionTitle: String
    var primaryActionEnabled: Bool
    var primaryActionDisabledReason: String?
    var drawFrameVisible: Bool
    var drawFrameEnabled: Bool
    var drawFrameDisabledReason: String?
    var hasPaperLock: Bool
    var capStateLabel: String
    var isLiveMotionMode: Bool
    var capDetected: Bool

    static let idle = SetupPanelSnapshot(
        instructionText: "Open the plotter camera and start setup.",
        fiducialDetail: "No setup state",
        fiducialStatus: .pending,
        greenCapDetail: "No cap state",
        greenCapStatus: .pending,
        visualCalibrationDetail: "No motion calibration",
        visualCalibrationStatus: .pending,
        bindingDetail: "No motion validation",
        bindingStatus: .pending,
        primaryActionTitle: "Start Setup",
        primaryActionEnabled: true,
        primaryActionDisabledReason: nil,
        drawFrameVisible: false,
        drawFrameEnabled: false,
        drawFrameDisabledReason: nil,
        hasPaperLock: false,
        capStateLabel: "--",
        isLiveMotionMode: false,
        capDetected: false
    )
}
