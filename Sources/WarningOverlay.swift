import AppKit
import CoreGraphics

// MARK: - Vignette Gradient Layer

class VignetteGradientLayer: CALayer {
    var intensity: CGFloat = 0.0
    var reach: CGFloat = 0.7
    var warningColor: NSColor = WarningDefaults.color

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? VignetteGradientLayer {
            intensity = other.intensity
            reach = other.reach
            warningColor = other.warningColor
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in ctx: CGContext) {
        guard intensity > 0 else { return }

        let bounds = self.bounds
        let centerX = bounds.midX
        let centerY = bounds.midY

        let maxRadius = sqrt(centerX * centerX + centerY * centerY)

        let baseInnerRatio: CGFloat = 1.0 - reach
        let innerRatio = max(0.05, baseInnerRatio - (intensity * 0.5))
        let innerRadius = maxRadius * innerRatio

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let maxAlpha: CGFloat = 0.95
        let alpha = intensity * maxAlpha

        let colors: [CGColor] = [
            NSColor.clear.cgColor,
            warningColor.withAlphaComponent(alpha * 0.4).cgColor,
            warningColor.withAlphaComponent(alpha * 0.8).cgColor,
            warningColor.withAlphaComponent(alpha).cgColor
        ]

        let locations: [CGFloat] = [0.0, 0.3, 0.6, 1.0]

        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors as CFArray,
            locations: locations
        ) else { return }

        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: centerX, y: centerY),
            startRadius: innerRadius,
            endCenter: CGPoint(x: centerX, y: centerY),
            endRadius: maxRadius,
            options: [.drawsAfterEndLocation]
        )
    }
}

// MARK: - Vignette Overlay View

class VignetteOverlayView: NSView {
    private var vignetteLayer: VignetteGradientLayer!
    private var lastDrawnIntensity: CGFloat = -1

    var intensity: CGFloat = 0.0 {
        didSet {
            updateLayerIfNeeded()
        }
    }

    var reach: CGFloat = 0.7 {
        didSet {
            vignetteLayer.reach = reach
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    var warningColor: NSColor = WarningDefaults.color {
        didSet {
            vignetteLayer.warningColor = warningColor
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        vignetteLayer = VignetteGradientLayer()
        vignetteLayer.frame = bounds
        vignetteLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(vignetteLayer)
    }

    override func layout() {
        super.layout()
        vignetteLayer.frame = bounds
        lastDrawnIntensity = -1
        updateLayerIfNeeded()
    }

    private func updateLayerIfNeeded() {
        // Only redraw if intensity changed enough to be visible
        let threshold: CGFloat = 0.01
        guard abs(intensity - lastDrawnIntensity) > threshold else { return }

        lastDrawnIntensity = intensity
        vignetteLayer.intensity = intensity
        vignetteLayer.setNeedsDisplay()
    }
}

// MARK: - Border Gradient Layer

class BorderGradientLayer: CALayer {
    var intensity: CGFloat = 0.0
    var maxBorderWidth: CGFloat = 80.0
    var warningColor: NSColor = WarningDefaults.color

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        isOpaque = false
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? BorderGradientLayer {
            intensity = other.intensity
            maxBorderWidth = other.maxBorderWidth
            warningColor = other.warningColor
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(in ctx: CGContext) {
        guard intensity > 0 else { return }

        let bounds = self.bounds
        let borderWidth = maxBorderWidth * intensity
        let maxAlpha: CGFloat = 0.9
        let alpha = intensity * maxAlpha

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outerColor = warningColor.withAlphaComponent(alpha).cgColor
        let innerColor = NSColor.clear.cgColor

        // Create gradient once and reuse for all edges
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [outerColor, innerColor] as CFArray,
            locations: [0.0, 1.0]
        ) else { return }

        // Top border
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: bounds.height - borderWidth, width: bounds.width, height: borderWidth))
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: bounds.midX, y: bounds.height),
            end: CGPoint(x: bounds.midX, y: bounds.height - borderWidth),
            options: [])
        ctx.restoreGState()

        // Bottom border
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: borderWidth))
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: bounds.midX, y: 0),
            end: CGPoint(x: bounds.midX, y: borderWidth),
            options: [])
        ctx.restoreGState()

        // Left border
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: borderWidth, height: bounds.height))
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: 0, y: bounds.midY),
            end: CGPoint(x: borderWidth, y: bounds.midY),
            options: [])
        ctx.restoreGState()

        // Right border
        ctx.saveGState()
        ctx.clip(to: CGRect(x: bounds.width - borderWidth, y: 0, width: borderWidth, height: bounds.height))
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: bounds.width, y: bounds.midY),
            end: CGPoint(x: bounds.width - borderWidth, y: bounds.midY),
            options: [])
        ctx.restoreGState()
    }
}

// MARK: - Border Overlay View

class BorderOverlayView: NSView {
    private var borderLayer: BorderGradientLayer!
    private var lastDrawnIntensity: CGFloat = -1

    var intensity: CGFloat = 0.0 {
        didSet {
            updateLayerIfNeeded()
        }
    }

    var maxBorderWidth: CGFloat = 80.0 {
        didSet {
            borderLayer.maxBorderWidth = maxBorderWidth
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    var warningColor: NSColor = WarningDefaults.color {
        didSet {
            borderLayer.warningColor = warningColor
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        borderLayer = BorderGradientLayer()
        borderLayer.frame = bounds
        borderLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.addSublayer(borderLayer)
    }

    override func layout() {
        super.layout()
        borderLayer.frame = bounds
        lastDrawnIntensity = -1
        updateLayerIfNeeded()
    }

    private func updateLayerIfNeeded() {
        let threshold: CGFloat = 0.01
        guard abs(intensity - lastDrawnIntensity) > threshold else { return }

        lastDrawnIntensity = intensity
        borderLayer.intensity = intensity
        borderLayer.setNeedsDisplay()
    }
}

// MARK: - Solid Overlay View

class SolidOverlayView: NSView {
    private var colorLayer: CALayer!
    private var lastDrawnIntensity: CGFloat = -1

    var intensity: CGFloat = 0.0 {
        didSet {
            updateLayerIfNeeded()
        }
    }

    var warningColor: NSColor = WarningDefaults.color {
        didSet {
            lastDrawnIntensity = -1
            updateLayerIfNeeded()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        colorLayer = CALayer()
        colorLayer.frame = bounds
        colorLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(colorLayer)
    }

    override func layout() {
        super.layout()
        colorLayer.frame = bounds
        lastDrawnIntensity = -1
        updateLayerIfNeeded()
    }

    private func updateLayerIfNeeded() {
        let threshold: CGFloat = 0.01
        guard abs(intensity - lastDrawnIntensity) > threshold else { return }

        lastDrawnIntensity = intensity

        let maxAlpha: CGFloat = 0.95
        let alpha = intensity * maxAlpha
        colorLayer.backgroundColor = warningColor.withAlphaComponent(alpha).cgColor
    }
}

// MARK: - Warning Overlay Manager

class WarningOverlayManager {
    var windows: [NSWindow] = []
    var overlayViews: [NSView] = []
    var currentIntensity: CGFloat = 0.0
    var targetIntensity: CGFloat = 0.0
    var mode: WarningMode = .vignette
    var warningColor: NSColor = WarningDefaults.color

    func setupOverlayWindows() {
        for screen in NSScreen.screens {
            let frame = screen.frame  // Use full frame including menu bar
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.ignoresMouseEvents = true
            window.hasShadow = false

            let overlayView: NSView
            switch mode {
            case .vignette:
                let view = VignetteOverlayView(frame: NSRect(origin: .zero, size: frame.size))
                view.warningColor = warningColor
                overlayView = view
            case .border:
                let view = BorderOverlayView(frame: NSRect(origin: .zero, size: frame.size))
                view.warningColor = warningColor
                overlayView = view
            case .solid:
                let view = SolidOverlayView(frame: NSRect(origin: .zero, size: frame.size))
                view.warningColor = warningColor
                overlayView = view
            case .blur, .none:
                // Blur is handled separately in AppDelegate, none has no visual
                overlayView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            }

            window.contentView = overlayView
            window.orderFrontRegardless()

            windows.append(window)
            overlayViews.append(overlayView)
        }
    }

    func rebuildOverlayWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        overlayViews.removeAll()
        setupOverlayWindows()
    }

    func updateWarning() {
        // Smooth transition - faster ramp up than blur
        let step: CGFloat = 0.05
        if currentIntensity < targetIntensity {
            currentIntensity = min(currentIntensity + step, targetIntensity)
        } else if currentIntensity > targetIntensity {
            // Near-instant recovery - clear immediately when posture is good
            currentIntensity = max(currentIntensity - 0.5, targetIntensity)
        }

        for view in overlayViews {
            if let vignetteView = view as? VignetteOverlayView {
                vignetteView.intensity = currentIntensity
            } else if let borderView = view as? BorderOverlayView {
                borderView.intensity = currentIntensity
            } else if let solidView = view as? SolidOverlayView {
                solidView.intensity = currentIntensity
            }
        }
    }

    func updateColor(_ color: NSColor) {
        warningColor = color
        for view in overlayViews {
            if let vignetteView = view as? VignetteOverlayView {
                vignetteView.warningColor = color
            } else if let borderView = view as? BorderOverlayView {
                borderView.warningColor = color
            } else if let solidView = view as? SolidOverlayView {
                solidView.warningColor = color
            }
        }
    }
}
