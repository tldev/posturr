import AppKit

/// Observes screen lock/unlock and sleep/wake events
final class ScreenLockObserver {

    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    var onScreenLocked: (() -> Void)?
    var onScreenUnlocked: (() -> Void)?

    var isObserving: Bool {
        lockObserver != nil
    }

    // MARK: - Public API

    func startObserving() {
        guard !isObserving else { return }

        let dnc = DistributedNotificationCenter.default()

        lockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenLocked?()
        }

        unlockObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlocked?()
        }

        // Screen sleep/wake: handles cases where the display sleeps without
        // an explicit lock (e.g. energy saver, lid close without password).
        let wnc = NSWorkspace.shared.notificationCenter

        sleepObserver = wnc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenLocked?()
        }

        wakeObserver = wnc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onScreenUnlocked?()
        }
    }

    func stopObserving() {
        let dnc = DistributedNotificationCenter.default()

        if let observer = lockObserver {
            dnc.removeObserver(observer)
            lockObserver = nil
        }

        if let observer = unlockObserver {
            dnc.removeObserver(observer)
            unlockObserver = nil
        }

        let wnc = NSWorkspace.shared.notificationCenter

        if let observer = sleepObserver {
            wnc.removeObserver(observer)
            sleepObserver = nil
        }

        if let observer = wakeObserver {
            wnc.removeObserver(observer)
            wakeObserver = nil
        }
    }

    deinit {
        stopObserving()
    }
}
