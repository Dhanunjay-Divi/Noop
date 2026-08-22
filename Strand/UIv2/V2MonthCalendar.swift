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
            // Metric picker — horizontal chips, the active one filled.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(metrics) { m in
                        let isOn = (active?.id == m.id)
                        Text(m.title)
                            .font(NoopV2.overline)
                            .tracking(0.6)
                            .foregroundStyle(isOn ? .black.opacity(0.85) : NoopV2.inkSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isOn ? m.base.opacity(0.92) : Color.white.opacity(0.07))
                            )
                            .onTapGesture { selected = m.id }
                    }
                }
            }

            // Weekday header
            HStack(spacing: 6) {
                ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Day grid
            let leading = Swift.max(0, Swift.min(6, firstWeekdayOffset))
            let cells = leading + dayCount
            let rows = Int(ceil(Double(cells) / Double(cols)))
            VStack(spacing: 8) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<cols, id: \.self) { c in
                            let idx = r * cols + c
                            let day = idx - leading + 1
                            if day >= 1 && day <= dayCount {
                                dayCell(day)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 34)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Int) -> some View {
        let frac = active?.values[day]
        let base = active?.base ?? NoopV2.charge
        let tip = active?.tip ?? NoopV2.chargeTip
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if let f = frac {
                    Circle()
                        .trim(from: 0, to: Swift.min(1, Swift.max(0.02, f)))
                        .stroke(NoopV2.ramp(base, tip), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if today == day {
                    Circle().fill(Color.white.opacity(0.14)).padding(4)
                }
            }
            .frame(width: 26, height: 26)
            Text("\(day)")
                .font(.system(size: 9, weight: today == day ? .bold : .regular).monospacedDigit())
                .foregroundStyle(today == day ? NoopV2.ink : NoopV2.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 34)
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
                    Text("Each ring is one day. An empty ring means no data for that day — gaps stay gaps.")
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
                let x = Double((d * seed) % 11) / 11.0
                out[d] = 0.35 + x * 0.6
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
