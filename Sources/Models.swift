import Foundation
import CoreGraphics
import AppKit

// MARK: - Icon Utilities

/// Applies macOS-style rounded corner mask to an app icon
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

// MARK: - Menu Bar Icons

enum MenuBarIcon: String, CaseIterable {
    case good = "posture-good"
    case bad = "posture-bad"
    case away = "posture-away"
    case paused = "posture-paused"
    case calibrating = "posture-calibrating"

    /// Fallback SF Symbol for each icon state
    private var fallbackSymbol: String {
        switch self {
        case .good: return "figure.stand"
        case .bad: return "figure.fall"
        case .away: return "figure.walk"
        case .paused: return "pause.circle"
        case .calibrating: return "figure.stand"
        }
    }

    /// Accessibility description for the icon
    private var accessibilityDescription: String {
        switch self {
        case .good: return "Good Posture"
        case .bad: return "Bad Posture"
        case .away: return "Away"
        case .paused: return "Paused"
        case .calibrating: return "Calibrating"
        }
    }

    /// Returns the menu bar icon, preferring custom PDF if available
    var image: NSImage? {
        // Try to load custom PDF icon from Resources/Icons/
        if let url = Bundle.main.url(forResource: rawValue, withExtension: "pdf", subdirectory: "Icons"),
           let customImage = NSImage(contentsOf: url) {
            // Resize to menu bar height (18pt) while preserving aspect ratio
            let targetHeight: CGFloat = 18
            let aspectRatio = customImage.size.width / customImage.size.height
            let targetWidth = targetHeight * aspectRatio
            let targetSize = NSSize(width: targetWidth, height: targetHeight)

            let resizedImage = NSImage(size: targetSize)
            resizedImage.lockFocus()
            customImage.draw(in: NSRect(origin: .zero, size: targetSize),
                           from: NSRect(origin: .zero, size: customImage.size),
                           operation: .copy,
                           fraction: 1.0)
            resizedImage.unlockFocus()
            resizedImage.isTemplate = true
            return resizedImage
        }

        // Fall back to SF Symbol
        let image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }
}

// MARK: - Constants

enum WarningDefaults {
    static let color = NSColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1.0)
}

// MARK: - Warning Mode

enum WarningMode: String, CaseIterable {
    case blur = "blur"
    case vignette = "vignette"
    case border = "border"
    case solid = "solid"
    case none = "none"

    /// Whether this mode uses the WarningOverlayManager for posture warnings.
    /// Vignette, border, and solid use the overlay system; blur and none do not.
    var usesWarningOverlay: Bool {
        switch self {
        case .vignette, .border, .solid: return true
        case .blur, .none: return false
        }
    }
}

// MARK: - Detection Mode

enum DetectionMode: String, CaseIterable {
    case responsive = "responsive"  // 10 fps - best accuracy (default)
    case balanced = "balanced"      // 4 fps - good balance
    case performance = "performance" // 2 fps - best battery life

    var frameRate: Double {
        switch self {
        case .responsive: return 10.0
        case .balanced: return 4.0
        case .performance: return 2.0
        }
    }

    var displayName: String {
        switch self {
        case .responsive: return "Responsive"
        case .balanced: return "Balanced"
        case .performance: return "Performance"
        }
    }
}

// MARK: - Settings Keys
enum SettingsKeys {
    static let intensity = "intensity"
    static let deadZone = "deadZone"
    static let useCompatibilityMode = "useCompatibilityMode"
    static let blurWhenAway = "blurWhenAway"
    static let showInDock = "showInDock"
    static let pauseOnTheGo = "pauseOnTheGo"
    static let lastCameraID = "lastCameraID"
    static let profiles = "profiles"
    static let warningMode = "warningMode"
    static let warningColor = "warningColor"
    static let warningOnsetDelay = "blurOnsetDelay"  // Keep key for backward compatibility
    static let toggleShortcutEnabled = "toggleShortcutEnabled"
    static let toggleShortcutKeyCode = "toggleShortcutKeyCode"
    static let toggleShortcutModifiers = "toggleShortcutModifiers"
    static let detectionMode = "detectionMode"
    static let trackingSource = "trackingSource"
    static let airPodsProfile = "airPodsProfile"
}

// MARK: - Keyboard Shortcut
struct KeyboardShortcut: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    // Default: Ctrl+Option+P
    static let defaultShortcut = KeyboardShortcut(
        keyCode: 35,  // 'P' key
        modifiers: [.control, .option]
    )

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    /// Returns lowercase character for use with NSMenuItem.keyEquivalent
    var keyCharacter: String {
        keyCodeToString(keyCode).lowercased()
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            50: "`", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 118: "F4", 119: "F2", 120: "F1", 122: "F16",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[keyCode] ?? "?"
    }
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
    case screenLocked
    case airPodsRemoved
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
