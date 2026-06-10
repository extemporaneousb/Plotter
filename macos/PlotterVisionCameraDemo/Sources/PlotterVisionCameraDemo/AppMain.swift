import SwiftUI
import AppKit

@main
struct PlotterVisionCameraApp: App {
    @NSApplicationDelegateAdaptor(WindowPlacementDelegate.self) private var windowPlacement
    @StateObject private var bridge = PlotterBridgeModel()

    var body: some Scene {
        WindowGroup {
            ContentView(bridge: bridge)
                .frame(minWidth: 1120, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("Machine", id: "machine-controls") {
            MachineControlPanel(bridge: bridge)
                .frame(width: 320)
                .padding(14)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 360, height: 640)
        .restorationBehavior(.disabled)
    }
}

final class WindowPlacementDelegate: NSObject, NSApplicationDelegate {
    private let minimumSize = NSSize(width: 1120, height: 720)
    private let preferredSize = NSSize(width: 1320, height: 820)

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

    private func normalizeOpenWindows() {
        for window in NSApplication.shared.windows where window.isVisible {
            guard window.title != "Machine" else { continue }
            normalize(window)
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
