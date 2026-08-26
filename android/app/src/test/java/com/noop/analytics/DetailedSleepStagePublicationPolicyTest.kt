package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DetailedSleepStagePublicationPolicyTest {
    private fun local(
        start: Long,
        end: Long,
        eligible: Int? = ((end - start) / 300L).toInt(),
        valid: Int? = 0,
    ) = SleepSession(
        deviceId = "my-band-noop",
        startTs = start,
        endTs = end,
        stagesJSON = """[{"start":$start,"end":$end,"stage":"light"}]""",
        rrEligibleWindowCount = eligible,
        rrValidWindowCount = valid,
    )

    @Test
    fun currentBridgedMainGroupAggregatesExactCountsAndExcludesNap() {
        val first = local(22 * 3_600L, 23 * 3_600L, eligible = 12, valid = 6)
        val second = local(23 * 3_600L + 600L, 24 * 3_600L + 600L, eligible = 12, valid = 6)
        val nap = local(38 * 3_600L, 39 * 3_600L, eligible = 12, valid = 12)

        assertEquals(
            setOf(0, 1),
            DetailedSleepStagePublication.publishableLocalMainGroupIndices(
                sessions = listOf(first, second, nap),
                offsetSec = 0,
                habitualMidsleepSec = null,
            ),
        )
        assertTrue(
            DetailedSleepStagePublication.canPublishCurrentMainGroup(listOf(first, second)),
        )
    }

    @Test
    fun oneMissingFragmentFailsWholeCurrentGroupClosed() {
        val first = local(22 * 3_600L, 23 * 3_600L, eligible = 12, valid = 12)
        val missing = local(
            23 * 3_600L + 600L,
            24 * 3_600L + 600L,
            eligible = null,
            valid = null,
        )

        assertEquals(
            emptySet<Int>(),
            DetailedSleepStagePublication.publishableLocalMainGroupIndices(
                sessions = listOf(first, missing),
                offsetSec = 0,
                habitualMidsleepSec = null,
            ),
        )
    }

    @Test
    fun exactEvidenceCannotAuthorizeAnUndecodableStagePayload() {
        val start = 22 * 3_600L
        val malformed = local(start, start + 8 * 3_600L, eligible = 96, valid = 24)
            .copy(stagesJSON = "not-json")

        assertEquals(
            emptySet<Int>(),
            DetailedSleepStagePublication.publishableLocalMainGroupIndices(
                sessions = listOf(malformed),
                offsetSec = 0,
                habitualMidsleepSec = null,
            ),
        )
    }

    @Test
    fun importedFragmentCannotAuthorizeAStageLessLocalFragment() {
        val imported = SleepSession(
            deviceId = "oura-import",
            startTs = 0,
            endTs = 14_400,
            stagesJSON = """{"awake":10,"light":150,"deep":40,"rem":40}""",
        )
        val localWithoutStages = local(
            start = 15_000,
            end = 28_800,
            eligible = 46,
            valid = 12,
        ).copy(stagesJSON = null)

        assertFalse(
            DetailedSleepStagePublication.canPublishCurrentMainGroup(
                listOf(imported, localWithoutStages),
            ),
        )
    }

    @Test
    fun staleCountsForDifferentBoundsAreRejected() {
        val row = local(0L, 8 * 3_600L, eligible = 96, valid = 24)
            .copy(startTsAdjusted = 600L)

        assertNull(DetailedSleepStagePublication.exactRrWindowCounts(row))
        assertFalse(DetailedSleepStagePublication.hasSustainedExactRrEvidence(listOf(row)))
    }

    @Test
    fun invalidOrOverflowProneEffectiveBoundsAreRejectedBeforeSubtraction() {
        val rows = listOf(
            local(-1L, 300L, eligible = 0, valid = 0),
            local(300L, -1L, eligible = 0, valid = 0),
            local(300L, 300L, eligible = 0, valid = 0),
            local(301L, 300L, eligible = 0, valid = 0),
            local(
                Long.MIN_VALUE,
                Long.MAX_VALUE,
                eligible = 0,
                valid = 0,
            ),
        )

        rows.forEach { row ->
            assertNull(DetailedSleepStagePublication.exactRrWindowCounts(row))
        }
    }

    @Test
    fun importedProviderStagesRemainIndependentButMixedLocalStagesStillNeedEvidence() {
        val imported = SleepSession(
            deviceId = "oura-import",
            startTs = 0,
            endTs = 28_800,
            stagesJSON = """{"awake":30,"light":230,"deep":80,"rem":100}""",
        )
        val unsupportedLocal = local(0, 28_800, eligible = null, valid = null)

        assertTrue(
            DetailedSleepStagePublication.canPublishCurrentMainGroup(listOf(imported)),
        )
        assertFalse(
            DetailedSleepStagePublication.canPublishCurrentMainGroup(
                listOf(imported, unsupportedLocal),
            ),
        )
    }
}
