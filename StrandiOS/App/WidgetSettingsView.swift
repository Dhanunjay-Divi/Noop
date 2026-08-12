#if os(iOS)
import SwiftUI
import WidgetKit
import StrandDesign

/// In-app control for the Daily Signal widget. WidgetKit does not let an app place a widget on the
/// Home Screen, but NOOP can make the content choice clear and update every existing widget immediately.
struct WidgetSettingsView: View {
    @State private var metrics = WidgetMetricPreference.defaultSelection
    @State private var snapshot = WidgetSnapshot.unavailable
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScreenScaffold(
            title: "Widgets",
            subtitle: "Choose what your Daily Signal shows at a glance.",
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                previewSection
                metricSection
                installSection
            }
        }
        .task {
            metrics = WidgetMetricPreference.load()
            refreshSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSnapshot() }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Daily Signal preview")
            NoopCard {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [StrandPalette.glyphFaceTop, StrandPalette.glyphFaceBottom],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                        Text("Daily Signal")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let live = snapshot.isLive(at: context.date)
                            Label(live ? "Live" : "Local", systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(StrandFont.caption)
                                .foregroundStyle(live
                                                 ? StrandPalette.statusPositive
                                                 : StrandPalette.textTertiary)
                        }
                    }

                    HStack(spacing: 8) {
                        previewScore("Recovery", value: snapshot.recovery,
                                     tint: StrandPalette.recoveryColor(Double(snapshot.recovery ?? 50)))
                        previewScore("Effort", value: snapshot.effort, tint: StrandPalette.effortColor)
                        previewScore("Sleep", value: snapshot.rest, tint: StrandPalette.restColor)
                    }

                    Divider().overlay(StrandPalette.hairline)

                    VStack(spacing: 10) {
                        ForEach(metrics, id: \.rawValue) { metric in
                            HStack(spacing: 9) {
                                Image(systemName: metric.symbol(snapshot: snapshot))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(metric.tint)
                                    .frame(width: 18)
                                Text(metric.label)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Spacer()
                                Text(metric.formattedValue(snapshot: snapshot))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(metric.label))
                            .accessibilityValue(Text(metric.formattedValue(snapshot: snapshot)))
                        }
                    }
                }
            }
            Text("Recovery, Effort, and Sleep stay fixed so the summary is always recognizable. A dash means NOOP does not have that reading yet.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Supporting metrics")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                        Menu {
                            ForEach(WidgetMetric.allCases, id: \.rawValue) { candidate in
                                Button {
                                    setMetric(candidate, at: index)
                                } label: {
                                    Label(candidate.label, systemImage: candidate == metric ? "checkmark" : candidate.symbol(snapshot: snapshot))
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: metric.symbol(snapshot: snapshot))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(metric.tint)
                                    .frame(width: 34, height: 34)
                                    .background(metric.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Metric \(index + 1)")
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                    Text(metric.label)
                                        .font(StrandFont.body)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                }
                                Spacer()
                                Text(metric.formattedValue(snapshot: snapshot))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Widget metric \(index + 1)")
                        .accessibilityValue(metric.label)
                        .accessibilityHint("Choose a supporting metric")

                        if index < metrics.count - 1 {
                            Divider().overlay(StrandPalette.hairline).padding(.leading, 62)
                        }
                    }
                }
            }
            Text("Choosing a metric already used in another slot swaps the two, so the widget never repeats the same number.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Add the widget")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    instruction(1, "Touch and hold an empty area of your Home Screen.")
                    instruction(2, "Tap Edit, then Add Widget.")
                    instruction(3, "Search for NOOP and choose Daily Signal.")
                }
            }
            Text("Changes here refresh widgets you already placed. iOS controls the exact refresh time and may briefly show the previous choice.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewScore(_ label: LocalizedStringKey, value: Int?, tint: Color) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(StrandPalette.surfaceInset.opacity(0.82))
                Circle().stroke(StrandPalette.hairline, lineWidth: 4)
                if let value {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, CGFloat(value) / 100)))
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            }
            .frame(width: 64, height: 64)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.map { Text("\($0) out of 100") } ?? Text("Unavailable"))
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.surfaceBase)
                .frame(width: 24, height: 24)
                .background(StrandPalette.textPrimary, in: Circle())
            Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setMetric(_ metric: WidgetMetric, at index: Int) {
        guard metrics.indices.contains(index) else { return }
        var updated = metrics
        if let existing = updated.firstIndex(of: metric), existing != index {
            updated.swapAt(index, existing)
        } else {
            updated[index] = metric
        }
        metrics = WidgetMetricPreference.normalized(updated.map(\.rawValue))
        WidgetMetricPreference.save(metrics)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func refreshSnapshot() {
        #if DEBUG
        let demoFallback: WidgetSnapshot = CommandLine.arguments.contains("--demo-seed")
            ? .placeholder : .unavailable
        #else
        let demoFallback: WidgetSnapshot = .unavailable
        #endif
        snapshot = WidgetSnapshot.load() ?? demoFallback
    }
}

private extension WidgetMetric {
    var label: LocalizedStringKey {
        switch self {
        case .heartRate: return "Heart rate"
        case .hrv: return "HRV"
        case .restingHeartRate: return "Resting heart rate"
        case .sleepDuration: return "Sleep duration"
        case .deviceBattery: return "Device battery"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate, .restingHeartRate: return StrandPalette.statusCritical
        case .hrv, .deviceBattery: return StrandPalette.chargeColor
        case .sleepDuration: return StrandPalette.restColor
        }
    }

    func symbol(snapshot: WidgetSnapshot) -> String {
        switch self {
        case .heartRate, .restingHeartRate: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleepDuration: return "bed.double.fill"
        case .deviceBattery:
            guard let battery = snapshot.batteryPct else { return "battery.0percent" }
            if battery < 25 { return "battery.25percent" }
            if battery < 50 { return "battery.50percent" }
            if battery < 75 { return "battery.75percent" }
            return "battery.100percent"
        }
    }

    func formattedValue(snapshot: WidgetSnapshot) -> String {
        switch self {
        case .heartRate: return snapshot.bpm.map { "\($0) bpm" } ?? "–"
        case .hrv: return snapshot.hrv.map { "\($0) ms" } ?? "–"
        case .restingHeartRate: return snapshot.restingHr.map { "\($0) bpm" } ?? "–"
        case .sleepDuration:
            guard let minutes = snapshot.sleepMinutes, minutes > 0 else { return "–" }
            let hours = minutes / 60
            let remainder = minutes % 60
            if hours == 0 { return "\(remainder)m" }
            if remainder == 0 { return "\(hours)h" }
            return "\(hours)h \(remainder)m"
        case .deviceBattery: return snapshot.batteryPct.map { "\($0)%" } ?? "–"
        }
    }
}

private extension WidgetSnapshot {
    /// A saved connection bit is only a point-in-time observation. Once the snapshot ages out, the
    /// preview must fall back to Local instead of implying that a killed/disconnected app is still live.
    func isLive(at date: Date) -> Bool { connected == true && freshness(at: date) == .current }
}
#endif
