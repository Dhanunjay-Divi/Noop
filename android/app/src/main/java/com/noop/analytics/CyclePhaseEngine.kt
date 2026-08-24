package com.noop.analytics

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.roundToInt

// CyclePhaseEngine.kt — on-device menstrual-cycle PHASE AWARENESS from the nightly skin-temperature series,
// corroborated by the luteal resting-HR rise and the luteal HRV drop.
// Byte-for-byte mirror of Strand/Packages/StrandAnalytics/Sources/StrandAnalytics/CyclePhaseEngine.swift.
//
// INDEPENDENT implementation of a publicly documented method (wrist skin-temperature cycle tracking,
// e.g. PMC11294004, plus the biphasic-ovulatory-shift literature): skin temperature runs ~0.3–0.5 °C
// HIGHER in the luteal phase than the follicular phase, with a nadir around ovulation, mirrored by a
// luteal RESTING-HR RISE and a luteal HRV (RMSSD) DROP. NOOP re-derives this from the user's OWN banked
// signals against their OWN baseline.
//
// WELLNESS / AWARENESS ONLY — APPROXIMATE. NOT contraception, NOT a fertility/ovulation predictor, NOT a
// medical device, NOT a diagnosis. Never a "fertile window" / "safe days", never a single confident period
// DATE (only a probabilistic WINDOW), never a condition verdict - flat/irregular → "no clear pattern".
object CyclePhaseEngine {

    // ── Tuning constants (pinned by test; mirror the Swift twin exactly) ──
    const val wTemp: Double = 0.6
    const val wRHR: Double = 0.2
    const val wHRV: Double = 0.2
    const val elevationK: Double = 0.5
    const val minCycleDays: Int = 21
    const val maxCycleDays: Int = 40
    const val defaultCycleDays: Int = 28
    const val minNightsToClassify: Int = 42
    const val periOvulatoryHalfWidth: Int = 2
    const val elevationConfirmationNights: Int = 3
    const val elevationRequiredNights: Int = 2
    const val minPersonalWindowHalfWidth: Int = 2
    const val maxPersonalWindowHalfWidth: Int = 7
    const val maxForecastableIntervalRange: Int = 12

    /** Standing awareness-only line shown on every cycle surface (legal/ethical framing). */
    const val awarenessLine =
        "For awareness only. Not a medical device, not contraception, not a substitute for professional care."

    // ── Inputs ──

    /**
     * One night's already-standardized inputs. [tempZ]/[rhrZ]/[hrvZ] are z-scores from
     * Baselines.deviation against each metric's personal baseline. [day] is a "yyyy-MM-dd" key,
     * oldest→newest in the list. A missing signal is null and doesn't contribute to that night's index.
     */
    data class Night(
        val day: String,
        val tempZ: Double?,
        val rhrZ: Double?,
        val hrvZ: Double?,
    )

    // ── Output ──

    enum class Phase(val raw: String) {
        FOLLICULAR("follicular"),
        PERI_OVULATORY("periOvulatory"),
        LUTEAL("luteal"),
        UNKNOWN("unknown"),
        LEARNING("learning"),
    }

    enum class Confidence(val raw: String) {
        LEARNING("learning"),
        BUILDING("building"),
        SOLID("solid"),
    }

    enum class NoteKind(val english: String) {
        LEARNING_NIGHTLY(
            "Learning your pattern from your nightly temperature - keep wearing it overnight.",
        ),
        NO_CLEAR_PATTERN("No clear temperature pattern yet."),
        NO_CLEAR_CONTEXT(
            "No clear temperature pattern yet - this can happen with irregular cycles, " +
                "hormonal birth control, or shift work.",
        ),
        LOG_SHIFT_MISMATCH(
            "Your temperature shift came at a different time than your logged date - " +
                "the logged start may be off.",
        ),
        PHASE_FOLLICULAR("Follicular range - temperature sitting at your baseline."),
        PHASE_MID_CYCLE("Around your mid-cycle shift - temperature is turning."),
        PHASE_LUTEAL("Luteal range - temperature is running above your baseline."),
        STALE_LOG(
            "Your last logged start is over 40 days old. Log the latest start to refresh " +
                "this estimate; NOOP will not roll an old date forward.",
        ),
        UNRELIABLE_LOGS(
            "Recent logged cycle lengths vary too much or include an interval outside the " +
                "supported range for a useful period forecast. " +
                "Cycle day still counts from your latest start.",
        ),
        FORECAST_PASSED(
            "The estimated window from your last log has passed. Log the next start when it happens; " +
                "NOOP will not roll an old date forward.",
        ),
        BROAD_PRIOR(
            "Cycle day is anchored to your logged start. The broad period window uses a 28-day prior " +
                "while nightly temperature calibration continues.",
        ),
        PERSONAL_INTERVALS(
            "Cycle day is anchored to your latest start. The period window uses your recent logged " +
                "intervals and expands with their variability.",
        ),
        START_LOGGING(
            "Log a period start and wear Noop Band overnight to begin a private estimate.",
        ),
        TURN_ON_AWARENESS(
            "Turn on cycle awareness to read a coarse phase from your nightly temperature.",
        ),
    }

    data class ShiftMarker(val day: String)

    data class NextPeriodWindow(val earliestDay: String, val latestDay: String)

    data class Result(
        val phase: Phase,
        val confidence: Confidence,
        val cycleDayLow: Int?,
        val cycleDayHigh: Int?,
        val cycleLengthDays: Int?,
        val nextPeriodWindow: NextPeriodWindow?,
        val shiftMarkers: List<ShiftMarker>,
        val note: String,
        val noteKinds: List<NoteKind> = emptyList(),
    )

    // ── Classify ──

    /**
     * Classify the most recent night from the trailing series. [baselineUsable] is the caller's
     * BaselineState.usable. [loggedPeriodStarts] are optional "yyyy-MM-dd" period-start days; the most
     * recent anchors cycle-day 1 and is CROSS-VALIDATED against the detected shift. [asOfDay] may supply
     * the current civil day so a log advances even when no wearable night exists.
     */
    fun classify(
        nights: List<Night>,
        baselineUsable: Boolean,
        loggedPeriodStarts: List<String> = emptyList(),
        asOfDay: String? = null,
    ): Result {
        // Explicit logs can anchor a bounded day range and broad period window while temperature is
        // still calibrating. They never create a sensor-derived phase.
        val fallbackAsOfDay = nights.map { it.day }.filter { parseDay(it) != null }.maxOrNull()
            ?: loggedPeriodStarts.filter { parseDay(it) != null }.maxOrNull()
        val effectiveAsOfDay = asOfDay?.takeIf { parseDay(it) != null } ?: fallbackAsOfDay
        val loggedEstimate = effectiveAsOfDay?.let {
            estimateFromLoggedStarts(loggedPeriodStarts, it)
        }

        if (!baselineUsable || nights.size < minNightsToClassify) {
            if (loggedEstimate != null) {
                return Result(
                    Phase.LEARNING,
                    Confidence.BUILDING,
                    loggedEstimate.cycleDayLow,
                    loggedEstimate.cycleDayHigh,
                    loggedEstimate.cycleLengthDays,
                    loggedEstimate.nextPeriodWindow,
                    emptyList(),
                    loggedEstimate.note,
                    listOf(loggedEstimate.noteKind),
                )
            }
            val noteKinds = listOf(NoteKind.LEARNING_NIGHTLY)
            return Result(Phase.LEARNING, Confidence.LEARNING, null, null, null, null, emptyList(),
                noteText(noteKinds), noteKinds)
        }

        val fused: List<Pair<String, Double?>> = nights.map { n ->
            n.day to fusedIndex(n.tempZ, n.rhrZ, n.hrvZ)
        }
        val values = fused.mapNotNull { it.second }
        if (values.size < minNightsToClassify) {
            if (loggedEstimate != null) {
                return Result(
                    Phase.LEARNING,
                    Confidence.BUILDING,
                    loggedEstimate.cycleDayLow,
                    loggedEstimate.cycleDayHigh,
                    loggedEstimate.cycleLengthDays,
                    loggedEstimate.nextPeriodWindow,
                    emptyList(),
                    loggedEstimate.note,
                    listOf(loggedEstimate.noteKind),
                )
            }
            val noteKinds = listOf(NoteKind.LEARNING_NIGHTLY)
            return Result(Phase.LEARNING, Confidence.LEARNING, null, null, null, null, emptyList(),
                noteText(noteKinds), noteKinds)
        }

        val center = median(values)
        val spread = maxOf(1e-9, medianAbsoluteDeviation(values, center))

        val rawElevated: List<Boolean> = fused.map { row ->
            val v = row.second ?: return@map false
            (v - center) >= elevationK * spread
        }
        val elevated: List<Boolean> = rawElevated.indices.map { index ->
            val lower = maxOf(0, index - elevationConfirmationNights + 1)
            rawElevated.subList(lower, index + 1).count { it } >= elevationRequiredNights
        }

        val onsets = mutableListOf<Int>()
        for (i in fused.indices) {
            if (elevated[i] && (i == 0 || !elevated[i - 1])) onsets.add(i)
        }
        val shiftMarkers = onsets.map { ShiftMarker(fused[it].first) }

        val lastOnsetIdx = onsets.lastOrNull() ?: run {
            if (loggedEstimate != null) {
                return Result(
                    Phase.UNKNOWN,
                    Confidence.BUILDING,
                    loggedEstimate.cycleDayLow,
                    loggedEstimate.cycleDayHigh,
                    loggedEstimate.cycleLengthDays,
                    loggedEstimate.nextPeriodWindow,
                    shiftMarkers,
                    noteText(listOf(NoteKind.NO_CLEAR_PATTERN, loggedEstimate.noteKind)),
                    listOf(NoteKind.NO_CLEAR_PATTERN, loggedEstimate.noteKind),
                )
            }
            val noteKinds = listOf(NoteKind.NO_CLEAR_CONTEXT)
            return Result(
                Phase.UNKNOWN, Confidence.BUILDING, null, null, null, null, shiftMarkers,
                noteText(noteKinds),
                noteKinds,
            )
        }

        val onsetGaps = mutableListOf<Int>()
        if (onsets.size >= 2) {
            for (k in 1 until onsets.size) {
                daysBetween(fused[onsets[k - 1]].first, fused[onsets[k]].first)?.let { onsetGaps.add(it) }
            }
        }
        val medianGap = if (onsetGaps.isEmpty()) null else median(onsetGaps.map { it.toDouble() }).roundToInt()
        val sensorCycleLength: Int? = medianGap?.takeIf { it in minCycleDays..maxCycleDays }
        val confidence = if (sensorCycleLength != null) Confidence.SOLID else Confidence.BUILDING

        val lastNightDay = fused.last().first
        var noteKinds = emptyList<NoteKind>()
        val anchorDay = fused[lastOnsetIdx].first
        val anchoredByLog = loggedEstimate?.cycleDayLow != null
        mostRecentOnOrBefore(loggedPeriodStarts, lastNightDay)
            ?.takeIf { anchoredByLog }
            ?.let { loggedStart ->
            // Implausible onset offset OR a logged start older than a full cycle before the latest night
            // (a newer period is overdue) means the log is likely mistimed — FLAG it, don't trust blindly.
            val delta = daysBetween(loggedStart, fused[lastOnsetIdx].first)
            val sinceLog = daysBetween(loggedStart, lastNightDay) ?: 0
            if ((delta != null && (delta < 0 || delta > maxCycleDays)) || sinceLog > maxCycleDays) {
                noteKinds = listOf(NoteKind.LOG_SHIFT_MISMATCH)
            }
        }

        val daysSinceAnchor = daysBetween(anchorDay, lastNightDay) ?: 0
        val cycleDayLow: Int?
        val cycleDayHigh: Int?
        if (anchoredByLog) {
            cycleDayLow = loggedEstimate?.cycleDayLow
            cycleDayHigh = loggedEstimate?.cycleDayHigh
        } else {
            val lutealStartDay = (sensorCycleLength ?: defaultCycleDays) / 2
            val d = lutealStartDay + daysSinceAnchor
            cycleDayLow = maxOf(1, d - 2); cycleDayHigh = d + 2
        }

        val daysSinceOnset = daysBetween(fused[lastOnsetIdx].first, lastNightDay) ?: 0
        val phase: Phase = if (elevated[fused.size - 1]) {
            if (daysSinceOnset <= periOvulatoryHalfWidth) Phase.PERI_OVULATORY else Phase.LUTEAL
        } else {
            if (daysSinceOnset <= periOvulatoryHalfWidth) Phase.PERI_OVULATORY else Phase.FOLLICULAR
        }

        var window: NextPeriodWindow? = loggedEstimate?.nextPeriodWindow
        if (loggedEstimate == null && sensorCycleLength != null) {
            val earliest = shiftDay(anchorDay, sensorCycleLength - 2)
            val latest = shiftDay(anchorDay, sensorCycleLength + 2)
            if (earliest != null && latest != null && latest >= lastNightDay) {
                window = NextPeriodWindow(maxOf(lastNightDay, earliest), latest)
            }
        }

        if (noteKinds.isEmpty()) {
            noteKinds = listOf(phaseNoteKind(phase))
            if (loggedEstimate?.forecastSuppressed == true) {
                noteKinds = noteKinds + loggedEstimate.noteKind
            }
        }

        val cycleLength = if (loggedEstimate != null) {
            loggedEstimate.cycleLengthDays
        } else {
            sensorCycleLength
        }
        return Result(
            phase,
            confidence,
            cycleDayLow,
            cycleDayHigh,
            cycleLength,
            window,
            shiftMarkers,
            noteText(noteKinds),
            noteKinds,
        )
    }

    // ── Fusion ──

    /** Weighted fused luteal index for one night (HRV z negated; renormalised over present signals). */
    fun fusedIndex(tempZ: Double?, rhrZ: Double?, hrvZ: Double?): Double? {
        var weighted = 0.0
        var wSum = 0.0
        if (tempZ != null) { weighted += wTemp * tempZ; wSum += wTemp }
        if (rhrZ != null) { weighted += wRHR * rhrZ; wSum += wRHR }
        if (hrvZ != null) { weighted += wHRV * (-hrvZ); wSum += wHRV }
        if (wSum <= 0) return null
        return weighted / wSum
    }

    // ── Copy ──

    internal fun phaseNote(phase: Phase): String = when (phase) {
        Phase.UNKNOWN -> "No clear pattern yet."
        Phase.LEARNING -> "Learning your pattern - keep wearing it overnight."
        else -> phaseNoteKind(phase).english
    }

    private fun phaseNoteKind(phase: Phase): NoteKind = when (phase) {
        Phase.FOLLICULAR -> NoteKind.PHASE_FOLLICULAR
        Phase.PERI_OVULATORY -> NoteKind.PHASE_MID_CYCLE
        Phase.LUTEAL -> NoteKind.PHASE_LUTEAL
        Phase.UNKNOWN -> NoteKind.NO_CLEAR_PATTERN
        Phase.LEARNING -> NoteKind.LEARNING_NIGHTLY
    }

    private fun noteText(kinds: List<NoteKind>): String = kinds.joinToString(" ") { it.english }

    // ── Logged-start estimate ──

    private data class LoggedEstimate(
        val cycleDayLow: Int?,
        val cycleDayHigh: Int?,
        val cycleLengthDays: Int?,
        val nextPeriodWindow: NextPeriodWindow?,
        val noteKind: NoteKind,
        val forecastSuppressed: Boolean,
    ) {
        val note: String get() = noteKind.english
    }

    /**
     * Bounded estimate from explicit period-start logs. One start uses a broad 28-day population prior
     * only for the window; repeated starts use the median plausible personal gap. This never emits a phase.
     */
    private fun estimateFromLoggedStarts(
        loggedPeriodStarts: List<String>,
        asOfDay: String,
    ): LoggedEstimate? {
        if (parseDay(asOfDay) == null) return null
        val starts = loggedPeriodStarts
            .filter { it <= asOfDay && parseDay(it) != null }
            .distinct()
            .sorted()
        val latestStart = starts.lastOrNull() ?: return null
        val daysSinceStart = daysBetween(latestStart, asOfDay)?.takeIf { it >= 0 } ?: return null

        val observedGaps = mutableListOf<Int>()
        for (index in 1 until starts.size) {
            val gap = daysBetween(starts[index - 1], starts[index]) ?: continue
            observedGaps.add(gap)
        }
        // Inspect the recent raw intervals before filtering. Discarding a 20- or 45-day interval can
        // make older 28-day intervals look falsely stable. It may reflect real irregularity or a missed
        // or corrected log; either interpretation is uncertainty, so suppress the forecast.
        val recentObservedGaps = observedGaps.takeLast(6)
        val recentPlausibleGaps = recentObservedGaps.filter { it in minCycleDays..maxCycleDays }
        val hasOutOfRangeRecentGap = recentPlausibleGaps.size != recentObservedGaps.size
        val cadence = recentPlausibleGaps
            .takeIf { it.isNotEmpty() }
            ?.let { median(it.map(Int::toDouble)).roundToInt() }
        val intervalRange = if (recentPlausibleGaps.isEmpty()) 0 else {
            recentPlausibleGaps.maxOrNull()!! - recentPlausibleGaps.minOrNull()!!
        }
        val forecastUnreliable = hasOutOfRangeRecentGap ||
            (recentPlausibleGaps.size >= 3 && intervalRange > maxForecastableIntervalRange)
        val personalLength = cadence?.takeUnless { forecastUnreliable }

        // Never roll an old log through guessed cycles. Ask for a fresh anchor instead.
        if (daysSinceStart >= maxCycleDays) {
            return LoggedEstimate(
                cycleDayLow = null,
                cycleDayHigh = null,
                cycleLengthDays = personalLength,
                nextPeriodWindow = null,
                noteKind = NoteKind.STALE_LOG,
                forecastSuppressed = true,
            )
        }

        val cycleDay = daysSinceStart + 1
        val cycleDayLow = maxOf(1, cycleDay - 1)
        val cycleDayHigh = cycleDay + 1
        if (forecastUnreliable) {
            return LoggedEstimate(
                cycleDayLow = cycleDayLow,
                cycleDayHigh = cycleDayHigh,
                cycleLengthDays = null,
                nextPeriodWindow = null,
                noteKind = NoteKind.UNRELIABLE_LOGS,
                forecastSuppressed = true,
            )
        }

        val forecastCadence = personalLength ?: defaultCycleDays
        val uncertainty = when {
            recentPlausibleGaps.isEmpty() || personalLength == null -> 5
            recentPlausibleGaps.size == 1 -> 4
            else -> {
                val deviations = recentPlausibleGaps.map { abs(it - personalLength) }
                val mad = median(deviations.map(Int::toDouble))
                val observed = deviations.maxOrNull() ?: 0
                val spread = maxOf(observed.toDouble(), 1.5 * mad)
                kotlin.math.ceil(spread).toInt()
                    .coerceIn(minPersonalWindowHalfWidth, maxPersonalWindowHalfWidth)
            }
        }
        val earliest = shiftDay(latestStart, forecastCadence - uncertainty)
        val latest = shiftDay(latestStart, forecastCadence + uncertainty)
        val window = if (earliest != null && latest != null && latest >= asOfDay) {
            NextPeriodWindow(maxOf(asOfDay, earliest), latest)
        } else null

        val forecastPassed = latest == null || latest < asOfDay
        val noteKind = if (forecastPassed) {
            NoteKind.FORECAST_PASSED
        } else if (personalLength == null) {
            NoteKind.BROAD_PRIOR
        } else {
            NoteKind.PERSONAL_INTERVALS
        }
        return LoggedEstimate(
            cycleDayLow = cycleDayLow,
            cycleDayHigh = cycleDayHigh,
            cycleLengthDays = personalLength,
            nextPeriodWindow = window,
            noteKind = noteKind,
            forecastSuppressed = forecastPassed,
        )
    }

    // ── Small stats / day helpers (self-contained, parity-clean) ──

    internal fun median(xs: List<Double>): Double {
        if (xs.isEmpty()) return 0.0
        val s = xs.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    internal fun medianAbsoluteDeviation(xs: List<Double>, center: Double): Double {
        if (xs.isEmpty()) return 0.0
        return median(xs.map { abs(it - center) })
    }

    /** Calendar days from [a] to [b] ("yyyy-MM-dd"), b − a. null if unparseable. UTC, pure. */
    internal fun daysBetween(a: String, b: String): Int? {
        val da = parseDay(a) ?: return null
        val db = parseDay(b) ?: return null
        return (db.toEpochDay() - da.toEpochDay()).toInt()
    }

    /** Most recent entry in [days] on or before [day] (ISO string compare is valid). */
    internal fun mostRecentOnOrBefore(days: List<String>, day: String): String? =
        days.filter { it <= day }.maxOrNull()

    internal fun parseDay(day: String): LocalDate? = runCatching { LocalDate.parse(day) }.getOrNull()

    /** Shift a "yyyy-MM-dd" by [delta] days. UTC, deterministic. null if unparseable. */
    internal fun shiftDay(day: String, delta: Int): String? =
        parseDay(day)?.plusDays(delta.toLong())?.toString()
}
