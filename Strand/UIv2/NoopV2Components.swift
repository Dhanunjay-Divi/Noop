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
                    .tracking(1.1)
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
            .tracking(0.7)
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
            // Arc group ONLY is rotated (135° puts the 270° sweep's gap centred at the bottom).
            // The readout must NOT inherit this rotation, so it lives in a sibling layer.
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.07),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(NoopV2.ramp(base, tip),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .shadow(color: base.opacity(0.55), radius: 14)
            }
            .rotationEffect(.degrees(135))

            // Upright readout
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
                    .tracking(1.4)
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
    }
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
                    .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 8, lineCap: .round))
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
                .tracking(0.9)
                .foregroundStyle(NoopV2.inkTertiary)
        }
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
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07)).frame(height: 7)
                    if let lo = rangeLow, let hi = rangeHigh, scale != nil, hi > lo {
                        let x = pos(lo, in: w)
                        Capsule()
                            .fill(tint.opacity(0.28))
                            .frame(width: Swift.max(3, pos(hi, in: w) - x), height: 7)
                            .offset(x: x)
                    }
                    if let v = value, scale != nil {
                        Circle()
                            .fill(tint)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 2))
                            .shadow(color: tint.opacity(0.7), radius: 6)
                            .offset(x: Swift.max(0, Swift.min(w - 13, pos(v, in: w) - 6.5)))
                    }
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            if let statusText {
                Text(statusText)
                    .font(NoopV2.overline)
                    .foregroundStyle(NoopV2.inkTertiary)
            }
        }
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
                    .tracking(0.8)
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
                    .tracking(1.0)
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

    private func color(_ v: Double?) -> Color {
        guard let v else { return Color.white.opacity(0.045) }
        if v < 1 { return NoopV2.rest.opacity(0.75) }        // calm  → indigo
        if v < 2 { return NoopV2.charge.opacity(0.80) }      // mid   → mint
        return NoopV2.effort.opacity(0.92)                   // high  → amber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text("").frame(width: 26)
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(hours, id: \.self) { h in
                HStack(spacing: 5) {
                    Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(NoopV2.inkTertiary)
                        .frame(width: 26, alignment: .trailing)
                    ForEach(0..<dayLabels.count, id: \.self) { d in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(level(h, d)))
                            .frame(height: 11)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            HStack(spacing: 10) {
                legend("Calm", NoopV2.rest)
                legend("Mid", NoopV2.charge)
                legend("High", NoopV2.effort)
                legend("No data", Color.white.opacity(0.10))
            }
            .padding(.top, 2)
            if let caption {
                Text(caption)
                    .font(NoopV2.caption)
                    .foregroundStyle(NoopV2.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t).font(.system(size: 9)).foregroundStyle(NoopV2.inkTertiary)
        }
    }
}

// MARK: - Sparkline (static path, no animation)

struct V2Sparkline: View {
    let points: [Double]
    var tint: Color = NoopV2.charge
    var height: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            if points.count > 1,
               let lo = points.min(), let hi = points.max(), hi > lo {
                let step = w / CGFloat(points.count - 1)
                Path { p in
                    for (i, v) in points.enumerated() {
                        let x = CGFloat(i) * step
                        let y = h - CGFloat((v - lo) / (hi - lo)) * h
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(NoopV2.ramp(tint, tint.opacity(0.6)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else {
                Capsule().fill(Color.white.opacity(0.07)).frame(height: 2).offset(y: h / 2)
            }
        }
        .frame(height: height)
    }
}
