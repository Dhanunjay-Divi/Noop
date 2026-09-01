import StrandDesign
import SwiftUI
import WhoopStore

/// Offline, NOOP-owned exercise motion. The drawing is intentionally stylized: it demonstrates the
/// movement path without pretending to replace coaching or copying OpenGym's restricted media.
struct StrengthExerciseMotionView: View {
    let exercise: StrengthExerciseRow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused = false

    private var guide: StrengthExerciseGuide {
        StrengthExerciseGuidance.guide(for: exercise)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StrandPalette.surfaceInset)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(StrandPalette.hairline, lineWidth: 1)
                }

            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30.0,
                    paused: paused || reduceMotion
                )
            ) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let phase: Double
                    if paused || reduceMotion {
                        phase = 0.22
                    } else {
                        phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: guide.cycleDuration)
                            / guide.cycleDuration
                    }
                    StrengthMotionRenderer.draw(
                        in: &context,
                        size: size,
                        exercise: exercise,
                        profile: guide.profile,
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
        .frame(maxWidth: .infinity)
        .aspectRatio(1.62, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strengthExerciseName(exercise))
    }
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
        phase: Double
    ) {
        let amount = 0.5 - 0.5 * cos(phase * .pi * 2)
        let keyframes = keyframes(for: profile)
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
        drawMotionTrack(
            in: &context,
            rect: drawingRect,
            from: keyframes.0,
            to: keyframes.1
        )
        drawEquipment(
            in: &context,
            rect: drawingRect,
            pose: currentPose,
            profile: profile,
            equipment: exercise.equipment,
            opacity: 0.9
        )
        drawFigure(
            in: &context,
            rect: drawingRect,
            pose: currentPose,
            primaryMuscle: exercise.primaryMuscle
        )
    }

    private static func drawStage(in context: inout GraphicsContext, rect: CGRect) {
        let groundY = rect.minY + rect.height * 0.91
        var ground = Path()
        ground.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: groundY))
        ground.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: groundY))
        context.stroke(
            ground,
            with: .color(StrandPalette.hairline.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )

        for fraction in [0.22, 0.5, 0.78] {
            let x = rect.minX + rect.width * fraction
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: groundY - 2))
            tick.addLine(to: CGPoint(x: x, y: groundY + 2))
            context.stroke(
                tick,
                with: .color(StrandPalette.hairline.opacity(0.65)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round)
            )
        }
    }

    private static func drawFigure(
        in context: inout GraphicsContext,
        rect: CGRect,
        pose: Pose,
        primaryMuscle: String
    ) {
        let rearColor = StrandPalette.textSecondary.opacity(0.72)
        let frontColor = StrandPalette.textPrimary.opacity(0.96)
        let torsoColor = StrandPalette.metricCyan.opacity(0.76)
        let torsoEdge = StrandPalette.textPrimary.opacity(0.34)
        let muscleColor = StrandPalette.effortColor.opacity(0.94)
        let rearArmWidth = max(5, rect.width * 0.026)
        let frontArmWidth = max(5.5, rect.width * 0.03)
        let rearLegWidth = max(6, rect.width * 0.034)
        let frontLegWidth = max(6.5, rect.width * 0.038)

        func cg(_ point: Point) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * point.x,
                y: rect.minY + rect.height * point.y
            )
        }

        func stroke(_ points: [Point], color: Color, width: CGFloat) {
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: cg(first))
            for point in points.dropFirst() { path.addLine(to: cg(point)) }
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
        }

        func circle(at point: Point, diameter: CGFloat, color: Color) {
            let center = cg(point)
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )
                ),
                with: .color(color)
            )
        }

        // Back limbs are drawn first so crossing movements retain readable depth.
        stroke(
            [pose.leftShoulder, pose.leftElbow, pose.leftHand],
            color: rearColor,
            width: rearArmWidth
        )
        stroke(
            [pose.hip, pose.leftKnee, pose.leftFoot],
            color: rearColor,
            width: rearLegWidth
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
        let hipHalfWidth = max(5, rect.width * 0.027)
        let hipLeft = CGPoint(
            x: hip.x - normalX * hipHalfWidth,
            y: hip.y - normalY * hipHalfWidth
        )
        let hipRight = CGPoint(
            x: hip.x + normalX * hipHalfWidth,
            y: hip.y + normalY * hipHalfWidth
        )
        var torso = Path()
        torso.move(to: shoulderLeft)
        torso.addQuadCurve(to: shoulderRight, control: cg(pose.neck))
        torso.addLine(to: hipRight)
        torso.addQuadCurve(to: hipLeft, control: hip)
        torso.closeSubpath()
        context.fill(torso, with: .color(torsoColor))
        context.stroke(
            torso,
            with: .color(torsoEdge),
            style: StrokeStyle(lineWidth: 1, lineJoin: .round)
        )
        stroke(
            [pose.neck, pose.hip],
            color: StrandPalette.textPrimary.opacity(0.2),
            width: max(1.2, rect.width * 0.006)
        )

        let pelvisLeft = Point(
            x: Double((hipLeft.x - rect.minX) / rect.width),
            y: Double((hipLeft.y - rect.minY) / rect.height)
        )
        let pelvisRight = Point(
            x: Double((hipRight.x - rect.minX) / rect.width),
            y: Double((hipRight.y - rect.minY) / rect.height)
        )
        stroke(
            [pelvisLeft, pelvisRight],
            color: torsoColor,
            width: max(6, rect.width * 0.034)
        )

        // Front limbs carry slightly more contrast and make the pose read as a solid mannequin.
        stroke(
            [pose.rightShoulder, pose.rightElbow, pose.rightHand],
            color: frontColor,
            width: frontArmWidth
        )
        stroke(
            [pose.hip, pose.rightKnee, pose.rightFoot],
            color: frontColor,
            width: frontLegWidth
        )

        let head = cg(pose.head)
        let headSize = max(12, rect.width * 0.068)
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: head.x - headSize / 2,
                    y: head.y - headSize / 2,
                    width: headSize,
                    height: headSize
                )
            ),
            with: .color(frontColor)
        )
        stroke(
            [pose.head, pose.neck],
            color: frontColor,
            width: max(4.5, rect.width * 0.024)
        )
        for point in [pose.rightElbow, pose.rightHand, pose.rightKnee] {
            circle(at: point, diameter: frontArmWidth, color: frontColor)
        }

        func accent(_ points: [Point], width: CGFloat) {
            stroke(points, color: muscleColor, width: width)
        }

        let upperArmWidth = max(3.5, rect.width * 0.018)
        let legAccentWidth = max(4, rect.width * 0.022)
        switch primaryMuscle {
        case "chest":
            accent(
                [
                    .mix(pose.leftShoulder, pose.neck, 0.18),
                    .mix(pose.rightShoulder, pose.neck, 0.18),
                ],
                width: max(4, rect.width * 0.021)
            )
        case "back":
            accent(
                [.mix(pose.neck, pose.hip, 0.18), .mix(pose.neck, pose.hip, 0.64)],
                width: max(5, rect.width * 0.027)
            )
        case "shoulders":
            circle(at: pose.leftShoulder, diameter: upperArmWidth * 1.25, color: muscleColor)
            circle(at: pose.rightShoulder, diameter: upperArmWidth * 1.25, color: muscleColor)
        case "biceps", "triceps":
            accent(
                [
                    .mix(pose.rightShoulder, pose.rightElbow, 0.18),
                    .mix(pose.rightShoulder, pose.rightElbow, 0.82),
                ],
                width: upperArmWidth
            )
        case "forearms":
            accent(
                [
                    .mix(pose.rightElbow, pose.rightHand, 0.16),
                    .mix(pose.rightElbow, pose.rightHand, 0.84),
                ],
                width: upperArmWidth * 0.82
            )
        case "core":
            accent(
                [.mix(pose.neck, pose.hip, 0.48), .mix(pose.neck, pose.hip, 0.82)],
                width: max(5, rect.width * 0.026)
            )
        case "quadriceps", "hamstrings":
            accent(
                [.mix(pose.hip, pose.rightKnee, 0.2), .mix(pose.hip, pose.rightKnee, 0.82)],
                width: legAccentWidth
            )
            accent(
                [.mix(pose.hip, pose.leftKnee, 0.2), .mix(pose.hip, pose.leftKnee, 0.82)],
                width: legAccentWidth * 0.86
            )
        case "glutes":
            circle(at: pose.hip, diameter: max(7, rect.width * 0.043), color: muscleColor)
        case "calves":
            accent(
                [
                    .mix(pose.rightKnee, pose.rightFoot, 0.2),
                    .mix(pose.rightKnee, pose.rightFoot, 0.78),
                ],
                width: legAccentWidth * 0.82
            )
        case "full_body":
            accent(
                [.mix(pose.neck, pose.hip, 0.22), .mix(pose.neck, pose.hip, 0.72)],
                width: max(4, rect.width * 0.021)
            )
        default:
            accent(
                [.mix(pose.neck, pose.hip, 0.34), .mix(pose.neck, pose.hip, 0.68)],
                width: max(4, rect.width * 0.019)
            )
        }
    }

    private static func drawEquipment(
        in context: inout GraphicsContext,
        rect: CGRect,
        pose: Pose,
        profile: StrengthExerciseMotionProfile,
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

        switch profile {
        case .benchPress, .chestFly, .skullCrusher:
            line(Point(x: 0.18, y: 0.61), Point(x: 0.72, y: 0.61), width: 5)
            line(Point(x: 0.29, y: 0.61), Point(x: 0.24, y: 0.83), width: 3)
            line(Point(x: 0.62, y: 0.61), Point(x: 0.67, y: 0.83), width: 3)
        case .pullUp:
            line(Point(x: 0.27, y: 0.11), Point(x: 0.73, y: 0.11), width: 4)
        case .latPulldown:
            line(Point(x: 0.25, y: 0.10), Point(x: 0.75, y: 0.10), width: 3)
            line(Point(x: 0.50, y: 0.10), Point(x: 0.50, y: 0.20), width: 1.5)
        case .legPress:
            line(Point(x: 0.72, y: 0.25), Point(x: 0.82, y: 0.70), width: 7)
            line(Point(x: 0.18, y: 0.72), Point(x: 0.50, y: 0.83), width: 6)
        case .legExtension, .legCurl:
            line(Point(x: 0.28, y: 0.58), Point(x: 0.63, y: 0.58), width: 6)
            line(Point(x: 0.34, y: 0.58), Point(x: 0.30, y: 0.84), width: 3)
        case .hipThrust:
            line(Point(x: 0.18, y: 0.56), Point(x: 0.43, y: 0.56), width: 6)
        case .dip:
            line(Point(x: 0.30, y: 0.42), Point(x: 0.46, y: 0.42), width: 4)
            line(Point(x: 0.54, y: 0.42), Point(x: 0.70, y: 0.42), width: 4)
        case .cycle:
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
        case .rowingErgometer:
            line(Point(x: 0.22, y: 0.76), Point(x: 0.82, y: 0.76), width: 4)
            line(Point(x: 0.75, y: 0.47), Point(x: 0.82, y: 0.76), width: 5)
        case .stairClimb:
            for index in 0..<4 {
                let x = 0.45 + Double(index) * 0.1
                let y = 0.82 - Double(index) * 0.11
                line(Point(x: x, y: y), Point(x: x + 0.12, y: y), width: 5)
            }
        case .backExtension:
            line(Point(x: 0.42, y: 0.58), Point(x: 0.64, y: 0.78), width: 7)
            line(Point(x: 0.55, y: 0.70), Point(x: 0.47, y: 0.88), width: 3)
        case .abRollout:
            weight(at: pose.leftHand, size: 0.07)
        default:
            break
        }

        switch equipment {
        case "barbell":
            let leftAnchor = profile == .squat ? pose.leftShoulder : pose.leftHand
            let rightAnchor = profile == .squat ? pose.rightShoulder : pose.rightHand
            let centerX = (leftAnchor.x + rightAnchor.x) / 2
            let centerY = (leftAnchor.y + rightAnchor.y) / 2
            let halfSpan = max(abs(rightAnchor.x - leftAnchor.x) / 2 + 0.11, 0.18)
            let minX = centerX - halfSpan
            let maxX = centerX + halfSpan
            line(
                Point(x: minX - 0.025, y: centerY),
                Point(x: maxX + 0.025, y: centerY),
                width: max(2.2, rect.width * 0.009)
            )
            plate(at: Point(x: minX, y: centerY))
            plate(at: Point(x: maxX, y: centerY))
        case "dumbbell", "kettlebell":
            weight(at: pose.leftHand, size: equipment == "kettlebell" ? 0.057 : 0.038)
            weight(at: pose.rightHand, size: equipment == "kettlebell" ? 0.057 : 0.038)
        case "band":
            line(pose.leftHand, pose.rightHand, width: 3)
        case "cable":
            line(Point(x: 0.86, y: 0.16), pose.rightHand, width: 1.5)
        default:
            break
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
