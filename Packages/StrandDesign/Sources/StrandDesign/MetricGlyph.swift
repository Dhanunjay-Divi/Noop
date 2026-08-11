import SwiftUI

/// The restrained entrance gesture used by a metric glyph.
///
/// These are deliberately one-shot motions, not looping decorations. A dashboard
/// can therefore show ten distinct metrics without ten icons constantly moving.
public enum MetricGlyphMotion: Equatable, Sendable {
    case automatic
    case pulse
    case float
    case rise
    case settle
}

/// A compact, monochrome dimensional icon for a named biometric metric.
///
/// `MetricGlyph` is decorative by design and hides itself from accessibility;
/// callers must place a visible metric name beside it. The SF Symbol supplies a
/// familiar physiological silhouette, while the pearl/obsidian plate keeps the
/// icon system coherent with NOOP's black-and-white identity. On first appearance
/// the symbol settles into place with a motion chosen for its meaning. Reduce
/// Motion users receive the final static state immediately.
public struct MetricGlyph: View {
    public let systemName: String
    public var size: CGFloat
    public var motion: MetricGlyphMotion

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false

    public init(
        _ systemName: String,
        size: CGFloat = 32,
        motion: MetricGlyphMotion = .automatic
    ) {
        self.systemName = systemName
        self.size = size
        self.motion = motion
    }

    public var body: some View {
        let resolved = resolvedMotion

        ExtrudedGlyphPlate(
            systemName: systemName,
            size: size,
            symbolScale: symbolScale(for: resolved),
            symbolOffset: symbolOffset(for: resolved),
            symbolRotation: symbolRotation(for: resolved),
            symbolOpacity: presented || reduceMotion ? 1 : 0.55
        )
        .onAppear {
            guard !presented else { return }
            if reduceMotion {
                presented = true
            } else {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.72)) {
                    presented = true
                }
            }
        }
    }

    /// Pure resolver kept internal so the semantic motion mapping is unit-testable.
    static func automaticMotion(for systemName: String) -> MetricGlyphMotion {
        let name = systemName.lowercased()
        if name.contains("heart") || name.contains("waveform") {
            return .pulse
        }
        if name.contains("lung") || name.contains("drop") ||
            name.contains("moon") || name.contains("bed") {
            return .float
        }
        if name.contains("flame") || name.contains("figure") ||
            name.contains("bolt") || name.contains("walk") || name.contains("run") {
            return .rise
        }
        return .settle
    }

    private var resolvedMotion: MetricGlyphMotion {
        motion == .automatic ? Self.automaticMotion(for: systemName) : motion
    }

    private func symbolScale(for motion: MetricGlyphMotion) -> CGFloat {
        guard !presented && !reduceMotion else { return 1 }
        switch motion {
        case .pulse: return 0.72
        case .float: return 0.90
        case .rise: return 0.84
        case .settle, .automatic: return 0.88
        }
    }

    private func symbolOffset(for motion: MetricGlyphMotion) -> CGSize {
        guard !presented && !reduceMotion else { return .zero }
        switch motion {
        case .float: return CGSize(width: 0, height: size * 0.08)
        case .rise: return CGSize(width: 0, height: size * 0.12)
        case .pulse, .settle, .automatic: return .zero
        }
    }

    private func symbolRotation(for motion: MetricGlyphMotion) -> Angle {
        guard !presented && !reduceMotion else { return .zero }
        return motion == .settle ? .degrees(-5) : .zero
    }

}

#if DEBUG
#Preview("Metric glyphs") {
    HStack(spacing: 14) {
        MetricGlyph("bolt.heart.fill")
        MetricGlyph("flame.fill")
        MetricGlyph("moon.stars.fill")
        MetricGlyph("waveform.path.ecg")
        MetricGlyph("lungs.fill")
    }
    .padding(28)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
