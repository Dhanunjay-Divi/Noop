package com.noop.ui

/** Pure UI transition pinned separately from the database callback. */
internal object AutoWorkoutSuggestionPolicy {
    enum class SaveDisposition { CLEAR_CANDIDATE, KEEP_FOR_RETRY }

    fun afterSave(saved: Boolean): SaveDisposition =
        if (saved) SaveDisposition.CLEAR_CANDIDATE else SaveDisposition.KEEP_FOR_RETRY
}
