package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ContextualActionPolicyTest {
    private fun action(
        kind: ContextualActionKind,
        id: String = kind.name,
        createdAt: Long = 1_000L,
        expiresAt: Long = 10_000L,
    ) = ContextualAction(
        id = id,
        kind = kind,
        title = id,
        detail = "",
        evidence = emptyList(),
        createdAtMillis = createdAt,
        expiresAtMillis = expiresAt,
    )

    @Test fun visibleActionsExpireDeduplicateByKindAndRespectPriorityLimit() {
        val visible = ContextualActionPolicy.visible(
            actions = listOf(
                action(ContextualActionKind.HYDRATION, "old-water", createdAt = 1_000L),
                action(ContextualActionKind.HYDRATION, "new-water", createdAt = 2_000L),
                action(ContextualActionKind.JOURNAL),
                action(ContextualActionKind.WIND_DOWN),
                action(ContextualActionKind.RECOVERY),
                action(ContextualActionKind.BREATHE, expiresAt = 4_000L),
            ),
            nowMillis = 5_000L,
        )

        assertEquals(3, visible.size)
        assertEquals(
            listOf(
                ContextualActionKind.RECOVERY,
                ContextualActionKind.WIND_DOWN,
                ContextualActionKind.HYDRATION,
            ),
            visible.map { it.kind },
        )
        assertEquals("new-water", visible.last().id)
        assertTrue(visible.none { it.kind == ContextualActionKind.BREATHE })
    }

    @Test fun zeroLimitReturnsNoActions() {
        assertTrue(
            ContextualActionPolicy.visible(
                listOf(action(ContextualActionKind.HYDRATION)),
                nowMillis = 2_000L,
                limit = 0,
            ).isEmpty(),
        )
    }
}
