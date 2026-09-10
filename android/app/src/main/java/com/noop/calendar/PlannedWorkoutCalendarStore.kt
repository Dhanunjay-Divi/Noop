package com.noop.calendar

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import com.noop.AppDiagnosticsRecorder
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.PlannedWorkoutTitleClassifier
import com.noop.ui.NoopPrefs
import java.time.ZonedDateTime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class PlannedWorkoutCalendarSnapshot(
    val day: String,
    val startSec: Long,
    val endSec: Long,
    val observedAtSec: Long,
    val revision: Long,
) {
    /**
     * Today rolls at 04:00 while Calendar Provider uses civil days. The query already proved this is
     * a future event on the current civil day, so only the planner-facing day key is bridged here.
     */
    fun asPlannedWorkout(planningDay: String = day) =
        DailyActionPlanner.PlannedWorkout(planningDay, startSec, endSec)
}

/**
 * Ephemeral Calendar Provider boundary for planned-workout guidance.
 *
 * Event content is classified inside the cursor loop and discarded there. The only published state is
 * a generic same-day time window; nothing is written to preferences, Room, diagnostics, or a network.
 */
object PlannedWorkoutCalendarStore {
    private const val CACHE_LIFETIME_MILLIS = 5L * 60L * 1_000L
    private val mutex = Mutex()
    private val stateLock = Any()
    private val _snapshot = MutableStateFlow<PlannedWorkoutCalendarSnapshot?>(null)
    val snapshot: StateFlow<PlannedWorkoutCalendarSnapshot?> = _snapshot.asStateFlow()

    private var revision = 0L
    private var invalidationGeneration = 0L
    private var lastRefreshAtMillis = 0L
    private var lastRefreshDay: String? = null

    fun clear() {
        synchronized(stateLock) {
            invalidationGeneration += 1L
            _snapshot.value = null
            lastRefreshAtMillis = 0L
            lastRefreshDay = null
        }
    }

    suspend fun refresh(
        context: Context,
        now: ZonedDateTime = ZonedDateTime.now(),
        force: Boolean = false,
    ): PlannedWorkoutCalendarSnapshot? = mutex.withLock {
        val appContext = context.applicationContext
        if (
            !NoopPrefs.adaptiveDayGuidance(appContext) ||
            !NoopPrefs.plannedWorkoutCalendar(appContext)
        ) {
            clear()
            return@withLock null
        }

        val day = now.toLocalDate().toString()
        val nowMillis = now.toInstant().toEpochMilli()
        val initialState = synchronized(stateLock) {
            Triple(
                !force &&
                    lastRefreshDay == day &&
                    nowMillis >= lastRefreshAtMillis &&
                    nowMillis - lastRefreshAtMillis < CACHE_LIFETIME_MILLIS,
                _snapshot.value,
                invalidationGeneration,
            )
        }
        if (initialState.first) return@withLock initialState.second
        val refreshGeneration = initialState.third

        val granted = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.READ_CALENDAR,
        ) == PackageManager.PERMISSION_GRANTED
        val diagnostic = AppDiagnosticsRecorder.beginOperation(
            "calendar.workout_plan_refresh",
            mapOf("permission_state" to if (granted) "granted" else "denied"),
        )
        if (!granted) {
            synchronized(stateLock) {
                if (refreshGeneration == invalidationGeneration) {
                    _snapshot.value = null
                    lastRefreshAtMillis = nowMillis
                    lastRefreshDay = day
                }
            }
            AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "permission_unavailable",
                fields = mapOf("candidate_bucket" to "zero"),
            )
            return@withLock null
        }

        val result = try {
            withContext(Dispatchers.IO) {
                query(appContext, now)
            }
        } catch (cancelled: CancellationException) {
            AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "cancelled",
                fields = mapOf("candidate_bucket" to "zero"),
            )
            throw cancelled
        } catch (_: SecurityException) {
            AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "permission_rejected",
                fields = mapOf("candidate_bucket" to "zero"),
            )
            synchronized(stateLock) {
                if (refreshGeneration == invalidationGeneration) {
                    _snapshot.value = null
                    lastRefreshAtMillis = nowMillis
                    lastRefreshDay = day
                }
            }
            return@withLock null
        } catch (_: Throwable) {
            AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = "failed",
                fields = mapOf("candidate_bucket" to "zero"),
            )
            synchronized(stateLock) {
                if (refreshGeneration == invalidationGeneration) {
                    _snapshot.value = null
                    lastRefreshAtMillis = nowMillis
                    lastRefreshDay = day
                }
            }
            return@withLock null
        }

        var rejectionOutcome: String? = null
        val published = synchronized(stateLock) {
            val stillGranted = ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.READ_CALENDAR,
            ) == PackageManager.PERMISSION_GRANTED
            if (refreshGeneration != invalidationGeneration) {
                rejectionOutcome = "superseded"
                false
            } else if (
                !NoopPrefs.adaptiveDayGuidance(appContext) ||
                !NoopPrefs.plannedWorkoutCalendar(appContext) ||
                !stillGranted
            ) {
                rejectionOutcome = "access_changed"
                false
            } else {
                revision += 1L
                _snapshot.value = result.window?.let {
                    PlannedWorkoutCalendarSnapshot(
                        day = day,
                        startSec = it.first / 1_000L,
                        endSec = it.second / 1_000L,
                        observedAtSec = now.toEpochSecond(),
                        revision = revision,
                    )
                }
                lastRefreshAtMillis = nowMillis
                lastRefreshDay = day
                true
            }
        }
        if (!published) {
            AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = rejectionOutcome ?: "access_changed",
                fields = mapOf("candidate_bucket" to "zero"),
            )
            return@withLock null
        }
        AppDiagnosticsRecorder.endOperation(
            diagnostic,
            outcome = if (result.window == null) "empty" else "matched",
            fields = mapOf("candidate_bucket" to result.candidateBucket),
        )
        _snapshot.value
    }

    private data class QueryResult(
        val window: Pair<Long, Long>?,
        val candidateBucket: String,
    )

    private fun query(context: Context, now: ZonedDateTime): QueryResult {
        val startMillis = now.toLocalDate()
            .atStartOfDay(now.zone)
            .toInstant()
            .toEpochMilli()
        val endMillis = now.toLocalDate()
            .plusDays(1)
            .atStartOfDay(now.zone)
            .toInstant()
            .toEpochMilli()
        val uriBuilder = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(uriBuilder, startMillis)
        ContentUris.appendId(uriBuilder, endMillis)
        val projection = arrayOf(
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Events.STATUS,
        )
        val cursor = context.contentResolver.query(
            uriBuilder.build(),
            projection,
            null,
            null,
            "${CalendarContract.Instances.BEGIN} ASC",
        ) ?: return QueryResult(null, "zero")

        val candidates = mutableListOf<Pair<Long, Long>>()
        cursor.use {
            val beginIndex = it.getColumnIndexOrThrow(CalendarContract.Instances.BEGIN)
            val endIndex = it.getColumnIndexOrThrow(CalendarContract.Instances.END)
            val titleIndex = it.getColumnIndexOrThrow(CalendarContract.Instances.TITLE)
            val allDayIndex = it.getColumnIndexOrThrow(CalendarContract.Instances.ALL_DAY)
            val statusIndex = it.getColumnIndexOrThrow(CalendarContract.Events.STATUS)
            while (it.moveToNext()) {
                val begin = it.getLong(beginIndex)
                val end = it.getLong(endIndex)
                val allDay = it.getInt(allDayIndex) != 0
                val cancelled =
                    !it.isNull(statusIndex) &&
                        it.getInt(statusIndex) == CalendarContract.Events.STATUS_CANCELED
                val title = if (it.isNull(titleIndex)) null else it.getString(titleIndex)
                val durationMinutes = (end - begin) / 60_000L
                if (
                    !allDay &&
                    !cancelled &&
                    begin > now.toInstant().toEpochMilli() &&
                    end > begin &&
                    durationMinutes in
                    DailyActionPlanner.MINIMUM_PLANNED_WORKOUT_MINUTES.toLong()..
                        DailyActionPlanner.MAXIMUM_PLANNED_WORKOUT_MINUTES.toLong() &&
                    PlannedWorkoutTitleClassifier.isWorkoutTitle(title)
                ) {
                    candidates += begin to end
                }
            }
        }
        val bucket = when (candidates.size) {
            0 -> "zero"
            1 -> "one"
            else -> "multiple"
        }
        return QueryResult(
            candidates.minWithOrNull(compareBy<Pair<Long, Long>> { it.first }.thenBy { it.second }),
            bucket,
        )
    }
}
