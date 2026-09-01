import StrandDesign
import SwiftUI
import WebKit
import WhoopStore

/// Offline 3D guidance for NOOP's built-in catalog, with a native fallback for custom exercises.
struct StrengthExerciseMotionView: View {
    let exercise: StrengthExerciseRow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var guide: StrengthExerciseGuide {
        StrengthExerciseGuidance.guide(for: exercise)
    }

    var body: some View {
        Group {
            if let variant = guide.animationVariant {
                StrengthMotionWebView(
                    exerciseID: variant.rawValue,
                    cycleDuration: guide.cycleDuration,
                    reduceMotion: reduceMotion
                )
            } else {
                StrengthExerciseFallbackMotionView(exercise: exercise, guide: guide)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.62, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(StrandPalette.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strengthExerciseName(exercise))
    }
}

private struct StrengthExerciseFallbackMotionView: View {
    let exercise: StrengthExerciseRow
    let guide: StrengthExerciseGuide

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            StrandPalette.surfaceInset

            TimelineView(
                .animation(minimumInterval: 1.0 / 30.0, paused: paused || reduceMotion)
            ) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let phase = paused || reduceMotion
                        ? 0.22
                        : timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: guide.cycleDuration)
                            / guide.cycleDuration
                    StrengthMotionRenderer.draw(
                        in: &context,
                        size: size,
                        exercise: exercise,
                        profile: guide.profile,
                        variant: nil,
                        phase: phase
                    )
                }
            }
            .accessibilityHidden(true)

            Button {
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel(paused ? "Start" : "Pause")
            .help(paused ? "Start" : "Pause")
        }
    }
}

private struct StrengthMotionWebConfiguration: Equatable {
    let exerciseID: String
    let cycleDuration: TimeInterval
    let reduceMotion: Bool

    var pageURL: URL? {
        guard let htmlURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "StrengthMotion"
        ),
            var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "exercise", value: exerciseID),
            URLQueryItem(name: "duration", value: String(format: "%.3f", cycleDuration)),
            URLQueryItem(name: "reduceMotion", value: reduceMotion ? "1" : "0"),
        ]
        return components.url
    }

    var readAccessURL: URL? {
        Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "StrengthMotion"
        )?.deletingLastPathComponent()
    }
}

#if os(iOS)
private struct StrengthMotionWebView: UIViewRepresentable {
    let exerciseID: String
    let cycleDuration: TimeInterval
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: webConfiguration())
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 0.031, green: 0.035, blue: 0.047, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(configuration, in: webView)
    }

    private var configuration: StrengthMotionWebConfiguration {
        .init(
            exerciseID: exerciseID,
            cycleDuration: cycleDuration,
            reduceMotion: reduceMotion
        )
    }

    final class Coordinator {
        private var loadedConfiguration: StrengthMotionWebConfiguration?

        func load(_ configuration: StrengthMotionWebConfiguration, in webView: WKWebView) {
            guard loadedConfiguration != configuration,
                  let pageURL = configuration.pageURL,
                  let readAccessURL = configuration.readAccessURL
            else {
                return
            }
            loadedConfiguration = configuration
            webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessURL)
        }
    }
}
#elseif os(macOS)
private struct StrengthMotionWebView: NSViewRepresentable {
    let exerciseID: String
    let cycleDuration: TimeInterval
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        WKWebView(frame: .zero, configuration: webConfiguration())
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(configuration, in: webView)
    }

    private var configuration: StrengthMotionWebConfiguration {
        .init(
            exerciseID: exerciseID,
            cycleDuration: cycleDuration,
            reduceMotion: reduceMotion
        )
    }

    final class Coordinator {
        private var loadedConfiguration: StrengthMotionWebConfiguration?

        func load(_ configuration: StrengthMotionWebConfiguration, in webView: WKWebView) {
            guard loadedConfiguration != configuration,
                  let pageURL = configuration.pageURL,
                  let readAccessURL = configuration.readAccessURL
            else {
                return
            }
            loadedConfiguration = configuration
            webView.loadFileURL(pageURL, allowingReadAccessTo: readAccessURL)
        }
    }
}
#endif

private func webConfiguration() -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.websiteDataStore = .nonPersistent()
    return configuration
}

enum StrengthBodyMapMode: String, CaseIterable, Identifiable {
    case load
    case recovery

    var id: String { rawValue }
}

struct StrengthBodyMapView: View {
    let statuses: [StrengthMuscleStatus]
    let mode: StrengthBodyMapMode
    let selectedMuscle: String?
    let onSelect: (String) -> Void

    private var statusByMuscle: [String: StrengthMuscleStatus] {
        Dictionary(uniqueKeysWithValues: statuses.map { ($0.muscle, $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space4) {
            bodyFigure(side: .front)
            bodyFigure(side: .back)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 306)
        .accessibilityElement(children: .contain)
    }

    private func bodyFigure(side: StrengthBodySide) -> some View {
        VStack(spacing: NoopMetrics.space2) {
            Text(side == .front ? "Front" : "Back")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            GeometryReader { proxy in
                ZStack {
                    StrengthBodySilhouette()
                        .fill(StrandPalette.textTertiary.opacity(0.14))
                    ForEach(side.regions) { region in
                        let status = statusByMuscle[region.muscle]
                        let score = mode == .load
                            ? (status?.loadScore ?? 0)
                            : (status?.residualLoadScore ?? 0)
                        Button {
                            onSelect(region.muscle)
                        } label: {
                            Capsule()
                                .fill(bodyMapColor(score: score))
                                .overlay {
                                    Capsule()
                                        .stroke(
                                            selectedMuscle == region.muscle
                                                ? StrandPalette.textPrimary
                                                : Color.white.opacity(0.13),
                                            lineWidth: selectedMuscle == region.muscle ? 2 : 0.8
                                        )
                                }
                                .frame(
                                    width: max(18, proxy.size.width * region.width),
                                    height: max(22, proxy.size.height * region.height)
                                )
                                .rotationEffect(.degrees(region.rotation))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: proxy.size.width * region.x,
                            y: proxy.size.height * region.y
                        )
                        .accessibilityLabel(
                            region.muscle
                                .replacingOccurrences(of: "_", with: " ")
                                .capitalized
                        )
                        .accessibilityValue(
                            mode == .load
                                ? "\(Int((status?.loadScore ?? 0) * 100)) percent load"
                                : "\(Int((status?.recoveryScore ?? 1) * 100)) percent recovered"
                        )
                    }
                }
            }
            .aspectRatio(0.46, contentMode: .fit)
        }
        .frame(maxWidth: .infinity)
    }

    private func bodyMapColor(score: Double) -> Color {
        let clamped = min(max(score, 0), 1)
        return Color(red: 0.92, green: 0.12, blue: 0.18)
            .opacity(0.13 + clamped * 0.77)
    }
}

private enum StrengthBodySide {
    case front
    case back

    var regions: [StrengthBodyRegion] {
        switch self {
        case .front:
            [
                .init("shoulders-left", "shoulders", 0.35, 0.19, 0.13, 0.065, 45),
                .init("shoulders-right", "shoulders", 0.65, 0.19, 0.13, 0.065, -45),
                .init("chest-left", "chest", 0.43, 0.29, 0.16, 0.12, 12),
                .init("chest-right", "chest", 0.57, 0.29, 0.16, 0.12, -12),
                .init("biceps-left", "biceps", 0.27, 0.35, 0.11, 0.15, 8),
                .init("biceps-right", "biceps", 0.73, 0.35, 0.11, 0.15, -8),
                .init("forearms-left", "forearms", 0.22, 0.51, 0.09, 0.17, 10),
                .init("forearms-right", "forearms", 0.78, 0.51, 0.09, 0.17, -10),
                .init("core", "core", 0.50, 0.45, 0.20, 0.24, 0),
                .init("quadriceps-left", "quadriceps", 0.42, 0.69, 0.14, 0.22, 3),
                .init("quadriceps-right", "quadriceps", 0.58, 0.69, 0.14, 0.22, -3),
                .init("calves-left", "calves", 0.40, 0.88, 0.10, 0.17, 2),
                .init("calves-right", "calves", 0.60, 0.88, 0.10, 0.17, -2),
            ]
        case .back:
            [
                .init("shoulders-left", "shoulders", 0.35, 0.19, 0.13, 0.065, 45),
                .init("shoulders-right", "shoulders", 0.65, 0.19, 0.13, 0.065, -45),
                .init("back", "back", 0.50, 0.35, 0.29, 0.27, 0),
                .init("triceps-left", "triceps", 0.27, 0.35, 0.11, 0.15, 8),
                .init("triceps-right", "triceps", 0.73, 0.35, 0.11, 0.15, -8),
                .init("forearms-left", "forearms", 0.22, 0.51, 0.09, 0.17, 10),
                .init("forearms-right", "forearms", 0.78, 0.51, 0.09, 0.17, -10),
                .init("glutes-left", "glutes", 0.43, 0.56, 0.16, 0.12, 4),
                .init("glutes-right", "glutes", 0.57, 0.56, 0.16, 0.12, -4),
                .init("hamstrings-left", "hamstrings", 0.42, 0.70, 0.14, 0.22, 3),
                .init("hamstrings-right", "hamstrings", 0.58, 0.70, 0.14, 0.22, -3),
                .init("calves-left", "calves", 0.40, 0.88, 0.10, 0.17, 2),
                .init("calves-right", "calves", 0.60, 0.88, 0.10, 0.17, -2),
            ]
        }
    }
}

private struct StrengthBodyRegion: Identifiable {
    let id: String
    let muscle: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let rotation: Double

    init(
        _ id: String,
        _ muscle: String,
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double,
        _ rotation: Double
    ) {
        self.id = id
        self.muscle = muscle
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}

private struct StrengthBodySilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let head = CGRect(
            x: rect.midX - rect.width * 0.09,
            y: rect.height * 0.02,
            width: rect.width * 0.18,
            height: rect.width * 0.18
        )
        path.addEllipse(in: head)
        path.addRoundedRect(
            in: CGRect(
                x: rect.width * 0.34,
                y: rect.height * 0.15,
                width: rect.width * 0.32,
                height: rect.height * 0.43
            ),
            cornerSize: CGSize(width: rect.width * 0.11, height: rect.width * 0.11)
        )
        path.addRoundedRect(
            in: CGRect(
                x: rect.width * 0.19,
                y: rect.height * 0.17,
                width: rect.width * 0.13,
                height: rect.height * 0.45
            ),
            cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07)
        )
        path.addRoundedRect(
            in: CGRect(
                x: rect.width * 0.68,
                y: rect.height * 0.17,
                width: rect.width * 0.13,
                height: rect.height * 0.45
            ),
            cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07)
        )
        path.addRoundedRect(
            in: CGRect(
                x: rect.width * 0.34,
                y: rect.height * 0.53,
                width: rect.width * 0.14,
                height: rect.height * 0.45
            ),
            cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07)
        )
        path.addRoundedRect(
            in: CGRect(
                x: rect.width * 0.52,
                y: rect.height * 0.53,
                width: rect.width * 0.14,
                height: rect.height * 0.45
            ),
            cornerSize: CGSize(width: rect.width * 0.07, height: rect.width * 0.07)
        )
        return path
    }
}

private enum StrengthMotionRenderer {
    private struct Point {
        var x: Double
        var y: Double

        static func mix(_ a: Point, _ b: Point, _ amount: Double) -> Point {
            Point(
                x: a.x + (b.x - a.x) * amount,
                y: a.y + (b.y - a.y) * amount
            )
        }
    }

    private struct Pose {
        var head: Point
        var neck: Point
        var leftShoulder: Point
        var rightShoulder: Point
        var leftElbow: Point
        var rightElbow: Point
        var leftHand: Point
        var rightHand: Point
        var hip: Point
        var leftKnee: Point
        var rightKnee: Point
        var leftFoot: Point
        var rightFoot: Point

        static func mix(_ a: Pose, _ b: Pose, amount: Double) -> Pose {
            Pose(
                head: .mix(a.head, b.head, amount),
                neck: .mix(a.neck, b.neck, amount),
                leftShoulder: .mix(a.leftShoulder, b.leftShoulder, amount),
                rightShoulder: .mix(a.rightShoulder, b.rightShoulder, amount),
                leftElbow: .mix(a.leftElbow, b.leftElbow, amount),
                rightElbow: .mix(a.rightElbow, b.rightElbow, amount),
                leftHand: .mix(a.leftHand, b.leftHand, amount),
                rightHand: .mix(a.rightHand, b.rightHand, amount),
                hip: .mix(a.hip, b.hip, amount),
                leftKnee: .mix(a.leftKnee, b.leftKnee, amount),
                rightKnee: .mix(a.rightKnee, b.rightKnee, amount),
                leftFoot: .mix(a.leftFoot, b.leftFoot, amount),
                rightFoot: .mix(a.rightFoot, b.rightFoot, amount)
            )
        }
    }

    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        exercise: StrengthExerciseRow,
        profile: StrengthExerciseMotionProfile,
        variant: StrengthExerciseAnimationVariant?,
        phase: Double
    ) {
        let pingPong = 0.5 - 0.5 * cos(phase * .pi * 2)
        let amount = pingPong * pingPong * (3 - 2 * pingPong)
        let keyframes = keyframes(for: profile, variant: variant)
        let currentPose = Pose.mix(keyframes.0, keyframes.1, amount: amount)
        let bounds = CGRect(origin: .zero, size: size)
        let scale = min(size.width, size.height * 1.62)
        let drawingRect = CGRect(
            x: bounds.midX - scale / 2,
            y: bounds.midY - scale / 3.24,
            width: scale,
            height: scale / 1.62
        ).insetBy(dx: scale * 0.035, dy: scale * 0.02)

        drawStage(in: &context, rect: drawingRect)
        drawEquipment(
            in: &context,
            rect: drawingRect,
            pose: currentPose,
            profile: profile,
            variant: variant,
            equipment: exercise.equipment,
            opacity: 0.9
        )
        drawFigure(
            in: &context,
            rect: drawingRect,
            pose: currentPose,
            primaryMuscle: exercise.primaryMuscle
        )
        drawHeldEquipment(
            in: &context,
            rect: drawingRect,
            pose: currentPose,
            profile: profile,
            variant: variant,
            equipment: exercise.equipment
        )
    }

    private static func drawStage(in context: inout GraphicsContext, rect: CGRect) {
        let groundY = rect.minY + rect.height * 0.91
        let pool = CGRect(
            x: rect.minX + rect.width * 0.12,
            y: groundY - rect.height * 0.035,
            width: rect.width * 0.76,
            height: rect.height * 0.09
        )
        context.fill(
            Path(ellipseIn: pool),
            with: .radialGradient(
                Gradient(colors: [
                    StrandPalette.textPrimary.opacity(0.10),
                    StrandPalette.textPrimary.opacity(0),
                ]),
                center: CGPoint(x: pool.midX, y: pool.midY),
                startRadius: 0,
                endRadius: pool.width / 2
            )
        )
        var ground = Path()
        ground.move(to: CGPoint(x: rect.minX + rect.width * 0.13, y: groundY))
        ground.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.13, y: groundY))
        context.stroke(
            ground,
            with: .linearGradient(
                Gradient(colors: [
                    StrandPalette.hairline.opacity(0),
                    StrandPalette.hairline.opacity(0.95),
                    StrandPalette.hairline.opacity(0),
                ]),
                startPoint: CGPoint(x: rect.minX, y: groundY),
                endPoint: CGPoint(x: rect.maxX, y: groundY)
            ),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )
    }

    private static func drawFigure(
        in context: inout GraphicsContext,
        rect: CGRect,
        pose: Pose,
        primaryMuscle: String
    ) {
        func cg(_ point: Point) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }

        func mix(_ a: CGPoint, _ b: CGPoint, _ amount: CGFloat) -> CGPoint {
            CGPoint(
                x: a.x + (b.x - a.x) * amount,
                y: a.y + (b.y - a.y) * amount
            )
        }

        func segment(
            from start: CGPoint,
            to end: CGPoint,
            startWidth: CGFloat,
            endWidth: CGFloat,
            colors: [Color]
        ) {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(1, hypot(dx, dy))
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            var path = Path()
            path.move(
                to: CGPoint(
                    x: start.x + normal.dx * startWidth / 2,
                    y: start.y + normal.dy * startWidth / 2
                )
            )
            path.addLine(
                to: CGPoint(
                    x: end.x + normal.dx * endWidth / 2,
                    y: end.y + normal.dy * endWidth / 2
                )
            )
            path.addQuadCurve(
                to: CGPoint(
                    x: end.x - normal.dx * endWidth / 2,
                    y: end.y - normal.dy * endWidth / 2
                ),
                control: CGPoint(
                    x: end.x + dx / length * endWidth / 2,
                    y: end.y + dy / length * endWidth / 2
                )
            )
            path.addLine(
                to: CGPoint(
                    x: start.x - normal.dx * startWidth / 2,
                    y: start.y - normal.dy * startWidth / 2
                )
            )
            path.addQuadCurve(
                to: CGPoint(
                    x: start.x + normal.dx * startWidth / 2,
                    y: start.y + normal.dy * startWidth / 2
                ),
                control: CGPoint(
                    x: start.x - dx / length * startWidth / 2,
                    y: start.y - dy / length * startWidth / 2
                )
            )
            path.closeSubpath()
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(
                        x: min(start.x, end.x) - max(startWidth, endWidth) / 2,
                        y: min(start.y, end.y)
                    ),
                    endPoint: CGPoint(
                        x: max(start.x, end.x) + max(startWidth, endWidth) / 2,
                        y: max(start.y, end.y)
                    )
                )
            )
        }

        func segment(
            _ start: Point,
            _ end: Point,
            _ startWidth: CGFloat,
            _ endWidth: CGFloat,
            _ colors: [Color]
        ) {
            segment(
                from: cg(start),
                to: cg(end),
                startWidth: startWidth,
                endWidth: endWidth,
                colors: colors
            )
        }

        func circle(at center: CGPoint, diameter: CGFloat, colors: [Color]) {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .linearGradient(
                    Gradient(colors: colors),
                    startPoint: CGPoint(
                        x: center.x - diameter * 0.35,
                        y: center.y - diameter * 0.45
                    ),
                    endPoint: CGPoint(
                        x: center.x + diameter * 0.4,
                        y: center.y + diameter * 0.5
                    )
                )
            )
        }

        func circle(at point: Point, diameter: CGFloat, colors: [Color]) {
            circle(at: cg(point), diameter: diameter, colors: colors)
        }

        let bodyRear = [
            StrandPalette.textTertiary.opacity(0.78),
            StrandPalette.textSecondary.opacity(0.88),
        ]
        let bodyFront = [
            StrandPalette.textPrimary.opacity(0.98),
            StrandPalette.textSecondary.opacity(0.92),
            StrandPalette.textTertiary.opacity(0.92),
        ]
        let torsoColors = [
            StrandPalette.textPrimary.opacity(0.96),
            StrandPalette.metricCyan.opacity(0.52),
            StrandPalette.textTertiary.opacity(0.92),
        ]
        let muscleColors = [
            StrandPalette.effortColor.opacity(0.98),
            Color(red: 0.62, green: 0.02, blue: 0.06).opacity(0.96),
        ]
        let armUpper = max(7.5, rect.width * 0.043)
        let forearmUpper = max(6.2, rect.width * 0.034)
        let thighUpper = max(10, rect.width * 0.058)
        let calfUpper = max(8, rect.width * 0.045)
        let joint = max(7, rect.width * 0.037)

        // Rear limbs first, with tapered anatomy instead of constant-width skeleton strokes.
        segment(
            pose.leftShoulder,
            pose.leftElbow,
            armUpper,
            armUpper * 0.78,
            bodyRear
        )
        segment(
            pose.leftElbow,
            pose.leftHand,
            forearmUpper,
            forearmUpper * 0.62,
            bodyRear
        )
        segment(
            pose.hip,
            pose.leftKnee,
            thighUpper,
            thighUpper * 0.72,
            bodyRear
        )
        segment(
            pose.leftKnee,
            pose.leftFoot,
            calfUpper,
            calfUpper * 0.54,
            bodyRear
        )

        let shoulderLeft = cg(pose.leftShoulder)
        let shoulderRight = cg(pose.rightShoulder)
        let shoulderMid = CGPoint(
            x: (shoulderLeft.x + shoulderRight.x) / 2,
            y: (shoulderLeft.y + shoulderRight.y) / 2
        )
        let hip = cg(pose.hip)
        let axisX = hip.x - shoulderMid.x
        let axisY = hip.y - shoulderMid.y
        let axisLength = max(1, hypot(axisX, axisY))
        var normalX = -axisY / axisLength
        var normalY = axisX / axisLength
        let shoulderVectorX = shoulderRight.x - shoulderLeft.x
        let shoulderVectorY = shoulderRight.y - shoulderLeft.y
        if normalX * shoulderVectorX + normalY * shoulderVectorY < 0 {
            normalX *= -1
            normalY *= -1
        }
        let hipHalfWidth = max(8, rect.width * 0.043)
        let hipLeft = CGPoint(
            x: hip.x - normalX * hipHalfWidth,
            y: hip.y - normalY * hipHalfWidth
        )
        let hipRight = CGPoint(
            x: hip.x + normalX * hipHalfWidth,
            y: hip.y + normalY * hipHalfWidth
        )
        let waistCenter = CGPoint(
            x: shoulderMid.x + (hip.x - shoulderMid.x) * 0.70,
            y: shoulderMid.y + (hip.y - shoulderMid.y) * 0.70
        )
        let waistHalfWidth = max(7, rect.width * 0.036)
        let waistLeft = CGPoint(
            x: waistCenter.x - normalX * waistHalfWidth,
            y: waistCenter.y - normalY * waistHalfWidth
        )
        let waistRight = CGPoint(
            x: waistCenter.x + normalX * waistHalfWidth,
            y: waistCenter.y + normalY * waistHalfWidth
        )
        var torso = Path()
        torso.move(to: shoulderLeft)
        torso.addQuadCurve(
            to: shoulderRight,
            control: CGPoint(
                x: cg(pose.neck).x + normalX * rect.width * 0.006,
                y: cg(pose.neck).y + normalY * rect.width * 0.006
            )
        )
        torso.addQuadCurve(to: waistRight, control: mix(shoulderRight, waistRight, 0.58))
        torso.addQuadCurve(to: hipRight, control: mix(waistRight, hipRight, 0.55))
        torso.addQuadCurve(to: hipLeft, control: hip)
        torso.addQuadCurve(to: waistLeft, control: mix(hipLeft, waistLeft, 0.45))
        torso.addQuadCurve(to: shoulderLeft, control: mix(waistLeft, shoulderLeft, 0.42))
        torso.closeSubpath()
        context.fill(
            torso,
            with: .linearGradient(
                Gradient(colors: torsoColors),
                startPoint: CGPoint(x: torso.boundingRect.minX, y: torso.boundingRect.minY),
                endPoint: CGPoint(x: torso.boundingRect.maxX, y: torso.boundingRect.maxY)
            )
        )
        context.stroke(
            torso,
            with: .color(StrandPalette.textPrimary.opacity(0.22)),
            style: StrokeStyle(lineWidth: max(0.8, rect.width * 0.004), lineJoin: .round)
        )
        segment(
            pose.neck,
            Point(
                x: (pose.leftShoulder.x + pose.rightShoulder.x) / 2,
                y: (pose.leftShoulder.y + pose.rightShoulder.y) / 2
            ),
            armUpper * 0.70,
            armUpper * 0.85,
            bodyFront
        )

        var seam = Path()
        seam.move(to: shoulderMid)
        seam.addLine(to: waistCenter)
        context.stroke(
            seam,
            with: .color(StrandPalette.textPrimary.opacity(0.13)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round)
        )
        segment(
            from: hipLeft,
            to: hipRight,
            startWidth: thighUpper * 0.72,
            endWidth: thighUpper * 0.72,
            colors: torsoColors
        )

        // Front limbs use a brighter edge and remain readable when limbs cross.
        segment(
            pose.rightShoulder,
            pose.rightElbow,
            armUpper * 1.04,
            armUpper * 0.80,
            bodyFront
        )
        segment(
            pose.rightElbow,
            pose.rightHand,
            forearmUpper * 1.04,
            forearmUpper * 0.60,
            bodyFront
        )
        segment(
            pose.hip,
            pose.rightKnee,
            thighUpper * 1.04,
            thighUpper * 0.72,
            bodyFront
        )
        segment(
            pose.rightKnee,
            pose.rightFoot,
            calfUpper * 1.04,
            calfUpper * 0.52,
            bodyFront
        )

        let head = cg(pose.head)
        let headWidth = max(16, rect.width * 0.082)
        let headHeight = headWidth * 1.14
        circle(
            at: head,
            diameter: headWidth,
            colors: bodyFront
        )
        let headMask = CGRect(
            x: head.x - headWidth / 2,
            y: head.y - headHeight / 2,
            width: headWidth,
            height: headHeight
        )
        context.stroke(
            Path(ellipseIn: headMask),
            with: .color(StrandPalette.textPrimary.opacity(0.18)),
            lineWidth: max(0.8, rect.width * 0.0035)
        )
        let facing = pose.head.x >= pose.neck.x ? 1.0 : -1.0
        var face = Path()
        face.move(
            to: CGPoint(
                x: head.x + facing * headWidth * 0.12,
                y: head.y - headHeight * 0.08
            )
        )
        face.addLine(
            to: CGPoint(
                x: head.x + facing * headWidth * 0.28,
                y: head.y + headHeight * 0.03
            )
        )
        context.stroke(
            face,
            with: .color(StrandPalette.surfaceInset.opacity(0.5)),
            style: StrokeStyle(lineWidth: max(1, rect.width * 0.004), lineCap: .round)
        )

        for point in [pose.leftElbow, pose.rightElbow, pose.leftKnee, pose.rightKnee] {
            circle(at: point, diameter: joint, colors: bodyFront)
        }
        for point in [pose.leftHand, pose.rightHand] {
            circle(at: point, diameter: forearmUpper * 0.74, colors: bodyFront)
        }
        func drawFoot(_ foot: Point, knee: Point, colors: [Color]) {
            let direction = foot.x >= knee.x ? 1.0 : -1.0
            let toe = Point(x: foot.x + direction * 0.045, y: foot.y + 0.006)
            segment(
                foot,
                toe,
                calfUpper * 0.48,
                calfUpper * 0.34,
                colors
            )
        }
        drawFoot(pose.leftFoot, knee: pose.leftKnee, colors: bodyRear)
        drawFoot(pose.rightFoot, knee: pose.rightKnee, colors: bodyFront)

        func accent(_ start: Point, _ end: Point, _ startWidth: CGFloat, _ endWidth: CGFloat) {
            segment(start, end, startWidth, endWidth, muscleColors)
        }
        func accentCircle(_ point: Point, diameter: CGFloat) {
            circle(at: point, diameter: diameter, colors: muscleColors)
        }

        let upperArmAccent = armUpper * 0.56
        let thighAccent = thighUpper * 0.58
        switch primaryMuscle {
        case "chest":
            accent(
                .mix(pose.leftShoulder, pose.neck, 0.20),
                .mix(pose.neck, pose.hip, 0.42),
                upperArmAccent,
                upperArmAccent * 0.82
            )
            accent(
                .mix(pose.rightShoulder, pose.neck, 0.20),
                .mix(pose.neck, pose.hip, 0.42),
                upperArmAccent,
                upperArmAccent * 0.82
            )
        case "back":
            accent(
                .mix(pose.neck, pose.hip, 0.14),
                .mix(pose.neck, pose.hip, 0.68),
                armUpper * 0.74,
                armUpper * 0.52
            )
        case "shoulders":
            accentCircle(pose.leftShoulder, diameter: armUpper * 0.72)
            accentCircle(pose.rightShoulder, diameter: armUpper * 0.72)
        case "biceps", "triceps":
            accent(
                .mix(pose.leftShoulder, pose.leftElbow, 0.16),
                .mix(pose.leftShoulder, pose.leftElbow, 0.82),
                upperArmAccent,
                upperArmAccent * 0.78
            )
            accent(
                .mix(pose.rightShoulder, pose.rightElbow, 0.16),
                .mix(pose.rightShoulder, pose.rightElbow, 0.82),
                upperArmAccent,
                upperArmAccent * 0.78
            )
        case "forearms":
            accent(
                .mix(pose.leftElbow, pose.leftHand, 0.14),
                .mix(pose.leftElbow, pose.leftHand, 0.82),
                forearmUpper * 0.58,
                forearmUpper * 0.40
            )
            accent(
                .mix(pose.rightElbow, pose.rightHand, 0.14),
                .mix(pose.rightElbow, pose.rightHand, 0.82),
                forearmUpper * 0.58,
                forearmUpper * 0.40
            )
        case "core":
            accent(
                .mix(pose.neck, pose.hip, 0.42),
                .mix(pose.neck, pose.hip, 0.83),
                armUpper * 0.62,
                armUpper * 0.50
            )
        case "quadriceps", "hamstrings":
            accent(
                .mix(pose.hip, pose.leftKnee, 0.16),
                .mix(pose.hip, pose.leftKnee, 0.82),
                thighAccent,
                thighAccent * 0.66
            )
            accent(
                .mix(pose.hip, pose.rightKnee, 0.16),
                .mix(pose.hip, pose.rightKnee, 0.82),
                thighAccent,
                thighAccent * 0.66
            )
        case "glutes":
            accentCircle(pose.hip, diameter: thighUpper * 0.82)
        case "calves":
            accent(
                .mix(pose.leftKnee, pose.leftFoot, 0.18),
                .mix(pose.leftKnee, pose.leftFoot, 0.76),
                calfUpper * 0.58,
                calfUpper * 0.39
            )
            accent(
                .mix(pose.rightKnee, pose.rightFoot, 0.18),
                .mix(pose.rightKnee, pose.rightFoot, 0.76),
                calfUpper * 0.58,
                calfUpper * 0.39
            )
        case "full_body":
            accent(
                .mix(pose.neck, pose.hip, 0.22),
                .mix(pose.neck, pose.hip, 0.74),
                upperArmAccent,
                upperArmAccent * 0.76
            )
            accent(
                .mix(pose.hip, pose.rightKnee, 0.22),
                .mix(pose.hip, pose.rightKnee, 0.72),
                thighAccent * 0.74,
                thighAccent * 0.52
            )
        default:
            accent(
                .mix(pose.neck, pose.hip, 0.34),
                .mix(pose.neck, pose.hip, 0.68),
                upperArmAccent * 0.80,
                upperArmAccent * 0.64
            )
        }
    }

    private static func drawEquipment(
        in context: inout GraphicsContext,
        rect: CGRect,
        pose: Pose,
        profile: StrengthExerciseMotionProfile,
        variant: StrengthExerciseAnimationVariant?,
        equipment: String,
        opacity: Double
    ) {
        func cg(_ point: Point) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }

        func line(_ a: Point, _ b: Point, width: CGFloat = 2.2) {
            var path = Path()
            path.move(to: cg(a))
            path.addLine(to: cg(b))
            context.stroke(
                path,
                with: .color(StrandPalette.textTertiary.opacity(opacity)),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }

        func weight(at point: Point, size: Double = 0.035) {
            let center = cg(point)
            let diameter = rect.width * size
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .color(StrandPalette.textTertiary.opacity(opacity))
            )
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .color(StrandPalette.hairline.opacity(opacity)),
                lineWidth: 1
            )
        }

        func plate(at point: Point) {
            let center = cg(point)
            let plateWidth = max(5, rect.width * 0.022)
            let plateHeight = max(13, rect.width * 0.072)
            let plateRect = CGRect(
                x: center.x - plateWidth / 2,
                y: center.y - plateHeight / 2,
                width: plateWidth,
                height: plateHeight
            )
            context.fill(
                Path(roundedRect: plateRect, cornerRadius: plateWidth * 0.34),
                with: .color(StrandPalette.textTertiary.opacity(opacity))
            )
            let hub = max(2.5, plateWidth * 0.42)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - hub / 2,
                        y: center.y - hub / 2,
                        width: hub,
                        height: hub
                    )
                ),
                with: .color(StrandPalette.surfaceInset.opacity(opacity))
            )
        }

        func flatBench() {
            line(Point(x: 0.18, y: 0.61), Point(x: 0.72, y: 0.61), width: 5)
            line(Point(x: 0.29, y: 0.61), Point(x: 0.24, y: 0.83), width: 3)
            line(Point(x: 0.62, y: 0.61), Point(x: 0.67, y: 0.83), width: 3)
        }

        func cableTower(double: Bool = false) {
            line(Point(x: 0.87, y: 0.15), Point(x: 0.87, y: 0.88), width: 6)
            line(Point(x: 0.82, y: 0.15), Point(x: 0.92, y: 0.15), width: 4)
            if double {
                line(Point(x: 0.13, y: 0.15), Point(x: 0.13, y: 0.88), width: 6)
                line(Point(x: 0.08, y: 0.15), Point(x: 0.18, y: 0.15), width: 4)
            }
        }

        switch variant {
        case .benchPress, .dumbbellBenchPress, .chestFly, .skullCrusher:
            flatBench()
        case .inclineBenchPress, .chestSupportedRow:
            line(Point(x: 0.22, y: 0.72), Point(x: 0.55, y: 0.49), width: 6)
            line(Point(x: 0.29, y: 0.67), Point(x: 0.24, y: 0.85), width: 3)
            line(Point(x: 0.51, y: 0.52), Point(x: 0.62, y: 0.84), width: 3)
        case .pullUp, .chinUp, .hangingLegRaise:
            line(Point(x: 0.27, y: 0.11), Point(x: 0.73, y: 0.11), width: 4)
            line(Point(x: 0.29, y: 0.11), Point(x: 0.29, y: 0.19), width: 3)
            line(Point(x: 0.71, y: 0.11), Point(x: 0.71, y: 0.19), width: 3)
        case .latPulldown:
            cableTower()
            line(Point(x: 0.25, y: 0.10), Point(x: 0.75, y: 0.10), width: 3)
            line(Point(x: 0.50, y: 0.10), Point(x: 0.50, y: 0.20), width: 1.5)
            line(Point(x: 0.30, y: 0.79), Point(x: 0.56, y: 0.79), width: 5)
        case .legPress, .hackSquat:
            line(Point(x: 0.72, y: 0.25), Point(x: 0.82, y: 0.70), width: 7)
            line(Point(x: 0.18, y: 0.72), Point(x: 0.50, y: 0.83), width: 6)
            line(Point(x: 0.18, y: 0.82), Point(x: 0.82, y: 0.82), width: 3)
        case .legExtension, .lyingLegCurl, .seatedCalfRaise:
            line(Point(x: 0.28, y: 0.58), Point(x: 0.63, y: 0.58), width: 6)
            line(Point(x: 0.34, y: 0.58), Point(x: 0.30, y: 0.84), width: 3)
            line(Point(x: 0.72, y: 0.58), Point(x: 0.72, y: 0.82), width: 4)
        case .hipThrust:
            line(Point(x: 0.18, y: 0.56), Point(x: 0.43, y: 0.56), width: 6)
        case .bulgarianSplitSquat:
            line(Point(x: 0.16, y: 0.66), Point(x: 0.36, y: 0.66), width: 6)
            line(Point(x: 0.21, y: 0.66), Point(x: 0.19, y: 0.86), width: 3)
        case .dip:
            line(Point(x: 0.30, y: 0.42), Point(x: 0.46, y: 0.42), width: 4)
            line(Point(x: 0.54, y: 0.42), Point(x: 0.70, y: 0.42), width: 4)
            line(Point(x: 0.34, y: 0.42), Point(x: 0.34, y: 0.84), width: 3)
            line(Point(x: 0.66, y: 0.42), Point(x: 0.66, y: 0.84), width: 3)
        case .tricepsPushdown, .cableCrossover, .seatedCableRow, .facePull, .cableCrunch:
            cableTower(double: variant == .cableCrossover)
            if variant == .seatedCableRow {
                line(Point(x: 0.30, y: 0.77), Point(x: 0.67, y: 0.77), width: 5)
            }
        case .machineChestPress:
            line(Point(x: 0.28, y: 0.55), Point(x: 0.28, y: 0.84), width: 6)
            line(Point(x: 0.28, y: 0.58), Point(x: 0.52, y: 0.58), width: 5)
            line(Point(x: 0.70, y: 0.31), Point(x: 0.70, y: 0.83), width: 5)
        case .preacherCurl:
            line(Point(x: 0.31, y: 0.62), Point(x: 0.57, y: 0.48), width: 7)
            line(Point(x: 0.42, y: 0.56), Point(x: 0.35, y: 0.84), width: 3)
        case .indoorCycling:
            let center = cg(Point(x: 0.55, y: 0.68))
            let diameter = rect.width * 0.27
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .color(StrandPalette.textTertiary.opacity(opacity)),
                lineWidth: 3
            )
            line(Point(x: 0.39, y: 0.52), Point(x: 0.55, y: 0.68), width: 3)
            line(Point(x: 0.55, y: 0.68), Point(x: 0.72, y: 0.49), width: 3)
            line(Point(x: 0.42, y: 0.48), Point(x: 0.48, y: 0.48), width: 5)
        case .rowingErgometer:
            line(Point(x: 0.22, y: 0.76), Point(x: 0.82, y: 0.76), width: 4)
            line(Point(x: 0.75, y: 0.47), Point(x: 0.82, y: 0.76), width: 5)
            weight(at: Point(x: 0.78, y: 0.51), size: 0.10)
        case .stairClimber:
            for index in 0..<4 {
                let x = 0.45 + Double(index) * 0.1
                let y = 0.82 - Double(index) * 0.11
                line(Point(x: x, y: y), Point(x: x + 0.12, y: y), width: 5)
            }
            line(Point(x: 0.84, y: 0.40), Point(x: 0.84, y: 0.83), width: 4)
        case .treadmillRun:
            line(Point(x: 0.16, y: 0.88), Point(x: 0.84, y: 0.88), width: 7)
            line(Point(x: 0.76, y: 0.88), Point(x: 0.84, y: 0.50), width: 4)
            line(Point(x: 0.69, y: 0.50), Point(x: 0.88, y: 0.50), width: 4)
        case .backExtension:
            line(Point(x: 0.42, y: 0.58), Point(x: 0.64, y: 0.78), width: 7)
            line(Point(x: 0.55, y: 0.70), Point(x: 0.47, y: 0.88), width: 3)
        case .abWheelRollout:
            weight(at: pose.leftHand, size: 0.07)
        default:
            switch profile {
            case .benchPress, .chestFly, .skullCrusher:
                flatBench()
            case .pullUp:
                line(Point(x: 0.27, y: 0.11), Point(x: 0.73, y: 0.11), width: 4)
            case .latPulldown:
                cableTower()
            case .legPress:
                line(Point(x: 0.72, y: 0.25), Point(x: 0.82, y: 0.70), width: 7)
            case .legExtension, .legCurl:
                line(Point(x: 0.28, y: 0.58), Point(x: 0.63, y: 0.58), width: 6)
            case .hipThrust:
                line(Point(x: 0.18, y: 0.56), Point(x: 0.43, y: 0.56), width: 6)
            case .dip:
                line(Point(x: 0.30, y: 0.42), Point(x: 0.70, y: 0.42), width: 4)
            case .backExtension:
                line(Point(x: 0.42, y: 0.58), Point(x: 0.64, y: 0.78), width: 7)
            case .abRollout:
                weight(at: pose.leftHand, size: 0.07)
            default:
                break
            }
        }
    }

    private static func drawHeldEquipment(
        in context: inout GraphicsContext,
        rect: CGRect,
        pose: Pose,
        profile: StrengthExerciseMotionProfile,
        variant: StrengthExerciseAnimationVariant?,
        equipment: String
    ) {
        func cg(_ point: Point) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }

        func line(_ a: Point, _ b: Point, width: CGFloat, color: Color) {
            var path = Path()
            path.move(to: cg(a))
            path.addLine(to: cg(b))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round)
            )
        }

        func disc(at point: Point, diameter: CGFloat, color: Color) {
            let center = cg(point)
            let frame = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(
                Path(ellipseIn: frame),
                with: .linearGradient(
                    Gradient(colors: [
                        StrandPalette.textPrimary.opacity(0.88),
                        color,
                        StrandPalette.surfaceInset.opacity(0.96),
                    ]),
                    startPoint: CGPoint(x: frame.minX, y: frame.minY),
                    endPoint: CGPoint(x: frame.maxX, y: frame.maxY)
                )
            )
            context.stroke(
                Path(ellipseIn: frame),
                with: .color(StrandPalette.textPrimary.opacity(0.28)),
                lineWidth: 1
            )
        }

        func dumbbell(at point: Point) {
            let center = cg(point)
            let span = rect.width * 0.043
            let axisA = Point(
                x: Double((center.x - span / 2 - rect.minX) / rect.width),
                y: point.y
            )
            let axisB = Point(
                x: Double((center.x + span / 2 - rect.minX) / rect.width),
                y: point.y
            )
            line(
                axisA,
                axisB,
                width: max(2, rect.width * 0.008),
                color: StrandPalette.textPrimary.opacity(0.9)
            )
            disc(at: axisA, diameter: max(8, rect.width * 0.032), color: StrandPalette.textTertiary)
            disc(at: axisB, diameter: max(8, rect.width * 0.032), color: StrandPalette.textTertiary)
        }

        let steel = StrandPalette.textSecondary.opacity(0.96)
        switch equipment {
        case "barbell":
            let leftAnchor: Point
            let rightAnchor: Point
            switch variant {
            case .backSquat:
                leftAnchor = pose.leftShoulder
                rightAnchor = pose.rightShoulder
            case .hipThrust:
                leftAnchor = Point(x: pose.hip.x - 0.08, y: pose.hip.y)
                rightAnchor = Point(x: pose.hip.x + 0.08, y: pose.hip.y)
            default:
                leftAnchor = pose.leftHand
                rightAnchor = pose.rightHand
            }
            let centerX = (leftAnchor.x + rightAnchor.x) / 2
            let centerY = (leftAnchor.y + rightAnchor.y) / 2
            let halfSpan = max(abs(rightAnchor.x - leftAnchor.x) / 2 + 0.12, 0.19)
            let left = Point(x: centerX - halfSpan, y: centerY)
            let right = Point(x: centerX + halfSpan, y: centerY)
            line(
                Point(x: left.x - 0.025, y: centerY),
                Point(x: right.x + 0.025, y: centerY),
                width: max(2.5, rect.width * 0.009),
                color: steel
            )
            disc(at: left, diameter: max(14, rect.width * 0.063), color: StrandPalette.textTertiary)
            disc(at: right, diameter: max(14, rect.width * 0.063), color: StrandPalette.textTertiary)
        case "dumbbell":
            if variant == .gobletSquat {
                dumbbell(at: .mix(pose.leftHand, pose.rightHand, 0.5))
            } else if variant == .oneArmDumbbellRow {
                dumbbell(at: pose.rightHand)
            } else {
                dumbbell(at: pose.leftHand)
                dumbbell(at: pose.rightHand)
            }
        case "kettlebell":
            let center = Point.mix(pose.leftHand, pose.rightHand, 0.5)
            disc(
                at: Point(x: center.x, y: center.y + 0.025),
                diameter: max(13, rect.width * 0.056),
                color: StrandPalette.textTertiary
            )
            var handle = Path()
            let cgCenter = cg(center)
            handle.addArc(
                center: CGPoint(x: cgCenter.x, y: cgCenter.y + rect.width * 0.008),
                radius: rect.width * 0.026,
                startAngle: .degrees(195),
                endAngle: .degrees(345),
                clockwise: false
            )
            context.stroke(
                handle,
                with: .color(steel),
                style: StrokeStyle(lineWidth: max(2, rect.width * 0.008), lineCap: .round)
            )
        case "band":
            line(
                pose.leftHand,
                pose.rightHand,
                width: max(2.5, rect.width * 0.009),
                color: StrandPalette.effortColor.opacity(0.92)
            )
        case "cable":
            if variant == .cableCrossover {
                line(
                    Point(x: 0.13, y: 0.20),
                    pose.leftHand,
                    width: 1.6,
                    color: steel.opacity(0.72)
                )
                line(
                    Point(x: 0.87, y: 0.20),
                    pose.rightHand,
                    width: 1.6,
                    color: steel.opacity(0.72)
                )
            } else {
                line(
                    Point(x: 0.87, y: variant == .seatedCableRow ? 0.66 : 0.18),
                    pose.rightHand,
                    width: 1.6,
                    color: steel.opacity(0.72)
                )
            }
        default:
            if profile == .abRollout {
                disc(
                    at: Point.mix(pose.leftHand, pose.rightHand, 0.5),
                    diameter: max(15, rect.width * 0.068),
                    color: StrandPalette.textTertiary
                )
            }
        }
    }

    private static func drawMotionTrack(
        in context: inout GraphicsContext,
        rect: CGRect,
        from start: Pose,
        to end: Pose
    ) {
        func cg(_ point: Point) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }
        let candidates = [
            (start.leftHand, end.leftHand),
            (start.rightHand, end.rightHand),
            (start.leftFoot, end.leftFoot),
            (start.rightFoot, end.rightFoot),
            (start.hip, end.hip),
            (start.head, end.head),
        ]
        guard let movement = candidates.max(by: { lhs, rhs in
            let lhsStart = cg(lhs.0)
            let lhsEnd = cg(lhs.1)
            let rhsStart = cg(rhs.0)
            let rhsEnd = cg(rhs.1)
            return hypot(lhsEnd.x - lhsStart.x, lhsEnd.y - lhsStart.y)
                < hypot(rhsEnd.x - rhsStart.x, rhsEnd.y - rhsStart.y)
        }) else { return }
        let startPoint = cg(movement.0)
        let endPoint = cg(movement.1)
        let dx = endPoint.x - startPoint.x
        let dy = endPoint.y - startPoint.y
        let distance = hypot(dx, dy)
        guard distance > rect.width * 0.025 else { return }
        let bend = min(rect.width * 0.026, distance * 0.18)
        let control = CGPoint(
            x: (startPoint.x + endPoint.x) / 2 - dy / distance * bend,
            y: (startPoint.y + endPoint.y) / 2 + dx / distance * bend
        )
        var track = Path()
        track.move(to: startPoint)
        track.addQuadCurve(
            to: endPoint,
            control: control
        )
        context.stroke(
            track,
            with: .color(StrandPalette.metricCyan.opacity(0.38)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [3, 5])
        )
        let endpointSize = max(5, rect.width * 0.022)
        for endpoint in [startPoint, endPoint] {
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: endpoint.x - endpointSize / 2,
                        y: endpoint.y - endpointSize / 2,
                        width: endpointSize,
                        height: endpointSize
                    )
                ),
                with: .color(StrandPalette.metricCyan.opacity(0.55)),
                lineWidth: 1.2
            )
        }
    }

    private static func keyframes(
        for profile: StrengthExerciseMotionProfile,
        variant: StrengthExerciseAnimationVariant?
    ) -> (Pose, Pose) {
        var (start, end) = baseKeyframes(for: profile)
        guard let variant else { return (start, end) }

        switch variant {
        case .frontSquat:
            start.leftElbow = Point(x: 0.34, y: 0.31)
            start.rightElbow = Point(x: 0.66, y: 0.31)
            start.leftHand = Point(x: 0.45, y: 0.27)
            start.rightHand = Point(x: 0.55, y: 0.27)
            end.leftElbow = Point(x: 0.34, y: 0.42)
            end.rightElbow = Point(x: 0.66, y: 0.42)
            end.leftHand = Point(x: 0.45, y: 0.38)
            end.rightHand = Point(x: 0.55, y: 0.38)
        case .gobletSquat:
            start.leftElbow = Point(x: 0.42, y: 0.40)
            start.rightElbow = Point(x: 0.58, y: 0.40)
            start.leftHand = Point(x: 0.47, y: 0.34)
            start.rightHand = Point(x: 0.53, y: 0.34)
            end.leftElbow = Point(x: 0.40, y: 0.51)
            end.rightElbow = Point(x: 0.60, y: 0.51)
            end.leftHand = Point(x: 0.47, y: 0.45)
            end.rightHand = Point(x: 0.53, y: 0.45)
        case .hackSquat:
            start = sideStanding()
            start.leftShoulder = Point(x: 0.55, y: 0.29)
            start.rightShoulder = Point(x: 0.59, y: 0.31)
            start.hip = Point(x: 0.52, y: 0.55)
            start.leftFoot = Point(x: 0.64, y: 0.89)
            start.rightFoot = Point(x: 0.70, y: 0.89)
            end = start
            shiftUpper(&end, dy: 0.12)
            end.hip = Point(x: 0.47, y: 0.66)
            end.leftKnee = Point(x: 0.61, y: 0.71)
            end.rightKnee = Point(x: 0.67, y: 0.73)
        case .romanianDeadlift:
            end.leftKnee = Point(x: 0.49, y: 0.73)
            end.rightKnee = Point(x: 0.55, y: 0.74)
            end.hip = Point(x: 0.43, y: 0.57)
            end.head = Point(x: 0.68, y: 0.36)
            end.neck = Point(x: 0.61, y: 0.41)
            end.leftShoulder = Point(x: 0.57, y: 0.44)
            end.rightShoulder = Point(x: 0.61, y: 0.46)
        case .gluteBridge:
            start.head = Point(x: 0.22, y: 0.66)
            start.neck = Point(x: 0.30, y: 0.65)
            start.leftShoulder = Point(x: 0.35, y: 0.64)
            start.rightShoulder = Point(x: 0.38, y: 0.67)
            start.hip = Point(x: 0.57, y: 0.72)
            end = start
            end.hip = Point(x: 0.58, y: 0.51)
            end.leftKnee = Point(x: 0.72, y: 0.66)
            end.rightKnee = Point(x: 0.76, y: 0.68)
        case .bulgarianSplitSquat:
            start = sideStanding()
            start.leftKnee = Point(x: 0.38, y: 0.70)
            start.leftFoot = Point(x: 0.29, y: 0.65)
            start.rightKnee = Point(x: 0.61, y: 0.72)
            start.rightFoot = Point(x: 0.72, y: 0.88)
            end = start
            shiftUpper(&end, dy: 0.11)
            end.hip = Point(x: 0.50, y: 0.65)
            end.leftKnee = Point(x: 0.40, y: 0.75)
            end.rightKnee = Point(x: 0.64, y: 0.70)
        case .walkingLunge:
            start = sideStanding()
            start.leftFoot = Point(x: 0.31, y: 0.88)
            start.rightFoot = Point(x: 0.64, y: 0.88)
            end.hip.x += 0.06
            end.head.x += 0.06
            end.neck.x += 0.06
            end.leftShoulder.x += 0.06
            end.rightShoulder.x += 0.06
        case .seatedCalfRaise:
            start = seated()
            start.leftFoot = Point(x: 0.67, y: 0.85)
            start.rightFoot = Point(x: 0.73, y: 0.86)
            end = start
            end.leftFoot.y -= 0.045
            end.rightFoot.y -= 0.045
            end.leftKnee.y -= 0.012
            end.rightKnee.y -= 0.012
        case .inclineBenchPress:
            start = rotated(start, around: Point(x: 0.58, y: 0.56), radians: -0.34)
            end = rotated(end, around: Point(x: 0.58, y: 0.56), radians: -0.34)
        case .cableCrossover:
            start = standing()
            start.leftElbow = Point(x: 0.29, y: 0.34)
            start.rightElbow = Point(x: 0.71, y: 0.34)
            start.leftHand = Point(x: 0.17, y: 0.31)
            start.rightHand = Point(x: 0.83, y: 0.31)
            end = start
            end.leftElbow = Point(x: 0.39, y: 0.44)
            end.rightElbow = Point(x: 0.61, y: 0.44)
            end.leftHand = Point(x: 0.47, y: 0.48)
            end.rightHand = Point(x: 0.53, y: 0.48)
        case .machineChestPress:
            start = seated()
            start.leftElbow = Point(x: 0.49, y: 0.46)
            start.rightElbow = Point(x: 0.53, y: 0.49)
            start.leftHand = Point(x: 0.58, y: 0.43)
            start.rightHand = Point(x: 0.61, y: 0.46)
            end = start
            end.leftElbow = Point(x: 0.60, y: 0.43)
            end.rightElbow = Point(x: 0.63, y: 0.46)
            end.leftHand = Point(x: 0.76, y: 0.42)
            end.rightHand = Point(x: 0.79, y: 0.45)
        case .oneArmDumbbellRow:
            start = bentOver()
            start.leftHand = Point(x: 0.78, y: 0.68)
            start.leftElbow = Point(x: 0.66, y: 0.57)
            start.rightHand = Point(x: 0.65, y: 0.73)
            end = start
            end.rightElbow = Point(x: 0.53, y: 0.50)
            end.rightHand = Point(x: 0.57, y: 0.56)
        case .seatedCableRow, .resistanceBandRow:
            start = seated()
            start.leftElbow = Point(x: 0.52, y: 0.47)
            start.rightElbow = Point(x: 0.55, y: 0.49)
            start.leftHand = Point(x: 0.72, y: 0.53)
            start.rightHand = Point(x: 0.75, y: 0.55)
            end = start
            end.leftElbow = Point(x: 0.43, y: 0.46)
            end.rightElbow = Point(x: 0.47, y: 0.48)
            end.leftHand = Point(x: 0.50, y: 0.51)
            end.rightHand = Point(x: 0.53, y: 0.53)
        case .chestSupportedRow:
            start = prone()
            start = rotated(start, around: Point(x: 0.58, y: 0.59), radians: -0.30)
            start.leftHand = Point(x: 0.61, y: 0.71)
            start.rightHand = Point(x: 0.66, y: 0.72)
            end = start
            end.leftElbow = Point(x: 0.50, y: 0.48)
            end.rightElbow = Point(x: 0.55, y: 0.50)
            end.leftHand = Point(x: 0.55, y: 0.57)
            end.rightHand = Point(x: 0.60, y: 0.59)
        case .chinUp:
            start.leftHand = Point(x: 0.42, y: 0.11)
            start.rightHand = Point(x: 0.58, y: 0.11)
            end.leftHand = start.leftHand
            end.rightHand = start.rightHand
            end.leftElbow = Point(x: 0.38, y: 0.29)
            end.rightElbow = Point(x: 0.62, y: 0.29)
        case .facePull:
            start = standing()
            start.leftHand = Point(x: 0.73, y: 0.35)
            start.rightHand = Point(x: 0.77, y: 0.37)
            start.leftElbow = Point(x: 0.57, y: 0.39)
            start.rightElbow = Point(x: 0.61, y: 0.41)
            end = start
            end.leftElbow = Point(x: 0.37, y: 0.30)
            end.rightElbow = Point(x: 0.63, y: 0.30)
            end.leftHand = Point(x: 0.47, y: 0.25)
            end.rightHand = Point(x: 0.53, y: 0.25)
        case .preacherCurl:
            start = seated()
            start.leftElbow = Point(x: 0.54, y: 0.51)
            start.rightElbow = Point(x: 0.58, y: 0.53)
            start.leftHand = Point(x: 0.62, y: 0.65)
            start.rightHand = Point(x: 0.66, y: 0.66)
            end = start
            end.leftHand = Point(x: 0.52, y: 0.38)
            end.rightHand = Point(x: 0.56, y: 0.39)
        case .sidePlank:
            start = plank()
            start.leftElbow = Point(x: 0.37, y: 0.68)
            start.leftHand = Point(x: 0.31, y: 0.75)
            start.rightShoulder = Point(x: 0.43, y: 0.47)
            start.rightElbow = Point(x: 0.46, y: 0.30)
            start.rightHand = Point(x: 0.48, y: 0.17)
            end = start
            end.hip.y -= 0.035
            end.head.y -= 0.018
        default:
            break
        }
        return (start, end)
    }

    private static func baseKeyframes(
        for profile: StrengthExerciseMotionProfile
    ) -> (Pose, Pose) {
        var start = standing()
        var end = standing()

        switch profile {
        case .squat:
            start.leftHand = Point(x: 0.43, y: 0.29)
            start.rightHand = Point(x: 0.57, y: 0.29)
            start.leftElbow = Point(x: 0.36, y: 0.34)
            start.rightElbow = Point(x: 0.64, y: 0.34)
            end = start
            end.head.y = 0.28
            end.neck.y = 0.36
            end.leftShoulder.y = 0.39
            end.rightShoulder.y = 0.39
            end.leftElbow.y += 0.11
            end.rightElbow.y += 0.11
            end.leftHand.y += 0.11
            end.rightHand.y += 0.11
            end.hip = Point(x: 0.50, y: 0.63)
            end.leftKnee = Point(x: 0.36, y: 0.70)
            end.rightKnee = Point(x: 0.64, y: 0.70)
        case .legPress:
            start = seated()
            start.leftFoot = Point(x: 0.76, y: 0.48)
            start.rightFoot = Point(x: 0.78, y: 0.55)
            start.leftKnee = Point(x: 0.57, y: 0.64)
            start.rightKnee = Point(x: 0.60, y: 0.70)
            end = start
            end.leftKnee = Point(x: 0.67, y: 0.54)
            end.rightKnee = Point(x: 0.69, y: 0.59)
            end.leftFoot = Point(x: 0.80, y: 0.38)
            end.rightFoot = Point(x: 0.82, y: 0.45)
        case .deadlift:
            start = sideStanding()
            start.leftHand = Point(x: 0.48, y: 0.56)
            start.rightHand = Point(x: 0.52, y: 0.56)
            end = start
            end.head = Point(x: 0.63, y: 0.31)
            end.neck = Point(x: 0.58, y: 0.38)
            end.leftShoulder = Point(x: 0.56, y: 0.41)
            end.rightShoulder = Point(x: 0.59, y: 0.43)
            end.hip = Point(x: 0.46, y: 0.58)
            end.leftElbow = Point(x: 0.59, y: 0.58)
            end.rightElbow = Point(x: 0.62, y: 0.59)
            end.leftHand = Point(x: 0.61, y: 0.76)
            end.rightHand = Point(x: 0.65, y: 0.76)
            end.leftKnee = Point(x: 0.53, y: 0.73)
            end.rightKnee = Point(x: 0.57, y: 0.74)
        case .hipThrust:
            start = lying()
            start.head = Point(x: 0.27, y: 0.48)
            start.neck = Point(x: 0.34, y: 0.52)
            start.hip = Point(x: 0.57, y: 0.69)
            start.leftKnee = Point(x: 0.72, y: 0.70)
            start.rightKnee = Point(x: 0.76, y: 0.72)
            start.leftFoot = Point(x: 0.79, y: 0.87)
            start.rightFoot = Point(x: 0.84, y: 0.87)
            end = start
            end.hip = Point(x: 0.58, y: 0.48)
            end.leftKnee = Point(x: 0.72, y: 0.64)
            end.rightKnee = Point(x: 0.76, y: 0.66)
        case .lunge:
            start = sideStanding()
            end = start
            end.hip = Point(x: 0.49, y: 0.58)
            end.leftKnee = Point(x: 0.34, y: 0.68)
            end.leftFoot = Point(x: 0.27, y: 0.88)
            end.rightKnee = Point(x: 0.65, y: 0.72)
            end.rightFoot = Point(x: 0.78, y: 0.88)
            shiftUpper(&end, dy: 0.08)
        case .benchPress:
            start = lying()
            start.leftElbow = Point(x: 0.38, y: 0.54)
            start.rightElbow = Point(x: 0.44, y: 0.57)
            start.leftHand = Point(x: 0.38, y: 0.36)
            start.rightHand = Point(x: 0.46, y: 0.36)
            end = start
            end.leftElbow = Point(x: 0.39, y: 0.33)
            end.rightElbow = Point(x: 0.45, y: 0.33)
            end.leftHand = Point(x: 0.39, y: 0.19)
            end.rightHand = Point(x: 0.45, y: 0.19)
        case .pushUp:
            start = plank()
            end = start
            shiftUpper(&end, dy: 0.12)
            end.leftElbow = Point(x: 0.37, y: 0.67)
            end.rightElbow = Point(x: 0.42, y: 0.70)
        case .chestFly:
            start = lying()
            start.leftElbow = Point(x: 0.27, y: 0.40)
            start.rightElbow = Point(x: 0.55, y: 0.40)
            start.leftHand = Point(x: 0.20, y: 0.43)
            start.rightHand = Point(x: 0.62, y: 0.43)
            end = start
            end.leftElbow = Point(x: 0.36, y: 0.29)
            end.rightElbow = Point(x: 0.46, y: 0.29)
            end.leftHand = Point(x: 0.39, y: 0.18)
            end.rightHand = Point(x: 0.43, y: 0.18)
        case .overheadPress:
            start.leftElbow = Point(x: 0.39, y: 0.41)
            start.rightElbow = Point(x: 0.61, y: 0.41)
            start.leftHand = Point(x: 0.42, y: 0.31)
            start.rightHand = Point(x: 0.58, y: 0.31)
            end = start
            end.leftElbow = Point(x: 0.44, y: 0.20)
            end.rightElbow = Point(x: 0.56, y: 0.20)
            end.leftHand = Point(x: 0.45, y: 0.09)
            end.rightHand = Point(x: 0.55, y: 0.09)
        case .lateralRaise:
            start.leftHand = Point(x: 0.43, y: 0.56)
            start.rightHand = Point(x: 0.57, y: 0.56)
            end = start
            end.leftElbow = Point(x: 0.30, y: 0.31)
            end.rightElbow = Point(x: 0.70, y: 0.31)
            end.leftHand = Point(x: 0.16, y: 0.31)
            end.rightHand = Point(x: 0.84, y: 0.31)
        case .rearDeltFly:
            start = bentOver()
            end = start
            end.leftElbow = Point(x: 0.48, y: 0.30)
            end.rightElbow = Point(x: 0.72, y: 0.45)
            end.leftHand = Point(x: 0.42, y: 0.24)
            end.rightHand = Point(x: 0.81, y: 0.43)
        case .row:
            start = bentOver()
            end = start
            end.leftElbow = Point(x: 0.48, y: 0.48)
            end.rightElbow = Point(x: 0.52, y: 0.50)
            end.leftHand = Point(x: 0.55, y: 0.55)
            end.rightHand = Point(x: 0.59, y: 0.56)
        case .pullUp:
            start = hanging()
            end = start
            shiftBody(&end, dy: -0.18)
            end.leftElbow = Point(x: 0.36, y: 0.29)
            end.rightElbow = Point(x: 0.64, y: 0.29)
            end.leftHand = start.leftHand
            end.rightHand = start.rightHand
        case .latPulldown:
            start = seated()
            start.leftHand = Point(x: 0.34, y: 0.13)
            start.rightHand = Point(x: 0.66, y: 0.13)
            start.leftElbow = Point(x: 0.40, y: 0.25)
            start.rightElbow = Point(x: 0.60, y: 0.25)
            end = start
            end.leftElbow = Point(x: 0.35, y: 0.39)
            end.rightElbow = Point(x: 0.65, y: 0.39)
            end.leftHand = Point(x: 0.43, y: 0.33)
            end.rightHand = Point(x: 0.57, y: 0.33)
        case .bandPullApart:
            start.leftHand = Point(x: 0.43, y: 0.36)
            start.rightHand = Point(x: 0.57, y: 0.36)
            start.leftElbow = Point(x: 0.39, y: 0.36)
            start.rightElbow = Point(x: 0.61, y: 0.36)
            end = start
            end.leftHand = Point(x: 0.20, y: 0.34)
            end.rightHand = Point(x: 0.80, y: 0.34)
            end.leftElbow = Point(x: 0.34, y: 0.34)
            end.rightElbow = Point(x: 0.66, y: 0.34)
        case .curl:
            start.leftHand = Point(x: 0.43, y: 0.59)
            start.rightHand = Point(x: 0.57, y: 0.59)
            start.leftElbow = Point(x: 0.43, y: 0.44)
            start.rightElbow = Point(x: 0.57, y: 0.44)
            end = start
            end.leftHand = Point(x: 0.43, y: 0.29)
            end.rightHand = Point(x: 0.57, y: 0.29)
        case .tricepsPushdown:
            start.leftElbow = Point(x: 0.43, y: 0.40)
            start.rightElbow = Point(x: 0.57, y: 0.40)
            start.leftHand = Point(x: 0.44, y: 0.42)
            start.rightHand = Point(x: 0.56, y: 0.42)
            end = start
            end.leftHand = Point(x: 0.42, y: 0.61)
            end.rightHand = Point(x: 0.58, y: 0.61)
        case .tricepsExtension:
            start.leftElbow = Point(x: 0.44, y: 0.18)
            start.rightElbow = Point(x: 0.56, y: 0.18)
            start.leftHand = Point(x: 0.48, y: 0.31)
            start.rightHand = Point(x: 0.52, y: 0.31)
            end = start
            end.leftHand = Point(x: 0.47, y: 0.08)
            end.rightHand = Point(x: 0.53, y: 0.08)
        case .skullCrusher:
            start = lying()
            start.leftElbow = Point(x: 0.39, y: 0.29)
            start.rightElbow = Point(x: 0.45, y: 0.29)
            start.leftHand = Point(x: 0.31, y: 0.40)
            start.rightHand = Point(x: 0.37, y: 0.40)
            end = start
            end.leftHand = Point(x: 0.39, y: 0.16)
            end.rightHand = Point(x: 0.45, y: 0.16)
        case .dip:
            start = standing()
            start.leftHand = Point(x: 0.42, y: 0.43)
            start.rightHand = Point(x: 0.58, y: 0.43)
            start.leftElbow = Point(x: 0.42, y: 0.36)
            start.rightElbow = Point(x: 0.58, y: 0.36)
            end = start
            shiftBody(&end, dy: 0.13)
            end.leftHand = start.leftHand
            end.rightHand = start.rightHand
            end.leftElbow = Point(x: 0.35, y: 0.42)
            end.rightElbow = Point(x: 0.65, y: 0.42)
        case .legExtension:
            start = seated()
            end = start
            end.leftKnee = Point(x: 0.64, y: 0.66)
            end.rightKnee = Point(x: 0.66, y: 0.70)
            end.leftFoot = Point(x: 0.83, y: 0.65)
            end.rightFoot = Point(x: 0.85, y: 0.70)
        case .legCurl:
            start = prone()
            end = start
            end.leftKnee = Point(x: 0.66, y: 0.62)
            end.rightKnee = Point(x: 0.70, y: 0.64)
            end.leftFoot = Point(x: 0.61, y: 0.39)
            end.rightFoot = Point(x: 0.66, y: 0.40)
        case .calfRaise:
            start = standing()
            end = start
            shiftBody(&end, dy: -0.045)
            end.leftFoot.y -= 0.015
            end.rightFoot.y -= 0.015
        case .plank:
            start = plank()
            end = start
            end.hip.y -= 0.025
            end.head.y -= 0.015
        case .sidePlank:
            start = plank()
            start.leftHand = Point(x: 0.39, y: 0.74)
            start.rightHand = Point(x: 0.54, y: 0.31)
            start.rightElbow = Point(x: 0.48, y: 0.41)
            end = start
            end.hip.y -= 0.04
        case .hangingLegRaise:
            start = hanging()
            end = start
            end.leftKnee = Point(x: 0.41, y: 0.61)
            end.rightKnee = Point(x: 0.59, y: 0.61)
            end.leftFoot = Point(x: 0.35, y: 0.48)
            end.rightFoot = Point(x: 0.65, y: 0.48)
        case .cableCrunch:
            start = kneeling()
            end = start
            end.head = Point(x: 0.57, y: 0.44)
            end.neck = Point(x: 0.54, y: 0.51)
            end.leftShoulder = Point(x: 0.50, y: 0.53)
            end.rightShoulder = Point(x: 0.55, y: 0.55)
        case .abRollout:
            start = kneeling()
            start.leftHand = Point(x: 0.56, y: 0.70)
            start.rightHand = Point(x: 0.60, y: 0.72)
            end = start
            end.head = Point(x: 0.70, y: 0.54)
            end.neck = Point(x: 0.65, y: 0.58)
            end.leftShoulder = Point(x: 0.62, y: 0.60)
            end.rightShoulder = Point(x: 0.65, y: 0.62)
            end.leftHand = Point(x: 0.78, y: 0.76)
            end.rightHand = Point(x: 0.82, y: 0.77)
        case .carry:
            start = sideStanding()
            end = start
            start.leftKnee = Point(x: 0.43, y: 0.72)
            start.leftFoot = Point(x: 0.57, y: 0.88)
            end.rightKnee = Point(x: 0.49, y: 0.72)
            end.rightFoot = Point(x: 0.35, y: 0.88)
        case .kettlebellSwing:
            start = bentOver()
            start.leftHand = Point(x: 0.58, y: 0.69)
            start.rightHand = Point(x: 0.62, y: 0.70)
            end = sideStanding()
            end.leftElbow = Point(x: 0.59, y: 0.37)
            end.rightElbow = Point(x: 0.62, y: 0.39)
            end.leftHand = Point(x: 0.74, y: 0.35)
            end.rightHand = Point(x: 0.77, y: 0.37)
        case .backExtension:
            start = bentOver()
            start.hip = Point(x: 0.52, y: 0.61)
            start.leftKnee = Point(x: 0.65, y: 0.70)
            start.rightKnee = Point(x: 0.68, y: 0.73)
            end = start
            end.head = Point(x: 0.28, y: 0.34)
            end.neck = Point(x: 0.34, y: 0.39)
            end.leftShoulder = Point(x: 0.38, y: 0.42)
            end.rightShoulder = Point(x: 0.40, y: 0.44)
        case .run:
            start = sideStanding()
            start.leftElbow = Point(x: 0.39, y: 0.35)
            start.leftHand = Point(x: 0.51, y: 0.42)
            start.rightElbow = Point(x: 0.59, y: 0.39)
            start.rightHand = Point(x: 0.46, y: 0.48)
            start.leftKnee = Point(x: 0.62, y: 0.66)
            start.leftFoot = Point(x: 0.73, y: 0.78)
            start.rightFoot = Point(x: 0.35, y: 0.88)
            end = start
            end.leftElbow = Point(x: 0.56, y: 0.38)
            end.leftHand = Point(x: 0.44, y: 0.47)
            end.rightElbow = Point(x: 0.40, y: 0.35)
            end.rightHand = Point(x: 0.52, y: 0.42)
            end.leftKnee = Point(x: 0.42, y: 0.73)
            end.leftFoot = Point(x: 0.34, y: 0.88)
            end.rightKnee = Point(x: 0.62, y: 0.66)
            end.rightFoot = Point(x: 0.73, y: 0.78)
        case .cycle:
            start = sideStanding()
            start.hip = Point(x: 0.48, y: 0.48)
            start.head = Point(x: 0.61, y: 0.23)
            start.neck = Point(x: 0.57, y: 0.29)
            start.leftShoulder = Point(x: 0.55, y: 0.33)
            start.rightShoulder = Point(x: 0.58, y: 0.35)
            start.leftHand = Point(x: 0.72, y: 0.46)
            start.rightHand = Point(x: 0.75, y: 0.47)
            start.leftKnee = Point(x: 0.58, y: 0.61)
            start.leftFoot = Point(x: 0.55, y: 0.68)
            start.rightKnee = Point(x: 0.44, y: 0.62)
            start.rightFoot = Point(x: 0.55, y: 0.68)
            end = start
            end.leftKnee = Point(x: 0.44, y: 0.62)
            end.leftFoot = Point(x: 0.55, y: 0.68)
            end.rightKnee = Point(x: 0.58, y: 0.61)
        case .rowingErgometer:
            start = seated()
            start.hip = Point(x: 0.43, y: 0.64)
            start.leftFoot = Point(x: 0.76, y: 0.73)
            start.rightFoot = Point(x: 0.78, y: 0.76)
            start.leftHand = Point(x: 0.68, y: 0.48)
            start.rightHand = Point(x: 0.71, y: 0.50)
            end = start
            end.head = Point(x: 0.38, y: 0.31)
            end.neck = Point(x: 0.41, y: 0.38)
            end.leftShoulder = Point(x: 0.44, y: 0.41)
            end.rightShoulder = Point(x: 0.46, y: 0.43)
            end.hip = Point(x: 0.33, y: 0.64)
            end.leftKnee = Point(x: 0.55, y: 0.68)
            end.rightKnee = Point(x: 0.58, y: 0.71)
            end.leftHand = Point(x: 0.48, y: 0.48)
            end.rightHand = Point(x: 0.51, y: 0.50)
        case .stairClimb:
            start = sideStanding()
            start.leftKnee = Point(x: 0.62, y: 0.67)
            start.leftFoot = Point(x: 0.69, y: 0.75)
            start.rightFoot = Point(x: 0.44, y: 0.88)
            end = start
            shiftBody(&end, dx: 0.08, dy: -0.07)
            end.leftKnee = Point(x: 0.53, y: 0.70)
            end.leftFoot = Point(x: 0.47, y: 0.82)
            end.rightKnee = Point(x: 0.68, y: 0.65)
            end.rightFoot = Point(x: 0.74, y: 0.72)
        case .generic:
            start = standing()
            end = start
            end.leftHand = Point(x: 0.36, y: 0.48)
            end.rightHand = Point(x: 0.64, y: 0.48)
            end.leftElbow = Point(x: 0.36, y: 0.39)
            end.rightElbow = Point(x: 0.64, y: 0.39)
        }
        return (start, end)
    }

    private static func standing() -> Pose {
        Pose(
            head: Point(x: 0.50, y: 0.15),
            neck: Point(x: 0.50, y: 0.24),
            leftShoulder: Point(x: 0.43, y: 0.28),
            rightShoulder: Point(x: 0.57, y: 0.28),
            leftElbow: Point(x: 0.40, y: 0.42),
            rightElbow: Point(x: 0.60, y: 0.42),
            leftHand: Point(x: 0.40, y: 0.56),
            rightHand: Point(x: 0.60, y: 0.56),
            hip: Point(x: 0.50, y: 0.55),
            leftKnee: Point(x: 0.44, y: 0.72),
            rightKnee: Point(x: 0.56, y: 0.72),
            leftFoot: Point(x: 0.41, y: 0.89),
            rightFoot: Point(x: 0.59, y: 0.89)
        )
    }

    private static func sideStanding() -> Pose {
        Pose(
            head: Point(x: 0.53, y: 0.15),
            neck: Point(x: 0.50, y: 0.24),
            leftShoulder: Point(x: 0.48, y: 0.29),
            rightShoulder: Point(x: 0.52, y: 0.30),
            leftElbow: Point(x: 0.45, y: 0.43),
            rightElbow: Point(x: 0.55, y: 0.44),
            leftHand: Point(x: 0.44, y: 0.57),
            rightHand: Point(x: 0.56, y: 0.58),
            hip: Point(x: 0.49, y: 0.55),
            leftKnee: Point(x: 0.44, y: 0.72),
            rightKnee: Point(x: 0.55, y: 0.72),
            leftFoot: Point(x: 0.40, y: 0.89),
            rightFoot: Point(x: 0.61, y: 0.89)
        )
    }

    private static func lying() -> Pose {
        Pose(
            head: Point(x: 0.22, y: 0.49),
            neck: Point(x: 0.29, y: 0.50),
            leftShoulder: Point(x: 0.34, y: 0.51),
            rightShoulder: Point(x: 0.37, y: 0.54),
            leftElbow: Point(x: 0.39, y: 0.43),
            rightElbow: Point(x: 0.43, y: 0.47),
            leftHand: Point(x: 0.40, y: 0.34),
            rightHand: Point(x: 0.45, y: 0.36),
            hip: Point(x: 0.58, y: 0.56),
            leftKnee: Point(x: 0.73, y: 0.66),
            rightKnee: Point(x: 0.76, y: 0.69),
            leftFoot: Point(x: 0.80, y: 0.86),
            rightFoot: Point(x: 0.86, y: 0.86)
        )
    }

    private static func prone() -> Pose {
        var pose = lying()
        pose.head = Point(x: 0.22, y: 0.53)
        pose.neck = Point(x: 0.29, y: 0.55)
        pose.leftShoulder = Point(x: 0.35, y: 0.56)
        pose.rightShoulder = Point(x: 0.38, y: 0.58)
        pose.hip = Point(x: 0.57, y: 0.59)
        pose.leftKnee = Point(x: 0.70, y: 0.61)
        pose.rightKnee = Point(x: 0.73, y: 0.64)
        pose.leftFoot = Point(x: 0.84, y: 0.62)
        pose.rightFoot = Point(x: 0.86, y: 0.66)
        return pose
    }

    private static func seated() -> Pose {
        Pose(
            head: Point(x: 0.39, y: 0.20),
            neck: Point(x: 0.41, y: 0.29),
            leftShoulder: Point(x: 0.38, y: 0.33),
            rightShoulder: Point(x: 0.43, y: 0.34),
            leftElbow: Point(x: 0.38, y: 0.46),
            rightElbow: Point(x: 0.45, y: 0.47),
            leftHand: Point(x: 0.40, y: 0.58),
            rightHand: Point(x: 0.48, y: 0.59),
            hip: Point(x: 0.44, y: 0.60),
            leftKnee: Point(x: 0.61, y: 0.65),
            rightKnee: Point(x: 0.65, y: 0.68),
            leftFoot: Point(x: 0.64, y: 0.86),
            rightFoot: Point(x: 0.69, y: 0.87)
        )
    }

    private static func bentOver() -> Pose {
        Pose(
            head: Point(x: 0.66, y: 0.34),
            neck: Point(x: 0.60, y: 0.39),
            leftShoulder: Point(x: 0.56, y: 0.42),
            rightShoulder: Point(x: 0.60, y: 0.44),
            leftElbow: Point(x: 0.61, y: 0.56),
            rightElbow: Point(x: 0.65, y: 0.58),
            leftHand: Point(x: 0.64, y: 0.70),
            rightHand: Point(x: 0.68, y: 0.71),
            hip: Point(x: 0.44, y: 0.57),
            leftKnee: Point(x: 0.42, y: 0.73),
            rightKnee: Point(x: 0.53, y: 0.74),
            leftFoot: Point(x: 0.37, y: 0.89),
            rightFoot: Point(x: 0.60, y: 0.89)
        )
    }

    private static func plank() -> Pose {
        Pose(
            head: Point(x: 0.25, y: 0.49),
            neck: Point(x: 0.31, y: 0.51),
            leftShoulder: Point(x: 0.36, y: 0.53),
            rightShoulder: Point(x: 0.39, y: 0.55),
            leftElbow: Point(x: 0.37, y: 0.64),
            rightElbow: Point(x: 0.42, y: 0.66),
            leftHand: Point(x: 0.35, y: 0.75),
            rightHand: Point(x: 0.43, y: 0.76),
            hip: Point(x: 0.59, y: 0.58),
            leftKnee: Point(x: 0.72, y: 0.63),
            rightKnee: Point(x: 0.75, y: 0.65),
            leftFoot: Point(x: 0.86, y: 0.68),
            rightFoot: Point(x: 0.89, y: 0.70)
        )
    }

    private static func hanging() -> Pose {
        Pose(
            head: Point(x: 0.50, y: 0.29),
            neck: Point(x: 0.50, y: 0.36),
            leftShoulder: Point(x: 0.43, y: 0.39),
            rightShoulder: Point(x: 0.57, y: 0.39),
            leftElbow: Point(x: 0.38, y: 0.25),
            rightElbow: Point(x: 0.62, y: 0.25),
            leftHand: Point(x: 0.34, y: 0.11),
            rightHand: Point(x: 0.66, y: 0.11),
            hip: Point(x: 0.50, y: 0.63),
            leftKnee: Point(x: 0.45, y: 0.75),
            rightKnee: Point(x: 0.55, y: 0.75),
            leftFoot: Point(x: 0.43, y: 0.89),
            rightFoot: Point(x: 0.57, y: 0.89)
        )
    }

    private static func kneeling() -> Pose {
        Pose(
            head: Point(x: 0.47, y: 0.28),
            neck: Point(x: 0.48, y: 0.36),
            leftShoulder: Point(x: 0.44, y: 0.40),
            rightShoulder: Point(x: 0.50, y: 0.41),
            leftElbow: Point(x: 0.48, y: 0.52),
            rightElbow: Point(x: 0.54, y: 0.53),
            leftHand: Point(x: 0.52, y: 0.64),
            rightHand: Point(x: 0.58, y: 0.65),
            hip: Point(x: 0.45, y: 0.62),
            leftKnee: Point(x: 0.40, y: 0.78),
            rightKnee: Point(x: 0.48, y: 0.79),
            leftFoot: Point(x: 0.30, y: 0.87),
            rightFoot: Point(x: 0.39, y: 0.88)
        )
    }

    private static func rotated(
        _ pose: Pose,
        around anchor: Point,
        radians: Double
    ) -> Pose {
        func point(_ value: Point) -> Point {
            let dx = value.x - anchor.x
            let dy = value.y - anchor.y
            return Point(
                x: anchor.x + dx * cos(radians) - dy * sin(radians),
                y: anchor.y + dx * sin(radians) + dy * cos(radians)
            )
        }
        return Pose(
            head: point(pose.head),
            neck: point(pose.neck),
            leftShoulder: point(pose.leftShoulder),
            rightShoulder: point(pose.rightShoulder),
            leftElbow: point(pose.leftElbow),
            rightElbow: point(pose.rightElbow),
            leftHand: point(pose.leftHand),
            rightHand: point(pose.rightHand),
            hip: point(pose.hip),
            leftKnee: point(pose.leftKnee),
            rightKnee: point(pose.rightKnee),
            leftFoot: point(pose.leftFoot),
            rightFoot: point(pose.rightFoot)
        )
    }

    private static func shiftUpper(_ pose: inout Pose, dy: Double) {
        pose.head.y += dy
        pose.neck.y += dy
        pose.leftShoulder.y += dy
        pose.rightShoulder.y += dy
    }

    private static func shiftBody(
        _ pose: inout Pose,
        dx: Double = 0,
        dy: Double = 0
    ) {
        pose.head.x += dx; pose.head.y += dy
        pose.neck.x += dx; pose.neck.y += dy
        pose.leftShoulder.x += dx; pose.leftShoulder.y += dy
        pose.rightShoulder.x += dx; pose.rightShoulder.y += dy
        pose.leftElbow.x += dx; pose.leftElbow.y += dy
        pose.rightElbow.x += dx; pose.rightElbow.y += dy
        pose.leftHand.x += dx; pose.leftHand.y += dy
        pose.rightHand.x += dx; pose.rightHand.y += dy
        pose.hip.x += dx; pose.hip.y += dy
        pose.leftKnee.x += dx; pose.leftKnee.y += dy
        pose.rightKnee.x += dx; pose.rightKnee.y += dy
        pose.leftFoot.x += dx; pose.leftFoot.y += dy
        pose.rightFoot.x += dx; pose.rightFoot.y += dy
    }
}
