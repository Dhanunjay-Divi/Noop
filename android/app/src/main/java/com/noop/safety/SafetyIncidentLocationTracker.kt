package com.noop.safety

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

/** Platform location stream for an active Safety page. It emits fixes, never route history. */
class SafetyIncidentLocationTracker(private val context: Context) {
    @SuppressLint("MissingPermission")
    fun stream(): Flow<SafetyLocation> = callbackFlow {
        val appContext = context.applicationContext
        val permitted =
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(appContext, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (!permitted) {
            close()
            return@callbackFlow
        }
        val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val provider = runCatching {
            when {
                manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ->
                    LocationManager.GPS_PROVIDER
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER) ->
                    LocationManager.NETWORK_PROVIDER
                else -> null
            }
        }.getOrNull()
        if (provider == null) {
            close()
            return@callbackFlow
        }
        val listener = LocationListener { location: Location ->
            val fix = SafetyLocation(
                latitude = location.latitude,
                longitude = location.longitude,
                horizontalAccuracyMeters =
                    location.accuracy.toDouble().takeIf { location.hasAccuracy() },
                capturedAtUnix =
                    (location.time.takeIf { it > 0L } ?: System.currentTimeMillis()) / 1_000L,
            )
            if (fix.isUsable(System.currentTimeMillis() / 1_000L)) trySend(fix)
        }
        try {
            manager.requestLocationUpdates(
                provider,
                12_000L,
                10f,
                listener,
                Looper.getMainLooper(),
            )
        } catch (_: Throwable) {
            close()
            return@callbackFlow
        }
        awaitClose { runCatching { manager.removeUpdates(listener) } }
    }
}
