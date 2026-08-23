import SwiftUI

// NoopV2Tokens.swift - the "AURORA" v2 design language (UI v2).
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
    //
    // Contrast measured on the L1 card surface (glassFill white 0.055 over canvasTop #0B0C10 ≈ #18191D):
    //   ink            #F9F9F6      → ~16.6:1  (AAA)
    //   inkSecondary   white 0.70   → ~9.1:1   (AAA)
    //   inkTertiaryText white 0.55  → ~6.1:1   (AA  ✅)
    //   decorationFaint white 0.45  → ~4.4:1   (FAILS AA for text — decoration only)
    //
    // C2 FIX (2026-08-22): the prototype used white 0.45 for the SMALLEST text in the app (11 pt overlines,
    // 13 pt captions, 9 pt heatmap/calendar labels, gauge status lines) — below the 4.5:1 AA floor, and
    // worse where a card overlaps the aurora bloom. Text tertiary is now 0.55; 0.45 survives only as
    // `decorationFaint` for hairlines and empty tracks, which have no contrast requirement.

    static let ink = Color(red: 0.976, green: 0.976, blue: 0.965)          // primary text
    static let inkSecondary = Color.white.opacity(0.70)
    /// Smallest-text tertiary — AA-compliant. Use this for ALL text.
    static let inkTertiary = Color.white.opacity(0.55)
    /// Non-text decoration only (hairlines, empty tracks, disabled glyphs). NEVER for text.
    static let decorationFaint = Color.white.opacity(0.45)

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

    // MARK: - Sequential LOAD ramp (heatmap / intensity only)
    //
    // C4 FIX: the heatmap previously reused the DOMAIN hues (mint = "mid" load, amber = "high"). But mint
    // means *recovery/good* everywhere else, so a mint-heavy heatmap read as "a calm week" when it actually
    // meant "mid stress all week". A heatmap must use a single ordered ramp whose low end is unambiguously
    // the good end. This cool→warm ramp is reserved for INTENSITY surfaces and is never used for a domain
    // score, so the two colour languages can't collide.
    //
    // Ordering is also encoded by LIGHTNESS (dark cool → bright warm), so the grid still reads correctly in
    // greyscale / for colour-vision deficiency — colour is never the only channel.
    static let loadRamp0 = Color(red: 0.16, green: 0.30, blue: 0.52)       // lowest  — deep blue
    static let loadRamp1 = Color(red: 0.20, green: 0.55, blue: 0.62)       // low     — teal
    static let loadRamp2 = Color(red: 0.85, green: 0.72, blue: 0.30)       // mid     — sand
    static let loadRamp3 = Color(red: 0.93, green: 0.45, blue: 0.22)       // high    — orange
    static let loadRampEmpty = Color.white.opacity(0.05)                   // no data — empty slot

    /// Bucket a 0–3 load level onto the sequential ramp. `nil` ⇒ the empty slot (never a filled zero).
    static func loadRampColor(_ level: Double?) -> Color {
        guard let v = level else { return loadRampEmpty }
        if v < 0.75 { return loadRamp0 }
        if v < 1.50 { return loadRamp1 }
        if v < 2.25 { return loadRamp2 }
        return loadRamp3
    }

    /// Human label for a ramp bucket (used in legends and VoiceOver — never colour alone).
    static func loadRampLabel(_ level: Double?) -> String {
        guard let v = level else { return "no data" }
        if v < 0.75 { return "lowest" }
        if v < 1.50 { return "low" }
        if v < 2.25 { return "mid" }
        return "high"
    }

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
    //
    // DYNAMIC TYPE (a11y fix, 2026-08-22): the prose styles are built on SEMANTIC TEXT STYLES, so they
    // scale with the user's Dynamic Type setting automatically. The prototype used fixed `.system(size:)`
    // for everything, which silently ignored the accessibility setting — unacceptable in a health app.
    //
    // DOCUMENTED EXCEPTION: `number(_:_:)` stays FIXED-size. Those figures sit inside fixed-diameter arcs
    // and rings (`V2HeroArc`, `V2SatelliteRing`), so scaling them would overflow the geometry rather than
    // help. The surrounding labels/captions DO scale, and every such readout carries a VoiceOver value, so
    // the information remains fully accessible at any type size.

    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static let display = Font.system(.largeTitle, design: .default).weight(.bold)
    static let title = Font.system(.title3, design: .default).weight(.semibold)
    static let headline = Font.system(.callout, design: .default).weight(.semibold)
    static let body = Font.system(.subheadline, design: .default)
    static let caption = Font.system(.footnote, design: .default)
    static let overline = Font.system(.caption2, design: .default).weight(.semibold)
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
