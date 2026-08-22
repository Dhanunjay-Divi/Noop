import SwiftUI

// NoopV2Components.swift — the v2 component library (UI v2 "Aurora").
//
// Every component here is STATIC (no TimelineView / Canvas physics / CoreMotion): depth comes from
// layered translucency, gradient strokes and soft shadows. That is deliberate — it is what makes v2 both
// look more premium than v1 and cost almost nothing per frame (the v1 liquid sims are the prime suspect
// for the reported lag).
//
// Honesty is a first-class citizen: every component that can show a value can also show "no data"
// truthfully (nil ⇒ an em-dash and a muted state, never a fabricated 0), and provenance/confidence chips
// are part of the library rather than an afterthought.

// MARK: - Section header

struct V2SectionHeader: View {
    let overline: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(overline.uppercased())
                    .font(NoopV2.overline)
                    .tracking(0)
                    .foregroundStyle(NoopV2.inkTertiary)
                Text(title)
                    .font(NoopV2.title)
                    .foregroundStyle(NoopV2.ink)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(NoopV2.caption)
                    .foregroundStyle(NoopV2.inkTertiary)
            }
        }
    }
}

// MARK: - Chips

/// A small provenance / confidence / status chip. This is NOOP's trust signal — kept prominent in v2.
struct V2Chip: View {
    let text: String
    var tone: Color = NoopV2.inkSecondary
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(NoopV2.overline)
            .tracking(0)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: NoopV2.chipRadius, style: .continuous)
                    .fill(filled ? tone.opacity(0.92) : tone.opacity(0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: NoopV2.chipRadius, style: .continuous)
                    .stroke(filled ? .clear : tone.opacity(0.22), lineWidth: 1)
            )
    }
}

/// A delta chip ("+3 vs baseline"). `nil` delta renders nothing at all rather than a fake zero.
struct V2DeltaChip: View {
    let delta: Double?
    var unit: String = ""
    /// When true, a HIGHER value is better (recovery); when false, LOWER is better (resting HR).
    var higherIsBetter: Bool = true

    var body: some View {
        if let d = delta, d.isFinite, abs(d) > 0.0001 {
            let good = higherIsBetter ? d > 0 : d < 0
            let tone = good ? NoopV2.positive : NoopV2.warning
            let direction = d > 0
                ? String(localized: "appwide.trend.direction.up")
                : String(localized: "appwide.trend.direction.down")
            let value = abs(d).formatted(
                .number.precision(.fractionLength(abs(d) < 10 ? 1 : 0))
            )
            let interpretation = good
                ? String(localized: "appwide.trend.interpretation.improving")
                : String(localized: "appwide.trend.interpretation.watch")
            HStack(spacing: 3) {
                Image(systemName: d > 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(abs(d), specifier: abs(d) < 10 ? "%.1f" : "%.0f")\(unit)")
                    .font(NoopV2.overline)
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.14)))
            // A11Y: speak a DIRECTION WORD and an interpretation — an arrow glyph alone is not accessible,
            // and colour alone must never carry the good/bad meaning.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Text(
                    String(
                        format: String(localized: "appwide.trend.baseline_format"),
                        direction,
                        value,
                        unit,
                        interpretation
                    )
                )
            )
        }
    }
}

// MARK: - Hero arc

/// The v2 hero: ONE large focal arc. v1 showed three equal rings competing for attention; v2 gives the
/// day a single headline and demotes the rest to satellites, which is the single biggest hierarchy win.
///
/// `value` is 0…1 of `max`; `nil` renders the honest calibrating state (dashed track, em-dash, no number).
struct V2HeroArc: View {
    let label: String
    let value: Double?            // 0…max, nil = no score yet
    var max: Double = 100
    var unit: String = ""
    let base: Color
    let tip: Color
    var caption: String? = nil
    var size: CGFloat = 232

    private var fraction: Double {
        guard let v = value, max > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, v / max))
    }

    var body: some View {
        ZStack {
            // ⚠️ C1 LOAD-BEARING LAYOUT — DO NOT WRAP THESE TWO LAYERS IN A SHARED MODIFIER.
            // The arc group ONLY is rotated (135° puts the 270° sweep's gap centred at the bottom). The
            // readout is a SIBLING layer precisely so it does not inherit that rotation. An earlier build
            // applied `.rotationEffect` to the whole ZStack and added a second un-rotated overlay, which
            // rendered the number TWICE — once mirrored and garbled (see noop_WIP/screenshots/v2/
            // todayv2_01.png for the evidence). Any refactor that re-nests these reintroduces that bug;
            // `V2HeroArcSnapshotContract` below documents the invariant.
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(NoopV2.decorationFaint.opacity(0.16),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(NoopV2.ramp(base, tip),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .shadow(color: base.opacity(0.55), radius: 14)
            }
            .rotationEffect(.degrees(135))

            // Upright readout (sibling — see C1 note above)
            VStack(spacing: 2) {
                if let v = value {
                    Text("\(Int(v.rounded()))")
                        .font(NoopV2.number(64, .bold))
                        .foregroundStyle(NoopV2.ink)
                } else {
                    Text("—")
                        .font(NoopV2.number(52, .bold))
                        .foregroundStyle(NoopV2.inkTertiary)
                }
                if !unit.isEmpty, value != nil {
                    Text(unit)
                        .font(NoopV2.caption)
                        .foregroundStyle(NoopV2.inkTertiary)
                }
                Text(label.uppercased())
                    .font(NoopV2.overline)
                    .tracking(0)
                    .foregroundStyle(NoopV2.inkSecondary)
                    .padding(.top, 2)
                if let caption {
                    Text(caption)
                        .font(NoopV2.caption)
                        .foregroundStyle(base)
                        .padding(.top, 1)
                }
            }
        }
        .frame(width: size, height: size)
        // A11Y: one element, spoken as data. Never expose an adjustable trait — this is a readout.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibilityReadout))
    }

    /// Spoken value: "64 out of 100, moderate" / "not yet calculated, calibrating".
    private var accessibilityReadout: String {
        guard let v = value else {
            return caption.map { "not yet calculated, \($0)" } ?? "not yet calculated"
        }
        let head = "\(Int(v.rounded())) out of \(Int(max))"
        return caption.map { "\(head), \($0)" } ?? head
    }
}

/// Documents the C1 invariant for the snapshot test that locks it (see ROUND-12).
enum V2HeroArcSnapshotContract {
    /// The hero must render EXACTLY ONE upright readout. If a future refactor nests the readout inside the
    /// rotated arc group (or re-adds an overlay copy), the snapshot diff catches the double/rotated render.
    static let expectedReadoutCount = 1
}

/// A compact satellite ring for the two non-headline scores.
struct V2SatelliteRing: View {
    let label: String
    let value: Double?
    var max: Double = 100
    let base: Color
    let tip: Color
    var size: CGFloat = 82

    private var fraction: Double {
        guard let v = value, max > 0 else { return 0 }
        return Swift.min(1, Swift.max(0, v / max))
    }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(NoopV2.decorationFaint.opacity(0.16), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(NoopV2.ramp(base, tip), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: base.opacity(0.45), radius: 7)
                if let v = value {
                    Text("\(Int(v.rounded()))")
                        .font(NoopV2.number(23, .bold))
                        .foregroundStyle(NoopV2.ink)
                } else {
                    Text("—")
                        .font(NoopV2.number(20, .bold))
                        .foregroundStyle(NoopV2.inkTertiary)
                }
            }
            .frame(width: size, height: size)
            Text(label.uppercased())
                .font(NoopV2.overline)
                .tracking(0)
                .foregroundStyle(NoopV2.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.map { "\(Int($0.rounded())) out of \(Int(max))" } ?? "no data"))
    }
}

// MARK: - Range gauge (the best idea from the Bevel reference)

/// "Where you sit inside YOUR OWN normal range" — the question a bare number never answers.
/// The band is the personal range (e.g. p10…p90 of the user's own baseline), the dot is today.
/// `value == nil` ⇒ muted track, em-dash, no dot. Never invents a position.
struct V2RangeGauge: View {
    let title: String
    let value: Double?
    let unit: String
    /// Personal range low/high in the same unit as `value`.
    let rangeLow: Double?
    let rangeHigh: Double?
    /// Full scale for the track (defaults to a padded version of the range).
    var scaleLow: Double? = nil
    var scaleHigh: Double? = nil
    var tint: Color = NoopV2.charge
    var statusText: String? = nil

    private var scale: (lo: Double, hi: Double)? {
        let lo = scaleLow ?? rangeLow.map { $0 - (abs($0) * 0.35 + 1) }
        let hi = scaleHigh ?? rangeHigh.map { $0 + (abs($0) * 0.35 + 1) }
        guard let lo, let hi, hi > lo else { return nil }
        return (lo, hi)
    }

    private func pos(_ v: Double, in width: CGFloat) -> CGFloat {
        guard let s = scale else { return 0 }
        let f = Swift.min(1, Swift.max(0, (v - s.lo) / (s.hi - s.lo)))
        return width * CGFloat(f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(NoopV2.caption)
                    .foregroundStyle(NoopV2.inkSecondary)
                Spacer(minLength: 4)
                if let v = value {
                    Text("\(v, specifier: abs(v) < 10 ? "%.1f" : "%.0f")")
                        .font(NoopV2.number(19, .bold))
                        .foregroundStyle(NoopV2.ink)
                    Text(unit)
                        .font(NoopV2.overline)
                        .foregroundStyle(NoopV2.inkTertiary)
                } else {
                    Text("—")
                        .font(NoopV2.number(19, .bold))
                        .foregroundStyle(NoopV2.inkTertiary)
                }
            }
            // C3 FIX: this is a READOUT, not a control. The old thin-track + glowing round dot was visually
            // identical to a `Slider` thumb, so users tried to drag it (affordance mismatch reads as broken).
            // Now: the personal-range BAND is the hero (taller, clearly a zone), the track is a thin rule,
            // and "you" is a CARET/tick that sits above the band rather than sitting in it like a thumb.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Thin full-scale rule
                    Capsule()
                        .fill(NoopV2.decorationFaint.opacity(0.14))
                        .frame(height: 4)
                        .offset(y: 5)
                    // The personal range band — the hero of this component
                    if let lo = rangeLow, let hi = rangeHigh, scale != nil, hi > lo {
                        let x = pos(lo, in: w)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tint.opacity(0.30))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(tint.opacity(0.45), lineWidth: 1)
                            )
                            .frame(width: Swift.max(4, pos(hi, in: w) - x), height: 14)
                            .offset(x: x)
                    }
                    // "You are here" caret — a downward triangle above the band. Deliberately NOT a circle.
                    if let v = value, scale != nil {
                        V2Caret()
                            .fill(NoopV2.ink)
                            .frame(width: 9, height: 6)
                            .offset(x: Swift.max(0, Swift.min(w - 9, pos(v, in: w) - 4.5)), y: -8)
                    }
                }
                .frame(height: 22)
            }
            .frame(height: 22)
            if let status = statusText {
                Text(status)
                    .font(NoopV2.overline)
                    .foregroundStyle(NoopV2.inkTertiary)
            }
        }
        // A11Y: read as data with an explicit range; no adjustable trait (reinforces C3).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(accessibilitySpoken))
    }

    private var accessibilitySpoken: String {
        guard let v = value else { return "no data" }
        let head = "\(v.formatted(.number.precision(.fractionLength(abs(v) < 10 ? 1 : 0)))) \(unit)"
        guard let lo = rangeLow, let hi = rangeHigh else { return "\(head). Not enough baseline yet." }
        let loS = lo.formatted(.number.precision(.fractionLength(0)))
        let hiS = hi.formatted(.number.precision(.fractionLength(0)))
        if v < lo { return "\(head). Below your usual range of \(loS) to \(hiS)." }
        if v > hi { return "\(head). Above your usual range of \(loS) to \(hiS)." }
        return "\(head). Inside your usual range of \(loS) to \(hiS)."
    }
}

/// A small downward caret ("you are here"), used instead of a round thumb so the range gauge cannot be
/// mistaken for an interactive slider (C3).
struct V2Caret: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Stat tile

struct V2StatTile: View {
    let label: String
    let value: String?
    var unit: String = ""
    var tint: Color = NoopV2.inkSecondary
    var delta: Double? = nil
    var higherIsBetter: Bool = true
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(label.uppercased())
                    .font(NoopV2.overline)
                    .tracking(0)
                    .foregroundStyle(NoopV2.inkTertiary)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—")
                    .font(NoopV2.number(26, .bold))
                    .foregroundStyle(value == nil ? NoopV2.inkTertiary : NoopV2.ink)
                if !unit.isEmpty, value != nil {
                    Text(unit)
                        .font(NoopV2.caption)
                        .foregroundStyle(NoopV2.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            V2DeltaChip(delta: delta, higherIsBetter: higherIsBetter)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card(padding: 14, radius: NoopV2.tileRadius)
    }
}

// MARK: - Coaching banner ("the one thing that matters today")

/// v2's answer to "a score with no guidance is just a number". One clear line, one optional action.
struct V2CoachBanner: View {
    let overline: String
    let message: String
    var tint: Color = NoopV2.charge
    var actionTitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                Text(overline.uppercased())
                    .font(NoopV2.overline)
                    .tracking(0)
            }
            .foregroundStyle(tint)
            Text(message)
                .font(NoopV2.headline)
                .foregroundStyle(NoopV2.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Text(actionTitle)
                    .font(NoopV2.overline)
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(tint))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .v2Card()
        .overlay(alignment: .leading) {
            // A domain-tinted spine so the banner reads as guidance, not another metric card.
            RoundedRectangle(cornerRadius: 2)
                .fill(NoopV2.ramp(tint, tint.opacity(0.5)))
                .frame(width: 3)
                .padding(.vertical, 14)
                .padding(.leading, 1)
        }
    }
}

// MARK: - Heatmap (consumes the R7 StressHeatmap engine)

/// Week×hour load heatmap. Cells with no signal stay EMPTY (a faint outline) — the engine returns nil and
/// the view respects it, so sparse wear looks sparse instead of calm.
struct V2Heatmap: View {
    /// Row-major cells: `levels[hour][dayIndex]` = 0…3 or nil.
    let hours: [Int]
    let dayLabels: [String]
    let level: (Int, Int) -> Double?   // (hour, dayIndex) -> level
    var caption: String? = nil

    // C4 FIX: use the dedicated SEQUENTIAL load ramp, not the domain hues. Reusing mint (= recovery/good
    // elsewhere) for "mid load" made a mid-stress week look calm. The ramp is ordered by lightness as well
    // as hue, so it survives greyscale and colour-vision deficiency — colour is never the only channel, and
    // the legend spells the buckets out in words.
    private func color(_ v: Double?) -> Color { NoopV2.loadRampColor(v) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text("").frame(width: 26)
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            // Tighter corners + smaller gaps so this reads as a GRID, not stacked pill bars (C4 note).
            ForEach(hours, id: \.self) { h in
                HStack(spacing: 2) {
                    Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(width: 26, alignment: .trailing)
                    ForEach(0..<dayLabels.count, id: \.self) { d in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color(level(h, d)))
                            .frame(height: 17)
                            .frame(maxWidth: .infinity)
                    }
                }
                // A11Y: one element PER ROW (never 7×16 cells). "3 PM: mostly high, no data Sunday."
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(rowSpoken(h)))
            }
            legendRow
            if let caption {
                Text(caption)
                    .font(NoopV2.caption)
                    .foregroundStyle(NoopV2.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A11Y: a single summary element comes first so VoiceOver users get the insight immediately.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(summarySpoken))
    }

    private var legendRow: some View {
        HStack(spacing: 10) {
            legend("Lowest", NoopV2.loadRamp0)
            legend("Low", NoopV2.loadRamp1)
            legend("Mid", NoopV2.loadRamp2)
            legend("High", NoopV2.loadRamp3)
            legend("No data", NoopV2.loadRampEmpty)
        }
        .padding(.top, 2)
        .accessibilityHidden(true)   // the words are already in the row/summary labels
    }

    /// "3 PM: mid Monday to Friday, no data Sunday" — bucket words, never colour names.
    private func rowSpoken(_ h: Int) -> String {
        var buckets: [String] = []
        for d in 0..<dayLabels.count {
            buckets.append(NoopV2.loadRampLabel(level(h, d)))
        }
        let hourText = h == 0 ? "12 AM" : (h < 12 ? "\(h) AM" : (h == 12 ? "12 PM" : "\(h - 12) PM"))
        // Collapse to the dominant bucket + count of empty days, so it stays listenable.
        let empties = buckets.filter { $0 == "no data" }.count
        let scored = buckets.filter { $0 != "no data" }
        let dominant = Dictionary(grouping: scored, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key ?? "no data"
        if scored.isEmpty { return "\(hourText): no data" }
        return empties > 0
            ? "\(hourText): mostly \(dominant), \(empties) day\(empties == 1 ? "" : "s") with no data"
            : "\(hourText): mostly \(dominant)"
    }

    private var summarySpoken: String {
        let base = "Load heatmap by hour and day."
        var empties = 0
        for h in hours { for d in 0..<dayLabels.count where level(h, d) == nil { empties += 1 } }
        let gap = empties > 0 ? " \(empties) hour-slots had no data." : ""
        return caption.map { "\(base) \($0)\(gap)" } ?? "\(base)\(gap)"
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(.system(size: 10)).foregroundStyle(NoopV2.inkTertiary)
        }
    }
}

// MARK: - Sparkline (static path, no animation)

/// C7 FIX: the sparkline was decorative — no baseline, no "today", no scale, so it carried no information.
/// It now draws the personal mean as a dashed rule and marks the latest point, which is what makes a
/// 14-day trace readable at a glance ("am I above or below my own normal, and where am I now?").
struct V2Sparkline: View {
    let points: [Double]
    var tint: Color = NoopV2.charge
    var height: CGFloat = 34
    /// Show the dashed personal-mean baseline + terminal "today" dot.
    var showContext: Bool = true
    /// Optional label for VoiceOver ("14-day recovery trend").
    var accessibilityTitle: String? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if points.count > 1,
               let lo = points.min(), let hi = points.max(), hi > lo {
                let step = w / CGFloat(points.count - 1)
                let mean = points.reduce(0, +) / Double(points.count)
                let meanY = h - CGFloat((mean - lo) / (hi - lo)) * h
                ZStack(alignment: .topLeading) {
                    if showContext {
                        // Personal mean — the reference the trace is judged against.
                        Path { p in
                            p.move(to: .init(x: 0, y: meanY))
                            p.addLine(to: .init(x: w, y: meanY))
                        }
                        .stroke(NoopV2.decorationFaint.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    Path { p in
                        for (i, v) in points.enumerated() {
                            let x = CGFloat(i) * step
                            let y = h - CGFloat((v - lo) / (hi - lo)) * h
                            i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                        }
                    }
                    .stroke(NoopV2.ramp(tint, tint.opacity(0.6)),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if showContext, let last = points.last {
                        let y = h - CGFloat((last - lo) / (hi - lo)) * h
                        Circle()
                            .fill(tint)
                            .frame(width: 6, height: 6)
                            .offset(x: w - 3, y: y - 3)
                    }
                }
            } else {
                Capsule().fill(NoopV2.decorationFaint.opacity(0.16)).frame(height: 2).offset(y: h / 2)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityTitle ?? "Trend"))
        .accessibilityValue(Text(trendSpoken))
    }

    private var trendSpoken: String {
        guard points.count > 1, let first = points.first, let last = points.last else { return "no data" }
        let mean = points.reduce(0, +) / Double(points.count)
        let dir = last > first ? "rising" : (last < first ? "falling" : "flat")
        let vsMean = last > mean ? "above" : (last < mean ? "below" : "at")
        return "\(dir), latest \(Int(last.rounded())), \(vsMean) your \(points.count)-point average of \(Int(mean.rounded()))"
    }
}
