package com.noop.ble.veepoo

import com.noop.bandsdk.BandSessionMachine
import com.noop.bandsdk.BandSessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException

class VeepooBandSourceTest {
    private data class ConnectionEvent(
        val operation: String,
        val attempt: VeepooAttemptToken,
    )

    private class FakeReconnectScheduler : VeepooReconnectScheduler {
        private data class Pending(
            val delayMilliseconds: Long,
            val task: () -> Unit,
            var cancelled: Boolean = false,
        )

        private val pending = mutableListOf<Pending>()
        val delays = mutableListOf<Long>()
        var closed = false

        override fun schedule(
            delayMilliseconds: Long,
            task: () -> Unit,
        ): VeepooReconnectCancellation {
            val item = Pending(delayMilliseconds, task)
            pending += item
            delays += delayMilliseconds
            return VeepooReconnectCancellation { item.cancelled = true }
        }

        fun runNext() {
            val item = pending.removeAt(0)
            if (!item.cancelled) item.task()
        }

        override fun close() {
            closed = true
        }
    }

    private class FakeBridge : VeepooBridge {
        lateinit var callback: VeepooBridge.Listener
        var attempt: VeepooAttemptToken? = null
        var authentication: VeepooAuthenticationToken? = null
        val operations = mutableListOf<String>()
        val targets = mutableListOf<VeepooConnectionTarget>()
        val intents = mutableListOf<VeepooConnectionIntent>()
        val submittedPasswords = mutableListOf<String>()
        val submittedBuffers = mutableListOf<CharArray>()
        val connectionEvents = mutableListOf<ConnectionEvent>()
        var throwOnNextConnect = false
        var throwOnNextAuthenticate = false
        var throwDuringCleanup = false

        override fun setListener(listener: VeepooBridge.Listener) {
            callback = listener
        }

        override fun startScan(attempt: VeepooAttemptToken) {
            this.attempt = attempt
            operations += "scan"
        }

        override fun stopScan(attempt: VeepooAttemptToken) {
            operations += "stop-scan"
            if (throwDuringCleanup) error("supplier cleanup")
        }

        override fun connect(
            target: VeepooConnectionTarget,
            attempt: VeepooAttemptToken,
            intent: VeepooConnectionIntent,
        ) {
            this.attempt = attempt
            targets += target
            intents += intent
            operations += "connect"
            connectionEvents += ConnectionEvent("connect", attempt)
            if (throwOnNextConnect) {
                throwOnNextConnect = false
                error("supplier connect")
            }
        }

        override fun authenticate(
            password: CharArray,
            attempt: VeepooAttemptToken,
            authentication: VeepooAuthenticationToken,
            intent: VeepooConnectionIntent,
        ) {
            this.authentication = authentication
            submittedPasswords += password.concatToString()
            submittedBuffers += password
            intents += intent
            operations += "authenticate"
            if (throwOnNextAuthenticate) {
                throwOnNextAuthenticate = false
                error("supplier authentication")
            }
        }

        override fun readBattery(attempt: VeepooAttemptToken) {
            operations += "battery"
        }

        override fun startLiveHeartRate(attempt: VeepooAttemptToken) {
            operations += "live"
        }

        override fun stopLiveHeartRate(attempt: VeepooAttemptToken) {
            operations += "stop-live"
            if (throwDuringCleanup) error("supplier cleanup")
        }

        override fun disconnect(attempt: VeepooAttemptToken) {
            operations += "disconnect"
            connectionEvents += ConnectionEvent("disconnect", attempt)
            if (throwDuringCleanup) error("supplier cleanup")
        }

        override fun close() {
            operations += "close"
            if (throwDuringCleanup) error("supplier cleanup")
        }
    }

    private class Harness(
        initialPassword: CharArray? = null,
        initialRevisionBinding: VeepooRevisionBinding? = initialPassword?.let {
            requireNotNull(VeepooRevisionBinding.from("hw-1", "fw-1"))
        },
        compatibilityPolicy: VeepooCompatibilityPolicy = approvedPolicy(),
        revisionPersistenceSucceeds: Boolean = true,
    ) {
        val bridge = FakeBridge()
        val session = BandSessionMachine()
        val reconnectScheduler = FakeReconnectScheduler()
        val diagnostics = mutableListOf<VeepooDiagnosticEvent>()
        var rejectedCredentials = 0
        var revisionPersistenceUnavailable = 0
        var runtimeUnavailable = 0
        val persistedRevisionBindings = mutableListOf<VeepooRevisionBinding>()
        val persistedRevisionPasswords = mutableListOf<String>()
        var operationsAtCredentialRejection: List<String> = emptyList()
        var runtimeUnavailableSource: VeepooBandSource? = null
        var stateAtRuntimeUnavailable: VeepooAdapterState? = null
        var operationsAtRuntimeUnavailable: List<String> = emptyList()
        val source = VeepooBandSource(
            deviceId = "supplier-test",
            bridge = bridge,
            initialReconnectPassword = initialPassword,
            initialReconnectRevisionBinding = initialRevisionBinding,
            compatibilityPolicy = compatibilityPolicy,
            diagnostics = VeepooDiagnosticSink(diagnostics::add),
            session = session,
            onReconnectCredentialRejected = { _ ->
                rejectedCredentials += 1
                operationsAtCredentialRejection = bridge.operations.toList()
            },
            onReconnectRevisionBindingChanged = { _, password, binding ->
                persistedRevisionPasswords += password.concatToString()
                persistedRevisionBindings += binding
                revisionPersistenceSucceeds
            },
            onReconnectRevisionPersistenceUnavailable = {
                revisionPersistenceUnavailable += 1
            },
            onRuntimeUnavailable = { unavailableSource ->
                runtimeUnavailable += 1
                runtimeUnavailableSource = unavailableSource
                stateAtRuntimeUnavailable = unavailableSource.state.value
                operationsAtRuntimeUnavailable = bridge.operations.toList()
            },
            reconnectScheduler = reconnectScheduler,
        )

        fun discover(handle: String = "candidate-1"): VeepooCandidateRow {
            source.scan()
            val attempt = requireNotNull(bridge.attempt)
            bridge.callback.onCandidate(
                attempt,
                VeepooCandidate(
                    VeepooCandidateHandle(handle),
                    compatible = true,
                    identifyEligible = true,
                ),
            )
            return source.candidates.value.single()
        }

        fun pairThroughBattery(
            returnedModelCode: String = "42",
        ): VeepooAttemptToken {
            val candidate = discover()
            assertTrue(source.selectCandidate(candidate.handle))
            val attempt = requireNotNull(bridge.attempt)
            bridge.callback.onTransportConnected(attempt)
            val password = "1234".toCharArray()
            assertTrue(source.submitPairing(password))
            password.fill('\u0000')
            bridge.callback.onAuthenticated(
                attempt,
                requireNotNull(bridge.authentication),
                VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
                VeepooIdentity(returnedModelCode, "hw-1", "fw-1"),
                VeepooCapabilities(liveHeartRate = true, battery = true),
            )
            return attempt
        }
    }

    @Test
    fun compatibilityManifestApprovesOnlyTheExactCaseSensitiveTuple() {
        val policy = approvedPolicy()

        assertEquals(
            VeepooCompatibilityDecision.APPROVED,
            policy.evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
        listOf(
            VeepooIdentity("43", "hw-1", "fw-1"),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooIdentity("42", "hw-1", "fw-2"),
            VeepooIdentity("42", "HW-1", "fw-1"),
        ).forEach { identity ->
            assertEquals(
                VeepooCompatibilityDecision.UNAPPROVED,
                policy.evaluate(identity),
            )
        }
    }

    @Test
    fun compatibilityManifestRejectsBlankWildcardUnknownAndDuplicateRows() {
        val invalidManifests = listOf(
            manifest(row(modelCode = "")),
            manifest(row(modelCode = "*")),
            manifest(row(modelCode = "ANY")),
            manifest(row(modelCode = "all")),
            manifest(row(modelCode = "default")),
            manifest(row(modelCode = "unknown")),
            manifest(row(modelCode = "A".repeat(65))),
            manifest(row().dropLast(1) + ""","extra":"field"}"""),
            manifest(row(), row()),
            """{"schemaVersion":1,"approvedBands":"not-an-array"}""",
            """{"schemaVersion":1,"approvedBands":[]} trailing""",
        )

        invalidManifests.forEachIndexed { index, raw ->
            assertEquals(
                "invalid manifest fixture $index was accepted: $raw",
                VeepooCompatibilityDecision.INVALID_POLICY,
                VeepooCompatibilityPolicy.parse(raw)
                    .evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
            )
        }
    }

    @Test
    fun qualificationModeRequiresAValidEmptyManifest() {
        assertEquals(
            VeepooCompatibilityDecision.QUALIFICATION_APPROVED,
            VeepooCompatibilityPolicy.parse(
                manifest(),
                allowUnlistedQualification = true,
            ).evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
        assertEquals(
            VeepooCompatibilityDecision.UNAPPROVED,
            VeepooCompatibilityPolicy.parse(
                manifest(row()),
                allowUnlistedQualification = true,
            ).evaluate(VeepooIdentity("43", "hw-2", "fw-2")),
        )
        assertEquals(
            VeepooCompatibilityDecision.QUALIFICATION_APPROVED,
            VeepooCompatibilityPolicy.parse(
                manifest(
                    row(
                        platform = "apple",
                        wrapperRevision = "veepoo-apple-display-v1",
                    ),
                ),
                allowUnlistedQualification = true,
            ).evaluate(VeepooIdentity("43", "hw-2", "fw-2")),
        )
        assertEquals(
            VeepooCompatibilityDecision.INVALID_POLICY,
            VeepooCompatibilityPolicy.load(
                allowUnlistedQualification = true,
            ) {
                throw FileNotFoundException("missing test manifest")
            }.evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
    }

    @Test
    fun emptyManifestIsValidButMissingManifestFailsClosed() {
        assertEquals(
            VeepooCompatibilityDecision.UNAPPROVED,
            VeepooCompatibilityPolicy.parse(manifest())
                .evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
        assertEquals(
            VeepooCompatibilityDecision.INVALID_POLICY,
            VeepooCompatibilityPolicy.load {
                throw FileNotFoundException("missing test manifest")
            }.evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
        assertEquals(
            VeepooCompatibilityDecision.APPROVED,
            VeepooCompatibilityPolicy.load {
                ByteArrayInputStream(manifest(row()).toByteArray())
            }.evaluate(VeepooIdentity("42", "hw-1", "fw-1")),
        )
    }

    @Test
    fun unapprovedOrBlankIdentityCannotPromoteBatteryLiveOrProvisioning() {
        listOf(
            VeepooIdentity("43", "hw-1", "fw-1"),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooIdentity("42", "hw-1", "fw-2"),
            VeepooIdentity("", "hw-1", "fw-1"),
            VeepooIdentity("42", "", "fw-1"),
            VeepooIdentity("42", "hw-1", ""),
        ).forEach { identity ->
            val harness = Harness()
            val candidate = harness.discover()
            assertTrue(harness.source.selectCandidate(candidate.handle))
            val attempt = requireNotNull(harness.bridge.attempt)
            harness.bridge.callback.onTransportConnected(attempt)
            assertTrue(harness.source.submitPairing("1234".toCharArray()))

            harness.bridge.callback.onAuthenticated(
                attempt,
                requireNotNull(harness.bridge.authentication),
                VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
                identity,
                VeepooCapabilities(liveHeartRate = true, battery = true),
            )

            assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
            assertNull(harness.source.takeProvisioningCommit())
            assertFalse(harness.bridge.operations.contains("battery"))
            assertFalse(harness.bridge.operations.contains("live"))
        }
    }

    @Test
    fun discoveryRequiresExplicitSelectionBeforeConnect() {
        val harness = Harness()
        val candidate = harness.discover()

        assertEquals(VeepooAdapterState.CANDIDATES_FOUND, harness.source.state.value)
        assertTrue(harness.bridge.targets.isEmpty())
        assertEquals(1, candidate.ordinal)

        assertTrue(harness.source.selectCandidate(candidate.handle))
        assertEquals(1, harness.bridge.targets.size)
        assertEquals(VeepooConnectionIntent.PAIRING, harness.bridge.intents.single())
    }

    @Test
    fun pairingWaitsForConfirmationAndVerifiesPrintedIdBeforeCommit() {
        val harness = Harness()
        val candidate = harness.discover()
        harness.source.selectCandidate(candidate.handle)
        val attempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(attempt)

        assertEquals(
            VeepooAdapterState.AWAITING_PAIRING_CONFIRMATION,
            harness.source.state.value,
        )
        assertTrue(harness.bridge.submittedPasswords.isEmpty())

        assertTrue(harness.source.submitPairing("1234".toCharArray()))
        harness.bridge.callback.onAuthenticated(
            attempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        val commit = requireNotNull(harness.source.takeProvisioningCommit())
        var saved = ""
        var revisionBinding: VeepooRevisionBinding? = null
        assertTrue(
            commit.saveCredential { password, binding ->
                saved = password.concatToString()
                revisionBinding = binding
                true
            },
        )
        assertEquals("1234", saved)
        assertEquals(
            VeepooRevisionBinding.from("hw-1", "fw-1"),
            revisionBinding,
        )
        assertTrue(harness.bridge.submittedBuffers.single().all { it == '\u0000' })
    }

    @Test
    fun unknownProductCodeCleansUpWithoutProvisioningCommit() {
        val harness = Harness()
        harness.pairThroughBattery(returnedModelCode = "41")

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertNull(harness.source.takeProvisioningCommit())
        assertTrue(harness.bridge.operations.containsAll(listOf("stop-scan", "stop-live", "disconnect", "close")))
    }

    @Test
    fun batteryCompletesBeforeDisplayOnlyHeartRateAndNothingIsPersisted() {
        val harness = Harness()
        val attempt = harness.pairThroughBattery()

        assertEquals(listOf("battery"), harness.bridge.operations.takeLast(1))
        assertFalse(harness.bridge.operations.contains("live"))
        harness.bridge.callback.onBattery(
            attempt,
            VeepooBatteryReading(percent = 73, observedAtMilliseconds = 1_000),
        )
        assertEquals(listOf("battery", "live"), harness.bridge.operations.takeLast(2))

        harness.bridge.callback.onLiveHeartRate(
            attempt,
            VeepooLiveHeartRate(beatsPerMinute = 77, phoneReceiptMilliseconds = 2_000),
        )
        assertEquals(77, harness.source.display.value.heartRate)
        assertEquals(2_000L, harness.source.display.value.phoneReceiptMilliseconds)
        assertEquals(BandSessionState.READY, harness.session.snapshot().state)
        assertEquals(0, harness.session.snapshot().durableSampleCount)
        assertFalse(harness.session.snapshot().liveActive)
    }

    @Test
    fun reconnectUsesStoredCredentialWithoutPairingConfirmation() {
        val original = "0042".toCharArray()
        val harness = Harness(original)
        assertTrue(original.all { it == '\u0000' })

        harness.source.connect("AA:BB:CC:DD:EE:01")
        val attempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(attempt)

        assertEquals(VeepooAdapterState.AUTHENTICATING, harness.source.state.value)
        assertEquals(listOf("0042"), harness.bridge.submittedPasswords)
        assertEquals(VeepooConnectionIntent.RECONNECT, harness.bridge.intents.last())
        harness.bridge.callback.onAuthenticated(
            attempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )
        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        assertNull(harness.source.takeProvisioningCommit())
    }

    @Test
    fun reconnectWithoutRevisionBindingFailsClosedBeforeTransportUse() {
        val harness = Harness(
            initialPassword = "0042".toCharArray(),
            initialRevisionBinding = null,
        )

        harness.source.connect("AA:BB:CC:DD:EE:01")

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertTrue(harness.bridge.targets.isEmpty())
        assertEquals(1, harness.rejectedCredentials)
    }

    @Test
    fun reconnectRebindsApprovedHardwareOrFirmwareRevisionDrift() {
        listOf(
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooIdentity("42", "hw-1", "fw-2"),
        ).forEach { identity ->
            val harness = Harness(
                initialPassword = "0042".toCharArray(),
                compatibilityPolicy = VeepooCompatibilityPolicy.parse(
                    manifest(
                        row(
                            hardwareRevision = identity.hardwareRevision,
                            firmwareRevision = identity.firmwareVersion,
                        ),
                    ),
                ),
            )
            harness.source.connect("AA:BB:CC:DD:EE:01")
            val attempt = requireNotNull(harness.bridge.attempt)
            harness.bridge.callback.onTransportConnected(attempt)

            harness.bridge.callback.onAuthenticated(
                attempt,
                requireNotNull(harness.bridge.authentication),
                VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
                identity,
                VeepooCapabilities(liveHeartRate = true, battery = true),
            )

            assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
            assertEquals(0, harness.rejectedCredentials)
            assertEquals(0, harness.revisionPersistenceUnavailable)
            assertEquals(0, harness.runtimeUnavailable)
            assertEquals(listOf("0042"), harness.persistedRevisionPasswords)
            assertEquals(
                listOf(
                    requireNotNull(
                        VeepooRevisionBinding.from(
                            identity.hardwareRevision,
                            identity.firmwareVersion,
                        ),
                    ),
                ),
                harness.persistedRevisionBindings,
            )
            assertEquals("battery", harness.bridge.operations.last())
        }
    }

    @Test
    fun approvedRevisionRebindSurvivesSourceRecreation() {
        val policy = VeepooCompatibilityPolicy.parse(
            manifest(row(hardwareRevision = "hw-2")),
        )
        val first = Harness(
            initialPassword = "0042".toCharArray(),
            compatibilityPolicy = policy,
        )
        first.source.connect("AA:BB:CC:DD:EE:01")
        val firstAttempt = requireNotNull(first.bridge.attempt)
        first.bridge.callback.onTransportConnected(firstAttempt)
        first.bridge.callback.onAuthenticated(
            firstAttempt,
            requireNotNull(first.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", firstAttempt),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )
        val persistedBinding = first.persistedRevisionBindings.single()
        first.source.stop()

        val recreated = Harness(
            initialPassword = "0042".toCharArray(),
            initialRevisionBinding = persistedBinding,
            compatibilityPolicy = policy,
        )
        recreated.source.connect("AA:BB:CC:DD:EE:01")
        val secondAttempt = requireNotNull(recreated.bridge.attempt)
        recreated.bridge.callback.onTransportConnected(secondAttempt)
        recreated.bridge.callback.onAuthenticated(
            secondAttempt,
            requireNotNull(recreated.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", secondAttempt),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.READING_BATTERY, recreated.source.state.value)
        assertTrue(recreated.persistedRevisionBindings.isEmpty())
        assertEquals(0, recreated.rejectedCredentials)
    }

    @Test
    fun approvedRevisionPersistenceFailurePreservesCredentialClassification() {
        val harness = Harness(
            initialPassword = "0042".toCharArray(),
            compatibilityPolicy = VeepooCompatibilityPolicy.parse(
                manifest(row(hardwareRevision = "hw-2")),
            ),
            revisionPersistenceSucceeds = false,
        )
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val attempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(attempt)
        harness.bridge.callback.onAuthenticated(
            attempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(1, harness.revisionPersistenceUnavailable)
        assertEquals(0, harness.runtimeUnavailable)
        assertFalse(harness.bridge.operations.contains("battery"))
    }

    @Test
    fun reconnectCompatibilityRejectionPreservesCredential() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val attempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(attempt)

        harness.bridge.callback.onAuthenticated(
            attempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
            VeepooIdentity("43", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(1, harness.runtimeUnavailable)
        assertFalse(harness.bridge.operations.contains("battery"))
    }

    @Test
    fun postLiveApprovedRevisionDriftPersistsReplacementBindingAndContinues() {
        val harness = Harness(
            compatibilityPolicy = VeepooCompatibilityPolicy.parse(
                manifest(
                    row(),
                    row(hardwareRevision = "hw-2"),
                ),
            ),
        )
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onConnectionDropped(firstAttempt)
        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(reconnectAttempt)

        harness.bridge.callback.onAuthenticated(
            reconnectAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", reconnectAttempt),
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(
            listOf(requireNotNull(VeepooRevisionBinding.from("hw-2", "fw-1"))),
            harness.persistedRevisionBindings,
        )
        assertEquals(listOf("1234"), harness.persistedRevisionPasswords)
        assertEquals(0, harness.revisionPersistenceUnavailable)
        assertEquals(0, harness.runtimeUnavailable)
        assertEquals("battery", harness.bridge.operations.last())
    }

    @Test
    fun postLiveReconnectRejectsApprovedDifferentModel() {
        val harness = Harness(
            compatibilityPolicy = VeepooCompatibilityPolicy.parse(
                manifest(
                    row(),
                    row(modelCode = "43"),
                ),
            ),
        )
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        val batteryOperationsBeforeReconnect =
            harness.bridge.operations.count { it == "battery" }
        harness.bridge.callback.onConnectionDropped(firstAttempt)
        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(reconnectAttempt)

        harness.bridge.callback.onAuthenticated(
            reconnectAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", reconnectAttempt),
            VeepooIdentity("43", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertTrue(harness.persistedRevisionBindings.isEmpty())
        assertEquals(1, harness.runtimeUnavailable)
        assertEquals(
            batteryOperationsBeforeReconnect,
            harness.bridge.operations.count { it == "battery" },
        )
    }

    @Test
    fun postLiveReconnectRejectsDifferentPeripheral() {
        val harness = Harness()
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onConnectionDropped(firstAttempt)
        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(reconnectAttempt)

        harness.bridge.callback.onAuthenticated(
            reconnectAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:02", reconnectAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertTrue(harness.persistedRevisionBindings.isEmpty())
        assertEquals(1, harness.runtimeUnavailable)
    }

    @Test
    fun reconnectAuthenticationRejectionCleansUpBeforeCoordinatorCallback() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val attempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(attempt)

        harness.bridge.callback.onAuthenticationFailed(
            attempt,
            requireNotNull(harness.bridge.authentication),
            VeepooFailure.AUTHENTICATION,
        )

        assertEquals(1, harness.rejectedCredentials)
        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertTrue(harness.operationsAtCredentialRejection.contains("disconnect"))
        assertTrue(harness.operationsAtCredentialRejection.contains("close"))
        assertEquals("close", harness.operationsAtCredentialRejection.last())
    }

    @Test
    fun durableDropUsesNeutralReconnectContractThenRestartsBatteryFirst() {
        val harness = Harness()
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onLiveHeartRate(
            firstAttempt,
            VeepooLiveHeartRate(beatsPerMinute = 77, phoneReceiptMilliseconds = 1_100),
        )

        harness.bridge.callback.onConnectionDropped(firstAttempt)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertNull(harness.source.display.value.batteryPercent)
        assertNull(harness.source.display.value.heartRate)
        assertNull(harness.source.display.value.phoneReceiptMilliseconds)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)
        assertEquals(firstAttempt, harness.bridge.attempt)

        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        assertTrue(reconnectAttempt !== firstAttempt)
        assertDisconnectedBeforeConnect(harness.bridge, firstAttempt, reconnectAttempt)
        harness.bridge.callback.onTransportConnected(reconnectAttempt)
        harness.bridge.callback.onAuthenticated(
            reconnectAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", reconnectAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(BandSessionState.EXECUTING_COMMAND, harness.session.snapshot().state)
        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        assertEquals("battery", harness.bridge.operations.last())

        harness.bridge.callback.onBattery(
            reconnectAttempt,
            VeepooBatteryReading(percent = 79, observedAtMilliseconds = 2_000),
        )
        assertEquals(BandSessionState.READY, harness.session.snapshot().state)
        assertEquals(VeepooAdapterState.LIVE_DISPLAY_ONLY, harness.source.state.value)
        assertEquals("live", harness.bridge.operations.last())
    }

    @Test
    fun coldStartTransientFailureUsesBoundedReconnect() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val firstAttempt = requireNotNull(harness.bridge.attempt)

        harness.bridge.callback.onFailure(firstAttempt, VeepooFailure.TIMEOUT)

        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(0, harness.runtimeUnavailable)

        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)
        assertDisconnectedBeforeConnect(harness.bridge, firstAttempt, retryAttempt)
        harness.bridge.callback.onTransportConnected(retryAttempt)
        harness.bridge.callback.onAuthenticated(
            retryAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", retryAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        assertEquals(0, harness.runtimeUnavailable)
    }

    @Test
    fun coldStartAuthenticationTimeoutUsesBoundedReconnect() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val firstAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(firstAttempt)

        harness.bridge.callback.onAuthenticationFailed(
            firstAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooFailure.TIMEOUT,
        )

        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(0, harness.runtimeUnavailable)

        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)
        assertDisconnectedBeforeConnect(harness.bridge, firstAttempt, retryAttempt)
        harness.bridge.callback.onTransportConnected(retryAttempt)
        assertEquals(VeepooAdapterState.AUTHENTICATING, harness.source.state.value)
        assertEquals(listOf("0042", "0042"), harness.bridge.submittedPasswords)
    }

    @Test
    fun synchronousConnectFailureDisconnectsAttemptBeforeRetryConnect() {
        val harness = Harness("0042".toCharArray())
        harness.bridge.throwOnNextConnect = true

        harness.source.connect("AA:BB:CC:DD:EE:01")
        val failedAttempt = requireNotNull(harness.bridge.attempt)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)

        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)

        assertDisconnectedBeforeConnect(harness.bridge, failedAttempt, retryAttempt)
        assertEquals(0, harness.runtimeUnavailable)
    }

    @Test
    fun synchronousAuthenticationFailureDisconnectsAttemptBeforeRetryConnect() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val failedAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.throwOnNextAuthenticate = true

        harness.bridge.callback.onTransportConnected(failedAttempt)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)

        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)

        assertDisconnectedBeforeConnect(harness.bridge, failedAttempt, retryAttempt)
        assertEquals(0, harness.runtimeUnavailable)
    }

    @Test
    fun liveTransientFailureTransitionsNeutralSessionBeforeReconnect() {
        val harness = Harness("0042".toCharArray())
        harness.source.connect("AA:BB:CC:DD:EE:01")
        val firstAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(firstAttempt)
        harness.bridge.callback.onAuthenticated(
            firstAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", firstAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onLiveHeartRate(
            firstAttempt,
            VeepooLiveHeartRate(beatsPerMinute = 77, phoneReceiptMilliseconds = 1_100),
        )
        assertEquals(BandSessionState.READY, harness.session.snapshot().state)
        assertEquals(VeepooAdapterState.LIVE_DISPLAY_ONLY, harness.source.state.value)
        assertEquals(77, harness.source.display.value.heartRate)

        harness.bridge.callback.onFailure(firstAttempt, VeepooFailure.TIMEOUT)

        assertEquals(BandSessionState.RECOVERING, harness.session.snapshot().state)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertNull(harness.source.display.value.heartRate)
        assertNull(harness.source.display.value.phoneReceiptMilliseconds)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)
        assertEquals(0, harness.runtimeUnavailable)

        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)
        assertDisconnectedBeforeConnect(harness.bridge, firstAttempt, retryAttempt)
        harness.bridge.callback.onTransportConnected(retryAttempt)
        harness.bridge.callback.onAuthenticated(
            retryAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", retryAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )

        assertEquals(BandSessionState.EXECUTING_COMMAND, harness.session.snapshot().state)
        assertEquals(VeepooAdapterState.READING_BATTERY, harness.source.state.value)
        assertNull(harness.source.display.value.heartRate)
        assertNull(harness.source.display.value.phoneReceiptMilliseconds)
        assertEquals(0, harness.runtimeUnavailable)
        harness.bridge.callback.onBattery(
            retryAttempt,
            VeepooBatteryReading(percent = 79, observedAtMilliseconds = 2_000),
        )
        assertEquals(VeepooAdapterState.LIVE_DISPLAY_ONLY, harness.source.state.value)
        assertNull(harness.source.display.value.heartRate)
        assertNull(harness.source.display.value.phoneReceiptMilliseconds)
    }

    @Test
    fun batteryTransientFailureDisconnectsBeforeReconnect() {
        val harness = Harness()
        val firstAttempt = harness.pairThroughBattery()

        harness.bridge.callback.onFailure(firstAttempt, VeepooFailure.TIMEOUT)
        harness.reconnectScheduler.runNext()
        val retryAttempt = requireNotNull(harness.bridge.attempt)

        assertDisconnectedBeforeConnect(harness.bridge, firstAttempt, retryAttempt)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
    }

    @Test
    fun terminalBatteryFailureExhaustsRetriesThenReconciles() {
        val harness = Harness()
        var attempt = harness.pairThroughBattery()

        listOf(2_000L, 5_000L, 15_000L).forEachIndexed { index, expectedDelay ->
            harness.bridge.callback.onFailure(attempt, VeepooFailure.TIMEOUT)
            assertEquals(expectedDelay, harness.reconnectScheduler.delays[index])
            harness.reconnectScheduler.runNext()
            attempt = requireNotNull(harness.bridge.attempt)
            harness.bridge.callback.onTransportConnected(attempt)
            harness.bridge.callback.onAuthenticated(
                attempt,
                requireNotNull(harness.bridge.authentication),
                VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
                VeepooIdentity("42", "hw-1", "fw-1"),
                VeepooCapabilities(liveHeartRate = true, battery = true),
            )
        }
        harness.bridge.callback.onFailure(attempt, VeepooFailure.TIMEOUT)

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertEquals(4, harness.bridge.operations.count { it == "battery" })
        assertEquals(0, harness.rejectedCredentials)
        assertEquals(1, harness.runtimeUnavailable)
        assertTrue(harness.reconnectScheduler.closed)
        assertTrue(harness.runtimeUnavailableSource === harness.source)
        assertEquals(VeepooAdapterState.FAILED, harness.stateAtRuntimeUnavailable)
        assertEquals("close", harness.operationsAtRuntimeUnavailable.last())
        assertEquals(4, harness.bridge.operations.count { it == "disconnect" })
        assertEquals(1, harness.bridge.operations.count { it == "close" })
    }

    @Test
    fun transientReconnectFailuresUseBoundedBackoffThenStop() {
        val harness = Harness()
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )

        harness.bridge.callback.onConnectionDropped(firstAttempt)
        listOf(2_000L, 5_000L, 15_000L).forEachIndexed { index, expectedDelay ->
            assertEquals(expectedDelay, harness.reconnectScheduler.delays[index])
            harness.reconnectScheduler.runNext()
            val attempt = requireNotNull(harness.bridge.attempt)
            harness.bridge.callback.onFailure(attempt, VeepooFailure.TIMEOUT)
        }

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertEquals(3, harness.bridge.operations.count { it == "connect" } - 1)
        assertTrue(harness.reconnectScheduler.closed)
    }

    @Test
    fun stopCancelsPendingReconnect() {
        val harness = Harness()
        val attempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            attempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onConnectionDropped(attempt)
        val connectCount = harness.bridge.operations.count { it == "connect" }

        harness.source.stop()
        harness.reconnectScheduler.runNext()

        assertEquals(connectCount, harness.bridge.operations.count { it == "connect" })
        assertEquals(VeepooAdapterState.STOPPED, harness.source.state.value)
        assertTrue(harness.reconnectScheduler.closed)
    }

    @Test
    fun successfulReconnectResetsBackoff() {
        val harness = Harness()
        val firstAttempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            firstAttempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )
        harness.bridge.callback.onConnectionDropped(firstAttempt)
        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        harness.bridge.callback.onTransportConnected(reconnectAttempt)
        harness.bridge.callback.onAuthenticated(
            reconnectAttempt,
            requireNotNull(harness.bridge.authentication),
            VeepooBinding.create("AA:BB:CC:DD:EE:01", reconnectAttempt),
            VeepooIdentity("42", "hw-1", "fw-1"),
            VeepooCapabilities(liveHeartRate = true, battery = true),
        )
        harness.bridge.callback.onBattery(
            reconnectAttempt,
            VeepooBatteryReading(percent = 79, observedAtMilliseconds = 2_000),
        )

        harness.bridge.callback.onConnectionDropped(reconnectAttempt)

        assertEquals(listOf(2_000L, 2_000L), harness.reconnectScheduler.delays)
    }

    @Test
    fun explicitStopDisconnectsAndClosesWithoutLeavingLiveState() {
        val harness = Harness()
        val attempt = harness.pairThroughBattery()
        harness.bridge.callback.onBattery(
            attempt,
            VeepooBatteryReading(percent = 80, observedAtMilliseconds = 1_000),
        )

        harness.source.stop()

        assertEquals(VeepooAdapterState.STOPPED, harness.source.state.value)
        assertTrue(harness.bridge.operations.containsAll(listOf("stop-live", "disconnect", "close")))
        assertNull(harness.source.display.value.heartRate)
    }

    @Test
    fun supplierAndCleanupExceptionsNeverEscape() {
        val harness = Harness()
        harness.discover()
        harness.bridge.throwDuringCleanup = true
        val attempt = requireNotNull(harness.bridge.attempt)

        harness.bridge.callback.onFailure(attempt, VeepooFailure.INTERNAL)

        assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
        assertTrue(harness.diagnostics.any { it.category == VeepooDiagnosticCategory.CLEANUP })
    }

    @Test
    fun terminalFailureThenStopCleansBridgeOnlyOnce() {
        val harness = Harness()
        harness.discover()
        val attempt = requireNotNull(harness.bridge.attempt)

        harness.bridge.callback.onFailure(attempt, VeepooFailure.PERMISSION)
        harness.source.stop()
        harness.source.stop()

        assertEquals(VeepooAdapterState.STOPPED, harness.source.state.value)
        assertTrue(harness.runtimeUnavailableSource === harness.source)
        assertEquals(VeepooAdapterState.FAILED, harness.stateAtRuntimeUnavailable)
        assertEquals("close", harness.operationsAtRuntimeUnavailable.last())
        assertEquals(1, harness.bridge.operations.count { it == "disconnect" })
        assertEquals(1, harness.bridge.operations.count { it == "close" })
    }

    companion object {
        private fun assertDisconnectedBeforeConnect(
            bridge: FakeBridge,
            disconnectedAttempt: VeepooAttemptToken,
            connectedAttempt: VeepooAttemptToken,
        ) {
            val disconnectIndex = bridge.connectionEvents.indexOfFirst {
                it.operation == "disconnect" && it.attempt === disconnectedAttempt
            }
            val connectIndex = bridge.connectionEvents.indexOfFirst {
                it.operation == "connect" && it.attempt === connectedAttempt
            }
            assertTrue(
                "exact retry attempt must be disconnected",
                disconnectIndex >= 0,
            )
            assertTrue(
                "disconnect must precede the replacement connect",
                connectIndex > disconnectIndex,
            )
        }

        private fun approvedPolicy(): VeepooCompatibilityPolicy =
            VeepooCompatibilityPolicy.parse(manifest(row()))

        private fun manifest(vararg rows: String): String =
            """{"schemaVersion":1,"approvedBands":[${rows.joinToString(",")}]}"""

        private fun row(
            platform: String = "android",
            modelCode: String = "42",
            hardwareRevision: String = "hw-1",
            firmwareRevision: String = "fw-1",
            wrapperRevision: String = "veepoo-android-display-v2",
        ): String =
            """{"platform":"$platform","modelCode":"$modelCode","hardwareRevision":"$hardwareRevision","firmwareRevision":"$firmwareRevision","protocolVersion":"noop-band-v1","wrapperRevision":"$wrapperRevision"}"""
    }
}
