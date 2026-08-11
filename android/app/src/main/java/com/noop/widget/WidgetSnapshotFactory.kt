package com.noop.widget

import android.content.Context
import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.ui.logicalDayKeyNow
import com.noop.ui.resolveTodayRow
import com.noop.ui.widgetAnchorRow
import kotlinx.coroutines.flow.first
import kotlin.math.roundToInt

/**
 * One mapping from NOOP's merged day model to every Android widget. Keeping it pure prevents the
 * foreground ViewModel, BLE service and background Health Connect worker from publishing subtly
 * different scores or provenance.
 */
internal object WidgetSnapshotFactory {
    fun make(
        anchorRow: DailyMetric?,
        vitalsRow: DailyMetric? = anchorRow,
        heartRate: Int?,
        batteryPct: Int?,
        connected: Boolean,
        updatedAtMs: Long,
        liveUpdatedAtMs: Long = updatedAtMs,
    ): WidgetSnapshot = WidgetSnapshot(
        recoveryPct = anchorRow?.recovery?.roundToInt(),
        restPct = anchorRow?.let { RestScorer.restFromDaily(it)?.roundToInt() },
        effortPct = anchorRow?.strain?.roundToInt(),
        heartRate = heartRate,
        batteryPct = batteryPct,
        connected = connected,
        updatedAtMs = updatedAtMs,
        hrvMs = vitalsRow?.avgHrv?.roundToInt(),
        restingHr = vitalsRow?.restingHr,
        sleepMinutes = vitalsRow?.totalSleepMin?.roundToInt(),
        scoreDay = anchorRow?.day,
        scoreSource = sourceFor(anchorRow)?.storageKey,
        vitalsDay = vitalsRow?.day,
        vitalsSource = sourceFor(vitalsRow)?.storageKey,
        liveUpdatedAtMs = liveUpdatedAtMs,
    )

    fun sourceFor(row: DailyMetric?): WidgetScoreSource? = when (val source = row?.deviceId) {
        null -> null
        WhoopRepository.HEALTH_CONNECT_SOURCE -> WidgetScoreSource.HEALTH_CONNECT
        WhoopRepository.APPLE_HEALTH_SOURCE -> WidgetScoreSource.APPLE_HEALTH
        WhoopRepository.ACTIVITY_FILE_SOURCE -> WidgetScoreSource.ACTIVITY_FILE
        else -> if (source.endsWith("-noop")) WidgetScoreSource.NOOP else WidgetScoreSource.WEARABLE
    }

    /** Freshest day carrying an overnight vital/sleep total, independent of Recovery availability. */
    fun vitalsRow(
        days: List<DailyMetric>,
        logicalKey: String,
        localKey: String,
    ): DailyMetric? {
        fun DailyMetric.hasWidgetVital(): Boolean =
            avgHrv != null || restingHr != null || totalSleepMin != null
        val today = resolveTodayRow(days, logicalKey, localKey)
        if (today?.hasWidgetVital() == true) return today
        val upperBound = today?.day ?: logicalKey
        return days.lastOrNull { it.day < upperBound && it.hasWidgetVital() }
    }
}

/** Background-score republisher used after a successful Health Connect import. */
internal object WidgetSnapshotPublisher {
    private const val LIVE_PRESERVE_MS = 2 * 60_000L

    suspend fun refreshScores(
        context: Context,
        repository: WhoopRepository,
        activeDeviceId: String,
        nowMs: Long = System.currentTimeMillis(),
    ) {
        val days = repository.recentDaysMergedFlow(activeDeviceId).first()
        val logicalKey = logicalDayKeyNow()
        val localKey = java.time.LocalDate.now().toString()
        val anchor = widgetAnchorRow(days, logicalKey, localKey)
        val vitals = WidgetSnapshotFactory.vitalsRow(days, logicalKey, localKey)
        val previous = WidgetSnapshotStore.load(context)
        val liveIsRecent = previous.liveUpdatedAtMs > 0L &&
            nowMs - previous.liveUpdatedAtMs in 0..LIVE_PRESERVE_MS
        WidgetSnapshotStore.push(
            context,
            WidgetSnapshotFactory.make(
                anchorRow = anchor,
                vitalsRow = vitals,
                heartRate = previous.heartRate.takeIf { liveIsRecent },
                // Battery is explicitly a last-known reading and remains useful after a score-only refresh.
                batteryPct = previous.batteryPct,
                connected = previous.connected && liveIsRecent,
                updatedAtMs = nowMs,
                liveUpdatedAtMs = previous.liveUpdatedAtMs,
            ),
        )
    }
}
