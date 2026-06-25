import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import Vision

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let role: CameraRole
    let session = AVCaptureSession()

    @Published var statusText: String
    @Published var isRunning = false
    @Published var isReceivingFrames = false
    @Published var isPaused = false
    @Published var segmentationEnabled = true {
        didSet { updateSettings { $0.enabled = segmentationEnabled } }
    }
    @Published var sensitivity = 0.68 {
        didSet { updateSettings { $0.sensitivity = sensitivity } }
    }
    @Published var minAreaRatio = 0.0008 {
        didSet { updateSettings { $0.minAreaRatio = minAreaRatio } }
    }
    @Published var changeDetectionEnabled = true {
        didSet { updateSettings { $0.changeEnabled = changeDetectionEnabled } }
    }
    @Published var changeSensitivity = 0.56 {
        didSet { updateSettings { $0.changeSensitivity = changeSensitivity } }
    }
    @Published var changeReportInterval = 1.25 {
        didSet { updateSettings { $0.changeReportInterval = changeReportInterval } }
    }
    @Published var showGrid = true
    @Published var showMeasurements = true
    @Published var availableCameras: [CameraDeviceOption] = []
    @Published var selectedCameraID = ""
    @Published var selectedCameraName = "Camera"
    @Published var segments: [VisionSegment] = []
    @Published var carriageMarker: CarriageMarker?
    @Published var stabilizedCarriageMarker: CarriageMarker?
    @Published var motionTracks: [MotionTrack] = []
    @Published var changeReport = ChangeReport.idle
    @Published var stats = AnalysisStats()
    @Published var videoSize = CGSize(width: 1280, height: 720)

    private let sessionQueue: DispatchQueue
    private let sampleQueue: DispatchQueue
    private let analysisQueue: DispatchQueue
    private let stateLock = NSLock()
    private let analyzer = VisionAnalyzer()
    private let changeAnalyzer = ChangeAnalyzer()
    private let selectedCameraDefaultsKey: String

    private var configured = false
    private var cameraName = "Camera"
    private var streamStartFrame = 0
    private var frameNumber = 0
    private var settings = AnalyzerSettings()
    private var pausedState = false
    private var isAnalyzing = false
    private var lastBuffer: CVPixelBuffer?
    private var lastVideoSize = CGSize.zero
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsFrames = 0
    private var carriageMarkerHistory: [CarriageMarker] = []
    private var carriageMarkerMissCount = 0
    private let carriageMarkerSmoothingWindow = 7
    private let carriageMarkerHoldMisses = 12
    private let carriageMarkerJumpResetDistance = 0.10

    init(role: CameraRole = .plotter) {
        self.role = role
        self.statusText = "\(role.statusPrefix) camera idle"
        self.selectedCameraDefaultsKey = role.defaultsKey
        self.sessionQueue = DispatchQueue(label: "plotter.camera.\(role.rawValue).session", qos: .userInitiated)
        self.sampleQueue = DispatchQueue(label: "plotter.camera.\(role.rawValue).samples", qos: .userInteractive)
        self.analysisQueue = DispatchQueue(label: "plotter.camera.\(role.rawValue).analysis", qos: .userInitiated)
        super.init()
        applyRoleDefaults()
        refreshCameraDevices()
    }

    private func applyRoleDefaults() {
        switch role {
        case .plotter:
            break
        case .face:
            segmentationEnabled = false
            changeDetectionEnabled = false
            showGrid = false
            showMeasurements = false
            updateSettings {
                $0.enabled = false
                $0.greenMarkerEnabled = false
                $0.changeEnabled = false
            }
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            statusText = "Requesting camera access for \(role.title)"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.configureAndStart() : self.markCameraDenied()
                }
            }
        default:
            markCameraDenied()
        }
    }

    func refreshCameraDevices(reconnect: Bool = false) {
        let devices = Self.discoverVideoDevices()
        let selected = preferredCameraDevice(from: devices)
        let selectedName = selected?.localizedName ?? "Camera"
        let status = "\(role.statusPrefix) found \(devices.count) camera\(devices.count == 1 ? "" : "s"): \(selectedName)"
        publishCameraList(devices: devices, selectedDevice: selected, statusText: status)
        if reconnect {
            reconnectSelectedCamera(status: "\(role.statusPrefix) reconnecting: \(selectedName)")
        }
    }

    func selectCamera(_ cameraID: String) {
        guard !cameraID.isEmpty else { return }

        UserDefaults.standard.set(cameraID, forKey: selectedCameraDefaultsKey)
        if let option = availableCameras.first(where: { $0.id == cameraID }) {
            selectedCameraName = option.displayName
            statusText = "\(role.statusPrefix) selected: \(option.displayName)"
        } else {
            selectedCameraName = "Camera"
            statusText = "\(role.statusPrefix) camera selected"
        }
        selectedCameraID = cameraID
        reconnectSelectedCamera(status: "\(role.statusPrefix) reconnecting: \(selectedCameraName)")
    }

    func reconnectSelectedCamera() {
        let devices = Self.discoverVideoDevices()
        let selected = preferredCameraDevice(from: devices)
        publishCameraList(
            devices: devices,
            selectedDevice: selected,
            statusText: "\(role.statusPrefix) reconnecting: \(selected?.localizedName ?? selectedCameraName)"
        )
        reconnectSelectedCamera(status: "\(role.statusPrefix) reconnecting: \(selected?.localizedName ?? selectedCameraName)")
    }

    private func reconnectSelectedCamera(status: String) {
        statusText = status
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.configured = false

            DispatchQueue.main.async {
                self.isRunning = false
                self.isReceivingFrames = false
                self.isPaused = false
                self.segments = []
                self.clearCarriageMarkerObservation()
                self.configureAndStart()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.isReceivingFrames = false
                self.statusText = "\(self.role.statusPrefix) camera stopped"
            }
        }
    }

    func togglePause() {
        let shouldPause = !isPaused
        setPaused(shouldPause)

        if shouldPause {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.isReceivingFrames = false
                    self.isPaused = true
                    self.statusText = "\(self.role.statusPrefix) paused on latest frame"
                }
            }
        } else {
            isPaused = false
            configureAndStart()
        }
    }

    func scanCurrentFrame() {
        guard let buffer = snapshotLastBuffer() else {
            statusText = "\(role.statusPrefix): no frame available"
            return
        }
        var snapshot = settingsSnapshot()
        snapshot.enabled = true
        runAnalysis(on: buffer, settings: snapshot, frame: nextManualFrameNumber(), force: true)
    }

    func clearCarriageMarkerObservation() {
        carriageMarker = nil
        stabilizedCarriageMarker = nil
        carriageMarkerHistory = []
        carriageMarkerMissCount = 0
        stats.carriageMarkerStatus = "CAP --"
    }

    func resetCapMarkerColorTarget() {
        updateSettings {
            $0.capMarkerColorTarget = nil
        }
        clearCarriageMarkerObservation()
        statusText = "\(role.statusPrefix) cap marker using default green"
        scanCurrentFrame()
    }

    func pickCapMarkerColor(cameraPoint: CGPoint) -> CapMarkerColorTarget? {
        guard let buffer = snapshotLastBuffer() else {
            statusText = "\(role.statusPrefix): no frame available for cap color"
            return nil
        }
        guard let target = sampleCapMarkerColor(pixelBuffer: buffer, cameraPoint: cameraPoint) else {
            statusText = "\(role.statusPrefix): cap color sample was too neutral or dark"
            return nil
        }
        updateSettings {
            $0.capMarkerColorTarget = target
        }
        clearCarriageMarkerObservation()
        statusText = String(
            format: "%@ cap marker sampled %@ rgb %.0f %.0f %.0f",
            role.statusPrefix,
            target.label,
            target.red,
            target.green,
            target.blue
        )
        scanCurrentFrame()
        return target
    }

    func inspectInk(cameraPoint: CGPoint, radiusPx: Int = 12) -> InkInspectionResult? {
        guard let buffer = snapshotLastBuffer() else {
            statusText = "\(role.statusPrefix): no frame available for ink check"
            return nil
        }
        guard let result = sampleInkVisibility(
            pixelBuffer: buffer,
            cameraPoint: cameraPoint,
            radiusPx: radiusPx
        ) else {
            statusText = "\(role.statusPrefix): ink check could not sample frame"
            return nil
        }
        statusText = "\(role.statusPrefix) \(result.summary)"
        return result
    }

    func captureFaceRaster(
        columns: Int = 14,
        rows: Int = 18,
        updatesStatus: Bool = true
    ) async throws -> FaceRasterSample {
        guard let buffer = snapshotLastBuffer() else {
            throw CameraError.noFrame
        }
        let frame = snapshotFrameNumber()
        let sample = try buildFaceRaster(
            pixelBuffer: buffer,
            frame: frame,
            columns: columns,
            rows: rows
        )
        if updatesStatus {
            statusText = String(
                format: "%@ face raster %dx%d %.0f%%",
                role.statusPrefix,
                columns,
                rows,
                sample.confidence * 100
            )
        }
        return sample
    }

    func captureFaceRasterBurst(
        columns: Int = 28,
        rows: Int = 36,
        targetFrames: Int = 24,
        minimumFrames: Int = 4,
        maxDurationSeconds: Double = 1.25
    ) async throws -> FaceRasterSample {
        guard columns >= 4, rows >= 4, columns <= 40, rows <= 40 else {
            throw CameraError.invalidRasterSize
        }

        var collected: [FaceRasterSample] = []
        var lastSampledFrame = -1
        var sawFrame = false
        let deadline = CACurrentMediaTime() + maxDurationSeconds

        while collected.count < targetFrames && CACurrentMediaTime() < deadline {
            let frame = snapshotFrameNumber()
            if frame == lastSampledFrame {
                try await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            lastSampledFrame = frame

            guard let buffer = snapshotLastBuffer() else {
                try await Task.sleep(nanoseconds: 25_000_000)
                continue
            }
            sawFrame = true
            if let sample = try? buildFaceRaster(
                pixelBuffer: buffer,
                frame: frame,
                columns: columns,
                rows: rows
            ) {
                collected.append(sample)
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        guard sawFrame else {
            throw CameraError.noFrame
        }
        guard collected.count >= minimumFrames else {
            throw collected.isEmpty ? CameraError.noFace : CameraError.insufficientBurstFrames
        }

        let sample = averageFaceRasterSamples(collected, columns: columns, rows: rows)
        statusText = String(
            format: "%@ portrait burst %df %dx%d %.0f%%",
            role.statusPrefix,
            sample.captureFrameCount,
            columns,
            rows,
            sample.confidence * 100
        )
        return sample
    }

    func resetChangeBaseline() {
        resetChangeBaseline(updateStatus: true)
    }

    func resetChangeBaseline(updateStatus: Bool) {
        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.changeAnalyzer.reset()
            DispatchQueue.main.async {
                self.motionTracks = []
                self.changeReport = .idle
                self.stats.motionCount = 0
                self.stats.reportNumber = 0
                if updateStatus {
                    self.statusText = "\(self.role.statusPrefix) change baseline reset"
                }
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let currentFrame = recordFrame(pixelBuffer: pixelBuffer)
        let snapshot = settingsSnapshot()
        guard (snapshot.enabled || snapshot.greenMarkerEnabled || snapshot.changeEnabled),
              !snapshotPaused(),
              currentFrame % 4 == 0
        else {
            return
        }

        runAnalysis(on: pixelBuffer, settings: snapshot, frame: currentFrame, force: false)
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured {
                    try self.configureSession()
                    self.configured = true
                }
                let frameAtStart = self.snapshotFrameNumber()
                self.streamStartFrame = frameAtStart
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.setPaused(false)
                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    self.isReceivingFrames = false
                    self.isPaused = false
                    self.statusText = self.session.isRunning
                        ? "\(self.role.statusPrefix) starting stream: \(self.cameraName)"
                        : "\(self.role.statusPrefix) failed to start: \(self.cameraName)"
                }
                self.scheduleFrameWatchdog(startFrame: frameAtStart, cameraName: self.cameraName)
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.isReceivingFrames = false
                    self.statusText = "\(self.role.statusPrefix) camera error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let devices = Self.discoverVideoDevices()
        guard let device = preferredCameraDevice(from: devices) else {
            throw CameraError.noCamera
        }

        cameraName = device.localizedName
        UserDefaults.standard.set(device.uniqueID, forKey: selectedCameraDefaultsKey)
        publishCameraList(devices: devices, selectedDevice: device)

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)

        guard session.canAddOutput(output) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func recordFrame(pixelBuffer: CVPixelBuffer) -> Int {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let observedSize = CGSize(width: width, height: height)
        if observedSize != lastVideoSize {
            lastVideoSize = observedSize
            DispatchQueue.main.async { [weak self] in
                self?.videoSize = observedSize
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isReceivingFrames {
                self.isReceivingFrames = true
                self.statusText = "\(self.role.statusPrefix) live: \(self.cameraName) \(Int(width))x\(Int(height))"
            }
        }

        fpsFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1.0 {
            let fps = Double(fpsFrames) / (now - fpsWindowStart)
            fpsFrames = 0
            fpsWindowStart = now
            DispatchQueue.main.async { [weak self] in
                self?.stats.fps = fps
            }
        }

        stateLock.lock()
        frameNumber += 1
        lastBuffer = pixelBuffer
        let currentFrame = frameNumber
        stateLock.unlock()
        return currentFrame
    }

    private func runAnalysis(
        on pixelBuffer: CVPixelBuffer,
        settings: AnalyzerSettings,
        frame: Int,
        force: Bool
    ) {
        stateLock.lock()
        if isAnalyzing && !force {
            stateLock.unlock()
            return
        }
        isAnalyzing = true
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.isAnalyzing = false
                self.stateLock.unlock()
            }

            do {
                let start = CFAbsoluteTimeGetCurrent()
                let visionResult = (settings.enabled || settings.greenMarkerEnabled)
                    ? try self.analyzer.analyze(pixelBuffer: pixelBuffer, settings: settings, frameNumber: frame)
                    : VisionAnalysisResult(
                        segments: [],
                        carriageMarker: nil,
                        elapsedMilliseconds: 0.0
                    )
                let changeResult = try self.changeAnalyzer.ingest(
                    pixelBuffer: pixelBuffer,
                    settings: settings,
                    frameNumber: frame,
                    timestamp: CACurrentMediaTime()
                )
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

                DispatchQueue.main.async {
                    self.segments = visionResult.segments
                    self.publishCarriageMarkerObservation(visionResult.carriageMarker)
                    self.stats.frameNumber = frame
                    self.stats.segmentCount = visionResult.segments.count
                    self.stats.analysisMilliseconds = elapsed
                    self.stats.cameraName = self.cameraName
                    if let changeResult {
                        self.motionTracks = changeResult.tracks
                        self.changeReport = changeResult.report
                        self.stats.motionCount = changeResult.tracks.count
                        self.stats.reportNumber = changeResult.report.sequence
                        self.stats.changeMilliseconds = changeResult.report.elapsedMilliseconds
                    }
                    let changeText = changeResult?.report.summary ?? self.changeReport.summary
                    self.statusText = self.isPaused
                        ? "\(self.role.statusPrefix) still frame analyzed"
                        : "\(self.role.statusPrefix) live: \(self.cameraName)  \(changeText)"
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusText = "\(self.role.statusPrefix) vision error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func publishCarriageMarkerObservation(_ marker: CarriageMarker?) {
        carriageMarker = marker
        guard let marker else {
            carriageMarkerMissCount += 1
            if carriageMarkerMissCount > carriageMarkerHoldMisses {
                stabilizedCarriageMarker = nil
                carriageMarkerHistory = []
                stats.carriageMarkerStatus = "CAP --"
            } else if let stabilizedCarriageMarker {
                stats.carriageMarkerStatus = "CAP \(stabilizedCarriageMarker.colorName) HOLD"
            } else {
                stats.carriageMarkerStatus = "CAP --"
            }
            return
        }

        if let previous = carriageMarkerHistory.last {
            let dx = Double(marker.center.x - previous.center.x)
            let dy = Double(marker.center.y - previous.center.y)
            if hypot(dx, dy) > carriageMarkerJumpResetDistance {
                carriageMarkerHistory.removeAll()
            }
        }

        carriageMarkerMissCount = 0
        carriageMarkerHistory.append(marker)
        if carriageMarkerHistory.count > carriageMarkerSmoothingWindow {
            carriageMarkerHistory.removeFirst(carriageMarkerHistory.count - carriageMarkerSmoothingWindow)
        }
        stabilizedCarriageMarker = averagedCarriageMarker(from: carriageMarkerHistory)
        stats.carriageMarkerStatus = "CAP \(marker.colorName)"
    }

    private func averagedCarriageMarker(from markers: [CarriageMarker]) -> CarriageMarker? {
        guard let latest = markers.last else { return nil }
        let count = CGFloat(markers.count)
        let centerX = markers.reduce(CGFloat.zero) { $0 + $1.center.x } / count
        let centerY = markers.reduce(CGFloat.zero) { $0 + $1.center.y } / count
        let boxX = markers.reduce(CGFloat.zero) { $0 + $1.boundingBox.origin.x } / count
        let boxY = markers.reduce(CGFloat.zero) { $0 + $1.boundingBox.origin.y } / count
        let boxWidth = markers.reduce(CGFloat.zero) { $0 + $1.boundingBox.width } / count
        let boxHeight = markers.reduce(CGFloat.zero) { $0 + $1.boundingBox.height } / count
        let pixelArea = markers.reduce(CGFloat.zero) { $0 + $1.pixelArea } / count
        let strength = markers.reduce(0.0) { $0 + $1.strength } / Double(markers.count)
        return CarriageMarker(
            id: latest.id,
            boundingBox: CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight),
            center: CGPoint(x: centerX, y: centerY),
            pixelArea: pixelArea,
            strength: strength,
            colorName: latest.colorName
        )
    }

    private func updateSettings(_ mutate: (inout AnalyzerSettings) -> Void) {
        stateLock.lock()
        mutate(&settings)
        stateLock.unlock()
    }

    private func settingsSnapshot() -> AnalyzerSettings {
        stateLock.lock()
        let snapshot = settings
        stateLock.unlock()
        return snapshot
    }

    private func setPaused(_ value: Bool) {
        stateLock.lock()
        pausedState = value
        stateLock.unlock()
    }

    private func snapshotPaused() -> Bool {
        stateLock.lock()
        let value = pausedState
        stateLock.unlock()
        return value
    }

    private func snapshotLastBuffer() -> CVPixelBuffer? {
        stateLock.lock()
        let buffer = lastBuffer
        stateLock.unlock()
        return buffer
    }

    private func sampleCapMarkerColor(
        pixelBuffer: CVPixelBuffer,
        cameraPoint: CGPoint
    ) -> CapMarkerColorTarget? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let xNorm = min(1.0, max(0.0, Double(cameraPoint.x)))
        let yNorm = min(1.0, max(0.0, Double(cameraPoint.y)))
        let centerX = Int(round(xNorm * Double(width - 1)))
        let centerY = Int(round((1.0 - yNorm) * Double(height - 1)))
        let radius = max(3, min(8, min(width, height) / 160))

        var redTotal = 0.0
        var greenTotal = 0.0
        var blueTotal = 0.0
        var count = 0.0

        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let offset = x * 4
                blueTotal += Double(row[offset])
                greenTotal += Double(row[offset + 1])
                redTotal += Double(row[offset + 2])
                count += 1.0
            }
        }

        guard count > 0 else { return nil }
        let red = redTotal / count
        let green = greenTotal / count
        let blue = blueTotal / count
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        guard maxChannel >= 45.0, maxChannel - minChannel >= 12.0 else {
            return nil
        }

        let dominant: String
        if green >= red, green >= blue {
            dominant = "PICKED GREEN"
        } else if blue >= red, blue >= green {
            dominant = "PICKED BLUE"
        } else {
            dominant = "PICKED CAP"
        }
        return CapMarkerColorTarget(
            red: red,
            green: green,
            blue: blue,
            tolerance: 0.12,
            label: dominant
        )
    }

    private func sampleInkVisibility(
        pixelBuffer: CVPixelBuffer,
        cameraPoint: CGPoint,
        radiusPx: Int
    ) -> InkInspectionResult? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let xNorm = min(1.0, max(0.0, Double(cameraPoint.x)))
        let yNorm = min(1.0, max(0.0, Double(cameraPoint.y)))
        let centerX = Int(round(xNorm * Double(width - 1)))
        let centerY = Int(round((1.0 - yNorm) * Double(height - 1)))
        let radius = max(6, min(24, radiusPx))
        let ringRadius = min(max(radius + 6, radius * 2), 42)
        let strokeBand = max(2, radius / 4)

        var centerTotal = 0.0
        var centerCount = 0.0
        var surroundTotal = 0.0
        var surroundCount = 0.0
        var darkCount = 0.0
        var horizontalBandCount = 0.0
        var horizontalDarkCount = 0.0
        var verticalBandCount = 0.0
        var verticalDarkCount = 0.0
        var crossBandCount = 0.0
        var crossDarkCount = 0.0

        for y in max(0, centerY - ringRadius)...min(height - 1, centerY + ringRadius) {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in max(0, centerX - ringRadius)...min(width - 1, centerX + ringRadius) {
                let dx = x - centerX
                let dy = y - centerY
                let distance = sqrt(Double(dx * dx + dy * dy))
                let offset = x * 4
                let blue = Double(row[offset])
                let green = Double(row[offset + 1])
                let red = Double(row[offset + 2])
                let luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
                if distance <= Double(radius) {
                    centerTotal += luma
                    centerCount += 1.0
                } else if distance >= Double(radius + 3), distance <= Double(ringRadius) {
                    surroundTotal += luma
                    surroundCount += 1.0
                }
            }
        }

        guard centerCount > 0, surroundCount > 0 else { return nil }
        let centerMean = centerTotal / centerCount
        let surroundMean = surroundTotal / surroundCount
        let darkThreshold = min(0.58, surroundMean - 0.04)

        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let dx = x - centerX
                let dy = y - centerY
                guard sqrt(Double(dx * dx + dy * dy)) <= Double(radius) else { continue }
                let offset = x * 4
                let blue = Double(row[offset])
                let green = Double(row[offset + 1])
                let red = Double(row[offset + 2])
                let luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
                let inHorizontalBand = abs(dy) <= strokeBand
                let inVerticalBand = abs(dx) <= strokeBand
                let inCrossBand = inHorizontalBand || inVerticalBand
                if inHorizontalBand {
                    horizontalBandCount += 1.0
                }
                if inVerticalBand {
                    verticalBandCount += 1.0
                }
                if inCrossBand {
                    crossBandCount += 1.0
                }
                if luma <= darkThreshold {
                    darkCount += 1.0
                    if inHorizontalBand {
                        horizontalDarkCount += 1.0
                    }
                    if inVerticalBand {
                        verticalDarkCount += 1.0
                    }
                    if inCrossBand {
                        crossDarkCount += 1.0
                    }
                }
            }
        }

        return InkInspectionResult(
            centerLuma: centerMean,
            surroundLuma: surroundMean,
            contrast: surroundMean - centerMean,
            darkFraction: darkCount / centerCount,
            horizontalDarkFraction: horizontalBandCount > 0 ? horizontalDarkCount / horizontalBandCount : 0.0,
            verticalDarkFraction: verticalBandCount > 0 ? verticalDarkCount / verticalBandCount : 0.0,
            crossDarkFraction: crossBandCount > 0 ? crossDarkCount / crossBandCount : 0.0
        )
    }

    private func nextManualFrameNumber() -> Int {
        stateLock.lock()
        frameNumber += 1
        let frame = frameNumber
        stateLock.unlock()
        return frame
    }

    private func snapshotFrameNumber() -> Int {
        stateLock.lock()
        let frame = frameNumber
        stateLock.unlock()
        return frame
    }

    private static func discoverVideoDevices() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.sorted {
            if $0.deviceType == .builtInWideAngleCamera && $1.deviceType != .builtInWideAngleCamera {
                return false
            }
            if $0.deviceType != .builtInWideAngleCamera && $1.deviceType == .builtInWideAngleCamera {
                return true
            }
            return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
        }
    }

    private func preferredCameraDevice(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        guard !devices.isEmpty else {
            return AVCaptureDevice.default(for: .video)
        }

        let requestedID = selectedCameraID.isEmpty
            ? UserDefaults.standard.string(forKey: selectedCameraDefaultsKey)
            : selectedCameraID
        if let requestedID,
           let selected = devices.first(where: { $0.uniqueID == requestedID }) {
            return selected
        }

        switch role {
        case .plotter:
            if let external = devices.first(where: { $0.deviceType != .builtInWideAngleCamera }) {
                return external
            }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video)
                ?? devices.first
        case .face:
            if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
                return builtIn
            }
            return AVCaptureDevice.default(for: .video) ?? devices.first
        }
    }

    private func publishCameraList(
        devices: [AVCaptureDevice],
        selectedDevice: AVCaptureDevice?,
        statusText: String? = nil
    ) {
        let options = devices.map {
            CameraDeviceOption(
                id: $0.uniqueID,
                name: $0.localizedName,
                modelID: $0.modelID,
                isExternal: $0.deviceType != .builtInWideAngleCamera
            )
        }
        let selectedID = selectedDevice?.uniqueID ?? ""
        let selectedName = options.first(where: { $0.id == selectedID })?.displayName
            ?? selectedDevice?.localizedName
            ?? "Camera"

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableCameras = options
            self.selectedCameraID = selectedID
            self.selectedCameraName = selectedName
            if let statusText {
                self.statusText = statusText
            }
        }
    }

    private func scheduleFrameWatchdog(startFrame: Int, cameraName: String) {
        sessionQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, self.streamStartFrame == startFrame else { return }
            guard self.snapshotFrameNumber() <= startFrame else { return }

            DispatchQueue.main.async {
                self.isReceivingFrames = false
                self.statusText = "\(self.role.statusPrefix) stream has no frames: \(cameraName)"
            }
        }
    }

    private func buildFaceRaster(
        pixelBuffer: CVPixelBuffer,
        frame: Int,
        columns: Int,
        rows: Int
    ) throws -> FaceRasterSample {
        guard columns >= 4, rows >= 4, columns <= 40, rows <= 40 else {
            throw CameraError.invalidRasterSize
        }

        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let face = request.results?.max(by: { lhs, rhs in
            lhs.boundingBox.width * lhs.boundingBox.height < rhs.boundingBox.width * rhs.boundingBox.height
        }) else {
            throw CameraError.noFace
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let crop = paddedFaceBounds(
            face.boundingBox,
            imageWidth: width,
            imageHeight: height,
            columns: columns,
            rows: rows
        )
        let samples = try sampleLuminanceGrid(
            pixelBuffer: pixelBuffer,
            crop: crop,
            columns: columns,
            rows: rows
        )
        return FaceRasterSample(
            columns: columns,
            rows: rows,
            samples: samples,
            faceBounds: crop,
            frameNumber: frame,
            confidence: Double(face.confidence),
            captureFrameCount: 1,
            luminanceStdDev: luminanceStdDev(samples)
        )
    }

    private func averageFaceRasterSamples(
        _ samples: [FaceRasterSample],
        columns: Int,
        rows: Int
    ) -> FaceRasterSample {
        var totals = Array(repeating: Array(repeating: 0.0, count: columns), count: rows)
        var bounds = CGRect.zero
        var confidence = 0.0

        for sample in samples {
            for row in 0..<rows {
                for column in 0..<columns {
                    totals[row][column] += sample.samples[row][column]
                }
            }
            bounds.origin.x += sample.faceBounds.origin.x
            bounds.origin.y += sample.faceBounds.origin.y
            bounds.size.width += sample.faceBounds.size.width
            bounds.size.height += sample.faceBounds.size.height
            confidence += sample.confidence
        }

        let count = Double(samples.count)
        let averaged = totals.map { row in row.map { $0 / count } }
        bounds.origin.x /= count
        bounds.origin.y /= count
        bounds.size.width /= count
        bounds.size.height /= count

        return FaceRasterSample(
            columns: columns,
            rows: rows,
            samples: averaged,
            faceBounds: bounds,
            frameNumber: samples.last?.frameNumber ?? 0,
            confidence: confidence / count,
            captureFrameCount: samples.count,
            luminanceStdDev: luminanceStdDev(averaged)
        )
    }

    private func paddedFaceBounds(
        _ faceBounds: CGRect,
        imageWidth: Int,
        imageHeight: Int,
        columns: Int,
        rows: Int
    ) -> CGRect {
        let imageAspect = CGFloat(imageWidth) / max(CGFloat(imageHeight), 1)
        let targetAspect = CGFloat(columns) / max(CGFloat(rows), 1)
        var width = faceBounds.width * 1.45
        var height = faceBounds.height * 1.75
        let currentAspect = width * imageAspect / max(height, 0.0001)

        if currentAspect < targetAspect {
            width = height * targetAspect / imageAspect
        } else {
            height = width * imageAspect / targetAspect
        }

        let center = CGPoint(x: faceBounds.midX, y: faceBounds.midY)
        let originX = clampCGFloat(center.x - width / 2, min: 0, max: max(0, 1 - width))
        let originY = clampCGFloat(center.y - height / 2, min: 0, max: max(0, 1 - height))
        return CGRect(
            x: originX,
            y: originY,
            width: min(width, 1),
            height: min(height, 1)
        )
    }

    private func sampleLuminanceGrid(
        pixelBuffer: CVPixelBuffer,
        crop: CGRect,
        columns: Int,
        rows: Int
    ) throws -> [[Double]] {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw CameraError.cannotReadFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw CameraError.cannotReadFrame
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let sampleCount = 3
        var raster: [[Double]] = []
        raster.reserveCapacity(rows)

        for row in 0..<rows {
            var rasterRow: [Double] = []
            rasterRow.reserveCapacity(columns)
            for column in 0..<columns {
                var total = 0.0
                var count = 0
                for sampleY in 0..<sampleCount {
                    for sampleX in 0..<sampleCount {
                        let xFraction = (CGFloat(column) + (CGFloat(sampleX) + 0.5) / CGFloat(sampleCount)) / CGFloat(columns)
                        let yFraction = (CGFloat(row) + (CGFloat(sampleY) + 0.5) / CGFloat(sampleCount)) / CGFloat(rows)
                        let normX = crop.minX + xFraction * crop.width
                        let normY = crop.maxY - yFraction * crop.height
                        let px = clampInt(Int(normX * CGFloat(width)), min: 0, max: width - 1)
                        let py = clampInt(Int((1.0 - normY) * CGFloat(height)), min: 0, max: height - 1)
                        let rowPointer = baseAddress.advanced(by: py * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        let offset = px * 4
                        let blue = Double(rowPointer[offset])
                        let green = Double(rowPointer[offset + 1])
                        let red = Double(rowPointer[offset + 2])
                        total += (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
                        count += 1
                    }
                }
                rasterRow.append(total / Double(max(count, 1)))
            }
            raster.append(rasterRow)
        }
        return raster
    }

    private func luminanceStdDev(_ samples: [[Double]]) -> Double {
        let values = samples.flatMap { $0 }
        guard !values.isEmpty else { return 0.0 }
        let mean = values.reduce(0.0, +) / Double(values.count)
        let variance = values.reduce(0.0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(values.count)
        return sqrt(variance)
    }

    private func markCameraDenied() {
        statusText = "\(role.statusPrefix) camera access denied"
        isRunning = false
        isPaused = false
        segments = []
        clearCarriageMarkerObservation()
        motionTracks = []
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case noFrame
    case noFace
    case invalidRasterSize
    case cannotReadFrame
    case insufficientBurstFrames

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No video camera was found."
        case .cannotAddInput:
            return "The selected camera input could not be added."
        case .cannotAddOutput:
            return "The camera video output could not be added."
        case .noFrame:
            return "No camera frame is available for face drawing."
        case .noFace:
            return "No face was detected in the latest frame."
        case .invalidRasterSize:
            return "Face raster size must be between 4x4 and 40x40."
        case .cannotReadFrame:
            return "The latest camera frame could not be sampled."
        case .insufficientBurstFrames:
            return "Not enough stable face frames were captured for portrait preview."
        }
    }
}

private func clampCGFloat(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.min(maxValue, Swift.max(minValue, value))
}

private func clampInt(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
    Swift.min(maxValue, Swift.max(minValue, value))
}
