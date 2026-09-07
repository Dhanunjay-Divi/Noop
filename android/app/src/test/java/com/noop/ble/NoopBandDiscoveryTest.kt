package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NoopBandDiscoveryTest {

    @Test
    fun setupScanListsEveryCompatibleService() {
        assertEquals(
            setOf(WhoopBleClient.WHOOP4_SERVICE, WhoopBleClient.WHOOP5_SERVICE),
            WhoopModel.compatibleServices.toSet(),
        )
    }

    @Test
    fun customerNameAndVisibleDiagnosticsHideVendorBrand() {
        assertEquals("Compatible band", WhoopModel.WHOOP4.displayName)
        assertEquals("Compatible band", WhoopModel.WHOOP5_MG.displayName)
        assertEquals("legacy band", WhoopModel.WHOOP4.transportName)
        assertEquals("newer band", WhoopModel.WHOOP5_MG.transportName)
    }

    @Test
    fun advertisementResolverPreservesActualTransportFamily() {
        assertEquals(
            WhoopModel.WHOOP4,
            WhoopModel.fromAdvertisedServiceUuids(listOf(WhoopBleClient.WHOOP4_SERVICE.toString())),
        )
        assertEquals(
            WhoopModel.WHOOP5_MG,
            WhoopModel.fromAdvertisedServiceUuids(listOf(WhoopBleClient.WHOOP5_SERVICE.toString().uppercase())),
        )
        assertNull(WhoopModel.fromAdvertisedServiceUuids(listOf("0000180d-0000-1000-8000-00805f9b34fb")))
    }

    @Test
    fun discoveredRowAndRegistrationUseObservedModel() {
        val discovered = WhoopBleClient.mergeDiscoveredWhoop(
            existing = emptyList(),
            address = "AA:BB:CC:DD:EE:FF",
            name = "Band",
            rssi = -42,
            advertisedServiceUuids = listOf(WhoopBleClient.WHOOP5_SERVICE.toString()),
        )

        assertEquals(1, discovered.size)
        assertEquals(WhoopModel.WHOOP5_MG, discovered.single().model)
        assertEquals("5.0 MG", discovered.single().model.registryModel)
        assertEquals("Compatible band", discovered.single().model.displayName)
    }

    @Test
    fun unsupportedAdvertisementDoesNotMutateRows() {
        val existing = listOf(
            WhoopBleClient.DiscoveredWhoop("AA", null, -60, WhoopModel.WHOOP4),
        )
        val unchanged = WhoopBleClient.mergeDiscoveredWhoop(
            existing = existing,
            address = "BB",
            name = null,
            rssi = -80,
            advertisedServiceUuids = listOf("0000180f-0000-1000-8000-00805f9b34fb"),
        )

        assertSame(existing, unchanged)
        assertTrue(unchanged.single().model == WhoopModel.WHOOP4)
    }
}
