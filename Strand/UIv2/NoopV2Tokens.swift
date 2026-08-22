import SwiftUI

// NoopV2Tokens.swift — the "AURORA" v2 design language (UI v2).
//
// WHY v2 EXISTS (see noop_WIP/rounds/ROUND-11-ui-v2.md):
//  • v1 is good but information-dense on Today, inconsistent between tabs (rich Liquid gradient vs flat
//    light), and its signature per-frame liquid physics (3 concurrent 60 fps Canvas sims + a 20 fps sky)
//    is the most likely cause of the reported lag.
//  • v2 is DARK-FIRST and PERFORMANCE-FIRST: every surface here is a static gradient / material. There is
//    no TimelineView, no Canvas physics, no CoreMotion. Depth comes from layered translucency and light,
//    not from animation — so it reads more premium AND costs almost nothing per frame.
//  • v1 is untouched and remains the default. v2 is additive and gated (see NoopV2.enabledKey), so
//    reverting is a flag flip or `git checkout ui-v1-baseline`.
//
// Reference synthesis: the depth/《big number》drama of WHOOP, the sectioning + range gauges + calendar of
// Bevel, the actionable-copy hierarchy of Welltory — kept inside NOOP's own voice (honest provenance
// chips, own-baseline framing, no invented metrics).
enum NoopV2 {

    /// UserDefaults flag that opts a build/user into the v2 surfaces. Default OFF ⇒ v1 stays canonical.
    static let enabledKey = "noop.ui.v2"

    // MARK: - Canvas & surfaces
    //
    // A near-black canvas (true OLED black would crush the layered glass, so we sit a hair above it) with
    // an optional domain-tinted aurora wash at the top. Cards are translucent glass so the wash reads
    // through them, which is what gives v2 depth without motion.

    static let canvasTop = Color(red: 0.043, green: 0.047, blue: 0.063)     // #0B0C10
    static let canvasBottom = Color(red: 0.024, green: 0.027, blue: 0.036)  // #060709

    /// The page background: vertical canvas gradient + a soft domain-tinted aurora bloom behind the hero.
    static func canvas(tint: Color) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [canvasTop, canvasBottom], startPoint: .top, endPoint: .bottom)
            // Aurora bloom — a wide, very soft radial tint. Static: no per-frame cost.
            RadialGradient(
                colors: [tint.opacity(0.28), tint.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.02),
                startRadius: 8,
                endRadius: 420
            )
            .blur(radius: 30)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Glass card fill + hairline. Tuned so text stays AA-legible over the aurora.
    static let glassFill = Color.white.opacity(0.055)
    static let glassFillRaised = Color.white.opacity(0.085)
    static let hairline = Color.white.opacity(0.10)
    static let hairlineStrong = Color.white.opacity(0.16)

    // MARK: - Ink

    static let ink = Color(red: 0.976, green: 0.976, blue: 0.965)          // primary text
    static let inkSecondary = Color.white.opacity(0.70)
    static let inkTertiary = Color.white.opacity(0.45)

    // MARK: - Domain accents (semantic, consistent everywhere)
    //
    // One hue per domain, each with a bright tip for gradients. Chosen for contrast on the dark canvas and
    // to stay distinguishable for the common colour-vision deficiencies (green/amber/blue/violet spread).

    static let charge = Color(red: 0.26, green: 0.86, blue: 0.60)          // recovery — mint
    static let chargeTip = Color(red: 0.60, green: 0.98, blue: 0.80)
    static let effort = Color(red: 1.00, green: 0.62, blue: 0.25)          // strain — amber
    static let effortTip = Color(red: 1.00, green: 0.82, blue: 0.45)
    static let rest = Color(red: 0.45, green: 0.60, blue: 0.98)            // sleep — indigo
    static let restTip = Color(red: 0.68, green: 0.80, blue: 1.00)
    static let load = Color(red: 0.78, green: 0.52, blue: 0.98)            // autonomic load — violet
    static let loadTip = Color(red: 0.90, green: 0.74, blue: 1.00)

    /// Status tones for chips/bands.
    static let positive = charge
    static let warning = effort
    static let critical = Color(red: 1.00, green: 0.42, blue: 0.42)

    /// A domain's stroke gradient (deep → bright tip) for arcs and bars.
    static func ramp(_ base: Color, _ tip: Color) -> LinearGradient {
        LinearGradient(colors: [base.opacity(0.85), tip], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    // MARK: - Geometry

    static let cardRadius: CGFloat = 24
    static let tileRadius: CGFloat = 20
    static let chipRadius: CGFloat = 9
    static let screenPadding: CGFloat = 18
    static let cardPadding: CGFloat = 18
    static let sectionGap: CGFloat = 26
    static let stackGap: CGFloat = 12

    // MARK: - Type
    //
    // Rounded design for numbers (friendly, and reads as "instrument"), tight tracking on display text.
    // Every numeric style is monospaced-digit so values don't jitter as they update.

    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static let display = Font.system(size: 34, weight: .bold, design: .default)
    static let title = Font.system(size: 21, weight: .semibold, design: .default)
    static let headline = Font.system(size: 16, weight: .semibold, design: .default)
    static let body = Font.system(size: 15, weight: .regular, design: .default)
    static let caption = Font.system(size: 13, weight: .regular, design: .default)
    static let overline = Font.system(size: 11, weight: .semibold, design: .default)
}

// MARK: - Reusable surface modifiers

extension View {
    /// The standard v2 glass card: translucent fill, hairline edge, generous radius.
    func v2Card(padding: CGFloat = NoopV2.cardPadding,
                radius: CGFloat = NoopV2.cardRadius,
                raised: Bool = false) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(raised ? NoopV2.glassFillRaised : NoopV2.glassFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(NoopV2.hairline, lineWidth: 1)
            )
    }
}
