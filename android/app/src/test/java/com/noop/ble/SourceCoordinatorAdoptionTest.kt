package com.noop.ble

import com.noop.data.DayOwnershipRow
import com.noop.data.DeviceRegistry
import com.noop.data.DeviceRegistryDao
import com.noop.data.DeviceStatus
import com.noop.data.AnalysisAffectedRange
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import com.noop.ble.veepoo.VeepooAttemptToken
import com.noop.ble.veepoo.VeepooAdapterState
import com.noop.ble.veepoo.VeepooBinding
import com.noop.ble.veepoo.VeepooCandidateHandle
import com.noop.ble.veepoo.VeepooCandidateRow
import com.noop.ble.veepoo.VeepooCredentialAccess
import com.noop.ble.veepoo.VeepooCredentialRead
import com.noop.ble.veepoo.VeepooDisplayState
import com.noop.ble.veepoo.VeepooManagedSource
import com.noop.ble.veepoo.VeepooProvisioningCommit
import com.noop.ble.veepoo.VeepooRevisionBinding
import com.noop.ble.veepoo.VeepooStoredCredential
import com.noop.ble.veepoo.VeepooSupplierLifecycleDiagnosticSink
import com.noop.ble.veepoo.VeepooSupplierLifecycleEvent
import com.noop.ble.veepoo.VeepooSupplierLifecycleFailure
import com.noop.ble.veepoo.VeepooSupplierLifecycleOutcome
import com.noop.ble.veepoo.VeepooSupplierLifecycleStage
import com.noop.ble.veepoo.VeepooSupplierLifecycleTrigger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [SourceCoordinator.connectedPeripheralChanged] identity-adoption + GUARD tests — the Kotlin twin of the
 * macOS `SourceCoordinator.connectedPeripheralChanged(to:)` behaviour (Strand/BLE/SourceCoordinator.swift
 * 213-231). The critical assertion is the different-strap guard: a strap whose address differs from the
 * active WHOOP row's already-adopted `peripheralId` must NEVER overwrite it (that would mis-map another
 * physical strap's samples onto this device's row).
 *
 * Harness mirrors DeviceRegistryTest: the project ships NO mocking framework and NO Robolectric (junit +
 * kotlinx-coroutines-test only — see app/build.gradle.kts), so this runs the REAL [DeviceRegistry] over an
 * in-memory [FakeRegistryDao] (the DAO's SQL semantics reproduced by hand). The coordinator's Android-only
 * deps ([context]/[repository]) are passed null — only [switchToStrap] touches them, and the adoption path
 * never reaches it. [Dispatchers.Unconfined] makes `scope.launch { … }` run eagerly inside `runBlocking`,
 * so the registry write is observable synchronously after the call.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class SourceCoordinatorAdoptionTest {

    private class FakeNoopBandSource(
        private val lifecycleOperations: MutableList<String>? = null,
    ) : LiveHrSource {
        var scans = 0
        val connections = mutableListOf<String>()
        var stops = 0

        override fun scan() {
            scans += 1
            lifecycleOperations?.add("source.scan")
        }

        override fun connect(address: String) {
            connections += address
            lifecycleOperations?.add("source.connect")
        }

        override fun stop() {
            stops += 1
            lifecycleOperations?.add("source.stop")
        }
    }

    private class FakeVeepooManagedSource(
        private val lifecycleOperations: MutableList<String>? = null,
        provisioningCommit: VeepooProvisioningCommit? = null,
    ) : VeepooManagedSource {
        private val mutableState = MutableStateFlow(VeepooAdapterState.IDLE)
        override val state: StateFlow<VeepooAdapterState> = mutableState.asStateFlow()
        private val mutableCandidates = MutableStateFlow<List<VeepooCandidateRow>>(emptyList())
        override val candidates: StateFlow<List<VeepooCandidateRow>> =
            mutableCandidates.asStateFlow()
        private val mutableDisplay = MutableStateFlow(VeepooDisplayState())
        override val display: StateFlow<VeepooDisplayState> = mutableDisplay.asStateFlow()
        val handle = VeepooCandidateHandle("candidate")
        private var pendingProvisioningCommit = provisioningCommit
        var selectionSucceeds = true
        var scanThrows = false
        var scans = 0
        var stops = 0

        override fun scan() {
            scans += 1
            if (scanThrows) error("injected scan failure")
            lifecycleOperations?.add("supplier.scan")
            mutableState.value = VeepooAdapterState.CANDIDATES_FOUND
            mutableCandidates.value = listOf(VeepooCandidateRow(handle, 1))
        }

        override fun connect(address: String) {
            lifecycleOperations?.add("supplier.connect")
            mutableState.value = VeepooAdapterState.CONNECTING
        }

        override fun stop() {
            stops += 1
            lifecycleOperations?.add("supplier.stop")
            mutableState.value = VeepooAdapterState.STOPPED
        }

        override fun selectCandidate(handle: VeepooCandidateHandle): Boolean {
            if (handle !== this.handle || !selectionSucceeds) return false
            mutableState.value = VeepooAdapterState.CONNECTING
            return true
        }

        override fun submitPairing(transportPassword: CharArray): Boolean = false

        override fun takeProvisioningCommit(): VeepooProvisioningCommit? =
            pendingProvisioningCommit.also { pendingProvisioningCommit = null }

        fun failPairing() {
            mutableState.value = VeepooAdapterState.FAILED
        }

        fun publishDisplay(value: VeepooDisplayState) {
            mutableDisplay.value = value
        }
    }

    /** In-memory [DeviceRegistryDao] (same reproduction as DeviceRegistryTest, trimmed to what's used). */
    private class FakeRegistryDao(
        private val lifecycleOperations: MutableList<String>? = null,
    ) : DeviceRegistryDao {
        val devices = LinkedHashMap<String, PairedDeviceRow>()
        val owners = LinkedHashMap<String, DayOwnershipRow>()
        val touches = mutableListOf<String>()
        var failUpsertFor: String? = null
        var failArchiveFor: String? = null
        var beforeUpsert: (suspend (PairedDeviceRow) -> Unit)? = null
        var beforeArchive: (suspend (String) -> Unit)? = null
        var beforePairedDevices: (suspend () -> Unit)? = null

        override suspend fun pairedDevices(): List<PairedDeviceRow> {
            beforePairedDevices?.invoke()
            return devices.values.sortedBy { it.addedAt }
        }
        override suspend fun activeDeviceId(): String? =
            devices.values.firstOrNull { it.status == DeviceStatus.active.name }?.id
        override suspend fun upsertPairedDevice(row: PairedDeviceRow) {
            lifecycleOperations?.add("registry.upsert")
            beforeUpsert?.invoke(row)
            if (row.id == failUpsertFor) error("injected registry failure")
            devices[row.id] = row
        }
        override suspend fun demoteActive() {
            for ((id, row) in devices) if (row.status == DeviceStatus.active.name) {
                devices[id] = row.copy(status = DeviceStatus.paired.name)
            }
        }
        override suspend fun promote(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.active.name, lastSeenAt = now) }
        }
        override suspend fun archiveDevice(id: String) {
            lifecycleOperations?.add("registry.archive")
            beforeArchive?.invoke(id)
            if (id == failArchiveFor) error("injected archive failure")
            devices[id]?.let { devices[id] = it.copy(status = DeviceStatus.archived.name) }
        }
        override suspend fun renameDevice(id: String, nickname: String?) {
            devices[id]?.let { devices[id] = it.copy(nickname = nickname) }
        }
        override suspend fun setModel(id: String, model: String) {
            devices[id]?.let { devices[id] = it.copy(model = model) }
        }
        override suspend fun setLegacyDeviceName(id: String, model: String) {}
        override suspend fun setPeripheralId(id: String, peripheralId: String?) {
            devices[id]?.let { devices[id] = it.copy(peripheralId = peripheralId) }
        }
        override suspend fun touchLastSeen(id: String, now: Long) {
            devices[id]?.let { devices[id] = it.copy(lastSeenAt = now) }
            touches += id
        }
        override suspend fun deviceForPeripheralId(peripheralId: String): PairedDeviceRow? =
            devices.values.firstOrNull { it.peripheralId == peripheralId }
        override suspend fun setDayOwner(row: DayOwnershipRow) { owners[row.day] = row }
        override suspend fun dayOwner(day: String): DayOwnershipRow? = owners[day]

        // Sample-table deletes are unmodelled here (validated by the Room-backed integration).
        override suspend fun deleteHrFor(deviceId: String) {}
        override suspend fun deleteRrFor(deviceId: String) {}
        override suspend fun deleteSpo2For(deviceId: String) {}
        override suspend fun deleteSkinTempFor(deviceId: String) {}
        override suspend fun deleteRespFor(deviceId: String) {}
        override suspend fun deleteGravityFor(deviceId: String) {}
        override suspend fun deleteStepsFor(deviceId: String) {}
        override suspend fun deletePpgHrFor(deviceId: String) {}
        override suspend fun deletePpgWaveformFor(deviceId: String) {}
        override suspend fun deleteRawImuFor(deviceId: String) {}
        override suspend fun deleteEventsFor(deviceId: String) {}
        override suspend fun deleteBatteryFor(deviceId: String) {}
        override suspend fun deleteBodyMeasurementsFor(deviceId: String) {}
        override suspend fun deleteDailyMetricsFor(deviceId: String) {}
        override suspend fun deleteSleepSessionsFor(deviceId: String) {}
        override suspend fun deleteJournalFor(deviceId: String) {}
        override suspend fun deleteWorkoutsFor(deviceId: String) {}
        override suspend fun deleteAppleDailyFor(deviceId: String) {}
        override suspend fun deleteMetricSeriesFor(deviceId: String) {}
        override suspend fun deleteSleepStatesFor(deviceId: String) {}
        override suspend fun deleteLabMarkersFor(deviceId: String) {}
        override suspend fun deleteNutritionEntriesFor(deviceId: String) {}
        override suspend fun deleteLiveSessionsFor(deviceId: String) {}
        override suspend fun deleteDismissedWorkoutsFor(deviceId: String) {}
        override suspend fun deleteDismissedSleepsFor(deviceId: String) {}
        override suspend fun deleteAnalysisDirtyFor(deviceId: String) {}
        override suspend fun ownershipAnalysisInputRange() =
            AnalysisAffectedRange(null, null)
        override suspend fun advanceAnalysisInvalidation(
            sourceId: String,
            earliestAffectedTs: Long?,
            latestAffectedTs: Long?,
        ): Int = 0
        override suspend fun insertAnalysisInvalidationIfAbsent(
            sourceId: String,
            earliestAffectedTs: Long?,
            latestAffectedTs: Long?,
        ): Long = 1L
        override suspend fun deleteDayOwnershipFor(deviceId: String) {
            owners.entries.removeIf { it.value.deviceId == deviceId }
        }
    }

    private fun registryWith(dao: FakeRegistryDao) = DeviceRegistry(
        dao,
        object : DeviceRegistry.Transactor {
            override suspend fun <R> run(block: suspend () -> R): R {
                val devices = LinkedHashMap(dao.devices)
                val owners = LinkedHashMap(dao.owners)
                val touches = dao.touches.toList()
                return try {
                    block()
                } catch (failure: Throwable) {
                    dao.devices.clear()
                    dao.devices.putAll(devices)
                    dao.owners.clear()
                    dao.owners.putAll(owners)
                    dao.touches.clear()
                    dao.touches.addAll(touches)
                    throw failure
                }
            }
        },
    )

    private fun provisioningCommit(
        peripheralId: String = "AA:BB:CC:DD:EE:10",
    ): VeepooProvisioningCommit {
        val attempt = VeepooAttemptToken.create()
        return VeepooProvisioningCommit(
            binding = VeepooBinding.create(peripheralId, attempt),
            hardwareRevision = "hw-1",
            firmwareVersion = "fw-1",
            password = "2468".toCharArray(),
        )
    }

    private class FakeCredentials(
        private val lifecycleOperations: MutableList<String>? = null,
    ) : VeepooCredentialAccess {
        data class Value(
            val password: String,
            val revisionBinding: VeepooRevisionBinding,
        )

        val values = mutableMapOf<String, Value>()
        var saveSucceeds = true
        var clearSucceeds = true
        var clearMutatesBeforeFailure = false
        var loadFails = false
        var unavailableReadsRemaining = 0

        override fun save(
            deviceId: String,
            password: CharArray,
            revisionBinding: VeepooRevisionBinding,
        ): Boolean {
            lifecycleOperations?.add("credential.save")
            if (!saveSucceeds) return false
            values[deviceId] = Value(password.concatToString(), revisionBinding)
            return true
        }

        override fun load(deviceId: String): VeepooStoredCredential? {
            lifecycleOperations?.add("credential.load")
            if (loadFails) error("injected credential read failure")
            return values[deviceId]?.let {
                VeepooStoredCredential(it.password.toCharArray(), it.revisionBinding)
            }
        }

        override fun readForRetention(deviceId: String): VeepooCredentialRead {
            lifecycleOperations?.add("credential.read")
            if (loadFails) return VeepooCredentialRead.Unavailable
            if (unavailableReadsRemaining > 0) {
                unavailableReadsRemaining -= 1
                return VeepooCredentialRead.Unavailable
            }
            return values[deviceId]?.let {
                VeepooCredentialRead.Available(
                    VeepooStoredCredential(
                        it.password.toCharArray(),
                        it.revisionBinding,
                    ),
                )
            } ?: VeepooCredentialRead.Missing
        }

        override fun clear(deviceId: String): Boolean {
            lifecycleOperations?.add("credential.clear")
            if (clearMutatesBeforeFailure) {
                values.remove(deviceId)
                return false
            }
            if (!clearSucceeds) return false
            values.remove(deviceId)
            return true
        }

        fun seed(deviceId: String, password: String = "2468") {
            values[deviceId] = Value(
                password = password,
                revisionBinding = requireNotNull(
                    VeepooRevisionBinding.from("hw-1", "fw-1"),
                ),
            )
        }
    }

    /** A WHOOP row seeded active, with the given [peripheralId] (null = not yet adopted). */
    private fun whoopRow(id: String, peripheralId: String?) = PairedDeviceRow(
        id = id, brand = "WHOOP", model = "WHOOP", nickname = null,
        sourceKind = SourceKind.liveBLE.name, capabilities = "hr",
        status = DeviceStatus.active.name, addedAt = 100, lastSeenAt = 100,
        peripheralId = peripheralId,
    )

    private fun supplierRow(
        id: String = "supplier-band",
        status: DeviceStatus = DeviceStatus.active,
    ) = PairedDeviceRow(
        id = id,
        brand = "NOOP",
        model = "Supplier band",
        nickname = null,
        sourceKind = SourceKind.veepoo.name,
        capabilities = "hr",
        status = status.name,
        addedAt = 200,
        lastSeenAt = 200,
        peripheralId = "AA:BB:CC:DD:EE:10",
    )

    private fun liveTransportRow(
        id: String,
        sourceKind: SourceKind,
        status: DeviceStatus = DeviceStatus.active,
    ) = PairedDeviceRow(
        id = id,
        brand = if (sourceKind == SourceKind.veepoo) "NOOP" else "Test",
        model = sourceKind.name,
        nickname = null,
        sourceKind = sourceKind.name,
        capabilities = "hr",
        status = status.name,
        addedAt = 200,
        lastSeenAt = 200,
        peripheralId = null,
    )

    private fun coordinatorOver(dao: FakeRegistryDao, log: (String) -> Unit = {}): SourceCoordinator =
        SourceCoordinator(
            context = null,                       // adoption path never reaches switchToStrap
            registry = registryWith(dao),
            repository = null,                    // same
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined), // launch runs eagerly inside runBlocking
            log = log,
        )

    /** A coordinator that counts the WHOOP start/stop churn, for the make-active adopt-in-place tests. */
    private fun churnCountingCoordinator(
        dao: FakeRegistryDao,
        starts: () -> Unit,
        stops: () -> Unit,
    ): SourceCoordinator = SourceCoordinator(
        context = null,
        registry = registryWith(dao),
        repository = null,
        liveSink = { _, _ -> },
        startWhoop = starts,
        stopWhoop = stops,
        scope = CoroutineScope(Dispatchers.Unconfined),
    )

    @Test
    fun nullPeripheralIdRowAdoptsConnectedAddress() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertEquals(listOf("my-whoop"), dao.touches)
    }

    @Test
    fun matchingAddressIsANoOp() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        // Same strap reconnecting (case-insensitive match) — identity is unchanged and no mismatch logs;
        // the real connection transition is still allowed to refresh lastSeen.
        coordinator.connectedPeripheralChanged("aa:bb:cc:dd:ee:01")

        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        assertNull("matching address must not log a different-strap notice", logged)
        assertEquals(listOf("my-whoop"), dao.touches)
    }

    @Test
    fun differentStrapDoesNotOverwriteAndLogs() = runBlocking {
        // The GUARD: the active WHOOP row already adopted ...:01; a DIFFERENT strap ...:02 connects.
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        var logged: String? = null
        val coordinator = coordinatorOver(dao) { logged = it }

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:02")

        // Stored identity is UNCHANGED — the other strap's address never lands on this row.
        assertEquals("AA:BB:CC:DD:EE:01", dao.devices["my-whoop"]!!.peripheralId)
        // And the mismatch is logged with the exact macOS wording.
        assertEquals(
            "Multi-WHOOP: active device my-whoop is registered to strap AA:BB:CC:DD:EE:01 but " +
                "AA:BB:CC:DD:EE:02 connected - not overwriting.",
            logged,
        )
        assertTrue("a different physical strap must not refresh this row", dao.touches.isEmpty())
    }

    @Test
    fun nullAddressIsIgnored() = runBlocking {
        val dao = FakeRegistryDao().apply { devices["my-whoop"] = whoopRow("my-whoop", peripheralId = null) }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged(null) // a disconnect republish

        assertNull(dao.devices["my-whoop"]!!.peripheralId) // nothing adopted
        assertTrue(dao.touches.isEmpty())
    }

    @Test
    fun actualConnectAndDisconnectEachStampLastSeenOnce() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", peripheralId = "AA:BB:CC:DD:EE:01")
        }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        coordinator.connectedPeripheralChanged(null)

        assertEquals(listOf("my-whoop", "my-whoop"), dao.touches)
    }

    @Test
    fun nonWhoopActiveDeviceIsIgnored() = runBlocking {
        // A generic strap is the active device — this WHOOP-side connection isn't ours; do not touch it.
        val dao = FakeRegistryDao().apply {
            devices["polar-1"] = PairedDeviceRow(
                id = "polar-1", brand = "Polar", model = "H10", nickname = null,
                sourceKind = SourceKind.liveBLE.name, capabilities = "hr,hrv",
                status = DeviceStatus.active.name, addedAt = 200, lastSeenAt = 200,
                peripheralId = null,
            )
        }
        val coordinator = coordinatorOver(dao)

        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")

        assertNull("a generic-strap active row must not adopt a WHOOP connection's address",
            dao.devices["polar-1"]!!.peripheralId)
        assertTrue(dao.devices.size == 1)
        assertTrue(dao.touches.isEmpty())
    }

    // ── make-active adopt-in-place (#74 keep) ───────────────────────────────────
    // switchToWhoop: activating a WHOOP row that is the SAME physical strap already connected must NOT
    // churn the link (no stopWhoop/startWhoop) - a churn there would drop the kept live link and force a
    // scan reconnect. Activating a DIFFERENT WHOOP must still churn.

    /** Seed two ACTIVE-capable WHOOP rows sharing the dao; only [activeId] is marked active. */
    private fun daoWithTwoWhoops(
        activeId: String,
        activePeripheral: String?,
        otherId: String,
        otherPeripheral: String?,
    ): FakeRegistryDao = FakeRegistryDao().apply {
        devices[activeId] = whoopRow(activeId, activePeripheral)
        // the other row is paired (not active) until we promote it
        devices[otherId] = whoopRow(otherId, otherPeripheral).copy(status = DeviceStatus.paired.name)
    }

    @Test
    fun makeActiveSameStrapAdoptsInPlaceWithoutChurn() = runBlocking {
        // Two WHOOP rows for the SAME physical strap (pick-same-strap Add flow): identical peripheralId.
        val dao = daoWithTwoWhoops(
            activeId = "my-whoop", activePeripheral = "AA:BB:CC:DD:EE:01",
            otherId = "whoop-aabbccddee01", otherPeripheral = "AA:BB:CC:DD:EE:01",
        )
        var starts = 0
        var stops = 0
        val coordinator = churnCountingCoordinator(dao, starts = { starts++ }, stops = { stops++ })

        coordinator.start()                                     // first WHOOP activation, no churn
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01") // link is live on this strap
        // Make the second (same-strap) row active, then reconcile it.
        dao.demoteActive(); dao.promote("whoop-aabbccddee01", 200)
        coordinator.onActiveDeviceChanged("whoop-aabbccddee01")

        assertEquals("same-strap make-active must not stop the live link", 0, stops)
        assertEquals("same-strap make-active must not rescan", 0, starts)
    }

    @Test
    fun makeActiveDifferentStrapStillChurns() = runBlocking {
        // Two WHOOP rows for DIFFERENT physical straps: switching must drop + reconnect.
        val dao = daoWithTwoWhoops(
            activeId = "my-whoop", activePeripheral = "AA:BB:CC:DD:EE:01",
            otherId = "whoop-aabbccddee02", otherPeripheral = "AA:BB:CC:DD:EE:02",
        )
        var starts = 0
        var stops = 0
        val coordinator = churnCountingCoordinator(dao, starts = { starts++ }, stops = { stops++ })

        coordinator.start()
        coordinator.connectedPeripheralChanged("AA:BB:CC:DD:EE:01")
        dao.demoteActive(); dao.promote("whoop-aabbccddee02", 200)
        coordinator.onActiveDeviceChanged("whoop-aabbccddee02")

        assertEquals("a different WHOOP must drop the current link", 1, stops)
        assertEquals("a different WHOOP must reconnect", 1, starts)
    }

    @Test
    fun explicitNoopBandFactoryOwnsNonWhoopLifecycle() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["noop-band-synthetic"] = PairedDeviceRow(
                id = "noop-band-synthetic",
                brand = "NOOP",
                model = "Synthetic",
                nickname = null,
                sourceKind = SourceKind.liveBLE.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 200,
                lastSeenAt = 200,
                peripheralId = null,
            )
        }
        val source = FakeNoopBandSource()
        val requested = mutableListOf<String>()
        var starts = 0
        var stops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = { stops += 1 },
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                requested += id
                source
            },
        )

        coordinator.onActiveDeviceChanged("noop-band-synthetic")
        assertEquals(listOf("noop-band-synthetic"), requested)
        assertEquals(1, stops)
        assertEquals(1, source.scans)
        assertTrue(source.connections.isEmpty())

        dao.demoteActive()
        dao.promote("my-whoop", 300)
        coordinator.onActiveDeviceChanged("my-whoop")
        assertEquals(1, source.stops)
        assertEquals(1, starts)
    }

    @Test
    fun whoopDefaultNeverRequestsNoopBandFactory() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
        }
        var factoryCalls = 0
        var starts = 0
        var stops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = { stops += 1 },
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { _, _ ->
                factoryCalls += 1
                FakeNoopBandSource()
            },
        )

        coordinator.start()
        assertEquals(0, factoryCalls)
        assertEquals(0, starts)
        assertEquals(0, stops)
    }

    @Test
    fun supplierAdoptionCompensatesCredentialWhenRegistryTransactionFails() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
            failUpsertFor = "supplier-new"
        }
        val credentials = FakeCredentials()
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val attempt = VeepooAttemptToken.create()
        val provisioning = VeepooProvisioningCommit(
            binding = VeepooBinding.create("AA:BB:CC:DD:EE:10", attempt),
            hardwareRevision = "hw",
            firmwareVersion = "fw",
            password = "2468".toCharArray(),
        )

        val adopted = VeepooPairingAdoption(
            registry = registryWith(dao),
            credentials = credentials,
            diagnostics = VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
        ).commit(
            deviceId = "supplier-new",
            nickname = "  Supplier  ",
            provisioning = provisioning,
            now = 500,
        )

        assertFalse(adopted)
        assertEquals("my-whoop", dao.activeDeviceId())
        assertFalse(dao.devices.containsKey("supplier-new"))
        assertTrue(credentials.values.isEmpty())
        assertEquals(
            listOf(
                VeepooSupplierLifecycleStage.ADOPTION to VeepooSupplierLifecycleOutcome.BEGAN,
                VeepooSupplierLifecycleStage.SECURE_CLEANUP to
                    VeepooSupplierLifecycleOutcome.COMPLETED,
                VeepooSupplierLifecycleStage.ADOPTION to VeepooSupplierLifecycleOutcome.FAILED,
            ),
            diagnostics.map { it.stage to it.outcome },
        )
        assertEquals(
            VeepooSupplierLifecycleFailure.REGISTRY_PERSISTENCE,
            diagnostics.last().failure,
        )
    }

    @Test
    fun queuedCancellationFromCommittingPairingCannotClearNewGeneration() = runTest {
        val upsertStarted = CompletableDeferred<Unit>()
        val releaseUpsert = CompletableDeferred<Unit>()
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
            beforeUpsert = {
                upsertStarted.complete(Unit)
                releaseUpsert.await()
            }
        }
        val pairingSources = mutableListOf<FakeVeepooManagedSource>()
        val coordinatorScheduler = TestCoroutineScheduler()
        val coordinatorJob = Job()
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(
                coordinatorJob + StandardTestDispatcher(coordinatorScheduler),
            ),
            noopBandSourceFactory = { _, _ -> FakeNoopBandSource() },
            veepooPairingSourceFactory = {
                FakeVeepooManagedSource(
                    provisioningCommit = if (pairingSources.isEmpty()) {
                        provisioningCommit()
                    } else {
                        null
                    },
                ).also(pairingSources::add)
            },
            veepooCredentials = FakeCredentials(),
        )

        try {
            assertTrue(coordinator.beginVeepooPairing())
            val commit = async { coordinator.commitVeepooPairing("Band") }
            upsertStarted.await()

            coordinator.cancelVeepooPairing()
            releaseUpsert.complete(Unit)
            assertTrue(commit.await())

            assertTrue(coordinator.beginVeepooPairing())
            val replacement = pairingSources.last()
            coordinatorScheduler.runCurrent()

            assertEquals(2, pairingSources.size)
            assertEquals(1, pairingSources.first().stops)
            assertEquals(0, replacement.stops)
            assertTrue(coordinator.selectVeepooCandidate(replacement.handle))
        } finally {
            coordinatorJob.cancel()
        }
    }

    @Test
    fun pairingWaitsForReconciliationLockInsteadOfFailingOnContention() = runTest {
        val readStarted = CompletableDeferred<Unit>()
        val releaseRead = CompletableDeferred<Unit>()
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
            beforePairedDevices = {
                readStarted.complete(Unit)
                releaseRead.await()
                beforePairedDevices = null
            }
        }
        val pairing = FakeVeepooManagedSource()
        val coordinatorScheduler = TestCoroutineScheduler()
        val coordinatorJob = Job()
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(
                coordinatorJob + StandardTestDispatcher(coordinatorScheduler),
            ),
            veepooPairingSourceFactory = { pairing },
            veepooCredentials = FakeCredentials(),
        )

        try {
            coordinator.start()
            coordinatorScheduler.runCurrent()
            readStarted.await()
            val begin = async { coordinator.beginVeepooPairing() }
            coordinatorScheduler.runCurrent()
            assertFalse(begin.isCompleted)

            releaseRead.complete(Unit)
            coordinatorScheduler.runCurrent()

            assertTrue(begin.await())
            assertEquals(1, pairing.scans)
        } finally {
            coordinatorJob.cancel()
        }
    }

    @Test
    fun cancellationInvalidatesPairingStartWaitingForReconciliationLock() = runTest {
        val readStarted = CompletableDeferred<Unit>()
        val releaseRead = CompletableDeferred<Unit>()
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
            beforePairedDevices = {
                readStarted.complete(Unit)
                releaseRead.await()
                beforePairedDevices = null
            }
        }
        val pairing = FakeVeepooManagedSource()
        val coordinatorScheduler = TestCoroutineScheduler()
        val coordinatorJob = Job()
        var whoopStops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = { whoopStops += 1 },
            scope = CoroutineScope(
                coordinatorJob + StandardTestDispatcher(coordinatorScheduler),
            ),
            veepooPairingSourceFactory = { pairing },
            veepooCredentials = FakeCredentials(),
        )

        try {
            coordinator.start()
            coordinatorScheduler.runCurrent()
            readStarted.await()
            val begin = async(start = CoroutineStart.UNDISPATCHED) {
                coordinator.beginVeepooPairing()
            }
            assertFalse(begin.isCompleted)

            coordinator.cancelVeepooPairing()
            releaseRead.complete(Unit)
            coordinatorScheduler.runCurrent()
            testScheduler.runCurrent()
            coordinatorScheduler.runCurrent()

            assertFalse(begin.await())
            assertEquals(0, pairing.scans)
            assertEquals(0, pairing.stops)
            assertEquals(0, whoopStops)
        } finally {
            coordinatorJob.cancel()
        }
    }

    @Test
    fun pairingScanFailureRestoresPausedWhoop() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
        }
        val pairing = FakeVeepooManagedSource().apply {
            scanThrows = true
        }
        var whoopStarts = 0
        var whoopStops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { whoopStarts += 1 },
            stopWhoop = { whoopStops += 1 },
            scope = CoroutineScope(Dispatchers.Unconfined),
            veepooPairingSourceFactory = { pairing },
            veepooCredentials = FakeCredentials(),
        )

        coordinator.start()

        assertFalse(coordinator.beginVeepooPairing())
        assertEquals(1, pairing.scans)
        assertEquals(1, pairing.stops)
        assertEquals(1, whoopStops)
        assertEquals(1, whoopStarts)
    }

    @Test
    fun transientCredentialReadKeepsSupplierActiveAndRetries() = runTest {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val credentials = FakeCredentials().apply {
            seed("supplier-band")
            unavailableReadsRemaining = 1
        }
        val sources = mutableListOf<FakeNoopBandSource>()
        var whoopStops = 0
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = { whoopStops += 1 },
            scope = this,
            veepooActiveSourceFactory = { id, _ ->
                check(id == "supplier-band")
                FakeNoopBandSource().also(sources::add)
            },
            veepooCredentials = credentials,
            veepooLifecycleDiagnostics =
                VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
            supplierCredentialRetryDelaysMillis = listOf(1L),
        )

        coordinator.start()
        testScheduler.runCurrent()

        assertEquals("supplier-band", dao.activeDeviceId())
        assertTrue(sources.isEmpty())
        assertEquals(1, whoopStops)

        advanceTimeBy(1L)
        testScheduler.runCurrent()

        assertEquals("supplier-band", dao.activeDeviceId())
        assertEquals(1, sources.size)
        assertEquals(1, sources.single().connections.size)
        assertEquals(1, whoopStops)
        assertTrue(
            diagnostics.any {
                it.stage == VeepooSupplierLifecycleStage.SECURE_READ &&
                    it.outcome == VeepooSupplierLifecycleOutcome.FAILED
            },
        )
        assertTrue(
            diagnostics.any {
                it.stage == VeepooSupplierLifecycleStage.SECURE_READ &&
                    it.outcome == VeepooSupplierLifecycleOutcome.COMPLETED
            },
        )
    }

    @Test
    fun pairingDuringCredentialRetryResumesDurableSupplierAfterCancellation() = runTest {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val credentials = FakeCredentials().apply {
            seed("supplier-band")
            unavailableReadsRemaining = 2
        }
        val pairing = FakeVeepooManagedSource()
        val sources = mutableListOf<FakeNoopBandSource>()
        var whoopStops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = { whoopStops += 1 },
            scope = this,
            veepooPairingSourceFactory = { pairing },
            veepooActiveSourceFactory = { _, _ ->
                FakeNoopBandSource().also(sources::add)
            },
            veepooCredentials = credentials,
            supplierCredentialRetryDelaysMillis = listOf(10L),
        )

        coordinator.start()
        testScheduler.runCurrent()

        assertEquals(1, whoopStops)
        assertEquals(1, credentials.unavailableReadsRemaining)
        assertTrue(sources.isEmpty())
        assertTrue(coordinator.beginVeepooPairing())
        assertEquals(1, pairing.scans)

        advanceTimeBy(10L)
        testScheduler.runCurrent()
        assertEquals(1, credentials.unavailableReadsRemaining)
        assertTrue(sources.isEmpty())

        coordinator.cancelVeepooPairing()
        testScheduler.runCurrent()
        assertEquals(1, pairing.stops)
        assertEquals(0, credentials.unavailableReadsRemaining)
        assertTrue(sources.isEmpty())

        advanceTimeBy(10L)
        testScheduler.runCurrent()
        assertEquals(1, sources.size)
        assertEquals(1, sources.single().connections.size)
        assertEquals("supplier-band", dao.activeDeviceId())
    }

    @Test
    fun unavailableSupplierRestoresDurableWhoopWithoutStoppingTheRunningWhoop() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val projected = mutableListOf<String>()
        var starts = 0
        var stops = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = { stops += 1 },
            scope = CoroutineScope(Dispatchers.Unconfined),
            veepooCredentials = FakeCredentials(),
            veepooLifecycleDiagnostics =
                VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
            onDurableActiveDeviceChanged = projected::add,
        )

        coordinator.start()

        assertEquals("my-whoop", dao.activeDeviceId())
        assertEquals(listOf("my-whoop"), projected)
        assertEquals(0, starts)
        assertEquals(0, stops)
        assertTrue(
            diagnostics.any {
                it.stage == VeepooSupplierLifecycleStage.RECONCILIATION &&
                    it.outcome == VeepooSupplierLifecycleOutcome.COMPLETED &&
                    it.trigger == VeepooSupplierLifecycleTrigger.SOURCE_UNAVAILABLE
            },
        )
    }

    @Test
    fun unavailableSupplierKeepsTheStillRunningFallbackStrap() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["polar"] = PairedDeviceRow(
                id = "polar",
                brand = "Polar",
                model = "H10",
                nickname = null,
                sourceKind = SourceKind.liveBLE.name,
                capabilities = "hr",
                status = DeviceStatus.active.name,
                addedAt = 150,
                lastSeenAt = 150,
            )
            devices["supplier-band"] = supplierRow(status = DeviceStatus.paired)
        }
        val fallback = FakeNoopBandSource()
        val projected = mutableListOf<String>()
        var stops = 0
        val registry = registryWith(dao)
        val coordinator = SourceCoordinator(
            context = null,
            registry = registry,
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = { stops += 1 },
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ -> if (id == "polar") fallback else null },
            veepooCredentials = FakeCredentials(),
            onDurableActiveDeviceChanged = projected::add,
        )
        coordinator.start()
        registry.setActive("supplier-band", now = 300)

        coordinator.onActiveDeviceChanged("supplier-band")

        assertEquals("polar", dao.activeDeviceId())
        assertEquals(listOf("polar"), projected)
        assertEquals(1, stops)
        assertEquals(0, fallback.stops)
        assertEquals(1, fallback.scans)
    }

    @Test
    fun authenticationRejectionClearsCredentialAndStartsDurableWhoopFallback() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val source = FakeNoopBandSource()
        val credentials = FakeCredentials().apply { seed("supplier-band") }
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val projected = mutableListOf<String>()
        var starts = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ -> if (id == "supplier-band") source else null },
            veepooCredentials = credentials,
            veepooLifecycleDiagnostics =
                VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
            onDurableActiveDeviceChanged = projected::add,
        )
        coordinator.start()

        coordinator.onVeepooAuthenticationRejected("supplier-band", source)

        assertEquals("my-whoop", dao.activeDeviceId())
        assertFalse(credentials.values.containsKey("supplier-band"))
        assertEquals(0, source.stops)
        assertEquals(1, starts)
        assertEquals(listOf("my-whoop"), projected)
        assertTrue(
            diagnostics.any {
                it.stage == VeepooSupplierLifecycleStage.RECONCILIATION &&
                    it.outcome == VeepooSupplierLifecycleOutcome.COMPLETED &&
                    it.trigger == VeepooSupplierLifecycleTrigger.AUTHENTICATION_REJECTED
            },
        )
    }

    @Test
    fun authenticationRejectionWaitsForRemovalRollbackBeforeClearingCredential() = runTest {
        val operations = mutableListOf<String>()
        val archiveStarted = CompletableDeferred<Unit>()
        val releaseArchive = CompletableDeferred<Unit>()
        val dao = FakeRegistryDao(operations).apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
            failArchiveFor = "supplier-band"
            beforeArchive = {
                archiveStarted.complete(Unit)
                releaseArchive.await()
            }
        }
        val sources = mutableListOf<FakeNoopBandSource>()
        val credentials = FakeCredentials(operations).apply { seed("supplier-band") }
        val coordinatorScheduler = TestCoroutineScheduler()
        val coordinatorJob = Job()
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(
                coordinatorJob + StandardTestDispatcher(coordinatorScheduler),
            ),
            noopBandSourceFactory = { id, _ ->
                if (id != "supplier-band") {
                    null
                } else {
                    FakeNoopBandSource(operations).also(sources::add)
                }
            },
            veepooCredentials = credentials,
        )

        try {
            coordinator.start()
            coordinatorScheduler.runCurrent()
            val rejectedSource = sources.single()
            operations.clear()

            val removal = async { coordinator.archiveVeepooDevice("supplier-band") }
            archiveStarted.await()
            coordinator.onVeepooAuthenticationRejected("supplier-band", rejectedSource)
            coordinatorScheduler.runCurrent()

            assertEquals(1, operations.count { it == "credential.clear" })

            releaseArchive.complete(Unit)
            assertFalse(removal.await())
            assertEquals("2468", credentials.values["supplier-band"]?.password)
            assertEquals(2, sources.size)
            val replacement = sources.last()

            coordinatorScheduler.runCurrent()

            assertFalse(credentials.values.containsKey("supplier-band"))
            assertEquals("my-whoop", dao.activeDeviceId())
            assertEquals(1, replacement.stops)
            assertTrue(
                operations.indexOf("credential.save") <
                    operations.lastIndexOf("credential.clear"),
            )
        } finally {
            coordinatorJob.cancel()
        }
    }

    @Test
    fun runtimeFailurePreservesCredentialAndStartsDurableWhoopFallback() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val source = FakeNoopBandSource()
        val credentials = FakeCredentials().apply { seed("supplier-band") }
        var starts = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ -> if (id == "supplier-band") source else null },
            veepooCredentials = credentials,
        )
        coordinator.start()

        coordinator.onVeepooRuntimeUnavailable("supplier-band", source)

        assertEquals("my-whoop", dao.activeDeviceId())
        assertEquals("2468", credentials.values["supplier-band"]?.password)
        assertEquals(0, source.stops)
        assertEquals(1, starts)
    }

    @Test
    fun delayedRuntimeFailureFromReplacedSourceDoesNotDemoteReplacement() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val sources = mutableListOf<FakeNoopBandSource>()
        val credentials = FakeCredentials().apply { seed("supplier-band") }
        var starts = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                if (id != "supplier-band") null else FakeNoopBandSource().also(sources::add)
            },
            veepooCredentials = credentials,
        )
        coordinator.start()
        val obsolete = sources.single()

        dao.devices["supplier-band"] = supplierRow(status = DeviceStatus.paired)
        dao.devices["my-whoop"] = whoopRow("my-whoop", null)
        coordinator.onActiveDeviceChanged("my-whoop")
        dao.devices["my-whoop"] = whoopRow("my-whoop", null)
            .copy(status = DeviceStatus.paired.name)
        dao.devices["supplier-band"] = supplierRow()
        coordinator.onActiveDeviceChanged("supplier-band")
        val replacement = sources.last()
        val startsBeforeDelayedCallback = starts

        coordinator.onVeepooRuntimeUnavailable("supplier-band", obsolete)

        assertEquals("supplier-band", dao.activeDeviceId())
        assertEquals(2, sources.size)
        assertEquals(0, replacement.stops)
        assertEquals(startsBeforeDelayedCallback, starts)
    }

    @Test
    fun activeSupplierRemovalStopsThenClearsThenArchives() = runBlocking {
        val operations = mutableListOf<String>()
        val dao = FakeRegistryDao(operations).apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val source = FakeNoopBandSource(operations)
        val credentials = FakeCredentials(operations).apply { seed("supplier-band") }
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val projected = mutableListOf<String>()
        var starts = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { starts += 1 },
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ -> if (id == "supplier-band") source else null },
            veepooCredentials = credentials,
            veepooLifecycleDiagnostics =
                VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
            onDurableActiveDeviceChanged = projected::add,
        )
        coordinator.start()
        operations.clear()

        val archived = coordinator.archiveVeepooDevice("supplier-band")

        assertTrue(archived)
        assertEquals(DeviceStatus.archived.name, dao.devices.getValue("supplier-band").status)
        assertEquals("my-whoop", dao.activeDeviceId())
        assertFalse(credentials.values.containsKey("supplier-band"))
        assertEquals(listOf("my-whoop"), projected)
        assertEquals(1, starts)
        assertTrue(operations.indexOf("source.stop") < operations.indexOf("credential.clear"))
        assertTrue(operations.indexOf("credential.clear") < operations.indexOf("registry.archive"))
        assertTrue(
            diagnostics.any {
                it.stage == VeepooSupplierLifecycleStage.REMOVAL &&
                    it.outcome == VeepooSupplierLifecycleOutcome.COMPLETED
            },
        )
    }

    @Test
    fun supplierRemovalRestoresCredentialBeforeReconnectWhenClearMutatesThenFails() = runBlocking {
        val operations = mutableListOf<String>()
        val dao = FakeRegistryDao(operations).apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val sources = mutableListOf<FakeNoopBandSource>()
        val credentials = FakeCredentials(operations).apply {
            seed("supplier-band")
            clearMutatesBeforeFailure = true
        }
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                if (id != "supplier-band") {
                    null
                } else {
                    FakeNoopBandSource(operations).also(sources::add)
                }
            },
            veepooCredentials = credentials,
        )
        coordinator.start()
        operations.clear()

        val archived = coordinator.archiveVeepooDevice("supplier-band")

        assertFalse(archived)
        assertEquals("supplier-band", dao.activeDeviceId())
        assertEquals("2468", credentials.values["supplier-band"]?.password)
        assertEquals(2, sources.size)
        assertEquals(1, sources.last().connections.size)
        assertTrue(operations.indexOf("credential.clear") < operations.indexOf("credential.save"))
        assertTrue(operations.indexOf("credential.save") < operations.indexOf("source.connect"))
        assertFalse(operations.contains("registry.archive"))
    }

    @Test
    fun supplierRemovalRestoresCredentialAndSourceWhenArchiveFails() = runBlocking {
        val operations = mutableListOf<String>()
        val dao = FakeRegistryDao(operations).apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
            failArchiveFor = "supplier-band"
        }
        val sources = mutableListOf<FakeNoopBandSource>()
        val credentials = FakeCredentials(operations).apply { seed("supplier-band") }
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                if (id != "supplier-band") {
                    null
                } else {
                    FakeNoopBandSource(operations).also(sources::add)
                }
            },
            veepooCredentials = credentials,
        )
        coordinator.start()
        operations.clear()

        val archived = coordinator.archiveVeepooDevice("supplier-band")

        assertFalse(archived)
        assertEquals("supplier-band", dao.activeDeviceId())
        assertEquals("2468", credentials.values["supplier-band"]?.password)
        assertEquals(2, sources.size)
        assertEquals(1, sources.last().connections.size)
        assertTrue(operations.indexOf("credential.clear") < operations.indexOf("registry.archive"))
        assertTrue(operations.indexOf("registry.archive") < operations.indexOf("credential.save"))
    }

    @Test
    fun supplierRemovalAbortsBeforeStoppingWhenCredentialCannotBeRetained() = runBlocking {
        val operations = mutableListOf<String>()
        val dao = FakeRegistryDao(operations).apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val source = FakeNoopBandSource(operations)
        val credentials = FakeCredentials(operations).apply {
            seed("supplier-band")
            loadFails = true
        }
        val diagnostics = mutableListOf<VeepooSupplierLifecycleEvent>()
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ -> if (id == "supplier-band") source else null },
            veepooCredentials = credentials,
            veepooLifecycleDiagnostics =
                VeepooSupplierLifecycleDiagnosticSink(diagnostics::add),
        )
        coordinator.start()
        operations.clear()

        val archived = coordinator.archiveVeepooDevice("supplier-band")

        assertFalse(archived)
        assertEquals("supplier-band", dao.activeDeviceId())
        assertEquals(DeviceStatus.active.name, dao.devices.getValue("supplier-band").status)
        assertEquals("2468", credentials.values["supplier-band"]?.password)
        assertEquals(0, source.stops)
        assertFalse(operations.contains("credential.clear"))
        assertFalse(operations.contains("registry.archive"))
        assertEquals(
            VeepooSupplierLifecycleFailure.CLEANUP_FAILED,
            diagnostics.last().failure,
        )
    }

    @Test
    fun durableReconciliationWaitsUntilPairingOwnershipEnds() = runBlocking {
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val activeSource = FakeVeepooManagedSource()
        val pairingSource = FakeVeepooManagedSource()
        var whoopStarts = 0
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = { whoopStarts += 1 },
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                activeSource.takeIf { id == "supplier-band" }
            },
            veepooPairingSourceFactory = { pairingSource },
            veepooCredentials = FakeCredentials(),
        )
        coordinator.start()
        assertTrue(coordinator.beginVeepooPairing())

        dao.devices["supplier-band"] = supplierRow(status = DeviceStatus.paired)
        dao.devices["my-whoop"] = whoopRow("my-whoop", null)
        coordinator.onActiveDeviceChanged("my-whoop")

        assertEquals(0, whoopStarts)
        assertEquals(0, pairingSource.stops)

        coordinator.cancelVeepooPairing()

        assertEquals(1, pairingSource.stops)
        assertEquals(1, whoopStarts)
    }

    @Test
    fun pairingCancellationRestoresTheExactPausedTransport() = runBlocking {
        assertPairingTerminalRestoresEachTransport(failPairing = false)
    }

    @Test
    fun pairingFailureRestoresTheExactPausedTransport() = runBlocking {
        assertPairingTerminalRestoresEachTransport(failPairing = true)
    }

    private suspend fun assertPairingTerminalRestoresEachTransport(
        failPairing: Boolean,
    ) {
        val cases = listOf(
            "WHOOP" to null,
            "standard HR" to SourceKind.liveBLE,
            "Oura" to SourceKind.oura,
            "active supplier" to SourceKind.veepoo,
        )
        cases.forEachIndexed { index, (label, sourceKind) ->
            val id = "transport-$index"
            val dao = FakeRegistryDao().apply {
                devices["my-whoop"] = whoopRow("my-whoop", null).copy(
                    status = if (sourceKind == null) {
                        DeviceStatus.active.name
                    } else {
                        DeviceStatus.paired.name
                    },
                )
                if (sourceKind != null) {
                    devices[id] = liveTransportRow(id, sourceKind)
                }
            }
            val sources = mutableListOf<FakeNoopBandSource>()
            val pairing = FakeVeepooManagedSource()
            var whoopStarts = 0
            var whoopStops = 0
            val coordinator = SourceCoordinator(
                context = null,
                registry = registryWith(dao),
                repository = null,
                liveSink = { _, _ -> },
                startWhoop = { whoopStarts += 1 },
                stopWhoop = { whoopStops += 1 },
                scope = CoroutineScope(Dispatchers.Unconfined),
                noopBandSourceFactory = { requestedId, _ ->
                    if (requestedId != id) {
                        null
                    } else {
                        FakeNoopBandSource().also(sources::add)
                    }
                },
                veepooPairingSourceFactory = { pairing },
                veepooCredentials = FakeCredentials(),
            )
            coordinator.start()
            val stopsBeforePairing = whoopStops

            assertTrue("$label pairing should start", coordinator.beginVeepooPairing())
            assertTrue(
                "$label candidate should be selected",
                coordinator.selectVeepooCandidate(pairing.handle),
            )
            if (sourceKind == null) {
                assertEquals("$label must be paused once", stopsBeforePairing + 1, whoopStops)
            } else {
                assertEquals("$label active source must stop once", 1, sources.single().stops)
                assertEquals("$label must not pause WHOOP again", stopsBeforePairing, whoopStops)
            }

            if (failPairing) {
                pairing.failPairing()
            } else {
                coordinator.cancelVeepooPairing()
            }

            if (sourceKind == null) {
                assertEquals("$label must resume once", 1, whoopStarts)
            } else {
                assertEquals("$label must be recreated", 2, sources.size)
                assertEquals("$label restored source must scan", 1, sources.last().scans)
                assertEquals("$label must not resume WHOOP", 0, whoopStarts)
            }
        }
    }

    @Test
    fun pairingPausesActiveSupplierBeforeConstructingSharedManagerClient() = runBlocking {
        val operations = mutableListOf<String>()
        val dao = FakeRegistryDao().apply {
            devices["my-whoop"] = whoopRow("my-whoop", null)
                .copy(status = DeviceStatus.paired.name)
            devices["supplier-band"] = supplierRow()
        }
        val activeSource = FakeVeepooManagedSource(operations)
        val pairingSource = FakeVeepooManagedSource(operations)
        val coordinator = SourceCoordinator(
            context = null,
            registry = registryWith(dao),
            repository = null,
            liveSink = { _, _ -> },
            startWhoop = {},
            stopWhoop = {},
            scope = CoroutineScope(Dispatchers.Unconfined),
            noopBandSourceFactory = { id, _ ->
                activeSource.takeIf { id == "supplier-band" }
            },
            veepooPairingSourceFactory = {
                operations += "pairing.construct"
                pairingSource
            },
            veepooCredentials = FakeCredentials(),
        )
        coordinator.start()
        activeSource.publishDisplay(
            VeepooDisplayState(
                adapterState = VeepooAdapterState.LIVE_DISPLAY_ONLY,
                heartRate = 71,
                phoneReceiptMilliseconds = 1_000,
                active = true,
            ),
        )
        assertEquals(71, coordinator.veepooDisplay.value.heartRate)
        operations.clear()

        assertTrue(coordinator.beginVeepooPairing())

        assertTrue(operations.indexOf("supplier.stop") < operations.indexOf("pairing.construct"))
        assertTrue(operations.indexOf("pairing.construct") < operations.indexOf("supplier.scan"))
        assertNull(coordinator.veepooDisplay.value.heartRate)
    }
}
