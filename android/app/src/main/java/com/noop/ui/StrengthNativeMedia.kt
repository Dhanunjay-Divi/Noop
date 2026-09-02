package com.noop.ui

import android.content.Context
import android.graphics.drawable.Animatable
import android.os.Build
import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.decode.DecodeResult
import coil.decode.Decoder
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.decode.SvgDecoder
import coil.fetch.SourceResult
import coil.request.ImageRequest
import coil.request.Options
import com.noop.BuildConfig
import com.noop.R
import com.noop.data.StrengthExerciseRow
import com.noop.data.StrengthMuscleStatus
import java.io.IOException
import kotlinx.coroutines.delay
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import org.json.JSONObject
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val STRENGTH_DEMO_MEDIA_HOST = "https://static.exercisedb.dev/media"
internal const val STRENGTH_MINIMUM_LICENSED_PIXELS = 360
internal const val STRENGTH_MAXIMUM_DOWNLOAD_BYTES = 16L * 1_024 * 1_024
private const val STRENGTH_MINIMUM_PIXELS_PARAMETER = "noop-strength-minimum-pixels"

internal object StrengthExerciseMediaPolicy {
    fun acceptsContentLength(contentLength: Long): Boolean =
        contentLength < 0 || contentLength <= STRENGTH_MAXIMUM_DOWNLOAD_BYTES

    fun acceptsGifHeader(header: ByteArray, minimumPixels: Int): Boolean {
        if (minimumPixels <= 0 || header.size < 10) return false
        val signature = header.copyOfRange(0, 6).decodeToString()
        if (signature != "GIF87a" && signature != "GIF89a") return false
        val width = header[6].toInt().and(0xff) or
            (header[7].toInt().and(0xff) shl 8)
        val height = header[8].toInt().and(0xff) or
            (header[9].toInt().and(0xff) shl 8)
        return width >= minimumPixels && height >= minimumPixels
    }
}

private data class StrengthExerciseMediaSource(
    val model: String,
    val minimumPixels: Int,
)

private class StrengthMediaDownloadCapInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): okhttp3.Response {
        val response = chain.proceed(chain.request())
        val body = response.body ?: return response
        if (!StrengthExerciseMediaPolicy.acceptsContentLength(body.contentLength())) {
            response.close()
            throw IOException("Strength exercise media exceeds the download limit")
        }
        return response.newBuilder()
            .body(StrengthCappedResponseBody(body, STRENGTH_MAXIMUM_DOWNLOAD_BYTES))
            .build()
    }
}

internal class StrengthCappedResponseBody(
    private val delegate: ResponseBody,
    private val maximumBytes: Long,
) : ResponseBody() {
    init {
        require(maximumBytes >= 0)
    }

    private val cappedSource: BufferedSource by lazy(LazyThreadSafetyMode.NONE) {
        object : ForwardingSource(delegate.source()) {
            private var consumedBytes = 0L

            override fun read(sink: Buffer, byteCount: Long): Long {
                if (byteCount == 0L) return 0L
                val remaining = maximumBytes - consumedBytes
                if (remaining < 0) {
                    throw IOException("Strength exercise media exceeds the download limit")
                }
                val read = super.read(sink, minOf(byteCount, remaining + 1))
                if (read > 0) {
                    consumedBytes += read
                    if (consumedBytes > maximumBytes) {
                        throw IOException("Strength exercise media exceeds the download limit")
                    }
                }
                return read
            }
        }.buffer()
    }

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun source(): BufferedSource = cappedSource
}

private class StrengthMediaValidationDecoderFactory : Decoder.Factory {
    override fun create(
        result: SourceResult,
        options: Options,
        imageLoader: ImageLoader,
    ): Decoder? {
        val minimumPixels =
            options.parameters.value<Int>(STRENGTH_MINIMUM_PIXELS_PARAMETER) ?: return null
        val header = runCatching {
            result.source.source().peek().use { it.readByteArray(10) }
        }.getOrNull()
        return if (
            header != null &&
            StrengthExerciseMediaPolicy.acceptsGifHeader(header, minimumPixels)
        ) {
            null
        } else {
            RejectingStrengthMediaDecoder()
        }
    }
}

private class RejectingStrengthMediaDecoder : Decoder {
    override suspend fun decode(): DecodeResult {
        throw IOException("Strength exercise media is not an approved native-resolution GIF")
    }
}

internal data class StrengthExerciseFormGuide(
    val setup: String,
    val movement: String,
    val breathing: String,
    val tempo: String,
    val safety: String,
)

private object StrengthNativeAssets {
    private var mediaIds: Map<String, String>? = null
    private var formGuides: Map<String, StrengthExerciseFormGuide>? = null
    private var bodyMapTemplate: String? = null
    private var imageLoader: ImageLoader? = null
    private var thumbnailImageLoader: ImageLoader? = null

    @Synchronized
    fun mediaId(context: Context, exerciseId: String): String? {
        val mapping = mediaIds ?: context.assets
            .open("strength-motion/exercise-media.json")
            .bufferedReader()
            .use { reader ->
                val json = JSONObject(reader.readText())
                buildMap {
                    json.keys().forEach { key -> put(key, json.getString(key)) }
                }
            }
            .also { mediaIds = it }
        return mapping[exerciseId]
    }

    fun mediaSource(context: Context, mediaId: String): StrengthExerciseMediaSource? {
        val bundled = "strength-motion/media/$mediaId.gif"
        val hasBundled = runCatching {
            context.assets.open(bundled).use { it.read() }
        }.isSuccess
        if (hasBundled) {
            return StrengthExerciseMediaSource(
                model = "file:///android_asset/$bundled",
                minimumPixels = STRENGTH_MINIMUM_LICENSED_PIXELS,
            )
        }

        val template = BuildConfig.STRENGTH_MEDIA_URL_TEMPLATE.trim()
        if (template.isNotEmpty() && !template.contains("\$(")) {
            val rendered = if (template.contains("{id}")) {
                template.replace("{id}", mediaId)
            } else {
                "${template.trimEnd('/')}/$mediaId.gif"
            }
            if (rendered.startsWith("https://")) {
                return StrengthExerciseMediaSource(
                    model = rendered,
                    minimumPixels = STRENGTH_MINIMUM_LICENSED_PIXELS,
                )
            }
        }
        return if (BuildConfig.DEBUG && BuildConfig.ALLOW_DEMO_STRENGTH_MEDIA) {
            StrengthExerciseMediaSource(
                model = "$STRENGTH_DEMO_MEDIA_HOST/$mediaId.gif",
                minimumPixels = 180,
            )
        } else {
            null
        }
    }

    @Synchronized
    fun formGuide(context: Context, exerciseId: String): StrengthExerciseFormGuide? {
        val guides = formGuides ?: context.assets
            .open("strength-motion/exercise-guidance.json")
            .bufferedReader()
            .use { reader ->
                val json = JSONObject(reader.readText())
                buildMap {
                    json.keys().forEach { key ->
                        val guide = json.getJSONObject(key)
                        put(
                            key,
                            StrengthExerciseFormGuide(
                                setup = guide.getString("setup"),
                                movement = guide.getString("movement"),
                                breathing = guide.getString("breathing"),
                                tempo = guide.getString("tempo"),
                                safety = guide.getString("safety"),
                            ),
                        )
                    }
                }
            }
            .also { formGuides = it }
        return guides[exerciseId]
    }

    @Synchronized
    fun bodyMapTemplate(context: Context): String =
        bodyMapTemplate ?: context.assets
            .open("strength-motion/body-map-native.svg")
            .bufferedReader()
            .use { it.readText() }
            .also { bodyMapTemplate = it }

    @Synchronized
    fun imageLoader(context: Context): ImageLoader =
        imageLoader ?: ImageLoader.Builder(context.applicationContext)
            .okHttpClient {
                OkHttpClient.Builder()
                    .addNetworkInterceptor(StrengthMediaDownloadCapInterceptor())
                    .build()
            }
            .components {
                add(SvgDecoder.Factory())
                add(StrengthMediaValidationDecoderFactory())
                if (Build.VERSION.SDK_INT >= 28) {
                    add(ImageDecoderDecoder.Factory())
                } else {
                    add(GifDecoder.Factory())
                }
            }
            .crossfade(false)
            .build()
            .also { imageLoader = it }

    @Synchronized
    fun thumbnailImageLoader(context: Context): ImageLoader =
        thumbnailImageLoader ?: ImageLoader.Builder(context.applicationContext)
            .crossfade(false)
            .build()
            .also { thumbnailImageLoader = it }
}

@Composable
internal fun StrengthNativeExerciseMedia(
    exercise: StrengthExerciseRow,
    reduceMotion: Boolean,
    minimized: Boolean,
    showsTechniqueButton: Boolean,
    showsSizeButton: Boolean,
    onToggleSize: () -> Unit,
    fallback: @Composable () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val imageLoader = remember(context.applicationContext) {
        StrengthNativeAssets.imageLoader(context)
    }
    val mediaId = remember(exercise.id) {
        StrengthNativeAssets.mediaId(context, exercise.id)
    }
    val mediaSource = remember(mediaId, context.applicationContext) {
        mediaId?.let { StrengthNativeAssets.mediaSource(context, it) }
    }
    if (mediaId == null || mediaSource == null) {
        fallback()
        return
    }

    var paused by remember(exercise.id) { mutableStateOf(reduceMotion) }
    var loading by remember(exercise.id) { mutableStateOf(true) }
    var failed by remember(exercise.id) { mutableStateOf(false) }
    var animation by remember(exercise.id) { mutableStateOf<Animatable?>(null) }
    var showInfo by remember(exercise.id) { mutableStateOf(false) }
    var requestVersion by remember(exercise.id) { mutableStateOf(0) }
    val formGuide = remember(exercise.id) {
        StrengthNativeAssets.formGuide(context, exercise.id)
    }
    val shape = RoundedCornerShape(8.dp)

    LaunchedEffect(paused, reduceMotion, animation) {
        if (paused || reduceMotion) animation?.stop() else animation?.start()
    }
    LaunchedEffect(exercise.id, requestVersion, loading) {
        if (!loading) return@LaunchedEffect
        delay(6_000)
        if (loading) {
            animation?.stop()
            loading = false
            failed = true
        }
    }
    DisposableEffect(animation) {
        onDispose { animation?.stop() }
    }

    BoxWithConstraints(
        modifier = modifier
            .clip(shape)
            .background(Palette.surfaceInset, shape)
            .border(1.dp, Palette.hairline, shape),
    ) {
        val controlRailWidth = if (showsSizeButton || showsTechniqueButton) 46.dp else 40.dp
        val mediaSize = minOf(
            maxHeight - 12.dp,
            maxWidth - (controlRailWidth * 2) - 16.dp,
        ).coerceAtLeast(0.dp)
        val mediaPixels = with(LocalDensity.current) {
            mediaSize.roundToPx().coerceAtLeast(1)
        }
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .size(mediaSize)
                .clip(RoundedCornerShape(6.dp))
                .background(Color.White)
                .border(
                    1.dp,
                    Color.Black.copy(alpha = 0.08f),
                    RoundedCornerShape(6.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (!failed) {
                AsyncImage(
                    model = ImageRequest.Builder(context)
                        .data(mediaSource.model)
                        .memoryCacheKey("strength-exercise-v2-$mediaId")
                        .diskCacheKey("strength-exercise-v2-$mediaId")
                        .setParameter("request-version", requestVersion)
                        .setParameter(
                            STRENGTH_MINIMUM_PIXELS_PARAMETER,
                            mediaSource.minimumPixels,
                        )
                        .size(mediaPixels)
                        .build(),
                    imageLoader = imageLoader,
                    contentDescription = stringResource(R.string.strength_exercise_guide),
                    contentScale = ContentScale.Fit,
                    filterQuality = FilterQuality.High,
                    modifier = Modifier
                        .fillMaxSize()
                        .clickable(
                            enabled = !reduceMotion,
                            role = Role.Button,
                        ) {
                            paused = !paused
                            if (paused) animation?.stop() else animation?.start()
                        },
                    onLoading = {
                        loading = true
                        failed = false
                    },
                    onSuccess = {
                        loading = false
                        failed = false
                        animation = it.result.drawable as? Animatable
                        if (paused || reduceMotion) animation?.stop() else animation?.start()
                    },
                    onError = {
                        loading = false
                        failed = true
                        Log.e(
                            "StrengthNativeMedia",
                            "Exercise media decode failed",
                            it.result.throwable,
                        )
                    },
                )
            }
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(28.dp),
                    color = Color(0xFFED2435),
                    trackColor = Color(0xFFE3E4E7),
                    strokeWidth = 2.dp,
                )
            }
            if (failed) {
                StrengthMediaControl(
                    imageVector = Icons.Filled.Refresh,
                    description = stringResource(R.string.today_weather_retry),
                    alignment = Alignment.Center,
                    visualSize = 40.dp,
                    onClick = {
                        requestVersion += 1
                        failed = false
                        loading = true
                    },
                )
            }
        }
        if (!loading && !failed) {
            StrengthMediaControl(
                imageVector = if (paused || reduceMotion) {
                    Icons.Filled.PlayArrow
                } else {
                    Icons.Filled.Pause
                },
                description = stringResource(
                    if (paused || reduceMotion) {
                        R.string.strength_play_guide
                    } else {
                        R.string.strength_pause_guide
                    },
                ),
                alignment = Alignment.BottomEnd,
                onClick = {
                    if (reduceMotion) return@StrengthMediaControl
                    paused = !paused
                    if (paused) animation?.stop() else animation?.start()
                },
            )
        }
        if (showsSizeButton) {
            StrengthMediaControl(
                imageVector = if (minimized) {
                    Icons.Filled.Fullscreen
                } else {
                    Icons.Filled.FullscreenExit
                },
                description = stringResource(
                    if (minimized) {
                        R.string.strength_expand_guide
                    } else {
                        R.string.strength_minimize_guide
                    },
                ),
                alignment = Alignment.BottomStart,
                onClick = onToggleSize,
            )
        }
        if (showsTechniqueButton) {
            StrengthMediaControl(
                imageVector = Icons.Filled.Info,
                description = stringResource(R.string.strength_form_info),
                alignment = Alignment.TopEnd,
                onClick = { showInfo = true },
            )
        }
    }

    if (showInfo) {
        StrengthExerciseTechniqueSheet(
            exercise = exercise,
            guide = formGuide,
            onDismissRequest = { showInfo = false },
        )
    }
}

@Composable
internal fun StrengthExerciseThumbnail(
    exercise: StrengthExerciseRow,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(6.dp)
    val tint = if (exercise.isCustom) Palette.accent else Palette.effortColor
    Box(
        modifier = modifier
            .background(tint.copy(alpha = 0.09f), shape)
            .border(1.dp, Palette.hairline, shape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.FitnessCenter,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun BoxScope.StrengthMediaControl(
    imageVector: ImageVector,
    description: String,
    alignment: Alignment,
    visualSize: androidx.compose.ui.unit.Dp = 34.dp,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .align(alignment)
            .padding(8.dp)
            .size(visualSize)
            .clip(CircleShape)
            .background(Palette.surfaceRaised)
            .border(1.dp, Palette.hairline, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(17.dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun StrengthExerciseTechniqueSheet(
    exercise: StrengthExerciseRow,
    guide: StrengthExerciseFormGuide?,
    onDismissRequest: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismissRequest,
        containerColor = Palette.surfaceOverlay,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 720.dp)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp)
                .padding(bottom = 28.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        strengthExerciseName(exercise),
                        style = NoopType.title2,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(
                            R.string.strength_descriptor_pair,
                            strengthDescriptor(exercise.primaryMuscle),
                            strengthDescriptor(exercise.equipment),
                        ),
                        style = NoopType.footnote,
                        color = Palette.textSecondary,
                    )
                }
                IconButton(onClick = onDismissRequest) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = stringResource(R.string.strength_done),
                        tint = Palette.textSecondary,
                    )
                }
            }
            Text(
                stringResource(R.string.strength_form_info),
                style = NoopType.headline,
                color = Palette.effortColor,
                modifier = Modifier.padding(top = 20.dp, bottom = 4.dp),
            )
            StrengthExerciseTechniqueContent(exercise = exercise, guide = guide)
        }
    }
}

@Composable
internal fun StrengthExerciseTechnique(
    exercise: StrengthExerciseRow,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val guide = remember(exercise.id) {
        StrengthNativeAssets.formGuide(context, exercise.id)
    }
    Column(modifier = modifier) {
        StrengthExerciseTechniqueContent(exercise = exercise, guide = guide)
    }
}

@Composable
private fun StrengthExerciseTechniqueContent(
    exercise: StrengthExerciseRow,
    guide: StrengthExerciseFormGuide?,
) {
    val sections = listOf(
        stringResource(R.string.strength_form_setup) to (
            guide?.setup ?: stringResource(
                R.string.strength_form_setup_body,
                strengthDescriptor(exercise.equipment),
            )
        ),
        stringResource(R.string.strength_form_movement) to (
            guide?.movement ?: stringResource(R.string.strength_form_movement_body)
        ),
        stringResource(R.string.strength_form_breathing) to (
            guide?.breathing ?: stringResource(R.string.strength_form_breathing_body)
        ),
        stringResource(R.string.strength_form_tempo) to (
            guide?.tempo ?: stringResource(R.string.strength_form_tempo_body)
        ),
        stringResource(R.string.strength_form_safety) to (
            guide?.safety ?: stringResource(R.string.strength_form_safety_body)
        ),
    )

    Column {
        sections.forEachIndexed { index, section ->
            FormGuideSection(
                index = index + 1,
                title = section.first,
                body = section.second,
            )
            if (index < sections.lastIndex) {
                HorizontalDivider(color = Palette.hairline)
            }
        }
    }
}

@Composable
private fun FormGuideSection(index: Int, title: String, body: String) {
    Row(
        modifier = Modifier.padding(vertical = 14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(Palette.effortColor.copy(alpha = 0.14f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                index.toString().padStart(2, '0'),
                style = NoopType.caption,
                color = Palette.effortColor,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(body, style = NoopType.footnote, color = Palette.textSecondary)
        }
    }
}

@Composable
internal fun StrengthNativeBodyMap(
    statuses: List<StrengthMuscleStatus>,
    mode: StrengthBodyMapMode,
    selectedMuscles: Set<String>,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val template = remember(context.applicationContext) {
        StrengthNativeAssets.bodyMapTemplate(context)
    }
    val scores = remember(statuses, mode) {
        statuses.associate { status ->
            status.muscle to when (mode) {
                StrengthBodyMapMode.LOAD -> status.loadScore
                StrengthBodyMapMode.RECOVERY -> status.residualLoadScore
            }.coerceIn(0.0, 1.0)
        }
    }
    val svg = remember(template, scores, selectedMuscles) {
        strengthBodyMapSvg(template, scores, selectedMuscles)
    }
    val imageLoader = remember(context.applicationContext) {
        StrengthNativeAssets.imageLoader(context)
    }
    val model = remember(svg) {
        ImageRequest.Builder(context)
            .data(svg.encodeToByteArray())
            .memoryCacheKey("strength-body-map-${svg.hashCode()}")
            .build()
    }

    AsyncImage(
        model = model,
        imageLoader = imageLoader,
        contentDescription = stringResource(R.string.strength_train_by_muscle),
        contentScale = ContentScale.Fit,
        onError = {
            Log.e("StrengthNativeMedia", "Body map SVG decode failed", it.result.throwable)
        },
        modifier = modifier
            .fillMaxWidth()
            .testTag("noop.strength.body-map")
            .pointerInput(onSelect) {
                detectTapGestures { offset ->
                    strengthBodyMapHit(offset, size.width.toFloat(), size.height.toFloat())
                        ?.let(onSelect)
                }
            },
    )
}

private fun strengthBodyMapSvg(
    template: String,
    scores: Map<String, Double>,
    selectedMuscles: Set<String>,
): String {
    var svg = template
    for (muscle in bodyMapMuscles) {
        val color = if (muscle in selectedMuscles) {
            "#ff3445"
        } else {
            bodyMapColor(scores[muscle] ?: 0.0)
        }
        svg = svg.replace("__NOOP_${muscle.uppercase()}__", color)
    }
    return svg
}

private fun bodyMapColor(score: Double): String {
    val intensity = sqrt(score.coerceIn(0.0, 1.0))
    val red = (52 + (235 - 52) * intensity).roundToInt()
    val green = (55 + (31 - 55) * intensity).roundToInt()
    val blue = (63 + (46 - 63) * intensity).roundToInt()
    return "#%02x%02x%02x".format(red, green, blue)
}

private val bodyMapMuscles = setOf(
    "chest",
    "back",
    "shoulders",
    "biceps",
    "triceps",
    "forearms",
    "core",
    "quadriceps",
    "hamstrings",
    "glutes",
    "calves",
)

private data class BodyMapHit(
    val side: Int,
    val muscle: String,
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
)

private val bodyMapHits = listOf(
    BodyMapHit(0, "shoulders", 0.35f, 0.19f, 0.22f, 0.12f),
    BodyMapHit(0, "shoulders", 0.65f, 0.19f, 0.22f, 0.12f),
    BodyMapHit(0, "chest", 0.50f, 0.28f, 0.34f, 0.15f),
    BodyMapHit(0, "biceps", 0.25f, 0.35f, 0.18f, 0.18f),
    BodyMapHit(0, "biceps", 0.75f, 0.35f, 0.18f, 0.18f),
    BodyMapHit(0, "forearms", 0.19f, 0.50f, 0.16f, 0.20f),
    BodyMapHit(0, "forearms", 0.81f, 0.50f, 0.16f, 0.20f),
    BodyMapHit(0, "core", 0.50f, 0.45f, 0.30f, 0.26f),
    BodyMapHit(0, "quadriceps", 0.50f, 0.68f, 0.34f, 0.24f),
    BodyMapHit(0, "calves", 0.50f, 0.88f, 0.30f, 0.20f),
    BodyMapHit(1, "shoulders", 0.50f, 0.19f, 0.44f, 0.13f),
    BodyMapHit(1, "back", 0.50f, 0.34f, 0.42f, 0.28f),
    BodyMapHit(1, "triceps", 0.25f, 0.35f, 0.18f, 0.18f),
    BodyMapHit(1, "triceps", 0.75f, 0.35f, 0.18f, 0.18f),
    BodyMapHit(1, "forearms", 0.19f, 0.50f, 0.16f, 0.20f),
    BodyMapHit(1, "forearms", 0.81f, 0.50f, 0.16f, 0.20f),
    BodyMapHit(1, "glutes", 0.50f, 0.56f, 0.34f, 0.14f),
    BodyMapHit(1, "hamstrings", 0.50f, 0.70f, 0.34f, 0.22f),
    BodyMapHit(1, "calves", 0.50f, 0.88f, 0.30f, 0.20f),
)

private fun strengthBodyMapHit(offset: Offset, width: Float, height: Float): String? {
    if (width <= 0f || height <= 0f) return null
    val side = if (offset.x < width / 2f) 0 else 1
    val localX = (offset.x - side * width / 2f) / (width / 2f)
    val localY = offset.y / height
    return bodyMapHits.firstOrNull { hit ->
        hit.side == side &&
            localX in (hit.x - hit.width / 2f)..(hit.x + hit.width / 2f) &&
            localY in (hit.y - hit.height / 2f)..(hit.y + hit.height / 2f)
    }?.muscle
}
