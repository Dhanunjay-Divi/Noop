package com.noop.analytics

import java.util.Locale

/**
 * Conservative, local-only classification for calendar titles.
 *
 * Callers discard the title immediately after this boolean decision. Ambiguous work-oriented titles
 * fail closed so a meeting called "training" cannot become a health-planning signal.
 */
object PlannedWorkoutTitleClassifier {
    private val directActivityTokens = setOf(
        "workout", "gym", "exercise", "hiit", "crossfit", "pilates", "yoga", "barre",
        "cardio", "lifting", "weights", "run", "running", "jog", "jogging", "ride",
        "cycling", "bike", "swim", "swimming", "hike", "hiking", "rowing", "boxing",
        "tennis", "soccer", "football", "basketball", "volleyball", "climbing", "spin",
        "bootcamp",
    )
    private val fitnessContextTokens = setOf(
        "strength", "fitness", "marathon", "triathlon", "race", "5k", "10k",
    )
    private val workContextTokens = setOf(
        "meeting", "interview", "webinar", "workshop", "conference", "standup",
        "onboarding", "presentation", "planning", "demo", "review", "sync", "project",
    )
    private val nonParticipationContextTokens = setOf(
        "repair", "service", "shop", "shopping", "watch", "party", "ticket", "tickets",
        "viewing",
    )
    private val excludedPhrases = listOf(
        "run errands", "school run", "coffee run", "dry run", "test run",
    )

    fun isWorkoutTitle(title: String?): Boolean {
        val tokens = title
            ?.lowercase(Locale.ROOT)
            ?.split(Regex("[^\\p{L}\\p{N}]+"))
            ?.filter { it.isNotEmpty() }
            .orEmpty()
        if (tokens.isEmpty()) return false

        val normalized = tokens.joinToString(" ")
        if (excludedPhrases.any(normalized::contains)) return false

        val tokenSet = tokens.toSet()
        if (tokenSet.any(workContextTokens::contains)) return false
        if (tokenSet.any(nonParticipationContextTokens::contains)) return false
        if (tokenSet.any(directActivityTokens::contains)) return true
        return "training" in tokenSet && tokenSet.any(fitnessContextTokens::contains)
    }
}
