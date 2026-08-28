import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

// CalendarMonthView.swift — the month-at-a-glance screen (2026-08-22).
//
// WHY: NOOP could show today, and it could show trends, but it had no way to answer "how did this MONTH
// go?" in one glance - the thing Bevel's calendar does well. This is that screen, built in NOOP's own
// language (ScreenScaffold, StrandPalette, MetricGlyph) rather than as a foreign component.
//
// DESIGN NOTES (learned the hard way from the v2 prototype):
//   • The supplied Bevel reference uses compact progress rings. NOOP keeps that shape, but dual-encodes
//     value with strong hue steps (low = red, mid = amber, high = the selected metric tint) so nearby
//     arc lengths remain distinguishable at calendar size.
//   • A day with no data renders as an EMPTY RING — never a zero-valued ring. Gaps must look like gaps.
//   • Each day is a ≥44 pt tap target even though the swatch is smaller (HIG minimum).
//   • The metric picker is a segmented row, so the same grid answers Recovery / Effort / Sleep questions.
struct CalendarMonthView: View {
    @EnvironmentObject private var model: AppModel

    /// Which metric colours the grid.
    private enum Metric: String, CaseIterable, Identifiable {
        case effort, recovery, sleep, stress, energy, nutrition
        var id: String { rawValue }

        /// How to read a HIGH value for this metric. This is the whole reason `stepColor` is not one
        /// shared ramp: painting every metric "low = red, high = green" was actively misleading. A rest
        /// day (low Effort) is not a red-alert day, and a high-autonomic-load day is not a good day —
        /// yet a single ramp said exactly that.
        enum Valence {
            /// Higher is better (Recovery, Sleep): low = red, middling = amber, high = the metric tint.
            case higherIsBetter
            /// Higher is worse (Load): the ramp inverts — calm reads positive, high load reads red.
            case higherIsWorse
            /// Neither good nor bad, just a quantity (Effort). No red/amber valence at all; a single-hue
            /// intensity ramp, so a hard day looks BIGGER, not WORSE.
            case neutralQuantity
        }

        var valence: Valence {
            switch self {
            case .recovery, .sleep: return .higherIsBetter
            case .stress:           return .higherIsWorse
            case .effort, .energy, .nutrition:
                return .neutralQuantity
            }
        }

        var title: String {
            switch self {
            case .effort:    return String(localized: "Effort")
            case .recovery: return String(localized: "Recovery")
            case .sleep:    return String(localized: "Sleep")
            case .stress:   return String(localized: "Stress")
            case .energy:   return String(localized: "Active energy")
            case .nutrition:return String(localized: "Nutrition")
            }
        }
        var tint: Color {
            switch self {
            case .effort:   return StrandPalette.effortColor
            case .recovery: return StrandPalette.chargeColor
            case .sleep:    return StrandPalette.restColor
            case .stress:   return StrandPalette.metricAmber
            case .energy:   return StrandPalette.statusWarning
            case .nutrition:return StrandPalette.statusPositive
            }
        }
        var glyph: String {
            switch self {
            case .effort:   return "flame.fill"
            case .recovery: return "bolt.heart.fill"
            case .sleep:    return "moon.zzz.fill"
            case .stress:   return "gauge.with.dots.needle.50percent"
            case .energy:   return "bolt.fill"
            case .nutrition:return "fork.knife"
            }
        }

        /// The three legend words, lowest bucket first, matching this metric's valence.
        var legendWords: [String] {
            switch valence {
            case .higherIsBetter:
                return [String(localized: "appwide.calendar.legend.low"),
                        String(localized: "appwide.calendar.legend.middling"),
                        String(localized: "appwide.calendar.legend.strong")]
            case .neutralQuantity:
                if self == .effort {
                    return [String(localized: "appwide.calendar.legend.easy"),
                            String(localized: "appwide.calendar.legend.moderate"),
                            String(localized: "appwide.calendar.legend.hard")]
                }
                return [String(localized: "Lower"),
                        String(localized: "Middle"),
                        String(localized: "Higher")]
            case .higherIsWorse:
                return [String(localized: "appwide.calendar.legend.calm"),
                        String(localized: "appwide.calendar.legend.elevated"),
                        String(localized: "appwide.calendar.legend.high")]
            }
        }

        var provenance: String? {
            switch self {
            case .stress:
                return String(localized: "appwide.calendar.stress_provenance")
            case .energy:
                return String(localized: "appwide.calendar.energy_provenance")
            case .nutrition:
                return String(localized: "appwide.calendar.nutrition_provenance")
            default:
                return nil
            }
        }

        var unit: String {
            switch self {
            case .effort: return "/100"
            case .recovery, .sleep: return "%"
            case .stress: return "/3"
            case .energy, .nutrition: return "kcal"
            }
        }

        func format(_ value: Double) -> String {
            switch self {
            case .stress:
                return String(format: "%.1f %@", value, unit)
            default:
                return "\(Int(value.rounded())) \(unit)"
            }
        }
    }

    @State private var metric: Metric = Self.demoMetric ?? .recovery

    /// Screenshot/visual-regression hook: `--demo-calendar-metric <effort|recovery|sleep|stress|energy|nutrition>` preselects
    /// the metric so each ramp's VALENCE can be captured and reviewed. Matches the existing
    /// `--demo-compact-tab-bar` / `--demo-scroll` convention. DEBUG only; production always starts on
    /// Recovery.
    private static var demoMetric: Metric? {
        #if DEBUG
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo-calendar-metric"), i + 1 < args.count else { return nil }
        return Metric(rawValue: args[i + 1])
        #else
        return nil
        #endif
    }
    @State private var monthAnchor = Date()
    @State private var rows: [DailyMetric] = []
    @State private var stressByDay: [String: Double] = [:]
    @State private var energyByDay: [String: Double] = [:]
    @State private var nutritionByDay: [String: Double] = [:]
    @State private var loading = true
    @State private var dayOverview: DayOverviewTarget?

    private let cal = Calendar.current

    var body: some View {
        ScreenScaffold(
            // C3: these were hardcoded English literals, so 8 of 9 locales showed English here even
            // though the translations already existed in the catalog.
            title: "appwide.calendar.your_month",
            subtitle: "appwide.calendar.subtitle",
            topBackground: AnyView(calendarHeaderBackdrop),
            topBackgroundUsesDarkHeader: true
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                monthHeader
                metricPicker
                grid
                legend
                summary
            }
        }
        .task(id: "\(monthKey)|\(model.repo.refreshSeq)") { await load() }
        .sheet(item: $dayOverview) { target in
            NavigationStack {
                DailyOverviewSheet(date: target.date)
                    .environmentObject(model.repo)
            }
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 620, height: 760)
            #endif
        }
    }

    /// A restrained, full-width green signal at the top that fades cleanly into the user's canvas.
    /// It carries the reference's futuristic depth without tinting the data cards or turning every
    /// state green; day rings remain red/amber when the underlying value calls for it.
    private var calendarHeaderBackdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.015, green: 0.16, blue: 0.095),
                Color.black.opacity(0.88),
                Color.black.opacity(0.30),
                .clear,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 380)
        .accessibilityHidden(true)
    }

    // MARK: Month navigation

    private var monthHeader: some View {
        HStack {
            Button { step(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(Text("appwide.calendar.previous_month"))

            Spacer()
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityIdentifier("noop.calendar.month")
            Spacer()

            Button { step(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .disabled(isCurrentMonth)
            .opacity(isCurrentMonth ? 0.3 : 1)
            .accessibilityLabel(Text("appwide.calendar.next_month"))
        }
    }

    private func step(_ months: Int) {
        if let d = cal.date(byAdding: .month, value: months, to: monthAnchor) { monthAnchor = d }
    }

    private var isCurrentMonth: Bool {
        cal.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    // MARK: Metric picker

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Metric.allCases) { m in
                    let on = m == metric
                    Button {
                        metric = m
                    } label: {
                        HStack(spacing: 6) {
                            MetricGlyph(m.glyph, size: 18)
                            Text(m.title)
                                .font(StrandFont.subhead)
                                .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(
                            Capsule()
                                .fill(on ? m.tint.opacity(0.18) : StrandPalette.surfaceInset.opacity(0.72))
                        )
                        .overlay(
                            Capsule()
                                .stroke(on ? m.tint.opacity(0.50) : StrandPalette.hairline, lineWidth: 0.8)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityLabel(Text(m.title))
                    .accessibilityIdentifier("noop.calendar.metric.\(m.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: Grid

    private var grid: some View {
        NoopCard {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(StrandFont.overline)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                let days = daysInMonth
                let lead = leadingBlanks
                let total = lead + days
                let weeks = Int(ceil(Double(total) / 7.0))
                VStack(spacing: 6) {
                    ForEach(0..<weeks, id: \.self) { w in
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { c in
                                let day = w * 7 + c - lead + 1
                                if day >= 1 && day <= days {
                                    dayCell(day)
                                } else {
                                    Color.clear.frame(maxWidth: .infinity).frame(height: 44)
                                }
                            }
                        }
                    }
                }
                if loading {
                    ProgressView().padding(.top, 4)
                }
            }
        }
    }

    private func dayCell(_ day: Int) -> some View {
        let raw = value(forDay: day)
        let progress = raw.map { normalizedProgress($0, metric: metric) }
        let isToday = isToday(day)
        return Button {
            guard let date = dayDate(day) else { return }
            dayOverview = DayOverviewTarget(date: date)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .stroke(StrandPalette.hairlineStrong.opacity(0.48), lineWidth: 4)
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.025, min(progress / 100, 1)))
                            .stroke(
                                Self.stepColor(progress, metric: metric),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    if isToday {
                        Circle()
                            .strokeBorder(StrandPalette.textPrimary.opacity(0.88), lineWidth: 1.4)
                            .padding(-3)
                    }
                }
                .frame(width: 28, height: 28)
                Text("\(day)")
                    .font(StrandFont.overline)
                    .foregroundStyle(isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken(day: day, value: raw, isToday: isToday)))
        .accessibilityHint(Text("appwide.day_overview.open_hint"))
    }

    /// Strong hue steps so a low day is unmistakable at 28 pt, where arc length alone is hard to read.
    ///
    /// The cut points are NOT local literals: they are `RecoveryScorer.bandRedMax` / `bandYellowMax`
    /// (34 / 67), the same constants the recovery band uses everywhere else, so the calendar can never
    /// drift from the rest of the app.
    ///
    /// Valence decides the DIRECTION of the ramp (see `Metric.Valence`). Recovery/Sleep run red → amber →
    /// tint; Load runs the other way, because a high autonomic-load day is a bad day; Effort gets no
    /// red/amber at all — it is a quantity, and a rest day must not be painted as an alarm.
    private static func stepColor(_ pct: Double, metric: Metric) -> Color {
        let v = min(100, max(0, pct))
        let low = v < RecoveryScorer.bandRedMax
        let mid = v < RecoveryScorer.bandYellowMax

        switch metric.valence {
        case .higherIsBetter:
            if low { return StrandPalette.statusCritical.opacity(0.85) }
            if mid { return StrandPalette.statusWarning.opacity(0.85) }
            return metric.tint.opacity(0.9)
        case .higherIsWorse:
            if low { return metric.tint.opacity(0.9) }
            if mid { return StrandPalette.statusWarning.opacity(0.85) }
            return StrandPalette.statusCritical.opacity(0.85)
        case .neutralQuantity:
            // One hue, three intensities: bigger day = stronger colour, never "worse". The floor is 0.55,
            // not 0.38: on the near-black canvas a 0.38-alpha stroke fell under the ~3:1 contrast a
            // non-text UI element needs, which made an easy day (and its legend swatch) almost invisible
            // rather than merely quiet.
            if low { return metric.tint.opacity(0.55) }
            if mid { return metric.tint.opacity(0.75) }
            return metric.tint.opacity(0.95)
        }
    }

    /// The legend swatch colours, lowest bucket first — derived from the SAME function the cells use, so
    /// the legend can never disagree with the grid.
    private var legendColors: [Color] {
        [Self.stepColor(10, metric: metric),
         Self.stepColor(50, metric: metric),
         Self.stepColor(90, metric: metric)]
    }

    // MARK: Legend + summary

    private var legend: some View {
        let words = metric.legendWords
        let colors = legendColors
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                        legendChip(word, colors[idx])
                    }
                    legendChip(String(localized: "appwide.calendar.legend.no_data"), .clear, outlined: true)
                }
            }
            if let provenance = metric.provenance {
                Text(provenance)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The swatch row is decorative (VoiceOver reads each day's value directly), but the provenance
        // sentence is information, so the legend as a whole must NOT be hidden from assistive tech.
        .accessibilityElement(children: .combine)
    }

    private func legendChip(_ t: String, _ c: Color, outlined: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(c)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(outlined ? StrandPalette.hairline : .clear, lineWidth: 1)
                )
                .frame(width: 10, height: 10)
            Text(t).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// Honest month summary: only counts days that actually have a value.
    private var summary: some View {
        let vals = (1...max(1, daysInMonth)).compactMap { value(forDay: $0) }
        return NoopCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("appwide.calendar.summary.overline").font(StrandFont.overline).tracking(0)
                    .foregroundStyle(StrandPalette.textSecondary)
                if vals.isEmpty {
                    Text(
                        String(
                            format: String(localized: "appwide.calendar.summary.empty_format"),
                            metric.title.lowercased()
                        )
                    )
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    let mean = vals.reduce(0, +) / Double(vals.count)
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "appwide.calendar.summary.scored_format"),
                            vals.count,
                            metric.format(mean)
                        )
                    )
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Text("appwide.calendar.summary.gaps")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Data

    private var monthKey: String {
        let c = cal.dateComponents([.year, .month], from: monthAnchor)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    private var daysInMonth: Int {
        cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
    }

    /// Weekday offset of day 1 within the user's week (0 = first column).
    private var leadingBlanks: Int {
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)) else { return 0 }
        let wd = cal.component(.weekday, from: first)
        return (wd - cal.firstWeekday + 7) % 7
    }

    private var weekdayInitials: [String] {
        let syms = cal.veryShortStandaloneWeekdaySymbols
        let start = cal.firstWeekday - 1
        return (0..<7).map { syms[(start + $0) % 7] }
    }

    private func dayKey(_ day: Int) -> String? {
        dayDate(day).map(Repository.localDayKey)
    }

    private func dayDate(_ day: Int) -> Date? {
        var c = cal.dateComponents([.year, .month], from: monthAnchor)
        c.day = day
        return cal.date(from: c)
    }

    private func isToday(_ day: Int) -> Bool {
        dayKey(day) == Repository.localDayKey(Date())
    }

    private func value(forDay day: Int) -> Double? {
        guard let key = dayKey(day) else { return nil }
        let row = rows.first(where: { $0.day == key })
        switch metric {
        case .effort:   return row?.strain
        case .recovery: return row?.recovery
        case .sleep:    return row.flatMap(AnalyticsEngineBridge.restScore)
        case .stress:   return stressByDay[key]
        case .energy:   return energyByDay[key]
        case .nutrition:return nutritionByDay[key]
        }
    }

    /// Score-like metrics already own a fixed scale. Quantity metrics are drawn relative to the
    /// selected month's largest observed day, so ring length means "more of this quantity", not
    /// "healthier" or "closer to a target".
    private func normalizedProgress(_ value: Double, metric: Metric) -> Double {
        switch metric {
        case .effort, .recovery, .sleep:
            return min(100, max(0, value))
        case .stress:
            return min(100, max(0, value / 3.0 * 100.0))
        case .energy:
            return relativeProgress(value, values: Array(energyByDay.values))
        case .nutrition:
            return relativeProgress(value, values: Array(nutritionByDay.values))
        }
    }

    private func relativeProgress(_ value: Double, values: [Double]) -> Double {
        let ceiling = values.filter { $0.isFinite && $0 > 0 }.max() ?? 0
        guard ceiling > 0 else { return 0 }
        return min(100, max(0, value / ceiling * 100))
    }

    private func spoken(day: Int, value: Double?, isToday: Bool) -> String {
        // C4: this used String(localized:) on an INTERPOLATED string, which produces a throwaway key
        // that is in no catalog — so every day cell spoke English regardless of locale, and the
        // "Today, " prefix was glued on in a word order that does not hold in other languages.
        guard let value else {
            return String(
                format: String(localized: isToday
                               ? "appwide.calendar.a11y.today_no_data_format"
                               : "appwide.calendar.a11y.day_no_data_format"),
                day
            )
        }
        return String.localizedStringWithFormat(
            String(localized: isToday
                   ? "appwide.calendar.a11y.today_value_format"
                   : "appwide.calendar.a11y.day_value_format"),
            day,
            metric.title,
            Int(value.rounded())
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Use the existing range read rather than inventing a month-specific query.
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)),
              let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first) else {
            rows = []; return
        }
        let baselineStart = cal.date(
            byAdding: .day,
            value: -(DailyAutonomicLoad.baselineWindowDays + 7),
            to: first
        ) ?? first
        async let historyA = model.repo.dailyMetrics(
            fromDay: Repository.localDayKey(baselineStart),
            toDay: Repository.localDayKey(last)
        )
        async let importedStressA = model.repo.exploreSeries(
            key: "stress", source: "my-whoop", fullHistory: true
        )
        async let appleEnergyA = model.repo.exploreSeries(
            key: "active_kcal", source: "apple-health", fullHistory: true
        )
        async let nutritionA = model.repo.exploreSeries(
            key: "calories_in", source: "nutrition-log", fullHistory: true
        )
        let history = await historyA
        let firstKey = Repository.localDayKey(first)
        let lastKey = Repository.localDayKey(last)
        rows = history.filter { $0.day >= firstKey }
        let proxyStress = CalendarMonthSeries.reliableStress(
            DailyAutonomicLoad.causalTrend(
                days: history.map {
                    DailyAutonomicLoad.Day(
                        day: $0.day,
                        restingHeartRate: $0.restingHr.map(Double.init),
                        hrv: $0.avgHrv
                    )
                }
            )
        )
        stressByDay = Self.mergeByDay(
            fallback: proxyStress,
            preferred: await importedStressA,
            from: firstKey,
            through: lastKey
        )
        energyByDay = Self.mergeByDay(
            fallback: [:],
            preferred: await appleEnergyA,
            from: firstKey,
            through: lastKey
        )
        nutritionByDay = Dictionary(
            uniqueKeysWithValues: (await nutritionA)
                .filter { $0.day >= firstKey && $0.day <= lastKey && $0.value.isFinite && $0.value >= 0 }
                .map { ($0.day, $0.value) }
        )
    }

    private static func mergeByDay(
        fallback: [String: Double],
        preferred: [(day: String, value: Double)],
        from firstDay: String,
        through lastDay: String
    ) -> [String: Double] {
        var merged = fallback.filter {
            $0.key >= firstDay && $0.key <= lastDay && $0.value.isFinite && $0.value >= 0
        }
        for point in preferred where point.day >= firstDay && point.day <= lastDay
            && point.value.isFinite && point.value >= 0 {
            merged[point.day] = point.value
        }
        return merged
    }
}

/// Data-integrity gates for month-level reference series. Kept pure so limited autonomic estimates
/// cannot silently re-enter the red/amber Stress calendar during a presentation refactor.
enum CalendarMonthSeries {
    static func reliableStress(
        _ readouts: [DailyAutonomicLoad.Readout]
    ) -> [String: Double] {
        readouts.reduce(into: [:]) { values, readout in
            guard readout.confidence == .reliable,
                  let day = readout.asOf,
                  let value = readout.value,
                  value.isFinite,
                  value >= 0 else { return }
            values[day] = value
        }
    }
}

/// Tiny indirection so the view does not need to know how Rest is composed.
private enum AnalyticsEngineBridge {
    static func restScore(for row: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: row)
    }
}
