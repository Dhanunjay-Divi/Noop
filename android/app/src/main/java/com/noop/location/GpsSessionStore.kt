package com.noop.location

import android.content.Context
import android.content.SharedPreferences
import com.noop.analytics.RouteMath
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Durable, local-only checkpoint for an in-flight GPS workout.
 *
 * A route can contain thousands of points. Re-encoding the whole route into SharedPreferences after every
 * fix made a long workout O(n²), performed XML writes from the service's main-thread collector, and created
 * an ever-growing queue of preference rewrites. This store instead writes one tiny header at Start and
 * appends one validated point record per accepted fix on a dedicated serial IO executor: O(1) work per fix,
 * O(n) total bytes, no cloud/backup exposure. A generation token prevents queued writes from an old session
 * landing after End or a new Start.
 */
class GpsSessionStore private constructor(
    private val file: File,
    private val legacyPrefs: SharedPreferences? = null,
    private val io: Executor = sharedIo,
) {
    private val generation = AtomicLong(0L)
    private val fileLock = Any()

    /** Replace any prior journal with a fresh, fsynced header. This one tiny write happens once at Start. */
    fun begin(state: GpsSession.State): Boolean {
        val header = GpsSessionPersistence.encodeHeader(state) ?: return false
        synchronized(fileLock) {
            generation.incrementAndGet()
            return runCatching {
                file.parentFile?.mkdirs()
                FileOutputStream(file, false).use { out ->
                    out.write(header.toByteArray(Charsets.UTF_8))
                    out.fd.sync()
                }
                true
            }.getOrDefault(false)
        }
    }

    /** Queue one constant-size point append away from the BLE/location main-thread collector. */
    fun append(point: RouteMath.LatLng) {
        val line = GpsSessionPersistence.encodePoint(point) ?: return
        val token = generation.get()
        io.execute {
            synchronized(fileLock) {
                if (token != generation.get() || !file.exists()) return@synchronized
                runCatching {
                    FileOutputStream(file, true).use { out ->
                        out.write(line.toByteArray(Charsets.UTF_8))
                    }
                }
            }
        }
    }

    fun load(nowMs: Long = System.currentTimeMillis()): GpsSession.State? = synchronized(fileLock) {
        if (file.isFile && file.length() in 1..GpsSessionPersistence.maxJournalBytes) {
            val raw = runCatching { file.readText(Charsets.UTF_8) }.getOrNull()
            val restored = GpsSessionPersistence.decode(raw, nowMs)
            if (restored != null) return@synchronized restored
        }

        // One-time compatibility with the earlier SharedPreferences full-polyline prototype. It may be
        // installed on a tester's phone already; migrate it to the append journal instead of dropping an
        // in-progress route during this update.
        val legacyRaw = legacyPrefs?.getString(LEGACY_KEY, null)
        val restored = GpsSessionPersistence.decode(legacyRaw, nowMs) ?: return@synchronized null
        val journal = GpsSessionPersistence.encode(restored) ?: return@synchronized restored
        runCatching {
            file.parentFile?.mkdirs()
            FileOutputStream(file, false).use { out ->
                out.write(journal.toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
            legacyPrefs?.edit()?.remove(LEGACY_KEY)?.commit()
        }
        restored
    }

    /** Invalidate queued appends, then synchronously remove the checkpoint. */
    fun clear(): Boolean = synchronized(fileLock) {
        generation.incrementAndGet()
        val fileCleared = !file.exists() || file.delete()
        val legacyCleared = legacyPrefs?.edit()?.remove(LEGACY_KEY)?.commit() ?: true
        fileCleared && legacyCleared
    }

    companion object {
        private const val FILE_NAME = "active-gps-workout.route"
        private const val LEGACY_PREFS = "noop_active_gps_workout"
        private const val LEGACY_KEY = "activeGpsWorkout.snapshot"
        private val sharedIo by lazy {
            Executors.newSingleThreadExecutor { task ->
                Thread(task, "noop-gps-checkpoint").apply { isDaemon = true }
            }
        }

        fun from(context: Context): GpsSessionStore =
            GpsSessionStore(
                file = File(context.noBackupFilesDir, FILE_NAME),
                legacyPrefs = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE),
            )
    }
}

/** Context-free journal codec, separated so process-death behavior is JVM-testable. */
object GpsSessionPersistence {
    const val maxSessionAgeMs: Long = 24L * 60L * 60L * 1_000L
    const val maxFutureSkewMs: Long = 5L * 60L * 1_000L
    const val maxJournalBytes: Long = 12L * 1024L * 1024L
    private const val MAX_POINTS = 100_000
    private const val JOURNAL_VERSION = "v2"
    private const val LEGACY_VERSION = "v1"

    /** Header is newline-terminated so every later point is one append-only record. */
    fun encodeHeader(state: GpsSession.State): String? {
        if (!state.active || state.startMs <= 0L || state.sportName.isBlank()) return null
        val sport = state.sportName.replace('\n', ' ').replace('\r', ' ').trim()
        if (sport.isBlank()) return null
        return "$JOURNAL_VERSION\n${state.startMs}\n$sport\n"
    }

    fun encodePoint(point: RouteMath.LatLng): String? {
        if (!point.lat.isFinite() || !point.lon.isFinite() ||
            point.lat !in -90.0..90.0 || point.lon !in -180.0..180.0
        ) return null
        return "${point.lat},${point.lon}\n"
    }

    /** Full journal encoder retained for pure tests and migration tools; production appends each point. */
    fun encode(state: GpsSession.State): String? {
        val header = encodeHeader(state) ?: return null
        return buildString(header.length + state.track.size * 24) {
            append(header)
            state.track.forEach { point -> append(encodePoint(point) ?: return null) }
        }
    }

    fun decode(raw: String?, nowMs: Long): GpsSession.State? {
        if (raw.isNullOrBlank() || nowMs <= 0L) return null
        return when {
            raw.startsWith("$JOURNAL_VERSION\n") -> decodeJournal(raw, nowMs)
            raw.startsWith("$LEGACY_VERSION\n") -> decodeLegacy(raw, nowMs)
            else -> null
        }
    }

    private fun decodeJournal(raw: String, nowMs: Long): GpsSession.State? {
        if (raw.toByteArray(Charsets.UTF_8).size > maxJournalBytes) return null
        val lines = raw.split('\n')
        if (lines.size < 4 || lines[0] != JOURNAL_VERSION) return null
        val startMs = lines[1].toLongOrNull() ?: return null
        val sport = lines[2].trim()
        if (!validHeader(startMs, sport, nowMs)) return null

        val track = ArrayList<RouteMath.LatLng>(minOf(lines.size - 3, MAX_POINTS))
        val lastPayloadIndex = lines.indexOfLast { it.isNotEmpty() }
        for (index in 3..lastPayloadIndex) {
            val line = lines[index]
            if (line.isEmpty()) continue
            val pieces = line.split(',', limit = 2)
            val lat = pieces.getOrNull(0)?.toDoubleOrNull()
            val lon = pieces.getOrNull(1)?.toDoubleOrNull()
            if (lat == null || lon == null || !validPoint(lat, lon)) {
                // A killed process can leave only the final append torn. Keep every complete point before it;
                // malformed data in the middle fails closed instead of splicing an untrusted route.
                if (index == lastPayloadIndex) break else return null
            }
            if (track.size >= MAX_POINTS) return null
            track += RouteMath.LatLng(lat, lon)
        }
        return restoredState(startMs, sport, track, nowMs)
    }

    /** Read the original full-polyline v1 representation so in-progress dev builds are not discarded. */
    private fun decodeLegacy(raw: String, nowMs: Long): GpsSession.State? {
        val lines = raw.split('\n', limit = 4)
        if (lines.size != 4 || lines[0] != LEGACY_VERSION) return null
        val startMs = lines[1].toLongOrNull() ?: return null
        val sport = lines[2].trim()
        if (!validHeader(startMs, sport, nowMs)) return null
        val track = runCatching { RouteMath.decode(lines[3]) }.getOrNull() ?: return null
        if (track.size > MAX_POINTS || track.any { !validPoint(it.lat, it.lon) }) return null
        return restoredState(startMs, sport, track, nowMs)
    }

    private fun validHeader(startMs: Long, sport: String, nowMs: Long): Boolean {
        val ageMs = nowMs - startMs
        return startMs > 0L && sport.isNotBlank() &&
            ageMs >= -maxFutureSkewMs && ageMs <= maxSessionAgeMs
    }

    private fun validPoint(lat: Double, lon: Double): Boolean =
        lat.isFinite() && lon.isFinite() && lat in -90.0..90.0 && lon in -180.0..180.0

    private fun restoredState(
        startMs: Long,
        sport: String,
        track: List<RouteMath.LatLng>,
        nowMs: Long,
    ): GpsSession.State {
        val distance = RouteMath.totalMeters(track)
        val elapsedSeconds = (nowMs - startMs).coerceAtLeast(0L) / 1_000.0
        return GpsSession.State(
            active = true,
            startMs = startMs,
            sportName = sport,
            track = track,
            pointCount = track.size,
            distanceM = distance,
            paceSecPerKm = RouteMath.paceSecPerKm(distance, elapsedSeconds),
        )
    }
}
