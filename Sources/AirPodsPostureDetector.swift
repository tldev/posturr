import Foundation
import CoreMotion
import IOBluetooth
import os.log

private let log = OSLog(subsystem: "com.posturr", category: "AirPodsDetector")

/// Represents a paired AirPods device
struct PairedAirPods {
    let name: String
    let isCompatible: Bool

    var compatibilityText: String {
        isCompatible ? "Compatible" : "No motion sensors"
    }
}

/// AirPods-based posture detection using head motion tracking
class AirPodsPostureDetector: NSObject, PostureDetector {
    // MARK: - PostureDetector Protocol

    let trackingSource: TrackingSource = .airpods

    var isAvailable: Bool {
        guard #available(macOS 14.0, *) else { return false }
        let manager = CMHeadphoneMotionManager()
        return manager.isDeviceMotionAvailable
    }

    private(set) var isActive: Bool = false

    var unavailableReason: String? {
        if #unavailable(macOS 14.0) {
            return "Requires macOS 14.0 or later"
        }
        if !isAvailable {
            return "No compatible AirPods connected"
        }
        return nil
    }

    /// Check if Motion & Fitness Activity permission is authorized
    var isAuthorized: Bool {
        guard #available(macOS 14.0, *) else { return false }
        return CMHeadphoneMotionManager.authorizationStatus() == .authorized
    }

    /// Request Motion & Fitness Activity permission
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(false)
            return
        }

        let status = CMHeadphoneMotionManager.authorizationStatus()
        os_log(.info, log: log, "requestAuthorization: current status = %{public}@",
               String(describing: status))

        switch status {
        case .authorized:
            os_log(.info, log: log, "Already authorized, proceeding")
            completion(true)
        case .denied, .restricted:
            os_log(.info, log: log, "Authorization denied/restricted")
            completion(false)
        case .notDetermined:
            // Need to trigger permission request by starting motion updates
            if motionManager == nil {
                motionManager = CMHeadphoneMotionManager()
            }
            guard let manager = motionManager else {
                completion(false)
                return
            }

            // Start updates to trigger permission dialog
            os_log(.info, log: log, "Status notDetermined - starting motion updates to trigger dialog")
            var hasCompleted = false
            manager.startDeviceMotionUpdates(to: .main) { _, _ in
                guard !hasCompleted else { return }
                // Check if now authorized
                let newStatus = CMHeadphoneMotionManager.authorizationStatus()
                if newStatus == .authorized {
                    hasCompleted = true
                    os_log(.info, log: log, "Permission granted via motion callback")
                    // Stop these temporary updates - will be restarted properly later
                    manager.stopDeviceMotionUpdates()
                    DispatchQueue.main.async {
                        completion(true)
                    }
                } else if newStatus == .denied || newStatus == .restricted {
                    hasCompleted = true
                    os_log(.info, log: log, "Permission denied via motion callback")
                    manager.stopDeviceMotionUpdates()
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
                // If still notDetermined, keep waiting for user to respond to dialog
            }
        @unknown default:
            completion(false)
        }
    }

    // MARK: - Paired AirPods Detection

    /// Get all paired AirPods devices
    func getPairedAirPods() -> [PairedAirPods] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }

        var airPodsList: [PairedAirPods] = []

        for device in devices {
            guard let name = device.name else { continue }
            let lowercaseName = name.lowercased()

            // Check if it's AirPods
            guard lowercaseName.contains("airpods") else { continue }

            // Determine compatibility (Pro, Max, and 3rd gen have motion sensors)
            let isCompatible = lowercaseName.contains("pro") ||
                               lowercaseName.contains("max") ||
                               lowercaseName.contains("3") ||
                               lowercaseName.contains("4")

            airPodsList.append(PairedAirPods(name: name, isCompatible: isCompatible))
        }

        return airPodsList
    }

    var onPostureReading: ((PostureReading) -> Void)?
    var onCalibrationUpdate: ((Any) -> Void)?

    // MARK: - Internal State

    // Store as Any? to avoid availability annotation on the class
    private var _motionManager: Any?

    @available(macOS 14.0, *)
    private var motionManager: CMHeadphoneMotionManager? {
        get { _motionManager as? CMHeadphoneMotionManager }
        set { _motionManager = newValue }
    }

    private var calibrationData: AirPodsCalibrationData?
    private var intensity: CGFloat = 1.0
    private var deadZone: CGFloat = 0.03
    private var isMonitoring = false

    // Current motion values
    private(set) var currentPitch: Double = 0.0
    private(set) var currentRoll: Double = 0.0
    private(set) var currentYaw: Double = 0.0


    // MARK: - Thresholds

    /// Base threshold in radians (~8.5 degrees)
    private let baseThreshold: Double = 0.15

    /// Maximum additional threshold from dead zone setting (~28 degrees)
    private let maxDeadZoneThreshold: Double = 0.5

    /// Maximum excess past threshold for full severity (~17 degrees)
    private let maxExcessForFullSeverity: Double = 0.3

    // MARK: - Connection State (Protocol)

    /// Whether AirPods are currently in ears and receiving motion data
    var isConnected: Bool { isReceivingMotionData }

    /// Callback when connection state changes (AirPods put in or removed from ears)
    var onConnectionStateChange: ((Bool) -> Void)? {
        get { onMotionDataAvailabilityChange }
        set { onMotionDataAvailabilityChange = newValue }
    }

    // MARK: - Internal Connection State

    /// Internal state tracking - use isConnected for external access
    private(set) var isReceivingMotionData: Bool = false

    /// Internal callback - use onConnectionStateChange for external access
    var onMotionDataAvailabilityChange: ((Bool) -> Void)?

    func start(completion: @escaping (Bool, String?) -> Void) {
        guard #available(macOS 14.0, *) else {
            os_log(.error, log: log, "macOS 14.0+ required for AirPods tracking")
            completion(false, "Requires macOS 14.0 or later")
            return
        }

        if motionManager == nil {
            motionManager = CMHeadphoneMotionManager()
        }

        guard let manager = motionManager else {
            completion(false, "Failed to create motion manager")
            return
        }

        guard manager.isDeviceMotionAvailable else {
            completion(false, "No compatible AirPods paired. Please pair AirPods Pro, Max, or 3rd gen.")
            return
        }

        // If already running, complete immediately
        if manager.isDeviceMotionActive {
            completion(true, nil)
            return
        }

        os_log(.info, log: log, "Starting AirPods motion tracking")

        // Set delegate for connection status callbacks
        manager.delegate = self
        manager.startConnectionStatusUpdates()
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self, self.isActive else { return }

            if let error = error {
                os_log(.error, log: log, "Motion update error: %{public}@", error.localizedDescription)
                return
            }

            guard let motion = motion else { return }

            // If we're receiving motion data, AirPods are in ears
            // This is a fallback in case the delegate doesn't fire
            if !self.isReceivingMotionData {
                os_log(.info, log: log, "Received motion data - AirPods connected (fallback)")
                self.isReceivingMotionData = true
                self.onMotionDataAvailabilityChange?(true)
            }

            // Extract Euler angles (in radians)
            self.currentPitch = motion.attitude.pitch
            self.currentRoll = motion.attitude.roll
            self.currentYaw = motion.attitude.yaw

            // Send calibration update if handler is set
            self.onCalibrationUpdate?((self.currentPitch, self.currentRoll, self.currentYaw))

            // Evaluate posture if monitoring
            if self.isMonitoring, let calibration = self.calibrationData {
                self.evaluatePosture(calibration: calibration)
            }
        }

        // Complete immediately - calibration screen will wait for connection
        isActive = true
        completion(true, nil)
    }

    func stop() {
        os_log(.info, log: log, "Stopping AirPods motion tracking")
        if #available(macOS 14.0, *) {
            motionManager?.stopDeviceMotionUpdates()
            motionManager?.stopConnectionStatusUpdates()
            motionManager?.delegate = nil
        }
        isActive = false
        isReceivingMotionData = false
        isMonitoring = false
    }

    // MARK: - Calibration

    func getCurrentCalibrationValue() -> Any {
        return (currentPitch, currentRoll, currentYaw)
    }

    func createCalibrationData(from points: [Any]) -> CalibrationData? {
        let motionPoints = points.compactMap { $0 as? (Double, Double, Double) }
        guard !motionPoints.isEmpty else { return nil }

        // Average all captured points
        let avgPitch = motionPoints.map { $0.0 }.reduce(0, +) / Double(motionPoints.count)
        let avgRoll = motionPoints.map { $0.1 }.reduce(0, +) / Double(motionPoints.count)
        let avgYaw = motionPoints.map { $0.2 }.reduce(0, +) / Double(motionPoints.count)

        os_log(.info, log: log, "Created calibration: pitch=%.3f, roll=%.3f, yaw=%.3f", avgPitch, avgRoll, avgYaw)

        return AirPodsCalibrationData(pitch: avgPitch, roll: avgRoll, yaw: avgYaw)
    }

    // MARK: - Monitoring

    func beginMonitoring(with calibration: CalibrationData, intensity: CGFloat, deadZone: CGFloat) {
        guard let airPodsCalibration = calibration as? AirPodsCalibrationData else {
            os_log(.error, log: log, "Invalid calibration data type")
            return
        }

        self.calibrationData = airPodsCalibration
        self.intensity = intensity
        self.deadZone = deadZone
        self.isMonitoring = true

        os_log(.info, log: log, "Started monitoring with intensity=%.2f, deadZone=%.2f", intensity, deadZone)
    }

    func updateParameters(intensity: CGFloat, deadZone: CGFloat) {
        self.intensity = intensity
        self.deadZone = deadZone
    }

    // MARK: - Posture Evaluation

    private func evaluatePosture(calibration: AirPodsCalibrationData) {
        // Calculate signed difference (Current - Neutral)
        // Looking down decreases pitch (negative direction)
        let diff = currentPitch - calibration.pitch

        // Threshold: base + scaled dead zone
        let threshold = baseThreshold + (Double(deadZone) * maxDeadZoneThreshold)

        // Only detect forward lean (negative diff exceeding threshold)
        // Leaning back (positive diff) is ignored (e.g., stretching)
        let isBadPosture = diff < -threshold

        // Calculate severity
        var severity: Double = 0
        if isBadPosture {
            // How much past the threshold?
            let excess = abs(diff) - threshold
            severity = min(1.0, excess / maxExcessForFullSeverity)
        }

        let reading = PostureReading(
            timestamp: Date(),
            isBadPosture: isBadPosture,
            severity: severity
        )

        onPostureReading?(reading)
    }
}

// MARK: - CMHeadphoneMotionManagerDelegate

@available(macOS 14.0, *)
extension AirPodsPostureDetector: CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        os_log(.info, log: log, "AirPods connected (in ears)")
        isReceivingMotionData = true
        let callback = onMotionDataAvailabilityChange
        DispatchQueue.main.async {
            callback?(true)
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        os_log(.info, log: log, "AirPods disconnected (removed from ears)")
        isReceivingMotionData = false
        let callback = onMotionDataAvailabilityChange
        DispatchQueue.main.async {
            callback?(false)
        }
    }
}
