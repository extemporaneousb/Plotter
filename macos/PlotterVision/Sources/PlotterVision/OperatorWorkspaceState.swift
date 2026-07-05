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
    @Published var motionCalibration = MotionCalibrationState.idle
    @Published var calibrationStatusText = "CAL idle"
    @Published var calibrationWizardActive = false
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
    @Published var fieldRegistrationProbeModel: FieldRegistrationProbeModel?
    @Published var fieldRegistrationProbeSamples: [FieldRegistrationProbeSample] = []
    @Published var visualFieldWidthMm = 200.0
    @Published var visualFieldHeightMm = 150.0
    @Published var visualMotionModel: VisualMotionModel?
    @Published var visualMotionSamples: [VisualMotionSample] = []
    @Published var visualCenterDotTaskActive = false
    @Published var operatorLog: [OperatorLogEntry] = []
    @Published var calibrationWizardSnapshot = CalibrationWizardSnapshot.idle
    @Published var pendingPanelCommand: OperatorPanelCommandRequest?
    @Published var machineControlsVisible = false
    @Published var plotterVideoPanelVisible = false
    @Published var faceVideoPanelVisible = false
    @Published var operatorLogVisible = false

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

    func requestPanelCommand(_ command: OperatorPanelCommand) {
        pendingPanelCommand = OperatorPanelCommandRequest(command: command)
    }

    func setWindowVisible(_ id: String, visible: Bool) {
        switch id {
        case OperatorWindowID.machineControls:
            machineControlsVisible = visible
        case OperatorWindowID.plotterVideoPanel:
            plotterVideoPanelVisible = visible
        case OperatorWindowID.faceVideoPanel:
            faceVideoPanelVisible = visible
        case OperatorWindowID.operatorLog:
            operatorLogVisible = visible
        default:
            break
        }
    }

    func isWindowVisible(_ id: String) -> Bool {
        switch id {
        case OperatorWindowID.machineControls:
            machineControlsVisible
        case OperatorWindowID.plotterVideoPanel:
            plotterVideoPanelVisible
        case OperatorWindowID.faceVideoPanel:
            faceVideoPanelVisible
        case OperatorWindowID.operatorLog:
            operatorLogVisible
        default:
            false
        }
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
                "machine_controls": machineControlsVisible,
                "calibration_wizard": calibrationWizardActive,
                "plotter_video_panel": plotterVideoPanelVisible,
                "face_video_panel": faceVideoPanelVisible,
                "operator_log": operatorLogVisible
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
                "visual_field_video_aspect_y_per_x": calibrationWizardSnapshot.fieldAspectYPerX ?? 0.0,
                "field_registration_probe_samples": fieldRegistrationProbeSamples.count,
                "field_registration_probe_basis_present": fieldRegistrationProbeModel != nil,
                "operator_log_entries": operatorLog.count
            ]
        ]
    }
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

struct CalibrationWizardSnapshot: Equatable {
    var fieldAspectYPerX: Double?

    static let idle = CalibrationWizardSnapshot(fieldAspectYPerX: nil)
}
