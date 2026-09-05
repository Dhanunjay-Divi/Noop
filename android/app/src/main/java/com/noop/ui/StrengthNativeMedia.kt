package com.noop.ui

import android.content.Context
import android.graphics.SurfaceTexture
import android.graphics.drawable.Animatable
import android.media.MediaPlayer
import android.media.MediaMetadataRetriever
import android.os.Build
import android.view.Surface
import android.view.TextureView
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
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
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
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.Interceptor
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.buffer
import org.json.JSONObject
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val STRENGTH_DEMO_MEDIA_HOST =
    "https://raw.githubusercontent.com/omercotkd/exercises-gifs/" +
        "ebf642cd90fdf73a6c73e7127e93b607b12c229e/assets"
internal const val STRENGTH_MINIMUM_LICENSED_PIXELS = 360
internal const val STRENGTH_MINIMUM_VIDEO_PIXELS = 720
internal const val STRENGTH_MAXIMUM_DOWNLOAD_BYTES = 16L * 1_024 * 1_024
internal const val STRENGTH_MINIMUM_FRAME_DELAY_HUNDREDTHS = 5
internal const val STRENGTH_MAXIMUM_FRAME_DELAY_HUNDREDTHS = 40
internal const val STRENGTH_GIF_FRAME_DURATION_PERCENT = 125
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

    fun mediaUrl(template: String, mediaId: String, extension: String): String? {
        val cleanTemplate = template.trim()
        if (
            cleanTemplate.isEmpty() ||
            cleanTemplate.contains("\$(") ||
            !mediaId.matches(Regex("[A-Za-z0-9]+")) ||
            !extension.matches(Regex("[A-Za-z0-9]+"))
        ) {
            return null
        }
        val rendered = if (cleanTemplate.contains("{id}")) {
            cleanTemplate
                .replace("{id}", mediaId)
                .replace("{ext}", extension)
        } else {
            "${cleanTemplate.trimEnd('/')}/$mediaId.$extension"
        }
        return rendered.takeIf { it.startsWith("https://") }
    }

    /**
     * ExerciseDB previews contain one-second endpoint frames that can look stalled. Slow the
     * movement frames slightly while capping those endpoint holds, preserving source frame order.
     */
    fun normalizePlaybackDelays(
        data: ByteArray,
        maximumDelayHundredths: Int = STRENGTH_MAXIMUM_FRAME_DELAY_HUNDREDTHS,
    ): ByteArray {
        if (maximumDelayHundredths !in 1..0xffff || data.size < 14) return data
        val signature = data.copyOfRange(0, 6).decodeToString()
        if (signature != "GIF87a" && signature != "GIF89a") return data

        val normalizedDelays = mutableListOf<Pair<Int, Int>>()
        val logicalScreenPacked = data[10].toInt().and(0xff)
        val globalColorTableBytes = if (logicalScreenPacked.and(0x80) != 0) {
            3 * (1 shl (logicalScreenPacked.and(0x07) + 1))
        } else {
            0
        }
        var offset = 13 + globalColorTableBytes
        if (offset >= data.size) return data

        while (offset < data.size) {
            when (data[offset].toInt().and(0xff)) {
                0x3b -> break
                0x21 -> {
                    if (offset + 2 >= data.size) return data
                    val label = data[offset + 1].toInt().and(0xff)
                    val blockStart = offset + 2
                    if (label == 0xf9) {
                        val blockSize = data[blockStart].toInt().and(0xff)
                        val terminator = blockStart + blockSize + 1
                        if (
                            blockSize != 4 ||
                            terminator >= data.size ||
                            data[terminator].toInt().and(0xff) != 0
                        ) {
                            return data
                        }
                        val delayOffset = blockStart + 2
                        val delay = data[delayOffset].toInt().and(0xff) or
                            (data[delayOffset + 1].toInt().and(0xff) shl 8)
                        val normalizedDelay = (
                            (delay * STRENGTH_GIF_FRAME_DURATION_PERCENT + 50) / 100
                            )
                            .coerceIn(
                                STRENGTH_MINIMUM_FRAME_DELAY_HUNDREDTHS,
                                maximumDelayHundredths,
                            )
                        if (delay != normalizedDelay) {
                            normalizedDelays += delayOffset to normalizedDelay
                        }
                        offset = terminator + 1
                    } else {
                        offset = skipGifSubBlocks(data, blockStart) ?: return data
                    }
                }
                0x2c -> {
                    if (offset + 9 >= data.size) return data
                    val imagePacked = data[offset + 9].toInt().and(0xff)
                    val localColorTableBytes = if (imagePacked.and(0x80) != 0) {
                        3 * (1 shl (imagePacked.and(0x07) + 1))
                    } else {
                        0
                    }
                    val imageDataStart = offset + 10 + localColorTableBytes
                    if (imageDataStart >= data.size) return data
                    offset = skipGifSubBlocks(data, imageDataStart + 1) ?: return data
                }
                else -> return data
            }
        }

        if (normalizedDelays.isEmpty()) return data
        return data.copyOf().also { normalized ->
            normalizedDelays.forEach { (delayOffset, delay) ->
                normalized[delayOffset] = delay.and(0xff).toByte()
                normalized[delayOffset + 1] =
                    delay.shr(8).and(0xff).toByte()
            }
        }
    }

    private fun skipGifSubBlocks(data: ByteArray, start: Int): Int? {
        var offset = start
        while (offset < data.size) {
            val blockSize = data[offset].toInt().and(0xff)
            offset += 1
            if (blockSize == 0) return offset
            if (offset + blockSize > data.size) return null
            offset += blockSize
        }
        return null
    }
}

private enum class StrengthExerciseMediaKind {
    VIDEO,
    GIF,
}

internal data class StrengthExerciseMediaDescriptor(
    val gif: String?,
    val video: String?,
)

private data class StrengthExerciseMediaSource(
    val mediaId: String,
    val kind: StrengthExerciseMediaKind,
    val model: String,
    val assetPath: String? = null,
    val minimumPixels: Int,
) {
    val cacheKey: String = "${kind.name.lowercase()}-$mediaId"
}

private class StrengthMediaDownloadCapInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): okhttp3.Response {
        val response = chain.proceed(chain.request())
        val body = response.body ?: return response
        if (!StrengthExerciseMediaPolicy.acceptsContentLength(body.contentLength())) {
            response.close()
            throw IOException("Strength exercise media exceeds the download limit")
        }
        val boundedBody = StrengthCappedResponseBody(
            body,
            STRENGTH_MAXIMUM_DOWNLOAD_BYTES,
        )
        val sourceBytes = try {
            boundedBody.source().use { it.readByteArray() }
        } catch (error: IOException) {
            response.close()
            throw error
        }
        val playbackBytes = StrengthExerciseMediaPolicy.normalizePlaybackDelays(sourceBytes)
        return response.newBuilder()
            .body(playbackBytes.toResponseBody(body.contentType()))
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
    private var mediaDescriptors: Map<String, StrengthExerciseMediaDescriptor>? = null
    private var formGuides: Map<String, StrengthExerciseFormGuide>? = null
    private var bodyMapTemplate: String? = null
    private var imageLoader: ImageLoader? = null
    private var thumbnailImageLoader: ImageLoader? = null

    @Synchronized
    fun mediaDescriptor(
        context: Context,
        exerciseId: String,
    ): StrengthExerciseMediaDescriptor? {
        val mapping = mediaDescriptors ?: context.assets
            .open("strength-motion/exercise-media.json")
            .bufferedReader()
            .use { reader ->
                val json = JSONObject(reader.readText())
                buildMap {
                    json.keys().forEach { key ->
                        val descriptor = json.getJSONObject(key)
                        put(
                            key,
                            StrengthExerciseMediaDescriptor(
                                gif = descriptor.optString("gif")
                                    .takeIf(String::isNotBlank),
                                video = descriptor.optString("video")
                                    .takeIf(String::isNotBlank),
                            ),
                        )
                    }
                }
            }
            .also { mediaDescriptors = it }
        return mapping[exerciseId]
    }

    fun mediaSources(
        context: Context,
        descriptor: StrengthExerciseMediaDescriptor,
    ): List<StrengthExerciseMediaSource> {
        val sources = mutableListOf<StrengthExerciseMediaSource>()
        descriptor.video?.let { videoId ->
            appendBundled(
                context = context,
                mediaId = videoId,
                kind = StrengthExerciseMediaKind.VIDEO,
                extension = "mp4",
                minimumPixels = STRENGTH_MINIMUM_VIDEO_PIXELS,
                to = sources,
            )
            appendConfigured(
                template = BuildConfig.STRENGTH_VIDEO_URL_TEMPLATE,
                mediaId = videoId,
                kind = StrengthExerciseMediaKind.VIDEO,
                extension = "mp4",
                minimumPixels = STRENGTH_MINIMUM_VIDEO_PIXELS,
                to = sources,
            )
        }

        descriptor.gif?.let { gifId ->
            appendBundled(
                context = context,
                mediaId = gifId,
                kind = StrengthExerciseMediaKind.GIF,
                extension = "gif",
                minimumPixels = STRENGTH_MINIMUM_LICENSED_PIXELS,
                to = sources,
            )
            appendConfigured(
                template = BuildConfig.STRENGTH_MEDIA_URL_TEMPLATE,
                mediaId = gifId,
                kind = StrengthExerciseMediaKind.GIF,
                extension = "gif",
                minimumPixels = STRENGTH_MINIMUM_LICENSED_PIXELS,
                to = sources,
            )
            if (BuildConfig.DEBUG && BuildConfig.ALLOW_DEMO_STRENGTH_MEDIA) {
                sources += StrengthExerciseMediaSource(
                    mediaId = gifId,
                    kind = StrengthExerciseMediaKind.GIF,
                    model = "$STRENGTH_DEMO_MEDIA_HOST/$gifId.gif",
                    minimumPixels = 180,
                )
            }
        }
        return sources.distinctBy(StrengthExerciseMediaSource::model)
    }

    private fun appendBundled(
        context: Context,
        mediaId: String,
        kind: StrengthExerciseMediaKind,
        extension: String,
        minimumPixels: Int,
        to: MutableList<StrengthExerciseMediaSource>,
    ) {
        val assetPath = "strength-motion/media/$mediaId.$extension"
        val exists = runCatching {
            context.assets.open(assetPath).use { it.read() }
        }.isSuccess
        if (exists) {
            to += StrengthExerciseMediaSource(
                mediaId = mediaId,
                kind = kind,
                model = "file:///android_asset/$assetPath",
                assetPath = assetPath,
                minimumPixels = minimumPixels,
            )
        }
    }

    private fun appendConfigured(
        template: String,
        mediaId: String,
        kind: StrengthExerciseMediaKind,
        extension: String,
        minimumPixels: Int,
        to: MutableList<StrengthExerciseMediaSource>,
    ) {
        val url = StrengthExerciseMediaPolicy.mediaUrl(
            template = template,
            mediaId = mediaId,
            extension = extension,
        ) ?: return
        to += StrengthExerciseMediaSource(
            mediaId = mediaId,
            kind = kind,
            model = url,
            minimumPixels = minimumPixels,
        )
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

private data class StrengthResolvedVideo(
    val assetPath: String? = null,
    val file: File? = null,
)

private object StrengthVideoCache {
    private val client = OkHttpClient.Builder().build()

    suspend fun resolve(
        context: Context,
        source: StrengthExerciseMediaSource,
    ): StrengthResolvedVideo? = withContext(Dispatchers.IO) {
        source.assetPath?.let { assetPath ->
            val resolved = StrengthResolvedVideo(assetPath = assetPath)
            val valid = runCatching {
                context.assets.openFd(assetPath).use { descriptor ->
                    descriptor.length in 33..STRENGTH_MAXIMUM_DOWNLOAD_BYTES
                }
            }.getOrDefault(false) &&
                meetsPolicy(context, resolved, source.minimumPixels)
            return@withContext if (valid) {
                resolved
            } else {
                null
            }
        }

        if (!source.model.startsWith("https://")) return@withContext null
        val directory = File(context.cacheDir, "noop-strength-media").apply { mkdirs() }
        val destination = File(directory, "${source.cacheKey}.mp4")
        if (
            destination.isFile &&
            destination.length() in 33..STRENGTH_MAXIMUM_DOWNLOAD_BYTES
        ) {
            val cached = StrengthResolvedVideo(file = destination)
            if (meetsPolicy(context, cached, source.minimumPixels)) {
                return@withContext cached
            }
            destination.delete()
        }

        val temporary = File(directory, "${source.cacheKey}.download")
        runCatching {
            client.newCall(
                Request.Builder()
                    .url(source.model)
                    .header("Accept", "video/mp4")
                    .build(),
            ).execute().use { response ->
                if (!response.isSuccessful) throw IOException("Video request failed")
                val body = response.body ?: throw IOException("Video response was empty")
                if (!StrengthExerciseMediaPolicy.acceptsContentLength(body.contentLength())) {
                    throw IOException("Strength exercise media exceeds the download limit")
                }
                var total = 0L
                body.byteStream().use { input ->
                    FileOutputStream(temporary).use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > STRENGTH_MAXIMUM_DOWNLOAD_BYTES) {
                                throw IOException(
                                    "Strength exercise media exceeds the download limit",
                                )
                            }
                            output.write(buffer, 0, count)
                        }
                    }
                }
                if (total <= 32) throw IOException("Video response was incomplete")
            }
            if (!temporary.renameTo(destination)) {
                temporary.copyTo(destination, overwrite = true)
                temporary.delete()
            }
            val resolved = StrengthResolvedVideo(file = destination)
            if (!meetsPolicy(context, resolved, source.minimumPixels)) {
                destination.delete()
                throw IOException("Exercise video does not meet the resolution policy")
            }
            resolved
        }.onFailure {
            temporary.delete()
            destination.takeIf { file -> file.length() <= 32 }?.delete()
            com.noop.AppDiagnosticsRecorder.record(
                "strength_media.load",
                fields = mapOf(
                    "media_kind" to "video_download",
                    "outcome" to "failed",
                    "failure_kind" to it.javaClass.simpleName,
                ),
            )
        }.getOrNull()
    }

    private fun meetsPolicy(
        context: Context,
        video: StrengthResolvedVideo,
        minimumPixels: Int,
    ): Boolean = runCatching {
        val retriever = MediaMetadataRetriever()
        try {
            video.assetPath?.let { path ->
                context.assets.openFd(path).use { descriptor ->
                    retriever.setDataSource(
                        descriptor.fileDescriptor,
                        descriptor.startOffset,
                        descriptor.length,
                    )
                    videoDimensionsMeetPolicy(retriever, minimumPixels)
                }
            } ?: run {
                retriever.setDataSource(requireNotNull(video.file).absolutePath)
                videoDimensionsMeetPolicy(retriever, minimumPixels)
            }
        } finally {
            retriever.release()
        }
    }.getOrDefault(false)

    private fun videoDimensionsMeetPolicy(
        retriever: MediaMetadataRetriever,
        minimumPixels: Int,
    ): Boolean {
        val width = retriever.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,
        )?.toIntOrNull() ?: return false
        val height = retriever.extractMetadata(
            MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,
        )?.toIntOrNull() ?: return false
        return width >= minimumPixels && height >= minimumPixels
    }
}

private class StrengthLoopingVideoTextureView(
    context: Context,
) : TextureView(context), TextureView.SurfaceTextureListener {
    private var player: MediaPlayer? = null
    private var playerSurface: Surface? = null
    private var boundSource: StrengthResolvedVideo? = null
    private var boundCacheKey: String? = null
    private var minimumPixels: Int = STRENGTH_MINIMUM_VIDEO_PIXELS
    private var shouldPlay = false
    private var prepared = false
    private var onReady: () -> Unit = {}
    private var onFailure: () -> Unit = {}

    init {
        surfaceTextureListener = this
    }

    fun bind(
        source: StrengthResolvedVideo,
        cacheKey: String,
        minimumPixels: Int,
        shouldPlay: Boolean,
        onReady: () -> Unit,
        onFailure: () -> Unit,
    ) {
        this.onReady = onReady
        this.onFailure = onFailure
        this.shouldPlay = shouldPlay
        val changed =
            boundSource != source ||
                boundCacheKey != cacheKey ||
                this.minimumPixels != minimumPixels
        if (changed) {
            releasePlayer()
            boundSource = source
            boundCacheKey = cacheKey
            this.minimumPixels = minimumPixels
            if (isAvailable) preparePlayer()
        } else {
            syncPlayback()
        }
    }

    fun release() {
        releasePlayer()
        boundSource = null
        boundCacheKey = null
    }

    private fun preparePlayer() {
        val source = boundSource ?: return
        val texture = surfaceTexture ?: return
        val expectedKey = boundCacheKey
        runCatching {
            val surface = Surface(texture)
            playerSurface = surface
            MediaPlayer().also { mediaPlayer ->
                player = mediaPlayer
                mediaPlayer.isLooping = true
                mediaPlayer.setVolume(0f, 0f)
                source.assetPath?.let { path ->
                    context.assets.openFd(path).use { descriptor ->
                        mediaPlayer.setDataSource(
                            descriptor.fileDescriptor,
                            descriptor.startOffset,
                            descriptor.length,
                        )
                    }
                } ?: mediaPlayer.setDataSource(
                    requireNotNull(source.file).absolutePath,
                )
                mediaPlayer.setSurface(surface)
                mediaPlayer.setOnPreparedListener { readyPlayer ->
                    if (expectedKey != boundCacheKey) return@setOnPreparedListener
                    if (
                        readyPlayer.videoWidth < minimumPixels ||
                        readyPlayer.videoHeight < minimumPixels
                    ) {
                        failCurrent()
                        return@setOnPreparedListener
                    }
                    prepared = true
                    readyPlayer.seekTo(0)
                    onReady()
                    syncPlayback()
                }
                mediaPlayer.setOnErrorListener { _, _, _ ->
                    if (expectedKey == boundCacheKey) failCurrent()
                    true
                }
                mediaPlayer.prepareAsync()
            }
        }.onFailure {
            com.noop.AppDiagnosticsRecorder.record(
                "strength_media.load",
                fields = mapOf(
                    "media_kind" to "video_playback",
                    "outcome" to "failed",
                    "failure_kind" to it.javaClass.simpleName,
                ),
            )
            failCurrent()
        }
    }

    private fun syncPlayback() {
        val mediaPlayer = player ?: return
        if (!prepared) return
        runCatching {
            if (shouldPlay) {
                mediaPlayer.start()
            } else {
                if (mediaPlayer.isPlaying) mediaPlayer.pause()
                if (mediaPlayer.currentPosition > 250) mediaPlayer.seekTo(0)
            }
        }.onFailure {
            failCurrent()
        }
    }

    private fun failCurrent() {
        releasePlayer()
        onFailure()
    }

    private fun releasePlayer() {
        prepared = false
        player?.runCatching { setSurface(null) }
        player?.release()
        player = null
        playerSurface?.release()
        playerSurface = null
    }

    override fun onSurfaceTextureAvailable(
        surface: SurfaceTexture,
        width: Int,
        height: Int,
    ) {
        preparePlayer()
    }

    override fun onSurfaceTextureSizeChanged(
        surface: SurfaceTexture,
        width: Int,
        height: Int,
    ) = Unit

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        releasePlayer()
        return true
    }

    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
}

@Composable
private fun StrengthExerciseVideo(
    source: StrengthExerciseMediaSource,
    requestVersion: Int,
    shouldPlay: Boolean,
    onLoading: () -> Unit,
    onSuccess: () -> Unit,
    onError: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var resolved by remember(source.model, requestVersion) {
        mutableStateOf<StrengthResolvedVideo?>(null)
    }
    var playerView by remember(source.model, requestVersion) {
        mutableStateOf<StrengthLoopingVideoTextureView?>(null)
    }

    LaunchedEffect(source.model, requestVersion) {
        onLoading()
        resolved = StrengthVideoCache.resolve(context.applicationContext, source)
        if (resolved == null) onError()
    }
    DisposableEffect(source.model, requestVersion) {
        onDispose { playerView?.release() }
    }

    resolved?.let { video ->
        AndroidView(
            factory = { viewContext ->
                StrengthLoopingVideoTextureView(viewContext).also { playerView = it }
            },
            update = { view ->
                view.bind(
                    source = video,
                    cacheKey = source.cacheKey,
                    minimumPixels = source.minimumPixels,
                    shouldPlay = shouldPlay,
                    onReady = onSuccess,
                    onFailure = onError,
                )
            },
            modifier = modifier,
        )
    }
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
    val descriptor = remember(exercise.id) {
        StrengthNativeAssets.mediaDescriptor(context, exercise.id)
    }
    val mediaSources = remember(descriptor, context.applicationContext) {
        descriptor?.let { StrengthNativeAssets.mediaSources(context, it) }.orEmpty()
    }
    if (descriptor == null || mediaSources.isEmpty()) {
        fallback()
        return
    }

    var paused by remember(exercise.id) { mutableStateOf(reduceMotion) }
    var loading by remember(exercise.id) { mutableStateOf(true) }
    var failed by remember(exercise.id) { mutableStateOf(false) }
    var animation by remember(exercise.id) { mutableStateOf<Animatable?>(null) }
    var showInfo by remember(exercise.id) { mutableStateOf(false) }
    var requestVersion by remember(exercise.id) { mutableStateOf(0) }
    var candidateIndex by remember(exercise.id) { mutableStateOf(0) }
    val mediaSource = mediaSources.getOrNull(candidateIndex)
    if (mediaSource == null) {
        fallback()
        return
    }
    val formGuide = remember(exercise.id) {
        StrengthNativeAssets.formGuide(context, exercise.id)
    }
    val shape = RoundedCornerShape(8.dp)
    val lifecycleOwner = LocalLifecycleOwner.current
    var lifecycleActive by remember(lifecycleOwner) {
        mutableStateOf(
            lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED),
        )
    }
    val mediaPaused = paused || reduceMotion || !lifecycleActive
    val sourceModel = mediaSource.model
    val advanceSource = {
        animation?.stop()
        animation = null
        if (
            mediaSources.getOrNull(candidateIndex)?.model == sourceModel &&
            candidateIndex < mediaSources.lastIndex
        ) {
            candidateIndex += 1
            loading = true
            failed = false
        } else if (mediaSources.getOrNull(candidateIndex)?.model == sourceModel) {
            loading = false
            failed = true
        }
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, _ ->
            lifecycleActive = lifecycleOwner.lifecycle.currentState
                .isAtLeast(Lifecycle.State.STARTED)
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(mediaPaused, animation) {
        if (mediaPaused) animation?.stop() else animation?.start()
    }
    LaunchedEffect(sourceModel, requestVersion) {
        loading = true
        failed = false
        animation = null
    }
    LaunchedEffect(sourceModel, requestVersion, loading) {
        if (!loading) return@LaunchedEffect
        delay(12_000)
        if (loading) advanceSource()
    }
    DisposableEffect(animation) {
        onDispose { animation?.stop() }
    }

    BoxWithConstraints(
        modifier = modifier
            .clip(shape)
            .background(Color.White, shape)
            .border(1.dp, Palette.hairline, shape),
    ) {
        val mediaSize = minOf(maxHeight, maxWidth).coerceAtLeast(0.dp)
        val mediaPixels = with(LocalDensity.current) {
            mediaSize.roundToPx().coerceAtLeast(1)
        }
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .size(mediaSize)
                .background(Color.White)
                .clickable(enabled = !reduceMotion, role = Role.Button) {
                    paused = !paused
                },
            contentAlignment = Alignment.Center,
        ) {
            if (!failed) {
                when (mediaSource.kind) {
                    StrengthExerciseMediaKind.VIDEO -> StrengthExerciseVideo(
                        source = mediaSource,
                        requestVersion = requestVersion,
                        shouldPlay = !mediaPaused,
                        onLoading = {
                            loading = true
                            failed = false
                        },
                        onSuccess = {
                            loading = false
                            failed = false
                        },
                        onError = advanceSource,
                        modifier = Modifier.fillMaxSize(),
                    )
                    StrengthExerciseMediaKind.GIF -> AsyncImage(
                        model = ImageRequest.Builder(context)
                            .data(mediaSource.model)
                            .memoryCacheKey(
                                "strength-exercise-v4-${mediaSource.cacheKey}",
                            )
                            .diskCacheKey(
                                "strength-exercise-v4-${mediaSource.cacheKey}",
                            )
                            .setParameter("request-version", requestVersion)
                            .setParameter(
                                STRENGTH_MINIMUM_PIXELS_PARAMETER,
                                mediaSource.minimumPixels,
                            )
                            .size(mediaPixels)
                            .build(),
                        imageLoader = imageLoader,
                        contentDescription = stringResource(
                            R.string.strength_exercise_guide,
                        ),
                        contentScale = ContentScale.Fit,
                        filterQuality = FilterQuality.High,
                        modifier = Modifier.fillMaxSize(),
                        onLoading = {
                            loading = true
                            failed = false
                        },
                        onSuccess = {
                            loading = false
                            failed = false
                            animation = it.result.drawable as? Animatable
                            if (mediaPaused) animation?.stop() else animation?.start()
                        },
                        onError = {
                            com.noop.AppDiagnosticsRecorder.record(
                                "strength_media.load",
                                fields = mapOf(
                                    "media_kind" to "exercise_animation",
                                    "outcome" to "decode_failed",
                                    "failure_kind" to it.result.throwable.javaClass.simpleName,
                                ),
                            )
                            advanceSource()
                        },
                    )
                }
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
                Icon(
                    Icons.Filled.FitnessCenter,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(30.dp),
                )
            }
        }
        if (!loading && !failed) {
            StrengthMediaControl(
                imageVector = if (mediaPaused) {
                    Icons.Filled.PlayArrow
                } else {
                    Icons.Filled.Pause
                },
                description = stringResource(
                    if (mediaPaused) {
                        R.string.strength_play_guide
                    } else {
                        R.string.strength_pause_guide
                    },
                ),
                alignment = Alignment.BottomEnd,
                onClick = {
                    if (reduceMotion) return@StrengthMediaControl
                    paused = !paused
                },
            )
        }
        if (failed) {
            StrengthMediaControl(
                imageVector = Icons.Filled.Refresh,
                description = stringResource(R.string.today_weather_retry),
                alignment = Alignment.BottomEnd,
                onClick = {
                    requestVersion += 1
                    candidateIndex = 0
                    failed = false
                    loading = true
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
            com.noop.AppDiagnosticsRecorder.record(
                "strength_media.load",
                fields = mapOf(
                    "media_kind" to "body_map",
                    "outcome" to "decode_failed",
                    "failure_kind" to it.result.throwable.javaClass.simpleName,
                ),
            )
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
