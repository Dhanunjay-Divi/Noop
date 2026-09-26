package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * [DeviceRegistry] contract tests — mirror the Swift DeviceRegistryStoreTests in
 * Packages/WhoopStore. The project ships NO Robolectric (junit + kotlinx-coroutines-test only — see
 * app/build.gradle.kts and MoodStoreTest), so rather than build a real Room DB these run the REAL
 * [DeviceRegistry] over an in-memory [FakeRegistryDao] that reproduces the DAO's SQL semantics exactly:
 *   - pairedDevices()  ORDER BY addedAt ASC
 *   - activeDeviceId() the single row WHERE status='active', LIMIT 1
 *   - upsertPairedDevice() / setDayOwner()  INSERT OR REPLACE by PK
 *   - demoteActive() + promote()  the single-active swap (run together via the pass-through transactor)
 * The fake is seeded with `my-whoop` active, exactly as MIGRATION_7_8 seeds the real DB.
 */
class DeviceRegistryTest {

    /** In-memory stand-in for [DeviceRegistryDao]. The (deviceId, status) bookkeeping reproduces the
     *  pairedDevice table; [day] map reproduces dayOwnership. No transaction isolation is modelled —
     *  the registry's [DeviceRegistry.setActive] is what couples demote+promote, and the test's
     *  transactor runs the block straight through, exactly as Room's withTransaction would commit it. */
    private class FakeRegistryDao : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>() // insertion order ≈ addedAt order
        val legacyNames = LinkedHashMap<String, String?>()
        val owners = LinkedHashMap<String, DayOwnershipRow>()
        val analysisGenerations = LinkedHashMap<String, Long>()
        val analysisBounds = LinkedHashMap<String, Pair<Long?, Long?>>()
        var ownershipInputRange = AnalysisAffectedRange(null, null)
        var failUpsertFor: String? = null

        override suspend fun pairedDevices(): List<PairedDeviceRow> =
            devices.values.sortedBy { it.addedAt }

        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id

        override suspend fun upsertPairedDevice(row: PairedDeviceRow) {
            if (row.id == failUpsertFor) error("injected registry failure")
            devices[row.id] = row // INSERT OR REPLACE by id PK
        }

        override suspend fun demoteActive() {
            for ((id, row) in devices) {
                if (row.status == DeviceStatus.active.name) {
                    devices[id] = row.copy(status = DeviceStatus.paired.name)
                }
            }
        }

        override suspend fun promote(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.active.name, lastSeenAt = now) }
        }
        override suspend fun ownershipAnalysisInputRange(): AnalysisAffectedRange =
            ownershipInputRange

        override suspend fun advanceAnalysisInvalidation(
            sourceId: String,
            earliestAffectedTs: Long?,
            latestAffectedTs: Long?,
        ): Int {
            val prior = analysisGenerations[sourceId] ?: return 0
            analysisGenerations[sourceId] = prior + 1L
            analysisBounds[sourceId] = mergeBounds(
                analysisBounds[sourceId],
                earliestAffectedTs,
                latestAffectedTs,
            )
            return 1
        }
        override suspend fun insertAnalysisInvalidationIfAbsent(
            sourceId: String,
            earliestAffectedTs: Long?,
            latestAffectedTs: Long?,
        ): Long {
            if (sourceId in analysisGenerations) return -1L
            analysisGenerations[sourceId] = 1L
            analysisBounds[sourceId] = earliestAffectedTs to latestAffectedTs
            return 1L
        }

        private fun mergeBounds(
            current: Pair<Long?, Long?>?,
            earliest: Long?,
            latest: Long?,
        ): Pair<Long?, Long?> {
            val currentEarliest = current?.first
            val currentLatest = current?.second
            return (
                when {
                    earliest == null -> currentEarliest
                    currentEarliest == null -> earliest
                    else -> minOf(currentEarliest, earliest)
                }
            ) to (
                when {
                    latest == null -> currentLatest
                    currentLatest == null -> latest
                    else -> maxOf(currentLatest, latest)
                }
            )
        }

        override suspend fun archiveDevice(id: String) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.archived.name) }
        }

        override suspend fun renameDevice(id: String, nickname: String?) {
            devices[id]?.let { devices[id] = it.copy(nickname = nickname) }
        }

        override suspend fun setModel(id: String, model: String) {
            devices[id]?.let { devices[id] = it.copy(model = model) }
        }

        override suspend fun setLegacyDeviceName(id: String, model: String) {
            if (id in legacyNames) legacyNames[id] = model
        }

        override suspend fun setPeripheralId(id: String, peripheralId: String?) {
            devices[id]?.let { devices[id] = it.copy(peripheralId = peripheralId) }
        }
        override suspend fun touchLastSeen(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(lastSeenAt = now) }
        }

        override suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
            devices.values.firstOrNull { it.peripheralId == peripheralId }

        override suspend fun setDayOwner(row: DayOwnershipRow) {
            owners[row.day] = row // INSERT OR REPLACE by day PK
        }

        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]

        // deleteAllData: this fake models the registry tables only (pairedDevice/dayOwnership). The
        // sample-table deletes are validated by the real Room-backed integration; here each delete just
        // RECORDS the table name + deviceId it was asked to clear (into [deletedTables]) so a test can
        // assert the fan-out reaches every device-scoped table for the right deviceId, and the
        // dayOwnership delete additionally mutates the state the fake holds.
        val deletedTables = mutableListOf<Pair<String, String>>() // (table, deviceId), in call order
        override suspend fun deleteHrFor(deviceId: String) { deletedTables += "hrSample" to deviceId }
        override suspend fun deleteRrFor(deviceId: String) { deletedTables += "rrInterval" to deviceId }
        override suspend fun deleteSpo2For(deviceId: String) { deletedTables += "spo2Sample" to deviceId }
        override suspend fun deleteSkinTempFor(deviceId: String) { deletedTables += "skinTempSample" to deviceId }
        override suspend fun deleteRespFor(deviceId: String) { deletedTables += "respSample" to deviceId }
        override suspend fun deleteGravityFor(deviceId: String) { deletedTables += "gravitySample" to deviceId }
        override suspend fun deleteStepsFor(deviceId: String) { deletedTables += "stepSample" to deviceId }
        override suspend fun deletePpgHrFor(deviceId: String) { deletedTables += "ppgHrSample" to deviceId }
        override suspend fun deletePpgWaveformFor(deviceId: String) { deletedTables += "ppgWaveformSample" to deviceId }
        override suspend fun deleteRawImuFor(deviceId: String) { deletedTables += "rawImuSample" to deviceId }
        override suspend fun deleteEventsFor(deviceId: String) { deletedTables += "event" to deviceId }
        override suspend fun deleteBatteryFor(deviceId: String) { deletedTables += "battery" to deviceId }
        override suspend fun deleteBodyMeasurementsFor(deviceId: String) {
            deletedTables += "bodyMeasurement" to deviceId
        }
        override suspend fun deleteDailyMetricsFor(deviceId: String) { deletedTables += "dailyMetric" to deviceId }
        override suspend fun deleteSleepSessionsFor(deviceId: String) { deletedTables += "sleepSession" to deviceId }
        override suspend fun deleteJournalFor(deviceId: String) { deletedTables += "journal" to deviceId }
        override suspend fun deleteWorkoutsFor(deviceId: String) { deletedTables += "workout" to deviceId }
        override suspend fun deleteAppleDailyFor(deviceId: String) { deletedTables += "appleDaily" to deviceId }
        override suspend fun deleteMetricSeriesFor(deviceId: String) { deletedTables += "metricSeries" to deviceId }
        override suspend fun deleteDayOwnershipFor(deviceId: String) {
            deletedTables += "dayOwnership" to deviceId
            owners.entries.removeIf { it.value.deviceId == deviceId }
        }
        override suspend fun deleteSleepStatesFor(deviceId: String) { deletedTables += "sleepStateSample" to deviceId }
        override suspend fun deleteLabMarkersFor(deviceId: String) { deletedTables += "labMarker" to deviceId }
        override suspend fun deleteNutritionEntriesFor(deviceId: String) { deletedTables += "nutritionEntry" to deviceId }
        override suspend fun deleteLiveSessionsFor(deviceId: String) { deletedTables += "liveSession" to deviceId }
        override suspend fun deleteDismissedWorkoutsFor(deviceId: String) { deletedTables += "dismissedWorkout" to deviceId }
        override suspend fun deleteDismissedSleepsFor(deviceId: String) { deletedTables += "dismissedSleep" to deviceId }
        override suspend fun deleteAnalysisDirtyFor(deviceId: String) {
            deletedTables += "analysisDirtySource" to deviceId
        }
    }

    /** Registry over a rollback-capable fake transaction, matching Room's throw-to-rollback contract. */
    private fun registryWith(dao: FakeRegistryDao) =
        DeviceRegistry(
            dao,
            object : DeviceRegistry.Transactor {
                override suspend fun <R> run(block: suspend () -> R): R {
                    val devices = LinkedHashMap(dao.devices)
                    val legacyNames = LinkedHashMap(dao.legacyNames)
                    val owners = LinkedHashMap(dao.owners)
                    val generations = LinkedHashMap(dao.analysisGenerations)
                    val bounds = LinkedHashMap(dao.analysisBounds)
                    val deletedTables = dao.deletedTables.toList()
                    return try {
                        block()
                    } catch (failure: Throwable) {
                        dao.devices.clear()
                        dao.devices.putAll(devices)
                        dao.legacyNames.clear()
                        dao.legacyNames.putAll(legacyNames)
                        dao.owners.clear()
                        dao.owners.putAll(owners)
                        dao.analysisGenerations.clear()
                        dao.analysisGenerations.putAll(generations)
                        dao.analysisBounds.clear()
                        dao.analysisBounds.putAll(bounds)
                        dao.deletedTables.clear()
                        dao.deletedTables.addAll(deletedTables)
                        throw failure
                    }
                }
            },
        )

    /** Seed the fake exactly as MIGRATION_7_8 does: `my-whoop`, brand/model WHOOP, liveBLE, active. */
    private fun seededDao(): FakeRegistryDao = FakeRegistryDao().apply {
        devices["my-whoop"] = PairedDeviceRow(
            id = "my-whoop", brand = "WHOOP", model = "WHOOP", nickname = null,
            sourceKind = SourceKind.liveBLE.name,
            capabilities = "hr,hrv,spo2,skinTemp,sleep,strainLoad",
            status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        )
    }

    @Test
    fun seededWhoopIsActive() = runBlocking {
        val reg = registryWith(seededDao())
        val all = reg.all()
        assertEquals(1, all.size)
        assertEquals("my-whoop", all.first().id)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun legacyWhoopCapabilityTokensAreSanitizedAtReadTime() = runBlocking {
        val dao = seededDao()
        dao.devices["my-whoop"] = checkNotNull(dao.devices["my-whoop"]).copy(
            capabilities = "hr,spo2,steps,strainLoad",
        )

        assertEquals(
            "hr,strainLoad",
            registryWith(dao).all().single().capabilities,
        )
    }

    @Test
    fun addCommitsOnlyAfterVerifiedReadBack() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        val paired = PairedDeviceRow(
            id = "whoop-test-band",
            brand = "WHOOP",
            model = "Compatible band 5.0 / MG",
            nickname = null,
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE.name,
            capabilities = "hr,hrv",
            status = DeviceStatus.paired.name,
            addedAt = 200,
            lastSeenAt = 200,
        )

        assertTrue(reg.add(paired))
        assertEquals(paired, dao.devices["whoop-test-band"])
    }

    @Test
    fun addRollsBackAndReportsFailureWhenPersistenceFails() = runBlocking {
        val dao = seededDao().apply { failUpsertFor = "whoop-test-band" }
        val reg = registryWith(dao)
        val paired = PairedDeviceRow(
            id = "whoop-test-band",
            brand = "WHOOP",
            model = "Compatible band 5.0 / MG",
            nickname = null,
            peripheralId = "opaque-whoop",
            sourceKind = SourceKind.liveBLE.name,
            capabilities = "hr,hrv",
            status = DeviceStatus.paired.name,
            addedAt = 200,
            lastSeenAt = 200,
        )

        assertFalse(reg.add(paired))
        assertFalse(dao.devices.containsKey("whoop-test-band"))
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun setActiveDemotesPreviousAndKeepsExactlyOneActive() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        reg.add(
            PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.paired.name, addedAt = 200, lastSeenAt = 200,
            ),
        )

        reg.setActive("polar-1", now = 999)

        assertEquals("polar-1", reg.activeDeviceId())
        assertEquals(1L, dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
        val byId = reg.all().associate { it.id to it.status }
        assertEquals(DeviceStatus.active.name, byId["polar-1"])
        assertEquals(DeviceStatus.paired.name, byId["my-whoop"]) // the previously-active device demoted
        // Invariant I1: exactly one active row.
        assertEquals(1, reg.all().count { it.status == DeviceStatus.active.name })
        assertEquals(999L, reg.all().first { it.id == "polar-1" }.lastSeenAt) // promote stamped lastSeenAt
    }

    @Test
    fun addAndSetActiveCommitsOneVerifiedActiveRow() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        val supplier = PairedDeviceRow(
            id = "supplier-1",
            brand = "NOOP",
            model = "Supplier band",
            nickname = null,
            peripheralId = "AA:BB:CC:DD:EE:10",
            sourceKind = SourceKind.veepoo.name,
            capabilities = "hr",
            status = DeviceStatus.paired.name,
            addedAt = 200,
            lastSeenAt = 200,
        )

        assertTrue(reg.addAndSetActive(supplier, now = 999))

        assertEquals("supplier-1", reg.activeDeviceId())
        assertEquals(1, reg.all().count { it.status == DeviceStatus.active.name })
        assertEquals(DeviceStatus.paired.name, dao.devices.getValue("my-whoop").status)
    }

    @Test
    fun addAndSetActiveRollsBackWhenTheRegistryMutationFails() = runBlocking {
        val dao = seededDao().apply { failUpsertFor = "supplier-1" }
        val reg = registryWith(dao)
        val supplier = PairedDeviceRow(
            id = "supplier-1",
            brand = "NOOP",
            model = "Supplier band",
            nickname = null,
            peripheralId = "AA:BB:CC:DD:EE:10",
            sourceKind = SourceKind.veepoo.name,
            capabilities = "hr",
            status = DeviceStatus.paired.name,
            addedAt = 200,
            lastSeenAt = 200,
        )

        assertFalse(reg.addAndSetActive(supplier, now = 999))

        assertEquals("my-whoop", reg.activeDeviceId())
        assertFalse(dao.devices.containsKey("supplier-1"))
        assertEquals(DeviceStatus.active.name, dao.devices.getValue("my-whoop").status)
    }

    @Test
    fun unavailableSupplierReconcilesToPreferredRunningTransport() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop")
                .copy(status = DeviceStatus.paired.name)
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1",
                brand = "Polar",
                model = "H10",
                nickname = null,
                sourceKind = SourceKind.liveBLE.name,
                capabilities = "hr",
                status = DeviceStatus.paired.name,
                addedAt = 150,
                lastSeenAt = 150,
            )
            devices["supplier-1"] = PairedDeviceRow(
                id = "supplier-1",
                brand = "NOOP",
                model = "Supplier band",
                nickname = null,
                sourceKind = SourceKind.veepoo.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
            )
        }
        val reg = registryWith(dao)

        val fallback = reg.reconcileUnavailableSupplier(
            unavailableDeviceId = "supplier-1",
            preferredTransportDeviceId = "polar-1",
            now = 999,
        )

        assertEquals("polar-1", fallback)
        assertEquals("polar-1", reg.activeDeviceId())
        assertEquals(DeviceStatus.paired.name, dao.devices.getValue("supplier-1").status)
    }

    @Test
    fun unavailableSupplierFallsBackToNonArchivedWhoop() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop")
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-1"] = PairedDeviceRow(
                id = "supplier-1",
                brand = "NOOP",
                model = "Supplier band",
                nickname = null,
                sourceKind = SourceKind.veepoo.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
            )
        }
        val reg = registryWith(dao)

        val fallback = reg.reconcileUnavailableSupplier("supplier-1", now = 999)

        assertEquals("my-whoop", fallback)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun activeSupplierArchivePromotesFallbackInTheSameTransaction() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop")
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-1"] = PairedDeviceRow(
                id = "supplier-1",
                brand = "NOOP",
                model = "Supplier band",
                nickname = null,
                peripheralId = "AA:BB:CC:DD:EE:10",
                sourceKind = SourceKind.veepoo.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
            )
        }
        val reg = registryWith(dao)

        val outcome = reg.archiveSupplierAndSelectFallback("supplier-1", now = 999)

        assertNotNull(outcome)
        assertEquals("my-whoop", outcome?.activeDeviceId)
        assertEquals("my-whoop", reg.activeDeviceId())
        assertEquals(DeviceStatus.archived.name, dao.devices.getValue("supplier-1").status)
        assertEquals(DeviceStatus.active.name, dao.devices.getValue("my-whoop").status)
    }

    @Test
    fun supplierArchiveFallbackSkipsEveryImportOnlySource() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop")
                .copy(status = DeviceStatus.archived.name)
            listOf(
                "cloud" to SourceKind.cloudImport,
                "file" to SourceKind.fileImport,
                "activity" to SourceKind.activityFile,
            ).forEachIndexed { index, (id, kind) ->
                devices[id] = PairedDeviceRow(
                    id = id,
                    brand = "Import",
                    model = kind.name,
                    nickname = null,
                    sourceKind = kind.name,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = 110L + index,
                    lastSeenAt = 110L + index,
                )
            }
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1",
                brand = "Polar",
                model = "H10",
                nickname = null,
                sourceKind = SourceKind.liveBLE.name,
                capabilities = "hr",
                status = DeviceStatus.paired.name,
                addedAt = 150,
                lastSeenAt = 150,
            )
            devices["supplier-1"] = PairedDeviceRow(
                id = "supplier-1",
                brand = "NOOP",
                model = "Supplier band",
                nickname = null,
                peripheralId = "AA:BB:CC:DD:EE:10",
                sourceKind = SourceKind.veepoo.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
            )
        }
        val reg = registryWith(dao)

        val outcome = reg.archiveSupplierAndSelectFallback("supplier-1", now = 999)

        assertEquals("polar-1", outcome?.activeDeviceId)
        assertEquals("polar-1", reg.activeDeviceId())
        assertTrue(
            listOf("cloud", "file", "activity").all {
                dao.devices.getValue(it).status == DeviceStatus.paired.name
            },
        )
    }

    @Test
    fun supplierArchiveLeavesNoActiveFallbackWhenOnlyNonLiveSourcesRemain() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop")
                .copy(status = DeviceStatus.archived.name)
            listOf(
                "cloud" to SourceKind.cloudImport.name,
                "file" to SourceKind.fileImport.name,
                "activity" to SourceKind.activityFile.name,
                "unknown" to "future-import",
            ).forEachIndexed { index, (id, kind) ->
                devices[id] = PairedDeviceRow(
                    id = id,
                    brand = "Import",
                    model = kind,
                    nickname = null,
                    sourceKind = kind,
                    capabilities = "hr",
                    status = DeviceStatus.paired.name,
                    addedAt = 110L + index,
                    lastSeenAt = 110L + index,
                )
            }
            devices["supplier-1"] = PairedDeviceRow(
                id = "supplier-1",
                brand = "NOOP",
                model = "Supplier band",
                nickname = null,
                peripheralId = "AA:BB:CC:DD:EE:10",
                sourceKind = SourceKind.veepoo.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
            )
        }
        val reg = registryWith(dao)

        val outcome = reg.archiveSupplierAndSelectFallback("supplier-1", now = 999)

        assertNotNull(outcome)
        assertNull(outcome?.activeDeviceId)
        assertNull(reg.activeDeviceId())
        assertEquals(DeviceStatus.archived.name, dao.devices.getValue("supplier-1").status)
        assertTrue(
            listOf("cloud", "file", "activity", "unknown").all {
                dao.devices.getValue(it).status == DeviceStatus.paired.name
            },
        )
    }

    @Test
    fun activatableLiveTransportPredicateFailsClosedForImportsAndUnknownKinds() {
        assertTrue(SourceKind.liveBLE.isActivatableLiveTransport)
        assertTrue(SourceKind.historyBLE.isActivatableLiveTransport)
        assertTrue(SourceKind.ftms.isActivatableLiveTransport)
        assertTrue(SourceKind.huami.isActivatableLiveTransport)
        assertTrue(SourceKind.oura.isActivatableLiveTransport)
        assertTrue(SourceKind.veepoo.isActivatableLiveTransport)
        assertFalse(SourceKind.cloudImport.isActivatableLiveTransport)
        assertFalse(SourceKind.fileImport.isActivatableLiveTransport)
        assertFalse(SourceKind.activityFile.isActivatableLiveTransport)

        val unknown = seededDao().devices.getValue("my-whoop").copy(
            id = "unknown",
            brand = "Import",
            sourceKind = "future-import",
        )
        assertFalse(unknown.isActivatableLiveTransport)
    }

    @Test
    fun activeDeviceSwitchCarriesTheCompleteMeasuredHistoryRange() = runBlocking {
        val dao = seededDao().apply {
            ownershipInputRange = AnalysisAffectedRange(101L, 909L)
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.paired.name, addedAt = 200, lastSeenAt = 200,
            )
        }

        registryWith(dao).setActive("polar-1", now = 999L)

        assertEquals(
            101L to 909L,
            dao.analysisBounds[AnalysisInvalidationSource.OWNERSHIP],
        )
    }

    @Test
    fun repeatedActiveSelectionDoesNotManufactureOwnershipInvalidation() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)

        reg.setActive("my-whoop", now = 999)

        assertNull(dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
    }

    @Test
    fun archiveKeepsRowAndClearsActive() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        reg.setDayOwner("2026-09-10", "my-whoop", locked = true)
        reg.archive("my-whoop")
        // I4: the row is kept (not deleted), just archived.
        assertEquals(1, reg.all().size)
        assertEquals(DeviceStatus.archived.name, reg.all().first().status)
        assertNull(reg.activeDeviceId())
        assertNull(reg.dayOwner("2026-09-10"))
        assertEquals(2L, dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
    }

    @Test
    fun reactivatingArchivedDeviceInvalidatesOwnershipAgainAndRestoresEligibility() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)

        reg.archive("my-whoop")
        reg.setActive("my-whoop", now = 1_234L)

        assertEquals(DeviceStatus.active.name, reg.all().single().status)
        assertEquals(2L, dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
    }

    @Test
    fun renameSetsAndClearsNickname() = runBlocking {
        val reg = registryWith(seededDao())
        reg.rename("my-whoop", "  Left wrist  ")
        assertEquals("Left wrist", reg.all().first().nickname) // trimmed
        reg.rename("my-whoop", "   ")
        assertNull(reg.all().first().nickname) // blank clears it
    }

    @Test
    fun deleteDeviceDataKeepsRegistryRowAndClearsOwnership() = runBlocking {
        val reg = registryWith(seededDao())
        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertNotNull(reg.dayOwner("2026-06-15"))

        reg.deleteDeviceData("my-whoop")

        // I4: the pairedDevice registry row is NOT removed by a delete-data op.
        assertEquals(1, reg.all().size)
        assertEquals("my-whoop", reg.all().first().id)
        // dayOwnership rows for the device are cleared (the one table the JVM fake models).
        assertNull(reg.dayOwner("2026-06-15"))
    }

    /**
     * Drift guard — Kotlin twin of the Swift DeviceRegistryStoreTests schema check (which enumerates
     * sqlite_master). No Room instance is available in JVM tests, so this asserts via the DAO's own method
     * surface instead: [DeviceRegistry.deleteDeviceData] must clear ONE deviceId-keyed table per
     * `delete*For(deviceId)` method the DAO exposes. If a new `delete*For` is added (a new deviceId-keyed
     * table) but left unwired from deleteDeviceData, that device's rows would silently survive a
     * "delete all" — this fails until it's wired. Unlike the hardcoded `expectedTables` set below, this
     * can't drift: it reads the DAO surface, not a copy of it. (Java reflection — the project ships no
     * kotlin-reflect.)
     */
    @Test
    fun deleteDeviceDataCallsEveryDaoDeleteMethod() = runBlocking {
        val dao = FakeRegistryDao()
        registryWith(dao).deleteDeviceData("apple-health")

        val daoDeleteMethods = DeviceRegistryDao::class.java.declaredMethods
            .map { it.name }
            .filter { it.startsWith("delete") && it.endsWith("For") }
            .toSet()
        val clearedTables = dao.deletedTables.map { it.first }.toSet()

        assertEquals(
            "deleteDeviceData cleared ${clearedTables.size} tables but the DAO exposes " +
                "${daoDeleteMethods.size} delete*For methods — a deviceId-keyed delete is unwired, so that " +
                "device's rows would survive a delete-all. Add the missing dao.delete…For(id) call to " +
                "DeviceRegistry.deleteDeviceData.",
            daoDeleteMethods.size, clearedTables.size,
        )
    }

    @Test
    fun deleteDeviceDataForAppleHealthFansOutToEveryDeviceScopedTableAndKeepsRegistry() = runBlocking {
        // ah-delete (#616): "Remove Apple Health imported data" calls deleteDeviceData("apple-health").
        // It must clear every deviceId-keyed table for THAT source (not my-whoop) and never touch the
        // pairedDevice registry row. This mirrors the Swift store's deviceScopedTables fan-out.
        val dao = seededDao()
        val reg = registryWith(dao)

        reg.deleteDeviceData("apple-health")

        // EVERY device-keyed table the fan-out must clear (mirrors the Swift store's deviceScopedTables).
        // Keep in sync with the deviceId-keyed @Entity list in Entities.kt — the audit found the last five
        // were missing, leaving raw sleep-state, lab markers, live sessions and dismissed markers behind.
        val expectedTables = setOf(
            "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
            "stepSample", "ppgHrSample", "ppgWaveformSample", "rawImuSample", "event", "battery",
            "bodyMeasurement", "dailyMetric", "sleepSession",
            "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
            "sleepStateSample", "labMarker", "nutritionEntry", "liveSession",
            "dismissedWorkout", "dismissedSleep", "analysisDirtySource",
        )
        assertEquals(expectedTables, dao.deletedTables.map { it.first }.toSet())
        assertEquals(
            "analysisDirtySource",
            dao.deletedTables.last().first,
        )
        // Every delete was scoped to the requested device, not the seeded my-whoop.
        assertEquals(setOf("apple-health"), dao.deletedTables.map { it.second }.toSet())
        // I4: the pairedDevice registry row is left intact (apple-health is a source, not a device row).
        assertEquals(1, reg.all().size)
        assertEquals("my-whoop", reg.all().first().id)
        assertEquals("my-whoop", reg.activeDeviceId())
    }

    @Test
    fun seededWhoopHasNoPeripheralIdUntilSet() = runBlocking {
        // The v8→v9 migration adds peripheralId as a nullable column; the seeded "my-whoop" row keeps it
        // NULL until the strap is (re)paired and adopts its address. (MW-1 parity)
        val reg = registryWith(seededDao())
        assertNull(reg.all().first().peripheralId)
        assertNull(reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun setPeripheralIdRoundTrips() = runBlocking {
        val reg = registryWith(seededDao())
        reg.setPeripheralId("my-whoop", "AA:BB:CC:DD:EE:FF")
        assertEquals("AA:BB:CC:DD:EE:FF", reg.all().first().peripheralId)
        // Resolvable back from the address.
        assertEquals("my-whoop", reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF")!!.id)
        // A null clears it (back to "no stored MAC").
        reg.setPeripheralId("my-whoop", null)
        assertNull(reg.all().first().peripheralId)
        assertNull(reg.deviceForPeripheralId("AA:BB:CC:DD:EE:FF"))
    }

    @Test
    fun setModelReconcilesMatchingPairedAndLegacyRowsOnly() = runBlocking {
        val dao = seededDao().apply {
            devices["other-whoop"] = devices.getValue("my-whoop").copy(
                id = "other-whoop", model = "WHOOP 4.0", status = DeviceStatus.paired.name,
            )
            legacyNames["my-whoop"] = "WHOOP 4.0"
            legacyNames["other-whoop"] = "WHOOP 4.0"
        }
        val reg = registryWith(dao)

        reg.setModel("my-whoop", "WHOOP MG")

        assertEquals("WHOOP MG", dao.devices.getValue("my-whoop").model)
        assertEquals("WHOOP MG", dao.legacyNames["my-whoop"])
        assertEquals("WHOOP 4.0", dao.devices.getValue("other-whoop").model)
        assertEquals("WHOOP 4.0", dao.legacyNames["other-whoop"])
    }

    @Test
    fun setModelHealsLegacyNameWhenPairedModelIsAlreadyExact() = runBlocking {
        val dao = seededDao().apply {
            devices["my-whoop"] = devices.getValue("my-whoop").copy(model = "WHOOP MG")
            legacyNames["my-whoop"] = "WHOOP 4.0"
        }
        val reg = registryWith(dao)

        reg.setModel("my-whoop", "WHOOP MG")

        assertEquals("WHOOP MG", dao.devices.getValue("my-whoop").model)
        assertEquals("WHOOP MG", dao.legacyNames["my-whoop"])
    }

    @Test
    fun dayOwnerUpsertAndRead() = runBlocking {
        val dao = seededDao()
        val reg = registryWith(dao)
        assertNull(reg.dayOwner("2000-01-01"))

        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertNotNull(reg.dayOwner("2026-06-15"))
        assertEquals("my-whoop", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(true, reg.dayOwner("2026-06-15")!!.locked)
        assertEquals(1L, dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
        val utcDayStart = LocalDate.parse("2026-06-15")
            .atStartOfDay(ZoneOffset.UTC)
            .toEpochSecond()
        val maximumOffset =
            OwnershipDayInvalidationRange.MAXIMUM_SUPPORTED_TIME_ZONE_OFFSET_SECONDS
        val expectedRange = (utcDayStart - maximumOffset) to (
            utcDayStart + 86_400L + maximumOffset - 1L
        )
        assertEquals(
            expectedRange,
            dao.analysisBounds[AnalysisInvalidationSource.OWNERSHIP],
        )

        reg.setDayOwner("2026-06-15", "my-whoop", locked = true)
        assertEquals(
            "an exact replay must not manufacture analysis work",
            1L,
            dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP],
        )

        // Upsert: re-writing the same day replaces the owner + locked flag (no duplicate row).
        reg.setDayOwner("2026-06-15", "polar-1", locked = false)
        assertEquals("polar-1", reg.dayOwner("2026-06-15")!!.deviceId)
        assertEquals(false, reg.dayOwner("2026-06-15")!!.locked)
        assertEquals(2L, dao.analysisGenerations[AnalysisInvalidationSource.OWNERSHIP])
        assertEquals(
            expectedRange,
            dao.analysisBounds[AnalysisInvalidationSource.OWNERSHIP],
        )
    }
}
