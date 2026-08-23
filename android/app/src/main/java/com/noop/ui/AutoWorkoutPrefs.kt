package com.noop.ui

import android.content.Context
import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.CoarseWorkoutClass
import com.noop.analytics.WorkoutSport
import com.noop.data.WorkoutRow

/**
 * AutoWorkoutPrefs — durable dismissed-span store for the opt-in auto-detect Today card.
 *
 * Byte-mirror of the iOS `Repository.autoDetectDismissedSpans` (UserDefaults key
 * "workouts.autoDetectDismissed"): stable `start:<startSec>` identities. Legacy `start:end` tokens
 * remain readable so upgrades preserve existing dismissals. Kept DELIBERATELY SEPARATE from the gravity detector's `dismissedWorkout` table
 * ([com.noop.data.WhoopRepository.dismissedDetected]) so the two features never cross-suppress each
 * other — exactly as the iOS twin does. A dismissed suggestion is remembered here so the same window
 * never re-prompts after a relaunch.
 *
 * Also stores the latest unattended save waiting for a Today Keep / Not a workout review. Older
 * auto-saved rows remain in Workouts even when a newer review replaces that one-card pointer.
 */
object AutoWorkoutPrefs {
    private const val FILE = "noop_auto_workout_prefs"
    private const val KEY_DISMISSED = "workouts.autoDetectDismissed"
    private const val KEY_REVIEW_START = "autoWorkout.review.start"
    private const val KEY_REVIEW_END = "autoWorkout.review.end"
    private const val KEY_REVIEW_SPORT = "autoWorkout.review.sport"
    private const val KEY_REVIEW_DEVICE = "autoWorkout.review.device"
    private const val KEY_REVIEW_SOURCE = "autoWorkout.review.source"
    private const val KEY_REVIEW_AVG = "autoWorkout.review.avg"
    private const val KEY_REVIEW_PEAK = "autoWorkout.review.peak"
    private const val KEY_PREFERRED_SPORT_PREFIX = "workouts.autoDetectPreferredSport."

    data class Review(
        val startSec: Long,
        val endSec: Long,
        val sport: String,
        val deviceId: String,
        val source: String,
        val avgBpm: Int,
        val peakBpm: Int,
    ) {
        fun row(): WorkoutRow = WorkoutRow(
            deviceId = deviceId, startTs = startSec, endTs = endSec,
            sport = sport, source = source, durationS = (endSec - startSec).toDouble(),
            energyKcal = null, avgHr = avgBpm, maxHr = peakBpm, strain = null,
            distanceM = null, zonesJSON = null, notes = null, routePolyline = null,
        )
    }

    /**
     * Hard cap on the dismissed-span set — a backstop so it can't grow without bound even in
     * pathological use. 200 most-recent (by span END) is far more than detection's ~2-day window can
     * ever re-surface; the age prune below normally keeps it much shorter. Mirrors the iOS twin.
     */
    private const val DISMISSED_MAX = 200

    /**
     * Spans whose END is older than this many seconds can never be re-suggested (detection only scans
     * the last ~2 days), so we drop them. 30 days, matching the iOS twin byte-for-byte.
     */
    private const val DISMISSED_MAX_AGE_SEC = 30L * 86_400L

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Stable identity for one bout. Endpoint growth/merging cannot create another prompt. */
    fun token(startSec: Long, endSec: Long): String {
        @Suppress("UNUSED_VARIABLE") val ignoredEnd = endSec
        return "start:$startSec"
    }

    fun token(w: AutoWorkoutDetector.DetectedWorkout): String = token(w.startSec, w.endSec)

    private fun tokenStart(token: String): Long? = when {
        token.startsWith("start:") -> token.removePrefix("start:").toLongOrNull()
        else -> token.substringBefore(':', "").toLongOrNull()
    }

    /** Match both the stable token and a legacy `start:end` token by the immutable start boundary. */
    fun matches(token: String, w: AutoWorkoutDetector.DetectedWorkout): Boolean =
        tokenStart(token) == w.startSec

    /** Reference time for retention: stable tokens use start; legacy span tokens use end. */
    private fun tokenReference(token: String): Long? =
        if (token.startsWith("start:")) tokenStart(token)
        else token.substringAfterLast(':', "").toLongOrNull()

    /**
     * Prune the dismissed-span set: drop spans whose END is older than ~30 days (they can never be
     * re-suggested anyway), then hard-cap to the [DISMISSED_MAX] most-recent (by END) as a backstop.
     * Malformed tokens are kept (treated as newest) so we never silently lose data on a parse miss.
     * Byte-mirrored in the iOS `Repository.prunedAutoDetectSpans`.
     */
    private fun prune(spans: Set<String>, now: Long): Set<String> {
        val cutoff = now - DISMISSED_MAX_AGE_SEC
        // Drop anything that aged out; an unparseable token survives the age filter.
        val fresh = spans.filter { token -> (tokenReference(token) ?: return@filter true) >= cutoff }
        if (fresh.size <= DISMISSED_MAX) return fresh.toSet()
        // Over the cap — keep the most-recent by END (unparseable sort as newest).
        return fresh.sortedByDescending { tokenReference(it) ?: Long.MAX_VALUE }
            .take(DISMISSED_MAX)
            .toSet()
    }

    /** The set of dismissed span tokens (empty when none). */
    fun dismissed(ctx: Context): Set<String> =
        prefs(ctx).getStringSet(KEY_DISMISSED, emptySet())?.toSet() ?: emptySet()

    /**
     * Record a dismissed span durably. Idempotent (a Set never double-stores a token). Prunes the
     * stored set on every add (drop spans older than ~30 days + hard-cap to 200 most-recent) so it can
     * never grow unbounded. Byte-mirrored in the iOS `Repository.dismissDetectedSuggestion`.
     */
    fun dismiss(ctx: Context, w: AutoWorkoutDetector.DetectedWorkout) {
        val cur = dismissed(ctx).toMutableSet()
        if (cur.none { matches(it, w) } && cur.add(token(w))) {
            // Store a fresh copy — SharedPreferences.getStringSet returns a live instance that must not
            // be mutated in place, so a new set is written back.
            val pruned = prune(cur, System.currentTimeMillis() / 1000L)
            prefs(ctx).edit().putStringSet(KEY_DISMISSED, pruned).apply()
        }
    }

    /** Bridge a persisted Detected/NOOP row into the canonical suggestion identity. */
    fun dismiss(ctx: Context, row: WorkoutRow) {
        dismiss(
            ctx,
            AutoWorkoutDetector.DetectedWorkout(
                startSec = row.startTs,
                endSec = row.endTs,
                avgBpm = row.avgHr ?: 60,
                peakBpm = row.maxHr ?: row.avgHr ?: 60,
                durationMin = maxOf(1, ((row.endTs - row.startTs) / 60L).toInt()),
            ),
        )
    }

    /** Last exact catalog choice for this broad detector hint. No free text or private notes are stored. */
    fun preferredSport(
        ctx: Context,
        candidate: AutoWorkoutDetector.DetectedWorkout,
    ): String {
        val key = KEY_PREFERRED_SPORT_PREFIX + (candidate.suggestedClass?.raw ?: "generic")
        prefs(ctx).getString(key, null)?.let { stored ->
            WorkoutSport.all.firstOrNull { it.name.equals(stored, ignoreCase = true) }?.let {
                return it.name
            }
        }
        return when (candidate.suggestedClass) {
            CoarseWorkoutClass.WALK -> "Walking"
            CoarseWorkoutClass.RUN -> "Running"
            CoarseWorkoutClass.STRENGTH -> "Strength"
            CoarseWorkoutClass.CYCLE -> "Cycling"
            CoarseWorkoutClass.SKI -> "Skiing"
            CoarseWorkoutClass.OTHER, null -> WorkoutSport.default.name
        }
    }

    fun rememberSport(ctx: Context, sportName: String, hint: CoarseWorkoutClass?) {
        val sport = WorkoutSport.all.firstOrNull {
            it.name.equals(sportName.trim(), ignoreCase = true)
        } ?: return
        val key = KEY_PREFERRED_SPORT_PREFIX + (hint?.raw ?: "generic")
        prefs(ctx).edit().putString(key, sport.name).apply()
    }

    fun recordReview(ctx: Context, review: Review) {
        prefs(ctx).edit()
            .putLong(KEY_REVIEW_START, review.startSec)
            .putLong(KEY_REVIEW_END, review.endSec)
            .putString(KEY_REVIEW_SPORT, review.sport)
            .putString(KEY_REVIEW_DEVICE, review.deviceId)
            .putString(KEY_REVIEW_SOURCE, review.source)
            .putInt(KEY_REVIEW_AVG, review.avgBpm)
            .putInt(KEY_REVIEW_PEAK, review.peakBpm)
            .apply()
    }

    fun pendingReview(ctx: Context): Review? {
        val p = prefs(ctx)
        if (!p.contains(KEY_REVIEW_START)) return null
        val start = p.getLong(KEY_REVIEW_START, 0L)
        val end = p.getLong(KEY_REVIEW_END, 0L)
        val sport = p.getString(KEY_REVIEW_SPORT, null)?.trim().orEmpty()
        val device = p.getString(KEY_REVIEW_DEVICE, null)?.trim().orEmpty()
        val source = p.getString(KEY_REVIEW_SOURCE, null)?.trim().orEmpty()
        val avg = p.getInt(KEY_REVIEW_AVG, 0)
        val peak = p.getInt(KEY_REVIEW_PEAK, 0)
        if (start <= 0L || end <= start || sport.isEmpty() || device.isEmpty() || source.isEmpty() ||
            avg !in 30..220 || peak !in avg..250
        ) {
            clearReview(ctx)
            return null
        }
        return Review(start, end, sport, device, source, avg, peak)
    }

    fun clearReview(ctx: Context, startSec: Long? = null) {
        if (startSec != null && pendingReview(ctx)?.startSec != startSec) return
        prefs(ctx).edit()
            .remove(KEY_REVIEW_START)
            .remove(KEY_REVIEW_END)
            .remove(KEY_REVIEW_SPORT)
            .remove(KEY_REVIEW_DEVICE)
            .remove(KEY_REVIEW_SOURCE)
            .remove(KEY_REVIEW_AVG)
            .remove(KEY_REVIEW_PEAK)
            .apply()
    }
}
