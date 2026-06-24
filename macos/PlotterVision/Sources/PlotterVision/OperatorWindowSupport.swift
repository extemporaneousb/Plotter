import AppKit

enum OperatorWindowID {
    static let machineControls = "machine-controls"
    static let setupPanel = "setup-panel"
    static let plotterVideoPanel = "plotter-video-panel"
    static let faceVideoPanel = "face-video-panel"
    static let operatorLog = "operator-log"
}

enum OperatorWindowSupport {
    static func closeWindow(title: String, identifier: String) -> Bool {
        guard let window = findWindow(title: title, identifier: identifier) else { return false }
        window.close()
        return true
    }

    static func isWindowOpen(title: String, identifier: String) -> Bool {
        findWindow(title: title, identifier: identifier) != nil
    }

    private static func findWindow(title: String, identifier: String) -> NSWindow? {
        NSApplication.shared.windows.first { window in
            window.isVisible && (window.identifier?.rawValue == identifier || window.title == title)
        }
    }
}
