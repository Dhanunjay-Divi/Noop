package com.noop.ble.veepoo

import com.noop.bandsdk.BandSessionMachine
import com.noop.bandsdk.BandSessionState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VeepooBandSourceTest {
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
    ) {
        val bridge = FakeBridge()
        val session = BandSessionMachine()
        val reconnectScheduler = FakeReconnectScheduler()
        val diagnostics = mutableListOf<VeepooDiagnosticEvent>()
        var rejectedCredentials = 0
        var operationsAtCredentialRejection: List<String> = emptyList()
        val source = VeepooBandSource(
            deviceId = "supplier-test",
            bridge = bridge,
            initialReconnectPassword = initialPassword,
            initialReconnectRevisionBinding = initialRevisionBinding,
            diagnostics = VeepooDiagnosticSink(diagnostics::add),
            session = session,
            onReconnectCredentialRejected = {
                rejectedCredentials += 1
                operationsAtCredentialRejection = bridge.operations.toList()
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
            printedId: String = "00042",
            returnedId: String = "42",
        ): VeepooAttemptToken {
            val candidate = discover()
            assertTrue(source.selectCandidate(candidate.handle))
            val attempt = requireNotNull(bridge.attempt)
            bridge.callback.onTransportConnected(attempt)
            val printed = printedId.toCharArray()
            val password = "1234".toCharArray()
            assertTrue(source.submitPairing(printed, password))
            printed.fill('\u0000')
            password.fill('\u0000')
            bridge.callback.onAuthenticated(
                attempt,
                requireNotNull(bridge.authentication),
                VeepooBinding.create("AA:BB:CC:DD:EE:01", attempt),
                VeepooIdentity(returnedId, "hw-1", "fw-1"),
                VeepooCapabilities(liveHeartRate = true, battery = true),
            )
            return attempt
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

        assertTrue(harness.source.submitPairing("00042".toCharArray(), "1234".toCharArray()))
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
    fun printedIdMismatchCleansUpWithoutProvisioningCommit() {
        val harness = Harness()
        harness.pairThroughBattery(printedId = "41", returnedId = "42")

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
    fun reconnectRejectsHardwareOrFirmwareRevisionDrift() {
        listOf(
            VeepooIdentity("42", "hw-2", "fw-1"),
            VeepooIdentity("42", "hw-1", "fw-2"),
        ).forEach { identity ->
            val harness = Harness("0042".toCharArray())
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

            assertEquals(VeepooAdapterState.FAILED, harness.source.state.value)
            assertEquals(1, harness.rejectedCredentials)
            assertFalse(harness.bridge.operations.contains("battery"))
        }
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

        harness.bridge.callback.onConnectionDropped(firstAttempt)
        assertEquals(VeepooAdapterState.RECONNECTING, harness.source.state.value)
        assertEquals(listOf(2_000L), harness.reconnectScheduler.delays)
        assertEquals(firstAttempt, harness.bridge.attempt)

        harness.reconnectScheduler.runNext()
        val reconnectAttempt = requireNotNull(harness.bridge.attempt)
        assertTrue(reconnectAttempt !== firstAttempt)
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
}
