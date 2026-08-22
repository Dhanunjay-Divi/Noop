import SwiftUI

// NoopV3Tokens.swift — "INSTRUMENT" (UI v3).
//
// WHY v3 (honest post-mortem of v2 "Aurora", which the owner judged worse than Bevel):
//  1. v2's aurora radial bloom muddied the top of every screen. Bevel and WHOOP both use a FLAT near-black
//     field and let the DATA be the only luminous thing. Colour-as-decoration cheapens; colour-as-data reads
//     premium. v3 has no ambient glow at all.
//  2. v2's 232 pt hero arc spent an entire viewport on ONE number. Bevel puts three compact rings in a
//     single row and is into real content by 40% of the screen. v3 does the same.
//  3. v2 was LOW DENSITY — it felt empty yet scrolled forever. The reference apps are dense but *organised*:
//     tight card grids, consistent rhythm, small-caps micro-labels over large figures. Density, done with
//     rhythm, is what reads as "professional instrument" rather than "hobby app".
//  4. v2's `white.opacity(0.055)` card on near-black reads as flat grey. v3 uses a slightly lifted solid
//     surface + a hairline, which is crisper and cheaper to render than a translucent fill.
//  5. v2 had no status vocabulary. Bevel's "Normal / Higher" beside each vital is the single cheapest thing
//     that makes a screen feel like a measuring device. v3 makes status a first-class token.
//
// IDENTITY: NOOP is the glass box in a category of black boxes. So the aesthetic target is laboratory
// instrument / Braun — exposed scales, visible units, monospaced figures, structure shown rather than hidden
// — not another neon-on-black fitness app.
//
// PERFORMANCE: still entirely static. No TimelineView, no Canvas physics, no CoreMotion, no ambient blur.
enum V3 {

    static let enabledKey = "noop.ui.v3"

    // MARK: - Field & surfaces (flat, no glow)

    /// The page field. Near-black but not pure black, so elevated surfaces can still read above it.
    static let field = Color(red: 0.035, green: 0.039, blue: 0.047)        // #090A0C
    /// Card surface — a solid lift, not a translucent wash (crisper than v2's glass, and cheaper).
    static let surface = Color(red: 0.078, green: 0.086, blue: 0.098)      // #141619
    /// A second level for nested/inset elements (gauge tracks, chips).
    static let surfaceInset = Color(red: 0.118, green: 0.129, blue: 0.145) // #1E2125
    static let hairline = Color.white.opacity(0.09)

    // MARK: - Ink (all AA+ on `surface`)

    static let ink = Color(red: 0.965, green: 0.969, blue: 0.976)          // primary
    static let inkSecondary = Color.white.opacity(0.72)                    // ~9:1
    static let inkTertiary = Color.white.opacity(0.56)                     // ~6.2:1 — smallest text
    static let inkFaint = Color.white.opacity(0.34)                        // NON-TEXT decoration only

    // MARK: - Data colours (used for DATA and STATUS only — never decoration)

    static let recovery = Color(red: 0.27, green: 0.83, blue: 0.55)        // green
    static let effort = Color(red: 0.99, green: 0.66, blue: 0.29)          // amber
    static let sleep = Color(red: 0.47, green: 0.62, blue: 0.99)           // indigo
    static let loadViolet = Color(red: 0.72, green: 0.55, blue: 0.98)      // violet

    /// Status vocabulary — the Bevel lesson. A value without a status word is just a number.
    enum Status: String {
        case low = "LOW", normal = "NORMAL", high = "HIGH", noData = "NO DATA", calibrating = "CALIBRATING"
        var color: Color {
            switch self {
            case .normal: return V3.recovery
            case .high: return V3.effort
            case .low: return V3.sleep
            case .noData, .calibrating: return V3.inkTertiary
            }
        }
    }

    // MARK: - Rhythm (dense but consistent — this is what makes it read as organised)

    static let screenPad: CGFloat = 16
    static let cardPad: CGFloat = 14
    static let cardRadius: CGFloat = 16
    static let gridGap: CGFloat = 8         // between tiles
    static let stackGap: CGFloat = 10       // within a card
    static let sectionGap: CGFloat = 22     // between sections

    // MARK: - Type (instrument voice: micro-caps labels over large tabular figures)

    /// Big figures — tabular so digits never jitter. Fixed size by design (they sit in fixed geometry);
    /// every such readout carries a VoiceOver value, and all surrounding prose scales.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    /// Micro label — uppercase, tracked out. The signature of a measuring device.
    static let micro = Font.system(.caption2, design: .default).weight(.semibold)
    static let unit = Font.system(.caption2, design: .default).weight(.medium)
    static let body = Font.system(.subheadline, design: .default)
    static let bodyStrong = Font.system(.subheadline, design: .default).weight(.semibold)
    static let sectionTitle = Font.system(.headline, design: .default).weight(.semibold)
    static let screenTitle = Font.system(.title2, design: .default).weight(.bold)
}

extension View {
    /// The v3 card: solid lifted surface + hairline. Crisper than translucency, and free to render.
    func v3Card(padding: CGFloat = V3.cardPad, radius: CGFloat = V3.cardRadius) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(V3.surface))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(V3.hairline, lineWidth: 0.5)
            )
    }

    /// A tracked-out micro caps label — used for every field name in v3.
    func v3MicroLabel() -> some View {
        self.font(V3.micro).tracking(0).foregroundStyle(V3.inkTertiary)
    }
}
