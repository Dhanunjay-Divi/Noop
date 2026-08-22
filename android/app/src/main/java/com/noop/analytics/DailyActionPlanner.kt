package com.noop.analytics

import java.time.LocalDate
import kotlin.math.ceil
import kotlin.math.floor

/**
 * Conservative daily planning contract. A wearable read never grants permission to train.
 *
 * A numeric range requires an "as usual" same-day self-check, a solid multi-signal readiness read,
 * and enough prior scored Effort days to describe the user's own normal range. PRIMED never raises
 * the range; readiness is a confidence gate, not a load bonus. Swift twin: DailyActionPlanner.swift.
 */
object DailyActionPlanner {
    enum class CheckIn(val storedValue: String) {
        UNANSWERED("unanswered"),
        AS_USUAL("asUsual"),
        BELOW_USUAL("belowUsual"),
        PAIN_OR_UNWELL("painOrUnwell");

        companion object {
            fun fromStoredValue(raw: String?): CheckIn? = entries.firstOrNull { it.storedValue == raw }
        }
    }
    enum class Availability { READY, CHECK_IN_NEEDED, CALIBRATING, RECOVERY_SHIFT, STOP }
    enum class Action {
        COMPLETE_CHECK_IN, KEEP_SLEEP_WINDOW, PROTECT_EXTRA_SLEEP, CHOOSE_EASY_DAY, STOP_AND_ASSESS,
    }
    enum class EvidenceSource { SELF_CHECK, READINESS_BASELINE, PERSONAL_EFFORT_HISTORY, SLEEP_PLAN }

    data class EffortDay(val day: String, val effort: Double?)
    data class EffortRange(val lower: Int, val upper: Int)
    data class Evidence(val source: EvidenceSource, val detail: String)
    data class Plan(
        val day: String,
        val availability: Availability,
        /** Personal planning range on NOOP's canonical 0-100 Effort scale. */
        val target: EffortRange?,
        val confidence: ScoreConfidence,
        val action: Action,
        val evidence: List<Evidence>,
        val limitations: List<String>,
    )

    const val HISTORY_WINDOW_DAYS = 28
    const val MINIMUM_EFFORT_DAYS = 7
    const val SOLID_EFFORT_DAYS = 14
    const val EXTRA_SLEEP_ACTION_THRESHOLD_MINUTES = 30

    private const val planningLimitation =
        "This is a personal planning range, not a safety limit, diagnosis, or medical clearance."

    fun plan(
        today: String,
        readiness: ReadinessEngine.Readiness,
        checkIn: CheckIn,
        recentEffort: List<EffortDay>,
        sleepRecoveryMinutes: Int = 0,
        sleepConfidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
    ): Plan {
        val selfEvidence = Evidence(EvidenceSource.SELF_CHECK, checkIn.storedValue)

        if (checkIn == CheckIn.PAIN_OR_UNWELL) {
            return Plan(
                today, Availability.STOP, null, ScoreConfidence.CALIBRATING, Action.STOP_AND_ASSESS,
                listOf(selfEvidence),
                listOf(planningLimitation, "A symptom or pain check-in always overrides wearable data."),
            )
        }
        if (checkIn == CheckIn.UNANSWERED) {
            return Plan(
                today, Availability.CHECK_IN_NEEDED, null, ScoreConfidence.CALIBRATING,
                Action.COMPLETE_CHECK_IN, emptyList(),
                listOf(planningLimitation, "A same-day self-check is required before showing a range."),
            )
        }
        if (checkIn == CheckIn.BELOW_USUAL) {
            return Plan(
                today, Availability.RECOVERY_SHIFT, null, ScoreConfidence.CALIBRATING,
                Action.CHOOSE_EASY_DAY, listOf(selfEvidence),
                listOf(planningLimitation, "How you feel takes priority over an aligned wearable read."),
            )
        }
        if (readiness.asOfDay != today) {
            return Plan(
                today, Availability.CALIBRATING, null, ScoreConfidence.CALIBRATING,
                Action.KEEP_SLEEP_WINDOW, listOf(selfEvidence),
                listOf(planningLimitation, "No current readiness read is available for this date."),
            )
        }

        val recoverySignals = readiness.signals.filter {
            it.key == "hrv" || it.key == "rhr" || it.key == "respRate"
        }
        val readinessEvidence = Evidence(
            EvidenceSource.READINESS_BASELINE,
            "${recoverySignals.size} current signals, ${readiness.baselineDays} prior days",
        )
        if (readiness.level == ReadinessEngine.Level.STRAINED ||
            readiness.level == ReadinessEngine.Level.RUNDOWN
        ) {
            return Plan(
                today, Availability.RECOVERY_SHIFT, null, readiness.confidence, Action.CHOOSE_EASY_DAY,
                listOf(selfEvidence, readinessEvidence),
                listOf(
                    planningLimitation,
                    "A measured recovery shift withholds the range; it does not diagnose a cause.",
                ),
            )
        }
        if (readiness.confidence != ScoreConfidence.SOLID ||
            (readiness.level != ReadinessEngine.Level.BALANCED &&
                readiness.level != ReadinessEngine.Level.PRIMED)
        ) {
            return Plan(
                today, Availability.CALIBRATING, null, readiness.confidence, Action.KEEP_SLEEP_WINDOW,
                listOf(selfEvidence, readinessEvidence),
                listOf(
                    planningLimitation,
                    "At least two current signals and a trusted personal baseline are required.",
                ),
            )
        }

        val values = effortValues(recentEffort, today)
        val effortEvidence = Evidence(
            EvidenceSource.PERSONAL_EFFORT_HISTORY,
            "${values.size} scored days in the prior $HISTORY_WINDOW_DAYS days",
        )
        val target = planningRange(values)
        if (values.size < MINIMUM_EFFORT_DAYS || target == null) {
            return Plan(
                today, Availability.CALIBRATING, null, ScoreConfidence.CALIBRATING,
                Action.KEEP_SLEEP_WINDOW, listOf(selfEvidence, readinessEvidence, effortEvidence),
                listOf(
                    planningLimitation,
                    "At least $MINIMUM_EFFORT_DAYS prior scored Effort days are required.",
                ),
            )
        }

        val boundedSleepRecovery = sleepRecoveryMinutes.coerceIn(0, 60)
        val supportedExtraSleep =
            boundedSleepRecovery >= EXTRA_SLEEP_ACTION_THRESHOLD_MINUTES &&
                sleepConfidence != ScoreConfidence.CALIBRATING
        val evidence = mutableListOf(selfEvidence, readinessEvidence, effortEvidence)
        if (supportedExtraSleep) {
            evidence += Evidence(
                EvidenceSource.SLEEP_PLAN,
                "$boundedSleepRecovery min recovery addition",
            )
        }
        return Plan(
            today,
            Availability.READY,
            target,
            if (values.size >= SOLID_EFFORT_DAYS) ScoreConfidence.SOLID else ScoreConfidence.BUILDING,
            if (supportedExtraSleep) Action.PROTECT_EXTRA_SLEEP else Action.KEEP_SLEEP_WINDOW,
            evidence,
            listOf(
                planningLimitation,
                "Aligned readiness never raises the range above the user's recent normal Effort.",
            ),
        )
    }

    /** One deterministic value per prior calendar day in [today-28, today-1]. */
    internal fun effortValues(days: List<EffortDay>, before: String): List<Double> {
        val end = runCatching { LocalDate.parse(before).takeIf { it.toString() == before } }.getOrNull()
            ?: return emptyList()
        val start = end.minusDays(HISTORY_WINDOW_DAYS.toLong()).toString()
        val grouped = mutableMapOf<String, MutableList<Double>>()
        for (row in days) {
            if (row.day < start || row.day >= before) continue
            val parsed = runCatching {
                LocalDate.parse(row.day).takeIf { it.toString() == row.day }
            }.getOrNull() ?: continue
            if (parsed.isBefore(end.minusDays(HISTORY_WINDOW_DAYS.toLong())) || !parsed.isBefore(end)) continue
            val effort = row.effort
            if (effort == null || !effort.isFinite() || effort !in 0.0..100.0) continue
            grouped.getOrPut(row.day) { mutableListOf() }.add(effort)
        }
        return grouped.keys.sorted().map { day -> grouped.getValue(day).average() }
    }

    internal fun planningRange(values: List<Double>): EffortRange? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        var lower = (floor(quantile(sorted, 0.25) / 5.0) * 5.0).toInt()
        var upper = (ceil(quantile(sorted, 0.75) / 5.0) * 5.0).toInt()
        if (upper - lower < 10) {
            val center = quantile(sorted, 0.5)
            lower = (floor((center - 5.0) / 5.0) * 5.0).toInt()
            upper = (ceil((center + 5.0) / 5.0) * 5.0).toInt()
        }
        lower = lower.coerceIn(0, 100)
        upper = upper.coerceIn(0, 100)
        if (upper - lower < 10) {
            if (lower == 0) {
                upper = minOf(100, lower + 10)
            } else if (upper == 100) {
                lower = maxOf(0, upper - 10)
            } else {
                upper = minOf(100, lower + 10)
            }
        }
        return EffortRange(lower, upper)
    }

    internal fun quantile(sorted: List<Double>, q: Double): Double {
        if (sorted.size <= 1) return sorted.firstOrNull() ?: 0.0
        val position = q.coerceIn(0.0, 1.0) * (sorted.size - 1)
        val lower = floor(position).toInt()
        val upper = minOf(lower + 1, sorted.lastIndex)
        val fraction = position - lower
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}
