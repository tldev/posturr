import SwiftUI
import Charts
import AppKit

// MARK: - Window Controller

@MainActor
class AnalyticsWindowController: NSWindowController {
    convenience init() {
        let hostingController = NSHostingController(rootView: AnalyticsView())
        let fittingSize = hostingController.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("analytics.title")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.center()

        self.init(window: window)
    }
}

// MARK: - SwiftUI Views

struct AnalyticsView: View {
    @ObservedObject var manager = AnalyticsManager.shared

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
                    Text(L("analytics.header"))
                        .font(.system(size: 22, weight: .semibold))
                    Text(L("analytics.tagline"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Today's Score Card
                HStack(spacing: 12) {
                    ScoreRing(score: manager.todayStats.postureScore)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("analytics.todayScore"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(formatPercent(manager.todayStats.postureScore))
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(scoreColor(manager.todayStats.postureScore))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .padding(.bottom, 8)

            // Main Content Grid
            HStack(alignment: .top, spacing: 16) {
                // Left Col: Stats
                VStack(spacing: 12) {
                    AnalyticsStatCard(
                        title: L("analytics.monitoringTime"),
                        value: formatDuration(manager.todayStats.totalSeconds),
                        icon: "clock",
                        color: .brandCyan
                    )

                    AnalyticsStatCard(
                        title: L("analytics.slouchDuration"),
                        value: formatDuration(manager.todayStats.slouchSeconds),
                        icon: "figure.fall",
                        color: .orange
                    )

                    AnalyticsStatCard(
                        title: L("analytics.slouchEvents"),
                        value: "\(manager.todayStats.slouchCount)",
                        icon: "exclamationmark.circle",
                        color: .red
                    )
                }
                .frame(width: 180)

                // Right Col: Charts
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.brandCyan)
                        Text(L("analytics.last7Days"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    let history = manager.getLast7Days()

                    Chart(history) { day in
                        if day.totalSeconds > 0 {
                            BarMark(
                                x: .value("Date", day.date, unit: .day),
                                y: .value("Score", day.postureScore)
                            )
                            .foregroundStyle(scoreColor(day.postureScore))
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                Text(String(format: "%.0f", day.postureScore))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            BarMark(
                                x: .value("Date", day.date, unit: .day),
                                y: .value("Score", 0)
                            )
                            .opacity(0)
                        }
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    }
                    .frame(minHeight: 180)
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
        .padding(24)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
    
    func scoreColor(_ score: Double) -> Color {
        if score >= 85 { return .brandCyan }
        if score >= 70 { return .yellow }
        return .orange
    }
    
    private static let hourMinuteFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute]
        return f
    }()

    private static let minuteSecondFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.minute, .second]
        return f
    }()

    private static let secondFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.second]
        return f
    }()

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        f.minimumFractionDigits = 0
        f.locale = Locale.autoupdatingCurrent
        return f
    }()

    private func formatPercent(_ score: Double) -> String {
        Self.percentFormatter.string(from: NSNumber(value: score / 100)) ?? "\(Int(round(score)))%"
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter: DateComponentsFormatter
        if seconds >= 3600 {
            formatter = Self.hourMinuteFormatter
        } else if seconds >= 60 {
            formatter = Self.minuteSecondFormatter
        } else {
            formatter = Self.secondFormatter
        }
        return formatter.string(from: seconds) ?? Self.secondFormatter.string(from: 0) ?? "0"
    }
}

struct AnalyticsStatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .brandCyan

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
            }
            Spacer()
        }
        .padding(12)
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

struct ScoreRing: View {
    let score: Double

    private var ringColor: Color {
        if score >= 85 { return .brandCyan }
        if score >= 70 { return .yellow }
        return .orange
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 6)

            Circle()
                .trim(from: 0, to: score / 100.0)
                .stroke(
                    ringColor,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: score)
        }
    }
}
