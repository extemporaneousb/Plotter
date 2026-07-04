import AppKit

enum OperatorWindowID {
    static let machineControls = "machine-controls"
    static let plotterVideoPanel = "plotter-video-panel"
    static let faceVideoPanel = "face-video-panel"
    static let operatorLog = "operator-log"
}

enum OperatorWindowSupport {
    static func closeWindow(title: String, identifier: String) -> Bool {
        guard let window = findWindow(title: title, identifier: identifier, visibleOnly: true) else { return false }
        window.close()
        return true
    }

    static func isWindowOpen(title: String, identifier: String) -> Bool {
        findWindow(title: title, identifier: identifier, visibleOnly: true) != nil
    }

    static func raiseWindow(title: String, identifier: String) -> Bool {
        guard let window = findWindow(title: title, identifier: identifier, visibleOnly: false) else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    private static func findWindow(title: String, identifier: String, visibleOnly: Bool) -> NSWindow? {
        NSApplication.shared.windows.first { window in
            (!visibleOnly || window.isVisible) && (window.identifier?.rawValue == identifier || window.title == title)
        }
    }
}
