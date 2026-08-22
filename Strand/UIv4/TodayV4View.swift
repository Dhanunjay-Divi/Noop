import SwiftUI
import StrandDesign

// TodayV4View.swift — "USEFUL" (UI v4).
//
// WHAT CHANGED AND WHY (owner feedback, verbatim: "Bevel looked good and NOOP 3d icons looked good…
// how is load chart helpful i'm not understanding… I want useful clear and nice metrics"):
//
//  1. **The load heatmap is GONE.** It was engineer-brain: a 112-cell hour×day matrix is a research
//     artifact, not something a person needs at 7am. Nobody opens a health app asking "what was my
//     autonomic load at 3pm last Tuesday". Removing it is the single biggest usefulness win here.
//
//  2. **Reuse NOOP's own 3D language.** `MetricGlyph`/`DepthGlyph` (real extruded icon plates) and
//     `BevelGauge` already exist in StrandDesign and are the thing the owner likes. v2/v3 ignored them in
//     favour of flat SF Symbols — a mistake, because those glyphs ARE the brand's visual signature.
//
//  3. **Every block answers ONE question a user actually has.** In order:
//        "Am I recovered?"            → the hero gauge + state word
//        "Why is it that number?"     → WHY: the three drivers, each vs YOUR baseline, in plain words
//        "What should I do today?"    → TARGET: a concrete effort range + one action
//        "Did I sleep enough?"        → the deficit in minutes, not a percentage
//        "Is anything off?"           → WATCH: appears only when something actually deviates
//        "Am I trending up or down?"  → a 7-day direction strip
//     A metric that cannot finish the sentence "…so you should ___" or "…which means ___" does not ship.
//
//  4. **Density like Bevel**: tight rows, hairline dividers, micro-caps field names, big tabular figures,
//     status words. Colour only ever encodes data or status.
//
// Still fully static (no per-frame work), still honest (nil ⇒ em-dash, never a fabricated 0).

struct TodayV4Model {
    var dateText = ""
    var provenance = "ON-DEVICE"
    var confidence = "SOLID"

    // Am I recovered?
    var recovery: Double?
    var recoveryState = ""            // "Ready" / "Moderate" / "Take it easy"

    // Why?
    struct Driver {
        var glyph: String             // SF Symbol name rendered as a 3D MetricGlyph
        var name: String
        var value: String?
        var unit: String
        var phrase: String            // plain-language meaning vs the user's own baseline
        var tone: V4.Tone
    }
    var drivers: [Driver] = []

    // What should I do?
    var targetLow: Int?
    var targetHigh: Int?
    var targetAction = ""

    // Did I sleep enough?
    var sleptMinutes: Int?
    var neededMinutes: Int?
    var sleepStages: [(String, Int, Color)] = []   // (name, minutes, colour)

    // Is anything off?
    var watchItems: [String] = []

    // Trending?
    struct Direction { var name: String; var delta: Double?; var unit: String; var higherIsBetter: Bool }
    var directions: [Direction] = []
}

enum V4 {
    enum Tone { case good, neutral, watch }

    static let field = Color(red: 0.035, green: 0.039, blue: 0.047)
    static let surface = Color(red: 0.078, green: 0.086, blue: 0.098)
    static let inset = Color(red: 0.118, green: 0.129, blue: 0.145)
    static let hairline = Color.white.opacity(0.09)

    static let ink = Color(red: 0.965, green: 0.969, blue: 0.976)
    static let ink2 = Color.white.opacity(0.72)
    static let ink3 = Color.white.opacity(0.56)

    static let good = Color(red: 0.27, green: 0.83, blue: 0.55)
    static let watch = Color(red: 0.99, green: 0.66, blue: 0.29)
    static let cool = Color(red: 0.47, green: 0.62, blue: 0.99)
    static let violet = Color(red: 0.72, green: 0.55, blue: 0.98)

    static func toneColor(_ t: Tone) -> Color {
        switch t { case .good: return good; case .watch: return watch; case .neutral: return ink3 }
    }

    static let pad: CGFloat = 16
    static let radius: CGFloat = 16
    static func figure(_ s: CGFloat, _ w: Font.Weight = .semibold) -> Font {
        .system(size: s, weight: w, design: .default).monospacedDigit()
    }
    static let micro = Font.system(.caption2).weight(.semibold)
    static let body = Font.system(.subheadline)
    static let bodyStrong = Font.system(.subheadline).weight(.semibold)
}

private extension View {
    func v4Card(_ padding: CGFloat = V4.pad) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: V4.radius, style: .continuous).fill(V4.surface))
            .overlay(RoundedRectangle(cornerRadius: V4.radius, style: .continuous)
                .stroke(V4.hairline, lineWidth: 0.5))
    }
    func v4Micro() -> some View {
        self.font(V4.micro).tracking(0).foregroundStyle(V4.ink3)
    }
}

struct TodayV4View: View {
    let model: TodayV4Model

    var body: some View {
        ZStack {
            V4.field.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    heroCard
                    whyCard
                    targetCard
                    sleepCard
                    if !model.watchItems.isEmpty { watchCard } else { allClearCard }
                    directionCard
                    footer
                }
                .padding(.horizontal, V4.pad)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text(model.dateText.uppercased()).v4Micro()
            Spacer(minLength: 8)
            tag(model.provenance, V4.ink3)
            tag(model.confidence, V4.good)
        }
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t.uppercased())
            .font(V4.micro).tracking(0).foregroundStyle(c)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(V4.inset))
    }

    // "Am I recovered?" — NOOP's own BevelGauge (the 3D dial the owner likes), not a flat arc.
    private var heroCard: some View {
        VStack(spacing: 10) {
            BevelGauge(
                fraction: (model.recovery ?? 0) / 100,
                stops: [.init(color: V4.good.opacity(0.85), location: 0),
                        .init(color: V4.good, location: 1)],
                tipColor: V4.good,
                numberText: model.recovery.map { "\(Int($0.rounded()))" } ?? "—",
                captionText: "RECOVERY",
                stateText: model.recoveryState.isEmpty ? nil : model.recoveryState,
                diameter: 176,
                lineWidth: 14,
                animatedFraction: (model.recovery ?? 0) / 100,
                bloomActive: false          // static: no per-frame bloom
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Recovery"))
            .accessibilityValue(
                Text(
                    model.recovery.map {
                        "\(Int($0.rounded())) out of 100, \(model.recoveryState)"
                    } ?? String(localized: "appwide.v4.not_calculated")
                )
            )
        }
        .frame(maxWidth: .infinity)
        .v4Card(18)
    }

    // "Why is it that number?" — the glass-box promise, made visible.
    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("appwide.v4.why").v4Micro()
            VStack(spacing: 0) {
                ForEach(Array(model.drivers.enumerated()), id: \.offset) { i, d in
                    HStack(spacing: 12) {
                        MetricGlyph(d.glyph, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(V4.bodyStrong).foregroundStyle(V4.ink)
                            Text(d.phrase).font(V4.micro).foregroundStyle(V4.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(d.value ?? "—")
                                .font(V4.figure(19))
                                .foregroundStyle(d.value == nil ? V4.ink3 : V4.toneColor(d.tone))
                            if d.value != nil, !d.unit.isEmpty {
                                Text(d.unit).font(V4.micro).foregroundStyle(V4.ink3)
                            }
                        }
                    }
                    .padding(.vertical, 11)
                    .accessibilityElement(children: .combine)
                    if i < model.drivers.count - 1 {
                        Rectangle().fill(V4.hairline).frame(height: 0.5)
                    }
                }
            }
        }
        .v4Card()
    }

    // "What should I do today?" — a concrete number, not vibes.
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("appwide.v4.target").v4Micro()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let lo = model.targetLow, let hi = model.targetHigh {
                    Text(
                        String(
                            format: String(localized: "appwide.range.format"),
                            lo,
                            hi
                        )
                    )
                        .font(V4.figure(34, .bold))
                        .foregroundStyle(V4.ink)
                    Text("EFFORT").font(V4.micro).foregroundStyle(V4.ink3)
                } else {
                    Text("—").font(V4.figure(34, .bold)).foregroundStyle(V4.ink3)
                }
            }
            if !model.targetAction.isEmpty {
                Text(model.targetAction)
                    .font(V4.body).foregroundStyle(V4.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v4Card()
    }

    // "Did I sleep enough?" — the DEFICIT IN MINUTES is the useful number, not a percentage.
    private var sleepCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SLEEP").v4Micro()
                Spacer(minLength: 8)
                if let s = model.sleptMinutes, let n = model.neededMinutes {
                    let gap = n - s
                    Text(
                        gap > 0
                            ? String(
                                format: String(localized: "appwide.v4.sleep.short_format"),
                                gap
                            )
                            : String(localized: "appwide.v4.sleep.met")
                    )
                        .font(V4.micro).tracking(0)
                        .foregroundStyle(gap > 0 ? V4.watch : V4.good)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MetricGlyph("bed.double.fill", size: 30)
                if let s = model.sleptMinutes {
                    Text("\(s / 60)h \(s % 60)m").font(V4.figure(26)).foregroundStyle(V4.ink)
                } else {
                    Text("—").font(V4.figure(26)).foregroundStyle(V4.ink3)
                }
                if let n = model.neededMinutes {
                    Text(
                        String(
                            format: String(localized: "appwide.v4.sleep.need_format"),
                            n / 60,
                            n % 60
                        )
                    )
                    .font(V4.micro)
                    .foregroundStyle(V4.ink3)
                }
            }
            // Stage split as one thin stacked bar — compact and instantly comparable.
            if !model.sleepStages.isEmpty, let s = model.sleptMinutes, s > 0 {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        ForEach(Array(model.sleepStages.enumerated()), id: \.offset) { _, st in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(st.2)
                                .frame(width: max(2, geo.size.width * CGFloat(Double(st.1) / Double(s))))
                        }
                    }
                }
                .frame(height: 8)
                HStack(spacing: 12) {
                    ForEach(Array(model.sleepStages.enumerated()), id: \.offset) { _, st in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5).fill(st.2).frame(width: 7, height: 7)
                            Text(
                                String(
                                    format: String(localized: "appwide.v4.sleep.stage_format"),
                                    st.0,
                                    st.1 / 60,
                                    st.1 % 60
                                )
                            )
                                .font(V4.micro).foregroundStyle(V4.ink3)
                        }
                    }
                }
            }
        }
        .v4Card()
    }

    // "Is anything off?" — shown ONLY when something deviates. Silence is information too.
    private var watchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("appwide.v4.watch").v4Micro()
            ForEach(Array(model.watchItems.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(V4.watch).frame(width: 5, height: 5).padding(.top, 6)
                    Text(item).font(V4.body).foregroundStyle(V4.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v4Card()
    }

    private var allClearCard: some View {
        HStack(spacing: 10) {
            MetricGlyph("checkmark.seal.fill", size: 26)
            Text("appwide.v4.all_clear")
                .font(V4.body).foregroundStyle(V4.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v4Card()
    }

    // "Am I trending up or down?" — one compact strip, direction words for a11y.
    private var directionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("appwide.v4.last_seven_days").v4Micro()
            HStack(spacing: 0) {
                ForEach(Array(model.directions.enumerated()), id: \.offset) { i, d in
                    VStack(spacing: 5) {
                        Text(d.name.uppercased()).font(V4.micro).foregroundStyle(V4.ink3)
                        if let v = d.delta {
                            let good = d.higherIsBetter ? v > 0 : v < 0
                            HStack(spacing: 2) {
                                Image(systemName: v > 0 ? "arrow.up" : "arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(abs(v) < 10 ? String(format: "%.1f", abs(v)) : String(Int(abs(v))))\(d.unit)")
                                    .font(V4.figure(15))
                            }
                            .foregroundStyle(good ? V4.good : V4.watch)
                        } else {
                            Text("—").font(V4.figure(15)).foregroundStyle(V4.ink3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(d.name))
                    .accessibilityValue(Text(directionSpoken(d)))
                    if i < model.directions.count - 1 {
                        Rectangle().fill(V4.hairline).frame(width: 0.5, height: 30)
                    }
                }
            }
        }
        .v4Card()
    }

    private func directionSpoken(_ d: TodayV4Model.Direction) -> String {
        guard let v = d.delta else { return "no data" }
        let good = d.higherIsBetter ? v > 0 : v < 0
        let direction = v > 0
            ? String(localized: "appwide.trend.direction.up")
            : String(localized: "appwide.trend.direction.down")
        let interpretation = good
            ? String(localized: "appwide.trend.interpretation.improving")
            : String(localized: "appwide.trend.interpretation.watch")
        return String(
            format: String(localized: "appwide.trend.seven_day_format"),
            direction,
            abs(v).formatted(),
            d.unit,
            interpretation
        )
    }

    private var footer: some View {
        Text("appwide.disclaimer.estimates")
            .font(V4.micro).foregroundStyle(V4.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Demo

extension TodayV4Model {
    static var demo: TodayV4Model {
        var m = TodayV4Model()
        m.dateText = "Saturday, 22 August"
        m.recovery = 64
        m.recoveryState = "MODERATE"
        m.drivers = [
            .init(glyph: "waveform.path.ecg", name: "HRV", value: "91", unit: "ms",
                  phrase: "Top of your usual range — a good sign", tone: .good),
            .init(glyph: "heart.fill", name: "Resting heart rate", value: "49", unit: "bpm",
                  phrase: "2 bpm below your average", tone: .good),
            .init(glyph: "moon.fill", name: "Sleep quality", value: "88", unit: "/100",
                  phrase: "Efficient night, slightly late bedtime", tone: .neutral),
        ]
        m.targetLow = 8; m.targetHigh = 14
        m.targetAction = "Your body can take a solid session. Aim for a moderate-to-hard effort and keep it under 14 to protect tomorrow."
        m.sleptMinutes = 468          // 7h 48m
        m.neededMinutes = 500         // 8h 20m
        m.sleepStages = [("Deep", 88, V4.violet), ("REM", 118, V4.cool), ("Light", 232, V4.cool.opacity(0.45)), ("Awake", 30, Color.white.opacity(0.18))]
        m.watchItems = [
            "Skin temperature is 0.2 °C above your baseline — worth a look if it climbs again tomorrow."
        ]
        m.directions = [
            .init(name: "Recovery", delta: 4, unit: "", higherIsBetter: true),
            .init(name: "HRV", delta: 6, unit: "ms", higherIsBetter: true),
            .init(name: "Rest HR", delta: -2, unit: "", higherIsBetter: false),
            .init(name: "Sleep", delta: -18, unit: "m", higherIsBetter: true),
        ]
        return m
    }
}

#if DEBUG
struct TodayV4View_Previews: PreviewProvider {
    static var previews: some View { TodayV4View(model: .demo) }
}
#endif
