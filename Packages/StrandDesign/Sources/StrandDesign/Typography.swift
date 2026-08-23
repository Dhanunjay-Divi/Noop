import SwiftUI

// MARK: - Strand Typography (§9.2)
//
// Native system typography on every Apple platform. Tabular digits keep live
// values stable, while semantic text styles preserve Dynamic Type behavior.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    private static func fixed(_ size: CGFloat, weight: Font.Weight,
                              design: Font.Design = .default) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number, with tabular digits so a
    /// changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        fixed(size, weight: .bold, design: .rounded).monospacedDigit()
    }

    /// Retained for source compatibility. Native display type uses zero tracking.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        0
    }

    /// A Helvetica-Neue numeric style at an arbitrary size/weight — the house
    /// numeral. Tabular so live values align. Use anywhere a score/number is shown.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        fixed(size, weight: weight, design: .rounded).monospacedDigit()
    }

    /// Title1 28 / Bold. Scales with Dynamic Type.
    public static let title1 = Font.system(.title, design: .default, weight: .bold)

    /// Title2 22 / Semibold. Scales with Dynamic Type.
    public static let title2 = Font.system(.title2, design: .default, weight: .semibold)

    /// Headline 17 / Semibold. Scales with Dynamic Type.
    public static let headline = Font.system(.headline, design: .default, weight: .semibold)

    /// Body 15 / Regular. Scales with Dynamic Type.
    public static let body = Font.system(.subheadline, design: .default, weight: .regular)

    /// Subhead 13. Scales with Dynamic Type.
    public static let subhead = Font.system(.footnote, design: .default, weight: .regular)

    /// Caption 12. Scales with Dynamic Type.
    public static let caption = Font.system(.caption, design: .default, weight: .regular)

    /// Footnote 11. Scales with Dynamic Type.
    public static let footnote = Font.system(.caption2, design: .default, weight: .regular)

    /// Overline 11 / Semibold. Sparing ALL-CAPS labels. Scales with Dynamic Type.
    public static let overline = Font.system(.caption2, design: .default, weight: .semibold)

    /// `overline` at a custom point size — same Helvetica face, weight and Dynamic-Type scaling
    /// (relativeTo `.caption2`), just smaller. Passing 11 returns exactly `.overline`. Lets a caller
    /// shrink an ALL-CAPS label to fit a small container without losing accessibility text-scaling.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        fixed(size, weight: .semibold)
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary size/weight, for live values.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        fixed(size, weight: weight, design: .rounded).monospacedDigit()
    }

    public static let bodyNumber = Font.system(.subheadline, design: .rounded, weight: .medium).monospacedDigit()

    public static let captionNumber = Font.system(.caption, design: .rounded, weight: .medium).monospacedDigit()

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static let overlineTracking: CGFloat = 0
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, semibold, zero tracking, tertiary text.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 - the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
