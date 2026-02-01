import AppKit
import AVFoundation
import Vision
import os.log

private let log = OSLog(subsystem: "com.posturr", category: "AppDelegate")

// MARK: - MenuBarIconType to MenuBarIcon Conversion

extension MenuBarIconType {
    var menuBarIcon: MenuBarIcon {
        switch self {
        case .good: return .good
        case .bad: return .bad
        case .away: return .away
        case .paused: return .paused
        case .calibrating: return .calibrating
        }
    }
}

// MARK: - App Delegate

public class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
    }

    // UI Components
    let menuBarManager = MenuBarManager()

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
    var intensity: CGFloat = 1.0 {
        didSet { postureConfig.intensity = intensity }
    }
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

    // Observers and monitors
    let displayMonitor = DisplayMonitor()
    let cameraObserver = CameraObserver()
    let screenLockObserver = ScreenLockObserver()
    let hotkeyManager = HotkeyManager()
    var stateBeforeLock: AppState?

    // Detection state - consolidated into PostureEngine types
    var monitoringState = PostureMonitoringState()
    var postureConfig = PostureConfig()

    // Computed properties for backward compatibility
    var isCurrentlySlouching: Bool {
        get { monitoringState.isCurrentlySlouching }
        set { monitoringState.isCurrentlySlouching = newValue }
    }
    var isCurrentlyAway: Bool {
        get { monitoringState.isCurrentlyAway }
        set { monitoringState.isCurrentlyAway = newValue }
    }
    var postureWarningIntensity: CGFloat {
        get { monitoringState.postureWarningIntensity }
        set { monitoringState.postureWarningIntensity = newValue }
    }

    // Blur onset delay
    var warningOnsetDelay: Double = 0.0 {
        didSet { postureConfig.warningOnsetDelay = warningOnsetDelay }
    }

    // Global keyboard shortcut
    var toggleShortcutEnabled = true
    var toggleShortcut = KeyboardShortcut.defaultShortcut

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
        let uiState = PostureUIState.derive(
            from: state,
            isCalibrated: isCalibrated,
            isCurrentlyAway: isCurrentlyAway,
            isCurrentlySlouching: isCurrentlySlouching,
            trackingSource: trackingSource
        )

        menuBarManager.updateStatus(text: uiState.statusText, icon: uiState.icon.menuBarIcon)
        menuBarManager.updateEnabledState(uiState.isEnabled)
        menuBarManager.updateRecalibrateEnabled(uiState.canRecalibrate)
    }

    // MARK: - App Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

        setupObservers()

        Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateBlur()
        }

        initialSetupFlow()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarManager.statusItem.button?.performClick(nil)
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

        // Use PostureEngine for pure logic
        let result = PostureEngine.processReading(
            reading,
            state: monitoringState,
            config: postureConfig,
            frameInterval: frameInterval
        )

        // Update state
        monitoringState = result.newState

        // Execute effects
        for effect in result.effects {
            switch effect {
            case .trackAnalytics(let interval, let isSlouching):
                AnalyticsManager.shared.trackTime(interval: interval, isSlouching: isSlouching)
            case .recordSlouchEvent:
                AnalyticsManager.shared.recordSlouchEvent()
            case .updateUI:
                DispatchQueue.main.async {
                    self.syncUIToState()
                }
            case .updateBlur:
                DispatchQueue.main.async {
                    self.updateBlur()
                }
            }
        }
    }

    private func handleAwayStateChange(_ isAway: Bool) {
        guard state == .monitoring else { return }

        let result = PostureEngine.processAwayChange(isAway: isAway, state: monitoringState)
        monitoringState = result.newState

        if result.shouldUpdateUI {
            DispatchQueue.main.async {
                self.syncUIToState()
            }
        }
    }

    // MARK: - Observers Setup

    private func setupObservers() {
        // Display configuration changes
        displayMonitor.onDisplayConfigurationChange = { [weak self] in
            self?.handleDisplayConfigurationChange()
        }
        displayMonitor.startMonitoring()

        // Camera hot-plug
        cameraObserver.onCameraConnected = { [weak self] device in
            self?.handleCameraConnected(device)
        }
        cameraObserver.onCameraDisconnected = { [weak self] device in
            self?.handleCameraDisconnected(device)
        }
        cameraObserver.startObserving()

        // Screen lock/unlock
        screenLockObserver.onScreenLocked = { [weak self] in
            self?.handleScreenLocked()
        }
        screenLockObserver.onScreenUnlocked = { [weak self] in
            self?.handleScreenUnlocked()
        }
        screenLockObserver.startObserving()

        // Global hotkey
        hotkeyManager.configure(
            enabled: toggleShortcutEnabled,
            shortcut: toggleShortcut,
            onToggle: { [weak self] in
                self?.toggleEnabled()
            }
        )
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        menuBarManager.setup()
        menuBarManager.updateShortcut(enabled: toggleShortcutEnabled, shortcut: toggleShortcut)

        menuBarManager.onToggleEnabled = { [weak self] in
            self?.toggleEnabled()
        }
        menuBarManager.onRecalibrate = { [weak self] in
            self?.startCalibration()
        }
        menuBarManager.onShowAnalytics = { [weak self] in
            self?.showAnalytics()
        }
        menuBarManager.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        menuBarManager.onQuit = { [weak self] in
            self?.quit()
        }
    }

    // MARK: - Menu Actions

    private func toggleEnabled() {
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

    private func showAnalytics() {
        if analyticsWindowController == nil {
            analyticsWindowController = AnalyticsWindowController()
        }
        analyticsWindowController?.showWindow(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        settingsWindowController.showSettings(appDelegate: self, fromStatusItem: menuBarManager.statusItem)
    }

    private func quit() {
        cameraDetector.stop()
        airPodsDetector.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Initial Setup Flow

    func initialSetupFlow() {
        guard !setupComplete else { return }
        setupComplete = true

        // Check if we have existing calibration
        let configKey = DisplayMonitor.getCurrentConfigKey()

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
            let configKey = DisplayMonitor.getCurrentConfigKey()
            saveProfile(forKey: configKey, data: profile)
        } else if let airPodsCalibration = calibration as? AirPodsCalibrationData {
            self.airPodsCalibration = airPodsCalibration
        }

        saveSettings()
        calibrationController = nil

        monitoringState.reset()

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

    private func handleCameraConnected(_ device: AVCaptureDevice) {
        guard trackingSource == .camera else { return }
        syncUIToState()

        guard case .paused(let reason) = state else { return }

        let configKey = DisplayMonitor.getCurrentConfigKey()
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

    private func handleCameraDisconnected(_ device: AVCaptureDevice) {
        guard trackingSource == .camera else { return }

        guard device.uniqueID == selectedCameraID else {
            syncUIToState()
            return
        }

        let cameras = cameraDetector.getAvailableCameras()

        if let fallbackCamera = cameras.first {
            cameraDetector.selectedCameraID = fallbackCamera.uniqueID
            cameraDetector.switchCamera(to: fallbackCamera.uniqueID)

            let configKey = DisplayMonitor.getCurrentConfigKey()
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

    private func handleScreenLocked() {
        guard state.isActive || (state != .disabled && state != .paused(.screenLocked)) else { return }
        stateBeforeLock = state
        state = .paused(.screenLocked)
    }

    private func handleScreenUnlocked() {
        guard case .paused(.screenLocked) = state else { return }

        if let previousState = stateBeforeLock {
            state = previousState
            stateBeforeLock = nil
        } else {
            startMonitoring()
        }
    }

    // MARK: - Global Keyboard Shortcut

    func updateGlobalKeyMonitor() {
        hotkeyManager.isEnabled = toggleShortcutEnabled
        hotkeyManager.shortcut = toggleShortcut
        menuBarManager.updateShortcut(enabled: toggleShortcutEnabled, shortcut: toggleShortcut)
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

    private func handleDisplayConfigurationChange() {
        rebuildOverlayWindows()

        guard state != .disabled else { return }

        if pauseOnTheGo && DisplayMonitor.isLaptopOnlyConfiguration() {
            state = .paused(.onTheGo)
            return
        }

        guard trackingSource == .camera else { return }

        let cameras = cameraDetector.getAvailableCameras()
        let configKey = DisplayMonitor.getCurrentConfigKey()
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
