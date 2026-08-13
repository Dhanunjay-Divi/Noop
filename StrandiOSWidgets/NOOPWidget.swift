import WidgetKit
import SwiftUI
import StrandDesign

/// Timeline entry backed by the latest tiny snapshot the app publishes into its private App Group.
struct NOOPEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let supportingMetrics: [WidgetMetric]

    init(date: Date, snapshot: WidgetSnapshot,
         supportingMetrics: [WidgetMetric] = WidgetMetricPreference.defaultSelection) {
        self.date = date
        self.snapshot = snapshot
        self.supportingMetrics = WidgetMetricPreference.normalized(supportingMetrics.map(\.rawValue))
    }
}

struct NOOPProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPEntry {
        NOOPEntry(date: Date(), snapshot: .placeholder,
                  supportingMetrics: WidgetMetricPreference.defaultSelection)
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPEntry) -> Void) {
        let fallback: WidgetSnapshot = context.isPreview ? .placeholder : .unavailable
        completion(NOOPEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? fallback,
                             supportingMetrics: WidgetMetricPreference.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load() ?? .unavailable
        // WidgetKit controls the final cadence. The app also explicitly reloads after meaningful data
        // changes, while high-frequency HR publishes are throttled before they reach the extension.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        let now = Date()
        let metrics = WidgetMetricPreference.load()
        var entries = [NOOPEntry(date: now, snapshot: snapshot, supportingMetrics: metrics)]
        // WidgetKit can defer the requested reload, so schedule semantic state transitions into this
        // timeline. Live HR expires from the REAL packet receipt (two minutes), while connection remains
        // a distinct, coarser observation that retains the existing 20-minute expiry.
        var expiries: [Date] = []
        if snapshot.hasLiveHeartRate(at: now), let liveUntil = snapshot.liveHeartRateExpiresAt {
            expiries.append(liveUntil.addingTimeInterval(1))
        }
        let connectionExpiry = snapshot.updated.addingTimeInterval(20 * 60 + 1)
        if snapshot.hasCurrentConnection(at: now), connectionExpiry > now {
            expiries.append(connectionExpiry)
        }
        for expiry in expiries.filter({ $0 > now }).sorted() {
            guard entries.last?.date != expiry else { continue }
            entries.append(NOOPEntry(date: expiry, snapshot: snapshot,
                                     supportingMetrics: metrics))
        }
        completion(Timeline(entries: entries,
                            policy: .after(next)))
    }
}

// MARK: - Daily Signal

/// The original kind string is intentionally retained so already-placed widgets upgrade in place.
struct NOOPDailyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            WidgetScoreGauge(value: snapshot.recovery, symbol: "bolt.heart.fill", tint: chargeTint)
        case .accessoryInline:
            Text(dailyInlineText)
        case .accessoryRectangular:
            DailyAccessoryRectangular(snapshot: snapshot)
        case .systemSmall:
            small
        case .systemMedium:
            medium
        case .systemLarge:
            large
        default:
            small
        }
    }

    private var chargeTint: Color { scoreTint(snapshot.recovery, fallback: StrandPalette.chargeColor) }
    private var effortTint: Color {
        guard let value = snapshot.effort else { return StrandPalette.effortColor }
        return StrandPalette.effortTint(fraction: Double(value) / 100)
    }
    private var restTint: Color { snapshot.rest == nil ? StrandPalette.textTertiary : StrandPalette.restColor }

    private var dailyInlineText: String {
        guard snapshot.hasDailySignal else { return String(localized: "NOOP · Open for your Daily Signal") }
        return "R \(value(snapshot.recovery)) · E \(value(snapshot.effort)) · S \(value(snapshot.rest))"
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Daily Signal", symbol: "waveform.path.ecg",
                         snapshot: snapshot, now: entry.date)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                WidgetScoreRing(label: "Recovery", value: snapshot.recovery, tint: chargeTint, diameter: 38)
                WidgetScoreRing(label: "Effort", value: snapshot.effort, tint: effortTint, diameter: 38)
                WidgetScoreRing(label: "Sleep", value: snapshot.rest, tint: restTint, diameter: 38)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            ScoreDayLabel(snapshot: snapshot, compact: true)
        }
        .padding(12)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 9) {
            WidgetHeader(title: "Daily Signal", symbol: "waveform.path.ecg",
                         snapshot: snapshot, now: entry.date)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    WidgetScoreRing(label: "Recovery", value: snapshot.recovery, tint: chargeTint, diameter: 50)
                    WidgetScoreRing(label: "Effort", value: snapshot.effort, tint: effortTint, diameter: 50)
                    WidgetScoreRing(label: "Sleep", value: snapshot.rest, tint: restTint, diameter: 50)
                }
                Divider().overlay(StrandPalette.hairline)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(entry.supportingMetrics, id: \.rawValue) { metric in
                        SupportingMetricLine(metric: metric, snapshot: snapshot)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                ScoreDayLabel(snapshot: snapshot, compact: true)
                Spacer()
                SnapshotFreshnessLabel(snapshot: snapshot, now: entry.date, compact: true)
            }
        }
        .padding(13)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Daily Signal", symbol: "waveform.path.ecg",
                         snapshot: snapshot, now: entry.date)

            HStack(spacing: 16) {
                WidgetScoreRing(label: "Recovery", value: snapshot.recovery, tint: chargeTint, diameter: 72)
                WidgetScoreRing(label: "Effort", value: snapshot.effort, tint: effortTint, diameter: 72)
                WidgetScoreRing(label: "Sleep", value: snapshot.rest, tint: restTint, diameter: 72)
            }
            .frame(maxWidth: .infinity)

            DailyGuidance(snapshot: snapshot)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(entry.supportingMetrics, id: \.rawValue) { metric in
                    SupportingMetricCard(metric: metric, snapshot: snapshot)
                }
                WidgetMetricCard(symbol: connectionSymbol(snapshot, at: entry.date), label: "Wearable",
                                 value: connectionLabel(snapshot, at: entry.date),
                                 tint: connectionColor(snapshot, at: entry.date))
            }

            HStack {
                ScoreDayLabel(snapshot: snapshot, compact: false)
                Spacer()
                SnapshotFreshnessLabel(snapshot: snapshot, now: entry.date, compact: false)
            }
        }
        .padding(16)
    }
}

// MARK: - Vitals

struct NOOPVitalsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "heart.fill").font(.caption2)
                Text(value(snapshot.bpm)).font(.system(.headline, design: .rounded, weight: .bold))
            }
            .widgetAccentable()
        case .accessoryInline:
            Text("HR \(value(snapshot.bpm)) · HRV \(value(snapshot.hrv)) · RHR \(value(snapshot.restingHr))")
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Vitals", symbol: "heart.text.square.fill",
                         snapshot: snapshot, now: entry.date)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value(snapshot.bpm))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(snapshot.bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text(snapshot.bpm == nil ? "" : "bpm")
                    .font(.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Text(isLive(snapshot, at: entry.date) ? "Live heart rate" : "Last heart rate")
                .font(.caption2.weight(.medium)).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                CompactMetric(label: "HRV", value: unitValue(snapshot.hrv, "ms"))
                CompactMetric(label: "RHR", value: unitValue(snapshot.restingHr, "bpm"))
            }
            SnapshotFreshnessLabel(snapshot: snapshot, now: entry.date, compact: true,
                                   tracksHeartRate: true)
        }
        .padding(10)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 9) {
            WidgetHeader(title: "Vitals", symbol: "heart.text.square.fill",
                         snapshot: snapshot, now: entry.date)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value(snapshot.bpm))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(snapshot.bpm == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                        if snapshot.bpm != nil {
                            Text("bpm").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Label(isLive(snapshot, at: entry.date) ? "Live now" : "Last reading",
                          systemImage: isLive(snapshot, at: entry.date) ? "dot.radiowaves.left.and.right" : "clock")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(isLive(snapshot, at: entry.date) ? StrandPalette.chargeColor : StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    WidgetMetricLine(symbol: "waveform.path.ecg", label: "HRV",
                                     value: unitValue(snapshot.hrv, "ms"), tint: StrandPalette.chargeColor)
                    WidgetMetricLine(symbol: "heart.fill", label: "Resting HR",
                                     value: unitValue(snapshot.restingHr, "bpm"), tint: StrandPalette.statusCritical)
                    WidgetMetricLine(symbol: batterySymbol(snapshot.batteryPct), label: "Device",
                                     value: percent(snapshot.batteryPct), tint: StrandPalette.chargeColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            SnapshotFreshnessLabel(snapshot: snapshot, now: entry.date, compact: false,
                                   tracksHeartRate: true)
        }
        .padding(13)
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Heart rate", systemImage: "heart.fill")
                Spacer()
                Text(unitValue(snapshot.bpm, "bpm")).fontWeight(.semibold)
            }
            HStack {
                Text("HRV \(unitValue(snapshot.hrv, "ms"))")
                Spacer()
                Text("RHR \(unitValue(snapshot.restingHr, "bpm"))")
            }
            .font(.caption2)
        }
        .widgetAccentable()
    }
}

// MARK: - Sleep

struct NOOPSleepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var restTint: Color { snapshot.rest == nil ? StrandPalette.textTertiary : StrandPalette.restColor }

    var body: some View {
        switch family {
        case .accessoryCircular:
            WidgetScoreGauge(value: snapshot.rest, symbol: "moon.zzz.fill", tint: restTint)
        case .accessoryInline:
            Text("Sleep \(value(snapshot.rest)) · \(sleepDuration(snapshot.sleepMinutes))")
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetHeader(title: "Sleep", symbol: "moon.zzz.fill",
                         snapshot: snapshot, now: entry.date)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                WidgetScoreRing(label: "Sleep", value: snapshot.rest, tint: restTint, diameter: 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text(sleepDuration(snapshot.sleepMinutes))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("sleep duration")
                        .font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                    Text("RHR \(unitValue(snapshot.restingHr, "bpm"))")
                        .font(.caption2.weight(.medium)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            ScoreDayLabel(snapshot: snapshot, compact: true)
        }
        .padding(10)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(title: "Sleep", symbol: "moon.zzz.fill",
                         snapshot: snapshot, now: entry.date)
            HStack(spacing: 16) {
                WidgetScoreRing(label: "Sleep", value: snapshot.rest, tint: restTint, diameter: 68)
                VStack(alignment: .leading, spacing: 9) {
                    WidgetMetricLine(symbol: "clock.fill", label: "Duration",
                                     value: sleepDuration(snapshot.sleepMinutes), tint: StrandPalette.restColor)
                    WidgetMetricLine(symbol: "waveform.path.ecg", label: "HRV",
                                     value: unitValue(snapshot.hrv, "ms"), tint: StrandPalette.chargeColor)
                    WidgetMetricLine(symbol: "heart.fill", label: "Resting HR",
                                     value: unitValue(snapshot.restingHr, "bpm"), tint: StrandPalette.statusCritical)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            ScoreDayLabel(snapshot: snapshot, compact: false)
        }
        .padding(12)
    }

    private var accessoryRectangular: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("Sleep \(value(snapshot.rest))").font(.headline)
                Text("Sleep \(sleepDuration(snapshot.sleepMinutes)) · HRV \(unitValue(snapshot.hrv, "ms"))")
                    .font(.caption2)
            }
        }
        .widgetAccentable()
    }
}

// MARK: - Shared visual language

private struct WidgetHeader: View {
    let title: LocalizedStringKey
    let symbol: String
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [StrandPalette.glyphFaceTop, StrandPalette.glyphFaceBottom],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(StrandPalette.bevelTop.opacity(0.35), lineWidth: 0.5)
                    }
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(StrandPalette.glyphInkBottom)
            }
            .frame(width: 23, height: 23)

            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Circle()
                    .fill(connectionTint)
                    .frame(width: 6, height: 6)
                Text(connectionText)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var connectionText: LocalizedStringKey {
        if isLive(snapshot, at: now) { return "Live" }
        if snapshot.hasCurrentConnection(at: now) { return "Connected" }
        if snapshot.bonded { return "Paired" }
        if snapshot.hasDailySignal || snapshot.hasVitals { return "Local data" }
        return "No device"
    }

    private var connectionTint: Color {
        if isLive(snapshot, at: now) { return StrandPalette.statusPositive }
        if snapshot.hasCurrentConnection(at: now) { return StrandPalette.statusPositive }
        if snapshot.bonded { return StrandPalette.statusWarning }
        return StrandPalette.textTertiary
    }
}

private struct WidgetScoreRing: View {
    let label: LocalizedStringKey
    let value: Int?
    let tint: Color
    let diameter: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(StrandPalette.surfaceInset.opacity(0.78))
                Circle()
                    .stroke(StrandPalette.hairline.opacity(0.7), lineWidth: max(3, diameter * 0.075))
                if let value {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, CGFloat(value) / 100)))
                        .stroke(tint, style: StrokeStyle(lineWidth: max(3, diameter * 0.075), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: tint.opacity(0.28), radius: 3)
                }
                Text(value.map(String.init) ?? "–")
                    .font(.system(size: diameter * 0.31, weight: .bold, design: .rounded))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: diameter, height: diameter)
            Text(label)
                .font(.system(size: max(8, diameter * 0.13), weight: .bold, design: .rounded))
                .foregroundStyle(StrandPalette.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.map { Text("\($0) out of 100") } ?? Text("Unavailable"))
    }
}

private struct WidgetScoreGauge: View {
    let value: Int?
    let symbol: String
    let tint: Color

    var body: some View {
        Gauge(value: Double(value ?? 0), in: 0...100) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(value.map(String.init) ?? "–")
                .fontWeight(.bold)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
        .widgetAccentable()
    }
}

private struct DailyAccessoryRectangular: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Daily Signal", systemImage: "waveform.path.ecg")
                Spacer()
                Text(scoreDayShort(snapshot.scoreDay)).font(.caption2)
            }
            HStack(spacing: 10) {
                accessoryScore("R", snapshot.recovery)
                accessoryScore("E", snapshot.effort)
                accessoryScore("S", snapshot.rest)
            }
        }
        .widgetAccentable()
    }

    private func accessoryScore(_ label: String, _ score: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(label).font(.caption2)
            Text(value(score)).font(.headline)
        }
    }
}

/// One user-selected supporting measurement. Keeping the mapping in the widget extension means the
/// persisted preference is only a stable semantic identifier — never formatted text, units, or colour.
private struct SupportingMetricLine: View {
    let metric: WidgetMetric
    let snapshot: WidgetSnapshot

    var body: some View {
        WidgetMetricLine(symbol: supportingMetricSymbol(metric, snapshot: snapshot),
                         label: supportingMetricLabel(metric),
                         value: supportingMetricValue(metric, snapshot: snapshot),
                         tint: supportingMetricTint(metric))
    }
}

private struct SupportingMetricCard: View {
    let metric: WidgetMetric
    let snapshot: WidgetSnapshot

    var body: some View {
        WidgetMetricCard(symbol: supportingMetricSymbol(metric, snapshot: snapshot),
                         label: supportingMetricLabel(metric),
                         value: supportingMetricValue(metric, snapshot: snapshot),
                         tint: supportingMetricTint(metric))
    }
}

private struct WidgetMetricLine: View {
    let symbol: String
    let label: LocalizedStringKey
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
            Text(label)
                .font(.caption2)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value == "–" ? String(localized: "Unavailable") : value))
    }
}

private struct WidgetMetricCard: View {
    let symbol: String
    let label: LocalizedStringKey
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(StrandPalette.surfaceRaised.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(StrandPalette.hairline.opacity(0.65), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}

private struct CompactMetric: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(.system(size: 10, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ScoreDayLabel: View {
    let snapshot: WidgetSnapshot
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
            Text(scoreDayDescription(snapshot.scoreDay))
                .lineLimit(1)
        }
        .font(.system(size: compact ? 8 : 10, weight: .medium, design: .rounded))
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

private struct SnapshotFreshnessLabel: View {
    let snapshot: WidgetSnapshot
    let now: Date
    let compact: Bool
    var tracksHeartRate = false

    private var displayedFreshness: WidgetSnapshot.Freshness {
        tracksHeartRate ? snapshot.heartRateFreshness(at: now) : snapshot.freshness(at: now)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: freshnessSymbol)
            switch displayedFreshness {
            case .unavailable:
                Text(tracksHeartRate ? "No HR sample" : "Open NOOP")
            case .current:
                Text(tracksHeartRate ? "HR now" : "Refreshed now")
            case .recent, .stale:
                if tracksHeartRate, let observed = snapshot.heartRateObservedAt {
                    Text("HR")
                    Text(observed, style: .relative)
                } else {
                    Text(snapshot.updated, style: .relative)
                }
            }
        }
        .font(.system(size: compact ? 8 : 10, weight: .medium, design: .rounded))
        .foregroundStyle(freshnessTint)
        .lineLimit(1)
    }

    private var freshnessSymbol: String {
        switch displayedFreshness {
        case .current: return "checkmark.circle.fill"
        case .recent: return "clock.fill"
        case .stale: return "exclamationmark.circle.fill"
        case .unavailable: return "arrow.up.forward.app"
        }
    }

    private var freshnessTint: Color {
        switch displayedFreshness {
        case .current: return StrandPalette.statusPositive
        case .recent: return StrandPalette.textTertiary
        case .stale: return StrandPalette.statusWarning
        case .unavailable: return StrandPalette.textTertiary
        }
    }
}

private struct DailyGuidance: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .bold, design: .rounded))
                Text(detail).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(StrandPalette.surfaceRaised.opacity(0.74), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StrandPalette.hairline.opacity(0.65), lineWidth: 0.5)
        }
    }

    private var title: LocalizedStringKey {
        guard let charge = snapshot.recovery else { return "Building your baseline" }
        if charge >= 67 { return "Capacity looks strong" }
        if charge >= 34 { return "Keep today balanced" }
        return "Prioritize recovery"
    }

    private var detail: LocalizedStringKey {
        guard snapshot.recovery != nil else { return "Wear your device consistently to unlock scores." }
        return "Open NOOP for context, trends, and confidence."
    }

    private var symbol: String {
        guard let charge = snapshot.recovery else { return "circle.dotted" }
        return charge >= 67 ? "sparkles" : charge >= 34 ? "equal.circle.fill" : "moon.zzz.fill"
    }

    private var tint: Color {
        scoreTint(snapshot.recovery, fallback: StrandPalette.chargeColor)
    }
}

private struct NOOPWidgetCanvas: View {
    let accent: Color

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase
            LinearGradient(
                colors: [StrandPalette.surfaceRaised.opacity(0.92), StrandPalette.surfaceInset.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 180, height: 180)
                .blur(radius: 32)
                .offset(x: -88, y: -90)
            Circle()
                .fill(StrandPalette.glowAmbient.opacity(0.08))
                .frame(width: 150, height: 150)
                .blur(radius: 26)
                .offset(x: 100, y: 110)
            LinearGradient(
                colors: [StrandPalette.bevelTop.opacity(0.18), .clear, StrandPalette.bevelBottom.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Configurations

struct NOOPWidget: Widget {
    let kind = "NOOPWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPDailyWidgetView(entry: entry)
                .noopAppearance(WidgetAppearancePreference.load())
                .privacySensitive()
                .containerBackground(for: .widget) {
                    NOOPWidgetCanvas(accent: StrandPalette.chargeColor)
                        .noopAppearance(WidgetAppearancePreference.load())
                }
                .widgetURL(NOOPWidgetDestination.today.url)
        }
        .configurationDisplayName("NOOP Daily Signal")
        .description("Recovery, Effort, Sleep, and your three chosen supporting metrics in one honest glance.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
        .contentMarginsDisabled()
    }
}

struct NOOPVitalsWidget: Widget {
    let kind = "NOOPVitalsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPVitalsWidgetView(entry: entry)
                .noopAppearance(WidgetAppearancePreference.load())
                .privacySensitive()
                .containerBackground(for: .widget) {
                    NOOPWidgetCanvas(accent: StrandPalette.statusCritical)
                        .noopAppearance(WidgetAppearancePreference.load())
                }
                .widgetURL(NOOPWidgetDestination.live.url)
        }
        .configurationDisplayName("NOOP Vitals")
        .description("Live or last heart rate, HRV, resting heart rate, connection, and wearable battery.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
        .contentMarginsDisabled()
    }
}

struct NOOPSleepWidget: Widget {
    let kind = "NOOPSleepWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            NOOPSleepWidgetView(entry: entry)
                .noopAppearance(WidgetAppearancePreference.load())
                .privacySensitive()
                .containerBackground(for: .widget) {
                    NOOPWidgetCanvas(accent: StrandPalette.restColor)
                        .noopAppearance(WidgetAppearancePreference.load())
                }
                .widgetURL(NOOPWidgetDestination.sleep.url)
        }
        .configurationDisplayName("NOOP Sleep")
        .description("Sleep score, duration, HRV, and resting heart rate from your latest sleep.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
        .contentMarginsDisabled()
    }
}

// MARK: - Formatting

private func value(_ value: Int?) -> String { value.map(String.init) ?? "–" }

private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "–" }

private func unitValue(_ value: Int?, _ unit: String) -> String {
    value.map { "\($0) \(unit)" } ?? "–"
}

private func sleepDuration(_ minutes: Int?) -> String {
    guard let minutes, minutes > 0 else { return "–" }
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours == 0 { return "\(remainder)m" }
    if remainder == 0 { return "\(hours)h" }
    return "\(hours)h \(remainder)m"
}

private func supportingMetricLabel(_ metric: WidgetMetric) -> LocalizedStringKey {
    switch metric {
    case .heartRate: return "Heart rate"
    case .hrv: return "HRV"
    case .restingHeartRate: return "Resting HR"
    case .sleepDuration: return "Sleep duration"
    case .deviceBattery: return "Device battery"
    }
}

private func supportingMetricSymbol(_ metric: WidgetMetric, snapshot: WidgetSnapshot) -> String {
    switch metric {
    case .heartRate, .restingHeartRate: return "heart.fill"
    case .hrv: return "waveform.path.ecg"
    case .sleepDuration: return "bed.double.fill"
    case .deviceBattery: return batterySymbol(snapshot.batteryPct)
    }
}

private func supportingMetricValue(_ metric: WidgetMetric, snapshot: WidgetSnapshot) -> String {
    switch metric {
    case .heartRate: return unitValue(snapshot.bpm, "bpm")
    case .hrv: return unitValue(snapshot.hrv, "ms")
    case .restingHeartRate: return unitValue(snapshot.restingHr, "bpm")
    case .sleepDuration: return sleepDuration(snapshot.sleepMinutes)
    case .deviceBattery: return percent(snapshot.batteryPct)
    }
}

private func supportingMetricTint(_ metric: WidgetMetric) -> Color {
    switch metric {
    case .heartRate, .restingHeartRate: return StrandPalette.statusCritical
    case .hrv, .deviceBattery: return StrandPalette.chargeColor
    case .sleepDuration: return StrandPalette.restColor
    }
}

private func connectionSymbol(_ snapshot: WidgetSnapshot, at now: Date) -> String {
    if isLive(snapshot, at: now) { return "dot.radiowaves.left.and.right" }
    if snapshot.hasCurrentConnection(at: now) { return "dot.radiowaves.left.and.right" }
    if snapshot.bonded { return "link" }
    return "link.slash"
}

private func connectionLabel(_ snapshot: WidgetSnapshot, at now: Date) -> String {
    if snapshot.hasCurrentConnection(at: now) { return String(localized: "Connected") }
    if snapshot.bonded { return String(localized: "Paired") }
    return String(localized: "Not paired")
}

private func connectionColor(_ snapshot: WidgetSnapshot, at now: Date) -> Color {
    if snapshot.hasCurrentConnection(at: now) { return StrandPalette.statusPositive }
    if snapshot.bonded { return StrandPalette.statusWarning }
    return StrandPalette.textTertiary
}

private func scoreTint(_ score: Int?, fallback: Color) -> Color {
    guard let score else { return StrandPalette.textTertiary }
    return StrandPalette.recoveryColor(Double(score))
}

private func isLive(_ snapshot: WidgetSnapshot, at now: Date) -> Bool {
    snapshot.hasLiveHeartRate(at: now)
}

private func batterySymbol(_ percent: Int?) -> String {
    guard let percent else { return "battery.0percent" }
    switch percent {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

private func scoreDayShort(_ raw: String?) -> String {
    guard let raw, let date = scoreDayFormatter.date(from: raw) else { return "–" }
    if Calendar.current.isDateInToday(date) { return String(localized: "Today") }
    if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday") }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private func scoreDayDescription(_ raw: String?) -> String {
    guard let raw else { return String(localized: "Waiting for daily data") }
    return String(localized: "Scores · \(scoreDayShort(raw))")
}

private let scoreDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

#if DEBUG
struct NOOPWidgetPreviews: PreviewProvider {
    private static var staleSnapshot: WidgetSnapshot {
        var snapshot = WidgetSnapshot.placeholder
        snapshot.updated = Date().addingTimeInterval(-8 * 60 * 60)
        return snapshot
    }

    static var previews: some View {
        Group {
            NOOPDailyWidgetView(entry: NOOPEntry(date: Date(), snapshot: .placeholder))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.chargeColor) }
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Daily · Small · Fresh")
            NOOPDailyWidgetView(entry: NOOPEntry(date: Date(), snapshot: .unavailable))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.chargeColor) }
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Daily · Medium · Empty")
            NOOPDailyWidgetView(entry: NOOPEntry(date: Date(), snapshot: staleSnapshot))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.chargeColor) }
                .previewContext(WidgetPreviewContext(family: .systemLarge))
                .preferredColorScheme(.dark)
                .previewDisplayName("Daily · Large · Stale")
            NOOPVitalsWidgetView(entry: NOOPEntry(date: Date(), snapshot: .placeholder))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.statusCritical) }
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Vitals · Small")
            NOOPVitalsWidgetView(entry: NOOPEntry(date: Date(), snapshot: .placeholder))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.statusCritical) }
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Vitals · Medium")
            NOOPSleepWidgetView(entry: NOOPEntry(date: Date(), snapshot: .placeholder))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.restColor) }
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Sleep · Small")
            NOOPSleepWidgetView(entry: NOOPEntry(date: Date(), snapshot: .unavailable))
                .containerBackground(for: .widget) { NOOPWidgetCanvas(accent: StrandPalette.restColor) }
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Sleep · Medium · Empty")
            NOOPDailyWidgetView(entry: NOOPEntry(date: Date(), snapshot: .placeholder))
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Daily · Lock Screen")
        }
    }
}
#endif
