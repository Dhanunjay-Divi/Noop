package com.noop.data

import androidx.room.withTransaction
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * Device-registry façade over [WhoopDao] + [WhoopDatabase] — the Android port of the Swift
 * `DeviceRegistryStore` (Packages/WhoopStore). Owns the device list, the single-active invariant, and
 * the day-ownership override table.
 *
 * Invariant I1 (at most one `active` device) is enforced in [setActive]: the demote+promote pair runs
 * inside one transaction, so a crash mid-swap can never leave two active rows (or none).
 *
 * The transaction boundary is injected as [transactor] (defaulting to Room's `db.withTransaction`) so
 * the registry's logic is exercisable on the plain JVM without a real Room database — mirroring how the
 * rest of the test suite stays Robolectric-free (see DeviceRegistryTest / MoodStoreTest).
 */
class DeviceRegistry(
    private val dao: DeviceRegistryDao,
    private val transactor: Transactor,
) {
    /** A single-transaction boundary. Production wraps Room's `withTransaction`; tests pass through.
     *  Not a `fun interface` — a SAM method may not be generic — so implementors use the object form. */
    interface Transactor {
        suspend fun <R> run(block: suspend () -> R): R
    }

    /** Production constructor: wraps the DAO + Room transaction over [db]. */
    constructor(db: WhoopDatabase) : this(
        dao = db.whoopDao(),
        transactor = object : Transactor {
            override suspend fun <R> run(block: suspend () -> R): R = db.withTransaction { block() }
        },
    )

    private suspend fun markOwnershipDirty(affectedRange: LongRange? = null) {
        val resolvedRange = affectedRange ?: dao.ownershipAnalysisInputRange().validRange()
        val earliest = resolvedRange?.first
        val latest = resolvedRange?.last
        if (
            dao.advanceAnalysisInvalidation(
                AnalysisInvalidationSource.OWNERSHIP,
                earliest,
                latest,
            ) == 0
        ) {
            dao.insertAnalysisInvalidationIfAbsent(
                AnalysisInvalidationSource.OWNERSHIP,
                earliest,
                latest,
            )
        }
    }

    private fun AnalysisAffectedRange.validRange(): LongRange? {
        val earliest = earliestAffectedTs ?: return null
        val latest = latestAffectedTs ?: return null
        return if (earliest >= 0L && latest >= earliest) earliest..latest else null
    }

    private fun ownershipDayRange(day: String): LongRange? {
        val timestamp = runCatching {
            LocalDate.parse(day)
                .atTime(LocalTime.NOON)
                .atZone(ZoneId.systemDefault())
                .toEpochSecond()
        }.getOrNull() ?: return null
        return timestamp..timestamp
    }

    /** All paired devices, oldest first. */
    suspend fun all(): List<PairedDeviceRow> = dao.pairedDevices().map { row ->
        val whoop = row.brand.equals("WHOOP", ignoreCase = true) || row.id == "my-whoop" || row.id.startsWith("whoop-")
        if (!whoop) row else {
            val stripped = WhoopLiveCapabilities.stripSpo2Token(row.capabilities)
            if (stripped == row.capabilities) row else row.copy(capabilities = stripped)
        }
    }

    /** The single active device id, or null if none. */
    suspend fun activeDeviceId(): String? = dao.activeDeviceId()

    /** Add (or update) a device. */
    suspend fun add(row: PairedDeviceRow) = dao.upsertPairedDevice(row)

    /**
     * Make [id] the single active device. The demote-old + promote-new pair is ONE transaction so the
     * "exactly one active" invariant (I1) holds even across a crash mid-swap - mirrors the Swift
     * store's single write transaction.
     */
    suspend fun setActive(id: String, now: Long = System.currentTimeMillis() / 1000) {
        transactor.run {
            val previous = dao.activeDeviceId()
            if (previous == id) {
                dao.promote(id, now)
                return@run
            }
            dao.demoteActive()
            dao.promote(id, now)
            markOwnershipDirty()
        }
    }

    /**
     * Archive a device while preserving its row and samples (invariant I4). Ownership overrides are
     * selection metadata, not recordings: clear them atomically so an archived source cannot still win a
     * day after claim construction excludes it, then invalidate ownership for one complete recompute.
     */
    suspend fun archive(id: String) {
        transactor.run {
            val row = dao.pairedDevices().firstOrNull { it.id == id } ?: return@run
            if (row.status == DeviceStatus.archived.name) return@run
            dao.archiveDevice(id)
            dao.deleteDayOwnershipFor(id)
            markOwnershipDirty()
        }
    }

    /** Atomically update the paired model and matching legacy-device name for this exact id. */
    suspend fun setModel(id: String, model: String) {
        transactor.run {
            dao.setModel(id, model)
            dao.setLegacyDeviceName(id, model)
        }
    }

    /** Persist (or clear) a device's stable BLE peripheral identifier (the MAC address on Android). Lets
     *  the seeded "my-whoop" adopt its strap's address on first connect and a specific WHOOP confirm its
     *  identity. Façade over [DeviceRegistryDao.setPeripheralId]; mirrors the Swift store. */
    suspend fun setPeripheralId(id: String, peripheralId: String?) = dao.setPeripheralId(id, peripheralId)

    /** Record a real connection-state transition, not a high-rate sample packet. */
    suspend fun touchLastSeen(id: String, now: Long = System.currentTimeMillis() / 1000) =
        dao.touchLastSeen(id, now)

    /** The paired device whose `peripheralId` matches [peripheralId], or null if none — resolves a strap
     *  discovered by its MAC address back to its registry row. Mirrors the Swift store. */
    suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
        dao.deviceForPeripheralId(peripheralId)

    /** Rename a device. A blank [nickname] clears it so the UI falls back to brand+model. Trims
     *  whitespace, mirroring the Swift `DeviceRegistry.rename`. */
    suspend fun rename(id: String, nickname: String?) {
        val trimmed = nickname?.trim()
        dao.renameDevice(id, if (!trimmed.isNullOrEmpty()) trimmed else null)
    }

    /**
     * Permanently delete every recorded sample/derived row for [id] across all deviceId-keyed tables, in
     * ONE transaction (all-or-nothing) — the Android twin of the Swift
     * `DeviceRegistryStore.deleteAllData(deviceId:)`. The `pairedDevice` registry row is left intact: a
     * delete-data op empties recordings; archiving/removing the registry entry is a separate op (I4).
     *
     * The table set is EVERY device-keyed table of [WhoopDatabase]: hrSample, rrInterval, spo2Sample,
     * skinTempSample, respSample, gravitySample, stepSample, ppgHrSample, ppgWaveformSample, event,
     * battery, bodyMeasurement, dailyMetric,
     * sleepSession, journal, workout, appleDaily, metricSeries, dayOwnership, sleepStateSample, labMarker,
     * liveSession, dismissedWorkout, dismissedSleep, and analysisDirtySource.
     * DeviceRegistryTest.deleteDeviceDataCallsEveryDaoDeleteMethod guards completeness (fails if a
     * delete*For DAO method isn't wired in here).
     */
    suspend fun deleteDeviceData(id: String) {
        transactor.run {
            dao.deleteHrFor(id)
            dao.deleteRrFor(id)
            dao.deleteSpo2For(id)
            dao.deleteSkinTempFor(id)
            dao.deleteRespFor(id)
            dao.deleteGravityFor(id)
            dao.deleteStepsFor(id)
            dao.deletePpgHrFor(id)
            dao.deletePpgWaveformFor(id)
            dao.deleteRawImuFor(id)   // #423
            dao.deleteEventsFor(id)
            dao.deleteBatteryFor(id)
            dao.deleteBodyMeasurementsFor(id)
            dao.deleteDailyMetricsFor(id)
            dao.deleteSleepSessionsFor(id)
            dao.deleteJournalFor(id)
            dao.deleteWorkoutsFor(id)
            dao.deleteAppleDailyFor(id)
            dao.deleteMetricSeriesFor(id)
            dao.deleteDayOwnershipFor(id)
            dao.deleteSleepStatesFor(id)
            dao.deleteLabMarkersFor(id)
            dao.deleteNutritionEntriesFor(id)
            dao.deleteLiveSessionsFor(id)
            dao.deleteDismissedWorkoutsFor(id)
            dao.deleteDismissedSleepsFor(id)
            // Raw-table deletes above intentionally fire analysis triggers. Remove the marker last so a
            // completed delete-all neither retains the source identifier nor schedules an empty rescore.
            dao.deleteAnalysisDirtyFor(id)
        }
    }

    /**
     * Set the owner override for a day and durably invalidate the ownership projection in the same
     * transaction. An exact replay is a no-op: it must not manufacture another generation.
     */
    suspend fun setDayOwner(day: String, deviceId: String, locked: Boolean) {
        val replacement = DayOwnershipRow(day = day, deviceId = deviceId, locked = locked)
        transactor.run {
            if (dao.dayOwner(day) == replacement) return@run
            dao.setDayOwner(replacement)
            markOwnershipDirty(ownershipDayRange(day))
        }
    }

    /** The owner override for a day, or null if none. */
    suspend fun dayOwner(day: String): DayOwnershipRow? = dao.dayOwner(day)
}
