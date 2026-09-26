package com.noop.ui

import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActiveDeviceProjectionRetryTest {
    @Test
    fun initialProjectionRetriesUntilTheRegistryBecomesReadable() = runTest {
        var attempts = 0
        val projection = loadActiveDeviceProjection(
            retryDelaysMillis = listOf(1L, 5L),
            readDevices = {
                attempts += 1
                if (attempts < 3) error("transient registry failure")
                listOf(supplierRow())
            },
        )

        assertEquals(3, attempts)
        assertEquals("supplier-band", projection?.deviceId)
        assertEquals("NOOP Supplier band", projection?.name)
        assertEquals(ActiveDeviceSourceState.SUPPLIER, projection?.sourceState)
    }

    @Test
    fun projectionCancellationIsNotConvertedIntoARetry() = runTest {
        var attempts = 0
        val failure = runCatching {
            loadActiveDeviceProjection(
                retryDelaysMillis = listOf(1L, 5L),
                readDevices = {
                    attempts += 1
                    throw CancellationException("cancelled")
                },
            )
        }.exceptionOrNull()

        assertTrue(failure is CancellationException)
        assertEquals(1, attempts)
    }

    @Test
    fun changingTheSelectedDeviceInvalidatesTheConfirmedProjection() {
        assertTrue(
            shouldInvalidateActiveDeviceProjection(
                confirmed = true,
                confirmedSelectionId = "supplier-band-a",
                selectedDeviceId = "supplier-band-b",
            ),
        )
        assertTrue(
            !shouldInvalidateActiveDeviceProjection(
                confirmed = true,
                confirmedSelectionId = "supplier-band-a",
                selectedDeviceId = "supplier-band-a",
            ),
        )
        assertTrue(
            !shouldInvalidateActiveDeviceProjection(
                confirmed = false,
                confirmedSelectionId = "supplier-band-a",
                selectedDeviceId = "supplier-band-b",
            ),
        )
    }

    private fun supplierRow() = PairedDeviceRow(
        id = "supplier-band",
        brand = "NOOP",
        model = "Supplier band",
        nickname = null,
        peripheralId = "AA:BB:CC:DD:EE:10",
        sourceKind = SourceKind.veepoo.name,
        capabilities = "hr",
        status = DeviceStatus.active.name,
        addedAt = 1L,
        lastSeenAt = 1L,
    )
}
