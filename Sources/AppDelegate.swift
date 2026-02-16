import AppKit
import AVFoundation
import Vision
import os.log

private let log = OSLog(subsystem: "com.thelazydeveloper.dorso", category: "AppDelegate")

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

@MainActor
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
    let settingsProfileManager = SettingsProfileManager()
    private var appliedWarningColorData: Data?

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
        isMarketingMode || (currentCalibration?.isValid ?? false)
    }

    // Settings
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
    private var lastPostureReadingTime: Date?

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

    // Global keyboard shortcut
    var toggleShortcutEnabled = true
    var toggleShortcut = KeyboardShortcut.defaultShortcut

    // Frame throttling
    var frameInterval: TimeInterval {
        isCurrentlySlouching ? 0.1 : (1.0 / activeDetectionMode.frameRate)
    }

    var activeSettingsProfile: SettingsProfile? {
        settingsProfileManager.activeProfile
    }

    var activeWarningMode: WarningMode {
        activeSettingsProfile?.warningMode ?? .blur
    }

    var activeWarningColor: NSColor {
        activeSettingsProfile?.warningColor ?? WarningDefaults.color
    }

    var activeDeadZone: CGFloat {
        CGFloat(activeSettingsProfile?.deadZone ?? 0.03)
    }

    var activeIntensity: CGFloat {
        CGFloat(activeSettingsProfile?.intensity ?? 1.0)
    }

    var activeWarningOnsetDelay: Double {
        activeSettingsProfile?.warningOnsetDelay ?? 0.0
    }

    var activeDetectionMode: DetectionMode {
        activeSettingsProfile?.detectionMode ?? .balanced
    }

    var setupComplete = false

    var isMarketingMode: Bool {
        UserDefaults.standard.bool(forKey: "MarketingMode")
            || CommandLine.arguments.contains("--marketing-mode")
    }

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
            monitoringState.reset()
            clearBlur()
            postureWarningIntensity = 0
            warningOverlayManager.targetIntensity = 0
            warningOverlayManager.updateWarning()
        }
        if newState == .monitoring {
            applyActiveSettingsProfile()
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
                        Task { @MainActor in
                            self?.state = .paused(.cameraDisconnected)
                        }
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

        warningOverlayManager.mode = activeWarningMode
        warningOverlayManager.warningColor = activeWarningColor
        appliedWarningColorData = activeSettingsProfile?.warningColorData
        if activeWarningMode.usesWarningOverlay {
            warningOverlayManager.setupOverlayWindows()
        }

        setupObservers()

        Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateBlur()
            }
        }

        if isMarketingMode {
            AnalyticsManager.shared.injectMarketingData()
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
        cameraDetector.baseFrameInterval = 1.0 / activeDetectionMode.frameRate

        cameraDetector.onPostureReading = { [weak self] reading in
            Task { @MainActor in
                self?.handlePostureReading(reading)
            }
        }

        cameraDetector.onAwayStateChange = { [weak self] isAway in
            Task { @MainActor in
                self?.handleAwayStateChange(isAway)
            }
        }

        // Configure AirPods detector
        airPodsDetector.onPostureReading = { [weak self] reading in
            Task { @MainActor in
                self?.handlePostureReading(reading)
            }
        }

        airPodsDetector.onConnectionStateChange = { [weak self] isConnected in
            Task { @MainActor in
                self?.handleConnectionStateChange(isConnected)
            }
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

        if isMarketingMode {
            monitoringState.isCurrentlySlouching = false
            monitoringState.postureWarningIntensity = 0
            monitoringState.consecutiveBadFrames = 0
            syncUIToState()
            updateBlur()
            return
        }

        // Use the detector's capture timestamp for consistency
        let readingTime = reading.timestamp

        // Calculate actual elapsed time since last reading for accurate analytics.
        // Skip analytics on the first reading (no prior reference point).
        let actualElapsed: TimeInterval?
        if let last = lastPostureReadingTime {
            let raw = readingTime.timeIntervalSince(last)
            // Clamp: ignore negative deltas (clock adjustment) and cap at 2s
            // to avoid a single huge chunk after sleep/stall.
            actualElapsed = min(max(0, raw), 2.0)
        } else {
            actualElapsed = nil
        }
        lastPostureReadingTime = readingTime

        // Use PostureEngine for pure logic
        let result = PostureEngine.processReading(
            reading,
            state: monitoringState,
            config: postureConfig,
            currentTime: readingTime,
            frameInterval: actualElapsed ?? 0
        )

        // Update state
        monitoringState = result.newState

        // Execute effects
        for effect in result.effects {
            switch effect {
            case .trackAnalytics(let interval, let isSlouching):
                if actualElapsed != nil {
                    AnalyticsManager.shared.trackTime(interval: interval, isSlouching: isSlouching)
                }
            case .recordSlouchEvent:
                AnalyticsManager.shared.recordSlouchEvent()
            case .updateUI:
                syncUIToState()
            case .updateBlur:
                updateBlur()
            }
        }
    }

    private func handleAwayStateChange(_ isAway: Bool) {
        guard state == .monitoring else { return }
        if isMarketingMode { return }

        let result = PostureEngine.processAwayChange(isAway: isAway, state: monitoringState)
        monitoringState = result.newState

        if result.shouldUpdateUI {
            syncUIToState()
        }
    }

    // MARK: - Observers Setup

    private func setupObservers() {
        // Display configuration changes
        displayMonitor.onDisplayConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleDisplayConfigurationChange()
            }
        }
        displayMonitor.startMonitoring()

        // Camera hot-plug
        cameraObserver.onCameraConnected = { [weak self] device in
            Task { @MainActor in
                self?.handleCameraConnected(device)
            }
        }
        cameraObserver.onCameraDisconnected = { [weak self] device in
            Task { @MainActor in
                self?.handleCameraDisconnected(device)
            }
        }
        cameraObserver.startObserving()

        // Screen lock/unlock
        screenLockObserver.onScreenLocked = { [weak self] in
            Task { @MainActor in
                self?.handleScreenLocked()
            }
        }
        screenLockObserver.onScreenUnlocked = { [weak self] in
            Task { @MainActor in
                self?.handleScreenUnlocked(triggeredByUnlockNotification: true)
            }
        }
        screenLockObserver.startObserving()

        // Global hotkey
        hotkeyManager.configure(
            enabled: toggleShortcutEnabled,
            shortcut: toggleShortcut,
            onToggle: { [weak self] in
                Task { @MainActor in
                    self?.toggleEnabled()
                }
            }
        )
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        menuBarManager.setup()
        menuBarManager.updateShortcut(enabled: toggleShortcutEnabled, shortcut: toggleShortcut)

        menuBarManager.onToggleEnabled = { [weak self] in
            Task { @MainActor in
                self?.toggleEnabled()
            }
        }
        menuBarManager.onRecalibrate = { [weak self] in
            Task { @MainActor in
                self?.startCalibration()
            }
        }
        menuBarManager.onShowAnalytics = { [weak self] in
            Task { @MainActor in
                self?.showAnalytics()
            }
        }
        menuBarManager.onOpenSettings = { [weak self] in
            Task { @MainActor in
                self?.openSettings()
            }
        }
        menuBarManager.onQuit = { [weak self] in
            Task { @MainActor in
                self?.quit()
            }
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

        if isMarketingMode {
            startMonitoring()
            return
        }

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
            Task { @MainActor in
                guard let self else { return }

                self.trackingSource = source
                if let cameraID = cameraID {
                    self.cameraDetector.selectedCameraID = cameraID
                }
                self.saveSettings()

                // Start calibration
                self.startCalibration()
            }
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
            startMonitoring()
        } else {
            // No calibration - pause and wait for user to calibrate
            // Don't auto-start calibration as it requires async permission and device availability
            state = .paused(.noProfile)
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        // Prevent multiple concurrent calibrations (use calibrationController as the lock)
        guard calibrationController == nil else { return }

        os_log(.info, log: log, "Starting calibration for %{public}@", trackingSource.displayName)

        // Request authorization (this shows permission dialog if needed)
        activeDetector.requestAuthorization { [weak self] authorized in
            Task { @MainActor in
                guard let self else { return }

                if !authorized {
                    os_log(.error, log: log, "Authorization denied for %{public}@", self.trackingSource.displayName)

                    // Reset state since we're not proceeding
                    self.state = self.isCalibrated ? .monitoring : .paused(.noProfile)

                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = L("alert.permissionRequired")
                    alert.informativeText = self.trackingSource == .airpods
                        ? L("alert.permissionRequired.airpods")
                        : L("alert.permissionRequired.camera")
                    alert.addButton(withTitle: L("alert.openSettings"))
                    alert.addButton(withTitle: L("common.cancel"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                    }
                    return
                }

                // Authorization granted - now start calibration
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
            Task { @MainActor in
                guard let self else { return }

                if !success {
                    os_log(.error, log: log, "Failed to start detector for calibration: %{public}@", error ?? "unknown")
                    self.state = .paused(.cameraDisconnected)
                    if self.trackingSource == .camera {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = L("alert.cameraNotAvailable")
                        alert.informativeText = error ?? L("alert.cameraNotAvailable.message")
                        alert.addButton(withTitle: L("alert.tryAgain"))
                        alert.addButton(withTitle: L("common.cancel"))
                        NSApp.activate(ignoringOtherApps: true)
                        if alert.runModal() == .alertFirstButtonReturn {
                            self.startCalibration()
                        }
                    }
                    return
                }

                self.calibrationController = CalibrationWindowController()
                self.calibrationController?.start(
                    detector: self.activeDetector,
                    onComplete: { [weak self] values in
                        Task { @MainActor in
                            self?.finishCalibration(values: values)
                        }
                    },
                    onCancel: { [weak self] in
                        Task { @MainActor in
                            self?.cancelCalibration()
                        }
                    }
                )
            }
        }
    }

    func finishCalibration(values: [CalibrationSample]) {
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
        if isMarketingMode {
            state = .monitoring
            return
        }

        guard let calibration = currentCalibration else {
            state = .paused(.noProfile)
            return
        }

        // For AirPods, check if they're actually in ears before monitoring
        if trackingSource == .airpods && !activeDetector.isConnected {
            os_log(.info, log: log, "AirPods not in ears - pausing instead of monitoring")
            activeDetector.beginMonitoring(with: calibration, intensity: activeIntensity, deadZone: activeDeadZone)
            state = .paused(.airPodsRemoved)
            return
        }

        lastPostureReadingTime = nil
        activeDetector.beginMonitoring(with: calibration, intensity: activeIntensity, deadZone: activeDeadZone)
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
        cameraDetector.baseFrameInterval = 1.0 / activeDetectionMode.frameRate
    }

    func applyActiveSettingsProfile() {
        postureConfig.intensity = activeIntensity
        postureConfig.warningOnsetDelay = activeWarningOnsetDelay
        activeDetector.updateParameters(intensity: activeIntensity, deadZone: activeDeadZone)
        applyDetectionMode()

        guard setupComplete else { return }

        if warningOverlayManager.mode != activeWarningMode {
            switchWarningMode(to: activeWarningMode)
        }

        let desiredColorData = activeSettingsProfile?.warningColorData
        if desiredColorData != appliedWarningColorData {
            appliedWarningColorData = desiredColorData
            updateWarningColor(activeWarningColor)
        }
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

    private func handleScreenUnlocked(triggeredByUnlockNotification: Bool) {
        if case .paused(.screenLocked) = state {
            if let previousState = stateBeforeLock {
                stateBeforeLock = nil
                switch previousState {
                case .monitoring:
                    // Re-enter monitoring via startMonitoring() so detector monitoring
                    // state/calibration are re-applied after lock pause.
                    startMonitoring()
                default:
                    state = previousState
                }
            } else {
                startMonitoring()
            }
        }

        // Wake can arrive before unlock; force a camera session rebuild on real unlock
        // to recover from stale AV capture pipelines.
        guard triggeredByUnlockNotification,
              trackingSource == .camera,
              state == .monitoring else { return }

        cameraDetector.restartSessionAfterWakeUnlock()
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

}
