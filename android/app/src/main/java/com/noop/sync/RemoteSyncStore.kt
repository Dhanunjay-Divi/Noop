package com.noop.sync

import androidx.room.withTransaction
import com.noop.data.AppleDaily
import com.noop.data.BatterySample
import com.noop.data.DailyMetric
import com.noop.data.EventRow
import com.noop.data.HrSample
import com.noop.data.JournalEntry
import com.noop.data.PairedDeviceRow
import com.noop.data.PpgHrSample
import com.noop.data.PpgWaveformSampleEntity
import com.noop.data.RespSample
import com.noop.data.RrInterval
import com.noop.data.SkinTempSample
import com.noop.data.SleepSession
import com.noop.data.Spo2Sample
import com.noop.data.StepSample
import com.noop.data.GravitySample
import com.noop.data.SleepStateSampleEntity
import com.noop.data.WhoopDatabase
import com.noop.data.WorkoutRow

/** Durable raw rows selected for one request, retaining every table's exact natural key. */
data class PendingRemoteStreams(
    val hr: List<HrSample> = emptyList(),
    val rr: List<RrInterval> = emptyList(),
    val events: List<EventRow> = emptyList(),
    val battery: List<BatterySample> = emptyList(),
    val spo2: List<Spo2Sample> = emptyList(),
    val skinTemp: List<SkinTempSample> = emptyList(),
    val respiration: List<RespSample> = emptyList(),
    val steps: List<StepSample> = emptyList(),
    val gravity: List<GravitySample> = emptyList(),
    val sleepState: List<SleepStateSampleEntity> = emptyList(),
    val ppgHr: List<PpgHrSample> = emptyList(),
    val ppgWaveform: List<PpgWaveformSampleEntity> = emptyList(),
) {
    val isEmpty: Boolean
        get() = hr.isEmpty() && rr.isEmpty() && events.isEmpty() && battery.isEmpty() &&
            spo2.isEmpty() && skinTemp.isEmpty() && respiration.isEmpty() && steps.isEmpty() &&
            gravity.isEmpty() && sleepState.isEmpty() && ppgHr.isEmpty() && ppgWaveform.isEmpty()
    val count: Int
        get() = hr.size + rr.size + events.size + battery.size + spo2.size +
            skinTemp.size + respiration.size + steps.size + gravity.size + sleepState.size +
            ppgHr.size + ppgWaveform.size
}

data class RemotePruneResult(
    val deletedRows: Int,
    val hasMoreEligibleRows: Boolean,
)

data class RemoteDerivedRows(
    val daily: List<DailyMetric> = emptyList(),
    val platformDaily: List<AppleDaily> = emptyList(),
    val sleep: List<SleepSession> = emptyList(),
    val workouts: List<WorkoutRow> = emptyList(),
    val journal: List<JournalEntry> = emptyList(),
)

interface RemoteSyncDataStore {
    suspend fun pending(deviceId: String, limitPerStream: Int): PendingRemoteStreams
    suspend fun acknowledge(deviceId: String, rows: PendingRemoteStreams)
    suspend fun reset(deviceIds: Set<String>)
    suspend fun hasPending(deviceId: String): Boolean
    suspend fun derived(
        deviceId: String,
        fromTs: Long,
        toTs: Long,
        fromDay: String,
        toDay: String,
        cursor: RemoteDerivedCursor,
        limit: Int,
        includeDaily: Boolean,
    ): RemoteDerivedRows

    suspend fun pairedDevice(deviceId: String): PairedDeviceRow?
    suspend fun pairedDevices(): List<PairedDeviceRow>
}

/** Room implementation. Acknowledgements and replay resets are atomic. */
class RoomRemoteSyncDataStore(private val database: WhoopDatabase) : RemoteSyncDataStore {
    private val dao = database.whoopDao()

    override suspend fun pending(deviceId: String, limitPerStream: Int): PendingRemoteStreams {
        val limit = limitPerStream.coerceIn(1, 10_000)
        return database.withTransaction {
            PendingRemoteStreams(
                hr = dao.pendingRemoteHr(deviceId, limit),
                rr = dao.pendingRemoteRr(deviceId, limit),
                events = dao.pendingRemoteEvents(deviceId, limit),
                battery = dao.pendingRemoteBattery(deviceId, limit),
                spo2 = dao.pendingRemoteSpo2(deviceId, limit),
                skinTemp = dao.pendingRemoteSkinTemp(deviceId, limit),
                respiration = dao.pendingRemoteResp(deviceId, limit),
                steps = dao.pendingRemoteSteps(deviceId, limit),
                gravity = dao.pendingRemoteGravity(deviceId, limit),
                sleepState = dao.pendingRemoteSleepState(deviceId, limit),
                ppgHr = dao.pendingRemotePpgHr(deviceId, limit),
                ppgWaveform = dao.pendingRemotePpgWaveform(deviceId, limit),
            )
        }
    }

    /**
     * Mark exactly the uploaded natural keys, in one transaction, only after the client returns a
     * matching `accepted` 2xx acknowledgement. Rows inserted concurrently remain pending.
     */
    override suspend fun acknowledge(deviceId: String, rows: PendingRemoteStreams) {
        if (rows.isEmpty) return
        database.withTransaction {
            rows.hr.forEach { dao.acknowledgeRemoteHr(deviceId, it.ts) }
            rows.rr.forEach { dao.acknowledgeRemoteRr(deviceId, it.ts, it.rrMs, it.seq) }
            rows.events.forEach { dao.acknowledgeRemoteEvent(deviceId, it.ts, it.kind) }
            rows.battery.forEach { dao.acknowledgeRemoteBattery(deviceId, it.ts) }
            rows.spo2.forEach { dao.acknowledgeRemoteSpo2(deviceId, it.ts) }
            rows.skinTemp.forEach { dao.acknowledgeRemoteSkinTemp(deviceId, it.ts) }
            rows.respiration.forEach { dao.acknowledgeRemoteResp(deviceId, it.ts) }
            rows.steps.forEach { dao.acknowledgeRemoteStep(deviceId, it.ts) }
            rows.gravity.forEach { dao.acknowledgeRemoteGravity(deviceId, it.ts) }
            rows.sleepState.forEach { dao.acknowledgeRemoteSleepState(deviceId, it.ts) }
            rows.ppgHr.forEach { dao.acknowledgeRemotePpgHr(deviceId, it.ts) }
            rows.ppgWaveform.forEach { dao.acknowledgeRemotePpgWaveform(deviceId, it.ts) }
        }
    }

    override suspend fun reset(deviceIds: Set<String>) {
        if (deviceIds.isEmpty()) return
        database.withTransaction {
            for (deviceId in deviceIds) {
                dao.resetRemoteHr(deviceId)
                dao.resetRemoteRr(deviceId)
                dao.resetRemoteEvents(deviceId)
                dao.resetRemoteBattery(deviceId)
                dao.resetRemoteSpo2(deviceId)
                dao.resetRemoteSkinTemp(deviceId)
                dao.resetRemoteResp(deviceId)
                dao.resetRemoteSteps(deviceId)
                dao.resetRemoteGravity(deviceId)
                dao.resetRemoteSleepState(deviceId)
                dao.resetRemotePpgHr(deviceId)
                dao.resetRemotePpgWaveform(deviceId)
            }
        }
    }

    override suspend fun hasPending(deviceId: String): Boolean =
        !pending(deviceId, limitPerStream = 1).isEmpty

    override suspend fun derived(
        deviceId: String,
        fromTs: Long,
        toTs: Long,
        fromDay: String,
        toDay: String,
        cursor: RemoteDerivedCursor,
        limit: Int,
        includeDaily: Boolean,
    ): RemoteDerivedRows = database.withTransaction {
        val boundedLimit = limit.coerceIn(1, 5_000)
        RemoteDerivedRows(
            daily = if (includeDaily) dao.dailyMetricsRange(deviceId, fromDay, toDay) else emptyList(),
            platformDaily = if (includeDaily) dao.appleDaily(deviceId, fromDay, toDay) else emptyList(),
            sleep = dao.remoteSleepSessions(
                deviceId, fromTs, toTs, cursor.sleepStartTs, boundedLimit,
            ),
            workouts = dao.remoteWorkouts(
                deviceId,
                fromTs,
                toTs,
                cursor.workoutStartTs,
                cursor.workoutSport,
                boundedLimit,
            ),
            journal = dao.remoteJournal(
                deviceId,
                fromDay,
                toDay,
                cursor.journalDay,
                cursor.journalQuestion,
                boundedLimit,
            ),
        )
    }

    override suspend fun pairedDevice(deviceId: String): PairedDeviceRow? =
        dao.pairedDevices().firstOrNull { it.id == deviceId }

    override suspend fun pairedDevices(): List<PairedDeviceRow> = dao.pairedDevices()

    suspend fun pruneAcknowledged(
        deviceId: String,
        cutoff: Long,
        limitPerStream: Int = 2_000,
    ): RemotePruneResult {
        val limit = limitPerStream.coerceIn(100, 5_000)
        return database.withTransaction {
            val deleted =
                dao.pruneRemoteHr(deviceId, cutoff, limit) +
                    dao.pruneRemoteRr(deviceId, cutoff, limit) +
                    dao.pruneRemoteEvents(deviceId, cutoff, limit) +
                    dao.pruneRemoteBattery(deviceId, cutoff, limit) +
                    dao.pruneRemoteSpo2(deviceId, cutoff, limit) +
                    dao.pruneRemoteSkinTemp(deviceId, cutoff, limit) +
                    dao.pruneRemoteResp(deviceId, cutoff, limit) +
                    dao.pruneRemoteSteps(deviceId, cutoff, limit) +
                    dao.pruneRemoteGravity(deviceId, cutoff, limit) +
                    dao.pruneRemoteSleepState(deviceId, cutoff, limit) +
                    dao.pruneRemotePpgHr(deviceId, cutoff, limit) +
                    dao.pruneRemotePpgWaveform(deviceId, cutoff, limit)
            RemotePruneResult(
                deletedRows = deleted,
                hasMoreEligibleRows = dao.hasPrunableRemoteRows(deviceId, cutoff),
            )
        }
    }
}
