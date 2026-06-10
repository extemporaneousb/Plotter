import CoreGraphics
import CoreVideo
import Foundation

final class ChangeAnalyzer {
    private let gridWidth = 96
    private let gridHeight = 54

    private var currentSum: [Double] = []
    private var currentCount = 0
    private var previousAverage: [Double]?
    private var lastReportTimestamp: Double?
    private var knownTracks: [TrackState] = []
    private var nextTrackID = 1
    private var reportNumber = 0

    func reset() {
        currentSum = []
        currentCount = 0
        previousAverage = nil
        lastReportTimestamp = nil
        knownTracks = []
        nextTrackID = 1
        reportNumber = 0
    }

    func ingest(
        pixelBuffer: CVPixelBuffer,
        settings: AnalyzerSettings,
        frameNumber: Int,
        timestamp: Double
    ) throws -> ChangeResult? {
        guard settings.changeEnabled else { return nil }

        let start = CFAbsoluteTimeGetCurrent()
        let sample = try sampleGrid(pixelBuffer: pixelBuffer)
        if currentSum.count != sample.count {
            currentSum = Array(repeating: 0, count: sample.count)
            currentCount = 0
            previousAverage = nil
        }

        for index in sample.indices {
            currentSum[index] += sample[index]
        }
        currentCount += 1

        if lastReportTimestamp == nil {
            lastReportTimestamp = timestamp
        }

        guard let lastReportTimestamp,
              timestamp - lastReportTimestamp >= settings.changeReportInterval,
              currentCount > 0
        else {
            return nil
        }

        let currentAverage = currentSum.map { $0 / Double(currentCount) }
        currentSum = Array(repeating: 0, count: sample.count)
        currentCount = 0
        self.lastReportTimestamp = timestamp

        guard let previousAverage else {
            self.previousAverage = currentAverage
            reportNumber += 1
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            return ChangeResult(
                tracks: [],
                report: ChangeReport(
                    sequence: reportNumber,
                    frameNumber: frameNumber,
                    objectCount: 0,
                    changedCells: 0,
                    elapsedMilliseconds: elapsed,
                    strongestTrackID: nil,
                    strongestTrackStrength: 0
                )
            )
        }

        let threshold = max(8.0, 36.0 - settings.changeSensitivity * 28.0)
        let rawObjects = clusterChangedCells(
            currentAverage: currentAverage,
            previousAverage: previousAverage,
            threshold: threshold,
            minChangedCells: settings.minChangedCells,
            pixelBuffer: pixelBuffer
        )

        self.previousAverage = currentAverage
        reportNumber += 1

        let tracks = assignTracks(rawObjects: rawObjects)
        let changedCells = tracks.reduce(0) { $0 + $1.changedCells }
        let strongest = tracks.max { $0.strength < $1.strength }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        return ChangeResult(
            tracks: tracks,
            report: ChangeReport(
                sequence: reportNumber,
                frameNumber: frameNumber,
                objectCount: tracks.count,
                changedCells: changedCells,
                elapsedMilliseconds: elapsed,
                strongestTrackID: strongest?.id,
                strongestTrackStrength: strongest?.strength ?? 0
            )
        )
    }

    private func sampleGrid(pixelBuffer: CVPixelBuffer) throws -> [Double] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ChangeAnalyzerError.missingBaseAddress
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var sample = Array(repeating: 0.0, count: gridWidth * gridHeight)

        for gridY in 0..<gridHeight {
            let sourceY = min(height - 1, (gridY * height) / gridHeight)
            for gridX in 0..<gridWidth {
                let sourceX = min(width - 1, (gridX * width) / gridWidth)
                let offset = sourceY * bytesPerRow + sourceX * 4
                let blue = Double(bytes[offset])
                let green = Double(bytes[offset + 1])
                let red = Double(bytes[offset + 2])
                sample[gridY * gridWidth + gridX] = red * 0.299 + green * 0.587 + blue * 0.114
            }
        }

        return sample
    }

    private func clusterChangedCells(
        currentAverage: [Double],
        previousAverage: [Double],
        threshold: Double,
        minChangedCells: Int,
        pixelBuffer: CVPixelBuffer
    ) -> [RawMotionObject] {
        let active = currentAverage.indices.map { index in
            abs(currentAverage[index] - previousAverage[index]) >= threshold
        }
        var visited = Array(repeating: false, count: active.count)
        var objects: [RawMotionObject] = []

        for index in active.indices where active[index] && !visited[index] {
            var queue = [index]
            var cursor = 0
            visited[index] = true
            var cells: [Int] = []

            while cursor < queue.count {
                let cell = queue[cursor]
                cursor += 1
                cells.append(cell)

                let x = cell % gridWidth
                let y = cell / gridWidth

                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let neighborX = x + dx
                        let neighborY = y + dy
                        guard neighborX >= 0, neighborX < gridWidth, neighborY >= 0, neighborY < gridHeight else {
                            continue
                        }

                        let neighbor = neighborY * gridWidth + neighborX
                        guard active[neighbor], !visited[neighbor] else { continue }
                        visited[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }

            guard cells.count >= minChangedCells else { continue }

            let object = makeRawObject(
                cells: cells,
                currentAverage: currentAverage,
                previousAverage: previousAverage,
                pixelBuffer: pixelBuffer
            )
            objects.append(object)
        }

        return objects
            .sorted { $0.changedCells > $1.changedCells }
            .prefix(24)
            .map { $0 }
    }

    private func makeRawObject(
        cells: [Int],
        currentAverage: [Double],
        previousAverage: [Double],
        pixelBuffer: CVPixelBuffer
    ) -> RawMotionObject {
        var minX = gridWidth
        var maxX = 0
        var minY = gridHeight
        var maxY = 0
        var totalDiff = 0.0

        for cell in cells {
            let x = cell % gridWidth
            let y = cell / gridWidth
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            totalDiff += abs(currentAverage[cell] - previousAverage[cell])
        }

        let normalized = CGRect(
            x: CGFloat(minX) / CGFloat(gridWidth),
            y: 1.0 - CGFloat(maxY + 1) / CGFloat(gridHeight),
            width: CGFloat(maxX - minX + 1) / CGFloat(gridWidth),
            height: CGFloat(maxY - minY + 1) / CGFloat(gridHeight)
        )
        let pixelArea = normalized.width
            * CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            * normalized.height
            * CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let strength = min(1.0, (totalDiff / Double(cells.count)) / 90.0)

        return RawMotionObject(
            boundingBox: normalized,
            center: CGPoint(x: normalized.midX, y: normalized.midY),
            changedCells: cells.count,
            pixelArea: pixelArea,
            strength: strength
        )
    }

    private func assignTracks(rawObjects: [RawMotionObject]) -> [MotionTrack] {
        var usedTrackIndexes = Set<Int>()
        var updatedStates: [TrackState] = []
        var tracks: [MotionTrack] = []

        for rawObject in rawObjects {
            let matchIndex = bestMatchIndex(for: rawObject, usedTrackIndexes: usedTrackIndexes)
            let id: Int
            let age: Int
            let velocity: CGPoint

            if let matchIndex {
                usedTrackIndexes.insert(matchIndex)
                let previous = knownTracks[matchIndex]
                id = previous.id
                age = previous.ageReports + 1
                velocity = CGPoint(
                    x: rawObject.center.x - previous.center.x,
                    y: rawObject.center.y - previous.center.y
                )
            } else {
                id = nextTrackID
                nextTrackID += 1
                age = 1
                velocity = .zero
            }

            updatedStates.append(
                TrackState(
                    id: id,
                    center: rawObject.center,
                    boundingBox: rawObject.boundingBox,
                    ageReports: age
                )
            )
            tracks.append(
                MotionTrack(
                    id: id,
                    boundingBox: rawObject.boundingBox,
                    center: rawObject.center,
                    velocity: velocity,
                    changedCells: rawObject.changedCells,
                    pixelArea: rawObject.pixelArea,
                    strength: rawObject.strength,
                    ageReports: age
                )
            )
        }

        knownTracks = updatedStates
        return tracks
    }

    private func bestMatchIndex(for rawObject: RawMotionObject, usedTrackIndexes: Set<Int>) -> Int? {
        var bestIndex: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for (index, track) in knownTracks.enumerated() where !usedTrackIndexes.contains(index) {
            let distance = hypot(rawObject.center.x - track.center.x, rawObject.center.y - track.center.y)
            let overlapBonus = rawObject.boundingBox.intersection(track.boundingBox).isNull ? 0.0 : -0.08
            let score = Double(distance) + overlapBonus
            guard score < bestScore, distance < 0.18 else { continue }
            bestScore = score
            bestIndex = index
        }

        return bestIndex
    }
}

struct ChangeResult {
    let tracks: [MotionTrack]
    let report: ChangeReport
}

private struct RawMotionObject {
    let boundingBox: CGRect
    let center: CGPoint
    let changedCells: Int
    let pixelArea: CGFloat
    let strength: Double
}

private struct TrackState {
    let id: Int
    let center: CGPoint
    let boundingBox: CGRect
    let ageReports: Int
}

private enum ChangeAnalyzerError: LocalizedError {
    case missingBaseAddress

    var errorDescription: String? {
        "The camera frame could not be read for change analysis."
    }
}
