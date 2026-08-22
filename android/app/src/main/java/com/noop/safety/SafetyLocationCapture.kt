package com.noop.safety

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/** One-shot location capture for a user-prepared safety message. Never starts background tracking. */
object SafetyLocationCapture {
    private const val TIMEOUT_MS = 15_000L

    @SuppressLint("MissingPermission")
    fun request(context: Context, onResult: (SafetyLocation?) -> Unit) {
        val appContext = context.applicationContext
        val hasPermission =
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (!hasPermission) {
            onResult(null)
            return
        }

        val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = runCatching {
            when {
                manager.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
                else -> null
            }
        }.getOrNull()
        if (provider == null) {
            onResult(null)
            return
        }

        val delivered = AtomicBoolean(false)
        val handler = Handler(Looper.getMainLooper())
        fun finish(location: Location?) {
            if (!delivered.compareAndSet(false, true)) return
            val captured = location?.toSafetyLocation()
            val nowUnix = System.currentTimeMillis() / 1_000L
            onResult(captured?.takeIf { it.isUsable(nowUnix) })
        }

        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val cancellation = CancellationSignal()
                handler.postDelayed({
                    cancellation.cancel()
                    finish(null)
                }, TIMEOUT_MS)
                manager.getCurrentLocation(
                    provider,
                    cancellation,
                    ContextCompat.getMainExecutor(appContext),
                ) { location -> finish(location) }
            } else {
                lateinit var listener: LocationListener
                listener = LocationListener { location ->
                    runCatching { manager.removeUpdates(listener) }
                    finish(location)
                }
                handler.postDelayed({
                    runCatching { manager.removeUpdates(listener) }
                    finish(null)
                }, TIMEOUT_MS)
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            }
        }.onFailure { finish(null) }
    }

    private fun Location.toSafetyLocation(): SafetyLocation {
        val captured = (time.takeIf { it > 0L } ?: System.currentTimeMillis()) / 1_000L
        return SafetyLocation(
            latitude = latitude,
            longitude = longitude,
            horizontalAccuracyMeters = if (hasAccuracy()) accuracy.toDouble() else null,
            capturedAtUnix = captured,
        )
    }
}
