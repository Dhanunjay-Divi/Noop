package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class WhoopCsvImportStoreTest {
    @Test
    fun officialReimportPreservesUserEditsAndLocalEvidence() {
        val existing = SleepSession(
            deviceId = "wearable-import",
            startTs = 100,
            endTs = 800,
            efficiency = 0.7,
            restingHr = 60,
            avgHrv = 40.0,
            stagesJSON = """[{"stage":"edited"}]""",
            userEdited = true,
            startTsAdjusted = 130,
            motionJSON = "[0.1,0.2]",
            sleepStateJSON = "[1,2]",
        )
        val incoming = SleepSession(
            deviceId = existing.deviceId,
            startTs = existing.startTs,
            endTs = 900,
            efficiency = 0.9,
            restingHr = 52,
            avgHrv = 61.0,
            stagesJSON = """[{"stage":"provider"}]""",
        )

        val merged = mergeOfficialSleepSession(existing, incoming)

        assertEquals(existing, merged)
    }

    @Test
    fun officialReimportRefreshesUneditedWindowButStillPreservesLocalEvidence() {
        val existing = SleepSession(
            deviceId = "wearable-import",
            startTs = 100,
            endTs = 800,
            stagesJSON = """[{"stage":"old"}]""",
            motionJSON = "[0.1]",
            sleepStateJSON = "[2]",
        )
        val incoming = SleepSession(
            deviceId = existing.deviceId,
            startTs = existing.startTs,
            endTs = 900,
            efficiency = 0.9,
            stagesJSON = """[{"stage":"provider"}]""",
        )

        val merged = mergeOfficialSleepSession(existing, incoming)

        assertEquals(900, merged.endTs)
        assertEquals(incoming.stagesJSON, merged.stagesJSON)
        assertFalse(merged.userEdited)
        assertNull(merged.startTsAdjusted)
        assertEquals("[0.1]", merged.motionJSON)
        assertEquals("[2]", merged.sleepStateJSON)
    }

    @Test
    fun officialSleepMergeRejectsDifferentNaturalKeys() {
        val existing = SleepSession("a", 100, 200)
        val incoming = SleepSession("b", 100, 200)

        assertThrows(IllegalArgumentException::class.java) {
            mergeOfficialSleepSession(existing, incoming)
        }
    }
}
