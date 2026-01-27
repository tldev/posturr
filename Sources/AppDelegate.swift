import AppKit
import AVFoundation
import Vision

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

    // Camera
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    let captureQueue = DispatchQueue(label: "capture.queue")
    var selectedCameraID: String?

    // Calibration
    var calibrationController: CalibrationWindowController?
    var isCalibrated = false
    var goodPostureY: CGFloat = 0.6
    var badPostureY: CGFloat = 0.4
    var neutralY: CGFloat = 0.5
    var postureRange: CGFloat = 0.2

    // Settings
    var intensity: CGFloat = 1.0
    var deadZone: CGFloat = 0.03
    var useCompatibilityMode = false
    var blurWhenAway = false
    var showInDock = false
    var pauseOnTheGo = false
    var settingsWindowController = SettingsWindowController()
    var analyticsWindowController: AnalyticsWindowController?

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
    var lastDetectionTime = Date()
    var consecutiveBadFrames = 0
    var consecutiveGoodFrames = 0
    var consecutiveNoDetectionFrames = 0
    let frameThreshold = 8
    let awayFrameThreshold = 15

    // Smoothing
    var noseYHistory: [CGFloat] = []
    let smoothingWindow = 5
    var smoothedNoseY: CGFloat = 0.5
    var currentNoseY: CGFloat = 0.5

    // Hysteresis
    var isCurrentlySlouching = false
    var isCurrentlyAway = false

    // Separate intensities for different concerns (0.0 to 1.0)
    var postureWarningIntensity: CGFloat = 0  // Posture-based warning
    // Privacy blur is derived from isCurrentlyAway (always full blur when away)

    // Blur onset delay
    var warningOnsetDelay: Double = 0.0
    var badPostureStartTime: Date?

    // Frame throttling
    var lastFrameTime: Date = .distantPast
    let frameInterval: TimeInterval = 0.1

    var cameraSetupComplete = false
    var waitingForPermission = false

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
        print("[State] Transition: \(oldState) -> \(newState)")
        syncCameraToState()
        if !newState.isActive {
            targetBlurRadius = 0
        }
        syncUIToState()
    }

    private func syncCameraToState() {
        let shouldRun: Bool
        switch state {
        case .calibrating, .monitoring:
            shouldRun = true
        case .disabled, .paused:
            shouldRun = false
        }

        print("[State] syncCameraToState: state=\(state), shouldRun=\(shouldRun), isRunning=\(captureSession?.isRunning ?? false)")

        if shouldRun {
            ensureCameraInput()
            let hasInputs = !(captureSession?.inputs.isEmpty ?? true)
            print("[State] After ensureCameraInput: hasInputs=\(hasInputs)")

            if !(captureSession?.isRunning ?? false) {
                print("[State] Starting capture session...")
                DispatchQueue.global(qos: .userInitiated).async {
                    self.captureSession?.startRunning()
                    DispatchQueue.main.async {
                        print("[State] Capture session running: \(self.captureSession?.isRunning ?? false)")
                    }
                }
            }
        } else if captureSession?.isRunning ?? false {
            print("[State] Stopping capture session")
            captureSession?.stopRunning()
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
                statusMenuItem.title = "Status: Camera disconnected"
            case .screenLocked:
                statusMenuItem.title = "Status: Paused (screen locked)"
            }
            statusItem.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
        }

        enabledMenuItem.state = (state != .disabled) ? .on : .off

        let cameras = getAvailableCameras()
        let hasCamera = !cameras.isEmpty && (selectedCameraID == nil || cameras.contains { $0.uniqueID == selectedCameraID })
        if hasCamera && state != .calibrating {
            recalibrateMenuItem.title = "Recalibrate"
            recalibrateMenuItem.action = #selector(recalibrate)
            recalibrateMenuItem.isEnabled = true
        } else {
            recalibrateMenuItem.title = hasCamera ? "Recalibrate" : "Recalibrate (no camera)"
            recalibrateMenuItem.action = nil
            recalibrateMenuItem.isEnabled = false
        }
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

        setupMenuBar()
        setupOverlayWindows()
        if warningMode != .blur && warningMode != .none {
            warningOverlayManager.mode = warningMode
            warningOverlayManager.warningColor = warningColor
            warningOverlayManager.setupOverlayWindows()
        }
        registerDisplayChangeCallback()
        registerCameraChangeNotifications()
        registerScreenLockNotifications()

        Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateBlur()
        }

        checkCameraPermissionAndStart()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.button?.performClick(nil)
        return false
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

        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
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
            } else if pauseOnTheGo && isLaptopOnlyConfiguration() {
                state = .paused(.onTheGo)
            } else if !isCameraAvailable() {
                state = .paused(.cameraDisconnected)
            } else {
                state = .monitoring
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
        captureSession?.stopRunning()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Camera Permission

    func checkCameraPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            setupCameraAndStartCalibration()
        case .notDetermined:
            statusMenuItem.title = "Status: Requesting camera..."
            waitingForPermission = true
            setupCamera()
        case .denied, .restricted:
            handleCameraDenied()
        @unknown default:
            handleCameraDenied()
        }
    }

    func setupCameraAndStartCalibration() {
        guard !cameraSetupComplete else { return }
        cameraSetupComplete = true

        setupCamera()

        // Note: We intentionally don't check pauseOnTheGo at startup.
        // "Pause on the go" should only trigger when display config *changes*
        // to laptop-only (e.g., unplugging external monitor), not at app launch.

        let configKey = getCurrentConfigKey()
        if let profile = loadProfile(forKey: configKey) {
            let cameras = getAvailableCameras()
            if cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
                selectedCameraID = profile.cameraID
                applyProfile(profile)
                state = .monitoring
                return
            } else {
                state = .paused(.cameraDisconnected)
                return
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.startCalibration()
        }
    }

    func onCameraPermissionGranted() {
        guard waitingForPermission else { return }
        waitingForPermission = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startCalibration()
        }
    }

    func handleCameraDenied() {
        state = .disabled
        statusMenuItem.title = "Status: Camera access denied"

        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "Posturr needs camera access to monitor your posture.\n\nPlease enable it in System Settings > Privacy & Security > Camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
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

    private func isCameraAvailable() -> Bool {
        let cameras = getAvailableCameras()
        return !cameras.isEmpty && (selectedCameraID == nil || cameras.contains { $0.uniqueID == selectedCameraID })
    }

    func restartCamera() {
        switchCameraInput()
        state = .paused(.noProfile)
    }

    private func switchCameraInput() {
        let wasRunning = captureSession?.isRunning ?? false
        print("[Camera] switchCameraInput called, wasRunning=\(wasRunning), selectedCameraID=\(selectedCameraID ?? "nil")")

        if wasRunning {
            captureSession?.stopRunning()
        }

        if let inputs = captureSession?.inputs {
            for input in inputs {
                captureSession?.removeInput(input)
            }
        }

        let cameras = getAvailableCameras()
        print("[Camera] Available cameras: \(cameras.map { $0.localizedName })")
        let camera = cameras.first { $0.uniqueID == selectedCameraID } ?? cameras.first

        guard let selectedCamera = camera else {
            print("[Camera] ERROR: No camera found!")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: selectedCamera)
            selectedCameraID = selectedCamera.uniqueID
            captureSession?.addInput(input)
            print("[Camera] Successfully added input for \(selectedCamera.localizedName)")
        } catch {
            print("[Camera] ERROR: Failed to create input: \(error)")
            return
        }

        if wasRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession?.startRunning()
                print("[Camera] Restarted session after input switch")
            }
        }
    }

    private func ensureCameraInput() {
        guard let session = captureSession else {
            print("[Camera] ensureCameraInput: No capture session!")
            return
        }

        if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
            if currentInput.device.uniqueID == selectedCameraID {
                print("[Camera] ensureCameraInput: Already have correct input")
                return
            }
            print("[Camera] ensureCameraInput: Have input for \(currentInput.device.uniqueID), but need \(selectedCameraID ?? "nil")")
        } else {
            print("[Camera] ensureCameraInput: No current input, need to configure")
        }

        switchCameraInput()
    }

    func setupCamera() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .low

        let cameras = getAvailableCameras()
        let camera: AVCaptureDevice?

        if let selectedID = selectedCameraID {
            camera = cameras.first { $0.uniqueID == selectedID }
        } else {
            camera = cameras.first { $0.position == .front } ?? cameras.first
        }

        guard let selectedCamera = camera,
              let input = try? AVCaptureDeviceInput(device: selectedCamera) else {
            statusMenuItem.title = "Status: No Camera"
            return
        }

        if selectedCameraID == nil {
            selectedCameraID = selectedCamera.uniqueID
        }

        captureSession?.addInput(input)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.alwaysDiscardsLateVideoFrames = true
        videoOutput?.setSampleBufferDelegate(self, queue: captureQueue)

        if let videoOutput = videoOutput {
            captureSession?.addOutput(videoOutput)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession?.startRunning()
        }
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
        syncUIToState()

        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              case .paused(let reason) = state else { return }

        let configKey = getCurrentConfigKey()
        if let profile = loadProfile(forKey: configKey),
           profile.cameraID == device.uniqueID {
            selectedCameraID = profile.cameraID
            applyProfile(profile)
            switchCameraInput()
            state = .monitoring
        } else if reason == .cameraDisconnected {
            state = .paused(.noProfile)
        }
    }

    func handleCameraDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }

        print("[Camera] Disconnected: \(device.localizedName) (ID: \(device.uniqueID))")
        print("[Camera] Selected camera was: \(selectedCameraID ?? "nil")")

        guard device.uniqueID == selectedCameraID else {
            print("[Camera] Not our selected camera, just refreshing menu")
            syncUIToState()
            return
        }

        let cameras = getAvailableCameras()
        print("[Camera] Remaining cameras: \(cameras.map { "\($0.localizedName) (\($0.uniqueID))" })")

        if let fallbackCamera = cameras.first {
            selectedCameraID = fallbackCamera.uniqueID
            print("[Camera] Auto-selecting fallback: \(fallbackCamera.localizedName)")
            switchCameraInput()

            let configKey = getCurrentConfigKey()
            if let profile = loadProfile(forKey: configKey), profile.cameraID == fallbackCamera.uniqueID {
                print("[Camera] Found matching profile for fallback camera, resuming monitoring")
                applyProfile(profile)
                state = .monitoring
            } else {
                print("[Camera] No matching profile for fallback camera, need recalibration")
                state = .paused(.noProfile)
            }
        } else {
            print("[Camera] No cameras remaining!")
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
        print("[ScreenLock] Screen locked")

        // Only save state and pause if we're in an active state
        guard state.isActive || (state != .disabled && state != .paused(.screenLocked)) else {
            print("[ScreenLock] Already paused or disabled, not changing state")
            return
        }

        stateBeforeLock = state
        print("[ScreenLock] Saved state: \(state), pausing")
        state = .paused(.screenLocked)
    }

    func handleScreenUnlocked() {
        print("[ScreenLock] Screen unlocked")

        // Only restore if we paused due to screen lock
        guard case .paused(.screenLocked) = state else {
            print("[ScreenLock] Not paused due to screen lock, ignoring")
            return
        }

        if let previousState = stateBeforeLock {
            print("[ScreenLock] Restoring previous state: \(previousState)")
            state = previousState
            stateBeforeLock = nil
        } else {
            print("[ScreenLock] No saved state, transitioning to monitoring")
            state = .monitoring
        }
    }

    // MARK: - Calibration

    func startCalibration() {
        guard state != .calibrating else {
            print("[Calibration] Already calibrating, ignoring")
            return
        }

        print("[Calibration] Starting calibration, selectedCameraID: \(selectedCameraID ?? "nil")")
        isCalibrated = false
        state = .calibrating

        calibrationController = CalibrationWindowController()
        calibrationController?.start(
            onComplete: { [weak self] values in
                self?.finishCalibration(values: values)
            },
            onCancel: { [weak self] in
                self?.cancelCalibration()
            }
        )
    }

    func finishCalibration(values: [CGFloat]) {
        guard values.count >= 4 else {
            cancelCalibration()
            return
        }

        print("[Calibration] Finishing with \(values.count) values")

        let maxY = values.max() ?? 0.6
        let minY = values.min() ?? 0.4
        let avgY = values.reduce(0, +) / CGFloat(values.count)

        goodPostureY = maxY
        badPostureY = minY
        neutralY = avgY
        postureRange = abs(maxY - minY)

        let profile = ProfileData(
            goodPostureY: goodPostureY,
            badPostureY: badPostureY,
            neutralY: neutralY,
            postureRange: postureRange,
            cameraID: selectedCameraID ?? ""
        )
        let configKey = getCurrentConfigKey()
        print("[Calibration] Saving profile for config: \(configKey), camera: \(selectedCameraID ?? "nil")")
        saveProfile(forKey: configKey, data: profile)

        isCalibrated = true
        calibrationController = nil

        consecutiveBadFrames = 0
        consecutiveGoodFrames = 0

        print("[Calibration] Complete, transitioning to monitoring")
        state = .monitoring
    }

    func cancelCalibration() {
        calibrationController = nil
        isCalibrated = true
        state = .monitoring
    }

    func applyProfile(_ profile: ProfileData) {
        goodPostureY = profile.goodPostureY
        badPostureY = profile.badPostureY
        neutralY = profile.neutralY
        postureRange = profile.postureRange
        isCalibrated = true
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
        defaults.set(warningMode.rawValue, forKey: SettingsKeys.warningMode)
        defaults.set(warningOnsetDelay, forKey: SettingsKeys.warningOnsetDelay)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: warningColor, requiringSecureCoding: false) {
            defaults.set(colorData, forKey: SettingsKeys.warningColor)
        }
        if let cameraID = selectedCameraID {
            defaults.set(cameraID, forKey: SettingsKeys.lastCameraID)
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
        selectedCameraID = defaults.string(forKey: SettingsKeys.lastCameraID)
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
        print("[Display] Configuration changed, rebuilding overlay windows")
        rebuildOverlayWindows()

        guard state != .disabled else {
            print("[Display] App is disabled, skipping state change")
            return
        }

        if pauseOnTheGo && isLaptopOnlyConfiguration() {
            print("[Display] Laptop-only + pauseOnTheGo enabled, pausing")
            state = .paused(.onTheGo)
            return
        }

        let cameras = getAvailableCameras()
        let configKey = getCurrentConfigKey()
        let profile = loadProfile(forKey: configKey)

        print("[Display] Config key: \(configKey)")
        print("[Display] Available cameras: \(cameras.map { "\($0.localizedName) (\($0.uniqueID))" })")
        print("[Display] Profile exists: \(profile != nil), profile cameraID: \(profile?.cameraID ?? "none")")

        if cameras.isEmpty {
            print("[Display] No cameras available")
            state = .paused(.cameraDisconnected)
            return
        }

        if let profile = profile,
           cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
            print("[Display] Found profile with matching camera")
            if selectedCameraID != profile.cameraID {
                print("[Display] Switching to profile camera: \(profile.cameraID)")
                selectedCameraID = profile.cameraID
                switchCameraInput()
            }
            applyProfile(profile)
            state = .monitoring
        } else {
            print("[Display] No matching profile, need calibration")
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

        if warningMode != .blur && warningMode != .none {
            warningOverlayManager.rebuildOverlayWindows()
        }
    }

    func clearBlur() {
        targetBlurRadius = 0
        currentBlurRadius = 0

        // Clear NSVisualEffectView alpha
        for blurView in blurViews {
            blurView.alphaValue = 0
        }

        #if !APP_STORE
        // Clear private API blur
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
        // Reset current warning state
        clearBlur()

        // Clear vignette/border intensity before removing windows
        warningOverlayManager.currentIntensity = 0
        warningOverlayManager.targetIntensity = 0
        for view in warningOverlayManager.overlayViews {
            if let vignetteView = view as? VignetteOverlayView {
                vignetteView.intensity = 0
            } else if let borderView = view as? BorderOverlayView {
                borderView.intensity = 0
            }
        }

        // Remove old warning overlay windows
        for window in warningOverlayManager.windows {
            window.orderOut(nil)
        }
        warningOverlayManager.windows.removeAll()
        warningOverlayManager.overlayViews.removeAll()

        // Set new mode and rebuild if needed
        warningMode = newMode
        if warningMode != .blur && warningMode != .none {
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
        if warningMode == .none {
            postureWarningIntensity = 0
            if currentBlurRadius != 0 || targetBlurRadius != 0 {
                clearBlur()
            } else {
                for blurView in blurViews {
                    blurView.alphaValue = 0
                }
            }
            warningOverlayManager.targetIntensity = 0
            warningOverlayManager.updateWarning()
            return
        }

        // Two independent concerns:
        // 1. Privacy blur: full blur when away (always uses blur overlay)
        // 2. Posture warning: user's chosen style (blur/vignette/border)

        let privacyBlurIntensity: CGFloat = isCurrentlyAway ? 1.0 : 0.0

        // Compute target blur radius from both sources
        if warningMode == .blur {
            // Both privacy and posture use blur - take the higher value
            let combinedIntensity = max(privacyBlurIntensity, postureWarningIntensity)
            targetBlurRadius = Int32(combinedIntensity * 64)
            // Ensure warning overlay is cleared
            warningOverlayManager.targetIntensity = 0
            warningOverlayManager.updateWarning()
        } else {
            // Privacy uses blur, posture uses vignette/border
            targetBlurRadius = Int32(privacyBlurIntensity * 64)
            warningOverlayManager.targetIntensity = postureWarningIntensity
            warningOverlayManager.updateWarning()
        }

        // Animate blur toward target
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

    // MARK: - Posture Detection

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
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

    func analyzeBodyPose(_ body: VNHumanBodyPoseObservation) {
        guard let nose = try? body.recognizedPoint(.nose), nose.confidence > 0.3 else {
            return
        }

        consecutiveNoDetectionFrames = 0
        isCurrentlyAway = false

        let noseY = nose.location.y
        currentNoseY = noseY

        if state == .calibrating {
            calibrationController?.updateCurrentNoseY(noseY)
            return
        }

        guard state == .monitoring && isCalibrated else { return }

        evaluatePosture(currentY: noseY)
    }

    func tryFaceDetection(pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        let faceRequest = VNDetectFaceRectanglesRequest { [weak self] request, error in
            if let results = request.results as? [VNFaceObservation], let face = results.first {
                self?.analyzeFace(face)
            } else {
                self?.handleNoDetection()
            }
        }

        try? handler.perform([faceRequest])
    }

    func handleNoDetection() {
        consecutiveNoDetectionFrames += 1
        consecutiveBadFrames = 0
        consecutiveGoodFrames = 0

        guard state == .monitoring && isCalibrated && blurWhenAway else {
            consecutiveNoDetectionFrames = 0
            return
        }

        if consecutiveNoDetectionFrames >= awayFrameThreshold && !isCurrentlyAway {
            isCurrentlyAway = true

            DispatchQueue.main.async {
                self.statusMenuItem.title = "Status: Away"
                self.statusItem.button?.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "Away")
            }
        }
    }

    func analyzeFace(_ face: VNFaceObservation) {
        consecutiveNoDetectionFrames = 0
        isCurrentlyAway = false

        let faceY = face.boundingBox.midY
        currentNoseY = faceY

        if state == .calibrating {
            calibrationController?.updateCurrentNoseY(faceY)
            return
        }

        guard state == .monitoring && isCalibrated else { return }

        evaluatePosture(currentY: faceY)
    }

    func smoothNoseY(_ rawY: CGFloat) -> CGFloat {
        noseYHistory.append(rawY)

        if noseYHistory.count > smoothingWindow {
            noseYHistory.removeFirst()
        }

        let sum = noseYHistory.reduce(0, +)
        smoothedNoseY = sum / CGFloat(noseYHistory.count)
        return smoothedNoseY
    }

    func evaluatePosture(currentY: CGFloat) {
        let smoothedY = smoothNoseY(currentY)

        // How far past the bad posture threshold (positive = slouching)
        let slouchAmount = badPostureY - smoothedY

        // Dead zone is an absolute buffer (percentage of posture range)
        let deadZoneThreshold = deadZone * postureRange

        // Hysteresis: easier to exit slouching state than enter it
        let enterThreshold = deadZoneThreshold
        let exitThreshold = deadZoneThreshold * 0.7

        let threshold = isCurrentlySlouching ? exitThreshold : enterThreshold
        let isBadPosture = slouchAmount > threshold

        // Track analytics
        AnalyticsManager.shared.trackTime(interval: frameInterval, isSlouching: isCurrentlySlouching)

        if isBadPosture {
            consecutiveBadFrames += 1
            consecutiveGoodFrames = 0

            if consecutiveBadFrames >= frameThreshold {
                // Start tracking when bad posture began (if not already)
                if badPostureStartTime == nil {
                    badPostureStartTime = Date()
                }

                // Check if we've waited long enough for the blur onset delay
                let elapsedTime = Date().timeIntervalSince(badPostureStartTime!)
                guard elapsedTime >= warningOnsetDelay else {
                    // Still waiting for delay, don't activate blur yet
                    return
                }

                // Record slouch event only once when transitioning to slouching state
                if !isCurrentlySlouching {
                    AnalyticsManager.shared.recordSlouchEvent()
                }

                isCurrentlySlouching = true

                // Calculate severity: how far past the dead zone (0 to 1)
                let pastDeadZone = slouchAmount - deadZoneThreshold
                let remainingRange = max(0.01, postureRange - deadZoneThreshold)
                let severity = min(1.0, max(0.0, pastDeadZone / remainingRange))

                // Intensity controls the curve: higher = warning ramps up faster
                // pow(severity, 1/intensity): intensity 2.0 = aggressive, 0.5 = gentle
                let adjustedSeverity = pow(severity, 1.0 / intensity)

                postureWarningIntensity = adjustedSeverity

                DispatchQueue.main.async {
                    self.statusMenuItem.title = "Status: Slouching"
                    self.statusItem.button?.image = NSImage(systemSymbolName: "figure.fall", accessibilityDescription: "Bad Posture")
                }
            }
        } else {
            consecutiveGoodFrames += 1
            consecutiveBadFrames = 0

            // Reset the bad posture start time when posture improves
            badPostureStartTime = nil

            postureWarningIntensity = 0

            if consecutiveGoodFrames >= frameThreshold {
                isCurrentlySlouching = false

                DispatchQueue.main.async {
                    self.statusMenuItem.title = "Status: Good Posture"
                    self.statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Good Posture")
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension AppDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if waitingForPermission {
            DispatchQueue.main.async {
                self.onCameraPermissionGranted()
            }
        }

        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        processFrame(pixelBuffer)
    }
}
