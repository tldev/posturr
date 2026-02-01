import AppKit
import CoreGraphics

/// Monitors display configuration changes (connect/disconnect/arrangement)
final class DisplayMonitor {

    private var debounceTimer: Timer?
    private var callbackRegistered = false

    var onDisplayConfigurationChange: (() -> Void)?

    // MARK: - Public API

    func startMonitoring() {
        guard !callbackRegistered else { return }

        let callback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
            guard let userInfo = userInfo else { return }
            let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            // Ignore begin configuration events
            if flags.contains(.beginConfigurationFlag) {
                return
            }

            monitor.scheduleConfigurationChange()
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(callback, userInfo)
        callbackRegistered = true
    }

    // MARK: - Display Utilities

    /// Returns sorted list of display UUIDs for current configuration
    static func getDisplayUUIDs() -> [String] {
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

    /// Returns a unique key identifying the current display configuration
    static func getCurrentConfigKey() -> String {
        let displays = getDisplayUUIDs()
        return "displays:\(displays.joined(separator: "+"))"
    }

    /// Checks if running on laptop display only (no external monitors)
    static func isLaptopOnlyConfiguration() -> Bool {
        let screens = NSScreen.screens
        if screens.count != 1 { return false }

        guard let screen = screens.first,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }

        return CGDisplayIsBuiltin(displayID) != 0
    }

    // MARK: - Private

    private func scheduleConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            self?.debounceTimer?.invalidate()
            self?.debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                self?.onDisplayConfigurationChange?()
            }
        }
    }
}
