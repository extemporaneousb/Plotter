import SwiftUI
import AppKit

@main
struct PlotterVisionApp: App {
    @NSApplicationDelegateAdaptor(WindowPlacementDelegate.self) private var windowPlacement
    @StateObject private var bridge = PlotterBridgeModel()

    var body: some Scene {
        WindowGroup(PlotterWindowConfiguration.mainTitle) {
            ContentView(bridge: bridge)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window(PlotterWindowConfiguration.machineTitle, id: "machine-controls") {
            MachineControlPanel(bridge: bridge)
                .frame(width: 320)
                .padding(14)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 360, height: 640)
        .restorationBehavior(.disabled)
    }
}

private enum PlotterWindowConfiguration {
    static let mainTitle = "Plotter Vision"
    static let machineTitle = "Machine"
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

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.normalizeOpenWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveOpenWindowFrames()
    }

    private func normalizeOpenWindows() {
        for window in NSApplication.shared.windows where window.isVisible {
            guard window.title != PlotterWindowConfiguration.machineTitle else { continue }
            configureMainWindow(window)
            normalize(window)
        }
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
