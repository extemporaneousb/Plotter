import SwiftUI
import AppKit

@main
struct PlotterVisionApp: App {
    @NSApplicationDelegateAdaptor(WindowPlacementDelegate.self) private var windowPlacement
    @StateObject private var bridge: PlotterBridgeModel
    @StateObject private var workspace = OperatorWorkspaceState.shared

    init() {
        let supervisor = BridgeProcessSupervisor.shared
        _bridge = StateObject(
            wrappedValue: PlotterBridgeModel(
                client: PlotterBridgeClient(baseURL: supervisor.baseURL),
                bridgeSupervisor: supervisor
            )
        )
    }

    var body: some Scene {
        WindowGroup(PlotterWindowConfiguration.mainTitle) {
            ContentView(bridge: bridge, workspace: workspace)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window(PlotterWindowConfiguration.machineTitle, id: OperatorWindowID.machineControls) {
            MachineControlPanel(bridge: bridge)
                .frame(width: 320)
                .padding(14)
                .preferredColorScheme(.dark)
                .onAppear {
                    bridge.recordOperatorEvent("window_visible", details: ["window_id": OperatorWindowID.machineControls])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_visible")
                }
                .onDisappear {
                    bridge.recordOperatorEvent("window_hidden", details: ["window_id": OperatorWindowID.machineControls])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_hidden")
                }
        }
        .defaultSize(width: 360, height: 640)
        .restorationBehavior(.disabled)

        Window(PlotterWindowConfiguration.setupTitle, id: OperatorWindowID.setupPanel) {
            SetupPanel(workspace: workspace, bridge: bridge)
                .preferredColorScheme(.dark)
                .onAppear {
                    workspace.setupWindowActive = true
                    bridge.recordOperatorEvent("window_visible", details: ["window_id": OperatorWindowID.setupPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_visible")
                }
                .onDisappear {
                    workspace.setupWindowActive = false
                    bridge.recordOperatorEvent("window_hidden", details: ["window_id": OperatorWindowID.setupPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_hidden")
                }
        }
        .defaultSize(width: 460, height: 620)
        .restorationBehavior(.disabled)

        Window(PlotterWindowConfiguration.plotterVideoTitle, id: OperatorWindowID.plotterVideoPanel) {
            PlotterVideoPanel(workspace: workspace, bridge: bridge)
                .preferredColorScheme(.dark)
                .onAppear {
                    bridge.recordOperatorEvent("window_visible", details: ["window_id": OperatorWindowID.plotterVideoPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_visible")
                }
                .onDisappear {
                    bridge.recordOperatorEvent("window_hidden", details: ["window_id": OperatorWindowID.plotterVideoPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_hidden")
                }
        }
        .defaultSize(width: 380, height: 520)
        .restorationBehavior(.disabled)

        Window(PlotterWindowConfiguration.faceVideoTitle, id: OperatorWindowID.faceVideoPanel) {
            FaceVideoPanel(workspace: workspace, bridge: bridge)
                .preferredColorScheme(.dark)
                .onAppear {
                    bridge.recordOperatorEvent("window_visible", details: ["window_id": OperatorWindowID.faceVideoPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_visible")
                }
                .onDisappear {
                    bridge.recordOperatorEvent("window_hidden", details: ["window_id": OperatorWindowID.faceVideoPanel])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_hidden")
                }
        }
        .defaultSize(width: 390, height: 720)
        .restorationBehavior(.disabled)

        Window(PlotterWindowConfiguration.logTitle, id: OperatorWindowID.operatorLog) {
            OperatorLogPanel(workspace: workspace)
                .preferredColorScheme(.dark)
                .onAppear {
                    bridge.recordOperatorEvent("window_visible", details: ["window_id": OperatorWindowID.operatorLog])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_visible")
                }
                .onDisappear {
                    bridge.recordOperatorEvent("window_hidden", details: ["window_id": OperatorWindowID.operatorLog])
                    bridge.updateOperatorUIState(workspace.diagnosticsState(), reason: "operator_ui_window_hidden")
                }
        }
        .defaultSize(width: 620, height: 520)
        .restorationBehavior(.disabled)
    }
}

private enum PlotterWindowConfiguration {
    static let mainTitle = "Plotter Vision"
    static let machineTitle = "Machine"
    static let setupTitle = "Setup"
    static let plotterVideoTitle = "Plotter Video"
    static let faceVideoTitle = "Face Video"
    static let logTitle = "Log"
    static let mainIdentifier = NSUserInterfaceItemIdentifier("plotter-main-window")
    static let mainFrameAutosaveName = NSWindow.FrameAutosaveName("PlotterVisionMainWindow")
}

final class WindowPlacementDelegate: NSObject, NSApplicationDelegate {
    private let minimumSize = NSSize(width: 1120, height: 720)
    private let preferredSize = NSSize(width: 1320, height: 820)
    private var configuredWindows = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.normalizeOpenWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveOpenWindowFrames()
        BridgeProcessSupervisor.shared.stopOwnedBridge(reason: "app_terminating")
    }

    private func normalizeOpenWindows() {
        for window in NSApplication.shared.windows where window.isVisible {
            guard isMainWindowCandidate(window) else { continue }
            configureMainWindow(window)
            normalize(window)
        }
    }

    private func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        window.identifier == PlotterWindowConfiguration.mainIdentifier
            || window.title == PlotterWindowConfiguration.mainTitle
    }

    private func configureMainWindow(_ window: NSWindow) {
        window.title = PlotterWindowConfiguration.mainTitle
        window.identifier = PlotterWindowConfiguration.mainIdentifier
        window.setFrameAutosaveName(PlotterWindowConfiguration.mainFrameAutosaveName)

        let windowID = ObjectIdentifier(window)
        guard !configuredWindows.contains(windowID) else { return }
        configuredWindows.insert(windowID)
        window.setFrameUsingName(PlotterWindowConfiguration.mainFrameAutosaveName, force: true)
    }

    private func saveOpenWindowFrames() {
        for window in NSApplication.shared.windows where window.identifier == PlotterWindowConfiguration.mainIdentifier {
            window.saveFrame(usingName: PlotterWindowConfiguration.mainFrameAutosaveName)
        }
    }

    private func normalize(_ window: NSWindow) {
        window.minSize = minimumSize

        guard let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 18, dy: 18)
        let frame = window.frame
        let tooSmall = frame.width < minimumSize.width || frame.height < minimumSize.height
        let notVisibleEnough = !visibleFrame.intersection(frame).hasUsableArea(minimumFraction: 0.62, of: frame)

        guard tooSmall || notVisibleEnough else { return }

        let width = min(preferredSize.width, visibleFrame.width)
        let height = min(preferredSize.height, visibleFrame.height)
        let normalizedFrame = NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(normalizedFrame, display: true, animate: false)
    }
}

private extension NSRect {
    func hasUsableArea(minimumFraction: CGFloat, of frame: NSRect) -> Bool {
        guard width > 0, height > 0, frame.width > 0, frame.height > 0 else { return false }
        let visibleArea = width * height
        let frameArea = frame.width * frame.height
        return visibleArea / frameArea >= minimumFraction
    }
}
