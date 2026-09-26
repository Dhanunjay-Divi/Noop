package com.noop.ble.veepoo

import android.content.Context
import com.noop.data.PairedDeviceRow

data class VeepooSourceRequest(
    val context: Context,
    val deviceId: String,
    val row: PairedDeviceRow?,
    val reconnectPassword: CharArray?,
)

fun interface VeepooBridgeProvider {
    fun create(context: Context): VeepooBridge
}

/**
 * The normal build has neither a supplier AAR reference nor an enabled flag. A separately wired local
 * build may add the Boolean BuildConfig field and this provider class; reflection keeps both optional.
 */
object VeepooBridgeProviderLoader {
    private const val FLAG = "VEEPOO_ADAPTER_AVAILABLE"
    private const val PROVIDER_CLASS = "com.noop.ble.veepoo.vendor.VeepooBridgeProviderImpl"

    fun load(): VeepooBridgeProvider? {
        val enabled = runCatching {
            Class.forName("com.noop.BuildConfig").getField(FLAG).getBoolean(null)
        }.getOrDefault(false)
        if (!enabled) return null
        return runCatching {
            Class.forName(PROVIDER_CLASS).getDeclaredConstructor().newInstance() as VeepooBridgeProvider
        }.getOrNull()
    }
}
