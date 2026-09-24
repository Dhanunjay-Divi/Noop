package com.noop.ui

import com.noop.ble.LiveHeartRateNotificationPolicy
import com.noop.ble.veepoo.VeepooAdapterState
import com.noop.ble.veepoo.VeepooDisplayState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SupplierDisplayHeartRatePolicyTest {
    private val liveDisplay = VeepooDisplayState(
        adapterState = VeepooAdapterState.LIVE_DISPLAY_ONLY,
        heartRate = 72,
        phoneReceiptMilliseconds = 100_000L,
        active = true,
    )

    @Test
    fun exactFreshnessBoundaryIsVisibleThenExpires() {
        assertEquals(
            72,
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                100_000L + LiveHeartRateNotificationPolicy.FRESHNESS_MS,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                100_001L + LiveHeartRateNotificationPolicy.FRESHNESS_MS,
            ),
        )
    }

    @Test
    fun futureReceiptTimeFailsClosed() {
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay.copy(phoneReceiptMilliseconds = 100_001L),
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay.copy(phoneReceiptMilliseconds = 100_001L),
                nowMillis = 100_000L,
            ),
        )
    }

    @Test
    fun unchangedDisplayStateExpiresAfterASilentStall() {
        assertEquals(
            LiveHeartRateNotificationPolicy.FRESHNESS_MS + 1L,
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay,
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                nowMillis = 100_000L +
                    LiveHeartRateNotificationPolicy.FRESHNESS_MS +
                    1L,
            ),
        )
        assertEquals(
            0L,
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay,
                nowMillis = 100_000L +
                    LiveHeartRateNotificationPolicy.FRESHNESS_MS +
                    1L,
            ),
        )
    }
}
