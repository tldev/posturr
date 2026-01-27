import Foundation
import CoreGraphics
import AppKit

// MARK: - Constants

enum WarningDefaults {
    static let color = NSColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1.0)
}

// MARK: - Warning Mode

enum WarningMode: String, CaseIterable {
    case blur = "blur"
    case vignette = "vignette"
    case border = "border"
}

// MARK: - Settings Keys
enum SettingsKeys {
    static let intensity = "intensity"
    static let deadZone = "deadZone"
    static let useCompatibilityMode = "useCompatibilityMode"
    static let blurWhenAway = "blurWhenAway"
    static let disableBlur = "disableBlur"
    static let showInDock = "showInDock"
    static let pauseOnTheGo = "pauseOnTheGo"
    static let lastCameraID = "lastCameraID"
    static let profiles = "profiles"
    static let warningMode = "warningMode"
    static let warningColor = "warningColor"
    static let warningOnsetDelay = "blurOnsetDelay"  // Keep key for backward compatibility
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
