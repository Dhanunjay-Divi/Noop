import SwiftUI

/// A large, meaning-led body illustration used at action and live-state moments.
///
/// This is intentionally separate from `MetricGlyph`: metric glyphs are compact labels,
/// while these illustrations are allowed more depth and motion because they appear once
/// in a hero, picker, or active-session card.
public enum SemanticBodyKind: Equatable, Sendable {
    case workout(systemImage: String)
    case heartRate
    case sleep
    case breathe

    fileprivate var systemImage: String {
        switch self {
        case .workout(let systemImage): return systemImage
        case .heartRate: return "heart.fill"
        case .sleep: return "moon.stars.fill"
        case .breathe: return "lungs.fill"
        }
    }
}

/// A code-native, GIF-like body illustration built from layered SF Symbols and glass.
///
/// Motion is semantic:
/// - workout figures stride only while a workout is active;
/// - the heart beats only while a live stream is active;
/// - sleep floats and breathing expands only while their caller marks them active.
///
/// Every illustration performs one short entrance settle. `eventToken` can replay that
/// settle for a meaningful change, such as selecting a different sport. Reduce Motion
/// always receives the final static frame.
public struct SemanticBodyIllustration: View {
    private let kind: SemanticBodyKind
    private let size: CGFloat
    private let tint: Color
    private let isActive: Bool
    private let eventToken: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var presented = false
    @State private var eventPresented = false

    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    public init(
        _ kind: SemanticBodyKind,
        size: CGFloat = 58,
        tint: Color = StrandPalette.accent,
        isActive: Bool = false,
        eventToken: Int = 0
    ) {
        self.kind = kind
        self.size = size
        self.tint = tint
        self.isActive = isActive
        self.eventToken = eventToken
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: poseStill || !isActive)) { context in
            illustration(at: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { settleIn() }
        .onChangeCompat(of: eventToken) { _ in replayEvent() }
    }

    private func illustration(at seconds: TimeInterval) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
        let phase = isActive && !poseStill ? seconds : 0
        let transform = motionTransform(at: phase)
        let settled = poseStill || (presented && eventPresented)

        return ZStack {
            shape
                .fill(
                    LinearGradient(
                        colors: plateColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            shape
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(scheme == .dark ? 0.28 : 0.18), .clear],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: size * 0.82
                    )
                )

            decoration(at: phase)

            Image(systemName: kind.systemImage)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(symbolStyle)
                .scaleEffect((settled ? 1 : 0.76) * transform.scale)
                .offset(
                    x: transform.x,
                    y: (settled ? 0 : size * 0.10) + transform.y
                )
                .rotationEffect(.degrees(transform.rotation))
                .opacity(settled ? 1 : 0.42)
                .shadow(color: .black.opacity(scheme == .dark ? 0.82 : 0.15),
                        radius: size * 0.055, y: size * 0.045)
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        .white.opacity(scheme == .dark ? 0.42 : 0.94),
                        StrandPalette.hairline,
                        .black.opacity(scheme == .dark ? 0.74 : 0.14),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: max(0.7, size * 0.018)
            )
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.48 : 0.14),
                radius: size * 0.18, y: size * 0.12)
    }

    @ViewBuilder
    private func decoration(at seconds: TimeInterval) -> some View {
        switch kind {
        case .workout(let systemImage):
            switch workoutMotion(for: systemImage) {
            case .stride:
                let stride = CGFloat(sin(seconds * 8.2))
                VStack(alignment: .leading, spacing: size * 0.065) {
                    Capsule()
                        .fill(tint.opacity(isActive ? 0.30 : 0.18))
                        .frame(width: size * 0.32, height: max(1, size * 0.028))
                        .offset(x: -size * 0.05 + stride * size * 0.025)
                    Capsule()
                        .fill(tint.opacity(isActive ? 0.18 : 0.10))
                        .frame(width: size * 0.22, height: max(1, size * 0.022))
                        .offset(x: -size * 0.12 - stride * size * 0.018)
                }
                .offset(x: -size * 0.16, y: size * 0.05)

            case .glide:
                let glide = CGFloat(sin(seconds * 3.4))
                VStack(spacing: size * 0.045) {
                    Capsule()
                        .fill(tint.opacity(isActive ? 0.24 : 0.14))
                        .frame(width: size * 0.46, height: max(1, size * 0.025))
                        .offset(x: glide * size * 0.025)
                    Capsule()
                        .fill(tint.opacity(isActive ? 0.14 : 0.08))
                        .frame(width: size * 0.32, height: max(1, size * 0.020))
                        .offset(x: -glide * size * 0.018)
                }
                .offset(y: size * 0.24)

            case .lift:
                Circle()
                    .stroke(tint.opacity(isActive ? 0.24 : 0.13),
                            lineWidth: max(1, size * 0.026))
                    .frame(width: size * 0.58, height: size * 0.58)
                Capsule()
                    .fill(tint.opacity(isActive ? 0.22 : 0.12))
                    .frame(width: size * 0.38, height: max(1, size * 0.025))
                    .offset(y: size * 0.28)

            case .calm:
                ZStack {
                    Circle()
                        .fill(tint.opacity(isActive ? 0.12 : 0.08))
                        .frame(width: size * 0.62, height: size * 0.62)
                    Circle()
                        .stroke(tint.opacity(isActive ? 0.22 : 0.12),
                                lineWidth: max(1, size * 0.020))
                        .frame(width: size * 0.44, height: size * 0.44)
                }

            case .dynamic:
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .stroke(tint.opacity(isActive ? 0.20 : 0.11),
                            lineWidth: max(1, size * 0.022))
                    .frame(width: size * 0.58, height: size * 0.58)
            }

        case .heartRate:
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.54, weight: .medium))
                .foregroundStyle(tint.opacity(isActive ? 0.24 : 0.13))

        case .sleep:
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: size * 0.48, height: size * 0.48)
                .offset(x: size * 0.17, y: -size * 0.12)

        case .breathe:
            let breath = isActive ? (CGFloat(sin(seconds * 1.15)) + 1) / 2 : 0.45
            Circle()
                .stroke(tint.opacity(0.22), lineWidth: max(1, size * 0.025))
                .frame(width: size * (0.56 + breath * 0.18),
                       height: size * (0.56 + breath * 0.18))
        }
    }

    private func motionTransform(at seconds: TimeInterval)
        -> (scale: CGFloat, x: CGFloat, y: CGFloat, rotation: Double) {
        guard isActive, !poseStill else { return (1, 0, 0, 0) }

        switch kind {
        case .workout(let systemImage):
            switch workoutMotion(for: systemImage) {
            case .stride:
                let stride = CGFloat(sin(seconds * 8.2))
                return (
                    1 + abs(stride) * 0.018,
                    stride * size * 0.012,
                    -abs(stride) * size * 0.030,
                    Double(stride * 3.2)
                )
            case .glide:
                let glide = CGFloat(sin(seconds * 3.4))
                return (
                    1 + abs(glide) * 0.010,
                    glide * size * 0.022,
                    -abs(glide) * size * 0.012,
                    Double(glide * 1.2)
                )
            case .lift:
                let repetition = (CGFloat(sin(seconds * 3.2)) + 1) / 2
                return (
                    0.985 + repetition * 0.025,
                    0,
                    -repetition * size * 0.028,
                    0
                )
            case .calm:
                let breath = (CGFloat(sin(seconds * 1.10)) + 1) / 2
                return (
                    0.985 + breath * 0.025,
                    0,
                    -breath * size * 0.010,
                    0
                )
            case .dynamic:
                let energy = CGFloat(sin(seconds * 4.2))
                return (
                    1 + abs(energy) * 0.012,
                    energy * size * 0.006,
                    -abs(energy) * size * 0.018,
                    Double(energy * 1.5)
                )
            }

        case .heartRate:
            let pulse = CGFloat(pow(max(0, sin(seconds * 7.4)), 7))
            return (1 + pulse * 0.10, 0, 0, 0)

        case .sleep:
            let drift = CGFloat(sin(seconds * 1.25))
            return (1, 0, drift * size * 0.028, Double(drift * 1.8))

        case .breathe:
            let breath = (CGFloat(sin(seconds * 1.15)) + 1) / 2
            return (0.96 + breath * 0.065, 0, 0, 0)
        }
    }

    private func settleIn() {
        guard !presented else { return }
        if poseStill {
            presented = true
            eventPresented = true
            return
        }
        withAnimation(.spring(response: 0.52, dampingFraction: 0.74)) {
            presented = true
            eventPresented = true
        }
    }

    private func replayEvent() {
        guard presented, !poseStill else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { eventPresented = false }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.70)) {
                eventPresented = true
            }
        }
    }

    /// Sport symbols resolve to a movement family so the animation matches the activity. A swimmer
    /// glides, strength work lifts, and yoga breathes; only locomotion receives running speed lines.
    private enum WorkoutMotion {
        case stride
        case glide
        case lift
        case calm
        case dynamic
    }

    private func workoutMotion(for systemImage: String) -> WorkoutMotion {
        let name = systemImage.lowercased()
        if name.contains("run") || name.contains("walk") || name.contains("cycle")
            || name.contains("elliptical") || name.contains("ski") || name.contains("snowboard") {
            return .stride
        }
        if name.contains("swim") || name.contains("rower") {
            return .glide
        }
        if name.contains("dumbbell") || name.contains("boxing")
            || name.contains("martial") || name.contains("climbing")
            || name.contains("highintensity") {
            return .lift
        }
        if name.contains("yoga") || name.contains("pilates")
            || name.contains("flexibility") || name.contains("mind.and.body") {
            return .calm
        }
        return .dynamic
    }

    private var plateColors: [Color] {
        if scheme == .dark {
            return [Color(hex: "#282828"), Color(hex: "#070707")]
        }
        return [Color.white, Color(hex: "#E4E4DF")]
    }

    private var symbolStyle: LinearGradient {
        if scheme == .dark {
            return LinearGradient(colors: [.white, Color(hex: "#BDBDB8")],
                                  startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [Color(hex: "#373734"), .black],
                              startPoint: .top, endPoint: .bottom)
    }
}

#if DEBUG
#Preview("Semantic body illustrations") {
    HStack(spacing: 18) {
        SemanticBodyIllustration(.workout(systemImage: "figure.run"),
                                 tint: StrandPalette.effortColor,
                                 isActive: true)
        SemanticBodyIllustration(.heartRate,
                                 tint: StrandPalette.metricRose,
                                 isActive: true)
        SemanticBodyIllustration(.sleep,
                                 tint: StrandPalette.restColor)
        SemanticBodyIllustration(.breathe,
                                 tint: StrandPalette.metricCyan,
                                 isActive: true)
    }
    .padding(28)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
