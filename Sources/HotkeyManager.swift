import Carbon.HIToolbox
import AppKit

/// Manages global keyboard shortcut registration using Carbon API
final class HotkeyManager {

    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    private var onToggle: (() -> Void)?

    var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                register()
            } else {
                unregister()
            }
        }
    }

    var shortcut: KeyboardShortcut = .defaultShortcut {
        didSet {
            if isEnabled {
                register()
            }
        }
    }

    // MARK: - Public API

    func configure(enabled: Bool, shortcut: KeyboardShortcut, onToggle: @escaping () -> Void) {
        self.isEnabled = enabled
        self.shortcut = shortcut
        self.onToggle = onToggle

        if enabled {
            register()
        }
    }

    func register() {
        unregister()

        guard isEnabled else { return }

        let carbonModifiers = carbonModifiersFromNSEvent(shortcut.modifiers)

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x504F5354) // "POST"
        hotKeyID.id = 1

        if carbonEventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            // Store weak reference to self for callback
            let refcon = Unmanaged.passUnretained(self).toOpaque()

            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, refcon) -> OSStatus in
                    guard let refcon = refcon else { return noErr }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.onToggle?()
                    }
                    return noErr
                },
                1,
                &eventType,
                refcon,
                &carbonEventHandler
            )

            if status != noErr {
                return
            }
        }

        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )

        if status != noErr {
            // Registration failed - could log this
        }
    }

    func unregister() {
        if let hotKeyRef = carbonHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            carbonHotKeyRef = nil
        }
    }

    // MARK: - Helpers

    private func carbonModifiersFromNSEvent(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        return carbonMods
    }

    deinit {
        unregister()
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
        }
    }
}
