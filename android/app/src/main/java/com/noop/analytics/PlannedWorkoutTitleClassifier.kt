package com.noop.analytics

import java.text.Normalizer
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
        "cardio", "lifting", "weights", "jog", "jogging", "ride",
        "cycling", "bike", "swim", "swimming", "hike", "hiking", "rowing", "boxing",
        "tennis", "soccer", "football", "basketball", "volleyball", "climbing",
        "bootcamp",
        // German
        "fitnessstudio", "schwimmen", "radfahren", "joggen", "wandern", "rudern",
        "boxen", "klettern", "krafttraining",
        // Spanish
        "gimnasio", "ejercicio", "natacion", "ciclismo", "correr", "senderismo",
        "remo", "boxeo", "escalada",
        // French
        "musculation", "natation", "cyclisme", "velo", "randonnee", "aviron",
        "boxe", "escalade",
        // Italian
        "palestra", "esercizio", "nuoto", "corsa", "escursione", "canottaggio",
        "pugilato",
        // Portuguese
        "ginasio", "exercicio", "natacao", "corrida", "caminhada",
        // Russian
        "спортзал", "тренировка", "фитнес", "плавание", "бег", "велоспорт",
        "йога", "пилатес", "бокс", "гребля", "скалолазание",
        // Simplified and Traditional Chinese
        "健身", "锻炼", "鍛鍊", "运动", "運動", "游泳", "跑步", "骑行", "騎行",
        "瑜伽", "普拉提", "皮拉提斯", "拳击", "拳擊", "力量训练", "重量訓練",
    )
    private val ambiguousActivityTokens = setOf(
        "run", "running", "spin",
    )
    private val fitnessContextTokens = setOf(
        "strength", "fitness", "marathon", "triathlon", "race", "5k", "10k",
        "morning", "afternoon", "evening", "night", "lunch", "trail", "track",
        "treadmill", "tempo", "interval", "intervals", "easy", "long", "recovery",
        "outdoor", "indoor", "club", "class", "practice",
    )
    private val workContextTokens = setOf(
        "meeting", "interview", "webinar", "workshop", "conference", "standup",
        "onboarding", "presentation", "planning", "demo", "review", "sync", "project",
        "payroll", "backup", "backups", "staging", "deploy", "deployment", "server",
        "database", "script", "pipeline", "batch", "runbook",
        "besprechung", "vorstellungsgespräch", "konferenz",
        "reunion", "entrevista", "conferencia", "taller",
        "entretien", "atelier",
        "riunione", "colloquio", "conferenza",
        "reuniao",
        "встреча", "собеседование", "конференция",
        "会议", "會議", "面试", "面試", "研讨会", "研討會",
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
            ?.let { Normalizer.normalize(it, Normalizer.Form.NFD) }
            ?.replace(Regex("\\p{M}+"), "")
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
        if (tokenSet.any(ambiguousActivityTokens::contains)) {
            return tokens.size == 1 || tokenSet.any(fitnessContextTokens::contains)
        }
        return "training" in tokenSet && tokenSet.any(fitnessContextTokens::contains)
    }
}
