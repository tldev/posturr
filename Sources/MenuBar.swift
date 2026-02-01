import AppKit

// MARK: - Menu Bar Manager

final class MenuBarManager {
    private(set) var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var enabledMenuItem: NSMenuItem!
    private var recalibrateMenuItem: NSMenuItem!

    // Callbacks
    var onToggleEnabled: (() -> Void)?
    var onRecalibrate: (() -> Void)?
    var onShowAnalytics: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = MenuBarIcon.good.image
        }

        let menu = NSMenu()

        // Status
        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Enabled toggle
        enabledMenuItem = NSMenuItem(title: "Enable", action: #selector(handleToggleEnabled), keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        // Recalibrate
        recalibrateMenuItem = NSMenuItem(title: "Recalibrate", action: #selector(handleRecalibrate), keyEquivalent: "r")
        recalibrateMenuItem.target = self
        menu.addItem(recalibrateMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Analytics
        let statsItem = NSMenuItem(title: "Analytics", action: #selector(handleShowAnalytics), keyEquivalent: "a")
        statsItem.target = self
        statsItem.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Analytics")
        menu.addItem(statsItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(handleOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(handleQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Updates

    func updateStatus(text: String, icon: MenuBarIcon) {
        statusMenuItem.title = text
        statusItem.button?.image = icon.image
    }

    func updateEnabledState(_ enabled: Bool) {
        enabledMenuItem.state = enabled ? .on : .off
    }

    func updateRecalibrateEnabled(_ enabled: Bool) {
        recalibrateMenuItem.isEnabled = enabled
    }

    func updateShortcut(enabled: Bool, shortcut: KeyboardShortcut) {
        if enabled {
            enabledMenuItem.keyEquivalent = shortcut.keyCharacter
            enabledMenuItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            enabledMenuItem.keyEquivalent = ""
            enabledMenuItem.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Actions

    @objc private func handleToggleEnabled() {
        onToggleEnabled?()
    }

    @objc private func handleRecalibrate() {
        onRecalibrate?()
    }

    @objc private func handleShowAnalytics() {
        onShowAnalytics?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }
}
