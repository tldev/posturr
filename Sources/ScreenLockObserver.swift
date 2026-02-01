import Foundation

/// Observes screen lock/unlock events via DistributedNotificationCenter
final class ScreenLockObserver {

    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

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
    }

    deinit {
        stopObserving()
    }
}
