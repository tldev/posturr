import Foundation

/// Icon types that map to MenuBarIcon - keeps this module UI-framework agnostic
enum MenuBarIconType: Equatable {
    case good
    case bad
    case away
    case paused
    case calibrating
}

/// Pure representation of the UI state - no dependencies on AppKit
struct PostureUIState: Equatable {
    let statusText: String
    let icon: MenuBarIconType
    let isEnabled: Bool
    let canRecalibrate: Bool

    /// Derives the complete UI state from the current app state and flags
    static func derive(
        from appState: AppState,
        isCalibrated: Bool,
        isCurrentlyAway: Bool,
        isCurrentlySlouching: Bool,
        trackingSource: TrackingSource
    ) -> PostureUIState {
        switch appState {
        case .disabled:
            return PostureUIState(
                statusText: "Status: Disabled",
                icon: .paused,
                isEnabled: false,
                canRecalibrate: true
            )

        case .calibrating:
            return PostureUIState(
                statusText: "Status: Calibrating...",
                icon: .calibrating,
                isEnabled: true,
                canRecalibrate: false
            )

        case .monitoring:
            let (statusText, icon) = monitoringState(
                isCalibrated: isCalibrated,
                isCurrentlyAway: isCurrentlyAway,
                isCurrentlySlouching: isCurrentlySlouching
            )
            return PostureUIState(
                statusText: statusText,
                icon: icon,
                isEnabled: true,
                canRecalibrate: true
            )

        case .paused(let reason):
            let statusText = pausedStatusText(reason: reason, trackingSource: trackingSource)
            return PostureUIState(
                statusText: statusText,
                icon: .paused,
                isEnabled: true,
                canRecalibrate: true
            )
        }
    }

    private static func monitoringState(
        isCalibrated: Bool,
        isCurrentlyAway: Bool,
        isCurrentlySlouching: Bool
    ) -> (String, MenuBarIconType) {
        guard isCalibrated else {
            return ("Status: Starting...", .good)
        }

        if isCurrentlyAway {
            return ("Status: Away", .away)
        } else if isCurrentlySlouching {
            return ("Status: Slouching", .bad)
        } else {
            return ("Status: Good Posture", .good)
        }
    }

    private static func pausedStatusText(reason: PauseReason, trackingSource: TrackingSource) -> String {
        switch reason {
        case .noProfile:
            return "Status: Calibration needed"
        case .onTheGo:
            return "Status: Paused (on the go - recalibrate)"
        case .cameraDisconnected:
            return trackingSource == .camera ? "Status: Camera disconnected" : "Status: AirPods disconnected"
        case .screenLocked:
            return "Status: Paused (screen locked)"
        case .airPodsRemoved:
            return "Status: Paused (put in AirPods)"
        }
    }
}
