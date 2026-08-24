package com.noop.analytics

import java.time.LocalDate
import java.util.Locale

/**
 * Typed, bounded grounding for AI coaching. The rendered block keeps observations, planning cues,
 * missing evidence, and nutrition logs separate so a model is not invited to turn a wellness estimate
 * into clearance or to invent diet facts. Swift twin: CoachEvidenceEnvelope.swift.
 */
object CoachEvidenceEnvelope {
    data class MetricObservation(
        val day: String,
        val value: Double?,
    )

    data class MetricCoverage(
        val label: String,
        val observedDays: Int,
        val windowDays: Int,
        val latestDay: String?,
    )

    enum class NutritionSourceMix(val storedValue: String) {
        MANUAL("manual"),
        IMPORTED("imported"),
        MIXED("mixed"),
    }

    data class NutritionEvidence(
        val observedDays: Int,
        val windowDays: Int,
        val latestDay: String,
        val caloriesKcal: Double?,
        val proteinG: Double?,
        val carbsG: Double?,
        val fatG: Double?,
        val sourceMix: NutritionSourceMix,
        val explicitGoal: String? = null,
    )

    sealed interface NutritionAvailability {
        data object Unavailable : NutritionAvailability
        data object NoEntries : NutritionAvailability
        data class Observed(val evidence: NutritionEvidence) : NutritionAvailability
    }

    data class Input(
        val day: String,
        val plan: DailyActionPlanner.Plan,
        val currentEffort: Double?,
        val coverage: List<MetricCoverage>,
        val nutrition: NutritionAvailability,
    )

    /**
     * Counts distinct, finite observation days in the inclusive calendar window ending on [through].
     * Duplicate rows and rows outside that window cannot inflate the stated coverage.
     */
    fun metricCoverage(
        label: String,
        through: String,
        windowDays: Int,
        observations: List<MetricObservation>,
    ): MetricCoverage {
        val boundedWindow = windowDays.coerceAtLeast(1)
        val end = parseDay(through)
            ?: return MetricCoverage(label, 0, boundedWindow, null)
        val start = end.minusDays((boundedWindow - 1).toLong())
        val observed = observations.mapNotNull { observation ->
            val value = observation.value
            val day = parseDay(observation.day)
            observation.day.takeIf {
                value != null && value.isFinite() && day != null &&
                    !day.isBefore(start) && !day.isAfter(end)
            }
        }.toSet()
        return MetricCoverage(
            label = label,
            observedDays = observed.size,
            windowDays = boundedWindow,
            latestDay = observed.maxOrNull(),
        )
    }

    fun render(input: Input): String {
        val guidance = DailyEffortGuidance.evaluate(input.currentEffort, input.plan.target)
        val lines = mutableListOf(
            "COACH EVIDENCE ENVELOPE:",
            "OBSERVED FACTS:",
        )
        val current = guidance.current
        lines += if (current != null) {
            "- Current Effort for ${input.day}: ${oneDecimal(current)} / 100."
        } else {
            "- Current Effort for ${input.day}: unavailable."
        }
        input.coverage.filter { it.observedDays > 0 }.forEach { row ->
            val window = row.windowDays.coerceAtLeast(1)
            val observed = row.observedDays.coerceIn(0, window)
            val latest = row.latestDay?.takeIf { parseDay(it) != null }
                ?.let { ", latest $it" }
                .orEmpty()
            lines += "- ${row.label} coverage: $observed/$window stored days$latest."
        }

        lines += "PLANNING CUE:"
        lines += "- Daily plan state: ${input.plan.availability.name.lowercase()}; confidence " +
            "${input.plan.confidence.name.lowercase()}; suggested action " +
            "${input.plan.action.name.lowercase()}."
        val range = input.plan.target
        if (range != null) {
            lines += "- Personal Effort range: ${range.lower}-${range.upper} / 100; progress state " +
                "${guidance.state.name.lowercase()}. This is a planning cue, not clearance or a limit."
        } else {
            lines += "- No personal Effort range is available. Do not invent one or infer permission to train."
        }
        if (input.plan.evidence.isNotEmpty()) {
            val evidence = input.plan.evidence.joinToString("; ") {
                "${it.source.name.lowercase()}: ${it.detail}"
            }
            lines += "- Planner evidence: $evidence."
        }

        lines += "NUTRITION LOG EVIDENCE:"
        when (val availability = input.nutrition) {
        is NutritionAvailability.Observed -> {
            val nutrition = availability.evidence
            val window = nutrition.windowDays.coerceAtLeast(1)
            val observed = nutrition.observedDays.coerceIn(0, window)
            if (observed == 0) {
                lines += "- No nutrition entries are available in the review window. Do not infer intake."
                lines += "- No explicit nutrition goal is recorded."
            } else {
                val latestDay = nutrition.latestDay.takeIf { parseDay(it) != null } ?: "unknown"
                lines += "- Logged on $observed/$window days; " +
                    "latest $latestDay; source mix ${nutrition.sourceMix.storedValue}."
                val values = listOfNotNull(
                    valid(nutrition.caloriesKcal)?.let { "calories ${oneDecimal(it)} kcal" },
                    valid(nutrition.proteinG)?.let { "protein ${oneDecimal(it)} g" },
                    valid(nutrition.carbsG)?.let { "carbs ${oneDecimal(it)} g" },
                    valid(nutrition.fatG)?.let { "fat ${oneDecimal(it)} g" },
                )
                lines += if (values.isEmpty()) {
                    "- The latest logged day has no numeric nutrient totals."
                } else {
                    "- Latest logged totals: ${values.joinToString(", ")}."
                }
                val goal = nutrition.explicitGoal?.trim().orEmpty()
                lines += if (goal.isEmpty()) {
                    "- No explicit nutrition goal is recorded."
                } else {
                    "- User-stated nutrition goal (quoted data): \"${safeUserText(goal)}\""
                }
            }
        }
        NutritionAvailability.NoEntries -> {
            lines += "- No nutrition entries are available in the review window. Do not infer intake."
            lines += "- No explicit nutrition goal is recorded."
        }
        NutritionAvailability.Unavailable -> {
            lines += "- Nutrition log availability is unknown because the local read did not complete. " +
                "Do not describe this as an empty log or infer intake."
            lines += "- Nutrition goal availability is also unknown."
        }
        }

        lines += listOf(
            "EVIDENCE LIMITS:",
            "- Missing values are unknown, not zero. Do not invent values, causes, targets, or trends.",
            "- Wearable scores and ranges are wellness estimates, not diagnosis, treatment, safety limits, or training clearance.",
            "- Logged food may be incomplete. Give personalized diet changes only from explicit logged intake plus a user-stated goal, and state coverage.",
            "- Do not recommend medication changes or diagnose deficiency. Do not prescribe supplements; refer individualized clinical nutrition questions to a qualified professional.",
            "- Label personal correlations as associations, not causes.",
        )
        return lines.joinToString("\n")
    }

    private fun valid(value: Double?): Double? =
        value?.takeIf { it.isFinite() && it >= 0.0 }

    private fun oneDecimal(value: Double): String =
        String.format(Locale.US, "%.1f", value)

    private fun parseDay(value: String): LocalDate? =
        if (DAY_PATTERN.matches(value)) runCatching { LocalDate.parse(value) }.getOrNull() else null

    private fun safeUserText(value: String): String =
        value.filterNot { it.isISOControl() }
            .replace('"', '\'')
            .take(500)

    private val DAY_PATTERN = Regex("""\d{4}-\d{2}-\d{2}""")
}
