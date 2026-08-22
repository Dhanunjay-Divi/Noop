import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

// CalendarMonthView.swift — the month-at-a-glance screen (2026-08-22).
//
// WHY: NOOP could show today, and it could show trends, but it had no way to answer "how did this MONTH
// go?" in one glance — the thing Bevel's calendar does well. This is that screen, built in NOOP's own
// language (ScreenScaffold, StrandPalette, MetricGlyph) rather than as a foreign component.
//
// DESIGN NOTES (learned the hard way from the v2 prototype):
//   • Value is encoded as a FILLED cell with strong hue steps (low = red, mid = amber, high = green), NOT
//     as a partial ring. At calendar size a 40% ring and a 70% ring look identical, which defeats the whole
//     purpose of a month view. Bevel uses hue steps for exactly this reason.
//   • A day with no data renders as an EMPTY OUTLINE — never a filled zero. Gaps must look like gaps.
//   • Each day is a ≥44 pt tap target even though the swatch is smaller (HIG minimum).
//   • The metric picker is a segmented row, so the same grid answers Recovery / Effort / Sleep questions.
struct CalendarMonthView: View {
    @EnvironmentObject private var model: AppModel

    /// Which metric colours the grid.
    private enum Metric: String, CaseIterable, Identifiable {
        case recovery, effort, sleep
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recovery: return String(localized: "Recovery")
            case .effort:   return String(localized: "Effort")
            case .sleep:    return String(localized: "Sleep")
            }
        }
        var tint: Color {
            switch self {
            case .recovery: return StrandPalette.chargeColor
            case .effort:   return StrandPalette.effortColor
            case .sleep:    return StrandPalette.restColor
            }
        }
        var glyph: String {
            switch self {
            case .recovery: return "bolt.heart.fill"
            case .effort:   return "flame.fill"
            case .sleep:    return "moon.zzz.fill"
            }
        }
    }

    @State private var metric: Metric = .recovery
    @State private var monthAnchor = Date()
    @State private var rows: [DailyMetric] = []
    @State private var loading = true

    private let cal = Calendar.current

    var body: some View {
        ScreenScaffold(title: "Calendar",
                       subtitle: "Your month, one square per day") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                monthHeader
                metricPicker
                grid
                legend
                summary
            }
        }
        .task(id: monthKey) { await load() }
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
        HStack(spacing: 8) {
            ForEach(Metric.allCases) { m in
                let on = m == metric
                HStack(spacing: 6) {
                    MetricGlyph(m.glyph, size: 20)
                    Text(m.title)
                        .font(StrandFont.subhead)
                        .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)                      // HIG tap target
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? m.tint.opacity(0.18) : StrandPalette.surfaceInset)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(on ? m.tint.opacity(0.55) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { metric = m }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(Text(m.title))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Grid

    private var grid: some View {
        NoopCard {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(weekdayInitials, id: \.self) { d in
                        Text(d)
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
        let v = value(forDay: day)
        let isToday = isToday(day)
        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    .frame(width: 32, height: 27)
                if let v {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Self.stepColor(v, tint: metric.tint))
                        .frame(width: 32, height: 27)
                }
                if isToday {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(StrandPalette.textPrimary, lineWidth: 2)
                        .frame(width: 32, height: 27)
                }
            }
            Text("\(day)")
                .font(StrandFont.overline)
                .foregroundStyle(isToday ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)                                  // ≥44 pt target
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken(day: day, value: v, isToday: isToday)))
    }

    /// Strong hue steps so a low day is RED, not "slightly less green" — arc length is unreadable at this
    /// size, hue is not. Ordered by lightness too, so the month still reads for colour-vision deficiency.
    static func stepColor(_ pct: Double, tint: Color) -> Color {
        let v = min(100, max(0, pct))
        if v < 34 { return StrandPalette.statusCritical.opacity(0.85) }
        if v < 67 { return StrandPalette.statusWarning.opacity(0.85) }
        return tint.opacity(0.9)
    }

    // MARK: Legend + summary

    private var legend: some View {
        HStack(spacing: 14) {
            legendChip(String(localized: "Low"), StrandPalette.statusCritical)
            legendChip(String(localized: "Middling"), StrandPalette.statusWarning)
            legendChip(String(localized: "Strong"), metric.tint)
            legendChip(String(localized: "No data"), .clear, outlined: true)
        }
        .accessibilityHidden(true)
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
                        String(
                            format: String(localized: "appwide.calendar.summary.scored_format"),
                            vals.count,
                            Int(mean.rounded())
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
        var c = cal.dateComponents([.year, .month], from: monthAnchor)
        c.day = day
        guard let d = cal.date(from: c) else { return nil }
        return Repository.localDayKey(d)
    }

    private func isToday(_ day: Int) -> Bool {
        dayKey(day) == Repository.localDayKey(Date())
    }

    private func value(forDay day: Int) -> Double? {
        guard let key = dayKey(day), let row = rows.first(where: { $0.day == key }) else { return nil }
        switch metric {
        case .recovery: return row.recovery
        case .effort:   return row.strain
        case .sleep:    return AnalyticsEngineBridge.restScore(for: row)
        }
    }

    private func spoken(day: Int, value: Double?, isToday: Bool) -> String {
        let prefix = isToday ? String(localized: "Today, ") : ""
        guard let value else {
            return prefix + String(localized: "day \(day), no data")
        }
        return prefix + String(localized: "day \(day), \(metric.title) \(Int(value.rounded()))")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Use the existing range read rather than inventing a month-specific query.
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)),
              let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first) else {
            rows = []; return
        }
        rows = await model.repo.dailyMetrics(fromDay: Repository.localDayKey(first),
                                             toDay: Repository.localDayKey(last))
    }
}

/// Tiny indirection so the view does not need to know how Rest is composed.
private enum AnalyticsEngineBridge {
    static func restScore(for row: DailyMetric) -> Double? {
        AnalyticsEngine.Rest.composite(daily: row)
    }
}
