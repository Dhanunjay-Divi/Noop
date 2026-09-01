package com.noop.notif

import android.content.Context

internal enum class ContextualPromptPostResult {
    POSTED,
    GLOBAL_COOLDOWN,
    FAILED,
}

/** Pure cross-topic anti-pileup rule shared by routine contextual phone prompts. */
internal object ContextualPromptGlobalPolicy {
    const val COOLDOWN_MILLIS = 30L * 60L * 1_000L

    fun canDeliver(lastDeliveryMillis: Long?, nowMillis: Long): Boolean =
        lastDeliveryMillis?.let { nowMillis - it >= COOLDOWN_MILLIS } ?: true
}

/**
 * Process- and restart-safe Android twin of Apple's shared contextual-intervention state.
 *
 * The platform notify call and global timestamp update run under one lock, so concurrent stress,
 * sleep, and vital evaluations cannot all pass a check-then-post race. Strong workout caution is
 * intentionally separate because it is an in-session safety prompt rather than a routine nudge.
 */
internal object ContextualPromptDeliveryLedger {
    private const val PREFS_FILE = "noop_contextual_prompt_delivery"
    private const val KEY_LAST_AT = "global.last.at"
    private val lock = Any()

    fun postIfAllowed(
        context: Context,
        nowMillis: Long,
        post: () -> Boolean,
    ): ContextualPromptPostResult = synchronized(lock) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        val last = prefs.getLong(KEY_LAST_AT, 0L).takeIf { prefs.contains(KEY_LAST_AT) }
        if (!ContextualPromptGlobalPolicy.canDeliver(last, nowMillis)) {
            return@synchronized ContextualPromptPostResult.GLOBAL_COOLDOWN
        }
        if (!post()) return@synchronized ContextualPromptPostResult.FAILED
        prefs.edit().putLong(KEY_LAST_AT, nowMillis).commit()
        ContextualPromptPostResult.POSTED
    }
}
