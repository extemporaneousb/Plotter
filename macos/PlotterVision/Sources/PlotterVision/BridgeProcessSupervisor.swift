import Darwin
import Foundation

enum BridgeProcessStartResult {
    case alreadyRunning(URL)
    case started(URL, String)
    case unavailable(String)
}

final class BridgeProcessSupervisor {
    static let shared = BridgeProcessSupervisor()

    let baseURL: URL

    private let port: Int
    private var process: Process?
    private var logHandle: FileHandle?
    private var sessionID = UUID().uuidString.lowercased()

    private init() {
        port = Self.availableLoopbackPort()
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    @discardableResult
    func startIfNeeded() -> BridgeProcessStartResult {
        if let process, process.isRunning {
            return .alreadyRunning(baseURL)
        }

        guard let sourceRoot = Self.sourceRootURL() else {
            return .unavailable("Missing PlotterSourceRoot in app bundle")
        }
        guard let plotterctl = Self.plotterctlURL(sourceRoot: sourceRoot) else {
            return .unavailable("Missing .VE/bin/plotterctl or .venv/bin/plotterctl")
        }

        let fileManager = FileManager.default
        let artifactsURL = sourceRoot.appendingPathComponent("artifacts", isDirectory: true)
        let sessionURL = artifactsURL.appendingPathComponent("dev_session", isDirectory: true)
        let transcriptURL = artifactsURL.appendingPathComponent("bridge_transcripts", isDirectory: true)
        let calibrationURL = artifactsURL.appendingPathComponent("calibration_sessions", isDirectory: true)
        let configURL = artifactsURL.appendingPathComponent("machine_config.json")
        let eventLogURL = artifactsURL.appendingPathComponent("bridge_events.jsonl")
        let logURL = sessionURL.appendingPathComponent("bridge-\(sessionID).log")

        do {
            try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: transcriptURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: calibrationURL, withIntermediateDirectories: true)
        } catch {
            return .unavailable("Could not create bridge artifact directories: \(error.localizedDescription)")
        }

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            logHandle = handle
        } catch {
            fileManager.createFile(atPath: logURL.path, contents: nil)
            do {
                logHandle = try FileHandle(forWritingTo: logURL)
            } catch {
                return .unavailable("Could not open bridge log: \(error.localizedDescription)")
            }
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/bash")
        child.arguments = ["-lc", Self.launchScript]
        child.currentDirectoryURL = sourceRoot
        child.standardOutput = logHandle
        child.standardError = logHandle
        child.terminationHandler = { [weak self] _ in
            self?.closeLogHandle()
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PLOTTERCTL"] = plotterctl.path
        environment["PLOTTER_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["PLOTTER_HTTP_PORT"] = String(port)
        environment["PLOTTER_BAUD"] = "115200"
        environment["PLOTTER_ARTIFACTS"] = artifactsURL.path
        environment["PLOTTER_CONFIG_PATH"] = configURL.path
        environment["PLOTTER_EVENT_LOG"] = eventLogURL.path
        environment["PLOTTER_TRANSCRIPT_DIR"] = transcriptURL.path
        environment["PLOTTER_CALIBRATION_DIR"] = calibrationURL.path
        environment["PLOTTER_WORKSPACE_X_MAX"] = "533.4"
        environment["PLOTTER_WORKSPACE_Y_MAX"] = "215.9"
        environment["PLOTTER_PEN_UP"] = "M3 S40"
        environment["PLOTTER_PEN_DOWN"] = "M3 S720"
        environment["PYTHONUNBUFFERED"] = "1"
        if let appBuildID = currentAppBuildId() {
            environment["PLOTTER_BRIDGE_BUILD_ID"] = appBuildID
        }
        child.environment = environment

        do {
            try child.run()
        } catch {
            closeLogHandle()
            return .unavailable("Could not start owned bridge: \(error.localizedDescription)")
        }

        process = child
        writeSessionManifest(
            sourceRoot: sourceRoot,
            plotterctl: plotterctl,
            logURL: logURL
        )
        return .started(baseURL, logURL.path)
    }

    func stopOwnedBridge(reason: String) {
        guard let process else {
            closeLogHandle()
            return
        }
        guard process.isRunning else {
            self.process = nil
            closeLogHandle()
            return
        }

        let ownedProcess = process
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard ownedProcess.isRunning else { return }
            kill(ownedProcess.processIdentifier, SIGKILL)
            self?.closeLogHandle()
        }
        self.process = nil
    }

    private func writeSessionManifest(sourceRoot: URL, plotterctl: URL, logURL: URL) {
        let manifestURL = sourceRoot
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("dev_session", isDirectory: true)
            .appendingPathComponent("current.json")
        let manifest: [String: Any] = [
            "schema_version": 1,
            "session_id": sessionID,
            "owner": "PlotterVision",
            "owner_pid": ProcessInfo.processInfo.processIdentifier,
            "base_url": baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "source_root": sourceRoot.path,
            "plotterctl": plotterctl.path,
            "app_build_id": currentAppBuildId() ?? "",
            "mode": "hardware_standby",
            "started_at": ISO8601DateFormatter().string(from: Date()),
            "log": logURL.path
        ]
        guard JSONSerialization.isValidJSONObject(manifest),
              let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: manifestURL, options: [.atomic])
    }

    private func closeLogHandle() {
        try? logHandle?.close()
        logHandle = nil
    }

    private static var launchScript: String {
        """
        set -euo pipefail

        "$PLOTTERCTL" save-pen-config \
          --up-command "$PLOTTER_PEN_UP" \
          --down-command "$PLOTTER_PEN_DOWN" \
          --out "$PLOTTER_CONFIG_PATH"

        "$PLOTTERCTL" bridge-server \
          --host 127.0.0.1 \
          --http-port "$PLOTTER_HTTP_PORT" \
          --baud "$PLOTTER_BAUD" \
          --dry-run \
          --config-path "$PLOTTER_CONFIG_PATH" \
          --workspace-x-max "$PLOTTER_WORKSPACE_X_MAX" \
          --workspace-y-max "$PLOTTER_WORKSPACE_Y_MAX" \
          --event-log "$PLOTTER_EVENT_LOG" \
          --transcript-dir "$PLOTTER_TRANSCRIPT_DIR" \
          --calibration-dir "$PLOTTER_CALIBRATION_DIR" &
        bridge_pid=$!

        stop_bridge() {
          kill "$bridge_pid" 2>/dev/null || true
          wait "$bridge_pid" 2>/dev/null || true
        }
        trap stop_bridge INT TERM EXIT

        while kill -0 "$bridge_pid" 2>/dev/null; do
          if ! kill -0 "$PLOTTER_PARENT_PID" 2>/dev/null; then
            exit 0
          fi
          sleep 0.5
        done
        wait "$bridge_pid"
        """
    }

    private static func sourceRootURL() -> URL? {
        if let value = cleanBridgeMetadata(Bundle.main.object(forInfoDictionaryKey: "PlotterSourceRoot") as? String) {
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }
        return nil
    }

    private static func plotterctlURL(sourceRoot: URL) -> URL? {
        for relativePath in [".VE/bin/plotterctl", ".venv/bin/plotterctl"] {
            let candidate = sourceRoot.appendingPathComponent(relativePath)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func availableLoopbackPort() -> Int {
        let fallback = Int.random(in: 28000...48999)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return fallback }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return fallback }

        var socketAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard named == 0 else { return fallback }

        let port = Int(UInt16(bigEndian: socketAddress.sin_port))
        return port > 0 ? port : fallback
    }
}
