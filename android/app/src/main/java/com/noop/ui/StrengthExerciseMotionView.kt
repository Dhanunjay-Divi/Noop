package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.StrengthExerciseGuidance
import com.noop.data.StrengthExerciseMotionProfile
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthMuscleStatus
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sqrt

/** Native offline counterpart to iOS StrengthExerciseMotionView. */
@Composable
fun StrengthExerciseMotionView(
    exercise: StrengthExerciseRow,
    modifier: Modifier = Modifier,
) {
    val guide = remember(exercise) { StrengthExerciseGuidance.guide(exercise) }
    val still = rememberPoseStill()
    var paused by rememberSaveable(exercise.id) { mutableStateOf(false) }
    var phase by remember(exercise.id) { mutableFloatStateOf(0f) }

    LaunchedEffect(paused, still, guide.cycleDurationSeconds) {
        if (paused || still) return@LaunchedEffect
        var previous = 0L
        while (true) {
            withFrameNanos { frame ->
                if (previous != 0L) {
                    val delta = ((frame - previous) / 1_000_000_000f)
                        .coerceIn(0f, 0.1f)
                    phase = (phase + delta / guide.cycleDurationSeconds) % 1f
                }
                previous = frame
            }
        }
    }

    val shape = RoundedCornerShape(8.dp)
    Box(
        modifier = modifier
            .aspectRatio(1.62f)
            .background(Palette.surfaceInset, shape)
            .border(1.dp, Palette.hairline, shape),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            drawStrengthMotion(
                exercise = exercise,
                profile = guide.profile,
                phase = if (paused || still) 0.22f else phase,
            )
        }
        IconButton(
            onClick = { paused = !paused },
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(10.dp)
                .background(Palette.surfaceOverlay.copy(alpha = 0.9f), CircleShape),
        ) {
            Icon(
                imageVector = if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                contentDescription = stringResource(
                    if (paused) R.string.strength_play_guide else R.string.strength_pause_guide,
                ),
                tint = Palette.textPrimary,
            )
        }
    }
}

enum class StrengthBodyMapMode {
    LOAD,
    RECOVERY,
}

@Composable
fun StrengthBodyMapView(
    statuses: List<StrengthMuscleStatus>,
    mode: StrengthBodyMapMode,
    selectedMuscle: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val statusByMuscle = remember(statuses) { statuses.associateBy { it.muscle } }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(306.dp),
    ) {
        StrengthBodyFigure(
            side = StrengthBodySide.FRONT,
            label = stringResource(R.string.strength_body_front),
            statusByMuscle = statusByMuscle,
            mode = mode,
            selectedMuscle = selectedMuscle,
            onSelect = onSelect,
            modifier = Modifier.weight(1f),
        )
        StrengthBodyFigure(
            side = StrengthBodySide.BACK,
            label = stringResource(R.string.strength_body_back),
            statusByMuscle = statusByMuscle,
            mode = mode,
            selectedMuscle = selectedMuscle,
            onSelect = onSelect,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun StrengthBodyFigure(
    side: StrengthBodySide,
    label: String,
    statusByMuscle: Map<String, StrengthMuscleStatus>,
    mode: StrengthBodyMapMode,
    selectedMuscle: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = label,
            style = NoopType.caption,
            color = Palette.textSecondary,
        )
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val silhouette = Palette.textTertiary.copy(alpha = 0.14f)
                drawCircle(
                    color = silhouette,
                    radius = size.width * 0.09f,
                    center = Offset(size.width * 0.5f, size.height * 0.08f),
                )
                drawRoundRect(
                    color = silhouette,
                    topLeft = Offset(size.width * 0.34f, size.height * 0.15f),
                    size = Size(size.width * 0.32f, size.height * 0.43f),
                    cornerRadius = CornerRadius(size.width * 0.11f),
                )
                drawRoundRect(
                    color = silhouette,
                    topLeft = Offset(size.width * 0.19f, size.height * 0.17f),
                    size = Size(size.width * 0.13f, size.height * 0.45f),
                    cornerRadius = CornerRadius(size.width * 0.07f),
                )
                drawRoundRect(
                    color = silhouette,
                    topLeft = Offset(size.width * 0.68f, size.height * 0.17f),
                    size = Size(size.width * 0.13f, size.height * 0.45f),
                    cornerRadius = CornerRadius(size.width * 0.07f),
                )
                drawRoundRect(
                    color = silhouette,
                    topLeft = Offset(size.width * 0.34f, size.height * 0.53f),
                    size = Size(size.width * 0.14f, size.height * 0.45f),
                    cornerRadius = CornerRadius(size.width * 0.07f),
                )
                drawRoundRect(
                    color = silhouette,
                    topLeft = Offset(size.width * 0.52f, size.height * 0.53f),
                    size = Size(size.width * 0.14f, size.height * 0.45f),
                    cornerRadius = CornerRadius(size.width * 0.07f),
                )
            }
            side.regions.forEach { region ->
                val status = statusByMuscle[region.muscle]
                val score = when (mode) {
                    StrengthBodyMapMode.LOAD -> status?.loadScore ?: 0.0
                    StrengthBodyMapMode.RECOVERY -> status?.residualLoadScore ?: 0.0
                }.coerceIn(0.0, 1.0)
                val selected = selectedMuscle == region.muscle
                val muscleLabel = strengthDescriptor(region.muscle)
                val state = if (mode == StrengthBodyMapMode.LOAD) {
                    stringResource(
                        R.string.strength_body_load_accessibility,
                        (score * 100).toInt(),
                    )
                } else {
                    stringResource(
                        R.string.strength_body_recovery_accessibility,
                        ((status?.recoveryScore ?: 1.0) * 100).toInt(),
                    )
                }
                val accessibilityDescription = "$muscleLabel, $state"
                val regionWidth = maxWidth * region.width
                val regionHeight = maxHeight * region.height
                Box(
                    modifier = Modifier
                        .offset(
                            x = maxWidth * region.x - regionWidth / 2,
                            y = maxHeight * region.y - regionHeight / 2,
                        )
                        .then(Modifier.fillMaxWidth(region.width))
                        .height(regionHeight)
                        .rotate(region.rotation)
                        .background(
                            Color(0xFFEB1F2E).copy(alpha = (0.13 + score * 0.77).toFloat()),
                            CircleShape,
                        )
                        .border(
                            width = if (selected) 2.dp else 1.dp,
                            color = if (selected) {
                                Palette.textPrimary
                            } else {
                                Color.White.copy(alpha = 0.13f)
                            },
                            shape = CircleShape,
                        )
                        .semantics {
                            contentDescription = accessibilityDescription
                            this.selected = selected
                        }
                        .clickable { onSelect(region.muscle) },
                )
            }
        }
    }
}

private enum class StrengthBodySide {
    FRONT,
    BACK;

    val regions: List<StrengthBodyRegion>
        get() = when (this) {
            FRONT -> listOf(
                StrengthBodyRegion("shoulders-left", "shoulders", 0.35f, 0.19f, 0.13f, 0.065f, 45f),
                StrengthBodyRegion("shoulders-right", "shoulders", 0.65f, 0.19f, 0.13f, 0.065f, -45f),
                StrengthBodyRegion("chest-left", "chest", 0.43f, 0.29f, 0.16f, 0.12f, 12f),
                StrengthBodyRegion("chest-right", "chest", 0.57f, 0.29f, 0.16f, 0.12f, -12f),
                StrengthBodyRegion("biceps-left", "biceps", 0.27f, 0.35f, 0.11f, 0.15f, 8f),
                StrengthBodyRegion("biceps-right", "biceps", 0.73f, 0.35f, 0.11f, 0.15f, -8f),
                StrengthBodyRegion("forearms-left", "forearms", 0.22f, 0.51f, 0.09f, 0.17f, 10f),
                StrengthBodyRegion("forearms-right", "forearms", 0.78f, 0.51f, 0.09f, 0.17f, -10f),
                StrengthBodyRegion("core", "core", 0.50f, 0.45f, 0.20f, 0.24f, 0f),
                StrengthBodyRegion("quadriceps-left", "quadriceps", 0.42f, 0.69f, 0.14f, 0.22f, 3f),
                StrengthBodyRegion("quadriceps-right", "quadriceps", 0.58f, 0.69f, 0.14f, 0.22f, -3f),
                StrengthBodyRegion("calves-left", "calves", 0.40f, 0.88f, 0.10f, 0.17f, 2f),
                StrengthBodyRegion("calves-right", "calves", 0.60f, 0.88f, 0.10f, 0.17f, -2f),
            )
            BACK -> listOf(
                StrengthBodyRegion("shoulders-left", "shoulders", 0.35f, 0.19f, 0.13f, 0.065f, 45f),
                StrengthBodyRegion("shoulders-right", "shoulders", 0.65f, 0.19f, 0.13f, 0.065f, -45f),
                StrengthBodyRegion("back", "back", 0.50f, 0.35f, 0.29f, 0.27f, 0f),
                StrengthBodyRegion("triceps-left", "triceps", 0.27f, 0.35f, 0.11f, 0.15f, 8f),
                StrengthBodyRegion("triceps-right", "triceps", 0.73f, 0.35f, 0.11f, 0.15f, -8f),
                StrengthBodyRegion("forearms-left", "forearms", 0.22f, 0.51f, 0.09f, 0.17f, 10f),
                StrengthBodyRegion("forearms-right", "forearms", 0.78f, 0.51f, 0.09f, 0.17f, -10f),
                StrengthBodyRegion("glutes-left", "glutes", 0.43f, 0.56f, 0.16f, 0.12f, 4f),
                StrengthBodyRegion("glutes-right", "glutes", 0.57f, 0.56f, 0.16f, 0.12f, -4f),
                StrengthBodyRegion("hamstrings-left", "hamstrings", 0.42f, 0.70f, 0.14f, 0.22f, 3f),
                StrengthBodyRegion("hamstrings-right", "hamstrings", 0.58f, 0.70f, 0.14f, 0.22f, -3f),
                StrengthBodyRegion("calves-left", "calves", 0.40f, 0.88f, 0.10f, 0.17f, 2f),
                StrengthBodyRegion("calves-right", "calves", 0.60f, 0.88f, 0.10f, 0.17f, -2f),
            )
        }
}

private data class StrengthBodyRegion(
    val id: String,
    val muscle: String,
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
    val rotation: Float,
)

private data class MotionPoint(var x: Float, var y: Float) {
    companion object {
        fun mix(a: MotionPoint, b: MotionPoint, amount: Float) = MotionPoint(
            x = a.x + (b.x - a.x) * amount,
            y = a.y + (b.y - a.y) * amount,
        )
    }
}

private data class MotionPose(
    var head: MotionPoint,
    var neck: MotionPoint,
    var leftShoulder: MotionPoint,
    var rightShoulder: MotionPoint,
    var leftElbow: MotionPoint,
    var rightElbow: MotionPoint,
    var leftHand: MotionPoint,
    var rightHand: MotionPoint,
    var hip: MotionPoint,
    var leftKnee: MotionPoint,
    var rightKnee: MotionPoint,
    var leftFoot: MotionPoint,
    var rightFoot: MotionPoint,
) {
    fun copyDeep() = MotionPose(
        head.copy(), neck.copy(), leftShoulder.copy(), rightShoulder.copy(),
        leftElbow.copy(), rightElbow.copy(), leftHand.copy(), rightHand.copy(),
        hip.copy(), leftKnee.copy(), rightKnee.copy(), leftFoot.copy(), rightFoot.copy(),
    )

    companion object {
        fun mix(a: MotionPose, b: MotionPose, amount: Float) = MotionPose(
            MotionPoint.mix(a.head, b.head, amount),
            MotionPoint.mix(a.neck, b.neck, amount),
            MotionPoint.mix(a.leftShoulder, b.leftShoulder, amount),
            MotionPoint.mix(a.rightShoulder, b.rightShoulder, amount),
            MotionPoint.mix(a.leftElbow, b.leftElbow, amount),
            MotionPoint.mix(a.rightElbow, b.rightElbow, amount),
            MotionPoint.mix(a.leftHand, b.leftHand, amount),
            MotionPoint.mix(a.rightHand, b.rightHand, amount),
            MotionPoint.mix(a.hip, b.hip, amount),
            MotionPoint.mix(a.leftKnee, b.leftKnee, amount),
            MotionPoint.mix(a.rightKnee, b.rightKnee, amount),
            MotionPoint.mix(a.leftFoot, b.leftFoot, amount),
            MotionPoint.mix(a.rightFoot, b.rightFoot, amount),
        )
    }
}

private fun DrawScope.drawStrengthMotion(
    exercise: StrengthExerciseRow,
    profile: StrengthExerciseMotionProfile,
    phase: Float,
) {
    val amount = (0.5 - 0.5 * cos(phase * PI * 2)).toFloat()
    val pair = strengthKeyframes(profile)
    val pose = MotionPose.mix(pair.first, pair.second, amount)
    val width = min(size.width, size.height * 1.62f)
    val height = width / 1.62f
    val origin = Offset((size.width - width) / 2f, (size.height - height) / 2f)

    val groundY = origin.y + height * 0.91f
    drawLine(
        Palette.hairline.copy(alpha = 0.9f),
        Offset(origin.x + width * 0.08f, groundY),
        Offset(origin.x + width * 0.92f, groundY),
        strokeWidth = 1.2f,
        cap = StrokeCap.Round,
    )
    listOf(0.22f, 0.5f, 0.78f).forEach { fraction ->
        val x = origin.x + width * fraction
        drawLine(
            Palette.hairline.copy(alpha = 0.65f),
            Offset(x, groundY - 2f),
            Offset(x, groundY + 2f),
            strokeWidth = 1f,
            cap = StrokeCap.Round,
        )
    }

    drawStrengthMotionTrack(pair.first, pair.second, width, height, origin)
    drawStrengthEquipment(
        pose = pose,
        profile = profile,
        equipment = exercise.equipment,
        width = width,
        height = height,
        origin = origin,
    )
    drawStrengthFigure(
        pose,
        exercise.primaryMuscle,
        width,
        height,
        origin,
    )
}

private fun DrawScope.drawStrengthMotionTrack(
    startPose: MotionPose,
    endPose: MotionPose,
    width: Float,
    height: Float,
    origin: Offset,
) {
    fun p(point: MotionPoint) = Offset(
        origin.x + width * point.x,
        origin.y + height * point.y,
    )
    val candidates = listOf(
        startPose.leftHand to endPose.leftHand,
        startPose.rightHand to endPose.rightHand,
        startPose.leftFoot to endPose.leftFoot,
        startPose.rightFoot to endPose.rightFoot,
        startPose.hip to endPose.hip,
        startPose.head to endPose.head,
    )
    val movement = candidates.maxByOrNull { (start, end) ->
        val from = p(start)
        val to = p(end)
        val dx = to.x - from.x
        val dy = to.y - from.y
        dx * dx + dy * dy
    } ?: return
    val start = p(movement.first)
    val end = p(movement.second)
    val dx = end.x - start.x
    val dy = end.y - start.y
    val distance = sqrt(dx * dx + dy * dy)
    if (distance <= width * 0.025f) return
    val bend = min(width * 0.026f, distance * 0.18f)
    val path = Path().apply {
        moveTo(start.x, start.y)
        quadraticBezierTo(
            (start.x + end.x) / 2f - dy / distance * bend,
            (start.y + end.y) / 2f + dx / distance * bend,
            end.x,
            end.y,
        )
    }
    drawPath(
        path,
        Palette.metricCyan.copy(alpha = 0.38f),
        style = Stroke(width = 1.4f),
    )
    val endpointRadius = maxOf(2.5f, width * 0.011f)
    listOf(start, end).forEach { endpoint ->
        drawCircle(
            Palette.metricCyan.copy(alpha = 0.55f),
            endpointRadius,
            endpoint,
            style = Stroke(width = 1.2f),
        )
    }
}

private fun DrawScope.drawStrengthFigure(
    pose: MotionPose,
    primaryMuscle: String,
    width: Float,
    height: Float,
    origin: Offset,
) {
    fun p(point: MotionPoint) = Offset(
        origin.x + width * point.x,
        origin.y + height * point.y,
    )
    fun limb(points: List<MotionPoint>, color: Color, stroke: Float) {
        points.zipWithNext().forEach { (a, b) ->
            drawLine(color, p(a), p(b), strokeWidth = stroke, cap = StrokeCap.Round)
        }
    }

    val rearColor = Palette.textSecondary.copy(alpha = 0.72f)
    val frontColor = Palette.textPrimary.copy(alpha = 0.96f)
    val torsoColor = Palette.metricCyan.copy(alpha = 0.76f)
    val torsoEdge = Palette.textPrimary.copy(alpha = 0.34f)
    val muscleColor = Palette.effortColor.copy(alpha = 0.94f)
    val rearArmWidth = maxOf(5f, width * 0.026f)
    val frontArmWidth = maxOf(5.5f, width * 0.03f)
    val rearLegWidth = maxOf(6f, width * 0.034f)
    val frontLegWidth = maxOf(6.5f, width * 0.038f)

    // Back limbs establish depth before the torso and brighter front limbs are drawn.
    limb(listOf(pose.leftShoulder, pose.leftElbow, pose.leftHand), rearColor, rearArmWidth)
    limb(listOf(pose.hip, pose.leftKnee, pose.leftFoot), rearColor, rearLegWidth)

    val shoulderLeft = p(pose.leftShoulder)
    val shoulderRight = p(pose.rightShoulder)
    val shoulderMid = Offset(
        (shoulderLeft.x + shoulderRight.x) / 2f,
        (shoulderLeft.y + shoulderRight.y) / 2f,
    )
    val hip = p(pose.hip)
    val axisX = hip.x - shoulderMid.x
    val axisY = hip.y - shoulderMid.y
    val axisLength = maxOf(1f, sqrt(axisX * axisX + axisY * axisY))
    var normalX = -axisY / axisLength
    var normalY = axisX / axisLength
    val shoulderVectorX = shoulderRight.x - shoulderLeft.x
    val shoulderVectorY = shoulderRight.y - shoulderLeft.y
    if (normalX * shoulderVectorX + normalY * shoulderVectorY < 0f) {
        normalX *= -1f
        normalY *= -1f
    }
    val hipHalfWidth = maxOf(5f, width * 0.027f)
    val hipLeft = Offset(
        hip.x - normalX * hipHalfWidth,
        hip.y - normalY * hipHalfWidth,
    )
    val hipRight = Offset(
        hip.x + normalX * hipHalfWidth,
        hip.y + normalY * hipHalfWidth,
    )
    val torso = Path().apply {
        moveTo(shoulderLeft.x, shoulderLeft.y)
        quadraticBezierTo(p(pose.neck).x, p(pose.neck).y, shoulderRight.x, shoulderRight.y)
        lineTo(hipRight.x, hipRight.y)
        quadraticBezierTo(hip.x, hip.y, hipLeft.x, hipLeft.y)
        close()
    }
    drawPath(torso, torsoColor)
    drawPath(torso, torsoEdge, style = Stroke(width = 1f))
    limb(
        listOf(pose.neck, pose.hip),
        Palette.textPrimary.copy(alpha = 0.2f),
        maxOf(1.2f, width * 0.006f),
    )
    drawLine(
        torsoColor,
        hipLeft,
        hipRight,
        strokeWidth = maxOf(6f, width * 0.034f),
        cap = StrokeCap.Round,
    )

    limb(
        listOf(pose.rightShoulder, pose.rightElbow, pose.rightHand),
        frontColor,
        frontArmWidth,
    )
    limb(
        listOf(pose.hip, pose.rightKnee, pose.rightFoot),
        frontColor,
        frontLegWidth,
    )

    drawCircle(frontColor, maxOf(6f, width * 0.034f), p(pose.head))
    limb(
        listOf(pose.head, pose.neck),
        frontColor,
        maxOf(4.5f, width * 0.024f),
    )
    listOf(pose.rightElbow, pose.rightHand, pose.rightKnee).forEach {
        drawCircle(frontColor, frontArmWidth / 2f, p(it))
    }

    fun accent(points: List<MotionPoint>, strokeWidth: Float) {
        limb(points, muscleColor, strokeWidth)
    }

    val upperArmWidth = maxOf(3.5f, width * 0.018f)
    val legAccentWidth = maxOf(4f, width * 0.022f)
    when (primaryMuscle) {
        "chest" -> accent(
            listOf(
                MotionPoint.mix(pose.leftShoulder, pose.neck, 0.18f),
                MotionPoint.mix(pose.rightShoulder, pose.neck, 0.18f),
            ),
            maxOf(4f, width * 0.021f),
        )
        "back" -> accent(
            listOf(
                MotionPoint.mix(pose.neck, pose.hip, 0.18f),
                MotionPoint.mix(pose.neck, pose.hip, 0.64f),
            ),
            maxOf(5f, width * 0.027f),
        )
        "shoulders" -> {
            drawCircle(muscleColor, upperArmWidth * 0.625f, p(pose.leftShoulder))
            drawCircle(muscleColor, upperArmWidth * 0.625f, p(pose.rightShoulder))
        }
        "biceps", "triceps" -> accent(
            listOf(
                MotionPoint.mix(pose.rightShoulder, pose.rightElbow, 0.18f),
                MotionPoint.mix(pose.rightShoulder, pose.rightElbow, 0.82f),
            ),
            upperArmWidth,
        )
        "forearms" -> accent(
            listOf(
                MotionPoint.mix(pose.rightElbow, pose.rightHand, 0.16f),
                MotionPoint.mix(pose.rightElbow, pose.rightHand, 0.84f),
            ),
            upperArmWidth * 0.82f,
        )
        "core" -> accent(
            listOf(
                MotionPoint.mix(pose.neck, pose.hip, 0.48f),
                MotionPoint.mix(pose.neck, pose.hip, 0.82f),
            ),
            maxOf(5f, width * 0.026f),
        )
        "quadriceps", "hamstrings" -> {
            accent(
                listOf(
                    MotionPoint.mix(pose.hip, pose.rightKnee, 0.2f),
                    MotionPoint.mix(pose.hip, pose.rightKnee, 0.82f),
                ),
                legAccentWidth,
            )
            accent(
                listOf(
                    MotionPoint.mix(pose.hip, pose.leftKnee, 0.2f),
                    MotionPoint.mix(pose.hip, pose.leftKnee, 0.82f),
                ),
                legAccentWidth * 0.86f,
            )
        }
        "glutes" -> drawCircle(
            muscleColor,
            maxOf(3.5f, width * 0.0215f),
            p(pose.hip),
        )
        "calves" -> accent(
            listOf(
                MotionPoint.mix(pose.rightKnee, pose.rightFoot, 0.2f),
                MotionPoint.mix(pose.rightKnee, pose.rightFoot, 0.78f),
            ),
            legAccentWidth * 0.82f,
        )
        "full_body" -> accent(
            listOf(
                MotionPoint.mix(pose.neck, pose.hip, 0.22f),
                MotionPoint.mix(pose.neck, pose.hip, 0.72f),
            ),
            maxOf(4f, width * 0.021f),
        )
        else -> accent(
            listOf(
                MotionPoint.mix(pose.neck, pose.hip, 0.34f),
                MotionPoint.mix(pose.neck, pose.hip, 0.68f),
            ),
            maxOf(4f, width * 0.019f),
        )
    }
}

private fun DrawScope.drawStrengthEquipment(
    pose: MotionPose,
    profile: StrengthExerciseMotionProfile,
    equipment: String,
    width: Float,
    height: Float,
    origin: Offset,
) {
    fun p(point: MotionPoint) = Offset(
        origin.x + width * point.x,
        origin.y + height * point.y,
    )
    fun line(a: MotionPoint, b: MotionPoint, stroke: Float = 2.2f) {
        drawLine(
            Palette.textTertiary.copy(alpha = 0.9f),
            p(a),
            p(b),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
    fun weight(point: MotionPoint, radius: Float = 0.021f) {
        drawCircle(
            Palette.textTertiary.copy(alpha = 0.9f),
            width * radius,
            p(point),
        )
        drawCircle(
            Palette.hairline.copy(alpha = 0.9f),
            width * radius,
            p(point),
            style = Stroke(width = 1f),
        )
    }
    fun plate(point: MotionPoint) {
        val center = p(point)
        val plateWidth = maxOf(5f, width * 0.022f)
        val plateHeight = maxOf(13f, width * 0.072f)
        drawRoundRect(
            color = Palette.textTertiary.copy(alpha = 0.9f),
            topLeft = Offset(
                center.x - plateWidth / 2f,
                center.y - plateHeight / 2f,
            ),
            size = Size(plateWidth, plateHeight),
            cornerRadius = CornerRadius(plateWidth * 0.34f),
        )
        drawCircle(
            Palette.surfaceInset.copy(alpha = 0.9f),
            maxOf(1.25f, plateWidth * 0.21f),
            center,
        )
    }

    when (profile) {
        StrengthExerciseMotionProfile.BENCH_PRESS,
        StrengthExerciseMotionProfile.CHEST_FLY,
        StrengthExerciseMotionProfile.SKULL_CRUSHER,
        -> {
            line(MotionPoint(0.18f, 0.61f), MotionPoint(0.72f, 0.61f), 5f)
            line(MotionPoint(0.29f, 0.61f), MotionPoint(0.24f, 0.83f), 3f)
            line(MotionPoint(0.62f, 0.61f), MotionPoint(0.67f, 0.83f), 3f)
        }
        StrengthExerciseMotionProfile.PULL_UP ->
            line(MotionPoint(0.27f, 0.11f), MotionPoint(0.73f, 0.11f), 4f)
        StrengthExerciseMotionProfile.LAT_PULLDOWN -> {
            line(MotionPoint(0.25f, 0.10f), MotionPoint(0.75f, 0.10f), 3f)
            line(MotionPoint(0.50f, 0.10f), MotionPoint(0.50f, 0.20f), 1.5f)
        }
        StrengthExerciseMotionProfile.LEG_PRESS -> {
            line(MotionPoint(0.72f, 0.25f), MotionPoint(0.82f, 0.70f), 7f)
            line(MotionPoint(0.18f, 0.72f), MotionPoint(0.50f, 0.83f), 6f)
        }
        StrengthExerciseMotionProfile.LEG_EXTENSION,
        StrengthExerciseMotionProfile.LEG_CURL,
        -> {
            line(MotionPoint(0.28f, 0.58f), MotionPoint(0.63f, 0.58f), 6f)
            line(MotionPoint(0.34f, 0.58f), MotionPoint(0.30f, 0.84f), 3f)
        }
        StrengthExerciseMotionProfile.HIP_THRUST ->
            line(MotionPoint(0.18f, 0.56f), MotionPoint(0.43f, 0.56f), 6f)
        StrengthExerciseMotionProfile.DIP -> {
            line(MotionPoint(0.30f, 0.42f), MotionPoint(0.46f, 0.42f), 4f)
            line(MotionPoint(0.54f, 0.42f), MotionPoint(0.70f, 0.42f), 4f)
        }
        StrengthExerciseMotionProfile.CYCLE -> {
            drawCircle(
                Palette.textTertiary.copy(alpha = 0.9f),
                width * 0.135f,
                p(MotionPoint(0.55f, 0.68f)),
                style = Stroke(width = 3f),
            )
            line(MotionPoint(0.39f, 0.52f), MotionPoint(0.55f, 0.68f), 3f)
            line(MotionPoint(0.55f, 0.68f), MotionPoint(0.72f, 0.49f), 3f)
        }
        StrengthExerciseMotionProfile.ROWING_ERGOMETER -> {
            line(MotionPoint(0.22f, 0.76f), MotionPoint(0.82f, 0.76f), 4f)
            line(MotionPoint(0.75f, 0.47f), MotionPoint(0.82f, 0.76f), 5f)
        }
        StrengthExerciseMotionProfile.STAIR_CLIMB ->
            repeat(4) { index ->
                val x = 0.45f + index * 0.1f
                val y = 0.82f - index * 0.11f
                line(MotionPoint(x, y), MotionPoint(x + 0.12f, y), 5f)
            }
        StrengthExerciseMotionProfile.BACK_EXTENSION -> {
            line(MotionPoint(0.42f, 0.58f), MotionPoint(0.64f, 0.78f), 7f)
            line(MotionPoint(0.55f, 0.70f), MotionPoint(0.47f, 0.88f), 3f)
        }
        StrengthExerciseMotionProfile.AB_ROLLOUT -> weight(pose.leftHand, 0.035f)
        else -> Unit
    }

    when (equipment) {
        "barbell" -> {
            val leftAnchor = if (profile == StrengthExerciseMotionProfile.SQUAT) {
                pose.leftShoulder
            } else {
                pose.leftHand
            }
            val rightAnchor = if (profile == StrengthExerciseMotionProfile.SQUAT) {
                pose.rightShoulder
            } else {
                pose.rightHand
            }
            val centerX = (leftAnchor.x + rightAnchor.x) / 2f
            val y = (leftAnchor.y + rightAnchor.y) / 2f
            val halfSpan = maxOf(abs(rightAnchor.x - leftAnchor.x) / 2f + 0.11f, 0.18f)
            val left = centerX - halfSpan
            val right = centerX + halfSpan
            line(
                MotionPoint(left - 0.025f, y),
                MotionPoint(right + 0.025f, y),
                maxOf(2.2f, width * 0.009f),
            )
            plate(MotionPoint(left, y))
            plate(MotionPoint(right, y))
        }
        "dumbbell", "kettlebell" -> {
            val radius = if (equipment == "kettlebell") 0.0285f else 0.019f
            weight(pose.leftHand, radius)
            weight(pose.rightHand, radius)
        }
        "band" -> line(pose.leftHand, pose.rightHand, 3f)
        "cable" -> line(MotionPoint(0.86f, 0.16f), pose.rightHand, 1.5f)
    }
}

private fun strengthKeyframes(
    profile: StrengthExerciseMotionProfile,
): Pair<MotionPose, MotionPose> {
    var start = strengthStanding()
    var end = strengthStanding()
    when (profile) {
        StrengthExerciseMotionProfile.SQUAT -> {
            start.leftHand = MotionPoint(0.43f, 0.29f)
            start.rightHand = MotionPoint(0.57f, 0.29f)
            start.leftElbow = MotionPoint(0.36f, 0.34f)
            start.rightElbow = MotionPoint(0.64f, 0.34f)
            end = start.copyDeep()
            end.head.y = 0.28f
            end.neck.y = 0.36f
            end.leftShoulder.y = 0.39f
            end.rightShoulder.y = 0.39f
            end.leftElbow.y += 0.11f
            end.rightElbow.y += 0.11f
            end.leftHand.y += 0.11f
            end.rightHand.y += 0.11f
            end.hip = MotionPoint(0.50f, 0.63f)
            end.leftKnee = MotionPoint(0.36f, 0.70f)
            end.rightKnee = MotionPoint(0.64f, 0.70f)
        }
        StrengthExerciseMotionProfile.LEG_PRESS -> {
            start = strengthSeated()
            start.leftFoot = MotionPoint(0.76f, 0.48f)
            start.rightFoot = MotionPoint(0.78f, 0.55f)
            start.leftKnee = MotionPoint(0.57f, 0.64f)
            start.rightKnee = MotionPoint(0.60f, 0.70f)
            end = start.copyDeep()
            end.leftKnee = MotionPoint(0.67f, 0.54f)
            end.rightKnee = MotionPoint(0.69f, 0.59f)
            end.leftFoot = MotionPoint(0.80f, 0.38f)
            end.rightFoot = MotionPoint(0.82f, 0.45f)
        }
        StrengthExerciseMotionProfile.DEADLIFT -> {
            start = strengthSideStanding()
            start.leftHand = MotionPoint(0.48f, 0.56f)
            start.rightHand = MotionPoint(0.52f, 0.56f)
            end = strengthBentOver()
            end.leftHand = MotionPoint(0.61f, 0.76f)
            end.rightHand = MotionPoint(0.65f, 0.76f)
        }
        StrengthExerciseMotionProfile.HIP_THRUST -> {
            start = strengthLying()
            start.head = MotionPoint(0.27f, 0.48f)
            start.neck = MotionPoint(0.34f, 0.52f)
            start.hip = MotionPoint(0.57f, 0.69f)
            end = start.copyDeep()
            end.hip = MotionPoint(0.58f, 0.48f)
            end.leftKnee = MotionPoint(0.72f, 0.64f)
            end.rightKnee = MotionPoint(0.76f, 0.66f)
        }
        StrengthExerciseMotionProfile.LUNGE -> {
            start = strengthSideStanding()
            end = start.copyDeep()
            end.hip = MotionPoint(0.49f, 0.58f)
            end.leftKnee = MotionPoint(0.34f, 0.68f)
            end.leftFoot = MotionPoint(0.27f, 0.88f)
            end.rightKnee = MotionPoint(0.65f, 0.72f)
            end.rightFoot = MotionPoint(0.78f, 0.88f)
            end.shiftUpper(0.08f)
        }
        StrengthExerciseMotionProfile.BENCH_PRESS -> {
            start = strengthLying()
            start.leftElbow = MotionPoint(0.38f, 0.54f)
            start.rightElbow = MotionPoint(0.44f, 0.57f)
            start.leftHand = MotionPoint(0.38f, 0.36f)
            start.rightHand = MotionPoint(0.46f, 0.36f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.39f, 0.33f)
            end.rightElbow = MotionPoint(0.45f, 0.33f)
            end.leftHand = MotionPoint(0.39f, 0.19f)
            end.rightHand = MotionPoint(0.45f, 0.19f)
        }
        StrengthExerciseMotionProfile.PUSH_UP -> {
            start = strengthPlank()
            end = start.copyDeep()
            end.shiftUpper(0.12f)
            end.leftElbow = MotionPoint(0.37f, 0.67f)
            end.rightElbow = MotionPoint(0.42f, 0.70f)
        }
        StrengthExerciseMotionProfile.CHEST_FLY -> {
            start = strengthLying()
            start.leftElbow = MotionPoint(0.27f, 0.40f)
            start.rightElbow = MotionPoint(0.55f, 0.40f)
            start.leftHand = MotionPoint(0.20f, 0.43f)
            start.rightHand = MotionPoint(0.62f, 0.43f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.36f, 0.29f)
            end.rightElbow = MotionPoint(0.46f, 0.29f)
            end.leftHand = MotionPoint(0.39f, 0.18f)
            end.rightHand = MotionPoint(0.43f, 0.18f)
        }
        StrengthExerciseMotionProfile.OVERHEAD_PRESS -> {
            start.leftElbow = MotionPoint(0.39f, 0.41f)
            start.rightElbow = MotionPoint(0.61f, 0.41f)
            start.leftHand = MotionPoint(0.42f, 0.31f)
            start.rightHand = MotionPoint(0.58f, 0.31f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.44f, 0.20f)
            end.rightElbow = MotionPoint(0.56f, 0.20f)
            end.leftHand = MotionPoint(0.45f, 0.09f)
            end.rightHand = MotionPoint(0.55f, 0.09f)
        }
        StrengthExerciseMotionProfile.LATERAL_RAISE -> {
            start.leftHand = MotionPoint(0.43f, 0.56f)
            start.rightHand = MotionPoint(0.57f, 0.56f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.30f, 0.31f)
            end.rightElbow = MotionPoint(0.70f, 0.31f)
            end.leftHand = MotionPoint(0.16f, 0.31f)
            end.rightHand = MotionPoint(0.84f, 0.31f)
        }
        StrengthExerciseMotionProfile.REAR_DELT_FLY -> {
            start = strengthBentOver()
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.48f, 0.30f)
            end.rightElbow = MotionPoint(0.72f, 0.45f)
            end.leftHand = MotionPoint(0.42f, 0.24f)
            end.rightHand = MotionPoint(0.81f, 0.43f)
        }
        StrengthExerciseMotionProfile.ROW -> {
            start = strengthBentOver()
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.48f, 0.48f)
            end.rightElbow = MotionPoint(0.52f, 0.50f)
            end.leftHand = MotionPoint(0.55f, 0.55f)
            end.rightHand = MotionPoint(0.59f, 0.56f)
        }
        StrengthExerciseMotionProfile.PULL_UP -> {
            start = strengthHanging()
            end = start.copyDeep()
            end.shiftBody(dy = -0.18f)
            end.leftElbow = MotionPoint(0.36f, 0.29f)
            end.rightElbow = MotionPoint(0.64f, 0.29f)
            end.leftHand = start.leftHand.copy()
            end.rightHand = start.rightHand.copy()
        }
        StrengthExerciseMotionProfile.LAT_PULLDOWN -> {
            start = strengthSeated()
            start.leftHand = MotionPoint(0.34f, 0.13f)
            start.rightHand = MotionPoint(0.66f, 0.13f)
            start.leftElbow = MotionPoint(0.40f, 0.25f)
            start.rightElbow = MotionPoint(0.60f, 0.25f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.35f, 0.39f)
            end.rightElbow = MotionPoint(0.65f, 0.39f)
            end.leftHand = MotionPoint(0.43f, 0.33f)
            end.rightHand = MotionPoint(0.57f, 0.33f)
        }
        StrengthExerciseMotionProfile.BAND_PULL_APART -> {
            start.leftHand = MotionPoint(0.43f, 0.36f)
            start.rightHand = MotionPoint(0.57f, 0.36f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.20f, 0.34f)
            end.rightHand = MotionPoint(0.80f, 0.34f)
            end.leftElbow = MotionPoint(0.34f, 0.34f)
            end.rightElbow = MotionPoint(0.66f, 0.34f)
        }
        StrengthExerciseMotionProfile.CURL -> {
            start.leftHand = MotionPoint(0.43f, 0.59f)
            start.rightHand = MotionPoint(0.57f, 0.59f)
            start.leftElbow = MotionPoint(0.43f, 0.44f)
            start.rightElbow = MotionPoint(0.57f, 0.44f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.43f, 0.29f)
            end.rightHand = MotionPoint(0.57f, 0.29f)
        }
        StrengthExerciseMotionProfile.TRICEPS_PUSHDOWN -> {
            start.leftElbow = MotionPoint(0.43f, 0.40f)
            start.rightElbow = MotionPoint(0.57f, 0.40f)
            start.leftHand = MotionPoint(0.44f, 0.42f)
            start.rightHand = MotionPoint(0.56f, 0.42f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.42f, 0.61f)
            end.rightHand = MotionPoint(0.58f, 0.61f)
        }
        StrengthExerciseMotionProfile.TRICEPS_EXTENSION -> {
            start.leftElbow = MotionPoint(0.44f, 0.18f)
            start.rightElbow = MotionPoint(0.56f, 0.18f)
            start.leftHand = MotionPoint(0.48f, 0.31f)
            start.rightHand = MotionPoint(0.52f, 0.31f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.47f, 0.08f)
            end.rightHand = MotionPoint(0.53f, 0.08f)
        }
        StrengthExerciseMotionProfile.SKULL_CRUSHER -> {
            start = strengthLying()
            start.leftElbow = MotionPoint(0.39f, 0.29f)
            start.rightElbow = MotionPoint(0.45f, 0.29f)
            start.leftHand = MotionPoint(0.31f, 0.40f)
            start.rightHand = MotionPoint(0.37f, 0.40f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.39f, 0.16f)
            end.rightHand = MotionPoint(0.45f, 0.16f)
        }
        StrengthExerciseMotionProfile.DIP -> {
            start.leftHand = MotionPoint(0.42f, 0.43f)
            start.rightHand = MotionPoint(0.58f, 0.43f)
            end = start.copyDeep()
            end.shiftBody(dy = 0.13f)
            end.leftHand = start.leftHand.copy()
            end.rightHand = start.rightHand.copy()
            end.leftElbow = MotionPoint(0.35f, 0.42f)
            end.rightElbow = MotionPoint(0.65f, 0.42f)
        }
        StrengthExerciseMotionProfile.LEG_EXTENSION -> {
            start = strengthSeated()
            end = start.copyDeep()
            end.leftKnee = MotionPoint(0.64f, 0.66f)
            end.rightKnee = MotionPoint(0.66f, 0.70f)
            end.leftFoot = MotionPoint(0.83f, 0.65f)
            end.rightFoot = MotionPoint(0.85f, 0.70f)
        }
        StrengthExerciseMotionProfile.LEG_CURL -> {
            start = strengthProne()
            end = start.copyDeep()
            end.leftFoot = MotionPoint(0.61f, 0.39f)
            end.rightFoot = MotionPoint(0.66f, 0.40f)
        }
        StrengthExerciseMotionProfile.CALF_RAISE -> {
            end = start.copyDeep()
            end.shiftBody(dy = -0.045f)
        }
        StrengthExerciseMotionProfile.PLANK -> {
            start = strengthPlank()
            end = start.copyDeep()
            end.hip.y -= 0.025f
            end.head.y -= 0.015f
        }
        StrengthExerciseMotionProfile.SIDE_PLANK -> {
            start = strengthPlank()
            start.leftHand = MotionPoint(0.39f, 0.74f)
            start.rightHand = MotionPoint(0.54f, 0.31f)
            end = start.copyDeep()
            end.hip.y -= 0.04f
        }
        StrengthExerciseMotionProfile.HANGING_LEG_RAISE -> {
            start = strengthHanging()
            end = start.copyDeep()
            end.leftKnee = MotionPoint(0.41f, 0.61f)
            end.rightKnee = MotionPoint(0.59f, 0.61f)
            end.leftFoot = MotionPoint(0.35f, 0.48f)
            end.rightFoot = MotionPoint(0.65f, 0.48f)
        }
        StrengthExerciseMotionProfile.CABLE_CRUNCH -> {
            start = strengthKneeling()
            end = start.copyDeep()
            end.head = MotionPoint(0.57f, 0.44f)
            end.neck = MotionPoint(0.54f, 0.51f)
            end.leftShoulder = MotionPoint(0.50f, 0.53f)
            end.rightShoulder = MotionPoint(0.55f, 0.55f)
        }
        StrengthExerciseMotionProfile.AB_ROLLOUT -> {
            start = strengthKneeling()
            end = start.copyDeep()
            end.head = MotionPoint(0.70f, 0.54f)
            end.neck = MotionPoint(0.65f, 0.58f)
            end.leftShoulder = MotionPoint(0.62f, 0.60f)
            end.rightShoulder = MotionPoint(0.65f, 0.62f)
            end.leftHand = MotionPoint(0.78f, 0.76f)
            end.rightHand = MotionPoint(0.82f, 0.77f)
        }
        StrengthExerciseMotionProfile.CARRY -> {
            start = strengthSideStanding()
            end = start.copyDeep()
            start.leftKnee = MotionPoint(0.43f, 0.72f)
            start.leftFoot = MotionPoint(0.57f, 0.88f)
            end.rightKnee = MotionPoint(0.49f, 0.72f)
            end.rightFoot = MotionPoint(0.35f, 0.88f)
        }
        StrengthExerciseMotionProfile.KETTLEBELL_SWING -> {
            start = strengthBentOver()
            start.leftHand = MotionPoint(0.58f, 0.69f)
            start.rightHand = MotionPoint(0.62f, 0.70f)
            end = strengthSideStanding()
            end.leftHand = MotionPoint(0.74f, 0.35f)
            end.rightHand = MotionPoint(0.77f, 0.37f)
        }
        StrengthExerciseMotionProfile.BACK_EXTENSION -> {
            start = strengthBentOver()
            end = start.copyDeep()
            end.head = MotionPoint(0.28f, 0.34f)
            end.neck = MotionPoint(0.34f, 0.39f)
            end.leftShoulder = MotionPoint(0.38f, 0.42f)
            end.rightShoulder = MotionPoint(0.40f, 0.44f)
        }
        StrengthExerciseMotionProfile.RUN -> {
            start = strengthSideStanding()
            start.leftHand = MotionPoint(0.51f, 0.42f)
            start.rightHand = MotionPoint(0.46f, 0.48f)
            start.leftKnee = MotionPoint(0.62f, 0.66f)
            start.leftFoot = MotionPoint(0.73f, 0.78f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.44f, 0.47f)
            end.rightHand = MotionPoint(0.52f, 0.42f)
            end.leftKnee = MotionPoint(0.42f, 0.73f)
            end.leftFoot = MotionPoint(0.34f, 0.88f)
            end.rightKnee = MotionPoint(0.62f, 0.66f)
            end.rightFoot = MotionPoint(0.73f, 0.78f)
        }
        StrengthExerciseMotionProfile.CYCLE -> {
            start = strengthSideStanding()
            start.hip = MotionPoint(0.48f, 0.48f)
            start.head = MotionPoint(0.61f, 0.23f)
            start.leftHand = MotionPoint(0.72f, 0.46f)
            start.rightHand = MotionPoint(0.75f, 0.47f)
            start.leftKnee = MotionPoint(0.58f, 0.61f)
            start.rightKnee = MotionPoint(0.44f, 0.62f)
            end = start.copyDeep()
            end.leftKnee = MotionPoint(0.44f, 0.62f)
            end.rightKnee = MotionPoint(0.58f, 0.61f)
        }
        StrengthExerciseMotionProfile.ROWING_ERGOMETER -> {
            start = strengthSeated()
            start.hip = MotionPoint(0.43f, 0.64f)
            start.leftFoot = MotionPoint(0.76f, 0.73f)
            start.rightFoot = MotionPoint(0.78f, 0.76f)
            start.leftHand = MotionPoint(0.68f, 0.48f)
            start.rightHand = MotionPoint(0.71f, 0.50f)
            end = start.copyDeep()
            end.head = MotionPoint(0.38f, 0.31f)
            end.neck = MotionPoint(0.41f, 0.38f)
            end.hip = MotionPoint(0.33f, 0.64f)
            end.leftKnee = MotionPoint(0.55f, 0.68f)
            end.rightKnee = MotionPoint(0.58f, 0.71f)
            end.leftHand = MotionPoint(0.48f, 0.48f)
            end.rightHand = MotionPoint(0.51f, 0.50f)
        }
        StrengthExerciseMotionProfile.STAIR_CLIMB -> {
            start = strengthSideStanding()
            start.leftKnee = MotionPoint(0.62f, 0.67f)
            start.leftFoot = MotionPoint(0.69f, 0.75f)
            end = start.copyDeep()
            end.shiftBody(dx = 0.08f, dy = -0.07f)
            end.rightKnee = MotionPoint(0.68f, 0.65f)
            end.rightFoot = MotionPoint(0.74f, 0.72f)
        }
        StrengthExerciseMotionProfile.GENERIC -> {
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.36f, 0.48f)
            end.rightHand = MotionPoint(0.64f, 0.48f)
        }
    }
    return start to end
}

private fun strengthStanding() = MotionPose(
    MotionPoint(0.50f, 0.15f), MotionPoint(0.50f, 0.24f),
    MotionPoint(0.43f, 0.28f), MotionPoint(0.57f, 0.28f),
    MotionPoint(0.40f, 0.42f), MotionPoint(0.60f, 0.42f),
    MotionPoint(0.40f, 0.56f), MotionPoint(0.60f, 0.56f),
    MotionPoint(0.50f, 0.55f), MotionPoint(0.44f, 0.72f),
    MotionPoint(0.56f, 0.72f), MotionPoint(0.41f, 0.89f),
    MotionPoint(0.59f, 0.89f),
)

private fun strengthSideStanding() = MotionPose(
    MotionPoint(0.53f, 0.15f), MotionPoint(0.50f, 0.24f),
    MotionPoint(0.48f, 0.29f), MotionPoint(0.52f, 0.30f),
    MotionPoint(0.45f, 0.43f), MotionPoint(0.55f, 0.44f),
    MotionPoint(0.44f, 0.57f), MotionPoint(0.56f, 0.58f),
    MotionPoint(0.49f, 0.55f), MotionPoint(0.44f, 0.72f),
    MotionPoint(0.55f, 0.72f), MotionPoint(0.40f, 0.89f),
    MotionPoint(0.61f, 0.89f),
)

private fun strengthLying() = MotionPose(
    MotionPoint(0.22f, 0.49f), MotionPoint(0.29f, 0.50f),
    MotionPoint(0.34f, 0.51f), MotionPoint(0.37f, 0.54f),
    MotionPoint(0.39f, 0.43f), MotionPoint(0.43f, 0.47f),
    MotionPoint(0.40f, 0.34f), MotionPoint(0.45f, 0.36f),
    MotionPoint(0.58f, 0.56f), MotionPoint(0.73f, 0.66f),
    MotionPoint(0.76f, 0.69f), MotionPoint(0.80f, 0.86f),
    MotionPoint(0.86f, 0.86f),
)

private fun strengthProne() = strengthLying().apply {
    head = MotionPoint(0.22f, 0.53f)
    neck = MotionPoint(0.29f, 0.55f)
    hip = MotionPoint(0.57f, 0.59f)
    leftKnee = MotionPoint(0.70f, 0.61f)
    rightKnee = MotionPoint(0.73f, 0.64f)
    leftFoot = MotionPoint(0.84f, 0.62f)
    rightFoot = MotionPoint(0.86f, 0.66f)
}

private fun strengthSeated() = MotionPose(
    MotionPoint(0.39f, 0.20f), MotionPoint(0.41f, 0.29f),
    MotionPoint(0.38f, 0.33f), MotionPoint(0.43f, 0.34f),
    MotionPoint(0.38f, 0.46f), MotionPoint(0.45f, 0.47f),
    MotionPoint(0.40f, 0.58f), MotionPoint(0.48f, 0.59f),
    MotionPoint(0.44f, 0.60f), MotionPoint(0.61f, 0.65f),
    MotionPoint(0.65f, 0.68f), MotionPoint(0.64f, 0.86f),
    MotionPoint(0.69f, 0.87f),
)

private fun strengthBentOver() = MotionPose(
    MotionPoint(0.66f, 0.34f), MotionPoint(0.60f, 0.39f),
    MotionPoint(0.56f, 0.42f), MotionPoint(0.60f, 0.44f),
    MotionPoint(0.61f, 0.56f), MotionPoint(0.65f, 0.58f),
    MotionPoint(0.64f, 0.70f), MotionPoint(0.68f, 0.71f),
    MotionPoint(0.44f, 0.57f), MotionPoint(0.42f, 0.73f),
    MotionPoint(0.53f, 0.74f), MotionPoint(0.37f, 0.89f),
    MotionPoint(0.60f, 0.89f),
)

private fun strengthPlank() = MotionPose(
    MotionPoint(0.25f, 0.49f), MotionPoint(0.31f, 0.51f),
    MotionPoint(0.36f, 0.53f), MotionPoint(0.39f, 0.55f),
    MotionPoint(0.37f, 0.64f), MotionPoint(0.42f, 0.66f),
    MotionPoint(0.35f, 0.75f), MotionPoint(0.43f, 0.76f),
    MotionPoint(0.59f, 0.58f), MotionPoint(0.72f, 0.63f),
    MotionPoint(0.75f, 0.65f), MotionPoint(0.86f, 0.68f),
    MotionPoint(0.89f, 0.70f),
)

private fun strengthHanging() = MotionPose(
    MotionPoint(0.50f, 0.29f), MotionPoint(0.50f, 0.36f),
    MotionPoint(0.43f, 0.39f), MotionPoint(0.57f, 0.39f),
    MotionPoint(0.38f, 0.25f), MotionPoint(0.62f, 0.25f),
    MotionPoint(0.34f, 0.11f), MotionPoint(0.66f, 0.11f),
    MotionPoint(0.50f, 0.63f), MotionPoint(0.45f, 0.75f),
    MotionPoint(0.55f, 0.75f), MotionPoint(0.43f, 0.89f),
    MotionPoint(0.57f, 0.89f),
)

private fun strengthKneeling() = MotionPose(
    MotionPoint(0.47f, 0.28f), MotionPoint(0.48f, 0.36f),
    MotionPoint(0.44f, 0.40f), MotionPoint(0.50f, 0.41f),
    MotionPoint(0.48f, 0.52f), MotionPoint(0.54f, 0.53f),
    MotionPoint(0.52f, 0.64f), MotionPoint(0.58f, 0.65f),
    MotionPoint(0.45f, 0.62f), MotionPoint(0.40f, 0.78f),
    MotionPoint(0.48f, 0.79f), MotionPoint(0.30f, 0.87f),
    MotionPoint(0.39f, 0.88f),
)

private fun MotionPose.shiftUpper(dy: Float) {
    head.y += dy
    neck.y += dy
    leftShoulder.y += dy
    rightShoulder.y += dy
}

private fun MotionPose.shiftBody(dx: Float = 0f, dy: Float = 0f) {
    listOf(
        head, neck, leftShoulder, rightShoulder, leftElbow, rightElbow,
        leftHand, rightHand, hip, leftKnee, rightKnee, leftFoot, rightFoot,
    ).forEach {
        it.x += dx
        it.y += dy
    }
}
