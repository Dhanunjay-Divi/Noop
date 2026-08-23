package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import kotlin.math.sqrt

/*
 * AutoWorkoutDetector.kt - MVP retroactive "did you just work out?" detector.
 *
 * Faithful Kotlin port of StrandAnalytics/AutoWorkoutDetector.swift — the two MUST stay
 * BYTE-PARITY on the detection logic (same thresholds, same span/merge/overlap rules,
 * same outputs), verified by the mirrored unit tests on each platform.
 *
 * This is DELIBERATELY SEPARATE from [WorkoutDetector] (the internal scoring detector). This one is the
 * canonical PURE detector. This component never performs I/O; the app-level Off / Ask policy decides
 * whether a candidate is ignored or shown for approval. A dormant legacy path remains fail-closed until
 * confidence is field-calibrated.
 *
 * The thresholds here are intentionally CONSERVATIVE (low sensitivity): a sustained ≥10-min
 * elevation of HR ≥ resting+30 bpm, brief (≤90 s) dips tolerated, and only short workout
 * fragments (≤5 min apart) merged. A window
 * is offered only after the stream contains >90 s of post-session quiet; an elevated span at the
 * end of the available data is still in progress and is never suggested. This
 * is tuned to avoid false positives from stress / caffeine / a brief flight of stairs, at the
 * cost of missing the odd short or gentle session — exactly right for a SUGGESTION you can
 * decline. An OPTIONAL continuous motion signal, when one is readily available, is required as
 * confirmation; with no motion series it runs HR-only.
 *
 * Pure / headless: no Android, no I/O, no clock. Inputs are the Room entities
 * com.noop.data.HrSample (ts:Long seconds, bpm:Int) and com.noop.data.GravitySample
 * (ts:Long seconds, x/y/z:Double). All ts/start/end are unix SECONDS as Long. NOT medical advice.
 */
object AutoWorkoutDetector {

    // ---- Constants (keep byte-identical with the Swift twin) ----

    /** Bump whenever rules or data-quality gates change; never infer a probability from this label. */
    const val detectorVersion: String = "noop-auto-workout-v1"

    /** Elevated gate: bpm must be at least restingHR + this margin to count as "working". */
    const val elevatedMarginBPM: Int = 30

    /**
     * Local candidate floor. Current WHOOP support pages describe 10- and 12-minute minimums in
     * different troubleshooting contexts, so NOOP documents its own fixed ten-minute rule explicitly.
     */
    const val minSustainedMin: Double = 10.0

    /** A dip below the gate no longer than this does NOT break the span (a red light, a sip of water). */
    const val maxDipS: Long = 90L

    /**
     * Conservative local fragment rule. Five minutes can join a short interval/rest break, while the
     * previous one-hour value could combine genuinely separate workouts and had no documented WHOOP
     * provenance.
     */
    const val mergeGapS: Long = 5L * 60L

    /**
     * When an OPTIONAL continuous motion series is supplied, a window must ALSO show elevated motion
     * to qualify (confirmation). "Elevated motion" = the window's mean per-second motion intensity
     * (L2 gravity-delta) is at least this. Mirrors the motion gate scale used by [WorkoutDetector].
     * Ignored entirely when no motion series is passed (HR-only mode).
     */
    const val motionConfirmMean: Double = 0.05

    /** Sparse motion cannot honestly veto an otherwise-valid HR candidate. */
    const val motionConfirmationMinSamples: Int = 30
    const val motionConfirmationMinSpanS: Long = 60L
    const val motionConfirmationMaxGapS: Long = 60L

    const val maxHRSampleGapS: Long = 60L
    const val minHRSamples: Int = 60
    const val maxSecondsPerHRSample: Long = 15L

    /** Resting-HR fallback when the caller has no nightly RHR for the day. */
    const val defaultRestingHR: Int = 60

    internal fun effectiveRestingBPM(restingHR: Int?, hr: List<HrSample>): Int {
        if (restingHR != null && restingHR in 30..120) return restingHR
        val values = hr.map { it.bpm }.filter { it in 30..220 }.sorted()
        if (values.isEmpty()) return defaultRestingHR
        val index = kotlin.math.floor((values.size - 1) * 0.10).toInt()
        return values[index].coerceIn(defaultRestingHR, 100)
    }

    internal fun hasSufficientHRCoverage(window: List<HrSample>, start: Long, end: Long): Boolean {
        if (end <= start) return false
        val ordered = cleanHR(window)
        val spanSeconds = end.toDouble() - start.toDouble()
        if (!spanSeconds.isFinite() || spanSeconds <= 0.0 ||
            spanSeconds > Int.MAX_VALUE.toDouble() * maxSecondsPerHRSample.toDouble()) return false
        val required = maxOf(
            minHRSamples,
            kotlin.math.ceil(spanSeconds / maxSecondsPerHRSample.toDouble()).toInt(),
        )
        if (ordered.size < required) return false
        return ordered.zipWithNext().all { (a, b) ->
            b.ts.toDouble() - a.ts.toDouble() <= maxHRSampleGapS.toDouble()
        }
    }

    enum class EvidenceProvenance(val wireValue: String) {
        HEART_RATE_ONLY("heart_rate_only"),
        HEART_RATE_AND_MOTION("heart_rate_and_motion"),
    }

    enum class ConfidenceStatus {
        UNCALIBRATED;

        /** Adding a validated status requires an explicit unattended-save decision here. */
        val permitsUnattendedSave: Boolean
            get() = when (this) {
                UNCALIBRATED -> false
            }
    }
    enum class TypeSuggestionStatus { UNKNOWN, SUGGESTED }

    /**
     * A detected workout window. All fields are derived purely from the HR samples inside the window.
     * `startSec`/`endSec` are unix seconds; `avgBpm`/`peakBpm` are rounded; `durationMin` is whole minutes.
     * Mirrors the Swift `DetectedWorkout` struct field-for-field.
     */
    data class DetectedWorkout(
        val startSec: Long,
        val endSec: Long,
        val avgBpm: Int,
        val peakBpm: Int,
        val durationMin: Int,
        /** Advisory broad-type hint attached after detection; null means the evidence was unclear. */
        val suggestedClass: CoarseWorkoutClass? = null,
        /** Confidence in the optional broad-type hint, not confidence that a workout happened. */
        val suggestionConfidence: Double? = null,
        val detectorVersion: String = AutoWorkoutDetector.detectorVersion,
        /** Intentionally null until held-out validation calibrates this rules engine. */
        val eventConfidence: Double? = null,
        val confidenceStatus: ConfidenceStatus = ConfidenceStatus.UNCALIBRATED,
        val evidenceProvenance: EvidenceProvenance = EvidenceProvenance.HEART_RATE_ONLY,
    ) {
        val typeSuggestionStatus: TypeSuggestionStatus
            get() = if (suggestedClass == null) TypeSuggestionStatus.UNKNOWN else TypeSuggestionStatus.SUGGESTED
    }

    sealed interface MotionConfirmation {
        data object Unavailable : MotionConfirmation
        data class Confirmed(val mean: Double) : MotionConfirmation
        data class Rejected(val mean: Double) : MotionConfirmation
    }

    /**
     * Require at least 30 motion points spanning the smaller of five minutes or one quarter of the
     * candidate. Missing/sparse motion returns [MotionConfirmation.Unavailable] and cannot veto HR.
     */
    internal fun motionConfirmation(
        motion: Map<Long, Double>,
        start: Long,
        end: Long,
    ): MotionConfirmation {
        if (end <= start) return MotionConfirmation.Unavailable
        val inWindow = motion.entries.filter { it.key in start..end && it.value.isFinite() }.sortedBy { it.key }
        if (inWindow.size < motionConfirmationMinSamples) return MotionConfirmation.Unavailable
        val spanSeconds = end.toDouble() - start.toDouble()
        val requiredSpan = minOf(5.0 * 60.0, maxOf(motionConfirmationMinSpanS.toDouble(), spanSeconds / 4.0))
        if (inWindow.last().key.toDouble() - inWindow.first().key.toDouble() < requiredSpan) {
            return MotionConfirmation.Unavailable
        }
        if (inWindow.zipWithNext().any { (a, b) ->
                b.key.toDouble() - a.key.toDouble() > motionConfirmationMaxGapS.toDouble()
            }) return MotionConfirmation.Unavailable
        val mean = inWindow.sumOf { it.value } / inWindow.size.toDouble()
        return if (mean >= motionConfirmMean) MotionConfirmation.Confirmed(mean)
        else MotionConfirmation.Rejected(mean)
    }

    /** Sorted (ts, bpm) HR pairs, ascending by ts. */
    internal fun cleanHR(hr: List<HrSample>): List<HrSample> = hr
        .asSequence()
        .filter { it.bpm in 30..220 }
        .groupBy { it.ts }
        .map { (_, samples) -> samples.minBy { it.bpm } }
        .sortedBy { it.ts }

    /**
     * Per-second motion intensity = L2 magnitude of the gravity change vs the previous record.
     * First row → 0. Returns a ts→intensity map for O(1) window lookups. Empty input → empty map.
     */
    internal fun motionIntensityByTs(gravity: List<GravitySample>): Map<Long, Double> {
        if (gravity.isEmpty()) return emptyMap()
        val rows = gravity.filter { it.x.isFinite() && it.y.isFinite() && it.z.isFinite() }
            .sortedBy { it.ts }
        val out = LinkedHashMap<Long, Double>(rows.size)
        var prev: GravitySample? = null
        for ((i, row) in rows.withIndex()) {
            val p = prev
            val intensity = if (i == 0 || p == null) {
                0.0
            } else if (row.ts.toDouble() - p.ts.toDouble() <= motionConfirmationMaxGapS.toDouble()) {
                val dx = row.x - p.x
                val dy = row.y - p.y
                val dz = row.z - p.z
                sqrt(dx * dx + dy * dy + dz * dz)
            } else 0.0
            out[row.ts] = intensity
            prev = row
        }
        return out
    }

    /** A telemetry gap abandons an open span; missing wall-clock time never counts as activity. */
    internal fun finalizedElevatedSpans(seg: List<HrSample>, floor: Int): List<Pair<Long, Long>> {
        val spans = ArrayList<Pair<Long, Long>>()
        var spanStart: Long? = null
        var spanEnd = 0L
        var dipStart: Long? = null
        var previousTimestamp: Long? = null

        fun closeSpan() {
            val s = spanStart
            if (s != null && spanEnd.toDouble() - s.toDouble() >= minSustainedMin * 60.0) {
                spans.add(s to spanEnd)
            }
            spanStart = null
            dipStart = null
        }

        for (sample in seg) {
            val previous = previousTimestamp
            if (previous != null &&
                sample.ts.toDouble() - previous.toDouble() > maxHRSampleGapS.toDouble()) {
                spanStart = null
                dipStart = null
            }
            previousTimestamp = sample.ts

            if (sample.bpm >= floor) {
                if (spanStart == null) spanStart = sample.ts
                spanEnd = sample.ts
                dipStart = null
            } else if (spanStart != null) {
                val d = dipStart ?: sample.ts.also { dipStart = it }
                if (sample.ts.toDouble() - d.toDouble() > maxDipS.toDouble()) closeSpan()
            }
        }
        return spans
    }

    internal fun mergeSpans(spans: List<Pair<Long, Long>>): List<Pair<Long, Long>> {
        if (spans.isEmpty()) return emptyList()
        val merged = ArrayList<Pair<Long, Long>>()
        var curStart = spans[0].first
        var curEnd = spans[0].second
        for (next in spans.drop(1)) {
            if (next.first.toDouble() - curEnd.toDouble() <= mergeGapS.toDouble()) {
                curEnd = maxOf(curEnd, next.second)
            } else {
                merged.add(curStart to curEnd)
                curStart = next.first
                curEnd = next.second
            }
        }
        merged.add(curStart to curEnd)
        return merged
    }

    /**
     * Detect candidate sustained-elevated-HR workout windows.
     *
     * Algorithm (kept byte-identical with the Swift twin):
     *  1. Sort HR ascending. Floor = restingHR + [elevatedMarginBPM]. Walk the samples; a sample is
     *     "elevated" when bpm >= floor.
     *  2. Grow a contiguous span across elevated samples. A run of NON-elevated samples is tolerated
     *     (does not end the span) ONLY while the dip's wall-clock duration stays <= [maxDipS]; a longer
     *     dip closes the span. The span's [start, end] are the first/last ELEVATED sample timestamps.
     *  3. Keep a span only when it lasts >= [minSustainedMin] AND a later below-threshold quiet tail
     *     exceeds [maxDipS]. An open span at end-of-input is still in progress and is not emitted.
     *  4. Merge two kept spans when the gap between them is <= [mergeGapS].
     *  5. If a motion series is supplied, drop a window unless its mean motion intensity over the window
     *     is >= [motionConfirmMean] (confirmation). With no motion series, HR-only — keep it.
     *  6. Drop a window that OVERLAPS any [savedWorkouts] [start, end] span (never re-suggest a logged one).
     *  7. Emit a [DetectedWorkout] per surviving window (avg/peak bpm + whole-minute duration).
     *
     * @param hr the day's (or last day or two's) HR samples; any order; empty → [].
     * @param restingHR the nightly resting HR for the day; null → [defaultRestingHR] (60).
     * @param gravity OPTIONAL continuous motion series for confirmation; empty/omitted → HR-only.
     * @param savedWorkouts already-saved workout windows as (startSec, endSec) pairs to exclude by overlap.
     */
    fun detect(
        hr: List<HrSample>,
        restingHR: Int? = null,
        gravity: List<GravitySample> = emptyList(),
        savedWorkouts: List<Pair<Long, Long>> = emptyList(),
    ): List<DetectedWorkout> {
        val seg = cleanHR(hr)
        if (seg.isEmpty()) return emptyList()

        val floor = effectiveRestingBPM(restingHR, seg) + elevatedMarginBPM

        // --- 1+2+3: grow sustained spans tolerating brief dips ---
        // A span is [spanStart, spanEnd] over ELEVATED-sample timestamps. `dipStart` marks where the
        // current sub-threshold run began (0 = not in a dip); a dip longer than maxDipS closes the span.
        val spans = finalizedElevatedSpans(seg, floor)
        // Deliberately DO NOT close an open span at end-of-input. Until a below-threshold tail lasts
        // longer than maxDipS, the workout may still be in progress and its endpoint is not stable.
        // The next scan will close it once enough post-session HR has arrived.

        if (spans.isEmpty()) return emptyList()

        // --- 4: merge spans whose gap is <= mergeGapS (spans are start-ascending by build) ---
        val merged = mergeSpans(spans)

        // --- 5+6+7 ---
        val motion = if (gravity.isEmpty()) emptyMap() else motionIntensityByTs(gravity)
        val results = ArrayList<DetectedWorkout>()
        for ((start, end) in merged) {
            // 6: never re-suggest a window overlapping an already-saved workout.
            if (savedWorkouts.any { overlaps(start, end, it.first, it.second) }) continue

            val window = seg.filter { it.ts in start..end }
            if (window.isEmpty()) continue
            if (!hasSufficientHRCoverage(window, start, end)) continue

            // 5: sufficiently-covered motion can confirm or reject. Sparse motion falls back to HR-only.
            val motionVerdict = if (motion.isEmpty()) MotionConfirmation.Unavailable
                else motionConfirmation(motion, start, end)
            if (motionVerdict is MotionConfirmation.Rejected) continue
            val provenance = if (motionVerdict is MotionConfirmation.Confirmed) {
                EvidenceProvenance.HEART_RATE_AND_MOTION
            } else EvidenceProvenance.HEART_RATE_ONLY

            val bpms = window.map { it.bpm }
            val avg = Math.round(bpms.sum().toDouble() / bpms.size.toDouble()).toInt()
            // window is non-empty so max() always exists; `?: avg` mirrors the Swift twin's fallback exactly.
            val peak = bpms.maxOrNull() ?: avg
            val durMin = ((end.toDouble() - start.toDouble()) / 60.0).toInt()
            results.add(DetectedWorkout(startSec = start, endSec = end, avgBpm = avg, peakBpm = peak,
                durationMin = durMin, evidenceProvenance = provenance))
        }
        return results
    }

    /** Two closed [aStart, aEnd] / [bStart, bEnd] intervals overlap (touching endpoints count). */
    internal fun overlaps(aStart: Long, aEnd: Long, bStart: Long, bEnd: Long): Boolean =
        aStart <= bEnd && bStart <= aEnd
}
