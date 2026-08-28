package com.noop.ui

import android.content.Context
import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.CoarseWorkoutClass
import com.noop.analytics.WorkoutSport
import com.noop.data.WorkoutRow
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

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
    private const val KEY_DECISION_HISTORY = "workouts.autoDetectDecisionHistory.v1"

    enum class DecisionAction(val wireValue: String) {
        ACCEPTED("accepted"),
        DISMISSED("dismissed"),
        AUTO_SAVED("auto_saved_pending_review"),
        KEPT_AUTO_SAVE("kept_auto_save"),
        REJECTED_AUTO_SAVE("rejected_auto_save"),
        REMOVED_DETECTED_WORKOUT("removed_detected_workout"),
    }

    enum class DecisionActor(val wireValue: String) {
        USER("user"),
        AUTOMATION("automation"),
    }

    data class DecisionRecord(
        val candidateStartSec: Long,
        val candidateEndSec: Long?,
        val recordedAtSec: Long?,
        val action: DecisionAction,
        val actor: DecisionActor,
        val activityName: String?,
        val detectorVersion: String?,
        val averageBpm: Int?,
        val peakBpm: Int?,
        val eventConfidence: Double?,
        val confidenceStatus: String?,
        val evidenceProvenance: String?,
        val suggestedClass: String?,
        val suggestionConfidence: Double?,
        val origin: String,
    )

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
    internal const val DECISION_HISTORY_MAX = 1_000
    private const val RECORDED_ORIGIN = "recorded_event"
    private const val LEGACY_ORIGIN = "legacy_dismissal_tombstone"

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
    @Synchronized
    fun dismiss(
        ctx: Context,
        w: AutoWorkoutDetector.DetectedWorkout,
        action: DecisionAction = DecisionAction.DISMISSED,
        activityName: String? = null,
    ) {
        val cur = dismissed(ctx).toMutableSet()
        if (cur.none { matches(it, w) } && cur.add(token(w))) {
            // Store a fresh copy — SharedPreferences.getStringSet returns a live instance that must not
            // be mutated in place, so a new set is written back.
            val pruned = prune(cur, System.currentTimeMillis() / 1000L)
            prefs(ctx).edit().putStringSet(KEY_DISMISSED, pruned).apply()
            recordDecisionLocked(
                ctx,
                candidateDecision(
                    candidate = w,
                    action = action,
                    actor = DecisionActor.USER,
                    activityName = activityName,
                ),
            )
        }
    }

    /** Bridge a persisted Detected/NOOP row into the canonical suggestion identity. */
    @Synchronized
    fun dismiss(
        ctx: Context,
        row: WorkoutRow,
        action: DecisionAction = DecisionAction.REMOVED_DETECTED_WORKOUT,
    ) {
        val cur = dismissed(ctx).toMutableSet()
        val identity = token(row.startTs, row.endTs)
        val candidate = AutoWorkoutDetector.DetectedWorkout(
            startSec = row.startTs,
            endSec = row.endTs,
            avgBpm = row.avgHr ?: 60,
            peakBpm = row.maxHr ?: row.avgHr ?: 60,
            durationMin = maxOf(1, ((row.endTs - row.startTs) / 60L).toInt()),
        )
        if (cur.none { matches(it, candidate) } && cur.add(identity)) {
            prefs(ctx).edit()
                .putStringSet(KEY_DISMISSED, prune(cur, System.currentTimeMillis() / 1_000L))
                .apply()
            recordDecisionLocked(
                ctx,
                spanDecision(
                    startSec = row.startTs,
                    endSec = row.endTs,
                    action = action,
                    activityName = row.sport,
                ),
            )
        }
    }

    @Synchronized
    fun recordCandidateDecision(
        ctx: Context,
        candidate: AutoWorkoutDetector.DetectedWorkout,
        action: DecisionAction,
        actor: DecisionActor,
        activityName: String?,
    ) {
        recordDecisionLocked(
            ctx,
            candidateDecision(candidate, action, actor, activityName),
        )
    }

    @Synchronized
    fun recordReviewDecision(
        ctx: Context,
        review: Review,
        action: DecisionAction,
    ) {
        recordDecisionLocked(
            ctx,
            spanDecision(
                startSec = review.startSec,
                endSec = review.endSec,
                action = action,
                activityName = review.sport,
            ),
        )
    }

    private fun candidateDecision(
        candidate: AutoWorkoutDetector.DetectedWorkout,
        action: DecisionAction,
        actor: DecisionActor,
        activityName: String?,
        nowSec: Long = System.currentTimeMillis() / 1_000L,
    ): DecisionRecord = DecisionRecord(
        candidateStartSec = candidate.startSec,
        candidateEndSec = candidate.endSec,
        recordedAtSec = nowSec,
        action = action,
        actor = actor,
        activityName = activityName,
        detectorVersion = candidate.detectorVersion,
        averageBpm = candidate.avgBpm,
        peakBpm = candidate.peakBpm,
        eventConfidence = candidate.eventConfidence,
        confidenceStatus = candidate.confidenceStatus.name.lowercase(Locale.US),
        evidenceProvenance = candidate.evidenceProvenance.wireValue,
        suggestedClass = candidate.suggestedClass?.raw,
        suggestionConfidence = candidate.suggestionConfidence,
        origin = RECORDED_ORIGIN,
    )

    private fun spanDecision(
        startSec: Long,
        endSec: Long?,
        action: DecisionAction,
        activityName: String?,
        nowSec: Long = System.currentTimeMillis() / 1_000L,
    ): DecisionRecord = DecisionRecord(
        candidateStartSec = startSec,
        candidateEndSec = endSec,
        recordedAtSec = nowSec,
        action = action,
        actor = DecisionActor.USER,
        activityName = activityName,
        detectorVersion = null,
        averageBpm = null,
        peakBpm = null,
        eventConfidence = null,
        confidenceStatus = null,
        evidenceProvenance = null,
        suggestedClass = null,
        suggestionConfidence = null,
        origin = RECORDED_ORIGIN,
    )

    private fun recordDecisionLocked(ctx: Context, record: DecisionRecord) {
        val history = decisionRecordsLocked(ctx).toMutableList()
        val index = history.indexOfFirst {
            it.candidateStartSec == record.candidateStartSec && it.action == record.action
        }
        if (index >= 0) history[index] = record else history += record
        val bounded = history.takeLast(DECISION_HISTORY_MAX)
        val encoded = JSONArray()
        bounded.forEach { encoded.put(decisionJson(it)) }
        prefs(ctx).edit().putString(KEY_DECISION_HISTORY, encoded.toString()).apply()
    }

    private fun decisionRecordsLocked(ctx: Context): List<DecisionRecord> {
        val raw = prefs(ctx).getString(KEY_DECISION_HISTORY, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val result = ArrayList<DecisionRecord>(minOf(array.length(), DECISION_HISTORY_MAX))
        val first = maxOf(0, array.length() - DECISION_HISTORY_MAX)
        for (index in first until array.length()) {
            val record = runCatching {
                decisionRecord(array.getJSONObject(index))
            }.getOrNull() ?: continue
            result += record
        }
        return result
    }

    @Synchronized
    fun exportDecisionRecords(ctx: Context): List<DecisionRecord> {
        val result = decisionRecordsLocked(ctx).toMutableList()
        val alreadyRejected = result.asSequence()
            .filter {
                it.action == DecisionAction.DISMISSED ||
                    it.action == DecisionAction.REJECTED_AUTO_SAVE ||
                    it.action == DecisionAction.REMOVED_DETECTED_WORKOUT
            }
            .map { it.candidateStartSec }
            .toMutableSet()
        for (legacyToken in dismissed(ctx)) {
            val start = tokenStart(legacyToken) ?: continue
            if (!alreadyRejected.add(start)) continue
            val end = if (legacyToken.startsWith("start:")) {
                null
            } else {
                legacyToken.substringAfterLast(':', "").toLongOrNull()
            }
            result += DecisionRecord(
                candidateStartSec = start,
                candidateEndSec = end,
                recordedAtSec = null,
                action = DecisionAction.DISMISSED,
                actor = DecisionActor.USER,
                activityName = null,
                detectorVersion = null,
                averageBpm = null,
                peakBpm = null,
                eventConfidence = null,
                confidenceStatus = null,
                evidenceProvenance = null,
                suggestedClass = null,
                suggestionConfidence = null,
                origin = LEGACY_ORIGIN,
            )
        }
        return result.sortedWith(
            compareBy<DecisionRecord>(
                { it.candidateStartSec },
                { it.recordedAtSec ?: Long.MIN_VALUE },
                { it.action.wireValue },
            ),
        )
    }

    private fun decisionJson(record: DecisionRecord): JSONObject = JSONObject()
        .put("candidate_start_sec", record.candidateStartSec)
        .put("candidate_end_sec", record.candidateEndSec ?: JSONObject.NULL)
        .put("recorded_at_sec", record.recordedAtSec ?: JSONObject.NULL)
        .put("action", record.action.wireValue)
        .put("actor", record.actor.wireValue)
        .put("activity_name", record.activityName ?: JSONObject.NULL)
        .put("detector_version", record.detectorVersion ?: JSONObject.NULL)
        .put("average_bpm", record.averageBpm ?: JSONObject.NULL)
        .put("peak_bpm", record.peakBpm ?: JSONObject.NULL)
        .put("event_confidence", record.eventConfidence ?: JSONObject.NULL)
        .put("confidence_status", record.confidenceStatus ?: JSONObject.NULL)
        .put("evidence_provenance", record.evidenceProvenance ?: JSONObject.NULL)
        .put("suggested_class", record.suggestedClass ?: JSONObject.NULL)
        .put("suggestion_confidence", record.suggestionConfidence ?: JSONObject.NULL)
        .put("origin", record.origin)

    private fun decisionRecord(json: JSONObject): DecisionRecord? {
        val start = json.optLong("candidate_start_sec", 0L)
        val action = DecisionAction.entries.firstOrNull {
            it.wireValue == json.optString("action")
        } ?: return null
        val actor = DecisionActor.entries.firstOrNull {
            it.wireValue == json.optString("actor")
        } ?: return null
        if (start <= 0L) return null
        return DecisionRecord(
            candidateStartSec = start,
            candidateEndSec = json.optionalLong("candidate_end_sec"),
            recordedAtSec = json.optionalLong("recorded_at_sec"),
            action = action,
            actor = actor,
            activityName = json.optionalString("activity_name"),
            detectorVersion = json.optionalString("detector_version"),
            averageBpm = json.optionalInt("average_bpm"),
            peakBpm = json.optionalInt("peak_bpm"),
            eventConfidence = json.optionalDouble("event_confidence"),
            confidenceStatus = json.optionalString("confidence_status"),
            evidenceProvenance = json.optionalString("evidence_provenance"),
            suggestedClass = json.optionalString("suggested_class"),
            suggestionConfidence = json.optionalDouble("suggestion_confidence"),
            origin = json.optString("origin", RECORDED_ORIGIN),
        )
    }

    private fun JSONObject.optionalString(key: String): String? =
        if (!has(key) || isNull(key)) null else getString(key)

    private fun JSONObject.optionalLong(key: String): Long? =
        if (!has(key) || isNull(key)) null else getLong(key)

    private fun JSONObject.optionalInt(key: String): Int? =
        if (!has(key) || isNull(key)) null else getInt(key)

    private fun JSONObject.optionalDouble(key: String): Double? =
        if (!has(key) || isNull(key)) null else getDouble(key).takeIf(Double::isFinite)

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
