package com.noop.ble

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.noop.managed.ManagedSafetyLiveLocationSession
import com.noop.safety.SafetyIncidentStatusMonitor
import com.noop.safety.SafetyLiveLocationSession
import com.noop.ui.NoopPrefs

/** Pure gate: reboot/process-death reconnect is allowed only for an existing user-kept connection. */
internal object BackgroundReconnectPolicy {
    data class Decision(
        val reconnect: Boolean,
        val reason: String,
        /** Reconnect restores the low-rate link/history offload; it never leases realtime HR. */
        val armRealtime: Boolean = false,
    )

    fun decide(
        keepConnectedEnabled: Boolean,
        hasRememberedDevice: Boolean,
        hasBluetoothConnectPermission: Boolean,
    ): Decision = when {
        !keepConnectedEnabled -> Decision(false, "Keep connected in background is off")
        !hasRememberedDevice -> Decision(false, "No previously paired band")
        !hasBluetoothConnectPermission -> Decision(false, "Bluetooth connect permission is missing")
        else -> Decision(true, "Reconnect allowed")
    }

    fun runtimeDecision(context: Context): Decision = decide(
        keepConnectedEnabled = NoopPrefs.backgroundConnection(context),
        hasRememberedDevice = NoopPrefs.lastDevice(context) != null,
        hasBluetoothConnectPermission = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED,
    )
}

internal fun shouldStartConnectionServiceAfterBoot(
    backgroundReconnectAllowed: Boolean,
    safetyLocationActive: Boolean,
): Boolean = backgroundReconnectAllowed || safetyLocationActive

/** Re-enters the already-opted-in foreground connection after a reboot; does nothing otherwise. */
class WhoopReconnectBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != ACTION_QUICKBOOT_POWERON
        ) return
        SafetyLiveLocationSession.initialize(context)
        ManagedSafetyLiveLocationSession.initialize(context)
        SafetyIncidentStatusMonitor.reconcile(context)
        val safetyLocationActive = SafetyLiveLocationSession.state.value.isActiveAt(
            System.currentTimeMillis() / 1_000L,
        ) || ManagedSafetyLiveLocationSession.state.value.isActiveAt(
            System.currentTimeMillis() / 1_000L,
        )
        if (
            shouldStartConnectionServiceAfterBoot(
                backgroundReconnectAllowed =
                    BackgroundReconnectPolicy.runtimeDecision(context).reconnect,
                safetyLocationActive = safetyLocationActive,
            )
        ) {
            WhoopConnectionService.startReconnect(context)
        }
    }

    private companion object {
        const val ACTION_QUICKBOOT_POWERON = "android.intent.action.QUICKBOOT_POWERON"
    }
}
