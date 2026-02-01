import AVFoundation

/// Observes camera connect/disconnect events
final class CameraObserver {

    private var connectedObserver: NSObjectProtocol?
    private var disconnectedObserver: NSObjectProtocol?

    var onCameraConnected: ((AVCaptureDevice) -> Void)?
    var onCameraDisconnected: ((AVCaptureDevice) -> Void)?

    var isObserving: Bool {
        connectedObserver != nil
    }

    // MARK: - Public API

    func startObserving() {
        guard !isObserving else { return }

        connectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.video) else { return }
            self?.onCameraConnected?(device)
        }

        disconnectedObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.video) else { return }
            self?.onCameraDisconnected?(device)
        }
    }

    func stopObserving() {
        if let observer = connectedObserver {
            NotificationCenter.default.removeObserver(observer)
            connectedObserver = nil
        }

        if let observer = disconnectedObserver {
            NotificationCenter.default.removeObserver(observer)
            disconnectedObserver = nil
        }
    }

    deinit {
        stopObserving()
    }
}
