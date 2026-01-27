import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Settings Window Controller

class SettingsWindowController: NSObject, NSWindowDelegate {
    var window: NSWindow?
    weak var appDelegate: AppDelegate?

    func showSettings(appDelegate: AppDelegate, fromStatusItem statusItem: NSStatusItem?) {
        self.appDelegate = appDelegate

        // Find the screen where the status item is located
        let targetScreen = statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first

        if let existingWindow = window {
            // Move existing window to the correct screen and center it
            if let screen = targetScreen {
                centerWindow(existingWindow, on: screen)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appDelegate: appDelegate)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Posturr Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Center on the target screen
        if let screen = targetScreen {
            centerWindow(window, on: screen)
        } else {
            window.center()
        }

        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Only hide from Dock if user hasn't enabled "Show in Dock"
        if let appDelegate = appDelegate, !appDelegate.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let screenFrame = screen.frame
        let windowSize = window.frame.size
        let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func close() {
        window?.close()
    }
}

// MARK: - Setting Toggle Component

struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    let helpText: String
    @State private var showingHelp = false

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
            Button(action: { showingHelp.toggle() }) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
                Text(helpText)
                    .padding(10)
                    .frame(width: 200)
            }
        }
    }
}

// MARK: - GroupBox with Info Icon

struct GroupBoxWithInfo<Content: View>: View {
    let title: String
    let helpText: String
    let content: Content
    @State private var showingHelp = false

    init(_ title: String, helpText: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.helpText = helpText
        self.content = content()
    }

    var body: some View {
        GroupBox {
            content
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Button(action: { showingHelp.toggle() }) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
                    Text(helpText)
                        .padding(10)
                        .frame(width: 220)
                }
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let appDelegate: AppDelegate

    // Local state that syncs with AppDelegate
    @State private var intensity: Double = 1.0
    @State private var deadZone: Double = 0.03
    @State private var intensitySlider: Double = 2
    @State private var deadZoneSlider: Double = 2
    @State private var blurWhenAway: Bool = false
    @State private var showInDock: Bool = false
    @State private var pauseOnTheGo: Bool = false
    @State private var useCompatibilityMode: Bool = false
    @State private var selectedCameraID: String = ""
    @State private var availableCameras: [(id: String, name: String)] = []
    @State private var warningMode: WarningMode = .blur
    @State private var warningColor: Color = Color(WarningDefaults.color)
    @State private var warningOnsetDelay: Double = 0.0
    @State private var launchAtLogin: Bool = false

    let intensityValues: [Double] = [0.08, 0.15, 0.35, 0.65, 1.2]
    let intensityLabels = ["Gentle", "Easy", "Medium", "Firm", "Aggressive"]

    let deadZoneValues: [Double] = [0.0, 0.08, 0.15, 0.25, 0.40]
    let deadZoneLabels = ["Strict", "Tight", "Medium", "Relaxed", "Loose"]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left column - Detection settings
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Camera") {
                    Picker("", selection: $selectedCameraID) {
                        ForEach(availableCameras, id: \.id) { camera in
                            Text(camera.name).tag(camera.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedCameraID) { newValue in
                        if newValue != appDelegate.selectedCameraID {
                            appDelegate.selectedCameraID = newValue
                            appDelegate.saveSettings()
                            appDelegate.restartCamera()
                        }
                    }
                }

                GroupBoxWithInfo("Warning Style", helpText: "How Posturr alerts you when slouching. Blur obscures the screen, Vignette shows a red glow from the edges, Border shows red borders around the screen. None disables visual warnings.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("", selection: $warningMode) {
                            Text("Blur").tag(WarningMode.blur)
                            Text("Vignette").tag(WarningMode.vignette)
                            Text("Border").tag(WarningMode.border)
                            Text("None").tag(WarningMode.none)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onChange(of: warningMode) { newValue in
                            if newValue != appDelegate.warningMode {
                                appDelegate.switchWarningMode(to: newValue)
                                appDelegate.saveSettings()
                            }
                        }

                        HStack {
                            Text("Color")
                            Spacer()
                            ColorPicker("", selection: $warningColor, supportsOpacity: false)
                                .labelsHidden()
                                .onChange(of: warningColor) { newValue in
                                    let nsColor = NSColor(newValue)
                                    appDelegate.updateWarningColor(nsColor)
                                    appDelegate.saveSettings()
                                }
                        }
                    }
                }

                GroupBoxWithInfo("Dead Zone", helpText: "How much you can move before blur starts. A relaxed dead zone allows more natural movement without triggering blur.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: $deadZoneSlider, in: 0...4, step: 1)
                            .onChange(of: deadZoneSlider) { newValue in
                                let index = Int(newValue)
                                deadZone = deadZoneValues[index]
                                appDelegate.deadZone = deadZone
                                appDelegate.saveSettings()
                            }
                        HStack {
                            Text("Strict")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(deadZoneLabels[Int(deadZoneSlider)])
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text("Relaxed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                GroupBoxWithInfo("Intensity", helpText: "How quickly blur increases as you slouch past the dead zone. Aggressive intensity applies stronger blur sooner.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: $intensitySlider, in: 0...4, step: 1)
                            .onChange(of: intensitySlider) { newValue in
                                let index = Int(newValue)
                                intensity = intensityValues[index]
                                appDelegate.intensity = intensity
                                appDelegate.saveSettings()
                            }
                        HStack {
                            Text("Gentle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(intensityLabels[Int(intensitySlider)])
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text("Aggressive")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                GroupBoxWithInfo("Warning Delay", helpText: "Grace period before warning activates. Allows brief glances at keyboard without triggering the warning.") {
                    VStack(alignment: .leading, spacing: 8) {
                        Slider(value: $warningOnsetDelay, in: 0...30, step: 1)
                            .onChange(of: warningOnsetDelay) { newValue in
                                appDelegate.warningOnsetDelay = newValue
                                appDelegate.saveSettings()
                            }
                        HStack {
                            Text("0s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(warningOnsetDelay))s")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                            Text("30s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(width: 240)

            // Right column - Behavior toggles
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Behavior") {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingToggle(
                            title: "Blur when away",
                            isOn: $blurWhenAway,
                            helpText: "Apply full blur when you step away from the screen"
                        )
                        .onChange(of: blurWhenAway) { newValue in
                            appDelegate.blurWhenAway = newValue
                            appDelegate.saveSettings()
                            if !newValue {
                                appDelegate.consecutiveNoDetectionFrames = 0
                            }
                        }

                        Divider()

                        SettingToggle(
                            title: "Show in dock",
                            isOn: $showInDock,
                            helpText: "Keep Posturr visible in the Dock and Cmd+Tab switcher"
                        )
                        .onChange(of: showInDock) { newValue in
                            appDelegate.showInDock = newValue
                            appDelegate.saveSettings()
                            // Change policy but keep settings window open
                            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                            // Re-activate to keep window visible
                            DispatchQueue.main.async {
                                appDelegate.settingsWindowController.window?.makeKeyAndOrderFront(nil)
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }

                        Divider()

                        SettingToggle(
                            title: "Pause on the go",
                            isOn: $pauseOnTheGo,
                            helpText: "Auto-pause when laptop display becomes the only screen"
                        )
                        .onChange(of: pauseOnTheGo) { newValue in
                            appDelegate.pauseOnTheGo = newValue
                            appDelegate.saveSettings()
                            if !newValue && appDelegate.state == .paused(.onTheGo) {
                                appDelegate.state = .monitoring
                            }
                        }

                        Divider()

                        SettingToggle(
                            title: "Launch at login",
                            isOn: $launchAtLogin,
                            helpText: "Automatically start Posturr when you log in to your Mac"
                        )
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                print("Failed to toggle launch at login: \(error)")
                                // Revert toggle if operation failed
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    }
                }

                #if !APP_STORE
                GroupBox("Advanced") {
                    SettingToggle(
                        title: "Compatibility mode",
                        isOn: $useCompatibilityMode,
                        helpText: "Enable if blur isn't appearing. Uses alternative rendering method."
                    )
                    .onChange(of: useCompatibilityMode) { newValue in
                        appDelegate.useCompatibilityMode = newValue
                        appDelegate.saveSettings()
                        appDelegate.currentBlurRadius = 0
                        for blurView in appDelegate.blurViews {
                            blurView.alphaValue = 0
                        }
                    }
                }
                #endif

                Spacer()
            }
            .frame(width: 280)
        }
        .padding(20)
        .onAppear {
            loadFromAppDelegate()
        }
    }

    private func loadFromAppDelegate() {
        intensity = appDelegate.intensity
        deadZone = appDelegate.deadZone
        blurWhenAway = appDelegate.blurWhenAway
        showInDock = appDelegate.showInDock
        pauseOnTheGo = appDelegate.pauseOnTheGo
        useCompatibilityMode = appDelegate.useCompatibilityMode
        warningMode = appDelegate.warningMode
        warningColor = Color(appDelegate.warningColor)
        warningOnsetDelay = appDelegate.warningOnsetDelay

        // Set slider indices based on loaded values
        intensitySlider = Double(intensityValues.firstIndex(of: intensity) ?? 2)
        deadZoneSlider = Double(deadZoneValues.firstIndex(of: deadZone) ?? 2)

        // Load cameras
        let cameras = appDelegate.getAvailableCameras()
        availableCameras = cameras.map { (id: $0.uniqueID, name: $0.localizedName) }
        selectedCameraID = appDelegate.selectedCameraID ?? cameras.first?.uniqueID ?? ""

        // Load launch at login state from system
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
