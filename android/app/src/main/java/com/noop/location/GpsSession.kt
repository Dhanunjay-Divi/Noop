package com.noop.location

import com.noop.analytics.RouteMath
import com.noop.analytics.RouteMath.LatLng
import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Process-level holder for the in-flight GPS workout's route, owned by [com.noop.NoopApplication]
 * and driven by [com.noop.ble.WhoopConnectionService] — NOT by the Activity-scoped AppViewModel.
 *
 * Why this exists: the route used to be collected in `AppViewModel.viewModelScope`, which Android
 * cancels the moment the ViewModel is cleared (screen off / Activity backgrounded). The collection
 * stopped mid-ride and distance froze (#215 — a 2.84 km ride banked as 0.38 km). The track now lives
 * here, at the process level, and the always-on foreground service feeds it from the platform
 * LocationManager, so it survives the UI going away. The ViewModel observes [state] for live display
 * and reads the final [State.track] when ending the workout; it no longer owns the location stream.
 * [initialize] also restores a durable route checkpoint, so an OS process restart no longer erases an
 * active session before the foreground service can resume it.
 *
 * Distance/pace are derived here (off the same [RouteMath] helpers AppViewModel used) so the running
 * totals are correct even across periods when no UI is observing.
 */
object GpsSession {

    /** A GPS workout's accumulated route. [startMs] anchors pace; [active] gates the service collector.
     *  [sportName] lets the UI rehydrate the active-workout card if the ViewModel was cleared mid-ride. */
    data class State(
        val active: Boolean = false,
        val startMs: Long = 0L,
        val sportName: String = "",
        /** Full route as restored at process start. New points live in the private O(1) accumulator; callers
         *  that need the exact current route use [snapshotTrack] rather than forcing a list copy per fix. */
        val track: List<LatLng> = emptyList(),
        val pointCount: Int = track.size,
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
    )

    private val _state = MutableStateFlow(State())
    @Volatile private var store: GpsSessionStore? = null
    private val trackLock = Any()
    private val trackAccumulator = ArrayList<LatLng>()
    /** The live route, observed by the UI (via AppViewModel) and the service's collect-gate. */
    val state: StateFlow<State> = _state.asStateFlow()

    /** Workouts & GPS test mode (Test Centre): the tagged sink for the .workouts GPS-fix lines, wired by
     *  [com.noop.ble.WhoopConnectionService] (which holds the BLE client + the gate). Default null (inert) so
     *  the route fold is byte-identical when the mode is off. The service ALWAYS checks the WORKOUTS gate
     *  before setting this, so [append] pays nothing extra when off. Diagnostic only - it never changes the
     *  route. The Android LocationTracker pre-filters UPSTREAM, so every appended fix is already ACCEPTED and
     *  the raw pre-filter count is not available at this seam; the gps line passes rawFixes = null (reads
     *  `n/a`) rather than imply an accept rate the platform never measured (the macOS recorder, which sees
     *  the raw stream, passes a real count). L4. */
    var workoutsLog: ((String) -> Unit)? = null

    /** Attach durable storage at application startup and restore a still-valid (<24 h) active route. */
    fun initialize(context: Context, nowMs: Long = System.currentTimeMillis()) {
        val next = GpsSessionStore.from(context.applicationContext)
        store = next
        val restored = next.load(nowMs)
        if (restored == null) next.clear()
        synchronized(trackLock) {
            trackAccumulator.clear()
            if (restored != null) trackAccumulator.addAll(restored.track)
        }
        _state.value = restored ?: State()
    }

    /** Begin a route for [sportName]'s workout started at [startMs]. A re-arm just resets the track. */
    fun start(startMs: Long, sportName: String) {
        val next = State(active = true, startMs = startMs, sportName = sportName)
        synchronized(trackLock) { trackAccumulator.clear() }
        _state.value = next
        store?.begin(next)
    }

    /** Fold one accepted fix into the route, recomputing distance + pace. No-op when not active. */
    fun append(pt: LatLng) {
        val s = _state.value
        if (!s.active) return
        val (last, count) = synchronized(trackLock) {
            val previous = trackAccumulator.lastOrNull()
            trackAccumulator.add(pt)
            previous to trackAccumulator.size
        }
        val dist = last?.let { s.distanceM + RouteMath.haversineMeters(it, pt) } ?: 0.0
        val secs = (System.currentTimeMillis() - s.startMs) / 1000.0
        val next = s.copy(pointCount = count, distanceM = dist, paceSecPerKm = RouteMath.paceSecPerKm(dist, secs))
        _state.value = next
        store?.append(pt)
        // Workouts & GPS test mode: one GPS-fix-progress line per accepted fix, only when the service wired a
        // sink (the WORKOUTS gate was on). The LocationTracker pre-filters UPSTREAM, so the raw pre-filter
        // count is not available at this seam (every fix here is already accepted). Pass rawFixes = null so
        // the line reads `rawFixes=n/a` instead of `rawFixes == accepted`, which would falsely imply a 100%
        // accept rate the platform never actually measured (macOS, which sees the raw stream, passes a real
        // count). L4.
        workoutsLog?.invoke(
            com.noop.analytics.WorkoutsTrace.gpsLine(
                rawFixes = null, acceptedPoints = count, distanceM = dist,
            ),
        )
    }

    /** Exact current route, copied once for End/persistence instead of once per GPS fix. */
    fun snapshotTrack(): List<LatLng> = synchronized(trackLock) { trackAccumulator.toList() }

    /** End the route and clear it. Returns the final accumulated track for the saved WorkoutRow. */
    fun stop(): List<LatLng> {
        val track = snapshotTrack()
        synchronized(trackLock) { trackAccumulator.clear() }
        _state.value = State()
        store?.clear()
        return track
    }
}
