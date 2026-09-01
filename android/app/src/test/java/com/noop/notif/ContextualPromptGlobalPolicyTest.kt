package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContextualPromptGlobalPolicyTest {
    @Test fun contextualTopicsShareOneThirtyMinuteWindow() {
        val now = 1_700_000_000_000L

        assertTrue(ContextualPromptGlobalPolicy.canDeliver(null, now))
        assertFalse(
            ContextualPromptGlobalPolicy.canDeliver(
                now,
                now + ContextualPromptGlobalPolicy.COOLDOWN_MILLIS - 1L,
            ),
        )
        assertTrue(
            ContextualPromptGlobalPolicy.canDeliver(
                now,
                now + ContextualPromptGlobalPolicy.COOLDOWN_MILLIS,
            ),
        )
    }
}
