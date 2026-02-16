import Foundation
import AVFoundation
import Vision
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "CameraDetector")

/// Camera-based posture detection using Vision framework
class CameraPostureDetector: NSObject, PostureDetector {
    // MARK: - PostureDetector Protocol

    let trackingSource: TrackingSource = .camera

    var isAvailable: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .authorized || status == .notDetermined
    }

    private(set) var isActive: Bool = false

    /// Camera is always "connected" - no separate connection state like AirPods
    /// (Camera doesn't have an equivalent to "put in your ears")
    var isConnected: Bool { true }

    /// Connection state changes (not used for camera - always connected when active)
    var onConnectionStateChange: ((Bool) -> Void)?

    /// Camera permission is handled separately via AVCaptureDevice
    var isAuthorized: Bool { true }

    /// Camera authorization is handled in start() - this is a no-op
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    var unavailableReason: String? {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .denied:
            return "Camera access denied. Enable in System Settings > Privacy & Security > Camera."
        case .restricted:
            return "Camera access is restricted on this device."
        default:
            if getAvailableCameras().isEmpty {
                return "No camera found."
            }
            return nil
        }
    }

    var onPostureReading: ((PostureReading) -> Void)?
    var onCalibrationUpdate: ((CalibrationSample) -> Void)?

    // MARK: - Camera State

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "dorso.camera.capture")

    var selectedCameraID: String?
    private var isMonitoring = false
    private var isStarting = false

    // MARK: - Calibration State

    private var calibrationData: CameraCalibrationData?
    private var intensity: CGFloat = 1.0
    private var deadZone: CGFloat = 0.03

    // MARK: - Detection State

    private var currentNoseY: CGFloat = 0.5
    private var currentFaceWidth: CGFloat = 0.0
    private var noseYHistory: [CGFloat] = []
    private let smoothingWindow = 5
    private var isCurrentlySlouching = false

    // Frame throttling
    private var lastFrameTime: Date = .distantPast
    var baseFrameInterval: TimeInterval = 0.25  // Configured frame interval (e.g., from detection mode)

    /// Actual frame interval - faster when slouching for quicker recovery detection
    private var frameInterval: TimeInterval {
        isCurrentlySlouching ? 0.1 : baseFrameInterval
    }

    // MARK: - Away Detection

    var blurWhenAway: Bool = false
    private var consecutiveNoDetectionFrames = 0
    private let awayFrameThreshold = 15
    var onAwayStateChange: ((Bool) -> Void)?
    private var isAway = false

    // MARK: - Lifecycle

    func start(completion: @escaping (Bool, String?) -> Void) {
        // Idempotent start (prevents double-start during calibration/state transitions)
        if isActive || isStarting {
            completion(true, nil)
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            isStarting = true
            setupCamera()
            startSession()
            completion(true, nil)

        case .notDetermined:
            isStarting = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                        self?.startSession()
                        completion(true, nil)
                    } else {
                        self?.isStarting = false
                        completion(false, "Camera access denied")
                    }
                }
            }

        case .denied:
            completion(false, "Camera access denied. Enable in System Settings > Privacy & Security > Camera.")

        case .restricted:
            completion(false, "Camera access is restricted on this device.")

        @unknown default:
            completion(false, "Unknown camera authorization status")
        }
    }

    func stop() {
        os_log(.info, log: log, "Stopping camera capture")
        captureSession?.stopRunning()
        isActive = false
        isMonitoring = false
        isStarting = false
        consecutiveNoDetectionFrames = 0
        isAway = false
    }

    // MARK: - Calibration

    func getCurrentCalibrationValue() -> CalibrationSample {
        let faceWidth: CGFloat? = currentFaceWidth > 0 ? currentFaceWidth : nil
        return .camera(CameraCalibrationSample(noseY: currentNoseY, faceWidth: faceWidth))
    }

    func createCalibrationData(from samples: [CalibrationSample]) -> CalibrationData? {
        var yValues: [CGFloat] = []
        var widthValues: [CGFloat] = []

        for sample in samples {
            guard case .camera(let cameraSample) = sample else { continue }
            yValues.append(cameraSample.noseY)
            if let faceWidth = cameraSample.faceWidth {
                widthValues.append(faceWidth)
            }
        }

        guard yValues.count >= 4 else { return nil }

        let maxY = yValues.max() ?? 0.6
        let minY = yValues.min() ?? 0.4
        let avgY = yValues.reduce(0, +) / CGFloat(yValues.count)
        let range = abs(maxY - minY)
        // Use max face width as baseline - this prevents false positives when user's
        // natural resting position is closer to screen than average calibration position
        let neutralWidth = widthValues.max() ?? 0.0

        os_log(.info, log: log, "Created calibration: goodY=%.3f, badY=%.3f, range=%.3f, neutralWidth=%.3f (max)", maxY, minY, range, neutralWidth)

        return CameraCalibrationData(
            goodPostureY: maxY,
            badPostureY: minY,
            neutralY: avgY,
            postureRange: range,
            cameraID: selectedCameraID ?? "",
            neutralFaceWidth: neutralWidth
        )
    }

    // MARK: - Monitoring

    func beginMonitoring(with calibration: CalibrationData, intensity: CGFloat, deadZone: CGFloat) {
        guard let cameraCalibration = calibration as? CameraCalibrationData else {
            os_log(.error, log: log, "Invalid calibration data type")
            return
        }

        self.calibrationData = cameraCalibration
        self.intensity = intensity
        self.deadZone = deadZone
        self.isMonitoring = true
        self.isCurrentlySlouching = false
        self.noseYHistory.removeAll()
        self.consecutiveNoDetectionFrames = 0
        self.isAway = false

        os_log(.info, log: log, "Started monitoring with intensity=%.2f, deadZone=%.2f", intensity, deadZone)
    }

    func updateParameters(intensity: CGFloat, deadZone: CGFloat) {
        self.intensity = intensity
        self.deadZone = deadZone
    }

    // MARK: - Camera Management

    func getAvailableCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    private func setupCamera() {
        captureSession = AVCaptureSession()

        // Use vga640x480 instead of cif352x288 for better compatibility with professional cameras
        // The CIF preset can cause pixel format issues on cameras like Elgato capture cards
        guard let session = captureSession else { return }

        session.beginConfiguration()

        // Try vga640x480 first (widely supported), fall back to medium if needed
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
            os_log(.info, log: log, "Using VGA 640x480 preset")
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
            os_log(.info, log: log, "Using medium preset (VGA not available)")
        } else {
            // Last resort - use whatever the default is
            os_log(.error, log: log, "Using default preset (VGA/medium not available)")
        }

        let cameras = getAvailableCameras()
        let camera: AVCaptureDevice?

        if let selectedID = selectedCameraID {
            camera = cameras.first { $0.uniqueID == selectedID }
        } else {
            camera = cameras.first { $0.position == .front } ?? cameras.first
        }

        guard let selectedCamera = camera,
              let input = try? AVCaptureDeviceInput(device: selectedCamera) else {
            session.commitConfiguration()
            os_log(.error, log: log, "Failed to create camera input")
            return
        }

        selectedCameraID = selectedCamera.uniqueID
        session.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.alwaysDiscardsLateVideoFrames = true

        // Explicitly set pixel format to 32BGRA for consistent color handling
        // This prevents issues with YUV color space on professional cameras (e.g., Elgato capture cards)
        videoOutput?.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ]
        os_log(.info, log: log, "Configured camera with 32BGRA pixel format")

        videoOutput?.setSampleBufferDelegate(self, queue: captureQueue)

        if let videoOutput = videoOutput {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        os_log(.info, log: log, "Camera setup complete: %{public}@", selectedCamera.localizedName)
    }

    private func startSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, let session = self.captureSession else {
                DispatchQueue.main.async {
                    self?.isActive = false
                    self?.isStarting = false
                    os_log(.error, log: log, "Camera session missing during start")
                }
                return
            }

            session.startRunning()

            DispatchQueue.main.async {
                self.isActive = session.isRunning
                self.isStarting = false
                if session.isRunning {
                    os_log(.info, log: log, "Camera session started")
                } else {
                    os_log(.error, log: log, "Camera session failed to start")
                }
            }
        }
    }

    func switchCamera(to cameraID: String) {
        guard let session = captureSession else { return }

        let wasRunning = session.isRunning

        if wasRunning {
            session.stopRunning()
        }

        session.beginConfiguration()

        // Remove existing inputs
        for input in session.inputs {
            session.removeInput(input)
        }

        let cameras = getAvailableCameras()
        guard let camera = cameras.first(where: { $0.uniqueID == cameraID }),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            session.commitConfiguration()
            os_log(.error, log: log, "Failed to switch to camera: %{public}@", cameraID)
            return
        }

        selectedCameraID = cameraID
        session.addInput(input)

        session.commitConfiguration()

        if wasRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        os_log(.info, log: log, "Switched to camera: %{public}@", camera.localizedName)
    }

    // MARK: - Frame Processing

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let bodyRequest = VNDetectHumanBodyPoseRequest { [weak self] request, error in
            if let results = request.results as? [VNHumanBodyPoseObservation], let body = results.first {
                self?.analyzeBodyPose(body)
            } else {
                self?.tryFaceDetection(pixelBuffer: pixelBuffer)
            }
        }

        do {
            try handler.perform([bodyRequest])
        } catch {
            tryFaceDetection(pixelBuffer: pixelBuffer)
        }
    }

    private func analyzeBodyPose(_ body: VNHumanBodyPoseObservation) {
        guard let nose = try? body.recognizedPoint(.nose), nose.confidence > 0.3 else {
            return
        }

        consecutiveNoDetectionFrames = 0
        handleDetection(noseY: nose.location.y)
    }

    private func tryFaceDetection(pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            if let results = request.results as? [VNFaceObservation], let face = results.first {
                self?.consecutiveNoDetectionFrames = 0
                self?.handleDetection(noseY: face.boundingBox.midY, faceWidth: face.boundingBox.width)
            } else {
                self?.handleNoDetection()
            }
        }

        try? handler.perform([faceRequest])
    }

    private func handleDetection(noseY: CGFloat, faceWidth: CGFloat? = nil) {
        currentNoseY = noseY
        if let width = faceWidth {
            currentFaceWidth = width
        }

        // Send calibration update
        onCalibrationUpdate?(.camera(CameraCalibrationSample(noseY: noseY, faceWidth: faceWidth)))

        // Reset away state only on transitions
        if blurWhenAway, isAway {
            isAway = false
            onAwayStateChange?(false)
        }

        // Evaluate posture if monitoring
        if isMonitoring, let calibration = calibrationData {
            evaluatePosture(currentY: noseY, currentFaceWidth: faceWidth ?? 0, calibration: calibration)
        }
    }

    private func handleNoDetection() {
        guard blurWhenAway else { return }

        consecutiveNoDetectionFrames += 1

        if consecutiveNoDetectionFrames >= awayFrameThreshold, !isAway {
            isAway = true
            onAwayStateChange?(true)
        }
    }

    // MARK: - Posture Evaluation

    private func smoothNoseY(_ rawY: CGFloat) -> CGFloat {
        noseYHistory.append(rawY)
        if noseYHistory.count > smoothingWindow {
            noseYHistory.removeFirst()
        }
        return noseYHistory.reduce(0, +) / CGFloat(noseYHistory.count)
    }

    private func evaluatePosture(currentY: CGFloat, currentFaceWidth: CGFloat, calibration: CameraCalibrationData) {
        let smoothedY = smoothNoseY(currentY)

        // Vertical position detection (slouching down)
        let slouchAmount = calibration.badPostureY - smoothedY
        let deadZoneThreshold = deadZone * calibration.postureRange

        let enterThreshold = deadZoneThreshold
        let exitThreshold = deadZoneThreshold * 0.7
        let threshold = isCurrentlySlouching ? exitThreshold : enterThreshold

        var isBadPosture = slouchAmount > threshold

        // Forward-head detection (moving closer to screen)
        let forwardHeadThreshold = 1.0 + max(CameraCalibrationData.forwardHeadBaseThreshold, deadZone)
        var forwardHeadSeverity: Double = 0.0

        if calibration.neutralFaceWidth > 0 && currentFaceWidth > 0 {
            let ratio = currentFaceWidth / calibration.neutralFaceWidth
            if ratio > forwardHeadThreshold {
                isBadPosture = true
                let sizeExcess = ratio - forwardHeadThreshold
                forwardHeadSeverity = min(1.0, max(0.0, Double(sizeExcess / CameraCalibrationData.forwardHeadSeverityRange)))
            }
        }

        // Calculate combined severity
        var severity: Double = 0.0

        if isBadPosture {
            // Vertical severity
            let pastDeadZone = slouchAmount - deadZoneThreshold
            let remainingRange = max(0.01, calibration.postureRange - deadZoneThreshold)
            let verticalSeverity = min(1.0, max(0.0, pastDeadZone / remainingRange))

            severity = max(Double(verticalSeverity), forwardHeadSeverity)

            // Ensure minimum severity when forward-head posture is detected
            if forwardHeadSeverity > 0 && severity < CameraCalibrationData.forwardHeadMinSeverity {
                severity = CameraCalibrationData.forwardHeadMinSeverity
            }
        }

        // Update hysteresis state
        if isBadPosture {
            isCurrentlySlouching = true
        } else if !isBadPosture && severity == 0 {
            isCurrentlySlouching = false
        }

        let reading = PostureReading(
            timestamp: Date(),
            isBadPosture: isBadPosture,
            severity: severity
        )

        DispatchQueue.main.async {
            self.onPostureReading?(reading)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraPostureDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        autoreleasepool {
            processFrame(pixelBuffer)
        }
    }
}
