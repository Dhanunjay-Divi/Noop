import SwiftUI

/// Shared construction for NOOP's small extruded icon plates.
///
/// Both navigation and metric glyphs use this exact stack so their bevel, symbol
/// weight and physical depth never drift apart. The face stays monochrome; metric
/// colour remains in the adjacent value, chart or gauge.
struct ExtrudedGlyphPlate: View {
    let systemName: String
    let size: CGFloat
    var selected = false
    var symbolScale: CGFloat = 1
    var symbolOffset: CGSize = .zero
    var symbolRotation: Angle = .zero
    var symbolOpacity: Double = 1

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
        let depth = max(1.5, size * 0.065)

        ZStack {
            // The lower duplicate is the actual extrusion—not another blurry
            // shadow. It leaves a crisp dark lip along the lower edge.
            shape
                .fill(extrusionColor)
                .offset(y: depth)

            shape
                .fill(
                    LinearGradient(
                        colors: faceColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Grazing top light: deliberately confined to the upper third.
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(specularOpacity), location: 0),
                            .init(color: .white.opacity(specularOpacity * 0.35), location: 0.22),
                            .init(color: .clear, location: 0.46),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // A one-point lower duplicate gives the SF Symbol a pressed-metal
            // edge while preserving its familiar, accessible silhouette.
            symbol
                .foregroundStyle(symbolExtrusion)
                .offset(x: symbolOffset.width, y: symbolOffset.height + max(0.8, size * 0.032))

            symbol
                .foregroundStyle(symbolGradient)
                .offset(symbolOffset)
        }
        .frame(width: size, height: size)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(rimTopOpacity),
                        StrandPalette.bevelSide.opacity(scheme == .dark ? 0.30 : 0.64),
                        StrandPalette.bevelBottom.opacity(scheme == .dark ? 0.94 : 0.30),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: max(0.7, size * 0.022)
            )
        )
        .overlay(
            shape
                .inset(by: 1)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(scheme == .dark ? 0.055 : 0.48),
                            .clear,
                            Color.black.opacity(scheme == .dark ? 0.28 : 0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.55
                )
        )
        .shadow(
            color: Color.black.opacity(scheme == .dark ? 0.44 : 0.13),
            radius: size * 0.21,
            x: 0,
            y: size * 0.13
        )
        .accessibilityHidden(true)
    }

    private var symbol: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.44, weight: .semibold))
            .scaleEffect(symbolScale)
            .rotationEffect(symbolRotation)
            .opacity(symbolOpacity)
    }

    private var faceColors: [Color] {
        if selected {
            return scheme == .dark
                ? [Color(hex: "#F7F7F4"), Color(hex: "#BFC0BC")]
                : [Color(hex: "#292A2D"), Color(hex: "#090A0C")]
        }
        return [StrandPalette.glyphFaceTop, StrandPalette.glyphFaceBottom]
    }

    private var symbolGradient: LinearGradient {
        let colors: [Color]
        if selected {
            colors = scheme == .dark
                ? [Color(hex: "#2B2C2F"), Color(hex: "#050506")]
                : [Color(hex: "#F7F7F4"), Color(hex: "#BFC0BC")]
        } else {
            colors = [StrandPalette.glyphInkTop, StrandPalette.glyphInkBottom]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    private var extrusionColor: Color {
        if selected {
            return scheme == .dark ? Color(hex: "#777873") : Color(hex: "#020203")
        }
        return StrandPalette.glyphExtrusion
    }

    private var symbolExtrusion: Color {
        if selected {
            return scheme == .dark ? .white.opacity(0.30) : .black.opacity(0.92)
        }
        return scheme == .dark ? .black.opacity(0.90) : .white.opacity(0.82)
    }

    private var specularOpacity: Double {
        if selected { return scheme == .dark ? 0.58 : 0.09 }
        return scheme == .dark ? 0.115 : 0.54
    }

    private var rimTopOpacity: Double {
        contrast == .increased
            ? (scheme == .dark ? 0.38 : 0.96)
            : (scheme == .dark ? 0.24 : 0.88)
    }
}

/// A small monochrome 3D icon plate for feature navigation.
///
/// The symbol stays an SF Symbol for accessibility and platform familiarity. Depth
/// comes from an obsidian/pearl plate, a specular top edge and two restrained
/// shadows—not from decorative color. Physiological colors remain reserved for data.
public struct DepthGlyph: View {
    public let systemName: String
    public var size: CGFloat
    public var selected: Bool

    public init(_ systemName: String, size: CGFloat = 38, selected: Bool = false) {
        self.systemName = systemName
        self.size = size
        self.selected = selected
    }

    public var body: some View {
        ExtrudedGlyphPlate(
            systemName: systemName,
            size: size,
            selected: selected
        )
    }
}

#if DEBUG
#Preview("Depth glyphs") {
    HStack(spacing: 20) {
        DepthGlyph("person.2.fill")
        DepthGlyph("waveform.path.ecg", selected: true)
        DepthGlyph("moon.stars.fill")
    }
    .padding(30)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
