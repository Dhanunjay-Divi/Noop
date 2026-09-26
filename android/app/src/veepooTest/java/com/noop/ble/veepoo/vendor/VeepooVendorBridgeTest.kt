package com.noop.ble.veepoo.vendor

import com.inuker.bluetooth.library.Code
import com.noop.ble.veepoo.VeepooAttemptToken
import com.noop.ble.veepoo.VeepooAuthenticationToken
import com.noop.ble.veepoo.VeepooBatteryReading
import com.noop.ble.veepoo.VeepooBinding
import com.noop.ble.veepoo.VeepooBridge
import com.noop.ble.veepoo.VeepooCandidate
import com.noop.ble.veepoo.VeepooCapabilities
import com.noop.ble.veepoo.VeepooConnectionIntent
import com.noop.ble.veepoo.VeepooConnectionTarget
import com.noop.ble.veepoo.VeepooFailure
import com.noop.ble.veepoo.VeepooIdentity
import com.noop.ble.veepoo.VeepooLiveHeartRate
import com.veepoo.protocol.model.datas.BatteryData
import com.veepoo.protocol.model.datas.HeartData
import com.veepoo.protocol.model.enums.EHeartStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VeepooVendorBridgeTest {
    private class FakeClient : VeepooVendorClient {
        data class ConnectionCall(
            val address: String,
            val requireDeviceConfirmation: Boolean,
            val callback: VeepooVendorConnectionCallback,
            val registration: Registration,
        )

        inner class Registration : VeepooVendorConnectionRegistration {
            var unregisterCount = 0

            override fun unregister() {
                unregisterCount += 1
                operations += "unregister"
            }
        }

        val operations = mutableListOf<String>()
        val scanCallbacks = mutableListOf<VeepooVendorScanCallback>()
        val connectionCalls = mutableListOf<ConnectionCall>()
        val authenticationCallbacks = mutableListOf<VeepooVendorAuthenticationCallback>()
        val batteryCallbacks = mutableListOf<VeepooVendorBatteryCallback>()
        val heartRateCallbacks = mutableListOf<VeepooVendorHeartRateCallback>()
        val submittedPasswords = mutableListOf<String>()
        val submittedPasswordBuffers = mutableListOf<CharArray>()
        var initializationFailure: Throwable? = null

        override fun initialize() {
            operations += "initialize"
            initializationFailure?.let { throw it }
        }

        override fun startScan(callback: VeepooVendorScanCallback) {
            operations += "start-scan"
            scanCallbacks += callback
        }

        override fun stopScan() {
            operations += "stop-scan"
        }

        override fun connect(
            address: String,
            requireDeviceConfirmation: Boolean,
            callback: VeepooVendorConnectionCallback,
        ): VeepooVendorConnectionRegistration {
            operations += "connect"
            val registration = Registration()
            connectionCalls += ConnectionCall(
                address,
                requireDeviceConfirmation,
                callback,
                registration,
            )
            return registration
        }

        override fun authenticate(
            password: CharArray,
            callback: VeepooVendorAuthenticationCallback,
        ) {
            operations += "authenticate"
            submittedPasswords += password.concatToString()
            submittedPasswordBuffers += password
            authenticationCallbacks += callback
        }

        override fun cancelAuthentication() {
            operations += "cancel-authentication"
        }

        override fun readBattery(callback: VeepooVendorBatteryCallback) {
            operations += "read-battery"
            batteryCallbacks += callback
        }

        override fun startLiveHeartRate(callback: VeepooVendorHeartRateCallback) {
            operations += "start-heart"
            heartRateCallbacks += callback
        }

        override fun stopLiveHeartRate() {
            operations += "stop-heart"
        }

        override fun disconnect() {
            operations += "disconnect"
        }

        override fun close() {
            operations += "close"
        }
    }

    private class RecordingListener : VeepooBridge.Listener {
        data class Authentication(
            val attempt: VeepooAttemptToken,
            val token: VeepooAuthenticationToken,
            val binding: VeepooBinding,
            val identity: VeepooIdentity,
            val capabilities: VeepooCapabilities,
        )

        val candidates = mutableListOf<Pair<VeepooAttemptToken, VeepooCandidate>>()
        val scanFinished = mutableListOf<VeepooAttemptToken>()
        val transports = mutableListOf<VeepooAttemptToken>()
        val authentications = mutableListOf<Authentication>()
        val authenticationFailures =
            mutableListOf<Triple<VeepooAttemptToken, VeepooAuthenticationToken, VeepooFailure>>()
        val batteries = mutableListOf<Pair<VeepooAttemptToken, VeepooBatteryReading>>()
        val heartRates = mutableListOf<Pair<VeepooAttemptToken, VeepooLiveHeartRate>>()
        val drops = mutableListOf<VeepooAttemptToken>()
        val failures = mutableListOf<Pair<VeepooAttemptToken, VeepooFailure>>()

        override fun onCandidate(attempt: VeepooAttemptToken, candidate: VeepooCandidate) {
            candidates += attempt to candidate
        }

        override fun onScanFinished(attempt: VeepooAttemptToken) {
            scanFinished += attempt
        }

        override fun onTransportConnected(attempt: VeepooAttemptToken) {
            transports += attempt
        }

        override fun onAuthenticated(
            attempt: VeepooAttemptToken,
            authentication: VeepooAuthenticationToken,
            binding: VeepooBinding,
            identity: VeepooIdentity,
            capabilities: VeepooCapabilities,
        ) {
            authentications += Authentication(
                attempt,
                authentication,
                binding,
                identity,
                capabilities,
            )
        }

        override fun onAuthenticationFailed(
            attempt: VeepooAttemptToken,
            authentication: VeepooAuthenticationToken,
            failure: VeepooFailure,
        ) {
            authenticationFailures += Triple(attempt, authentication, failure)
        }

        override fun onBattery(
            attempt: VeepooAttemptToken,
            reading: VeepooBatteryReading,
        ) {
            batteries += attempt to reading
        }

        override fun onLiveHeartRate(
            attempt: VeepooAttemptToken,
            reading: VeepooLiveHeartRate,
        ) {
            heartRates += attempt to reading
        }

        override fun onConnectionDropped(attempt: VeepooAttemptToken) {
            drops += attempt
        }

        override fun onFailure(attempt: VeepooAttemptToken, failure: VeepooFailure) {
            failures += attempt to failure
        }
    }

    private class Harness(
        val client: FakeClient = FakeClient(),
    ) {
        val listener = RecordingListener()
        val bridge = VeepooVendorBridge(client, clockMilliseconds = { 4_242L }).also {
            it.setListener(listener)
        }

        fun connectDiscovered(
            intent: VeepooConnectionIntent = VeepooConnectionIntent.PAIRING,
        ): Pair<VeepooAttemptToken, FakeClient.ConnectionCall> {
            val attempt = VeepooAttemptToken.create()
            bridge.startScan(attempt)
            client.scanCallbacks.last().onCandidate(SYNTHETIC_ADDRESS)
            val candidate = listener.candidates.last().second
            bridge.stopScan(attempt)
            bridge.connect(
                VeepooConnectionTarget.Discovered(candidate.handle),
                attempt,
                intent,
            )
            return attempt to client.connectionCalls.last()
        }

        fun connectReady(
            intent: VeepooConnectionIntent = VeepooConnectionIntent.PAIRING,
        ): Pair<VeepooAttemptToken, FakeClient.ConnectionCall> {
            val result = connectDiscovered(intent)
            result.second.callback.onConnected(oadMode = false)
            result.second.callback.onNotifyReady()
            return result
        }

        fun authenticate(
            attempt: VeepooAttemptToken,
            intent: VeepooConnectionIntent = VeepooConnectionIntent.PAIRING,
        ): VeepooAuthenticationToken {
            val token = VeepooAuthenticationToken.create()
            bridge.authenticate("1234".toCharArray(), attempt, token, intent)
            client.authenticationCallbacks.last().apply {
                onIdentity(
                    VeepooVendorIdentity(
                        deviceNumber = 42,
                        hardwareRevision = "test-revision",
                        firmwareVersion = "release-version",
                    ),
                )
                onHeartRateCapability(true)
                onComplete()
            }
            return token
        }
    }

    @Test
    fun scanRequiresExplicitSelectionAndTransportWaitsForNotify() {
        val harness = Harness()
        val attempt = VeepooAttemptToken.create()

        harness.bridge.startScan(attempt)
        harness.client.scanCallbacks.single().onCandidate(SYNTHETIC_ADDRESS)

        assertTrue(harness.client.connectionCalls.isEmpty())
        val candidate = harness.listener.candidates.single().second
        assertNotEquals(SYNTHETIC_ADDRESS, candidate.handle.value)
        assertFalse(candidate.handle.toString().contains(SYNTHETIC_ADDRESS))

        harness.bridge.stopScan(attempt)
        harness.bridge.connect(
            VeepooConnectionTarget.Discovered(candidate.handle),
            attempt,
            VeepooConnectionIntent.PAIRING,
        )
        val connection = harness.client.connectionCalls.single()
        assertEquals(SYNTHETIC_ADDRESS, connection.address)
        assertTrue(connection.requireDeviceConfirmation)

        connection.callback.onConnected(oadMode = false)
        assertTrue(harness.listener.transports.isEmpty())
        connection.callback.onNotifyReady()
        connection.callback.onNotifyReady()
        assertEquals(listOf(attempt), harness.listener.transports)
    }

    @Test
    fun staleScanAndConnectionCallbacksAreFenced() {
        val harness = Harness()
        val firstAttempt = VeepooAttemptToken.create()
        harness.bridge.startScan(firstAttempt)
        val firstScan = harness.client.scanCallbacks.last()

        val secondAttempt = VeepooAttemptToken.create()
        harness.bridge.startScan(secondAttempt)
        val secondScan = harness.client.scanCallbacks.last()
        firstScan.onCandidate("AA:00:00:00:00:01")
        firstScan.onFinished()
        secondScan.onCandidate("AA:00:00:00:00:02")

        assertEquals(1, harness.listener.candidates.size)
        assertEquals(secondAttempt, harness.listener.candidates.single().first)
        assertTrue(harness.listener.scanFinished.isEmpty())

        val candidate = harness.listener.candidates.single().second
        harness.bridge.connect(
            VeepooConnectionTarget.Discovered(candidate.handle),
            secondAttempt,
            VeepooConnectionIntent.PAIRING,
        )
        val firstConnection = harness.client.connectionCalls.last()

        val reconnectAttempt = VeepooAttemptToken.create()
        harness.bridge.connect(
            VeepooConnectionTarget.KnownAddress("AA:00:00:00:00:03"),
            reconnectAttempt,
            VeepooConnectionIntent.RECONNECT,
        )
        val reconnect = harness.client.connectionCalls.last()
        assertEquals(1, firstConnection.registration.unregisterCount)
        assertFalse(reconnect.requireDeviceConfirmation)

        firstConnection.callback.onConnected(oadMode = false)
        firstConnection.callback.onNotifyReady()
        firstConnection.callback.onDisconnected()
        assertTrue(harness.listener.transports.isEmpty())
        assertTrue(harness.listener.drops.isEmpty())

        reconnect.callback.onConnected(oadMode = false)
        reconnect.callback.onNotifyReady()
        reconnect.callback.onDisconnected()
        reconnect.callback.onDisconnected()
        assertEquals(listOf(reconnectAttempt), harness.listener.transports)
        assertEquals(listOf(reconnectAttempt), harness.listener.drops)
    }

    @Test
    fun authenticationRequiresFourDigitsAndFinalCompletionCallback() {
        val harness = Harness()
        val (attempt, _) = harness.connectReady()
        val rejectedToken = VeepooAuthenticationToken.create()

        harness.bridge.authenticate(
            "12x4".toCharArray(),
            attempt,
            rejectedToken,
            VeepooConnectionIntent.PAIRING,
        )

        assertTrue(harness.client.authenticationCallbacks.isEmpty())
        assertEquals(VeepooFailure.REJECTED, harness.listener.authenticationFailures.single().third)

        val token = VeepooAuthenticationToken.create()
        harness.bridge.authenticate(
            "0042".toCharArray(),
            attempt,
            token,
            VeepooConnectionIntent.PAIRING,
        )
        val callback = harness.client.authenticationCallbacks.single()
        callback.onIdentity(
            VeepooVendorIdentity(
                deviceNumber = 42,
                hardwareRevision = "test-revision",
                firmwareVersion = "release-version",
            ),
        )
        callback.onHeartRateCapability(true)
        assertTrue(harness.listener.authentications.isEmpty())

        callback.onComplete()
        val result = harness.listener.authentications.single()
        assertEquals(token, result.token)
        assertEquals("42", result.identity.modelCode)
        assertEquals("test-revision", result.identity.hardwareRevision)
        assertEquals("release-version", result.identity.firmwareVersion)
        assertEquals(VeepooCapabilities(liveHeartRate = true, battery = true), result.capabilities)
        assertEquals("0042", harness.client.submittedPasswords.single())
        assertTrue(harness.client.submittedPasswordBuffers.single().all { it == '\u0000' })

        callback.onFailure(VeepooFailure.INTERNAL)
        assertEquals(1, harness.listener.authenticationFailures.size)
    }

    @Test
    fun batteryMustCompleteBeforeLiveHeartRateAndStopFencesSamples() {
        val harness = Harness()
        val (attempt, _) = harness.connectReady()
        harness.authenticate(attempt)

        harness.bridge.startLiveHeartRate(attempt)
        assertTrue(harness.client.heartRateCallbacks.isEmpty())
        assertEquals(attempt to VeepooFailure.REJECTED, harness.listener.failures.single())

        harness.bridge.readBattery(attempt)
        harness.client.batteryCallbacks.single().onReading(73)
        assertEquals(73, harness.listener.batteries.single().second.percent)
        assertEquals(4_242L, harness.listener.batteries.single().second.observedAtMilliseconds)

        harness.bridge.startLiveHeartRate(attempt)
        val heartCallback = harness.client.heartRateCallbacks.single()
        heartCallback.onReading(77)
        assertEquals(77, harness.listener.heartRates.single().second.beatsPerMinute)
        assertEquals(4_242L, harness.listener.heartRates.single().second.phoneReceiptMilliseconds)

        harness.bridge.stopLiveHeartRate(attempt)
        heartCallback.onReading(88)
        assertEquals(1, harness.listener.heartRates.size)
    }

    @Test
    fun disconnectUnregistersDurableListenerBeforeDisconnectAndCloseIsIdempotent() {
        val harness = Harness()
        val (attempt, connection) = harness.connectReady()
        harness.authenticate(attempt)
        harness.bridge.readBattery(attempt)
        harness.client.batteryCallbacks.single().onReading(80)
        harness.bridge.startLiveHeartRate(attempt)
        val staleHeartCallback = harness.client.heartRateCallbacks.single()

        harness.bridge.disconnect(attempt)
        assertEquals(1, connection.registration.unregisterCount)
        assertTrue(
            harness.client.operations.indexOf("unregister") <
                harness.client.operations.lastIndexOf("disconnect"),
        )

        staleHeartCallback.onReading(88)
        assertTrue(harness.listener.heartRates.isEmpty())

        harness.bridge.close()
        harness.bridge.close()
        assertEquals(1, harness.client.operations.count { it == "close" })
    }

    @Test
    fun initializationAndSynchronousFailuresUseFixedCategories() {
        val client = FakeClient().apply {
            initializationFailure = SecurityException()
        }
        val harness = Harness(client)
        val attempt = VeepooAttemptToken.create()

        harness.bridge.startScan(attempt)

        assertEquals(listOf(attempt to VeepooFailure.PERMISSION), harness.listener.failures)
        assertTrue(client.scanCallbacks.isEmpty())
        assertEquals(VeepooFailure.UNSUPPORTED, mapVeepooCode(Code.BLE_NOT_SUPPORTED))
        assertEquals(VeepooFailure.UNAVAILABLE, mapVeepooCode(Code.BLUETOOTH_DISABLED))
        assertEquals(VeepooFailure.TIMEOUT, mapVeepooCode(Code.REQUEST_TIMEDOUT))
        assertEquals(VeepooFailure.REJECTED, mapVeepooCode(Code.REQUEST_DENIED))
        assertEquals(VeepooFailure.INTERNAL, mapVeepooCode(Code.REQUEST_FAILED))
        assertTrue(sameVeepooAddress("AA:BB:CC:DD:EE:FF", "aa:bb:cc:dd:ee:ff"))
        assertFalse(sameVeepooAddress("AA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:00"))
    }

    @Test
    fun batteryAndHeartStatusDecodersFailClosed() {
        val percentage = BatteryData().apply {
            setPercent(true)
            setBatteryPercent(61)
        }
        assertEquals(VeepooBatteryResult.Reading(61), decodeVeepooBattery(percentage))

        val level = BatteryData().apply {
            setPercent(false)
            setBatteryLevel(3)
        }
        assertEquals(VeepooBatteryResult.Reading(75), decodeVeepooBattery(level))

        level.setLowBattery(true)
        assertEquals(
            VeepooBatteryResult.Reading(75),
            decodeVeepooBattery(level),
        )

        val heart = HeartData()
        listOf(
            EHeartStatus.STATE_HEART_BUSY,
            EHeartStatus.STATE_HEART_WEAR_ERROR,
            EHeartStatus.STATE_LOW_BATTERY,
        ).forEach { status ->
            heart.setHeartStatus(status)
            assertEquals(
                VeepooHeartRateResult.Pending,
                decodeVeepooHeartRate(heart),
            )
        }

        heart.setHeartStatus(EHeartStatus.STATE_HEART_NORMAL)
        heart.setData(72)
        assertEquals(VeepooHeartRateResult.Reading(72), decodeVeepooHeartRate(heart))
    }

    companion object {
        private const val SYNTHETIC_ADDRESS = "AA:00:00:00:00:42"
    }
}
