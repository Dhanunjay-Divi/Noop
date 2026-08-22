package com.noop.ui

/**
 * Local-only phrase matching for a voice/text journal draft. Matches only preselect familiar
 * journal rows; the Coach screen always presents the complete review list before saving.
 */
internal object CoachJournalDraftPolicy {
    val questions: List<String> = STARTER_JOURNAL_QUESTIONS

    private val aliases = mapOf(
        "Did you drink any alcohol?" to listOf("alcohol", "beer", "wine", "cocktail", "drank"),
        "Did you have caffeine late in the day?" to
            listOf("late caffeine", "coffee late", "evening coffee", "energy drink"),
        "Did you view a screen in bed?" to
            listOf("screen in bed", "phone in bed", "tablet in bed", "watched in bed"),
        "Did you eat close to bedtime?" to
            listOf("late meal", "ate late", "bedtime snack", "close to bedtime"),
        "Did you feel stressed?" to listOf("stressed", "stressful", "under stress"),
        "Did you use a sauna?" to listOf("sauna"),
        "Did you share your bed?" to listOf("shared my bed", "share my bed", "bed partner"),
        "Did you feel sick or ill?" to listOf("sick", "ill", "unwell"),
        "Did you take magnesium?" to listOf("magnesium"),
        "Did you read before bed?" to listOf("read before bed", "reading before bed"),
    )

    fun matches(text: String): List<String> {
        val normalized = normalize(text)
        if (normalized.isEmpty()) return emptyList()
        return questions.filter { question ->
            aliases[question].orEmpty().any { normalized.contains(normalize(it)) }
        }
    }

    private fun normalize(value: String): String = buildString {
        var previousSpace = true
        value.lowercase().forEach { character ->
            if (character.isLetterOrDigit()) {
                append(character)
                previousSpace = false
            } else if (!previousSpace) {
                append(' ')
                previousSpace = true
            }
        }
    }.trim()
}
