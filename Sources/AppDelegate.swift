import AppKit
import AVFoundation
import Vision
import Carbon.HIToolbox
import os.log

private let log = OSLog(subsystem: "com.posturr", category: "AppDelegate")

// MARK: - Icon Masking Utility

func applyMacOSIconMask(to image: NSImage) -> NSImage {
    let size = NSSize(width: 512, height: 512)

    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return image }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)

    let cornerRadius = size.width * 0.2237
    let rect = NSRect(origin: .zero, size: size)

    NSColor.clear.setFill()
    rect.fill()

    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()

    let result = NSImage(size: size)
    result.addRepresentation(bitmapRep)
    return result
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // UI Components
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var enabledMenuItem: NSMenuItem!
    var recalibrateMenuItem: NSMenuItem!

    // Overlay windows and blur
    var windows: [NSWindow] = []
    var blurViews: [NSVisualEffectView] = []
    var currentBlurRadius: Int32 = 0
    var targetBlurRadius: Int32 = 0

    // Warning overlay (alternative to blur)
    var warningOverlayManager = WarningOverlayManager()
    var warningMode: WarningMode = .blur
    var warningColor: NSColor = WarningDefaults.color

    // MARK: - Posture Detectors

    let cameraDetector = CameraPostureDetector()
    let airPodsDetector = AirPodsPostureDetector()

    var trackingSource: TrackingSource = .camera {
        didSet {
            if oldValue != trackingSource {
                syncDetectorToState()
            }
        }
    }

    var activeDetector: PostureDetector {
        trackingSource == .camera ? cameraDetector : airPodsDetector
    }

    // Calibration data storage
    var cameraCalibration: CameraCalibrationData?
    var airPodsCalibration: AirPodsCalibrationData?

    var currentCalibration: CalibrationData? {
        trackingSource == .camera ? cameraCalibration : airPodsCalibration
    }

    // Legacy camera ID accessor for settings
    var selectedCameraID: String? {
        get { cameraDetector.selectedCameraID }
        set { cameraDetector.selectedCameraID = newValue }
    }

    // Calibration
    var calibrationController: CalibrationWindowController?
    var isCalibrated: Bool {
        currentCalibration?.isValid ?? false
    }

    // Settings
    var intensity: CGFloat = 1.0
    var deadZone: CGFloat = 0.03
    var useCompatibilityMode = false
    var blurWhenAway = false {
        didSet {
            cameraDetector.blurWhenAway = blurWhenAway
            if !blurWhenAway {
                handleAwayStateChange(false)
            }
        }
    }
    var showInDock = false
    var pauseOnTheGo = false
    var detectionMode: DetectionMode = .balanced
    var settingsWindowController = SettingsWindowController()
    var analyticsWindowController: AnalyticsWindowController?
    var onboardingWindowController: OnboardingWindowController?

    // Display management
    var displayDebounceTimer: Timer?

    // Camera observers
    var cameraConnectedObserver: NSObjectProtocol?
    var cameraDisconnectedObserver: NSObjectProtocol?

    // Screen lock observers
    var screenLockObserver: NSObjectProtocol?
    var screenUnlockObserver: NSObjectProtocol?
    var stateBeforeLock: AppState?

    // Detection state
    var consecutiveBadFrames = 0
    var consecutiveGoodFrames = 0
    let frameThreshold = 8

    // Hysteresis
    var isCurrentlySlouching = false
    var isCurrentlyAway = false

    // Separate intensities for different concerns (0.0 to 1.0)
    var postureWarningIntensity: CGFloat = 0

    // Blur onset delay
    var warningOnsetDelay: Double = 0.0
    var badPostureStartTime: Date?

    // Global keyboard shortcut (Carbon API)
    var toggleShortcutEnabled = true
    var toggleShortcut = KeyboardShortcut.defaultShortcut
    var carbonHotKeyRef: EventHotKeyRef?
    var carbonEventHandler: EventHandlerRef?

    // Frame throttling
    var frameInterval: TimeInterval {
        isCurrentlySlouching ? 0.1 : (1.0 / detectionMode.frameRate)
    }

    var setupComplete = false

    // MARK: - State Machine

    private var _state: AppState = .disabled
    var state: AppState {
        get { _state }
        set {
            guard newValue != _state else { return }
            let oldState = _state
            _state = newValue
            handleStateTransition(from: oldState, to: newValue)
        }
    }

    private func handleStateTransition(from oldState: AppState, to newState: AppState) {
        os_log(.info, log: log, "State transition: %{public}@ -> %{public}@", String(describing: oldState), String(describing: newState))
        syncDetectorToState()
        if !newState.isActive {
            targetBlurRadius = 0
            postureWarningIntensity = 0
        }
        syncUIToState()
    }

    private func syncDetectorToState() {
        var shouldRun: Bool
        switch state {
        case .calibrating, .monitoring:
            shouldRun = true
        case .disabled, .paused:
            shouldRun = false
        }

        // Special case: Keep AirPods detector running when paused due to removal
        // so we can detect when they're put back in ears
        if case .paused(.airPodsRemoved) = state, trackingSource == .airpods {
            shouldRun = true
        }

        // Stop the other detector
        if trackingSource == .camera {
            if airPodsDetector.isActive {
                airPodsDetector.stop()
            }
        } else {
            if cameraDetector.isActive {
                cameraDetector.stop()
            }
        }

        // Start/stop the active detector
        if shouldRun {
            if !activeDetector.isActive {
                activeDetector.start { [weak self] success, error in
                    if !success, let error = error {
                        os_log(.error, log: log, "Failed to start detector: %{public}@", error)
                        self?.state = .paused(.cameraDisconnected)
                    }
                }
            }
        } else {
            if activeDetector.isActive {
                activeDetector.stop()
            }
        }
    }

    private func syncUIToState() {
        switch state {
        case .disabled:
            statusMenuItem.title = "Status: Disabled"
            statusItem.button?.image = NSImage(systemSymbolName: "figure.stand.line.dotted.figure.stand", accessibilityDescription: "Disabled")

        case .calibrating:
            statusMenuItem.title = "Status: Calibrating..."
            statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Calibrating")

        case .monitoring:
            if isCalibrated {
                statusMenuItem.title = "Status: Good Posture"
                statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Good Posture")
            } else {
                statusMenuItem.title = "Status: Starting..."
                statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Posturr")
            }

        case .paused(let reason):
            switch reason {
            case .noProfile:
                statusMenuItem.title = "Status: Calibration needed"
            case .onTheGo:
                statusMenuItem.title = "Status: Paused (on the go - recalibrate)"
            case .cameraDisconnected:
                statusMenuItem.title = trackingSource == .camera ? "Status: Camera disconnected" : "Status: AirPods disconnected"
            case .screenLocked:
                statusMenuItem.title = "Status: Paused (screen locked)"
            case .airPodsRemoved:
                statusMenuItem.title = "Status: Paused (put in AirPods)"
            }
            statusItem.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
        }

        enabledMenuItem.state = (state != .disabled) ? .on : .off
        recalibrateMenuItem.isEnabled = state != .calibrating
    }

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()

        if showInDock {
            NSApp.setActivationPolicy(.regular)
        }

        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = applyMacOSIconMask(to: icon)
        }

        setupDetectors()
        setupMenuBar()
        setupOverlayWindows()

        if warningMode.usesWarningOverlay {
            warningOverlayManager.mode = warningMode
            warningOverlayManager.warningColor = warningColor
            warningOverlayManager.setupOverlayWindows()
        }

        registerDisplayChangeCallback()
        registerCameraChangeNotifications()
        registerScreenLockNotifications()
        registerGlobalHotKey()

        Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateBlur()
        }

        initialSetupFlow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
    }

    // MARK: - Detector Setup

    private func setupDetectors() {
        // Configure camera detector
        cameraDetector.blurWhenAway = blurWhenAway
        cameraDetector.baseFrameInterval = 1.0 / detectionMode.frameRate

        cameraDetector.onPostureReading = { [weak self] reading in
            self?.handlePostureReading(reading)
        }

        cameraDetector.onAwayStateChange = { [weak self] isAway in
            self?.handleAwayStateChange(isAway)
        }

        // Configure AirPods detector
        airPodsDetector.onPostureReading = { [weak self] reading in
            self?.handlePostureReading(reading)
        }

        airPodsDetector.onConnectionStateChange = { [weak self] isConnected in
            self?.handleConnectionStateChange(isConnected)
        }
    }

    private func handleConnectionStateChange(_ isConnected: Bool) {
        // Only AirPods uses connection state changes currently
        guard trackingSource == .airpods else { return }

        if isConnected {
            // AirPods back in ears - resume if we were paused due to removal
            if state == .paused(.airPodsRemoved) {
                os_log(.info, log: log, "AirPods back in ears - resuming monitoring")
                startMonitoring()
            }
        } else {
            // AirPods removed - pause monitoring
            if state == .monitoring {
                os_log(.info, log: log, "AirPods removed - pausing monitoring")
                state = .paused(.airPodsRemoved)
                isCurrentlySlouching = false
                postureWarningIntensity = 0
                updateBlur()
                syncUIToState()
            }
        }
    }

    private func handlePostureReading(_ reading: PostureReading) {
        guard state == .monitoring else { return }

        // Track analytics
        AnalyticsManager.shared.trackTime(interval: frameInterval, isSlouching: isCurrentlySlouching)

        if reading.isBadPosture {
            consecutiveBadFrames += 1
            consecutiveGoodFrames = 0

            if consecutiveBadFrames >= frameThreshold {
                // Start tracking when bad posture began
                if badPostureStartTime == nil {
                    badPostureStartTime = Date()
                }

                // Check onset delay
                let elapsedTime = Date().timeIntervalSince(badPostureStartTime!)
                guard elapsedTime >= warningOnsetDelay else { return }

                // Record slouch event only once when transitioning
                if !isCurrentlySlouching {
                    AnalyticsManager.shared.recordSlouchEvent()
                }

                isCurrentlySlouching = true

                // Adjust severity by intensity setting
                let adjustedSeverity = pow(reading.severity, 1.0 / Double(intensity))
                postureWarningIntensity = CGFloat(adjustedSeverity)

                DispatchQueue.main.async {
                    self.statusMenuItem.title = "Status: Slouching"
                    self.statusItem.button?.image = NSImage(systemSymbolName: "figure.fall", accessibilityDescription: "Bad Posture")
                }
            }
        } else {
            consecutiveGoodFrames += 1
            consecutiveBadFrames = 0
            badPostureStartTime = nil
            postureWarningIntensity = 0

            if consecutiveGoodFrames >= 5 {
                isCurrentlySlouching = false
                DispatchQueue.main.async {
                    self.syncUIToState()
                }
            }
        }

        DispatchQueue.main.async {
            self.updateBlur()
        }
    }

    private func handleAwayStateChange(_ isAway: Bool) {
        guard state == .monitoring else { return }

        isCurrentlyAway = isAway

        if isAway {
            DispatchQueue.main.async {
                self.statusMenuItem.title = "Status: Away"
                self.statusItem.button?.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "Away")
            }
        } else {
            DispatchQueue.main.async {
                self.syncUIToState()
            }
        }
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Posturr")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        updateEnabledMenuItemShortcut()
        menu.addItem(enabledMenuItem)

        recalibrateMenuItem = NSMenuItem(title: "Recalibrate", action: #selector(recalibrate), keyEquivalent: "r")
        recalibrateMenuItem.target = self
        menu.addItem(recalibrateMenuItem)

        menu.addItem(NSMenuItem.separator())

        let statsItem = NSMenuItem(title: "Statistics", action: #selector(showAnalytics), keyEquivalent: "s")
        statsItem.target = self
        statsItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Statistics")
        menu.addItem(statsItem)

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Menu Actions

    @objc func toggleEnabled() {
        if state == .disabled {
            if !isCalibrated {
                state = .paused(.noProfile)
            } else if trackingSource == .camera && !cameraDetector.isAvailable {
                state = .paused(.cameraDisconnected)
            } else if trackingSource == .airpods && !airPodsDetector.isAvailable {
                state = .paused(.cameraDisconnected)
            } else {
                startMonitoring()
            }
        } else {
            state = .disabled
        }
        saveSettings()
    }

    @objc func recalibrate() {
        startCalibration()
    }

    @objc func showAnalytics() {
        if analyticsWindowController == nil {
            analyticsWindowController = AnalyticsWindowController()
        }
        analyticsWindowController?.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        settingsWindowController.showSettings(appDelegate: self, fromStatusItem: statusItem)
    }

    @objc func quit() {
        cameraDetector.stop()
        airPodsDetector.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Initial Setup Flow

    func initialSetupFlow() {
        guard !setupComplete else { return }
        setupComplete = true

        // Check if we have existing calibration
        let configKey = getCurrentConfigKey()

        if trackingSource == .camera {
            if let profile = loadProfile(forKey: configKey) {
                let cameras = cameraDetector.getAvailableCameras()
                if cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
                    cameraDetector.selectedCameraID = profile.cameraID
                    cameraCalibration = CameraCalibrationData(
                        goodPostureY: profile.goodPostureY,
                        badPostureY: profile.badPostureY,
                        neutralY: profile.neutralY,
                        postureRange: profile.postureRange,
                        cameraID: profile.cameraID
                    )
                    startMonitoring()
                    return
                }
            }
        } else if let calibration = airPodsCalibration, calibration.isValid {
            startMonitoring()
            return
        }

        // No valid calibration - show onboarding
        showOnboarding()
    }

    func showOnboarding() {
        onboardingWindowController = OnboardingWindowController()
        onboardingWindowController?.show(
            cameraDetector: cameraDetector,
            airPodsDetector: airPodsDetector
        ) { [weak self] source, cameraID in
            guard let self = self else { return }

            self.trackingSource = source
            if let cameraID = cameraID {
                self.cameraDetector.selectedCameraID = cameraID
            }
            self.saveSettings()

            // Start calibration
            self.startCalibration()
        }
    }

    // MARK: - Tracking Source Management

    func switchTrackingSource(to source: TrackingSource) {
        guard source != trackingSource else { return }

        // Stop current detector
        activeDetector.stop()

        trackingSource = source
        saveSettings()

        // Check if calibration exists for the new source
        if isCalibrated {
            // Existing calibration - start monitoring
            startMonitoring()
        } else {
            // No calibration - start calibration flow
            startCalibration()
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        // Prevent multiple concurrent calibrations (use calibrationController as the lock)
        guard calibrationController == nil else { return }

        os_log(.info, log: log, "Starting calibration for %{public}@", trackingSource.displayName)

        // Request authorization (this shows permission dialog if needed)
        activeDetector.requestAuthorization { [weak self] authorized in
            guard let self = self else { return }

            if !authorized {
                os_log(.error, log: log, "Authorization denied for %{public}@", self.trackingSource.displayName)
                DispatchQueue.main.async {
                    // Reset state since we're not proceeding
                    self.state = self.isCalibrated ? .monitoring : .paused(.noProfile)

                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Permission Required"
                    alert.informativeText = self.trackingSource == .airpods
                        ? "Motion & Fitness Activity permission is required for AirPods tracking. Please enable it in System Settings > Privacy & Security > Motion & Fitness Activity."
                        : "Camera permission is required. Please enable it in System Settings > Privacy & Security > Camera."
                    alert.addButton(withTitle: "Open Settings")
                    alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                }
                return
            }

            // Authorization granted - now start calibration
            DispatchQueue.main.async {
                self.state = .calibrating
                self.startDetectorAndShowCalibration()
            }
        }
    }

    private func startDetectorAndShowCalibration() {
        // Double-check no calibration controller already exists
        guard calibrationController == nil else {
            os_log(.info, log: log, "Skipping calibration window - already exists")
            return
        }

        activeDetector.start { [weak self] success, error in
            guard let self = self else { return }

            if !success {
                os_log(.error, log: log, "Failed to start detector for calibration: %{public}@", error ?? "unknown")
                DispatchQueue.main.async {
                    self.state = .paused(.cameraDisconnected)
                    if self.trackingSource == .camera {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Camera Not Available"
                        alert.informativeText = error ?? "Please make sure your camera is connected and camera access is granted."
                        alert.addButton(withTitle: "Try Again")
                        alert.addButton(withTitle: "Cancel")
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            self.startCalibration()
                        }
                    }
                }
                return
            }

            DispatchQueue.main.async {
                self.calibrationController = CalibrationWindowController()
                self.calibrationController?.start(
                    detector: self.activeDetector,
                    onComplete: { [weak self] values in
                        self?.finishCalibration(values: values)
                    },
                    onCancel: { [weak self] in
                        self?.cancelCalibration()
                    }
                )
            }
        }
    }

    func finishCalibration(values: [Any]) {
        guard values.count >= 4 else {
            cancelCalibration()
            return
        }

        os_log(.info, log: log, "Finishing calibration with %d values", values.count)

        // Create calibration data using the detector
        guard let calibration = activeDetector.createCalibrationData(from: values) else {
            cancelCalibration()
            return
        }

        // Store calibration
        if let cameraCalibration = calibration as? CameraCalibrationData {
            self.cameraCalibration = cameraCalibration
            // Also save as legacy profile
            let profile = ProfileData(
                goodPostureY: cameraCalibration.goodPostureY,
                badPostureY: cameraCalibration.badPostureY,
                neutralY: cameraCalibration.neutralY,
                postureRange: cameraCalibration.postureRange,
                cameraID: cameraCalibration.cameraID
            )
            let configKey = getCurrentConfigKey()
            saveProfile(forKey: configKey, data: profile)
        } else if let airPodsCalibration = calibration as? AirPodsCalibrationData {
            self.airPodsCalibration = airPodsCalibration
        }

        saveSettings()
        calibrationController = nil

        consecutiveBadFrames = 0
        consecutiveGoodFrames = 0

        startMonitoring()
    }

    func cancelCalibration() {
        calibrationController = nil
        if isCalibrated {
            startMonitoring()
        } else {
            state = .paused(.noProfile)
        }
    }

    func startMonitoring() {
        guard let calibration = currentCalibration else {
            state = .paused(.noProfile)
            return
        }

        // For AirPods, check if they're actually in ears before monitoring
        if trackingSource == .airpods && !activeDetector.isConnected {
            os_log(.info, log: log, "AirPods not in ears - pausing instead of monitoring")
            activeDetector.beginMonitoring(with: calibration, intensity: intensity, deadZone: deadZone)
            state = .paused(.airPodsRemoved)
            return
        }

        activeDetector.beginMonitoring(with: calibration, intensity: intensity, deadZone: deadZone)
        state = .monitoring
    }

    // MARK: - Camera Management (for Settings compatibility)

    func getAvailableCameras() -> [AVCaptureDevice] {
        return cameraDetector.getAvailableCameras()
    }

    func restartCamera() {
        guard trackingSource == .camera, let cameraID = selectedCameraID else { return }
        cameraDetector.switchCamera(to: cameraID)
        state = .paused(.noProfile)
    }

    func applyDetectionMode() {
        cameraDetector.baseFrameInterval = 1.0 / detectionMode.frameRate
    }

    // MARK: - Camera Hot-Plug

    func registerCameraChangeNotifications() {
        cameraConnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCameraConnected(notification)
        }

        cameraDisconnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCameraDisconnected(notification)
        }
    }

    func handleCameraConnected(_ notification: Notification) {
        guard trackingSource == .camera else { return }
        syncUIToState()

        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              case .paused(let reason) = state else { return }

        let configKey = getCurrentConfigKey()
        if let profile = loadProfile(forKey: configKey),
           profile.cameraID == device.uniqueID {
            cameraDetector.selectedCameraID = profile.cameraID
            cameraCalibration = CameraCalibrationData(
                goodPostureY: profile.goodPostureY,
                badPostureY: profile.badPostureY,
                neutralY: profile.neutralY,
                postureRange: profile.postureRange,
                cameraID: profile.cameraID
            )
            cameraDetector.switchCamera(to: profile.cameraID)
            startMonitoring()
        } else if reason == .cameraDisconnected {
            state = .paused(.noProfile)
        }
    }

    func handleCameraDisconnected(_ notification: Notification) {
        guard trackingSource == .camera else { return }

        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }

        guard device.uniqueID == selectedCameraID else {
            syncUIToState()
            return
        }

        let cameras = cameraDetector.getAvailableCameras()

        if let fallbackCamera = cameras.first {
            cameraDetector.selectedCameraID = fallbackCamera.uniqueID
            cameraDetector.switchCamera(to: fallbackCamera.uniqueID)

            let configKey = getCurrentConfigKey()
            if let profile = loadProfile(forKey: configKey), profile.cameraID == fallbackCamera.uniqueID {
                cameraCalibration = CameraCalibrationData(
                    goodPostureY: profile.goodPostureY,
                    badPostureY: profile.badPostureY,
                    neutralY: profile.neutralY,
                    postureRange: profile.postureRange,
                    cameraID: profile.cameraID
                )
                startMonitoring()
            } else {
                state = .paused(.noProfile)
            }
        } else {
            state = .paused(.cameraDisconnected)
        }
    }

    // MARK: - Screen Lock Detection

    func registerScreenLockNotifications() {
        let dnc = DistributedNotificationCenter.default()

        screenLockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenLocked()
        }

        screenUnlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenUnlocked()
        }
    }

    func handleScreenLocked() {
        guard state.isActive || (state != .disabled && state != .paused(.screenLocked)) else { return }
        stateBeforeLock = state
        state = .paused(.screenLocked)
    }

    func handleScreenUnlocked() {
        guard case .paused(.screenLocked) = state else { return }

        if let previousState = stateBeforeLock {
            state = previousState
            stateBeforeLock = nil
        } else {
            startMonitoring()
        }
    }

    // MARK: - Global Keyboard Shortcut (Carbon API)

    func registerGlobalHotKey() {
        unregisterGlobalHotKey()

        guard toggleShortcutEnabled else { return }

        let carbonModifiers = carbonModifiersFromNSEvent(toggleShortcut.modifiers)

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x504F5354)
        hotKeyID.id = 1

        if carbonEventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, _) -> OSStatus in
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        DispatchQueue.main.async {
                            appDelegate.toggleEnabled()
                        }
                    }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &(NSApp.delegate as! AppDelegate).carbonEventHandler
            )

            if status != noErr {
                return
            }
        }

        let status = RegisterEventHotKey(
            UInt32(toggleShortcut.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )

        if status != noErr {
            os_log(.error, log: log, "Failed to register hotkey: %d", status)
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKeyRef = carbonHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            carbonHotKeyRef = nil
        }
    }

    func carbonModifiersFromNSEvent(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        return carbonMods
    }

    func updateGlobalKeyMonitor() {
        registerGlobalHotKey()
        updateEnabledMenuItemShortcut()
    }

    func updateEnabledMenuItemShortcut() {
        guard let menuItem = enabledMenuItem else { return }

        if toggleShortcutEnabled {
            menuItem.title = "Enabled (\(toggleShortcut.displayString))"
        } else {
            menuItem.title = "Enabled"
        }
    }

    // MARK: - Persistence

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(intensity, forKey: SettingsKeys.intensity)
        defaults.set(deadZone, forKey: SettingsKeys.deadZone)
        defaults.set(useCompatibilityMode, forKey: SettingsKeys.useCompatibilityMode)
        defaults.set(blurWhenAway, forKey: SettingsKeys.blurWhenAway)
        defaults.set(showInDock, forKey: SettingsKeys.showInDock)
        defaults.set(pauseOnTheGo, forKey: SettingsKeys.pauseOnTheGo)
        defaults.set(detectionMode.rawValue, forKey: SettingsKeys.detectionMode)
        defaults.set(warningMode.rawValue, forKey: SettingsKeys.warningMode)
        defaults.set(warningOnsetDelay, forKey: SettingsKeys.warningOnsetDelay)
        defaults.set(toggleShortcutEnabled, forKey: SettingsKeys.toggleShortcutEnabled)
        defaults.set(Int(toggleShortcut.keyCode), forKey: SettingsKeys.toggleShortcutKeyCode)
        defaults.set(Int(toggleShortcut.modifiers.rawValue), forKey: SettingsKeys.toggleShortcutModifiers)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: warningColor, requiringSecureCoding: false) {
            defaults.set(colorData, forKey: SettingsKeys.warningColor)
        }
        if let cameraID = selectedCameraID {
            defaults.set(cameraID, forKey: SettingsKeys.lastCameraID)
        }
        defaults.set(trackingSource.rawValue, forKey: SettingsKeys.trackingSource)
        if let airPodsCalibration = airPodsCalibration,
           let data = try? JSONEncoder().encode(airPodsCalibration) {
            defaults.set(data, forKey: SettingsKeys.airPodsCalibration)
        }
    }

    func loadSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: SettingsKeys.intensity) != nil {
            intensity = defaults.double(forKey: SettingsKeys.intensity)
        }
        if defaults.object(forKey: SettingsKeys.deadZone) != nil {
            deadZone = defaults.double(forKey: SettingsKeys.deadZone)
        }
        useCompatibilityMode = defaults.bool(forKey: SettingsKeys.useCompatibilityMode)
        blurWhenAway = defaults.bool(forKey: SettingsKeys.blurWhenAway)
        showInDock = defaults.bool(forKey: SettingsKeys.showInDock)
        pauseOnTheGo = defaults.bool(forKey: SettingsKeys.pauseOnTheGo)
        if let modeString = defaults.string(forKey: SettingsKeys.detectionMode),
           let mode = DetectionMode(rawValue: modeString) {
            detectionMode = mode
        }
        cameraDetector.selectedCameraID = defaults.string(forKey: SettingsKeys.lastCameraID)
        if let sourceString = defaults.string(forKey: SettingsKeys.trackingSource),
           let source = TrackingSource(rawValue: sourceString) {
            trackingSource = source
        }
        if let data = defaults.data(forKey: SettingsKeys.airPodsCalibration),
           let calibration = try? JSONDecoder().decode(AirPodsCalibrationData.self, from: data) {
            airPodsCalibration = calibration
        }
        if let modeString = defaults.string(forKey: SettingsKeys.warningMode),
           let mode = WarningMode(rawValue: modeString) {
            warningMode = mode
        }
        if let colorData = defaults.data(forKey: SettingsKeys.warningColor),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
            warningColor = color
        }
        if defaults.object(forKey: SettingsKeys.warningOnsetDelay) != nil {
            warningOnsetDelay = defaults.double(forKey: SettingsKeys.warningOnsetDelay)
        }
        if defaults.object(forKey: SettingsKeys.toggleShortcutEnabled) != nil {
            toggleShortcutEnabled = defaults.bool(forKey: SettingsKeys.toggleShortcutEnabled)
        }
        if defaults.object(forKey: SettingsKeys.toggleShortcutKeyCode) != nil {
            let keyCode = UInt16(defaults.integer(forKey: SettingsKeys.toggleShortcutKeyCode))
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: SettingsKeys.toggleShortcutModifiers)))
            toggleShortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
        }
    }

    func saveProfile(forKey key: String, data: ProfileData) {
        let defaults = UserDefaults.standard
        var profiles = defaults.dictionary(forKey: SettingsKeys.profiles) as? [String: Data] ?? [:]

        if let encoded = try? JSONEncoder().encode(data) {
            profiles[key] = encoded
            defaults.set(profiles, forKey: SettingsKeys.profiles)
        }
    }

    func loadProfile(forKey key: String) -> ProfileData? {
        let defaults = UserDefaults.standard
        guard let profiles = defaults.dictionary(forKey: SettingsKeys.profiles) as? [String: Data],
              let data = profiles[key] else {
            return nil
        }

        return try? JSONDecoder().decode(ProfileData.self, from: data)
    }

    // MARK: - Display Configuration

    func getDisplayUUIDs() -> [String] {
        var uuids: [String] = []

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }

            if let uuid = CGDisplayCreateUUIDFromDisplayID(screenNumber)?.takeRetainedValue() {
                let uuidString = CFUUIDCreateString(nil, uuid) as String
                uuids.append(uuidString)
            }
        }

        return uuids.sorted()
    }

    func getCurrentConfigKey() -> String {
        let displays = getDisplayUUIDs()
        return "displays:\(displays.joined(separator: "+"))"
    }

    func isLaptopOnlyConfiguration() -> Bool {
        let screens = NSScreen.screens
        if screens.count != 1 { return false }

        guard let screen = screens.first,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }

        return CGDisplayIsBuiltin(displayID) != 0
    }

    func registerDisplayChangeCallback() {
        let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

            if flags.contains(.beginConfigurationFlag) {
                return
            }

            appDelegate.scheduleDisplayConfigurationChange()
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(callback, userInfo)
    }

    func scheduleDisplayConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            self?.displayDebounceTimer?.invalidate()
            self?.displayDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.handleDisplayConfigurationChange()
            }
        }
    }

    func handleDisplayConfigurationChange() {
        rebuildOverlayWindows()

        guard state != .disabled else { return }

        if pauseOnTheGo && isLaptopOnlyConfiguration() {
            state = .paused(.onTheGo)
            return
        }

        guard trackingSource == .camera else { return }

        let cameras = cameraDetector.getAvailableCameras()
        let configKey = getCurrentConfigKey()
        let profile = loadProfile(forKey: configKey)

        if cameras.isEmpty {
            state = .paused(.cameraDisconnected)
            return
        }

        if let profile = profile,
           cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
            if selectedCameraID != profile.cameraID {
                cameraDetector.selectedCameraID = profile.cameraID
                cameraDetector.switchCamera(to: profile.cameraID)
            }
            cameraCalibration = CameraCalibrationData(
                goodPostureY: profile.goodPostureY,
                badPostureY: profile.badPostureY,
                neutralY: profile.neutralY,
                postureRange: profile.postureRange,
                cameraID: profile.cameraID
            )
            startMonitoring()
        } else {
            state = .paused(.noProfile)
        }
    }

    // MARK: - Overlay Windows

    func setupOverlayWindows() {
        for screen in NSScreen.screens {
            let frame = screen.visibleFrame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            blurView.blendingMode = .behindWindow
            blurView.material = .fullScreenUI
            blurView.state = .active
            blurView.alphaValue = 0

            window.contentView = blurView
            window.orderFrontRegardless()
            windows.append(window)
            blurViews.append(blurView)
        }
    }

    func rebuildOverlayWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        blurViews.removeAll()
        setupOverlayWindows()

        if warningMode.usesWarningOverlay {
            warningOverlayManager.rebuildOverlayWindows()
        }
    }

    func clearBlur() {
        targetBlurRadius = 0
        currentBlurRadius = 0

        for blurView in blurViews {
            blurView.alphaValue = 0
        }

        #if !APP_STORE
        if let getConnectionID = cgsMainConnectionID,
           let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), 0)
            }
        }
        #endif
    }

    func switchWarningMode(to newMode: WarningMode) {
        clearBlur()

        warningOverlayManager.currentIntensity = 0
        warningOverlayManager.targetIntensity = 0
        for view in warningOverlayManager.overlayViews {
            if let vignetteView = view as? VignetteOverlayView {
                vignetteView.intensity = 0
            } else if let borderView = view as? BorderOverlayView {
                borderView.intensity = 0
            }
        }

        for window in warningOverlayManager.windows {
            window.orderOut(nil)
        }
        warningOverlayManager.windows.removeAll()
        warningOverlayManager.overlayViews.removeAll()

        warningMode = newMode
        if warningMode.usesWarningOverlay {
            warningOverlayManager.mode = warningMode
            warningOverlayManager.warningColor = warningColor
            warningOverlayManager.setupOverlayWindows()
        }
    }

    func updateWarningColor(_ color: NSColor) {
        warningColor = color
        warningOverlayManager.updateColor(color)
    }

    func updateBlur() {
        let privacyBlurIntensity: CGFloat = isCurrentlyAway ? 1.0 : 0.0

        switch warningMode {
        case .blur:
            let combinedIntensity = max(privacyBlurIntensity, postureWarningIntensity)
            targetBlurRadius = Int32(combinedIntensity * 64)
            warningOverlayManager.targetIntensity = 0
        case .none:
            targetBlurRadius = Int32(privacyBlurIntensity * 64)
            warningOverlayManager.targetIntensity = 0
        case .vignette, .border, .solid:
            targetBlurRadius = Int32(privacyBlurIntensity * 64)
            warningOverlayManager.targetIntensity = postureWarningIntensity
        }
        warningOverlayManager.updateWarning()

        if currentBlurRadius < targetBlurRadius {
            currentBlurRadius = min(currentBlurRadius + 1, targetBlurRadius)
        } else if currentBlurRadius > targetBlurRadius {
            currentBlurRadius = max(currentBlurRadius - 3, targetBlurRadius)
        }

        let normalizedBlur = CGFloat(currentBlurRadius) / 64.0
        let visualEffectAlpha = min(1.0, sqrt(normalizedBlur) * 1.2)

        #if APP_STORE
        for blurView in blurViews {
            blurView.alphaValue = visualEffectAlpha
        }
        #else
        if useCompatibilityMode {
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        } else if let getConnectionID = cgsMainConnectionID,
                  let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), currentBlurRadius)
            }
        } else {
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        }
        #endif
    }
}
