import SwiftUI

// TodayV2View.swift — the v2 "Aurora" Today screen (UI v2).
//
// HIERARCHY (the core fix vs v1): v1 put three equal rings + badges + synthesis + vitals + a metric grid
// above the fold, so nothing led. v2 reads top-to-bottom as an answer:
//   1. ONE hero arc — the day's headline score.
//   2. Two satellites — the other scores, clearly secondary.
//   3. ONE coaching line — "the one thing that matters today".
//   4. Your own range — vitals as "where I sit in MY range" (the question a bare number never answers).
//   5. Pattern — the week×hour load heatmap (R7 engine).
//   6. Detail — the metric grid, last.
//
// PERFORMANCE: every surface is static (no TimelineView / Canvas physics / CoreMotion). This is the same
// screen content as v1 with ~none of the per-frame cost.
//
// HONESTY: nil values render as an em-dash with a muted treatment; provenance/confidence chips ride the
// hero; the heatmap leaves unscored hours empty. Nothing is fabricated to make the layout look full.

/// Plain value input so the screen renders identically from live data or the screenshot harness.
struct TodayV2Model {
    var dateText: String = ""
    var greeting: String = ""

    // Scores (0–100), nil = not scored yet
    var charge: Double?
    var effort: Double?
    var rest: Double?
    var confidence: String = "Calibrating"     // Calibrating / Building / Solid
    var provenance: String = "On-device"

    // Coaching
    var coachOverline: String = "Today's focus"
    var coachMessage: String = ""
    var coachAction: String? = nil

    // Vitals with personal ranges
    var hrv: Double?
    var hrvRange: (Double, Double)?
    var restingHR: Double?
    var restingHRRange: (Double, Double)?
    var respiratory: Double?
    var respiratoryRange: (Double, Double)?
    var skinTempDev: Double?

    // Deltas vs baseline
    var hrvDelta: Double?
    var rhrDelta: Double?

    // Detail tiles
    var sleepHours: Double?
    var steps: Int?
    var calories: Int?
    var spo2: Double?
    var hydrationML: Int?
    var hydrationGoalML: Int?

    // Heatmap: [hour: [dayIndex: level]]
    var heatmap: [Int: [Int: Double]] = [:]
    var heatmapDays: [String] = []
    var heatmapCaption: String? = nil

    // Trend
    var chargeTrend: [Double] = []

    /// Which score leads the screen. Rest is the honest default early in the day (it's the one that's
    /// actually complete on waking); Charge takes over once it exists.
    var headline: (label: String, value: Double?, base: Color, tip: Color, caption: String?) {
        if let c = charge {
            return ("Recovery", c, NoopV2.charge, NoopV2.chargeTip, c >= 66 ? "Ready" : (c >= 34 ? "Moderate" : "Take it easy"))
        }
        if let r = rest {
            return ("Sleep", r, NoopV2.rest, NoopV2.restTip, r >= 85 ? "Optimal" : "Building")
        }
        return ("Recovery", nil, NoopV2.charge, NoopV2.chargeTip, "Calibrating")
    }
}

struct TodayV2View: View {
    let model: TodayV2Model

    private var heroTint: Color { model.headline.base }

    var body: some View {
        ZStack {
            NoopV2.canvas(tint: heroTint)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopV2.sectionGap) {
                        header.id("header")
                        hero.id("hero")
                        if !model.coachMessage.isEmpty {
                            V2CoachBanner(overline: model.coachOverline,
                                          message: model.coachMessage,
                                          tint: heroTint,
                                          actionTitle: model.coachAction)
                        }
                        ranges.id("ranges")
                        if !model.chargeTrend.isEmpty { trendCard.id("trend") }
                        if !model.heatmapDays.isEmpty { heatmap.id("heatmap") }
                        detail.id("detail")
                        footer
                    }
                    .padding(.horizontal, NoopV2.screenPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .onAppear {
                    // DEBUG screenshot harness: `--demo-scroll ranges|heatmap|detail` jumps straight to a
                    // section so each part of a long screen can be captured deterministically.
                    #if DEBUG
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--demo-scroll"), i + 1 < args.count {
                        let anchor = args[i + 1]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                    #endif
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.dateText.uppercased())
                    .font(NoopV2.overline)
                    .tracking(0)
                    .foregroundStyle(NoopV2.inkTertiary)
                Text(model.greeting)
                    .font(NoopV2.display)
                    .foregroundStyle(NoopV2.ink)
            }
            Spacer()
            HStack(spacing: 7) {
                V2Chip(text: model.provenance, tone: NoopV2.inkSecondary)
                V2Chip(text: model.confidence,
                       tone: model.confidence.lowercased() == "solid" ? NoopV2.positive : NoopV2.inkSecondary)
            }
        }
    }

    // MARK: Hero + satellites

    private var hero: some View {
        VStack(spacing: 20) {
            let h = model.headline
            V2HeroArc(label: h.label, value: h.value, max: 100,
                      base: h.base, tip: h.tip, caption: h.caption)
                .padding(.top, 4)

            // C8 FIX: TWO satellites only. The old row put Sleep + Effort rings AND a labelled sparkline
            // side by side — three objects of different shapes at similar visual weight, which re-created
            // v1's "nothing leads" problem in miniature. The trend moved to its own card below (C7).
            HStack(spacing: 22) {
                if h.label != "Sleep" {
                    V2SatelliteRing(label: "Sleep", value: model.rest,
                                    base: NoopV2.rest, tip: NoopV2.restTip)
                }
                V2SatelliteRing(label: "Effort", value: model.effort,
                                base: NoopV2.effort, tip: NoopV2.effortTip)
                if h.label == "Sleep" {
                    V2SatelliteRing(label: "Recovery", value: model.charge,
                                    base: NoopV2.charge, tip: NoopV2.chargeTip)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .v2Card(padding: 20, raised: true)
    }

    /// C7/C8: the 14-day trace, now with a personal-mean baseline and a "today" marker, in its own card
    /// where it has room to mean something.
    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    String(
                        format: String(localized: "appwide.v2.trend.title_format"),
                        model.headline.label.uppercased()
                    )
                )
                    .font(NoopV2.overline)
                    .tracking(0)
                    .foregroundStyle(NoopV2.inkTertiary)
                Spacer(minLength: 8)
                Text("appwide.v2.trend.average")
                    .font(NoopV2.overline)
                    .foregroundStyle(NoopV2.inkTertiary)
            }
            V2Sparkline(points: model.chargeTrend,
                        tint: model.headline.base,
                        height: 56,
                        accessibilityTitle: "14-day \(model.headline.label) trend")
        }
        .v2Card()
    }

    // MARK: Your own range

    private var ranges: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2SectionHeader(overline: "vs your own baseline",
                            title: "Your range",
                            trailing: "30-day")
            VStack(spacing: 16) {
                V2RangeGauge(title: "HRV (RMSSD)", value: model.hrv, unit: "ms",
                             rangeLow: model.hrvRange?.0, rangeHigh: model.hrvRange?.1,
                             tint: NoopV2.charge,
                             statusText: rangeStatus(model.hrv, model.hrvRange, higherIsBetter: true))
                V2RangeGauge(title: "Resting heart rate", value: model.restingHR, unit: "bpm",
                             rangeLow: model.restingHRRange?.0, rangeHigh: model.restingHRRange?.1,
                             tint: NoopV2.rest,
                             statusText: rangeStatus(model.restingHR, model.restingHRRange, higherIsBetter: false))
                V2RangeGauge(title: "Respiratory rate", value: model.respiratory, unit: "rpm",
                             rangeLow: model.respiratoryRange?.0, rangeHigh: model.respiratoryRange?.1,
                             tint: NoopV2.load,
                             statusText: rangeStatus(model.respiratory, model.respiratoryRange, higherIsBetter: false))
            }
            .v2Card()
        }
    }

    /// Honest one-liner: where in YOUR range you sit — never a population verdict.
    ///
    /// The agent's review flagged that all three gauges read "Inside your usual range", which is
    /// repetitive and low-information. Copy now varies by POSITION within the personal band, so three
    /// gauges tell three different stories while still saying nothing clinical.
    private func rangeStatus(_ v: Double?, _ range: (Double, Double)?, higherIsBetter: Bool) -> String? {
        guard let v, let r = range, r.1 > r.0 else { return "Not enough baseline yet" }
        if v < r.0 { return "Below your usual range" }
        if v > r.1 { return "Above your usual range" }
        let f = (v - r.0) / (r.1 - r.0)          // 0 = bottom of your band, 1 = top
        if f >= 0.75 { return higherIsBetter ? "Top of your range — strong" : "High side of your range" }
        if f <= 0.25 { return higherIsBetter ? "Low side of your range" : "Bottom of your range — good" }
        return "Mid-range for you"
    }

    // MARK: Pattern

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2SectionHeader(overline: "when you run hot",
                            title: "Load pattern",
                            trailing: "this week")
            V2Heatmap(hours: Array(model.heatmap.keys.sorted()),
                      dayLabels: model.heatmapDays,
                      level: { h, d in model.heatmap[h]?[d] },
                      caption: model.heatmapCaption)
                .v2Card()
        }
    }

    // MARK: Detail grid

    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2SectionHeader(overline: "today", title: "Details")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopV2.stackGap),
                                GridItem(.flexible(), spacing: NoopV2.stackGap)],
                      spacing: NoopV2.stackGap) {
                V2StatTile(label: "Sleep", value: model.sleepHours.map { String(format: "%.1f", $0) },
                           unit: "h", tint: NoopV2.rest, systemImage: "moon.fill")
                V2StatTile(label: "HRV", value: model.hrv.map { String(Int($0.rounded())) },
                           unit: "ms", tint: NoopV2.charge, delta: model.hrvDelta,
                           higherIsBetter: true, systemImage: "waveform.path.ecg")
                V2StatTile(label: "Resting HR", value: model.restingHR.map { String(Int($0.rounded())) },
                           unit: "bpm", tint: NoopV2.rest, delta: model.rhrDelta,
                           higherIsBetter: false, systemImage: "heart.fill")
                V2StatTile(label: "Blood oxygen", value: model.spo2.map { String(format: "%.1f", $0) },
                           unit: "%", tint: NoopV2.load, systemImage: "drop.fill")
                V2StatTile(label: "Steps", value: model.steps.map { "\($0)" },
                           tint: NoopV2.charge, systemImage: "figure.walk")
                V2StatTile(label: "Calories", value: model.calories.map { "\($0)" },
                           unit: "kcal", tint: NoopV2.effort, systemImage: "flame.fill")
                if let ml = model.hydrationML, let goal = model.hydrationGoalML {
                    V2StatTile(label: "Hydration",
                               value: String(format: "%.1f", Double(ml) / 1000),
                               unit: "of \(String(format: "%.1f", Double(goal) / 1000)) L",
                               tint: NoopV2.rest, systemImage: "drop.circle.fill")
                }
                if let t = model.skinTempDev {
                    V2StatTile(label: "Skin temp", value: String(format: "%+.1f", t),
                               unit: "°C vs base", tint: NoopV2.effort, systemImage: "thermometer.medium")
                }
            }
        }
    }

    private var footer: some View {
        Text("appwide.disclaimer.estimates_advice")
            .font(NoopV2.caption)
            .foregroundStyle(NoopV2.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

// MARK: - Demo data (screenshot harness / previews)

extension TodayV2Model {
    /// A realistic, fully-populated day so the layout can be reviewed and screenshotted. Mirrors the
    /// shapes the live wiring will provide.
    static var demo: TodayV2Model {
        var m = TodayV2Model()
        m.dateText = "Saturday, August 22"
        m.greeting = "Good morning"
        m.charge = 64
        m.effort = 41
        m.rest = 88
        m.confidence = "Solid"
        m.provenance = "On-device"
        m.coachOverline = "Today's focus"
        m.coachMessage = "Sleep was strong and your HRV is inside your usual range — a moderate-to-hard session is well supported today."
        m.coachAction = "See training target"
        m.hrv = 91          // near the top of the personal band -> "Top of your range"
        m.hrvRange = (62, 96)
        m.restingHR = 49    // bottom of the band, and lower is better -> "Bottom of your range - good"
        m.restingHRRange = (48, 60)
        m.respiratory = 14.2
        m.respiratoryRange = (12.5, 16.0)
        m.skinTempDev = 0.2
        m.hrvDelta = 4
        m.rhrDelta = -2
        m.sleepHours = 7.8
        m.steps = 6420
        m.calories = 2810
        m.spo2 = 97.4
        m.hydrationML = 1450
        m.hydrationGoalML = 3100
        m.chargeTrend = [52, 58, 61, 49, 55, 63, 66, 60, 57, 65, 69, 62, 61, 64]
        m.heatmapDays = ["M", "T", "W", "T", "F", "S", "S"]
        // A believable week: calm mornings, a hot Wednesday afternoon, sparse Sunday wear.
        var grid: [Int: [Int: Double]] = [:]
        for h in 6..<22 {
            var row: [Int: Double] = [:]
            for d in 0..<7 {
                if d == 6 && h > 12 { continue }                       // sparse wear ⇒ empty cells
                var v = 0.7 + Double((h * 7 + d) % 5) * 0.18
                if h >= 13 && h <= 17 { v += 0.7 }                     // afternoon lift
                if d == 2 && h >= 13 && h <= 17 { v += 0.8 }           // hot Wednesday
                if h >= 20 { v = 0.45 }                                // evening wind-down
                row[d] = min(3, v)
            }
            grid[h] = row
        }
        m.heatmap = grid
        m.heatmapCaption = "Your load peaks mid-afternoon and settles after 20:00. Wednesday ran hottest this week."
        return m
    }
}

#if DEBUG
struct TodayV2View_Previews: PreviewProvider {
    static var previews: some View {
        TodayV2View(model: .demo)
    }
}
#endif
