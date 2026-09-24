package com.noop.ui

import com.noop.ble.LiveHeartRateNotificationPolicy
import com.noop.ble.veepoo.VeepooAdapterState
import com.noop.ble.veepoo.VeepooDisplayState

internal object SupplierDisplayHeartRatePolicy {
    fun visibleBpm(display: VeepooDisplayState, nowMillis: Long): Int? =
        LiveHeartRateNotificationPolicy.visibleBpm(
            enabled = true,
            connected = display.active &&
                display.adapterState == VeepooAdapterState.LIVE_DISPLAY_ONLY,
            bpm = display.heartRate,
            receivedAtMillis = display.phoneReceiptMilliseconds,
            nowMillis = nowMillis,
        )

    fun expiryCheckDelayMillis(
        display: VeepooDisplayState,
        nowMillis: Long,
    ): Long? {
        if (
            !display.active ||
            display.adapterState != VeepooAdapterState.LIVE_DISPLAY_ONLY ||
            display.heartRate !in 30..220
        ) {
            return null
        }
        return LiveHeartRateNotificationPolicy.expiryCheckDelayMillis(
            receivedAtMillis = display.phoneReceiptMilliseconds,
            nowMillis = nowMillis,
        )
    }
}
