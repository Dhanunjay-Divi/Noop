package com.noop.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color as AndroidColor
import android.util.Log
import android.view.View
import android.webkit.ConsoleMessage
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebViewClient
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.noop.R
import com.noop.BuildConfig
import com.noop.data.StrengthExerciseAnimationVariant
import com.noop.data.StrengthExerciseGuidance
import com.noop.data.StrengthExerciseMotionProfile
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthMuscleStatus
import java.io.ByteArrayInputStream
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

private const val STRENGTH_MOTION_HOST = "appassets.androidplatform.net"
private const val STRENGTH_MOTION_PREFIX = "/assets/strength-motion/"
private const val STRENGTH_MOTION_ORIGIN = "https://$STRENGTH_MOTION_HOST"

/** Native offline counterpart to iOS StrengthExerciseMotionView. */
@Composable
fun StrengthExerciseMotionView(
    exercise: StrengthExerciseRow,
    modifier: Modifier = Modifier,
) {
    val guide = remember(exercise) { StrengthExerciseGuidance.guide(exercise) }
    val still = rememberPoseStill()
    val animationVariant = guide.animationVariant
    if (animationVariant != null) {
        StrengthMotionWebView(
            exerciseId = animationVariant.exerciseId,
            cycleDurationSeconds = guide.cycleDurationSeconds,
            reduceMotion = still,
            modifier = modifier,
        )
        return
    }
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
                variant = guide.animationVariant,
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

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun StrengthMotionWebView(
    exerciseId: String,
    cycleDurationSeconds: Float,
    reduceMotion: Boolean,
    modifier: Modifier,
) {
    val shape = RoundedCornerShape(8.dp)
    val pageUrl = remember(exerciseId, cycleDurationSeconds, reduceMotion) {
        "$STRENGTH_MOTION_ORIGIN${STRENGTH_MOTION_PREFIX}index.html" +
            "?exercise=$exerciseId" +
            "&duration=${String.format(Locale.US, "%.3f", cycleDurationSeconds)}" +
            "&reduceMotion=${if (reduceMotion) 1 else 0}"
    }
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                if (BuildConfig.DEBUG) {
                    WebView.setWebContentsDebuggingEnabled(true)
                }
                setBackgroundColor(AndroidColor.rgb(8, 9, 12))
                setLayerType(View.LAYER_TYPE_HARDWARE, null)
                overScrollMode = View.OVER_SCROLL_NEVER
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = false
                settings.databaseEnabled = false
                settings.cacheMode = WebSettings.LOAD_NO_CACHE
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.allowFileAccessFromFileURLs = false
                settings.allowUniversalAccessFromFileURLs = false
                settings.blockNetworkLoads = true
                settings.mediaPlaybackRequiresUserGesture = true
                if (BuildConfig.DEBUG) {
                    webChromeClient = object : WebChromeClient() {
                        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
                            Log.d(
                                "StrengthMotion",
                                "${message.messageLevel()}: ${message.message()} " +
                                    "(${message.sourceId()}:${message.lineNumber()})",
                            )
                            return true
                        }
                    }
                }
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(
                        view: WebView,
                        request: WebResourceRequest,
                    ): WebResourceResponse? = strengthMotionAssetResponse(context, request)

                    override fun onPageFinished(view: WebView, url: String) {
                        if (BuildConfig.DEBUG) {
                            Log.d("StrengthMotion", "Loaded $url")
                        }
                    }

                    override fun onReceivedError(
                        view: WebView,
                        request: WebResourceRequest,
                        error: WebResourceError,
                    ) {
                        if (BuildConfig.DEBUG) {
                            Log.e(
                                "StrengthMotion",
                                "Failed ${request.url}: ${error.errorCode} ${error.description}",
                            )
                        }
                    }
                }
            }
        },
        update = { webView ->
            if (webView.tag != pageUrl) {
                webView.tag = pageUrl
                webView.loadUrl(pageUrl)
            }
        },
        modifier = modifier
            .aspectRatio(1.62f)
            .clip(shape)
            .background(Palette.surfaceInset, shape)
            .border(1.dp, Palette.hairline, shape)
            .semantics {
                contentDescription = "Interactive 3D exercise demonstration"
            },
    )
}

private fun strengthMotionAssetResponse(
    context: Context,
    request: WebResourceRequest,
): WebResourceResponse? {
    val url = request.url
    if (url.scheme != "http" && url.scheme != "https") return null
    if (
        url.scheme != "https" ||
        url.host != STRENGTH_MOTION_HOST ||
        url.path?.startsWith(STRENGTH_MOTION_PREFIX) != true
    ) {
        return strengthMotionErrorResponse(403, "Forbidden")
    }
    val assetPath = url.path!!.removePrefix("/assets/")
    if (assetPath.contains("..")) {
        return strengthMotionErrorResponse(403, "Forbidden")
    }
    return runCatching {
        val extension = assetPath.substringAfterLast('.', missingDelimiterValue = "")
        val mimeType = when (extension) {
            "html" -> "text/html"
            "css" -> "text/css"
            "js" -> "application/javascript"
            "json" -> "application/json"
            "glb" -> "model/gltf-binary"
            else -> "application/octet-stream"
        }
        val encoding = if (extension in setOf("html", "css", "js", "json")) "UTF-8" else null
        WebResourceResponse(mimeType, encoding, context.assets.open(assetPath))
    }.getOrElse { cause ->
        Log.e("StrengthMotion", "Missing local asset $assetPath", cause)
        strengthMotionErrorResponse(404, "Not Found")
    }
}

private fun strengthMotionErrorResponse(statusCode: Int, reason: String): WebResourceResponse =
    WebResourceResponse(
        "text/plain",
        "UTF-8",
        statusCode,
        reason,
        emptyMap(),
        ByteArrayInputStream(reason.toByteArray(Charsets.UTF_8)),
    )

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
    variant: StrengthExerciseAnimationVariant?,
    phase: Float,
) {
    val pingPong = (0.5 - 0.5 * cos(phase * PI * 2)).toFloat()
    val amount = pingPong * pingPong * (3f - 2f * pingPong)
    val pair = strengthKeyframes(profile, variant)
    val pose = MotionPose.mix(pair.first, pair.second, amount)
    val width = min(size.width, size.height * 1.62f)
    val height = width / 1.62f
    val origin = Offset((size.width - width) / 2f, (size.height - height) / 2f)

    drawStrengthStage(width, height, origin)
    drawStrengthEquipment(
        pose = pose,
        profile = profile,
        variant = variant,
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
    drawStrengthHeldEquipment(
        pose = pose,
        profile = profile,
        variant = variant,
        equipment = exercise.equipment,
        width = width,
        height = height,
        origin = origin,
    )
}

private fun DrawScope.drawStrengthStage(
    width: Float,
    height: Float,
    origin: Offset,
) {
    val groundY = origin.y + height * 0.91f
    val poolCenter = Offset(origin.x + width * 0.5f, groundY)
    drawOval(
        brush = Brush.radialGradient(
            colors = listOf(
                Palette.textPrimary.copy(alpha = 0.10f),
                Color.Transparent,
            ),
            center = poolCenter,
            radius = width * 0.38f,
        ),
        topLeft = Offset(origin.x + width * 0.12f, groundY - height * 0.035f),
        size = Size(width * 0.76f, height * 0.09f),
    )
    drawLine(
        brush = Brush.linearGradient(
            colors = listOf(
                Color.Transparent,
                Palette.hairline.copy(alpha = 0.95f),
                Color.Transparent,
            ),
            start = Offset(origin.x, groundY),
            end = Offset(origin.x + width, groundY),
        ),
        start = Offset(origin.x + width * 0.13f, groundY),
        end = Offset(origin.x + width * 0.87f, groundY),
        strokeWidth = 1.2f,
        cap = StrokeCap.Round,
    )
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
    fun mix(a: Offset, b: Offset, amount: Float) = Offset(
        x = a.x + (b.x - a.x) * amount,
        y = a.y + (b.y - a.y) * amount,
    )
    fun taperedSegment(
        start: Offset,
        end: Offset,
        startWidth: Float,
        endWidth: Float,
        colors: List<Color>,
    ) {
        val dx = end.x - start.x
        val dy = end.y - start.y
        val length = maxOf(1f, sqrt(dx * dx + dy * dy))
        val nx = -dy / length
        val ny = dx / length
        val path = Path().apply {
            moveTo(start.x + nx * startWidth / 2f, start.y + ny * startWidth / 2f)
            lineTo(end.x + nx * endWidth / 2f, end.y + ny * endWidth / 2f)
            quadraticBezierTo(
                end.x + dx / length * endWidth / 2f,
                end.y + dy / length * endWidth / 2f,
                end.x - nx * endWidth / 2f,
                end.y - ny * endWidth / 2f,
            )
            lineTo(start.x - nx * startWidth / 2f, start.y - ny * startWidth / 2f)
            quadraticBezierTo(
                start.x - dx / length * startWidth / 2f,
                start.y - dy / length * startWidth / 2f,
                start.x + nx * startWidth / 2f,
                start.y + ny * startWidth / 2f,
            )
            close()
        }
        drawPath(
            path = path,
            brush = Brush.linearGradient(
                colors = colors,
                start = Offset(
                    minOf(start.x, end.x) - maxOf(startWidth, endWidth) / 2f,
                    minOf(start.y, end.y),
                ),
                end = Offset(
                    maxOf(start.x, end.x) + maxOf(startWidth, endWidth) / 2f,
                    maxOf(start.y, end.y),
                ),
            ),
        )
    }
    fun taperedSegment(
        start: MotionPoint,
        end: MotionPoint,
        startWidth: Float,
        endWidth: Float,
        colors: List<Color>,
    ) = taperedSegment(p(start), p(end), startWidth, endWidth, colors)

    fun gradientCircle(point: MotionPoint, diameter: Float, colors: List<Color>) {
        val center = p(point)
        drawCircle(
            brush = Brush.linearGradient(
                colors = colors,
                start = Offset(center.x - diameter * 0.35f, center.y - diameter * 0.45f),
                end = Offset(center.x + diameter * 0.4f, center.y + diameter * 0.5f),
            ),
            radius = diameter / 2f,
            center = center,
        )
    }

    val bodyRear = listOf(
        Palette.textTertiary.copy(alpha = 0.78f),
        Palette.textSecondary.copy(alpha = 0.88f),
    )
    val bodyFront = listOf(
        Palette.textPrimary.copy(alpha = 0.98f),
        Palette.textSecondary.copy(alpha = 0.92f),
        Palette.textTertiary.copy(alpha = 0.92f),
    )
    val torsoColors = listOf(
        Palette.textPrimary.copy(alpha = 0.96f),
        Palette.metricCyan.copy(alpha = 0.52f),
        Palette.textTertiary.copy(alpha = 0.92f),
    )
    val muscleColors = listOf(
        Palette.effortColor.copy(alpha = 0.98f),
        Color(0xFF9E010F).copy(alpha = 0.96f),
    )
    val armUpper = maxOf(7.5f, width * 0.043f)
    val forearmUpper = maxOf(6.2f, width * 0.034f)
    val thighUpper = maxOf(10f, width * 0.058f)
    val calfUpper = maxOf(8f, width * 0.045f)
    val joint = maxOf(7f, width * 0.037f)

    taperedSegment(
        pose.leftShoulder,
        pose.leftElbow,
        armUpper,
        armUpper * 0.78f,
        bodyRear,
    )
    taperedSegment(
        pose.leftElbow,
        pose.leftHand,
        forearmUpper,
        forearmUpper * 0.62f,
        bodyRear,
    )
    taperedSegment(
        pose.hip,
        pose.leftKnee,
        thighUpper,
        thighUpper * 0.72f,
        bodyRear,
    )
    taperedSegment(
        pose.leftKnee,
        pose.leftFoot,
        calfUpper,
        calfUpper * 0.54f,
        bodyRear,
    )

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
    val hipHalfWidth = maxOf(8f, width * 0.043f)
    val hipLeft = Offset(
        hip.x - normalX * hipHalfWidth,
        hip.y - normalY * hipHalfWidth,
    )
    val hipRight = Offset(
        hip.x + normalX * hipHalfWidth,
        hip.y + normalY * hipHalfWidth,
    )
    val waistCenter = mix(shoulderMid, hip, 0.70f)
    val waistHalfWidth = maxOf(7f, width * 0.036f)
    val waistLeft = Offset(
        waistCenter.x - normalX * waistHalfWidth,
        waistCenter.y - normalY * waistHalfWidth,
    )
    val waistRight = Offset(
        waistCenter.x + normalX * waistHalfWidth,
        waistCenter.y + normalY * waistHalfWidth,
    )
    val torso = Path().apply {
        moveTo(shoulderLeft.x, shoulderLeft.y)
        quadraticBezierTo(p(pose.neck).x, p(pose.neck).y, shoulderRight.x, shoulderRight.y)
        quadraticBezierTo(
            mix(shoulderRight, waistRight, 0.58f).x,
            mix(shoulderRight, waistRight, 0.58f).y,
            waistRight.x,
            waistRight.y,
        )
        quadraticBezierTo(
            mix(waistRight, hipRight, 0.55f).x,
            mix(waistRight, hipRight, 0.55f).y,
            hipRight.x,
            hipRight.y,
        )
        quadraticBezierTo(hip.x, hip.y, hipLeft.x, hipLeft.y)
        quadraticBezierTo(
            mix(hipLeft, waistLeft, 0.45f).x,
            mix(hipLeft, waistLeft, 0.45f).y,
            waistLeft.x,
            waistLeft.y,
        )
        quadraticBezierTo(
            mix(waistLeft, shoulderLeft, 0.42f).x,
            mix(waistLeft, shoulderLeft, 0.42f).y,
            shoulderLeft.x,
            shoulderLeft.y,
        )
        close()
    }
    drawPath(
        path = torso,
        brush = Brush.linearGradient(
            colors = torsoColors,
            start = Offset(
                minOf(shoulderLeft.x, shoulderRight.x),
                minOf(shoulderLeft.y, shoulderRight.y),
            ),
            end = Offset(maxOf(hipLeft.x, hipRight.x), maxOf(hipLeft.y, hipRight.y)),
        ),
    )
    drawPath(
        path = torso,
        color = Palette.textPrimary.copy(alpha = 0.22f),
        style = Stroke(width = maxOf(0.8f, width * 0.004f)),
    )
    taperedSegment(
        pose.neck,
        MotionPoint(
            (pose.leftShoulder.x + pose.rightShoulder.x) / 2f,
            (pose.leftShoulder.y + pose.rightShoulder.y) / 2f,
        ),
        armUpper * 0.70f,
        armUpper * 0.85f,
        bodyFront,
    )
    drawLine(
        color = Palette.textPrimary.copy(alpha = 0.13f),
        start = shoulderMid,
        end = waistCenter,
        strokeWidth = 1f,
        cap = StrokeCap.Round,
    )
    taperedSegment(
        hipLeft,
        hipRight,
        thighUpper * 0.72f,
        thighUpper * 0.72f,
        torsoColors,
    )

    taperedSegment(
        pose.rightShoulder,
        pose.rightElbow,
        armUpper * 1.04f,
        armUpper * 0.80f,
        bodyFront,
    )
    taperedSegment(
        pose.rightElbow,
        pose.rightHand,
        forearmUpper * 1.04f,
        forearmUpper * 0.60f,
        bodyFront,
    )
    taperedSegment(
        pose.hip,
        pose.rightKnee,
        thighUpper * 1.04f,
        thighUpper * 0.72f,
        bodyFront,
    )
    taperedSegment(
        pose.rightKnee,
        pose.rightFoot,
        calfUpper * 1.04f,
        calfUpper * 0.52f,
        bodyFront,
    )

    val head = p(pose.head)
    val headWidth = maxOf(16f, width * 0.082f)
    val headHeight = headWidth * 1.14f
    drawOval(
        brush = Brush.linearGradient(
            colors = bodyFront,
            start = Offset(head.x - headWidth * 0.35f, head.y - headHeight * 0.45f),
            end = Offset(head.x + headWidth * 0.4f, head.y + headHeight * 0.5f),
        ),
        topLeft = Offset(head.x - headWidth / 2f, head.y - headHeight / 2f),
        size = Size(headWidth, headHeight),
    )
    drawOval(
        color = Palette.textPrimary.copy(alpha = 0.18f),
        topLeft = Offset(head.x - headWidth / 2f, head.y - headHeight / 2f),
        size = Size(headWidth, headHeight),
        style = Stroke(width = maxOf(0.8f, width * 0.0035f)),
    )
    val facing = if (pose.head.x >= pose.neck.x) 1f else -1f
    drawLine(
        color = Palette.surfaceInset.copy(alpha = 0.5f),
        start = Offset(head.x + facing * headWidth * 0.12f, head.y - headHeight * 0.08f),
        end = Offset(head.x + facing * headWidth * 0.28f, head.y + headHeight * 0.03f),
        strokeWidth = maxOf(1f, width * 0.004f),
        cap = StrokeCap.Round,
    )
    listOf(pose.leftElbow, pose.rightElbow, pose.leftKnee, pose.rightKnee).forEach {
        gradientCircle(it, joint, bodyFront)
    }
    listOf(pose.leftHand, pose.rightHand).forEach {
        gradientCircle(it, forearmUpper * 0.74f, bodyFront)
    }
    fun drawFoot(foot: MotionPoint, knee: MotionPoint, colors: List<Color>) {
        val direction = if (foot.x >= knee.x) 1f else -1f
        taperedSegment(
            foot,
            MotionPoint(foot.x + direction * 0.045f, foot.y + 0.006f),
            calfUpper * 0.48f,
            calfUpper * 0.34f,
            colors,
        )
    }
    drawFoot(pose.leftFoot, pose.leftKnee, bodyRear)
    drawFoot(pose.rightFoot, pose.rightKnee, bodyFront)

    fun accent(start: MotionPoint, end: MotionPoint, startWidth: Float, endWidth: Float) {
        taperedSegment(start, end, startWidth, endWidth, muscleColors)
    }
    fun accentCircle(point: MotionPoint, diameter: Float) {
        gradientCircle(point, diameter, muscleColors)
    }
    val upperArmAccent = armUpper * 0.56f
    val thighAccent = thighUpper * 0.58f
    when (primaryMuscle) {
        "chest" -> {
            accent(
                MotionPoint.mix(pose.leftShoulder, pose.neck, 0.18f),
                MotionPoint.mix(pose.neck, pose.hip, 0.42f),
                upperArmAccent,
                upperArmAccent * 0.82f,
            )
            accent(
                MotionPoint.mix(pose.rightShoulder, pose.neck, 0.18f),
                MotionPoint.mix(pose.neck, pose.hip, 0.42f),
                upperArmAccent,
                upperArmAccent * 0.82f,
            )
        }
        "back" -> accent(
            MotionPoint.mix(pose.neck, pose.hip, 0.14f),
            MotionPoint.mix(pose.neck, pose.hip, 0.68f),
            armUpper * 0.74f,
            armUpper * 0.52f,
        )
        "shoulders" -> {
            accentCircle(pose.leftShoulder, armUpper * 0.72f)
            accentCircle(pose.rightShoulder, armUpper * 0.72f)
        }
        "biceps", "triceps" -> {
            accent(
                MotionPoint.mix(pose.leftShoulder, pose.leftElbow, 0.16f),
                MotionPoint.mix(pose.leftShoulder, pose.leftElbow, 0.82f),
                upperArmAccent,
                upperArmAccent * 0.78f,
            )
            accent(
                MotionPoint.mix(pose.rightShoulder, pose.rightElbow, 0.18f),
                MotionPoint.mix(pose.rightShoulder, pose.rightElbow, 0.82f),
                upperArmAccent,
                upperArmAccent * 0.78f,
            )
        }
        "forearms" -> {
            accent(
                MotionPoint.mix(pose.leftElbow, pose.leftHand, 0.14f),
                MotionPoint.mix(pose.leftElbow, pose.leftHand, 0.82f),
                forearmUpper * 0.58f,
                forearmUpper * 0.40f,
            )
            accent(
                MotionPoint.mix(pose.rightElbow, pose.rightHand, 0.16f),
                MotionPoint.mix(pose.rightElbow, pose.rightHand, 0.84f),
                forearmUpper * 0.58f,
                forearmUpper * 0.40f,
            )
        }
        "core" -> accent(
            MotionPoint.mix(pose.neck, pose.hip, 0.42f),
            MotionPoint.mix(pose.neck, pose.hip, 0.83f),
            armUpper * 0.62f,
            armUpper * 0.50f,
        )
        "quadriceps", "hamstrings" -> {
            accent(
                MotionPoint.mix(pose.hip, pose.leftKnee, 0.16f),
                MotionPoint.mix(pose.hip, pose.leftKnee, 0.82f),
                thighAccent,
                thighAccent * 0.66f,
            )
            accent(
                MotionPoint.mix(pose.hip, pose.rightKnee, 0.16f),
                MotionPoint.mix(pose.hip, pose.rightKnee, 0.82f),
                thighAccent,
                thighAccent * 0.66f,
            )
        }
        "glutes" -> accentCircle(pose.hip, thighUpper * 0.82f)
        "calves" -> {
            accent(
                MotionPoint.mix(pose.leftKnee, pose.leftFoot, 0.18f),
                MotionPoint.mix(pose.leftKnee, pose.leftFoot, 0.76f),
                calfUpper * 0.58f,
                calfUpper * 0.39f,
            )
            accent(
                MotionPoint.mix(pose.rightKnee, pose.rightFoot, 0.2f),
                MotionPoint.mix(pose.rightKnee, pose.rightFoot, 0.78f),
                calfUpper * 0.58f,
                calfUpper * 0.39f,
            )
        }
        "full_body" -> {
            accent(
                MotionPoint.mix(pose.neck, pose.hip, 0.22f),
                MotionPoint.mix(pose.neck, pose.hip, 0.72f),
                upperArmAccent,
                upperArmAccent * 0.76f,
            )
            accent(
                MotionPoint.mix(pose.hip, pose.rightKnee, 0.22f),
                MotionPoint.mix(pose.hip, pose.rightKnee, 0.72f),
                thighAccent * 0.74f,
                thighAccent * 0.52f,
            )
        }
        else -> accent(
            MotionPoint.mix(pose.neck, pose.hip, 0.34f),
            MotionPoint.mix(pose.neck, pose.hip, 0.68f),
            upperArmAccent * 0.80f,
            upperArmAccent * 0.64f,
        )
    }
}

private fun DrawScope.drawStrengthEquipment(
    pose: MotionPose,
    profile: StrengthExerciseMotionProfile,
    variant: StrengthExerciseAnimationVariant?,
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
    fun flatBench() {
        line(MotionPoint(0.18f, 0.61f), MotionPoint(0.72f, 0.61f), 5f)
        line(MotionPoint(0.29f, 0.61f), MotionPoint(0.24f, 0.83f), 3f)
        line(MotionPoint(0.62f, 0.61f), MotionPoint(0.67f, 0.83f), 3f)
    }
    fun cableTower(double: Boolean = false) {
        line(MotionPoint(0.87f, 0.15f), MotionPoint(0.87f, 0.88f), 6f)
        line(MotionPoint(0.82f, 0.15f), MotionPoint(0.92f, 0.15f), 4f)
        if (double) {
            line(MotionPoint(0.13f, 0.15f), MotionPoint(0.13f, 0.88f), 6f)
            line(MotionPoint(0.08f, 0.15f), MotionPoint(0.18f, 0.15f), 4f)
        }
    }

    when (variant) {
        StrengthExerciseAnimationVariant.BENCH_PRESS,
        StrengthExerciseAnimationVariant.DUMBBELL_BENCH_PRESS,
        StrengthExerciseAnimationVariant.CHEST_FLY,
        StrengthExerciseAnimationVariant.SKULL_CRUSHER,
        -> flatBench()
        StrengthExerciseAnimationVariant.INCLINE_BENCH_PRESS,
        StrengthExerciseAnimationVariant.CHEST_SUPPORTED_ROW,
        -> {
            line(MotionPoint(0.22f, 0.72f), MotionPoint(0.55f, 0.49f), 6f)
            line(MotionPoint(0.29f, 0.67f), MotionPoint(0.24f, 0.85f), 3f)
            line(MotionPoint(0.51f, 0.52f), MotionPoint(0.62f, 0.84f), 3f)
        }
        StrengthExerciseAnimationVariant.PULL_UP,
        StrengthExerciseAnimationVariant.CHIN_UP,
        StrengthExerciseAnimationVariant.HANGING_LEG_RAISE,
        -> {
            line(MotionPoint(0.27f, 0.11f), MotionPoint(0.73f, 0.11f), 4f)
            line(MotionPoint(0.29f, 0.11f), MotionPoint(0.29f, 0.19f), 3f)
            line(MotionPoint(0.71f, 0.11f), MotionPoint(0.71f, 0.19f), 3f)
        }
        StrengthExerciseAnimationVariant.LAT_PULLDOWN -> {
            cableTower()
            line(MotionPoint(0.25f, 0.10f), MotionPoint(0.75f, 0.10f), 3f)
            line(MotionPoint(0.50f, 0.10f), MotionPoint(0.50f, 0.20f), 1.5f)
            line(MotionPoint(0.30f, 0.79f), MotionPoint(0.56f, 0.79f), 5f)
        }
        StrengthExerciseAnimationVariant.LEG_PRESS,
        StrengthExerciseAnimationVariant.HACK_SQUAT,
        -> {
            line(MotionPoint(0.72f, 0.25f), MotionPoint(0.82f, 0.70f), 7f)
            line(MotionPoint(0.18f, 0.72f), MotionPoint(0.50f, 0.83f), 6f)
            line(MotionPoint(0.18f, 0.82f), MotionPoint(0.82f, 0.82f), 3f)
        }
        StrengthExerciseAnimationVariant.LEG_EXTENSION,
        StrengthExerciseAnimationVariant.LYING_LEG_CURL,
        StrengthExerciseAnimationVariant.SEATED_CALF_RAISE,
        -> {
            line(MotionPoint(0.28f, 0.58f), MotionPoint(0.63f, 0.58f), 6f)
            line(MotionPoint(0.34f, 0.58f), MotionPoint(0.30f, 0.84f), 3f)
            line(MotionPoint(0.72f, 0.58f), MotionPoint(0.72f, 0.82f), 4f)
        }
        StrengthExerciseAnimationVariant.HIP_THRUST ->
            line(MotionPoint(0.18f, 0.56f), MotionPoint(0.43f, 0.56f), 6f)
        StrengthExerciseAnimationVariant.BULGARIAN_SPLIT_SQUAT -> {
            line(MotionPoint(0.16f, 0.66f), MotionPoint(0.36f, 0.66f), 6f)
            line(MotionPoint(0.21f, 0.66f), MotionPoint(0.19f, 0.86f), 3f)
        }
        StrengthExerciseAnimationVariant.DIP -> {
            line(MotionPoint(0.30f, 0.42f), MotionPoint(0.46f, 0.42f), 4f)
            line(MotionPoint(0.54f, 0.42f), MotionPoint(0.70f, 0.42f), 4f)
            line(MotionPoint(0.34f, 0.42f), MotionPoint(0.34f, 0.84f), 3f)
            line(MotionPoint(0.66f, 0.42f), MotionPoint(0.66f, 0.84f), 3f)
        }
        StrengthExerciseAnimationVariant.TRICEPS_PUSHDOWN,
        StrengthExerciseAnimationVariant.CABLE_CROSSOVER,
        StrengthExerciseAnimationVariant.SEATED_CABLE_ROW,
        StrengthExerciseAnimationVariant.FACE_PULL,
        StrengthExerciseAnimationVariant.CABLE_CRUNCH,
        -> {
            cableTower(variant == StrengthExerciseAnimationVariant.CABLE_CROSSOVER)
            if (variant == StrengthExerciseAnimationVariant.SEATED_CABLE_ROW) {
                line(MotionPoint(0.30f, 0.77f), MotionPoint(0.67f, 0.77f), 5f)
            }
        }
        StrengthExerciseAnimationVariant.MACHINE_CHEST_PRESS -> {
            line(MotionPoint(0.28f, 0.55f), MotionPoint(0.28f, 0.84f), 6f)
            line(MotionPoint(0.28f, 0.58f), MotionPoint(0.52f, 0.58f), 5f)
            line(MotionPoint(0.70f, 0.31f), MotionPoint(0.70f, 0.83f), 5f)
        }
        StrengthExerciseAnimationVariant.PREACHER_CURL -> {
            line(MotionPoint(0.31f, 0.62f), MotionPoint(0.57f, 0.48f), 7f)
            line(MotionPoint(0.42f, 0.56f), MotionPoint(0.35f, 0.84f), 3f)
        }
        StrengthExerciseAnimationVariant.INDOOR_CYCLING -> {
            drawCircle(
                Palette.textTertiary.copy(alpha = 0.9f),
                width * 0.135f,
                p(MotionPoint(0.55f, 0.68f)),
                style = Stroke(width = 3f),
            )
            line(MotionPoint(0.39f, 0.52f), MotionPoint(0.55f, 0.68f), 3f)
            line(MotionPoint(0.55f, 0.68f), MotionPoint(0.72f, 0.49f), 3f)
            line(MotionPoint(0.42f, 0.48f), MotionPoint(0.48f, 0.48f), 5f)
        }
        StrengthExerciseAnimationVariant.ROWING_ERGOMETER -> {
            line(MotionPoint(0.22f, 0.76f), MotionPoint(0.82f, 0.76f), 4f)
            line(MotionPoint(0.75f, 0.47f), MotionPoint(0.82f, 0.76f), 5f)
            weight(MotionPoint(0.78f, 0.51f), 0.05f)
        }
        StrengthExerciseAnimationVariant.STAIR_CLIMBER -> {
            repeat(4) { index ->
                val x = 0.45f + index * 0.1f
                val y = 0.82f - index * 0.11f
                line(MotionPoint(x, y), MotionPoint(x + 0.12f, y), 5f)
            }
            line(MotionPoint(0.84f, 0.40f), MotionPoint(0.84f, 0.83f), 4f)
        }
        StrengthExerciseAnimationVariant.TREADMILL_RUN -> {
            line(MotionPoint(0.16f, 0.88f), MotionPoint(0.84f, 0.88f), 7f)
            line(MotionPoint(0.76f, 0.88f), MotionPoint(0.84f, 0.50f), 4f)
            line(MotionPoint(0.69f, 0.50f), MotionPoint(0.88f, 0.50f), 4f)
        }
        StrengthExerciseAnimationVariant.BACK_EXTENSION -> {
            line(MotionPoint(0.42f, 0.58f), MotionPoint(0.64f, 0.78f), 7f)
            line(MotionPoint(0.55f, 0.70f), MotionPoint(0.47f, 0.88f), 3f)
        }
        StrengthExerciseAnimationVariant.AB_WHEEL_ROLLOUT -> weight(pose.leftHand, 0.035f)
        else -> when (profile) {
            StrengthExerciseMotionProfile.BENCH_PRESS,
            StrengthExerciseMotionProfile.CHEST_FLY,
            StrengthExerciseMotionProfile.SKULL_CRUSHER,
            -> flatBench()
            StrengthExerciseMotionProfile.PULL_UP ->
                line(MotionPoint(0.27f, 0.11f), MotionPoint(0.73f, 0.11f), 4f)
            StrengthExerciseMotionProfile.LAT_PULLDOWN -> cableTower()
            StrengthExerciseMotionProfile.LEG_PRESS ->
                line(MotionPoint(0.72f, 0.25f), MotionPoint(0.82f, 0.70f), 7f)
            StrengthExerciseMotionProfile.LEG_EXTENSION,
            StrengthExerciseMotionProfile.LEG_CURL,
            -> line(MotionPoint(0.28f, 0.58f), MotionPoint(0.63f, 0.58f), 6f)
            StrengthExerciseMotionProfile.HIP_THRUST ->
                line(MotionPoint(0.18f, 0.56f), MotionPoint(0.43f, 0.56f), 6f)
            StrengthExerciseMotionProfile.DIP ->
                line(MotionPoint(0.30f, 0.42f), MotionPoint(0.70f, 0.42f), 4f)
            StrengthExerciseMotionProfile.BACK_EXTENSION ->
                line(MotionPoint(0.42f, 0.58f), MotionPoint(0.64f, 0.78f), 7f)
            StrengthExerciseMotionProfile.AB_ROLLOUT -> weight(pose.leftHand, 0.035f)
            else -> Unit
        }
    }
}

private fun DrawScope.drawStrengthHeldEquipment(
    pose: MotionPose,
    profile: StrengthExerciseMotionProfile,
    variant: StrengthExerciseAnimationVariant?,
    equipment: String,
    width: Float,
    height: Float,
    origin: Offset,
) {
    fun p(point: MotionPoint) = Offset(
        origin.x + width * point.x,
        origin.y + height * point.y,
    )
    fun line(a: MotionPoint, b: MotionPoint, stroke: Float, color: Color) {
        drawLine(color, p(a), p(b), strokeWidth = stroke, cap = StrokeCap.Round)
    }
    fun disc(point: MotionPoint, diameter: Float, color: Color) {
        val center = p(point)
        drawCircle(
            brush = Brush.linearGradient(
                colors = listOf(
                    Palette.textPrimary.copy(alpha = 0.88f),
                    color,
                    Palette.surfaceInset.copy(alpha = 0.96f),
                ),
                start = Offset(center.x - diameter / 2f, center.y - diameter / 2f),
                end = Offset(center.x + diameter / 2f, center.y + diameter / 2f),
            ),
            radius = diameter / 2f,
            center = center,
        )
        drawCircle(
            color = Palette.textPrimary.copy(alpha = 0.28f),
            radius = diameter / 2f,
            center = center,
            style = Stroke(width = 1f),
        )
    }
    fun dumbbell(point: MotionPoint) {
        val halfSpan = 0.022f
        val left = MotionPoint(point.x - halfSpan, point.y)
        val right = MotionPoint(point.x + halfSpan, point.y)
        line(left, right, maxOf(2f, width * 0.008f), Palette.textPrimary.copy(alpha = 0.9f))
        val diameter = maxOf(8f, width * 0.032f)
        disc(left, diameter, Palette.textTertiary)
        disc(right, diameter, Palette.textTertiary)
    }

    val steel = Palette.textSecondary.copy(alpha = 0.96f)
    when (equipment) {
        "barbell" -> {
            val anchors = when (variant) {
                StrengthExerciseAnimationVariant.BACK_SQUAT ->
                    pose.leftShoulder to pose.rightShoulder
                StrengthExerciseAnimationVariant.HIP_THRUST ->
                    MotionPoint(pose.hip.x - 0.08f, pose.hip.y) to
                        MotionPoint(pose.hip.x + 0.08f, pose.hip.y)
                else -> pose.leftHand to pose.rightHand
            }
            val centerX = (anchors.first.x + anchors.second.x) / 2f
            val centerY = (anchors.first.y + anchors.second.y) / 2f
            val halfSpan = maxOf(abs(anchors.second.x - anchors.first.x) / 2f + 0.12f, 0.19f)
            val left = MotionPoint(centerX - halfSpan, centerY)
            val right = MotionPoint(centerX + halfSpan, centerY)
            line(
                MotionPoint(left.x - 0.025f, centerY),
                MotionPoint(right.x + 0.025f, centerY),
                maxOf(2.5f, width * 0.009f),
                steel,
            )
            val diameter = maxOf(14f, width * 0.063f)
            disc(left, diameter, Palette.textTertiary)
            disc(right, diameter, Palette.textTertiary)
        }
        "dumbbell" -> when (variant) {
            StrengthExerciseAnimationVariant.GOBLET_SQUAT ->
                dumbbell(MotionPoint.mix(pose.leftHand, pose.rightHand, 0.5f))
            StrengthExerciseAnimationVariant.ONE_ARM_DUMBBELL_ROW -> dumbbell(pose.rightHand)
            else -> {
                dumbbell(pose.leftHand)
                dumbbell(pose.rightHand)
            }
        }
        "kettlebell" -> {
            val center = MotionPoint.mix(pose.leftHand, pose.rightHand, 0.5f)
            disc(
                MotionPoint(center.x, center.y + 0.025f),
                maxOf(13f, width * 0.056f),
                Palette.textTertiary,
            )
            val handleCenter = p(center)
            val handleRadius = width * 0.026f
            drawArc(
                color = steel,
                startAngle = 195f,
                sweepAngle = 150f,
                useCenter = false,
                topLeft = Offset(handleCenter.x - handleRadius, handleCenter.y - handleRadius),
                size = Size(handleRadius * 2f, handleRadius * 2f),
                style = Stroke(width = maxOf(2f, width * 0.008f), cap = StrokeCap.Round),
            )
        }
        "band" -> line(
            pose.leftHand,
            pose.rightHand,
            maxOf(2.5f, width * 0.009f),
            Palette.effortColor.copy(alpha = 0.92f),
        )
        "cable" -> {
            if (variant == StrengthExerciseAnimationVariant.CABLE_CROSSOVER) {
                line(
                    MotionPoint(0.13f, 0.20f),
                    pose.leftHand,
                    1.6f,
                    steel.copy(alpha = 0.72f),
                )
                line(
                    MotionPoint(0.87f, 0.20f),
                    pose.rightHand,
                    1.6f,
                    steel.copy(alpha = 0.72f),
                )
            } else {
                line(
                    MotionPoint(
                        0.87f,
                        if (variant == StrengthExerciseAnimationVariant.SEATED_CABLE_ROW) {
                            0.66f
                        } else {
                            0.18f
                        },
                    ),
                    pose.rightHand,
                    1.6f,
                    steel.copy(alpha = 0.72f),
                )
            }
        }
        else -> if (profile == StrengthExerciseMotionProfile.AB_ROLLOUT) {
            disc(
                MotionPoint.mix(pose.leftHand, pose.rightHand, 0.5f),
                maxOf(15f, width * 0.068f),
                Palette.textTertiary,
            )
        }
    }
}

private fun strengthKeyframes(
    profile: StrengthExerciseMotionProfile,
    variant: StrengthExerciseAnimationVariant?,
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

    when (variant) {
        StrengthExerciseAnimationVariant.FRONT_SQUAT -> {
            start.leftElbow = MotionPoint(0.34f, 0.31f)
            start.rightElbow = MotionPoint(0.66f, 0.31f)
            start.leftHand = MotionPoint(0.45f, 0.27f)
            start.rightHand = MotionPoint(0.55f, 0.27f)
            end.leftElbow = MotionPoint(0.34f, 0.42f)
            end.rightElbow = MotionPoint(0.66f, 0.42f)
            end.leftHand = MotionPoint(0.45f, 0.38f)
            end.rightHand = MotionPoint(0.55f, 0.38f)
        }
        StrengthExerciseAnimationVariant.GOBLET_SQUAT -> {
            start.leftElbow = MotionPoint(0.42f, 0.40f)
            start.rightElbow = MotionPoint(0.58f, 0.40f)
            start.leftHand = MotionPoint(0.47f, 0.34f)
            start.rightHand = MotionPoint(0.53f, 0.34f)
            end.leftElbow = MotionPoint(0.40f, 0.51f)
            end.rightElbow = MotionPoint(0.60f, 0.51f)
            end.leftHand = MotionPoint(0.47f, 0.45f)
            end.rightHand = MotionPoint(0.53f, 0.45f)
        }
        StrengthExerciseAnimationVariant.HACK_SQUAT -> {
            start = strengthSideStanding()
            start.leftShoulder = MotionPoint(0.55f, 0.29f)
            start.rightShoulder = MotionPoint(0.59f, 0.31f)
            start.hip = MotionPoint(0.52f, 0.55f)
            start.leftFoot = MotionPoint(0.64f, 0.89f)
            start.rightFoot = MotionPoint(0.70f, 0.89f)
            end = start.copyDeep()
            end.shiftUpper(0.12f)
            end.hip = MotionPoint(0.47f, 0.66f)
            end.leftKnee = MotionPoint(0.61f, 0.71f)
            end.rightKnee = MotionPoint(0.67f, 0.73f)
        }
        StrengthExerciseAnimationVariant.ROMANIAN_DEADLIFT -> {
            end.leftKnee = MotionPoint(0.49f, 0.73f)
            end.rightKnee = MotionPoint(0.55f, 0.74f)
            end.hip = MotionPoint(0.43f, 0.57f)
            end.head = MotionPoint(0.68f, 0.36f)
            end.neck = MotionPoint(0.61f, 0.41f)
            end.leftShoulder = MotionPoint(0.57f, 0.44f)
            end.rightShoulder = MotionPoint(0.61f, 0.46f)
        }
        StrengthExerciseAnimationVariant.GLUTE_BRIDGE -> {
            start.head = MotionPoint(0.22f, 0.66f)
            start.neck = MotionPoint(0.30f, 0.65f)
            start.leftShoulder = MotionPoint(0.35f, 0.64f)
            start.rightShoulder = MotionPoint(0.38f, 0.67f)
            start.hip = MotionPoint(0.57f, 0.72f)
            end = start.copyDeep()
            end.hip = MotionPoint(0.58f, 0.51f)
            end.leftKnee = MotionPoint(0.72f, 0.66f)
            end.rightKnee = MotionPoint(0.76f, 0.68f)
        }
        StrengthExerciseAnimationVariant.BULGARIAN_SPLIT_SQUAT -> {
            start = strengthSideStanding()
            start.leftKnee = MotionPoint(0.38f, 0.70f)
            start.leftFoot = MotionPoint(0.29f, 0.65f)
            start.rightKnee = MotionPoint(0.61f, 0.72f)
            start.rightFoot = MotionPoint(0.72f, 0.88f)
            end = start.copyDeep()
            end.shiftUpper(0.11f)
            end.hip = MotionPoint(0.50f, 0.65f)
            end.leftKnee = MotionPoint(0.40f, 0.75f)
            end.rightKnee = MotionPoint(0.64f, 0.70f)
        }
        StrengthExerciseAnimationVariant.WALKING_LUNGE -> {
            start = strengthSideStanding()
            start.leftFoot = MotionPoint(0.31f, 0.88f)
            start.rightFoot = MotionPoint(0.64f, 0.88f)
            end.shiftBody(dx = 0.06f)
        }
        StrengthExerciseAnimationVariant.SEATED_CALF_RAISE -> {
            start = strengthSeated()
            start.leftFoot = MotionPoint(0.67f, 0.85f)
            start.rightFoot = MotionPoint(0.73f, 0.86f)
            end = start.copyDeep()
            end.leftFoot.y -= 0.045f
            end.rightFoot.y -= 0.045f
            end.leftKnee.y -= 0.012f
            end.rightKnee.y -= 0.012f
        }
        StrengthExerciseAnimationVariant.INCLINE_BENCH_PRESS -> {
            start = start.rotated(MotionPoint(0.58f, 0.56f), -0.34f)
            end = end.rotated(MotionPoint(0.58f, 0.56f), -0.34f)
        }
        StrengthExerciseAnimationVariant.CABLE_CROSSOVER -> {
            start = strengthStanding()
            start.leftElbow = MotionPoint(0.29f, 0.34f)
            start.rightElbow = MotionPoint(0.71f, 0.34f)
            start.leftHand = MotionPoint(0.17f, 0.31f)
            start.rightHand = MotionPoint(0.83f, 0.31f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.39f, 0.44f)
            end.rightElbow = MotionPoint(0.61f, 0.44f)
            end.leftHand = MotionPoint(0.47f, 0.48f)
            end.rightHand = MotionPoint(0.53f, 0.48f)
        }
        StrengthExerciseAnimationVariant.MACHINE_CHEST_PRESS -> {
            start = strengthSeated()
            start.leftElbow = MotionPoint(0.49f, 0.46f)
            start.rightElbow = MotionPoint(0.53f, 0.49f)
            start.leftHand = MotionPoint(0.58f, 0.43f)
            start.rightHand = MotionPoint(0.61f, 0.46f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.60f, 0.43f)
            end.rightElbow = MotionPoint(0.63f, 0.46f)
            end.leftHand = MotionPoint(0.76f, 0.42f)
            end.rightHand = MotionPoint(0.79f, 0.45f)
        }
        StrengthExerciseAnimationVariant.ONE_ARM_DUMBBELL_ROW -> {
            start = strengthBentOver()
            start.leftHand = MotionPoint(0.78f, 0.68f)
            start.leftElbow = MotionPoint(0.66f, 0.57f)
            start.rightHand = MotionPoint(0.65f, 0.73f)
            end = start.copyDeep()
            end.rightElbow = MotionPoint(0.53f, 0.50f)
            end.rightHand = MotionPoint(0.57f, 0.56f)
        }
        StrengthExerciseAnimationVariant.SEATED_CABLE_ROW,
        StrengthExerciseAnimationVariant.RESISTANCE_BAND_ROW,
        -> {
            start = strengthSeated()
            start.leftElbow = MotionPoint(0.52f, 0.47f)
            start.rightElbow = MotionPoint(0.55f, 0.49f)
            start.leftHand = MotionPoint(0.72f, 0.53f)
            start.rightHand = MotionPoint(0.75f, 0.55f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.43f, 0.46f)
            end.rightElbow = MotionPoint(0.47f, 0.48f)
            end.leftHand = MotionPoint(0.50f, 0.51f)
            end.rightHand = MotionPoint(0.53f, 0.53f)
        }
        StrengthExerciseAnimationVariant.CHEST_SUPPORTED_ROW -> {
            start = strengthProne().rotated(MotionPoint(0.58f, 0.59f), -0.30f)
            start.leftHand = MotionPoint(0.61f, 0.71f)
            start.rightHand = MotionPoint(0.66f, 0.72f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.50f, 0.48f)
            end.rightElbow = MotionPoint(0.55f, 0.50f)
            end.leftHand = MotionPoint(0.55f, 0.57f)
            end.rightHand = MotionPoint(0.60f, 0.59f)
        }
        StrengthExerciseAnimationVariant.CHIN_UP -> {
            start.leftHand = MotionPoint(0.42f, 0.11f)
            start.rightHand = MotionPoint(0.58f, 0.11f)
            end.leftHand = start.leftHand.copy()
            end.rightHand = start.rightHand.copy()
            end.leftElbow = MotionPoint(0.38f, 0.29f)
            end.rightElbow = MotionPoint(0.62f, 0.29f)
        }
        StrengthExerciseAnimationVariant.FACE_PULL -> {
            start = strengthStanding()
            start.leftHand = MotionPoint(0.73f, 0.35f)
            start.rightHand = MotionPoint(0.77f, 0.37f)
            start.leftElbow = MotionPoint(0.57f, 0.39f)
            start.rightElbow = MotionPoint(0.61f, 0.41f)
            end = start.copyDeep()
            end.leftElbow = MotionPoint(0.37f, 0.30f)
            end.rightElbow = MotionPoint(0.63f, 0.30f)
            end.leftHand = MotionPoint(0.47f, 0.25f)
            end.rightHand = MotionPoint(0.53f, 0.25f)
        }
        StrengthExerciseAnimationVariant.PREACHER_CURL -> {
            start = strengthSeated()
            start.leftElbow = MotionPoint(0.54f, 0.51f)
            start.rightElbow = MotionPoint(0.58f, 0.53f)
            start.leftHand = MotionPoint(0.62f, 0.65f)
            start.rightHand = MotionPoint(0.66f, 0.66f)
            end = start.copyDeep()
            end.leftHand = MotionPoint(0.52f, 0.38f)
            end.rightHand = MotionPoint(0.56f, 0.39f)
        }
        StrengthExerciseAnimationVariant.SIDE_PLANK -> {
            start = strengthPlank()
            start.leftElbow = MotionPoint(0.37f, 0.68f)
            start.leftHand = MotionPoint(0.31f, 0.75f)
            start.rightShoulder = MotionPoint(0.43f, 0.47f)
            start.rightElbow = MotionPoint(0.46f, 0.30f)
            start.rightHand = MotionPoint(0.48f, 0.17f)
            end = start.copyDeep()
            end.hip.y -= 0.035f
            end.head.y -= 0.018f
        }
        else -> Unit
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

private fun MotionPose.rotated(anchor: MotionPoint, radians: Float): MotionPose {
    fun point(value: MotionPoint): MotionPoint {
        val dx = value.x - anchor.x
        val dy = value.y - anchor.y
        return MotionPoint(
            x = anchor.x + dx * cos(radians) - dy * sin(radians),
            y = anchor.y + dx * sin(radians) + dy * cos(radians),
        )
    }
    return MotionPose(
        point(head),
        point(neck),
        point(leftShoulder),
        point(rightShoulder),
        point(leftElbow),
        point(rightElbow),
        point(leftHand),
        point(rightHand),
        point(hip),
        point(leftKnee),
        point(rightKnee),
        point(leftFoot),
        point(rightFoot),
    )
}

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
