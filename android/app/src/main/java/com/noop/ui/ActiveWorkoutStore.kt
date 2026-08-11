package com.noop.ui

import android.content.Context
import android.content.SharedPreferences
import com.noop.analytics.RouteMath
import com.noop.data.HrSample

/**
 * Durable persistence for a manually-started workout (#529).
 *
 * The snapshot covers both GPS and non-GPS sessions. While a GPS session is recording its route remains in
 * [com.noop.location.GpsSession]'s append-only checkpoint; when the user taps End the exact final route and
 * end time are copied here *before* that live checkpoint is cleared. The snapshot is removed only after the
 * Room workout + HR rows commit, or after an explicit discard, so a failed save is retryable after relaunch.
 *
 * On-device only; nothing leaves the phone. The encode/decode is factored into the pure
 * [ActiveWorkoutPersistence] so the round-trip is unit-testable without a Context.
 */
class ActiveWorkoutStore(private val prefs: SharedPreferences) {

    /** Persist (overwrite) the active workout snapshot. Called at Start and a bounded HR cadence. */
    fun save(snapshot: ActiveWorkoutPersistence.Snapshot) {
        prefs.edit().putString(KEY_SNAPSHOT, ActiveWorkoutPersistence.encode(snapshot)).apply()
    }

    /** Synchronous durability barrier used exactly once when End freezes the final route/time. */
    fun saveDurably(snapshot: ActiveWorkoutPersistence.Snapshot): Boolean =
        prefs.edit().putString(KEY_SNAPSHOT, ActiveWorkoutPersistence.encode(snapshot)).commit()

    /** Read the persisted snapshot, or null if none is stored (or it was corrupt). */
    fun load(): ActiveWorkoutPersistence.Snapshot? =
        ActiveWorkoutPersistence.decode(prefs.getString(KEY_SNAPSHOT, null))

    /** Clear only after a successful database commit or an explicit discard. */
    fun clear(): Boolean = prefs.edit().remove(KEY_SNAPSHOT).commit()

    companion object {
        private const val PREFS = "noop_active_workout"
        private const val KEY_SNAPSHOT = "activeWorkout.snapshot"

        fun from(context: Context): ActiveWorkoutStore =
            ActiveWorkoutStore(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))
    }
}

/**
 * Pure (Context-free) codec for the durable active-workout snapshot. Kept separate from the
 * SharedPreferences wrapper so the persist/rehydrate round-trip can be unit-tested on the JVM.
 *
 * Version 2 adds the frozen end, GPS flag, distance/pace, and final encoded route. Version 1 remains
 * readable so installing this build cannot discard an already-running non-GPS workout. Anything malformed
 * decodes to null (treated as "no in-flight session"), so a corrupt write cannot crash rehydration.
 */
object ActiveWorkoutPersistence {

    /** The durable shape required to rebuild an active session or retry an exact, already-ended one. */
    data class Snapshot(
        val startMs: Long,
        val sportName: String,
        val deviceId: String,
        val samples: List<HrSample>,
        val avgHr: Int,
        val peakHr: Int,
        val liveStrain: Double,
        val endMs: Long? = null,
        val gpsEnabled: Boolean = false,
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
        val routePolyline: String? = null,
    )

    /** Encode a snapshot to the compact line format. */
    fun encode(s: Snapshot): String {
        val sb = StringBuilder()
        // Header v2: version | start | end? | avg | peak | strain | gps | distance | pace? | route? |
        // sport | device. The encoded polyline alphabet never contains our control-char delimiters; free
        // text is sanitized below. An active GPS snapshot normally has an empty route here (the append-only
        // GPS checkpoint owns it); a finished snapshot carries the final route for retry.
        sb.append("v2").append(FIELD)
            .append(s.startMs).append(FIELD)
            .append(s.endMs ?: "").append(FIELD)
            .append(s.avgHr).append(FIELD)
            .append(s.peakHr).append(FIELD)
            .append(s.liveStrain).append(FIELD)
            .append(if (s.gpsEnabled) "1" else "0").append(FIELD)
            .append(s.distanceM).append(FIELD)
            .append(s.paceSecPerKm ?: "").append(FIELD)
            .append(s.routePolyline.orEmpty()).append(FIELD)
            .append(sanitize(s.sportName)).append(FIELD)
            .append(sanitize(s.deviceId))
        for (hr in s.samples) {
            sb.append(LINE).append(hr.ts).append(',').append(hr.bpm)
        }
        return sb.toString()
    }

    /** Decode the line format back to a snapshot. Returns null for null/blank/malformed input so a
     *  corrupt write is treated as "no session" rather than reviving a broken card. */
    fun decode(raw: String?): Snapshot? {
        if (raw.isNullOrBlank()) return null
        val lines = raw.split(LINE)
        val header = lines.firstOrNull()?.split(FIELD) ?: return null
        val version = header.firstOrNull()
        if (version != "v1" && version != "v2") return null

        val startMs: Long
        val endMs: Long?
        val avgHr: Int
        val peakHr: Int
        val liveStrain: Double
        val gpsEnabled: Boolean
        val distanceM: Double
        val paceSecPerKm: Double?
        val routePolyline: String?
        val sportName: String
        val deviceId: String
        if (version == "v1") {
            // Legacy: version | start | avg | peak | strain | sport | device.
            if (header.size < 7) return null
            startMs = header[1].toLongOrNull() ?: return null
            endMs = null
            avgHr = header[2].toIntOrNull() ?: return null
            peakHr = header[3].toIntOrNull() ?: return null
            liveStrain = header[4].toDoubleOrNull() ?: return null
            gpsEnabled = false
            distanceM = 0.0
            paceSecPerKm = null
            routePolyline = null
            sportName = header[5]
            deviceId = header[6]
        } else {
            if (header.size < 12) return null
            startMs = header[1].toLongOrNull() ?: return null
            endMs = header[2].takeIf { it.isNotEmpty() }?.toLongOrNull()
            if (header[2].isNotEmpty() && endMs == null) return null
            avgHr = header[3].toIntOrNull() ?: return null
            peakHr = header[4].toIntOrNull() ?: return null
            liveStrain = header[5].toDoubleOrNull() ?: return null
            gpsEnabled = when (header[6]) { "1" -> true; "0" -> false; else -> return null }
            distanceM = header[7].toDoubleOrNull() ?: return null
            paceSecPerKm = header[8].takeIf { it.isNotEmpty() }?.toDoubleOrNull()
            if (header[8].isNotEmpty() && paceSecPerKm == null) return null
            routePolyline = header[9].takeIf { it.isNotEmpty() }
            sportName = header[10]
            deviceId = header[11]
        }
        if (startMs <= 0L) return null
        if (endMs != null && endMs < startMs) return null
        if (deviceId.isBlank() || sportName.isBlank()) return null
        if (!distanceM.isFinite() || distanceM < 0.0) return null
        if (paceSecPerKm != null && (!paceSecPerKm.isFinite() || paceSecPerKm < 0.0)) return null
        if (routePolyline != null) {
            val route = runCatching { RouteMath.decode(routePolyline) }.getOrNull() ?: return null
            if (route.size < 2 || route.any {
                    !it.lat.isFinite() || !it.lon.isFinite() ||
                        it.lat !in -90.0..90.0 || it.lon !in -180.0..180.0
                }
            ) return null
        }
        val samples = ArrayList<HrSample>(lines.size - 1)
        for (i in 1 until lines.size) {
            val parts = lines[i].split(',')
            if (parts.size != 2) continue   // tolerate a torn final line — skip it, don't fail
            val ts = parts[0].toLongOrNull() ?: continue
            val bpm = parts[1].toIntOrNull() ?: continue
            // Bound-check untrusted persisted values: a plausible epoch-seconds ts and a real bpm only.
            if (ts <= 0L) continue
            if (bpm !in 1..300) continue
            samples.add(HrSample(deviceId = deviceId, ts = ts, bpm = bpm))
        }
        return Snapshot(
            startMs = startMs,
            sportName = sportName,
            deviceId = deviceId,
            samples = samples,
            avgHr = avgHr.coerceAtLeast(0),
            peakHr = peakHr.coerceAtLeast(0),
            liveStrain = if (liveStrain.isFinite()) liveStrain.coerceAtLeast(0.0) else 0.0,
            endMs = endMs,
            gpsEnabled = gpsEnabled,
            distanceM = distanceM,
            paceSecPerKm = paceSecPerKm,
            routePolyline = routePolyline,
        )
    }

    /** Save a finished workout before clearing its recovery snapshot. Failures preserve the snapshot. */
    sealed interface SaveResult {
        data object Saved : SaveResult
        data class Failed(val detail: String) : SaveResult
    }

    suspend fun saveThenClear(
        save: suspend () -> Unit,
        clear: () -> Boolean,
    ): SaveResult = try {
        save()
        if (!clear()) SaveResult.Failed("recovery snapshot could not be cleared") else SaveResult.Saved
    } catch (t: Throwable) {
        SaveResult.Failed(t.message ?: t.javaClass.simpleName)
    }

    /** Strip the two structural delimiters from a free-text field so it can't corrupt the framing. */
    private fun sanitize(s: String): String = s.replace(FIELD, " ").replace(LINE, " ")

    // Delimiters chosen to never appear in a sport name or device id: a unit/record separator pair.
    private const val FIELD = "\u001F"   // field separator (ASCII unit separator) within the header
    private const val LINE = "\u001E"    // record separator (ASCII record separator) between header and each sample
}

/**
 * Cursor for manual-workout HR capture. A new BLE packet sequence is required, so unrelated LiveState
 * republishes cannot duplicate a cached BPM. The raw packet BPM is stored (the smoothed BPM remains UI-only),
 * and the database's one-second time resolution is honored by admitting at most one sample per second.
 */
class WorkoutHeartRateCursor(
    consumedSequence: Long,
    lastTimestampSec: Long? = null,
) {
    var consumedSequence: Long = consumedSequence
        private set
    var lastTimestampSec: Long? = lastTimestampSec
        private set

    fun consume(sequence: Long, bpm: Int?, receivedAtSec: Long, deviceId: String): HrSample? {
        if (sequence == consumedSequence) return null
        consumedSequence = sequence
        if (bpm == null || bpm !in 30..220 || receivedAtSec <= 0L) return null
        if (receivedAtSec <= (lastTimestampSec ?: 0L)) return null
        lastTimestampSec = receivedAtSec
        return HrSample(deviceId = deviceId, ts = receivedAtSec, bpm = bpm)
    }
}

/**
 * Bounds active-snapshot rewrites. Encoding the entire growing HR window on every 1 Hz packet is O(n²)
 * over a long workout; one checkpoint every 30 seconds makes the work O(n²/30) in the strict mathematical
 * sense but, more importantly, caps writes to two per minute and keeps them off the packet hot path. Start
 * and End are always forced. A sudden process kill can therefore lose at most the latest ~30 seconds of HR;
 * the workout start and append-only GPS route are independently durable.
 */
object ActiveWorkoutCheckpointPolicy {
    const val intervalSec = 30L

    fun shouldCheckpoint(lastCheckpointSec: Long?, sampleSec: Long, force: Boolean = false): Boolean =
        force || lastCheckpointSec == null || sampleSec - lastCheckpointSec >= intervalSec
}
