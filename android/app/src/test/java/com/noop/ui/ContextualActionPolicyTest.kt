package com.noop.ui

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ContextualActionPolicyTest {
    private fun action(
        kind: ContextualActionKind,
        id: String = kind.name,
        createdAt: Long = 1_000L,
        expiresAt: Long = 10_000L,
        route: NoopNotificationRoute? = null,
        source: ContextualActionSource? = null,
    ) = ContextualAction(
        id = id,
        kind = kind,
        title = id,
        detail = "",
        evidence = emptyList(),
        createdAtMillis = createdAt,
        expiresAtMillis = expiresAt,
        route = route,
        source = source,
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

    @Test fun recoveryRouteDefaultsToSleepAndPreservesWorkoutDestination() {
        assertEquals(
            NoopNotificationRoute.SLEEP,
            action(ContextualActionKind.RECOVERY).resolvedRecoveryRoute(),
        )
        assertEquals(
            NoopNotificationRoute.WORKOUTS,
            action(
                ContextualActionKind.RECOVERY,
                route = NoopNotificationRoute.WORKOUTS,
            ).resolvedRecoveryRoute(),
        )
    }

    @Test fun equivalentLegacyWorkoutActionAndHistoryIdsMigrateTogether() {
        val legacyFingerprint =
            "planned-workout|2026-08-22|1700000123|SLEEP_DEFICIT"
        val currentFingerprint = "planned-workout|2026-08-22|1700000123"
        val legacyId = "recovery:$legacyFingerprint"
        val currentId = "recovery:$currentFingerprint"
        val migrated = ContextualActionIdentityMigration.recovery(
            state = ContextualActionIdentityState(
                actions = listOf(
                    action(
                        kind = ContextualActionKind.RECOVERY,
                        id = legacyId,
                        route = NoopNotificationRoute.WORKOUTS,
                    ),
                ),
                processingIds = setOf(legacyId),
                dismissedIds = setOf(legacyId),
                completedIds = setOf(legacyId),
            ),
            route = NoopNotificationRoute.WORKOUTS,
            toFingerprint = currentFingerprint,
        ) {
            it.substringBeforeLast('|') == currentFingerprint
        }

        assertEquals(listOf(currentId), migrated.actions.map { it.id })
        assertEquals(setOf(currentId), migrated.processingIds)
        assertEquals(setOf(currentId), migrated.dismissedIds)
        assertEquals(setOf(currentId), migrated.completedIds)
        assertFalse(migrated.actions.any { it.id == legacyId })
    }

    @Test fun adaptiveCleanupPreservesUnrelatedSleepRecoveryActions() {
        val retained = ContextualActionCleanupPolicy.removeRecoveryActions(
            actions = listOf(
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:adaptive-current",
                    source = ContextualActionSource.ADAPTIVE_DAY,
                ),
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:adaptive-legacy",
                ),
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:morning-review",
                ),
                action(
                    kind = ContextualActionKind.JOURNAL,
                    id = "journal:daily",
                ),
            ),
            source = ContextualActionSource.ADAPTIVE_DAY,
            legacyFingerprints = setOf("adaptive-legacy"),
        )

        assertEquals(
            listOf("recovery:morning-review", "journal:daily"),
            retained.map { it.id },
        )
    }

    @Test fun disabledAdaptiveGuidanceHidesTaggedAndLegacyActionsOnly() {
        val candidates = ContextualActionConsentPolicy.visibleCandidates(
            actions = listOf(
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:sleep:2026-09-11:372",
                ),
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:adaptive-tagged",
                    source = ContextualActionSource.ADAPTIVE_DAY,
                ),
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:morning:2026-09-11",
                ),
                action(
                    kind = ContextualActionKind.JOURNAL,
                    id = "journal:daily",
                ),
            ),
            hiddenActionIds = setOf("journal:daily"),
            adaptiveDayEnabled = false,
            plannedWorkoutCalendarEnabled = false,
        )

        assertEquals(
            listOf("recovery:morning:2026-09-11"),
            candidates.map { it.id },
        )
    }

    @Test fun calendarOptOutHidesOnlyPlannedWorkoutRecovery() {
        val candidates = ContextualActionConsentPolicy.visibleCandidates(
            actions = listOf(
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:planned-workout|2026-09-11|1789160400",
                    route = NoopNotificationRoute.WORKOUTS,
                ),
                action(
                    kind = ContextualActionKind.RECOVERY,
                    id = "recovery:sleep:2026-09-11:372",
                    source = ContextualActionSource.ADAPTIVE_DAY,
                ),
            ),
            hiddenActionIds = emptySet(),
            adaptiveDayEnabled = true,
            plannedWorkoutCalendarEnabled = false,
        )

        assertEquals(
            listOf("recovery:sleep:2026-09-11:372"),
            candidates.map { it.id },
        )
    }

    @Test fun synchronousActionStateWriteReportsCommitFailureWithoutPublishing() {
        val prefs = FakeSharedPreferences(commitResult = false)

        val committed = ContextualActionStateStore.write(
            prefs = prefs,
            key = "state",
            encodedState = """{"actions":[]}""",
            synchronous = true,
        )

        assertFalse(committed)
        assertFalse(prefs.contains("state"))
    }

    @Test fun sameFingerprintRefreshPreservesIdentityAndOriginalCreationTime() {
        val original = ContextualAction(
            id = "recovery:same-signal",
            kind = ContextualActionKind.RECOVERY,
            title = "Initial title",
            detail = "Initial detail",
            evidence = listOf("Initial evidence"),
            createdAtMillis = 1_000L,
            expiresAtMillis = 2_000L,
            amountMl = 250,
            route = NoopNotificationRoute.WORKOUTS,
            source = ContextualActionSource.ADAPTIVE_DAY,
        )

        val refreshed = ContextualActionRefreshPolicy.refreshed(
            existing = original,
            title = "Updated title",
            detail = "Updated detail",
            evidence = listOf("Updated evidence", "", "Second evidence"),
            expiresAtMillis = 9_000L,
            amountMl = null,
            route = null,
            source = null,
        )

        assertEquals(original.id, refreshed.id)
        assertEquals(original.createdAtMillis, refreshed.createdAtMillis)
        assertEquals("Updated title", refreshed.title)
        assertEquals("Updated detail", refreshed.detail)
        assertEquals(listOf("Updated evidence", "Second evidence"), refreshed.evidence)
        assertEquals(9_000L, refreshed.expiresAtMillis)
        assertEquals(250, refreshed.amountMl)
        assertEquals(NoopNotificationRoute.WORKOUTS, refreshed.route)
        assertEquals(ContextualActionSource.ADAPTIVE_DAY, refreshed.source)
    }
}
