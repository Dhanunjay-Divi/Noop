package com.noop.weather

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.noop.BuildConfig
import java.io.Closeable
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject

data class TodayWeatherSnapshot(
    val temperatureC: Double,
    val weatherCode: Int,
    val observedAtMs: Long,
)

enum class TodayWeatherStatus {
    IDLE,
    LOCATING,
    READY,
    DENIED,
    UNAVAILABLE,
    FAILED,
}

data class TodayWeatherState(
    val snapshot: TodayWeatherSnapshot? = null,
    val status: TodayWeatherStatus = TodayWeatherStatus.IDLE,
)

enum class TodayWeatherCondition {
    CLEAR,
    MOSTLY_CLEAR,
    PARTLY_CLOUDY,
    OVERCAST,
    FOG,
    DRIZZLE,
    RAIN,
    SNOW,
    THUNDERSTORM,
    UNKNOWN,
}

internal object TodayWeatherCode {
    fun condition(code: Int): TodayWeatherCondition = when (code) {
        0 -> TodayWeatherCondition.CLEAR
        1 -> TodayWeatherCondition.MOSTLY_CLEAR
        2 -> TodayWeatherCondition.PARTLY_CLOUDY
        3 -> TodayWeatherCondition.OVERCAST
        45, 48 -> TodayWeatherCondition.FOG
        in 51..57 -> TodayWeatherCondition.DRIZZLE
        in 61..67, in 80..82 -> TodayWeatherCondition.RAIN
        in 71..77, in 85..86 -> TodayWeatherCondition.SNOW
        95, 96, 99 -> TodayWeatherCondition.THUNDERSTORM
        else -> TodayWeatherCondition.UNKNOWN
    }
}

internal object TodayWeatherParser {
    fun parse(payload: String, observedAtMs: Long): TodayWeatherSnapshot {
        val current = JSONObject(payload).getJSONObject("current")
        val temperature = current.getDouble("temperature_2m")
        val weatherCode = current.getInt("weather_code")
        require(temperature.isFinite() && temperature in -100.0..70.0) {
            "Weather response contained an invalid temperature"
        }
        require(weatherCode in 0..99) {
            "Weather response contained an invalid weather code"
        }
        return TodayWeatherSnapshot(
            temperatureC = temperature,
            weatherCode = weatherCode,
            observedAtMs = observedAtMs,
        )
    }
}

internal object TodayWeatherRequest {
    private val endpoint = "https://api.open-meteo.com/v1/forecast".toHttpUrl()

    fun coarseCoordinate(value: Double): String =
        String.format(Locale.US, "%.2f", value)

    fun url(latitude: Double, longitude: Double): HttpUrl = endpoint.newBuilder()
        .addQueryParameter("latitude", coarseCoordinate(latitude))
        .addQueryParameter("longitude", coarseCoordinate(longitude))
        .addQueryParameter("current", "temperature_2m,weather_code")
        .addQueryParameter("forecast_days", "1")
        .build()
}

/**
 * Explicitly enabled current conditions for Android Today.
 *
 * The store asks for one approximate location only after a person taps the weather chip. Coordinates
 * are rounded before the Open-Meteo request, are never persisted, and the resulting conditions are
 * cached locally for two hours.
 */
class TodayWeatherStore(context: Context) : Closeable {
    private val appContext = context.applicationContext
    private val prefs =
        appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val manager =
        appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val initialSnapshot = cachedSnapshot(System.currentTimeMillis())
    private val mutableState = MutableStateFlow(
        TodayWeatherState(
            snapshot = initialSnapshot,
            status = if (initialSnapshot == null) {
                TodayWeatherStatus.IDLE
            } else {
                TodayWeatherStatus.READY
            },
        ),
    )

    val state: StateFlow<TodayWeatherState> = mutableState.asStateFlow()

    private var activeListener: LocationListener? = null
    private var requestInFlight = false
    private var closed = false
    private val locationTimeout = Runnable {
        clearLocationListener()
        finishFailure(TodayWeatherStatus.FAILED)
    }

    fun startIfEnabled() {
        if (!prefs.getBoolean(KEY_ENABLED, false)) return
        if (mutableState.value.snapshot != null) return
        if (isDemoBuild()) {
            publishDemo()
        } else if (hasLocationPermission()) {
            refresh()
        } else {
            mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.DENIED)
        }
    }

    fun enableAndRefresh(onPermissionRequired: () -> Unit) {
        prefs.edit().putBoolean(KEY_ENABLED, true).apply()
        if (isDemoBuild()) {
            publishDemo()
        } else if (hasLocationPermission()) {
            refresh()
        } else {
            mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.LOCATING)
            onPermissionRequired()
        }
    }

    fun onPermissionResult(granted: Boolean) {
        if (closed) return
        if (granted || hasLocationPermission()) {
            refresh()
        } else {
            requestInFlight = false
            mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.DENIED)
        }
    }

    @SuppressLint("MissingPermission")
    fun refresh() {
        if (closed || requestInFlight) return
        if (isDemoBuild()) {
            publishDemo()
            return
        }
        if (!hasLocationPermission()) {
            mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.DENIED)
            return
        }

        val enabledProviders = runCatching { manager.getProviders(true) }.getOrDefault(emptyList())
        if (
            LocationManager.NETWORK_PROVIDER !in enabledProviders &&
            LocationManager.GPS_PROVIDER !in enabledProviders
        ) {
            mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.UNAVAILABLE)
            return
        }

        requestInFlight = true
        mutableState.value = mutableState.value.copy(status = TodayWeatherStatus.LOCATING)

        val now = System.currentTimeMillis()
        val lastKnown = enabledProviders
            .asSequence()
            .mapNotNull { provider ->
                runCatching { manager.getLastKnownLocation(provider) }.getOrNull()
            }
            .filter { it.time in 1..now }
            .maxByOrNull(Location::getTime)
        if (lastKnown != null && now - lastKnown.time <= LAST_LOCATION_MAX_AGE_MS) {
            fetchWeather(lastKnown)
            return
        }

        val provider = when {
            LocationManager.NETWORK_PROVIDER in enabledProviders ->
                LocationManager.NETWORK_PROVIDER
            LocationManager.GPS_PROVIDER in enabledProviders ->
                LocationManager.GPS_PROVIDER
            else -> null
        }
        if (provider == null) {
            finishFailure(TodayWeatherStatus.UNAVAILABLE)
            return
        }

        val listener = LocationListener(::fetchWeather)
        activeListener = listener
        try {
            manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
            handler.postDelayed(locationTimeout, LOCATION_TIMEOUT_MS)
        } catch (_: SecurityException) {
            clearLocationListener()
            finishFailure(TodayWeatherStatus.DENIED)
        } catch (_: IllegalArgumentException) {
            clearLocationListener()
            finishFailure(TodayWeatherStatus.UNAVAILABLE)
        }
    }

    private fun fetchWeather(location: Location) {
        if (closed) return
        clearLocationListener()
        scope.launch {
            val result = try {
                Result.success(
                    withContext(Dispatchers.IO) {
                        val request = Request.Builder()
                            .url(TodayWeatherRequest.url(location.latitude, location.longitude))
                            .header("Accept", "application/json")
                            .header("User-Agent", "NOOP/${BuildConfig.VERSION_NAME}")
                            .get()
                            .build()
                        http.newCall(request).execute().use { response ->
                            check(response.isSuccessful) {
                                "Weather request returned HTTP ${response.code}"
                            }
                            val body = response.body?.string()
                                ?: error("Weather response was empty")
                            TodayWeatherParser.parse(body, System.currentTimeMillis())
                        }
                    },
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
            if (closed) return@launch
            requestInFlight = false
            result.onSuccess { snapshot ->
                cache(snapshot)
                mutableState.value = TodayWeatherState(
                    snapshot = snapshot,
                    status = TodayWeatherStatus.READY,
                )
            }.onFailure {
                finishFailure(TodayWeatherStatus.FAILED)
            }
        }
    }

    private fun finishFailure(status: TodayWeatherStatus) {
        if (closed) return
        requestInFlight = false
        mutableState.value = mutableState.value.copy(
            status = if (mutableState.value.snapshot == null) {
                status
            } else {
                TodayWeatherStatus.READY
            },
        )
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED

    private fun cachedSnapshot(now: Long): TodayWeatherSnapshot? {
        if (!prefs.contains(KEY_TEMPERATURE_C)) return null
        val observedAt = prefs.getLong(KEY_OBSERVED_AT_MS, 0)
        if (observedAt <= 0 || observedAt > now || now - observedAt >= CACHE_LIFETIME_MS) {
            return null
        }
        val temperature = java.lang.Double.longBitsToDouble(
            prefs.getLong(KEY_TEMPERATURE_C, Double.NaN.toRawBits()),
        )
        val weatherCode = prefs.getInt(KEY_WEATHER_CODE, -1)
        return if (temperature.isFinite() && weatherCode in 0..99) {
            TodayWeatherSnapshot(temperature, weatherCode, observedAt)
        } else {
            null
        }
    }

    private fun cache(snapshot: TodayWeatherSnapshot) {
        prefs.edit()
            .putLong(KEY_TEMPERATURE_C, snapshot.temperatureC.toRawBits())
            .putInt(KEY_WEATHER_CODE, snapshot.weatherCode)
            .putLong(KEY_OBSERVED_AT_MS, snapshot.observedAtMs)
            .apply()
    }

    private fun publishDemo() {
        if (closed) return
        val snapshot = TodayWeatherSnapshot(
            temperatureC = 22.0,
            weatherCode = 2,
            observedAtMs = System.currentTimeMillis(),
        )
        cache(snapshot)
        mutableState.value = TodayWeatherState(snapshot, TodayWeatherStatus.READY)
    }

    private fun isDemoBuild(): Boolean =
        BuildConfig.DEBUG && BuildConfig.ENABLE_DEMO

    @SuppressLint("MissingPermission")
    private fun clearLocationListener() {
        handler.removeCallbacks(locationTimeout)
        activeListener?.let { listener ->
            runCatching { manager.removeUpdates(listener) }
        }
        activeListener = null
    }

    override fun close() {
        if (closed) return
        closed = true
        clearLocationListener()
        requestInFlight = false
        scope.cancel()
    }

    companion object {
        const val ATTRIBUTION_URL = "https://open-meteo.com/"

        private const val PREFS_NAME = "noop_today_weather"
        private const val KEY_ENABLED = "today.weather.enabled"
        private const val KEY_TEMPERATURE_C = "today.weather.temperatureC"
        private const val KEY_WEATHER_CODE = "today.weather.weatherCode"
        private const val KEY_OBSERVED_AT_MS = "today.weather.observedAtMs"
        private const val CACHE_LIFETIME_MS = 2 * 60 * 60 * 1_000L
        private const val LAST_LOCATION_MAX_AGE_MS = 30 * 60 * 1_000L
        private const val LOCATION_TIMEOUT_MS = 15_000L

        private val http = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .callTimeout(20, TimeUnit.SECONDS)
            .build()
    }
}
