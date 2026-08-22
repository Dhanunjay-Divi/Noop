import SwiftUI

// V2MonthCalendar.swift — the month-at-a-glance grid (UI v2).
//
// Reflects the one distinctive idea from the Bevel reference NOOP had no equivalent for: a month of days
// as small rings, with a metric picker, so a user can spot streaks and bad patches instantly. v1 has
// Trends (ranges + charts) but nothing that answers "how did this MONTH go?" in one glance.
//
// Pure presentation over series NOOP already stores. Static (no animation). Days with no value render as
// an empty track — never a zero ring, so a gap in wear looks like a gap.

/// One metric the calendar can colour by.
struct V2CalendarMetric: Identifiable, Equatable {
    let id: String
    let title: String
    let base: Color
    let tip: Color
    /// 0…1 fraction per day-of-month (1-based key). Missing key ⇒ no data for that day.
    let values: [Int: Double]
}

struct V2MonthCalendar: View {
    let monthTitle: String
    let metrics: [V2CalendarMetric]
    /// Weekday index (0 = Sunday) that day 1 falls on.
    let firstWeekdayOffset: Int
    let dayCount: Int
    /// Highlighted "today" day-of-month, if this month contains it.
    var today: Int? = nil
    @State private var selected: String = ""

    private var active: V2CalendarMetric? {
        metrics.first { $0.id == selected } ?? metrics.first
    }

    private let cols = 7
    private let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Metric picker — horizontal chips. C5: vertical padding raised so each pill clears ~44 pt.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(metrics) { m in
                        let isOn = (active?.id == m.id)
                        Text(m.title)
                            .font(NoopV2.overline)
                            .tracking(0.6)
                            .foregroundStyle(isOn ? .black.opacity(0.85) : NoopV2.inkSecondary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)                     // C5: HIG minimum
                            .background(
                                Capsule().fill(isOn ? m.base.opacity(0.92) : Color.white.opacity(0.07))
                            )
                            .contentShape(Capsule())
                            .onTapGesture { selected = m.id }
                            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                            .accessibilityLabel(Text(m.title))
                    }
                }
                .padding(.vertical, 1)
            }

            // Weekday header
            HStack(spacing: 6) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid
            let leading = Swift.max(0, Swift.min(6, firstWeekdayOffset))
            let cells = leading + dayCount
            let rows = Int(ceil(Double(cells) / Double(cols)))
            VStack(spacing: 6) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            let day = idx - leading + 1
                            if day >= 1 && day <= dayCount {
                                dayCell(day)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 44)
                            }
                        }
                    }
                }
            }
        }
    }

    /// C6 FIX: at 26 pt with a 3 pt stroke a 40% day and a 70% day looked identical ("an almost-full green
    /// ring"), which destroyed the whole point of a month view. Value is now encoded as a FILLED cell with
    /// strong hue steps (red → amber → mint, the idea Bevel's own month view uses) plus opacity — far easier
    /// to compare at this size than arc length. A no-data day stays an EMPTY outline, never a filled zero.
    ///
    /// C5 FIX: the visible cell is compact but the hit area is a full 44 pt square.
    private func dayCell(_ day: Int) -> some View {
        let frac = active?.values[day]
        let isToday = today == day
        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(NoopV2.decorationFaint.opacity(0.28), lineWidth: 1)
                    .frame(width: 30, height: 26)
                if let f = frac {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Self.stepColor(f))
                        .frame(width: 30, height: 26)
                }
                if isToday {
                    // "Today" must be unmistakable (the old white-0.14 disc was too subtle).
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(NoopV2.ink, lineWidth: 2)
                        .frame(width: 30, height: 26)
                }
            }
            Text("\(day)")
                .font(.system(size: 10, weight: isToday ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isToday ? NoopV2.ink : NoopV2.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)                       // C5: ≥44 pt target even though the swatch is 26 pt
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(spoken(day: day, frac: frac, isToday: isToday)))
    }

    /// Strong hue steps so a bad day is RED, not "slightly less green" (C6). Ordered by lightness too, so
    /// the month still reads in greyscale / with colour-vision deficiency.
    static func stepColor(_ f: Double) -> Color {
        let v = Swift.min(1, Swift.max(0, f))
        if v < 0.34 { return Color(red: 0.85, green: 0.30, blue: 0.28).opacity(0.90) }   // low  — red
        if v < 0.67 { return Color(red: 0.93, green: 0.72, blue: 0.28).opacity(0.90) }   // mid  — amber
        return Color(red: 0.26, green: 0.82, blue: 0.58).opacity(0.92)                   // high — mint
    }

    private func spoken(day: Int, frac: Double?, isToday: Bool) -> String {
        let prefix = isToday ? "Today, " : ""
        let name = active?.title ?? "value"
        guard let f = frac else { return "\(prefix)day \(day), no data" }
        return "\(prefix)day \(day), \(name) \(Int((f * 100).rounded())) percent"
    }
}

// MARK: - Demo host (screenshot harness)

struct V2MonthCalendarDemo: View {
    var body: some View {
        ZStack {
            NoopV2.canvas(tint: NoopV2.charge)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopV2.sectionGap) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AUGUST 2026".uppercased())
                            .font(NoopV2.overline).tracking(1.2)
                            .foregroundStyle(NoopV2.inkTertiary)
                        Text("Your month")
                            .font(NoopV2.display)
                            .foregroundStyle(NoopV2.ink)
                    }
                    V2MonthCalendar(monthTitle: "August 2026",
                                    metrics: Self.demoMetrics,
                                    firstWeekdayOffset: 6,   // Aug 1 2026 = Saturday
                                    dayCount: 31,
                                    today: 22)
                        .v2Card()
                    Text("Each square is one day: red is a low day, amber middling, mint strong. An empty outline means no data — gaps stay gaps.")
                        .font(NoopV2.caption)
                        .foregroundStyle(NoopV2.inkTertiary)
                }
                .padding(.horizontal, NoopV2.screenPadding)
                .padding(.vertical, 14)
            }
        }
        .preferredColorScheme(.dark)
    }

    static var demoMetrics: [V2CalendarMetric] {
        func series(_ seed: Int, gapDays: Set<Int>) -> [Int: Double] {
            var out: [Int: Double] = [:]
            for d in 1...22 {                                   // future days have no data yet
                if gapDays.contains(d) { continue }             // honest wear gaps
                // Spread across the full 0-1 range so the red/amber/mint hue steps are all exercised.
                let x = Double((d * seed) % 11) / 10.0
                out[d] = 0.08 + x * 0.9
            }
            return out
        }
        return [
            V2CalendarMetric(id: "recovery", title: "Recovery",
                             base: NoopV2.charge, tip: NoopV2.chargeTip,
                             values: series(7, gapDays: [10, 17])),
            V2CalendarMetric(id: "sleep", title: "Sleep",
                             base: NoopV2.rest, tip: NoopV2.restTip,
                             values: series(5, gapDays: [10])),
            V2CalendarMetric(id: "effort", title: "Effort",
                             base: NoopV2.effort, tip: NoopV2.effortTip,
                             values: series(3, gapDays: [10, 11, 17])),
            V2CalendarMetric(id: "load", title: "Load",
                             base: NoopV2.load, tip: NoopV2.loadTip,
                             values: series(9, gapDays: [10, 17, 18])),
        ]
    }
}
