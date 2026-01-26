import AppKit
import AVFoundation
import Vision
import CoreImage
import CoreGraphics

// MARK: - Dynamic Private API Loading
// Private CoreGraphics APIs for enhanced blur effect (not available in App Store builds)
#if !APP_STORE
private let cgsMainConnectionID: (@convention(c) () -> UInt32)? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> UInt32).self)
}()

private let cgsSetWindowBackgroundBlurRadius: (@convention(c) (UInt32, UInt32, Int32) -> Int32)? = {
    guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
    guard let sym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (UInt32, UInt32, Int32) -> Int32).self)
}()

private var privateAPIsAvailable: Bool {
    return cgsMainConnectionID != nil && cgsSetWindowBackgroundBlurRadius != nil
}
#else
// App Store build: no private APIs available
private var privateAPIsAvailable: Bool { return false }
#endif

// MARK: - Settings Keys
enum SettingsKeys {
    static let sensitivity = "sensitivity"
    static let deadZone = "deadZone"
    static let useCompatibilityMode = "useCompatibilityMode"
    static let blurWhenAway = "blurWhenAway"
    static let pauseOnTheGo = "pauseOnTheGo"
    static let lastCameraID = "lastCameraID"
    static let profiles = "profiles"
}

// MARK: - Profile Data
struct ProfileData: Codable {
    let goodPostureY: CGFloat
    let badPostureY: CGFloat
    let neutralY: CGFloat
    let postureRange: CGFloat
    let cameraID: String
}

// MARK: - Pause Reason
enum PauseReason: Equatable {
    case noProfile
    case onTheGo
    case cameraDisconnected
}

// MARK: - App State
enum AppState: Equatable {
    case disabled
    case calibrating
    case monitoring
    case paused(PauseReason)

    var isActive: Bool {
        switch self {
        case .monitoring, .calibrating: return true
        case .disabled, .paused: return false
        }
    }
}

// MARK: - Calibration View
class CalibrationView: NSView {
    var targetPosition: NSPoint = .zero
    var pulsePhase: CGFloat = 0
    var instructionText: String = "Look at the ring and press Space"
    var stepText: String = "Step 1 of 4"
    var showRing: Bool = true

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Dark overlay
        NSColor.black.withAlphaComponent(0.85).setFill()
        dirtyRect.fill()

        // Pulsing ring (only if this screen should show it)
        if showRing {
            let baseRadius: CGFloat = 50
            let pulseAmount: CGFloat = 15
            let radius = baseRadius + sin(pulsePhase) * pulseAmount

            let ringRect = NSRect(
                x: targetPosition.x - radius,
                y: targetPosition.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            // Outer glow
            let glowColor = NSColor.cyan.withAlphaComponent(0.3 + 0.2 * sin(pulsePhase))
            glowColor.setFill()
            let glowRect = ringRect.insetBy(dx: -25, dy: -25)
            NSBezierPath(ovalIn: glowRect).fill()

            // Main ring
            let ringPath = NSBezierPath(ovalIn: ringRect)
            NSColor.cyan.withAlphaComponent(0.9).setStroke()
            ringPath.lineWidth = 5
            ringPath.stroke()

            // Inner dot
            let dotRect = NSRect(
                x: targetPosition.x - 10,
                y: targetPosition.y - 10,
                width: 20,
                height: 20
            )
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // Instructions
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]

        let stepAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            .paragraphStyle: paragraphStyle
        ]

        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.cyan,
            .paragraphStyle: paragraphStyle
        ]

        // Draw step indicator at top center
        let stepRect = NSRect(x: 0, y: bounds.height - 100, width: bounds.width, height: 40)
        (stepText as NSString).draw(in: stepRect, withAttributes: stepAttrs)

        // Draw instruction in center
        let textRect = NSRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 50)
        (instructionText as NSString).draw(in: textRect, withAttributes: titleAttrs)

        // Draw hint below
        let hintRect = NSRect(x: 0, y: bounds.midY - 70, width: bounds.width, height: 30)
        ("Move your head naturally • Press Space when ready" as NSString).draw(in: hintRect, withAttributes: hintAttrs)

        // Draw escape hint smaller
        let escapeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .paragraphStyle: paragraphStyle
        ]
        let escapeRect = NSRect(x: 0, y: bounds.midY - 110, width: bounds.width, height: 25)
        ("Escape to skip calibration" as NSString).draw(in: escapeRect, withAttributes: escapeAttrs)
    }
}

// MARK: - Calibration Window Controller
class CalibrationWindowController: NSObject {
    var windows: [NSWindow] = []
    var calibrationViews: [CalibrationView] = []
    var animationTimer: Timer?
    var currentStep = 0
    var onComplete: (([CGFloat]) -> Void)?
    var onCancel: (() -> Void)?
    var capturedValues: [CGFloat] = []
    var currentNoseY: CGFloat = 0.5
    var localEventMonitor: Any?
    var globalEventMonitor: Any?

    struct CalibrationStep {
        let instruction: String
        let screenIndex: Int
        let corner: Corner
    }

    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight

        func position(in bounds: NSRect, margin: CGFloat = 120) -> NSPoint {
            switch self {
            case .topLeft:
                return NSPoint(x: margin, y: bounds.height - margin)
            case .topRight:
                return NSPoint(x: bounds.width - margin, y: bounds.height - margin)
            case .bottomLeft:
                return NSPoint(x: margin, y: margin)
            case .bottomRight:
                return NSPoint(x: bounds.width - margin, y: margin)
            }
        }

        var name: String {
            switch self {
            case .topLeft: return "TOP-LEFT"
            case .topRight: return "TOP-RIGHT"
            case .bottomLeft: return "BOTTOM-LEFT"
            case .bottomRight: return "BOTTOM-RIGHT"
            }
        }
    }

    var steps: [CalibrationStep] = []

    func buildSteps() {
        steps = []
        let corners: [Corner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

        for screenIndex in 0..<NSScreen.screens.count {
            let screenName = NSScreen.screens.count > 1 ? "Screen \(screenIndex + 1) " : ""
            for corner in corners {
                steps.append(CalibrationStep(
                    instruction: "Look at the \(screenName)\(corner.name) corner",
                    screenIndex: screenIndex,
                    corner: corner
                ))
            }
        }
    }

    func start(onComplete: @escaping ([CGFloat]) -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.currentStep = 0
        self.capturedValues = []

        buildSteps()

        // Create calibration window for each screen
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver + 1
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = CalibrationView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.showRing = false  // Hide by default
            window.contentView = view

            window.orderFrontRegardless()
            windows.append(window)
            calibrationViews.append(view)
        }

        // Setup keyboard monitoring (both local and global)
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // Space
                self?.captureCurrentPosition()
                return nil
            } else if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 { // Space
                self?.captureCurrentPosition()
            } else if event.keyCode == 53 { // Escape
                self?.cancel()
            }
        }

        if let firstWindow = windows.first {
            firstWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)

        updateStep()
        startAnimation()
    }

    func updateStep() {
        guard currentStep < steps.count else {
            complete()
            return
        }

        let step = steps[currentStep]

        // Update all views
        for (index, view) in calibrationViews.enumerated() {
            if index == step.screenIndex {
                view.showRing = true
                view.targetPosition = step.corner.position(in: view.bounds)
                view.instructionText = step.instruction
                view.stepText = "Step \(currentStep + 1) of \(steps.count)"
            } else {
                view.showRing = false
                view.instructionText = "Look at the other screen"
                view.stepText = "Step \(currentStep + 1) of \(steps.count)"
            }
            view.needsDisplay = true
        }
    }

    func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            for view in self?.calibrationViews ?? [] {
                view.pulsePhase += 0.08
                view.needsDisplay = true
            }
        }
    }

    func captureCurrentPosition() {
        capturedValues.append(currentNoseY)
        currentStep += 1
        updateStep()
    }

    func updateCurrentNoseY(_ value: CGFloat) {
        currentNoseY = value
    }

    func complete() {
        cleanup()
        onComplete?(capturedValues)
    }

    func cancel() {
        cleanup()
        onCancel?()
    }

    func cleanup() {
        animationTimer?.invalidate()
        animationTimer = nil

        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        calibrationViews = []
    }
}

// MARK: - Icon Masking
func applyMacOSIconMask(to image: NSImage) -> NSImage {
    let size = NSSize(width: 512, height: 512)

    // Create a new image with alpha
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

    // macOS icon corner radius is approximately 22.37% of the icon size
    let cornerRadius = size.width * 0.2237
    let rect = NSRect(origin: .zero, size: size)

    // Clear to transparent
    NSColor.clear.setFill()
    rect.fill()

    // Clip to rounded rect and draw
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
    var windows: [NSWindow] = []
    var blurViews: [NSVisualEffectView] = []
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var enabledMenuItem: NSMenuItem!
    var recalibrateMenuItem: NSMenuItem!
    var compatibilityModeMenuItem: NSMenuItem!

    // Posture tracking
    var captureSession: AVCaptureSession?
    var videoOutput: AVCaptureVideoDataOutput?
    var currentBlurRadius: Int32 = 0
    var targetBlurRadius: Int32 = 0
    let captureQueue = DispatchQueue(label: "capture.queue")
    var selectedCameraID: String?  // nil = auto-select
    var cameraMenuItem: NSMenuItem!

    // Calibration
    var calibrationController: CalibrationWindowController?
    var isCalibrated = false

    // Calibration values (Y positions)
    var goodPostureY: CGFloat = 0.6    // Looking up / good posture
    var badPostureY: CGFloat = 0.4     // Looking down / slouching
    var neutralY: CGFloat = 0.5        // Normal position
    var postureRange: CGFloat = 0.2    // Range between good and bad

    // Settings
    var sensitivity: CGFloat = 0.85  // Medium
    var deadZone: CGFloat = 0.03     // Medium
    var useCompatibilityMode = false
    var blurWhenAway = false
    var blurWhenAwayMenuItem: NSMenuItem!
    var showInAppSwitcher = false
    var showInAppSwitcherMenuItem: NSMenuItem!
    var pauseOnTheGo = false
    var pauseOnTheGoMenuItem: NSMenuItem!

    // MARK: - State Machine
    // Single source of truth for app state - all UI derives from this
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

    /// Central handler for all state transitions - updates ALL derived state
    private func handleStateTransition(from oldState: AppState, to newState: AppState) {
        print("[State] Transition: \(oldState) -> \(newState)")

        // 1. Update camera state
        syncCameraToState()

        // 2. Update blur
        if !newState.isActive {
            targetBlurRadius = 0
        }

        // 3. Update all UI elements
        syncUIToState()
    }

    /// Derives camera running state from app state
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
            // Ensure camera input is configured before starting
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

    /// Derives ALL UI state from app state - single place for UI consistency
    private func syncUIToState() {
        // Status text and icon
        switch state {
        case .disabled:
            statusMenuItem.title = "Status: Disabled"
            statusItem.button?.image = NSImage(systemSymbolName: "figure.stand.line.dotted.figure.stand", accessibilityDescription: "Disabled")

        case .calibrating:
            statusMenuItem.title = "Status: Calibrating..."
            statusItem.button?.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Calibrating")

        case .monitoring:
            // Default monitoring state - will be overwritten by posture detection
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
            }
            statusItem.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "Paused")
        }

        // Enabled menu item
        enabledMenuItem.state = (state != .disabled) ? .on : .off

        // Recalibrate menu item
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

    // Display change handling
    var displayReconfigurationPending = false
    var displayDebounceTimer: Timer?

    // Camera hot-plug observers
    var cameraConnectedObserver: NSObjectProtocol?
    var cameraDisconnectedObserver: NSObjectProtocol?

    // Detection state
    var lastDetectionTime = Date()
    var consecutiveBadFrames = 0
    var consecutiveGoodFrames = 0
    var consecutiveNoDetectionFrames = 0
    let frameThreshold = 8  // Require more consecutive frames
    let awayFrameThreshold = 15  // Frames before "away" blur kicks in

    // Smoothing for nose position (reduces flicker)
    var noseYHistory: [CGFloat] = []
    let smoothingWindow = 5  // Average over last 5 readings
    var smoothedNoseY: CGFloat = 0.5

    // Current detection value (for calibration)
    var currentNoseY: CGFloat = 0.5

    // Hysteresis - different thresholds for entering vs exiting slouch state
    var isCurrentlySlouching = false

    // Frame throttling - process ~10fps instead of 30fps to reduce CPU
    var lastFrameTime: Date = .distantPast
    let frameInterval: TimeInterval = 0.1  // 10fps

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadSettings()

        // Load app icon for Dock/app switcher (needed when switching to .regular policy)
        if let iconPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = applyMacOSIconMask(to: icon)
        }

        setupMenuBar()
        setupOverlayWindows()
        registerDisplayChangeCallback()
        registerCameraChangeNotifications()

        // Smooth blur transition timer (30fps is enough for smooth transitions)
        Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.updateBlur()
        }

        // Check camera permission before starting
        checkCameraPermissionAndStart()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Show menu dropdown when user Cmd+Tabs to the app
        if showInAppSwitcher {
            statusItem.button?.performClick(nil)
        }
    }

    var cameraSetupComplete = false
    var waitingForPermission = false

    func checkCameraPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            // Already authorized - start camera and calibration
            setupCameraAndStartCalibration()

        case .notDetermined:
            // Show status and setup camera - system will show permission dialog
            statusMenuItem.title = "Status: Requesting camera..."
            waitingForPermission = true
            setupCamera()
            // Camera setup will trigger permission dialog
            // We'll start calibration once we detect frames coming in

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

        // Check for existing profile first
        let configKey = getCurrentConfigKey()
        if let profile = loadProfile(forKey: configKey) {
            // Check if profile's camera is available
            let cameras = getAvailableCameras()
            if cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
                // Camera available - use this profile
                selectedCameraID = profile.cameraID
                applyProfile(profile)

                // Check for on-the-go pause
                if pauseOnTheGo && isLaptopOnlyConfiguration() {
                    state = .paused(.onTheGo)
                } else {
                    state = .monitoring
                }
                return
            } else {
                // Profile exists but camera not available
                state = .paused(.cameraDisconnected)
                return
            }
        }

        // No profile - need calibration
        // Check for on-the-go pause before calibration
        if pauseOnTheGo && isLaptopOnlyConfiguration() {
            state = .paused(.onTheGo)
            return
        }

        // Wait for camera to fully initialize before calibration
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

        // Show alert
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "Posturr needs camera access to monitor your posture.\n\nPlease enable it in System Settings > Privacy & Security > Camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Settings to Camera privacy
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: "Posturr")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        // Status
        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Enabled toggle
        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "e")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        // Recalibrate
        recalibrateMenuItem = NSMenuItem(title: "Recalibrate", action: #selector(recalibrate), keyEquivalent: "r")
        recalibrateMenuItem.target = self
        menu.addItem(recalibrateMenuItem)

        // Camera submenu
        cameraMenuItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraMenuItem.submenu = NSMenu()
        menu.addItem(cameraMenuItem)
        updateCameraMenu()

        // Sensitivity submenu
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu()
        let sensitivityOptions: [(String, Double, String)] = [
            ("Very Low", 0.4, "Only major slouching"),
            ("Low", 0.6, "Allows more movement"),
            ("Medium", 0.85, "Balanced"),
            ("High", 0.95, "Reacts to small changes"),
            ("Very High", 1.0, "Maximum response")
        ]
        for (title, value, desc) in sensitivityOptions {
            let item = NSMenuItem(title: "\(title) — \(desc)", action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(value * 100)
            item.state = (sensitivity == CGFloat(value)) ? .on : .off
            sensitivityMenu.addItem(item)
        }
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        // Dead Zone submenu
        let deadZoneItem = NSMenuItem(title: "Dead Zone", action: nil, keyEquivalent: "")
        let deadZoneMenu = NSMenu()
        let deadZoneOptions: [(String, Double, String)] = [
            ("Very Small", 0.01, "Activates immediately"),
            ("Small", 0.02, "Strict enforcement"),
            ("Medium", 0.03, "Balanced"),
            ("Large", 0.05, "Allows natural movement"),
            ("Very Large", 0.08, "Only major slouching")
        ]
        for (title, value, desc) in deadZoneOptions {
            let item = NSMenuItem(title: "\(title) — \(desc)", action: #selector(setDeadZone(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(value * 1000)
            item.state = (deadZone == CGFloat(value)) ? .on : .off
            deadZoneMenu.addItem(item)
        }
        deadZoneItem.submenu = deadZoneMenu
        menu.addItem(deadZoneItem)

        menu.addItem(NSMenuItem.separator())

        // Blur When Away toggle
        blurWhenAwayMenuItem = NSMenuItem(title: "Blur When Away", action: #selector(toggleBlurWhenAway), keyEquivalent: "")
        blurWhenAwayMenuItem.target = self
        blurWhenAwayMenuItem.state = blurWhenAway ? .on : .off
        menu.addItem(blurWhenAwayMenuItem)

        // Show in Dock/App Switcher toggle
        showInAppSwitcherMenuItem = NSMenuItem(title: "Show in Dock/App Switcher", action: #selector(toggleShowInAppSwitcher), keyEquivalent: "")
        showInAppSwitcherMenuItem.target = self
        showInAppSwitcherMenuItem.state = showInAppSwitcher ? .on : .off
        menu.addItem(showInAppSwitcherMenuItem)

        // Pause on the Go toggle
        pauseOnTheGoMenuItem = NSMenuItem(title: "Pause on the Go", action: #selector(togglePauseOnTheGo), keyEquivalent: "")
        pauseOnTheGoMenuItem.target = self
        pauseOnTheGoMenuItem.state = pauseOnTheGo ? .on : .off
        menu.addItem(pauseOnTheGoMenuItem)

        // Hint text for pause on the go
        let baseFont = NSFont.systemFont(ofSize: 11, weight: .regular)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let pauseHintItem = NSMenuItem()
        pauseHintItem.attributedTitle = NSAttributedString(
            string: "  Auto-pause when using laptop display only",
            attributes: [
                .font: italicFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        pauseHintItem.isEnabled = false
        menu.addItem(pauseHintItem)

        menu.addItem(NSMenuItem.separator())

        #if !APP_STORE
        // Compatibility Mode (only shown in direct download builds with private API support)
        compatibilityModeMenuItem = NSMenuItem(title: "Compatibility Mode", action: #selector(toggleCompatibilityMode), keyEquivalent: "")
        compatibilityModeMenuItem.target = self
        compatibilityModeMenuItem.state = useCompatibilityMode ? .on : .off
        menu.addItem(compatibilityModeMenuItem)

        // Hint text for compatibility mode
        let compatHintItem = NSMenuItem()
        compatHintItem.attributedTitle = NSAttributedString(
            string: "  Enable if blur isn't appearing",
            attributes: [
                .font: italicFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        compatHintItem.isEnabled = false
        menu.addItem(compatHintItem)

        menu.addItem(NSMenuItem.separator())
        #endif

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc func toggleEnabled() {
        if state == .disabled {
            // Re-enable: check what state we should enter
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

    private func isCameraAvailable() -> Bool {
        let cameras = getAvailableCameras()
        return !cameras.isEmpty && (selectedCameraID == nil || cameras.contains { $0.uniqueID == selectedCameraID })
    }

    @objc func toggleBlurWhenAway() {
        blurWhenAway.toggle()
        blurWhenAwayMenuItem.state = blurWhenAway ? .on : .off
        saveSettings()

        if !blurWhenAway {
            // Reset no-detection state when disabled
            consecutiveNoDetectionFrames = 0
        }
    }

    @objc func toggleShowInAppSwitcher() {
        showInAppSwitcher.toggle()
        showInAppSwitcherMenuItem.state = showInAppSwitcher ? .on : .off

        // .regular shows in Cmd+Tab and Dock, .accessory hides from both
        NSApp.setActivationPolicy(showInAppSwitcher ? .regular : .accessory)
    }

    @objc func togglePauseOnTheGo() {
        pauseOnTheGo.toggle()
        pauseOnTheGoMenuItem.state = pauseOnTheGo ? .on : .off
        saveSettings()

        // Don't immediately pause when enabling - only pause on transition to laptop-only
        // But if we disabled it and we were paused for on-the-go, resume
        if !pauseOnTheGo && state == .paused(.onTheGo) {
            // If we disabled it and we were paused for on-the-go, resume
            state = .monitoring
        }
    }

    @objc func recalibrate() {
        startCalibration()
    }

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

        // Find min and max Y values from all captured corners
        // Higher Y = looking up (good posture)
        // Lower Y = looking down (slouching)
        let maxY = values.max() ?? 0.6
        let minY = values.min() ?? 0.4
        let avgY = values.reduce(0, +) / CGFloat(values.count)

        goodPostureY = maxY
        badPostureY = minY
        neutralY = avgY
        postureRange = abs(maxY - minY)

        // Save profile for this display configuration
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

        // Reset counters
        consecutiveBadFrames = 0
        consecutiveGoodFrames = 0

        // Transition to monitoring
        print("[Calibration] Complete, transitioning to monitoring")
        state = .monitoring
    }

    func cancelCalibration() {
        calibrationController = nil

        // Use sensible defaults
        isCalibrated = true

        // Transition to monitoring with defaults
        state = .monitoring
    }

    @objc func setSensitivity(_ sender: NSMenuItem) {
        sensitivity = CGFloat(sender.tag) / 100.0
        saveSettings()

        if let menu = sender.menu {
            for item in menu.items {
                item.state = (item.tag == sender.tag) ? .on : .off
            }
        }
    }

    @objc func setDeadZone(_ sender: NSMenuItem) {
        deadZone = CGFloat(sender.tag) / 1000.0
        saveSettings()

        if let menu = sender.menu {
            for item in menu.items {
                item.state = (item.tag == sender.tag) ? .on : .off
            }
        }
    }

    func getAvailableCameras() -> [AVCaptureDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices
    }

    func updateCameraMenu() {
        guard let menu = cameraMenuItem.submenu else { return }
        menu.removeAllItems()

        let cameras = getAvailableCameras()

        if cameras.isEmpty {
            let noCamera = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            noCamera.isEnabled = false
            menu.addItem(noCamera)
            return
        }

        for camera in cameras {
            let item = NSMenuItem(title: camera.localizedName, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = camera.uniqueID
            item.state = (selectedCameraID == camera.uniqueID || (selectedCameraID == nil && camera == cameras.first)) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func selectCamera(_ sender: NSMenuItem) {
        guard let cameraID = sender.representedObject as? String else { return }

        print("[Camera] User selected camera: \(cameraID)")

        // If same camera, do nothing
        if cameraID == selectedCameraID {
            print("[Camera] Same camera selected, ignoring")
            return
        }

        selectedCameraID = cameraID
        saveSettings()

        // Update menu checkmarks
        if let menu = sender.menu {
            for item in menu.items {
                item.state = (item.representedObject as? String == cameraID) ? .on : .off
            }
        }

        // Camera changed - must recalibrate
        print("[Camera] Camera changed, calling restartCamera")
        restartCamera()
    }

    func restartCamera() {
        switchCameraInput()

        // Camera changed by user - require recalibration
        state = .paused(.noProfile)
    }

    /// Switches camera input without changing state (used for profile-based switching)
    /// Configures the capture session input for the selected camera (doesn't affect running state)
    private func switchCameraInput() {
        let wasRunning = captureSession?.isRunning ?? false
        print("[Camera] switchCameraInput called, wasRunning=\(wasRunning), selectedCameraID=\(selectedCameraID ?? "nil")")

        if wasRunning {
            captureSession?.stopRunning()
        }

        // Remove existing input
        if let inputs = captureSession?.inputs {
            for input in inputs {
                captureSession?.removeInput(input)
            }
        }

        // Find and add new camera
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

        // Restore running state
        if wasRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession?.startRunning()
                print("[Camera] Restarted session after input switch")
            }
        }
    }

    /// Ensures capture session has a valid input for the current camera selection
    private func ensureCameraInput() {
        guard let session = captureSession else {
            print("[Camera] ensureCameraInput: No capture session!")
            return
        }

        // Check if we already have the right input
        if let currentInput = session.inputs.first as? AVCaptureDeviceInput {
            if currentInput.device.uniqueID == selectedCameraID {
                print("[Camera] ensureCameraInput: Already have correct input")
                return  // Already configured correctly
            }
            print("[Camera] ensureCameraInput: Have input for \(currentInput.device.uniqueID), but need \(selectedCameraID ?? "nil")")
        } else {
            print("[Camera] ensureCameraInput: No current input, need to configure")
        }

        // Need to reconfigure
        switchCameraInput()
    }

    @objc func toggleCompatibilityMode() {
        useCompatibilityMode.toggle()
        compatibilityModeMenuItem.state = useCompatibilityMode ? .on : .off
        saveSettings()

        // Reset blur state when switching modes
        currentBlurRadius = 0
        for blurView in blurViews {
            blurView.alphaValue = 0
        }
        #if !APP_STORE
        for window in windows {
            if let getConnectionID = cgsMainConnectionID,
               let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
                let cid = getConnectionID()
                _ = setBlurRadius(cid, UInt32(window.windowNumber), 0)
            }
            window.backgroundColor = .clear
        }
        #endif
    }

    @objc func quit() {
        captureSession?.stopRunning()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Persistence

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(sensitivity, forKey: SettingsKeys.sensitivity)
        defaults.set(deadZone, forKey: SettingsKeys.deadZone)
        defaults.set(useCompatibilityMode, forKey: SettingsKeys.useCompatibilityMode)
        defaults.set(blurWhenAway, forKey: SettingsKeys.blurWhenAway)
        defaults.set(pauseOnTheGo, forKey: SettingsKeys.pauseOnTheGo)
        if let cameraID = selectedCameraID {
            defaults.set(cameraID, forKey: SettingsKeys.lastCameraID)
        }
    }

    func loadSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: SettingsKeys.sensitivity) != nil {
            sensitivity = defaults.double(forKey: SettingsKeys.sensitivity)
        }
        if defaults.object(forKey: SettingsKeys.deadZone) != nil {
            deadZone = defaults.double(forKey: SettingsKeys.deadZone)
        }
        useCompatibilityMode = defaults.bool(forKey: SettingsKeys.useCompatibilityMode)
        blurWhenAway = defaults.bool(forKey: SettingsKeys.blurWhenAway)
        pauseOnTheGo = defaults.bool(forKey: SettingsKeys.pauseOnTheGo)
        selectedCameraID = defaults.string(forKey: SettingsKeys.lastCameraID)
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

    func deleteProfile(forKey key: String) {
        let defaults = UserDefaults.standard
        var profiles = defaults.dictionary(forKey: SettingsKeys.profiles) as? [String: Data] ?? [:]
        profiles.removeValue(forKey: key)
        defaults.set(profiles, forKey: SettingsKeys.profiles)
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

    func buildConfigKey(displayUUIDs: [String]) -> String {
        return "displays:\(displayUUIDs.joined(separator: "+"))"
    }

    func getCurrentConfigKey() -> String {
        let displays = getDisplayUUIDs()
        return buildConfigKey(displayUUIDs: displays)
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

            // Only handle when reconfiguration completes
            if flags.contains(.beginConfigurationFlag) {
                return
            }

            appDelegate.scheduleDisplayConfigurationChange()
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(callback, userInfo)
    }

    func scheduleDisplayConfigurationChange() {
        // Debounce - displays often send multiple events
        DispatchQueue.main.async { [weak self] in
            self?.displayDebounceTimer?.invalidate()
            self?.displayDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.handleDisplayConfigurationChange()
            }
        }
    }

    func handleDisplayConfigurationChange() {
        print("[Display] Configuration changed, rebuilding overlay windows")
        // Rebuild overlay windows for new screen configuration
        rebuildOverlayWindows()

        // Don't change state if disabled
        guard state != .disabled else {
            print("[Display] App is disabled, skipping state change")
            return
        }

        // Check for on-the-go pause first
        if pauseOnTheGo && isLaptopOnlyConfiguration() {
            print("[Display] Laptop-only + pauseOnTheGo enabled, pausing")
            state = .paused(.onTheGo)
            return
        }

        // Get available cameras and current config
        let cameras = getAvailableCameras()
        let configKey = getCurrentConfigKey()
        let profile = loadProfile(forKey: configKey)

        print("[Display] Config key: \(configKey)")
        print("[Display] Available cameras: \(cameras.map { "\($0.localizedName) (\($0.uniqueID))" })")
        print("[Display] Profile exists: \(profile != nil), profile cameraID: \(profile?.cameraID ?? "none")")

        // No cameras at all - truly disconnected
        if cameras.isEmpty {
            print("[Display] No cameras available")
            state = .paused(.cameraDisconnected)
            return
        }

        // Check if we have a profile with a matching camera
        if let profile = profile,
           cameras.contains(where: { $0.uniqueID == profile.cameraID }) {
            // Profile's camera is available - use it
            print("[Display] Found profile with matching camera")
            if selectedCameraID != profile.cameraID {
                print("[Display] Switching to profile camera: \(profile.cameraID)")
                selectedCameraID = profile.cameraID
                switchCameraInput()
            }
            applyProfile(profile)
            updateCameraMenu()
            state = .monitoring
        } else {
            // Either no profile, or profile's camera isn't available
            // (but other cameras are) - need to calibrate for this config
            print("[Display] No matching profile, need calibration")
            updateCameraMenu()
            state = .paused(.noProfile)
        }
    }

    func rebuildOverlayWindows() {
        // Remove old windows
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        blurViews.removeAll()

        // Create new windows for current screens
        setupOverlayWindows()
    }

    // MARK: - Profile Management

    func applyProfile(_ profile: ProfileData) {
        goodPostureY = profile.goodPostureY
        badPostureY = profile.badPostureY
        neutralY = profile.neutralY
        postureRange = profile.postureRange
        isCalibrated = true
    }

    func setupOverlayWindows() {
        for screen in NSScreen.screens {
            // Use visibleFrame to exclude the menu bar area
            let frame = screen.visibleFrame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            // Use a level below popUpMenu so menu bar dropdowns appear above the blur
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            // Use NSVisualEffectView - supports both private API mode and compatibility mode
            let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            blurView.blendingMode = .behindWindow
            blurView.material = .fullScreenUI
            blurView.state = .active
            blurView.alphaValue = 0  // Start invisible

            window.contentView = blurView
            window.orderFrontRegardless()
            windows.append(window)
            blurViews.append(blurView)
        }
    }

    func updateBlur() {
        // Smooth transition - ease in slowly, ease out smoothly
        if currentBlurRadius < targetBlurRadius {
            // Slow ease-in: +1 per frame
            currentBlurRadius = min(currentBlurRadius + 1, targetBlurRadius)
        } else if currentBlurRadius > targetBlurRadius {
            // Fast ease-out: -3 per frame for quick recovery
            currentBlurRadius = max(currentBlurRadius - 3, targetBlurRadius)
        }

        // Calculate alpha for NSVisualEffectView modes
        // Square root curve for faster initial ramp, smooth fade
        let normalizedBlur = CGFloat(currentBlurRadius) / 64.0
        let visualEffectAlpha = min(1.0, sqrt(normalizedBlur) * 1.2)

        #if APP_STORE
        // App Store build: always use NSVisualEffectView (public API)
        for blurView in blurViews {
            blurView.alphaValue = visualEffectAlpha
        }
        #else
        if useCompatibilityMode {
            // Compatibility mode: use NSVisualEffectView alphaValue (public API)
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        } else if let getConnectionID = cgsMainConnectionID,
                  let setBlurRadius = cgsSetWindowBackgroundBlurRadius {
            // Default: use private CoreGraphics API for blur
            let cid = getConnectionID()
            for window in windows {
                _ = setBlurRadius(cid, UInt32(window.windowNumber), currentBlurRadius)
            }
        } else {
            // Fallback if private APIs unavailable: use NSVisualEffectView
            for blurView in blurViews {
                blurView.alphaValue = visualEffectAlpha
            }
        }
        #endif
    }

    func setupCamera() {
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .low  // Low resolution is sufficient for pose detection

        // Use selected camera or auto-select
        let cameras = getAvailableCameras()
        let camera: AVCaptureDevice?

        if let selectedID = selectedCameraID {
            camera = cameras.first { $0.uniqueID == selectedID }
        } else {
            // Prefer front-facing built-in camera, then any camera
            camera = cameras.first { $0.position == .front }
                ?? cameras.first
        }

        guard let selectedCamera = camera,
              let input = try? AVCaptureDeviceInput(device: selectedCamera) else {
            statusMenuItem.title = "Status: No Camera"
            return
        }

        // Store the selected camera ID for menu state
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

    // MARK: - Camera Hot-Plug Detection

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
        // Refresh camera menu with new device
        updateCameraMenu()
        syncUIToState()  // Update recalibrate menu item

        // If we're paused, check if this camera helps us
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video),
              case .paused(let reason) = state else { return }

        let configKey = getCurrentConfigKey()
        if let profile = loadProfile(forKey: configKey),
           profile.cameraID == device.uniqueID {
            // The camera we need just connected - resume
            selectedCameraID = profile.cameraID
            applyProfile(profile)
            switchCameraInput()
            state = .monitoring
        } else if reason == .cameraDisconnected {
            // A camera connected but it's not the profile's camera
            // Now we have cameras available, so user can recalibrate
            state = .paused(.noProfile)
        }
    }

    func handleCameraDisconnected(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice,
              device.hasMediaType(.video) else { return }

        print("[Camera] Disconnected: \(device.localizedName) (ID: \(device.uniqueID))")
        print("[Camera] Selected camera was: \(selectedCameraID ?? "nil")")

        // Check if disconnected camera was the selected one
        guard device.uniqueID == selectedCameraID else {
            // Not our camera - just refresh menu
            print("[Camera] Not our selected camera, just refreshing menu")
            updateCameraMenu()
            syncUIToState()
            return
        }

        // Our selected camera was unplugged
        let cameras = getAvailableCameras()
        print("[Camera] Remaining cameras: \(cameras.map { "\($0.localizedName) (\($0.uniqueID))" })")

        if let fallbackCamera = cameras.first {
            // Auto-select another available camera
            selectedCameraID = fallbackCamera.uniqueID
            print("[Camera] Auto-selecting fallback: \(fallbackCamera.localizedName)")
            switchCameraInput()
            updateCameraMenu()

            // Check if we have a profile for current display config that uses this camera
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
            // No cameras left
            print("[Camera] No cameras remaining!")
            updateCameraMenu()
            state = .paused(.cameraDisconnected)
        }
    }

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

        // Reset away counter - we can see the user
        consecutiveNoDetectionFrames = 0

        let noseY = nose.location.y
        currentNoseY = noseY

        // Update calibration controller if active
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
        // Reset detection counters since we can't see the user
        consecutiveNoDetectionFrames += 1
        consecutiveBadFrames = 0
        consecutiveGoodFrames = 0

        guard state == .monitoring && isCalibrated && blurWhenAway else {
            consecutiveNoDetectionFrames = 0
            return
        }

        if consecutiveNoDetectionFrames >= awayFrameThreshold {
            // User is away - apply full blur for privacy
            targetBlurRadius = 64

            DispatchQueue.main.async {
                self.statusMenuItem.title = "Status: Away"
                self.statusItem.button?.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "Away")
            }
        }
    }

    func analyzeFace(_ face: VNFaceObservation) {
        // Reset away counter - we can see the user
        consecutiveNoDetectionFrames = 0

        let faceY = face.boundingBox.midY
        currentNoseY = faceY

        // Update calibration controller if active
        if state == .calibrating {
            calibrationController?.updateCurrentNoseY(faceY)
            return
        }

        guard state == .monitoring && isCalibrated else { return }

        evaluatePosture(currentY: faceY)
    }

    func smoothNoseY(_ rawY: CGFloat) -> CGFloat {
        // Add to history
        noseYHistory.append(rawY)

        // Keep only last N values
        if noseYHistory.count > smoothingWindow {
            noseYHistory.removeFirst()
        }

        // Return average
        let sum = noseYHistory.reduce(0, +)
        smoothedNoseY = sum / CGFloat(noseYHistory.count)
        return smoothedNoseY
    }

    func evaluatePosture(currentY: CGFloat) {
        // Apply smoothing to reduce flicker
        let smoothedY = smoothNoseY(currentY)

        // Slouching = head drops BELOW the minimum calibrated position (bottom corners)
        let slouchAmount = badPostureY - smoothedY  // Positive = below minimum = slouching

        // Apply sensitivity and calculate threshold
        let baseThreshold = deadZone * postureRange * sensitivity

        // Hysteresis: require more slouch to enter slouch state, less to exit
        // This prevents flickering at the boundary
        let enterThreshold = baseThreshold
        let exitThreshold = baseThreshold * 0.5  // Easier to exit slouch state

        let threshold = isCurrentlySlouching ? exitThreshold : enterThreshold
        let isBadPosture = slouchAmount > threshold

        if isBadPosture {
            consecutiveBadFrames += 1
            consecutiveGoodFrames = 0

            if consecutiveBadFrames >= frameThreshold {
                isCurrentlySlouching = true

                // Calculate blur intensity with gentle easing
                let severity = (slouchAmount - enterThreshold) / postureRange
                let clampedSeverity = min(1.0, max(0.0, severity))
                let easedSeverity = clampedSeverity * clampedSeverity  // Quadratic ease-in

                // Start blur at 2 (barely perceptible), max at 64
                let blurIntensity = Int32(2 + easedSeverity * 62 * sensitivity)
                targetBlurRadius = min(64, blurIntensity)

                DispatchQueue.main.async {
                    self.statusMenuItem.title = "Status: Slouching"
                    self.statusItem.button?.image = NSImage(systemSymbolName: "figure.fall", accessibilityDescription: "Bad Posture")
                }
            }
        } else {
            consecutiveGoodFrames += 1
            consecutiveBadFrames = 0

            // Start fading blur immediately when posture improves
            targetBlurRadius = 0

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

extension AppDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Detect when camera starts working (permission was granted)
        if waitingForPermission {
            DispatchQueue.main.async {
                self.onCameraPermissionGranted()
            }
        }

        // Throttle frame processing to reduce CPU usage (~10fps instead of 30fps)
        let now = Date()
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        processFrame(pixelBuffer)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
