package com.noop.data

import com.noop.protocol.RrSourceChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** Pins Room's additive R-R ordering/channel migrations and the persisted beat metadata. */
class RrOrderingMigrationTest {

    @Test
    fun orderMigrationIsNullableAndAdditive() {
        assertEquals(listOf("ALTER TABLE `rrInterval` ADD COLUMN `ord` INTEGER"),
            WhoopDatabase.RR_ORD_MIGRATION_SQL)
        assertEquals(23, WhoopDatabase.MIGRATION_23_24.startVersion)
        assertEquals(24, WhoopDatabase.MIGRATION_23_24.endVersion)
        assertFalse(WhoopDatabase.RR_ORD_MIGRATION_SQL.single().uppercase().contains("NOT NULL"))
    }

    @Test
    fun sourceMigrationIsNullableAndAdditive() {
        assertEquals(listOf("ALTER TABLE `rrInterval` ADD COLUMN `srcChannel` INTEGER"),
            WhoopDatabase.RR_SRC_CHANNEL_MIGRATION_SQL)
        assertEquals(24, WhoopDatabase.MIGRATION_24_25.startVersion)
        assertEquals(25, WhoopDatabase.MIGRATION_24_25.endVersion)
        assertFalse(WhoopDatabase.RR_SRC_CHANNEL_MIGRATION_SQL.single().uppercase().contains("NOT NULL"))
        assertNull(RrInterval(deviceId = "legacy", ts = 1, rrMs = 800).srcChannel)
    }

    @Test
    fun assignmentPreservesEmissionOrderAndDurableChannelCode() {
        val stored = assignRrSeq(
            "ring",
            listOf(
                RrRow(100, 910, RrSourceChannel.GREEN_QUALITY),
                RrRow(100, 700, RrSourceChannel.SPO2_IBI),
                RrRow(100, 850, RrSourceChannel.IBI_AMPLITUDE),
            ),
        )

        assertEquals(listOf(0, 1, 2), stored.map { it.ord })
        assertEquals(listOf(1, 2, 3), stored.map { it.srcChannel })
        assertEquals(listOf(1, 2, 3, 4), RrSourceChannel.entries.map { it.code })
    }
}
