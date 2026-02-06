import AppKit

// MARK: - Calibration View

class CalibrationView: NSView {
    var targetPosition: NSPoint = .zero
    var pulsePhase: CGFloat = 0
    var instructionText: String = L("calibration.lookAtRing")
    var stepText: String = L("calibration.stepOf", 1, 4)
    var showRing: Bool = true
    var waitingForAirPods: Bool = false
    private var keycapSegmentCache: [String: [(text: String, isKeycap: Bool)]] = [:]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Dark overlay
        NSColor.black.withAlphaComponent(0.85).setFill()
        dirtyRect.fill()

        // Show AirPods waiting state
        if waitingForAirPods {
            drawWaitingForAirPods()
            return
        }

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

        // Draw step indicator at top center
        let stepRect = NSRect(x: 0, y: bounds.height - 100, width: bounds.width, height: 40)
        (stepText as NSString).draw(in: stepRect, withAttributes: stepAttrs)

        // Draw instruction in center
        let textRect = NSRect(x: 0, y: bounds.midY - 20, width: bounds.width, height: 50)
        (instructionText as NSString).draw(in: textRect, withAttributes: titleAttrs)

        // Draw hint with keycap for Space
        let hintY = bounds.midY - 70
        drawLocalizedHintWithKeycap(
            text: L("calibration.hint.tapSpace"),
            centerY: hintY,
            textColor: NSColor.cyan,
            fontSize: 18
        )

        // Draw escape hint with keycap for Esc
        let escapeY = bounds.midY - 110
        drawLocalizedHintWithKeycap(
            text: L("calibration.hint.escToSkip"),
            centerY: escapeY,
            textColor: NSColor.white.withAlphaComponent(0.5),
            fontSize: 14
        )
    }

    private func drawLocalizedHintWithKeycap(text: String, centerY: CGFloat, textColor: NSColor, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let keycapFont = NSFont.systemFont(ofSize: fontSize - 1, weight: .semibold)

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let keycapTextAttrs: [NSAttributedString.Key: Any] = [
            .font: keycapFont,
            .foregroundColor: NSColor.white
        ]

        let keycapPaddingH: CGFloat = 8
        let keycapPaddingV: CGFloat = 4

        let segments = keycapSegments(for: text)

        // Calculate total width
        var totalWidth: CGFloat = 0
        for segment in segments {
            if segment.isKeycap {
                let keycapTextSize = (segment.text as NSString).size(withAttributes: keycapTextAttrs)
                totalWidth += keycapTextSize.width + keycapPaddingH * 2
            } else {
                totalWidth += (segment.text as NSString).size(withAttributes: textAttrs).width
            }
        }

        var currentX = (bounds.width - totalWidth) / 2

        for segment in segments {
            if segment.isKeycap {
                let keycapTextSize = (segment.text as NSString).size(withAttributes: keycapTextAttrs)
                let keycapWidth = keycapTextSize.width + keycapPaddingH * 2
                let keycapHeight = keycapTextSize.height + keycapPaddingV * 2

                let keycapRect = NSRect(
                    x: currentX,
                    y: centerY - keycapPaddingV,
                    width: keycapWidth,
                    height: keycapHeight
                )
                let keycapPath = NSBezierPath(roundedRect: keycapRect, xRadius: 5, yRadius: 5)

                NSColor.white.withAlphaComponent(0.15).setFill()
                keycapPath.fill()
                NSColor.white.withAlphaComponent(0.3).setStroke()
                keycapPath.lineWidth = 1
                keycapPath.stroke()

                let keycapTextY = keycapRect.minY + (keycapRect.height - keycapTextSize.height) / 2
                (segment.text as NSString).draw(at: NSPoint(x: currentX + keycapPaddingH, y: keycapTextY), withAttributes: keycapTextAttrs)
                currentX += keycapWidth
            } else {
                (segment.text as NSString).draw(at: NSPoint(x: currentX, y: centerY), withAttributes: textAttrs)
                currentX += (segment.text as NSString).size(withAttributes: textAttrs).width
            }
        }
    }

    private func keycapSegments(for text: String) -> [(text: String, isKeycap: Bool)] {
        if let cached = keycapSegmentCache[text] {
            return cached
        }

        var segments: [(text: String, isKeycap: Bool)] = []
        var remaining = text
        while let openBrace = remaining.range(of: "{") {
            let prefix = String(remaining[..<openBrace.lowerBound])
            if !prefix.isEmpty {
                segments.append((prefix, false))
            }
            remaining = String(remaining[openBrace.upperBound...])
            if let closeBrace = remaining.range(of: "}") {
                let keycap = String(remaining[..<closeBrace.lowerBound])
                segments.append((keycap, true))
                remaining = String(remaining[closeBrace.upperBound...])
            } else {
                segments.append(("{\(remaining)", false))
                remaining = ""
                break
            }
        }
        if !remaining.isEmpty {
            segments.append((remaining, false))
        }

        keycapSegmentCache[text] = segments
        return segments
    }

    private func drawWaitingForAirPods() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        // Draw pulsing AirPods icon (using SF Symbol or text)
        let iconAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .light),
            .foregroundColor: NSColor.cyan.withAlphaComponent(0.7 + 0.3 * sin(pulsePhase)),
            .paragraphStyle: paragraphStyle
        ]
        let iconRect = NSRect(x: 0, y: bounds.midY + 20, width: bounds.width, height: 90)
        ("🎧" as NSString).draw(in: iconRect, withAttributes: iconAttrs)

        // Main instruction
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let titleRect = NSRect(x: 0, y: bounds.midY - 30, width: bounds.width, height: 45)
        (L("calibration.airpods.putIn") as NSString).draw(in: titleRect, withAttributes: titleAttrs)

        // Subtitle
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
            .paragraphStyle: paragraphStyle
        ]
        let subtitleRect = NSRect(x: 0, y: bounds.midY - 70, width: bounds.width, height: 30)
        (L("calibration.airpods.autoBegin") as NSString).draw(in: subtitleRect, withAttributes: subtitleAttrs)

        // Escape hint (keycap style)
        drawLocalizedHintWithKeycap(
            text: L("calibration.airpods.escToCancel"),
            centerY: bounds.midY - 120,
            textColor: NSColor.white.withAlphaComponent(0.5),
            fontSize: 14
        )
    }
}

// MARK: - Calibration Window Controller

@MainActor
class CalibrationWindowController: NSObject {
    var windows: [NSWindow] = []
    var calibrationViews: [CalibrationView] = []
    var animationTimer: Timer?
    var currentStep = 0
    var onComplete: (([CalibrationSample]) -> Void)?
    var onCancel: (() -> Void)?
    var capturedValues: [CalibrationSample] = []

    var localEventMonitor: Any?
    var globalEventMonitor: Any?

    // The detector being used for calibration
    weak var detector: PostureDetector?

    // Waiting for detector connection (e.g., AirPods in ears)
    var isWaitingForConnection: Bool = false

    // Store the original connection callback to restore later
    var originalConnectionCallback: ((Bool) -> Void)?

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
            case .topLeft: return L("calibration.corner.topLeft")
            case .topRight: return L("calibration.corner.topRight")
            case .bottomLeft: return L("calibration.corner.bottomLeft")
            case .bottomRight: return L("calibration.corner.bottomRight")
            }
        }
    }

    var steps: [CalibrationStep] = []

    func buildSteps() {
        steps = []
        let corners: [Corner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

        for screenIndex in 0..<NSScreen.screens.count {
            for corner in corners {
                steps.append(CalibrationStep(
                    instruction: L("calibration.lookAtCorner", corner.name),
                    screenIndex: screenIndex,
                    corner: corner
                ))
            }
        }
    }

    func start(detector: PostureDetector, onComplete: @escaping ([CalibrationSample]) -> Void, onCancel: @escaping () -> Void) {
        self.detector = detector
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

        // Check if detector needs to wait for connection (e.g., AirPods in ears)
        // Save the original callback to restore later
        originalConnectionCallback = detector.onConnectionStateChange

        if !detector.isConnected {
            // Show waiting state with lower window level so permission dialogs appear on top
            isWaitingForConnection = true
            for window in windows {
                window.level = .floating  // Lower level allows system dialogs on top
            }
            showWaitingForConnection()

            // Subscribe to connection state changes (wrapping the original callback)
            detector.onConnectionStateChange = { [weak self] isConnected in
                // Call our handler for calibration
                if isConnected {
                    self?.detectorConnected()
                }
                // Also call the original callback so AppDelegate stays in sync
                self?.originalConnectionCallback?(isConnected)
            }
        } else {
            // Already connected and authorized - proceed with calibration
            updateStep()
        }

        startAnimation()
    }

    func showWaitingForConnection() {
        for view in calibrationViews {
            view.waitingForAirPods = true  // View still uses this name for the UI state
            view.showRing = false
            view.needsDisplay = true
        }
    }

    func detectorConnected() {
        isWaitingForConnection = false

        // Raise window level back to full screen calibration level
        for window in windows {
            window.level = .screenSaver + 1
        }
        NSApp.activate(ignoringOtherApps: true)

        for view in calibrationViews {
            view.waitingForAirPods = false  // View still uses this name for the UI state
            view.needsDisplay = true
        }
        updateStep()
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
                view.stepText = L("calibration.stepOf", currentStep + 1, steps.count)
            } else {
                view.showRing = false
                view.instructionText = L("calibration.lookOtherScreen")
                view.stepText = L("calibration.stepOf", currentStep + 1, steps.count)
            }
            view.needsDisplay = true
        }
    }

    func startAnimation() {
        // Respect accessibility reduce motion preference
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for view in self.calibrationViews {
                    if !reduceMotion {
                        view.pulsePhase += 0.08
                    }
                    view.needsDisplay = true
                }
            }
        }
    }

    func captureCurrentPosition() {
        // Don't capture while waiting for detector connection
        guard !isWaitingForConnection else { return }

        // Get current calibration value from the detector
        if let detector {
            capturedValues.append(detector.getCurrentCalibrationValue())
        }

        currentStep += 1
        updateStep()
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

        // Restore original connection callback
        detector?.onConnectionStateChange = originalConnectionCallback
        originalConnectionCallback = nil

        for window in windows {
            window.orderOut(nil)
        }
        windows = []
        calibrationViews = []
    }
}
