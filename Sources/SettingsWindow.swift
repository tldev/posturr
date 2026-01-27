import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Brand Colors

extension Color {
    static let brandCyan = Color(red: 0.31, green: 0.82, blue: 0.77)      // #4fd1c5
    static let brandNavy = Color(red: 0.10, green: 0.15, blue: 0.27)      // #1a2744
    static let sectionBackground = Color(NSColor.controlBackgroundColor).opacity(0.5)
}

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

        // Let the content determine the window size
        let fittingSize = hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor

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

// MARK: - Section Card

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.brandCyan)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Setting Row

struct SettingRow: View {
    let title: String
    let helpText: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13))

            HelpButton(text: helpText)

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(.brandCyan)
        }
    }
}

// MARK: - Subtle Divider

struct SubtleDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

// MARK: - Labeled Slider

struct LabeledSlider: View {
    let title: String
    let helpText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let leftLabel: String
    let rightLabel: String
    let valueLabel: String
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))

                HelpButton(text: helpText)

                Spacer()

                Text(valueLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.brandCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.brandCyan.opacity(0.12))
                    )
            }

            Slider(value: $value, in: range, step: step)
                .tint(.brandCyan)

            HStack {
                Text(leftLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
                Text(rightLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }
}

// MARK: - Warning Style Picker

struct WarningStylePicker: View {
    @Binding var selection: WarningMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach([WarningMode.blur, .vignette, .border, .none], id: \.self) { mode in
                Button(action: { selection = mode }) {
                    Text(mode.displayName)
                        .font(.system(size: 11, weight: selection == mode ? .semibold : .regular))
                        .foregroundColor(selection == mode ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selection == mode ? Color.brandCyan : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

extension WarningMode {
    var displayName: String {
        switch self {
        case .blur: return "Blur"
        case .vignette: return "Vignette"
        case .border: return "Border"
        case .none: return "None"
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
        VStack(spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    if let appIcon = NSImage(named: NSImage.applicationIconName) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Posturr")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Gentle posture reminders")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Social links
                    HStack(spacing: 6) {
                        Link(destination: URL(string: "https://github.com/tldev/posturr")!) {
                            GitHubIcon(color: Color.secondary.opacity(0.7))
                                .frame(width: 16, height: 16)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("View on GitHub")

                        Link(destination: URL(string: "https://discord.gg/posturr")!) {
                            DiscordIcon(color: Color.secondary.opacity(0.7))
                                .frame(width: 16, height: 16)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .help("Join Discord")
                    }

                    // Version badge
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("v\(version)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                }
                .padding(.bottom, 8)

                // Two column layout
                HStack(alignment: .top, spacing: 16) {
                    // Left column - Detection
                    VStack(spacing: 12) {
                        SectionCard("Camera", icon: "camera") {
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

                        SectionCard("Warning", icon: "eye") {
                            VStack(alignment: .leading, spacing: 14) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 4) {
                                        Text("Style")
                                            .font(.system(size: 13))

                                        HelpButton(text: "How Posturr alerts you when slouching. Blur obscures the screen, Vignette shows a glow from the edges, Border shows colored borders. None disables visual warnings.")
                                    }

                                    WarningStylePicker(selection: $warningMode)
                                        .onChange(of: warningMode) { newValue in
                                            if newValue != appDelegate.warningMode {
                                                appDelegate.switchWarningMode(to: newValue)
                                                appDelegate.saveSettings()
                                            }
                                        }
                                }

                                HStack {
                                    Text("Color")
                                        .font(.system(size: 13))
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

                        SectionCard("Sensitivity", icon: "slider.horizontal.3") {
                            VStack(spacing: 14) {
                                LabeledSlider(
                                    title: "Dead Zone",
                                    helpText: "How much you can move before warning starts. A relaxed dead zone allows more natural movement.",
                                    value: $deadZoneSlider,
                                    range: 0...4,
                                    step: 1,
                                    leftLabel: "Strict",
                                    rightLabel: "Loose",
                                    valueLabel: deadZoneLabels[Int(deadZoneSlider)]
                                )
                                .onChange(of: deadZoneSlider) { newValue in
                                    let index = Int(newValue)
                                    deadZone = deadZoneValues[index]
                                    appDelegate.deadZone = deadZone
                                    appDelegate.saveSettings()
                                }

                                SubtleDivider()

                                LabeledSlider(
                                    title: "Intensity",
                                    helpText: "How quickly the warning increases as you slouch past the dead zone.",
                                    value: $intensitySlider,
                                    range: 0...4,
                                    step: 1,
                                    leftLabel: "Gentle",
                                    rightLabel: "Aggressive",
                                    valueLabel: intensityLabels[Int(intensitySlider)]
                                )
                                .onChange(of: intensitySlider) { newValue in
                                    let index = Int(newValue)
                                    intensity = intensityValues[index]
                                    appDelegate.intensity = intensity
                                    appDelegate.saveSettings()
                                }

                                SubtleDivider()

                                LabeledSlider(
                                    title: "Delay",
                                    helpText: "Grace period before warning activates. Allows brief glances at keyboard without triggering.",
                                    value: $warningOnsetDelay,
                                    range: 0...30,
                                    step: 1,
                                    leftLabel: "0s",
                                    rightLabel: "30s",
                                    valueLabel: "\(Int(warningOnsetDelay))s"
                                )
                                .onChange(of: warningOnsetDelay) { newValue in
                                    appDelegate.warningOnsetDelay = newValue
                                    appDelegate.saveSettings()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Right column - Behavior
                    VStack(spacing: 12) {
                        SectionCard("Behavior", icon: "gearshape") {
                            VStack(spacing: 12) {
                                SettingRow(
                                    title: "Launch at login",
                                    helpText: "Automatically start Posturr when you log in to your Mac",
                                    isOn: $launchAtLogin
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
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    }
                                }

                                SubtleDivider()

                                SettingRow(
                                    title: "Show in dock",
                                    helpText: "Keep Posturr visible in the Dock and Cmd+Tab switcher",
                                    isOn: $showInDock
                                )
                                .onChange(of: showInDock) { newValue in
                                    appDelegate.showInDock = newValue
                                    appDelegate.saveSettings()
                                    NSApp.setActivationPolicy(newValue ? .regular : .accessory)
                                    DispatchQueue.main.async {
                                        appDelegate.settingsWindowController.window?.makeKeyAndOrderFront(nil)
                                        NSApp.activate(ignoringOtherApps: true)
                                    }
                                }

                                SubtleDivider()

                                SettingRow(
                                    title: "Blur when away",
                                    helpText: "Apply full blur when you step away from the screen",
                                    isOn: $blurWhenAway
                                )
                                .onChange(of: blurWhenAway) { newValue in
                                    appDelegate.blurWhenAway = newValue
                                    appDelegate.saveSettings()
                                    if !newValue {
                                        appDelegate.consecutiveNoDetectionFrames = 0
                                    }
                                }

                                SubtleDivider()

                                SettingRow(
                                    title: "Pause on the go",
                                    helpText: "Auto-pause when laptop display becomes the only screen",
                                    isOn: $pauseOnTheGo
                                )
                                .onChange(of: pauseOnTheGo) { newValue in
                                    appDelegate.pauseOnTheGo = newValue
                                    appDelegate.saveSettings()
                                    if !newValue && appDelegate.state == .paused(.onTheGo) {
                                        appDelegate.state = .monitoring
                                    }
                                }
                            }
                        }

                        #if !APP_STORE
                        SectionCard("Advanced", icon: "wrench.and.screwdriver") {
                            SettingRow(
                                title: "Compatibility mode",
                                helpText: "Enable if blur isn't appearing. Uses alternative rendering method.",
                                isOn: $useCompatibilityMode
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

                        // Recalibrate action
                        Button(action: {
                            appDelegate.startCalibration()
                        }) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Recalibrate Posture")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.brandCyan)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.brandCyan.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.brandCyan.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }

            }
        .padding(24)
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Social Icons (Official SVG paths from Simple Icons)

struct GitHubIcon: View {
    var color: Color = .secondary

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let scale = min(geometry.size.width, geometry.size.height) / 24

                // Official GitHub Octocat path
                path.move(to: CGPoint(x: 12 * scale, y: 0.297 * scale))
                path.addCurve(to: CGPoint(x: 0 * scale, y: 12.297 * scale),
                              control1: CGPoint(x: 5.37 * scale, y: 0.297 * scale),
                              control2: CGPoint(x: 0 * scale, y: 5.67 * scale))
                path.addCurve(to: CGPoint(x: 8.205 * scale, y: 23.682 * scale),
                              control1: CGPoint(x: 0 * scale, y: 17.6 * scale),
                              control2: CGPoint(x: 3.438 * scale, y: 22.097 * scale))
                path.addCurve(to: CGPoint(x: 9.025 * scale, y: 23.105 * scale),
                              control1: CGPoint(x: 8.805 * scale, y: 23.795 * scale),
                              control2: CGPoint(x: 9.025 * scale, y: 23.424 * scale))
                path.addCurve(to: CGPoint(x: 9.01 * scale, y: 21.065 * scale),
                              control1: CGPoint(x: 9.025 * scale, y: 22.82 * scale),
                              control2: CGPoint(x: 9.01 * scale, y: 22.145 * scale))
                path.addCurve(to: CGPoint(x: 4.968 * scale, y: 19.455 * scale),
                              control1: CGPoint(x: 5.672 * scale, y: 21.789 * scale),
                              control2: CGPoint(x: 4.968 * scale, y: 19.455 * scale))
                path.addCurve(to: CGPoint(x: 3.633 * scale, y: 17.7 * scale),
                              control1: CGPoint(x: 4.422 * scale, y: 18.07 * scale),
                              control2: CGPoint(x: 3.633 * scale, y: 17.7 * scale))
                path.addCurve(to: CGPoint(x: 3.717 * scale, y: 16.971 * scale),
                              control1: CGPoint(x: 2.546 * scale, y: 16.956 * scale),
                              control2: CGPoint(x: 3.717 * scale, y: 16.971 * scale))
                path.addCurve(to: CGPoint(x: 5.555 * scale, y: 18.207 * scale),
                              control1: CGPoint(x: 4.922 * scale, y: 17.055 * scale),
                              control2: CGPoint(x: 5.555 * scale, y: 18.207 * scale))
                path.addCurve(to: CGPoint(x: 9.05 * scale, y: 19.205 * scale),
                              control1: CGPoint(x: 6.625 * scale, y: 20.042 * scale),
                              control2: CGPoint(x: 8.364 * scale, y: 19.512 * scale))
                path.addCurve(to: CGPoint(x: 9.81 * scale, y: 17.6 * scale),
                              control1: CGPoint(x: 9.158 * scale, y: 18.429 * scale),
                              control2: CGPoint(x: 9.467 * scale, y: 17.9 * scale))
                path.addCurve(to: CGPoint(x: 4.344 * scale, y: 11.67 * scale),
                              control1: CGPoint(x: 7.145 * scale, y: 17.3 * scale),
                              control2: CGPoint(x: 4.344 * scale, y: 16.332 * scale))
                path.addCurve(to: CGPoint(x: 5.579 * scale, y: 8.45 * scale),
                              control1: CGPoint(x: 4.344 * scale, y: 10.36 * scale),
                              control2: CGPoint(x: 4.809 * scale, y: 9.14 * scale))
                path.addCurve(to: CGPoint(x: 5.684 * scale, y: 5.274 * scale),
                              control1: CGPoint(x: 5.444 * scale, y: 8.147 * scale),
                              control2: CGPoint(x: 5.039 * scale, y: 6.797 * scale))
                path.addCurve(to: CGPoint(x: 8.984 * scale, y: 6.504 * scale),
                              control1: CGPoint(x: 5.684 * scale, y: 5.274 * scale),
                              control2: CGPoint(x: 6.689 * scale, y: 4.952 * scale))
                path.addCurve(to: CGPoint(x: 12 * scale, y: 6.099 * scale),
                              control1: CGPoint(x: 9.944 * scale, y: 6.237 * scale),
                              control2: CGPoint(x: 10.964 * scale, y: 6.093 * scale))
                path.addCurve(to: CGPoint(x: 15 * scale, y: 6.504 * scale),
                              control1: CGPoint(x: 13.02 * scale, y: 6.105 * scale),
                              control2: CGPoint(x: 14.04 * scale, y: 6.237 * scale))
                path.addCurve(to: CGPoint(x: 18.285 * scale, y: 5.274 * scale),
                              control1: CGPoint(x: 17.28 * scale, y: 4.952 * scale),
                              control2: CGPoint(x: 18.285 * scale, y: 5.274 * scale))
                path.addCurve(to: CGPoint(x: 18.405 * scale, y: 8.45 * scale),
                              control1: CGPoint(x: 18.93 * scale, y: 6.927 * scale),
                              control2: CGPoint(x: 18.645 * scale, y: 8.147 * scale))
                path.addCurve(to: CGPoint(x: 19.635 * scale, y: 11.67 * scale),
                              control1: CGPoint(x: 19.17 * scale, y: 9.29 * scale),
                              control2: CGPoint(x: 19.635 * scale, y: 10.36 * scale))
                path.addCurve(to: CGPoint(x: 14.16 * scale, y: 17.59 * scale),
                              control1: CGPoint(x: 19.635 * scale, y: 16.28 * scale),
                              control2: CGPoint(x: 16.83 * scale, y: 17.29 * scale))
                path.addCurve(to: CGPoint(x: 14.97 * scale, y: 19.81 * scale),
                              control1: CGPoint(x: 14.58 * scale, y: 17.95 * scale),
                              control2: CGPoint(x: 14.97 * scale, y: 18.706 * scale))
                path.addCurve(to: CGPoint(x: 14.955 * scale, y: 23.096 * scale),
                              control1: CGPoint(x: 14.97 * scale, y: 21.416 * scale),
                              control2: CGPoint(x: 14.955 * scale, y: 23.096 * scale))
                path.addCurve(to: CGPoint(x: 15.78 * scale, y: 23.67 * scale),
                              control1: CGPoint(x: 14.955 * scale, y: 23.406 * scale),
                              control2: CGPoint(x: 15.165 * scale, y: 23.783 * scale))
                path.addCurve(to: CGPoint(x: 24 * scale, y: 12.297 * scale),
                              control1: CGPoint(x: 20.565 * scale, y: 22.092 * scale),
                              control2: CGPoint(x: 24 * scale, y: 17.592 * scale))
                path.addCurve(to: CGPoint(x: 12 * scale, y: 0.297 * scale),
                              control1: CGPoint(x: 24 * scale, y: 5.67 * scale),
                              control2: CGPoint(x: 18.63 * scale, y: 0.297 * scale))
                path.closeSubpath()
            }
            .fill(color)
        }
    }
}

struct DiscordIcon: View {
    var color: Color = .secondary

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let scale = min(geometry.size.width, geometry.size.height) / 24

                // Official Discord path
                path.move(to: CGPoint(x: 20.317 * scale, y: 4.3698 * scale))
                path.addCurve(to: CGPoint(x: 15.432 * scale, y: 2.8546 * scale),
                              control1: CGPoint(x: 18.7873 * scale, y: 3.6588 * scale),
                              control2: CGPoint(x: 17.1461 * scale, y: 3.1346 * scale))
                path.addCurve(to: CGPoint(x: 14.8237 * scale, y: 4.1041 * scale),
                              control1: CGPoint(x: 15.3535 * scale, y: 2.8917 * scale),
                              control2: CGPoint(x: 15.0347 * scale, y: 3.4793 * scale))
                path.addCurve(to: CGPoint(x: 9.3369 * scale, y: 4.1041 * scale),
                              control1: CGPoint(x: 12.979 * scale, y: 3.8279 * scale),
                              control2: CGPoint(x: 11.1437 * scale, y: 3.8279 * scale))
                path.addCurve(to: CGPoint(x: 8.7192 * scale, y: 2.8546 * scale),
                              control1: CGPoint(x: 9.1269 * scale, y: 3.4793 * scale),
                              control2: CGPoint(x: 8.7963 * scale, y: 2.8917 * scale))
                path.addCurve(to: CGPoint(x: 3.8341 * scale, y: 4.3698 * scale),
                              control1: CGPoint(x: 7.0042 * scale, y: 3.1346 * scale),
                              control2: CGPoint(x: 5.3643 * scale, y: 3.6588 * scale))
                path.addCurve(to: CGPoint(x: 0.5524 * scale, y: 18.0578 * scale),
                              control1: CGPoint(x: 0.5524 * scale, y: 9.0458 * scale),
                              control2: CGPoint(x: -0.3811 * scale, y: 13.5799 * scale))
                path.addCurve(to: CGPoint(x: 6.6052 * scale, y: 21.0872 * scale),
                              control1: CGPoint(x: 2.6052 * scale, y: 19.5654 * scale),
                              control2: CGPoint(x: 4.5939 * scale, y: 20.51 * scale))
                path.addCurve(to: CGPoint(x: 7.8312 * scale, y: 19.093 * scale),
                              control1: CGPoint(x: 7.0668 * scale, y: 20.4568 * scale),
                              control2: CGPoint(x: 7.4862 * scale, y: 19.7878 * scale))
                path.addCurve(to: CGPoint(x: 5.959 * scale, y: 18.2007 * scale),
                              control1: CGPoint(x: 7.179 * scale, y: 18.8454 * scale),
                              control2: CGPoint(x: 6.5569 * scale, y: 18.5483 * scale))
                path.addCurve(to: CGPoint(x: 6.3308 * scale, y: 17.9093 * scale),
                              control1: CGPoint(x: 6.0848 * scale, y: 18.1064 * scale),
                              control2: CGPoint(x: 6.2108 * scale, y: 18.008 * scale))
                path.addCurve(to: CGPoint(x: 12 * scale, y: 19.7026 * scale),
                              control1: CGPoint(x: 8.2586 * scale, y: 19.7026 * scale),
                              control2: CGPoint(x: 10.1508 * scale, y: 19.7026 * scale))
                path.addCurve(to: CGPoint(x: 17.6692 * scale, y: 17.9093 * scale),
                              control1: CGPoint(x: 13.8492 * scale, y: 19.7026 * scale),
                              control2: CGPoint(x: 15.7414 * scale, y: 19.7026 * scale))
                path.addCurve(to: CGPoint(x: 18.041 * scale, y: 18.2007 * scale),
                              control1: CGPoint(x: 17.7892 * scale, y: 18.008 * scale),
                              control2: CGPoint(x: 17.9152 * scale, y: 18.1064 * scale))
                path.addCurve(to: CGPoint(x: 16.1688 * scale, y: 19.093 * scale),
                              control1: CGPoint(x: 17.4431 * scale, y: 18.5483 * scale),
                              control2: CGPoint(x: 16.821 * scale, y: 18.8454 * scale))
                path.addCurve(to: CGPoint(x: 17.3948 * scale, y: 21.0872 * scale),
                              control1: CGPoint(x: 16.5138 * scale, y: 19.7878 * scale),
                              control2: CGPoint(x: 16.9332 * scale, y: 20.4568 * scale))
                path.addCurve(to: CGPoint(x: 23.4476 * scale, y: 18.0578 * scale),
                              control1: CGPoint(x: 19.4061 * scale, y: 20.51 * scale),
                              control2: CGPoint(x: 21.3948 * scale, y: 19.5654 * scale))
                path.addCurve(to: CGPoint(x: 20.317 * scale, y: 4.3698 * scale),
                              control1: CGPoint(x: 24.3811 * scale, y: 13.5799 * scale),
                              control2: CGPoint(x: 23.4476 * scale, y: 9.0458 * scale))
                path.closeSubpath()

                // Left eye
                path.addEllipse(in: CGRect(x: 5.8631 * scale, y: 10.9122 * scale, width: 4.314 * scale, height: 4.838 * scale))

                // Right eye
                path.addEllipse(in: CGRect(x: 13.8369 * scale, y: 10.9122 * scale, width: 4.314 * scale, height: 4.838 * scale))
            }
            .fill(color, style: FillStyle(eoFill: true))
        }
    }
}

// MARK: - Help Button

struct HelpButton: View {
    let text: String
    @State private var showingHelp = false

    var body: some View {
        Button(action: { showingHelp.toggle() }) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingHelp, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 12))
                .padding(12)
                .frame(width: 220)
        }
    }
}
