package com.noop.ui

import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceDisplayNameTest {
    @Test
    fun transportAssignedBandNameStaysOutOfProductUi() {
        assertEquals("Compatible band", displayName(band(nickname = "WHOOP 5AG0146459")))
        assertEquals("Compatible band", displayName(band(nickname = "whoop")))
    }

    @Test
    fun userAssignedBandNameStillWins() {
        assertEquals("Morning Band", displayName(band(nickname = "  Morning Band  ")))
    }

    @Test
    fun duplicateModelIsHiddenButDistinctModelRemainsVisible() {
        assertEquals(false, shouldShowDeviceModel(" Compatible band ", "compatible BAND"))
        assertEquals(true, shouldShowDeviceModel("Morning Band", "Compatible band"))
    }

    private fun band(nickname: String?) = PairedDeviceRow(
        id = "my-whoop",
        brand = "WHOOP",
        model = "5.0 MG",
        nickname = nickname,
        sourceKind = SourceKind.liveBLE.name,
        capabilities = "hr,hrv,sleep",
        status = DeviceStatus.active.name,
        addedAt = 0,
        lastSeenAt = 0,
    )
}
