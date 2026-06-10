import Foundation

struct SavedFrameState: Codable {
    var plotterOverlay: PlotterOverlaySettings
    var drawingFrame: DrawingFrameSettings
    var plotterViewport: PlotterViewportSettings?
}

enum FrameStateStore {
    static var path: URL {
        let directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PlotterVisionCamera", isDirectory: true)
        return directory.appendingPathComponent("frame_state.json")
    }

    static func load() -> SavedFrameState? {
        let url = path
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedFrameState.self, from: data)
    }

    static func save(
        plotterOverlay: PlotterOverlaySettings,
        drawingFrame: DrawingFrameSettings,
        plotterViewport: PlotterViewportSettings
    ) {
        let url = path
        let state = SavedFrameState(
            plotterOverlay: plotterOverlay,
            drawingFrame: drawingFrame,
            plotterViewport: plotterViewport
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder.pretty.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Failed to save frame state: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
