import SwiftUI

// TodayV3View.swift — "INSTRUMENT" Today (UI v3).
//
// Layout logic, corrected from v2:
//   1. HEADER: date + provenance, one line. No wasted vertical space.
//   2. SCORE ROW: three COMPACT rings (Recovery / Effort / Sleep) side by side — the reference pattern.
//      A viewport should show scores AND content, not one giant arc.
//   3. READ: one plain-language line. Not a boxed "alert" — just typography, like a lab note.
//   4. VITALS: a 2×2 grid where every tile carries value + unit + a VERTICAL range gauge + a STATUS word.
//      This is the single thing that makes Bevel feel like a measuring device, and v2 lacked it.
//   5. LOAD: hour×day grid, sequential ramp, honest empty cells.
//   6. TODAY: compact metric rows (label · value · unit), high density, low ornament.
//   7. FOOTER: the non-medical statement, always.
//
// Everything is static (no per-frame work). Colour appears only as DATA or STATUS.

struct TodayV3Model {
    var dateText = ""
    var provenance = "ON-DEVICE"
    var confidence = "SOLID"

    var recovery: Double?          // 0–100
    var effort: Double?            // 0–100
    var sleep: Double?             // 0–100
    var readLine = ""

    struct Vital {
        var name: String
        var value: Double?
        var unit: String
        var low: Double?           // personal range low
        var high: Double?          // personal range high
        var tint: Color
        /// true when a HIGHER value is the better direction (HRV yes, resting HR no).
        var higherIsBetter: Bool = true
    }
    var vitals: [Vital] = []

    var heatmapHours: [Int] = []
    var heatmapDays: [String] = []
    var heatmapLevel: (Int, Int) -> Double? = { _, _ in nil }
    var heatmapNote: String?

    struct Row { var name: String; var value: String?; var unit: String }
    var rows: [Row] = []

    var trend: [Double] = []
    var trendLabel = "14-DAY RECOVERY"
}

struct TodayV3View: View {
    let model: TodayV3Model

    var body: some View {
        ZStack {
            V3.field.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: V3.sectionGap) {
                    header
                    scoreRow
                    if !model.readLine.isEmpty { readNote }
                    vitalsSection
                    if !model.heatmapDays.isEmpty { loadSection }
                    if !model.trend.isEmpty { trendSection }
                    if !model.rows.isEmpty { rowsSection }
                    footer
                }
                .padding(.horizontal, V3.screenPad)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
    }

    // 1. HEADER — one compact line, no oversized greeting.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.dateText.uppercased())
                .v3MicroLabel()
            Spacer(minLength: 8)
            V3Tag(model.provenance)
            V3Tag(model.confidence, tint: V3.recovery)
        }
    }

    // 2. SCORE ROW — three compact rings, equal weight, in one card.
    private var scoreRow: some View {
        HStack(spacing: 0) {
            V3ScoreRing(label: "RECOVERY", value: model.recovery, tint: V3.recovery)
            divider
            V3ScoreRing(label: "EFFORT", value: model.effort, tint: V3.effort)
            divider
            V3ScoreRing(label: "SLEEP", value: model.sleep, tint: V3.sleep)
        }
        .v3Card(padding: 16)
    }

    private var divider: some View {
        Rectangle().fill(V3.hairline).frame(width: 0.5, height: 62)
    }

    // 3. READ — a lab note, not an alert box.
    private var readNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("appwide.v3.read").v3MicroLabel()
            Text(model.readLine)
                .font(V3.body)
                .foregroundStyle(V3.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    // 4. VITALS — the instrument grid: value + unit + vertical range gauge + status word.
    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: V3.stackGap) {
            sectionHeader("VITALS", trailing: "vs your 30-day range")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: V3.gridGap),
                                GridItem(.flexible(), spacing: V3.gridGap)],
                      spacing: V3.gridGap) {
                ForEach(Array(model.vitals.enumerated()), id: \.offset) { _, v in
                    V3VitalTile(vital: v)
                }
            }
        }
    }

    // 5. LOAD — hour × day grid.
    private var loadSection: some View {
        VStack(alignment: .leading, spacing: V3.stackGap) {
            sectionHeader("LOAD", trailing: "this week")
            V3LoadGrid(hours: model.heatmapHours,
                       dayLabels: model.heatmapDays,
                       level: model.heatmapLevel,
                       note: model.heatmapNote)
                .v3Card()
        }
    }

    // 6. TREND — a real plot with a mean reference, not a decorative squiggle.
    private var trendSection: some View {
        VStack(alignment: .leading, spacing: V3.stackGap) {
            sectionHeader(model.trendLabel, trailing: "mean shown")
            V3TrendPlot(points: model.trend, tint: V3.recovery)
                .v3Card()
        }
    }

    // 7. TODAY ROWS — dense list, minimal ornament.
    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: V3.stackGap) {
            sectionHeader("TODAY", trailing: nil)
            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text(r.name)
                            .font(V3.body)
                            .foregroundStyle(V3.inkSecondary)
                        Spacer(minLength: 8)
                        Text(r.value ?? "—")
                            .font(V3.figure(17, .semibold))
                            .foregroundStyle(r.value == nil ? V3.inkTertiary : V3.ink)
                        if r.value != nil, !r.unit.isEmpty {
                            Text(r.unit).font(V3.unit).foregroundStyle(V3.inkTertiary)
                        }
                    }
                    .padding(.vertical, 11)
                    if i < model.rows.count - 1 {
                        Rectangle().fill(V3.hairline).frame(height: 0.5)
                    }
                }
            }
            .padding(.horizontal, V3.cardPad)
            .background(RoundedRectangle(cornerRadius: V3.cardRadius, style: .continuous).fill(V3.surface))
            .overlay(
                RoundedRectangle(cornerRadius: V3.cardRadius, style: .continuous)
                    .stroke(V3.hairline, lineWidth: 0.5)
            )
        }
    }

    private var footer: some View {
        Text("appwide.disclaimer.estimates")
            .font(V3.micro)
            .foregroundStyle(V3.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).v3MicroLabel()
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(V3.micro).foregroundStyle(V3.inkFaint)
            }
        }
    }
}

// MARK: - Components

/// A small tag (provenance / confidence). Inset surface, micro caps.
struct V3Tag: View {
    let text: String
    var tint: Color = V3.inkTertiary
    init(_ text: String, tint: Color = V3.inkTertiary) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text.uppercased())
            .font(V3.micro)
            .tracking(0)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(V3.surfaceInset))
    }
}

/// One compact score ring. Thin stroke, figure inside, micro label under. Equal weight to its siblings.
struct V3ScoreRing: View {
    let label: String
    let value: Double?
    let tint: Color
    var size: CGFloat = 62

    private var frac: Double { value.map { min(1, max(0, $0 / 100)) } ?? 0 }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(V3.surfaceInset, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: frac)
                    .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(V3.figure(21, .semibold))
                    .foregroundStyle(value == nil ? V3.inkTertiary : V3.ink)
            }
            .frame(width: size, height: size)
            Text(label).v3MicroLabel()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label.capitalized))
        .accessibilityValue(Text(value.map { "\(Int($0.rounded())) out of 100" } ?? "no data"))
    }
}

/// The instrument tile: micro name, big figure + unit, a VERTICAL personal-range gauge, and a STATUS word.
/// This is the pattern that makes a screen read as a measuring device rather than a dashboard.
struct V3VitalTile: View {
    let vital: TodayV3Model.Vital

    private var status: V3.Status {
        guard let v = vital.value else { return .noData }
        guard let lo = vital.low, let hi = vital.high, hi > lo else { return .calibrating }
        if v < lo { return .low }
        if v > hi { return .high }
        return .normal
    }

    /// Position of the value inside the drawn scale (padded personal range), 0…1 bottom→top.
    private var pos: Double? {
        guard let v = vital.value, let lo = vital.low, let hi = vital.high, hi > lo else { return nil }
        let pad = (hi - lo) * 0.45
        let sLo = lo - pad, sHi = hi + pad
        return min(1, max(0, (v - sLo) / (sHi - sLo)))
    }

    /// Band extent inside the scale.
    private var band: (lo: Double, hi: Double)? {
        guard let lo = vital.low, let hi = vital.high, hi > lo else { return nil }
        let pad = (hi - lo) * 0.45
        let sLo = lo - pad, sHi = hi + pad
        return ((lo - sLo) / (sHi - sLo), (hi - sLo) / (sHi - sLo))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(vital.name.uppercased()).v3MicroLabel()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(vital.value.map { $0 < 10 ? String(format: "%.1f", $0) : String(Int($0.rounded())) } ?? "—")
                        .font(V3.figure(24, .semibold))
                        .foregroundStyle(vital.value == nil ? V3.inkTertiary : V3.ink)
                    Text(vital.unit).font(V3.unit).foregroundStyle(V3.inkTertiary)
                }
                Text(status.rawValue)
                    .font(V3.micro)
                    .tracking(0)
                    .foregroundStyle(status.color)
            }
            Spacer(minLength: 0)
            // Vertical scale: track, personal-range band, value marker.
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2.5).fill(V3.surfaceInset).frame(width: 5)
                    if let b = band {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(vital.tint.opacity(0.30))
                            .frame(width: 5, height: max(3, h * (b.hi - b.lo)))
                            .offset(y: -h * b.lo)
                    }
                    if let p = pos {
                        // A wide tick, not a draggable-looking dot.
                        RoundedRectangle(cornerRadius: 1)
                            .fill(V3.ink)
                            .frame(width: 13, height: 2.5)
                            .offset(y: -(h * p) + 1.25)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(width: 16, height: 62)
        }
        .v3Card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(vital.name))
        .accessibilityValue(Text(spoken))
    }

    private var spoken: String {
        guard let v = vital.value else { return "no data" }
        let head = "\(v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))) \(vital.unit)"
        guard let lo = vital.low, let hi = vital.high else { return "\(head), not enough baseline yet" }
        let range = "your usual range \(Int(lo)) to \(Int(hi))"
        switch status {
        case .low: return "\(head), below \(range)"
        case .high: return "\(head), above \(range)"
        default: return "\(head), inside \(range)"
        }
    }
}

/// Hour × day load grid. Sequential cool→warm ramp (never the domain hues), lightness-ordered so it
/// survives greyscale/colour-vision deficiency. Unscored cells stay empty — a gap must look like a gap.
struct V3LoadGrid: View {
    let hours: [Int]
    let dayLabels: [String]
    let level: (Int, Int) -> Double?
    var note: String?

    static func color(_ v: Double?) -> Color {
        guard let v else { return V3.surfaceInset.opacity(0.55) }
        if v < 0.75 { return Color(red: 0.16, green: 0.31, blue: 0.52) }
        if v < 1.50 { return Color(red: 0.20, green: 0.55, blue: 0.60) }
        if v < 2.25 { return Color(red: 0.85, green: 0.71, blue: 0.30) }
        return Color(red: 0.92, green: 0.44, blue: 0.23)
    }
    static func word(_ v: Double?) -> String {
        guard let v else { return "no data" }
        if v < 0.75 { return "lowest" }
        if v < 1.50 { return "low" }
        if v < 2.25 { return "mid" }
        return "high"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 2) {
                Text("").frame(width: 22)
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, d in
                    Text(d).font(V3.micro).foregroundStyle(V3.inkTertiary).frame(maxWidth: .infinity)
                }
            }
            ForEach(hours, id: \.self) { h in
                HStack(spacing: 2) {
                    Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                        .font(V3.micro).foregroundStyle(V3.inkTertiary)
                        .frame(width: 22, alignment: .trailing)
                    ForEach(0..<dayLabels.count, id: \.self) { d in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Self.color(level(h, d)))
                            .frame(height: 15)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(rowSpoken(h)))
            }
            HStack(spacing: 9) {
                ForEach(["lowest", "low", "mid", "high", "no data"], id: \.self) { w in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Self.color(w == "no data" ? nil : (w == "lowest" ? 0.3 : w == "low" ? 1.0 : w == "mid" ? 1.8 : 2.6)))
                            .frame(width: 8, height: 8)
                        Text(w).font(V3.micro).foregroundStyle(V3.inkTertiary)
                    }
                }
            }
            .padding(.top, 1)
            .accessibilityHidden(true)
            if let note {
                Text(note)
                    .font(V3.body)
                    .foregroundStyle(V3.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }

    private func rowSpoken(_ h: Int) -> String {
        let hourText = h == 0 ? "12 AM" : (h < 12 ? "\(h) AM" : (h == 12 ? "12 PM" : "\(h - 12) PM"))
        var words: [String] = []
        for d in 0..<dayLabels.count { words.append(Self.word(level(h, d))) }
        let scored = words.filter { $0 != "no data" }
        if scored.isEmpty { return "\(hourText): no data" }
        let dominant = Dictionary(grouping: scored, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? "mid"
        let empties = words.count - scored.count
        return empties > 0 ? "\(hourText): mostly \(dominant), \(empties) with no data" : "\(hourText): mostly \(dominant)"
    }
}

/// A real plot: min/max ticks, a dashed mean reference, and the latest point marked.
struct V3TrendPlot: View {
    let points: [Double]
    var tint: Color = V3.recovery
    var height: CGFloat = 64

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                if points.count > 1, let lo = points.min(), let hi = points.max(), hi > lo {
                    let mean = points.reduce(0, +) / Double(points.count)
                    let y = { (v: Double) in h - CGFloat((v - lo) / (hi - lo)) * h }
                    ZStack(alignment: .topLeading) {
                        Path { p in
                            p.move(to: .init(x: 0, y: y(mean)))
                            p.addLine(to: .init(x: w, y: y(mean)))
                        }
                        .stroke(V3.inkFaint, style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        Path { p in
                            let step = w / CGFloat(points.count - 1)
                            for (i, v) in points.enumerated() {
                                let pt = CGPoint(x: CGFloat(i) * step, y: y(v))
                                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                            }
                        }
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                        if let last = points.last {
                            Circle().fill(tint).frame(width: 5, height: 5)
                                .offset(x: w - 2.5, y: y(last) - 2.5)
                        }
                    }
                }
            }
            .frame(height: height)
            // Scale ticks — visible units are part of the instrument language.
            if let lo = points.min(), let hi = points.max() {
                VStack(alignment: .leading) {
                    Text("\(Int(hi.rounded()))").font(V3.micro).foregroundStyle(V3.inkTertiary)
                    Spacer(minLength: 0)
                    Text("\(Int(lo.rounded()))").font(V3.micro).foregroundStyle(V3.inkTertiary)
                }
                .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trend"))
        .accessibilityValue(Text(spoken))
    }

    private var spoken: String {
        guard points.count > 1, let f = points.first, let l = points.last else { return "no data" }
        let mean = points.reduce(0, +) / Double(points.count)
        let dir = l > f ? "rising" : (l < f ? "falling" : "flat")
        return "\(dir), latest \(Int(l.rounded())), \(l > mean ? "above" : "below") your average of \(Int(mean.rounded()))"
    }
}

// MARK: - Demo

extension TodayV3Model {
    static var demo: TodayV3Model {
        var m = TodayV3Model()
        m.dateText = "Saturday, 22 August"
        m.recovery = 64; m.effort = 41; m.sleep = 88
        m.readLine = "Sleep was strong and HRV sits at the top of your range. A moderate-to-hard session is well supported today."
        m.vitals = [
            .init(name: "HRV (RMSSD)", value: 91, unit: "ms", low: 62, high: 96, tint: V3.recovery),
            .init(name: "Resting HR", value: 49, unit: "bpm", low: 48, high: 60, tint: V3.sleep, higherIsBetter: false),
            .init(name: "Respiratory", value: 14.2, unit: "rpm", low: 12.5, high: 16, tint: V3.loadViolet, higherIsBetter: false),
            .init(name: "Blood oxygen", value: 97.4, unit: "%", low: 95, high: 99, tint: V3.recovery),
        ]
        m.heatmapHours = Array(6..<22)
        m.heatmapDays = ["M", "T", "W", "T", "F", "S", "S"]
        var grid: [Int: [Int: Double]] = [:]
        for h in 6..<22 {
            var row: [Int: Double] = [:]
            for d in 0..<7 {
                if d == 6 && h > 12 { continue }
                var v = 0.65 + Double((h * 5 + d) % 4) * 0.2
                if (13...17).contains(h) { v += 0.75 }
                if d == 2 && (13...17).contains(h) { v += 0.8 }
                if h >= 20 { v = 0.4 }
                row[d] = min(3, v)
            }
            grid[h] = row
        }
        m.heatmapLevel = { h, d in grid[h]?[d] }
        m.heatmapNote = "Load peaks mid-afternoon and settles after 20:00. Wednesday ran hottest."
        m.trend = [52, 58, 61, 49, 55, 63, 66, 60, 57, 65, 69, 62, 61, 64]
        m.rows = [
            .init(name: "Sleep duration", value: "7.8", unit: "h"),
            .init(name: "Steps", value: "6,420", unit: ""),
            .init(name: "Calories", value: "2,810", unit: "kcal"),
            .init(name: "Hydration", value: "1.4", unit: "of 3.0 L"),
            .init(name: "Skin temp", value: "+0.2", unit: "°C vs base"),
            .init(name: "Weight", value: nil, unit: "kg"),
        ]
        return m
    }
}

#if DEBUG
struct TodayV3View_Previews: PreviewProvider {
    static var previews: some View { TodayV3View(model: .demo) }
}
#endif
