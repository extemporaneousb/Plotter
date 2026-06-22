import Foundation
import OSLog

final class AppDiagnostics {
    static let shared = AppDiagnostics()

    private let logger = Logger(subsystem: "com.plottervision.camera", category: "diagnostics")
    private let queue = DispatchQueue(label: "com.plottervision.camera.diagnostics")
    private let encoder = JSONEncoder()
    private let directoryURL: URL
    private let stateURL: URL
    private let eventsURL: URL
    private let maxEventLogBytes = 256 * 1024
    private let maxStringLength = 180

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        directoryURL = Self.resolveDirectoryURL()
        stateURL = directoryURL.appendingPathComponent("app_state.json")
        eventsURL = directoryURL.appendingPathComponent("app_events.jsonl")
        queue.async { [directoryURL] in
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    func recordEvent(_ name: String, payload: [String: Any] = [:]) {
        let cleanName = sanitizeString(name)
        let cleanPayload = sanitize(payload)
        let summary = summarize(cleanPayload)
        logger.info("\(cleanName, privacy: .public) \(summary, privacy: .public)")

        queue.async { [weak self] in
            guard let self else { return }
            var event = cleanPayload
            event["schema_version"] = 1
            event["artifact_type"] = "plotter_app_event"
            event["timestamp"] = Self.timestamp()
            event["event"] = cleanName
            event["status"] = cleanPayload["status"] as? String ?? "reported"
            self.appendEvent(event)
        }
    }

    func writeState(_ state: [String: Any]) {
        let cleanState = sanitize(state)
        queue.async { [weak self] in
            guard let self else { return }
            var snapshot = cleanState
            snapshot["schema_version"] = 1
            snapshot["artifact_type"] = "plotter_app_state"
            snapshot["updated_at"] = Self.timestamp()
            do {
                try FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
                let data = try self.encoder.encode(JSONObject(snapshot))
                try data.write(to: self.stateURL, options: [.atomic])
            } catch {
                self.logger.error("state_write_failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func appendEvent(_ event: [String: Any]) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: eventsURL.path) {
                let handle = try FileHandle(forWritingTo: eventsURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: eventsURL, options: [.atomic])
            }
            trimEventLogIfNeeded()
        } catch {
            logger.error("event_write_failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trimEventLogIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: eventsURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxEventLogBytes,
              let data = try? Data(contentsOf: eventsURL) else {
            return
        }

        let suffixStart = max(0, data.count - maxEventLogBytes)
        var trimmed = data.suffix(from: suffixStart)
        if let newlineIndex = trimmed.firstIndex(of: 0x0A), newlineIndex < trimmed.endIndex {
            trimmed = trimmed.suffix(from: trimmed.index(after: newlineIndex))
        }
        try? Data(trimmed).write(to: eventsURL, options: [.atomic])
    }

    private func sanitize(_ payload: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in payload.keys.sorted() {
            guard let cleanKey = sanitizeKey(key),
                  let value = sanitizeValue(payload[key]) else {
                continue
            }
            result[cleanKey] = value
        }
        return result
    }

    private func sanitizeValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        switch value {
        case let value as String:
            return sanitizeString(value)
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            guard value.isFinite else { return nil }
            return (value * 1000).rounded() / 1000
        case let value as Float:
            guard value.isFinite else { return nil }
            return (Double(value) * 1000).rounded() / 1000
        case let value as [String: Any]:
            return sanitize(value)
        case let value as [String]:
            return Array(value.prefix(16)).map(sanitizeString)
        case let value as [Double]:
            return value.prefix(16).compactMap { $0.isFinite ? ($0 * 1000).rounded() / 1000 : nil }
        case let value as [Int]:
            return Array(value.prefix(16))
        default:
            return sanitizeString(String(describing: value))
        }
    }

    private func sanitizeKey(_ key: String) -> String? {
        let allowed = key.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
        let trimmed = allowed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    }

    private func sanitizeString(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(maxStringLength))
    }

    private func summarize(_ payload: [String: Any]) -> String {
        let parts = payload.keys.sorted().prefix(8).compactMap { key -> String? in
            guard let value = payload[key] else { return nil }
            if let nested = value as? [String: Any] {
                return "\(key)=\(nested.keys.sorted().joined(separator: ","))"
            }
            return "\(key)=\(sanitizeString(String(describing: value)))"
        }
        return parts.joined(separator: " ")
    }

    private static func resolveDirectoryURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        for key in ["PLOTTER_APP_DIAGNOSTICS_DIR", "PLOTTER_ARTIFACTS_DIR", "ARTIFACTS"] {
            if let value = cleanPath(environment[key]) {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }

        if let sourceRoot = cleanPath(Bundle.main.object(forInfoDictionaryKey: "PlotterSourceRoot") as? String) {
            return URL(fileURLWithPath: sourceRoot, isDirectory: true)
                .appendingPathComponent("artifacts", isDirectory: true)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    private static func cleanPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private struct JSONObject: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as [String: Any]:
            try container.encode(DictionaryValue(value))
        case let value as [Any]:
            try container.encode(ArrayValue(value))
        case let value as String:
            try container.encode(value)
        case let value as Bool:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        default:
            try container.encode(String(describing: value))
        }
    }
}

private struct DictionaryValue: Encodable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for key in value.keys.sorted() {
            guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
            try container.encode(JSONObject(value[key] as Any), forKey: codingKey)
        }
    }
}

private struct ArrayValue: Encodable {
    let value: [Any]

    init(_ value: [Any]) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for item in value {
            try container.encode(JSONObject(item))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
