import SwiftUI

// MARK: - BrandMark — the NOOP monogram
//
// The canonical brand lock-up is a compact 2×2 NO / OP grid:
//
//      N O
//      O P
//
// The diagonal cut in the upper O is the one custom gesture: an interrupted
// biometric trace / open data path. The letters are native geometry rather than
// a system font, so every platform can reproduce exactly the same silhouette
// from a 22pt navigation mark to a 1024px launcher master.

public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    private let tileColor = Color(hex: "#050505")
    private let letterColor = Color(hex: "#F4F1EA")
    private var cornerRadius: CGFloat { size * 0.235 }
    private var rimWidth: CGFloat { max(0.5, size * 0.006) }

    public var body: some View {
        ZStack {
            obsidianTile

            NoopMonogram()
                .fill(letterColor, style: FillStyle(eoFill: true))

            // A narrow radial incision turns the upper-right O into NOOP's
            // proprietary "open signal" glyph. It remains at least one point
            // wide so it survives 22pt navigation rendering.
            Rectangle()
                .fill(tileColor)
                .frame(
                    width: max(1, size * 0.014),
                    height: size * 0.095
                )
                .rotationEffect(.degrees(35))
                .position(x: size * 0.707, y: size * 0.253)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("NOOP"))
        .accessibilityAddTraits(.isImage)
    }

    /// The icon material is intentionally flat. Recognition comes from the
    /// monogram and notch, not a generic glass/power-button treatment.
    private var obsidianTile: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tileColor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: rimWidth)
            )
    }
}

/// Geometric master for the NO / OP letter grid. All coordinates are fractions
/// of a square, matching the approved raster composition.
private struct NoopMonogram: Shape {
    func path(in rect: CGRect) -> Path {
        let edge = min(rect.width, rect.height)
        let origin = CGPoint(
            x: rect.midX - edge / 2,
            y: rect.midY - edge / 2
        )
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + edge * x, y: origin.y + edge * y)
        }

        var path = Path()

        // N — deliberately geometric, with the same mass as the circular O's.
        path.move(to: point(0.210, 0.205))
        path.addLine(to: point(0.305, 0.205))
        path.addLine(to: point(0.405, 0.340))
        path.addLine(to: point(0.405, 0.205))
        path.addLine(to: point(0.490, 0.205))
        path.addLine(to: point(0.490, 0.490))
        path.addLine(to: point(0.397, 0.490))
        path.addLine(to: point(0.303, 0.358))
        path.addLine(to: point(0.303, 0.490))
        path.addLine(to: point(0.210, 0.490))
        path.closeSubpath()

        // Upper O. The diagonal notch is applied as an obsidian overlay in
        // BrandMark so its width can be pixel-clamped at tiny sizes.
        path.addEllipse(in: CGRect(
            x: origin.x + edge * 0.515,
            y: origin.y + edge * 0.200,
            width: edge * 0.295,
            height: edge * 0.292
        ))
        path.addEllipse(in: CGRect(
            x: origin.x + edge * 0.604,
            y: origin.y + edge * 0.287,
            width: edge * 0.117,
            height: edge * 0.121
        ))

        // Lower O.
        path.addEllipse(in: CGRect(
            x: origin.x + edge * 0.207,
            y: origin.y + edge * 0.500,
            width: edge * 0.296,
            height: edge * 0.287
        ))
        path.addEllipse(in: CGRect(
            x: origin.x + edge * 0.296,
            y: origin.y + edge * 0.579,
            width: edge * 0.119,
            height: edge * 0.128
        ))

        // P outer silhouette.
        path.move(to: point(0.516, 0.505))
        path.addLine(to: point(0.680, 0.505))
        path.addCurve(
            to: point(0.802, 0.608),
            control1: point(0.756, 0.505),
            control2: point(0.802, 0.546)
        )
        path.addCurve(
            to: point(0.680, 0.711),
            control1: point(0.802, 0.670),
            control2: point(0.756, 0.711)
        )
        path.addLine(to: point(0.614, 0.711))
        path.addLine(to: point(0.614, 0.780))
        path.addLine(to: point(0.516, 0.780))
        path.closeSubpath()

        // P counter.
        path.move(to: point(0.614, 0.576))
        path.addLine(to: point(0.678, 0.576))
        path.addCurve(
            to: point(0.724, 0.608),
            control1: point(0.707, 0.576),
            control2: point(0.724, 0.589)
        )
        path.addCurve(
            to: point(0.678, 0.641),
            control1: point(0.724, 0.627),
            control2: point(0.707, 0.641)
        )
        path.addLine(to: point(0.614, 0.641))
        path.closeSubpath()

        return path
    }
}

#if DEBUG
#Preview("BrandMark - sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
