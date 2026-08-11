package com.noop.ble

import com.noop.protocol.CommandNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pins the pure half of the production single-delivery queue without Robolectric/Bluetooth hardware. */
class GattWriteSingleDeliveryTest {
    private class FakeGatt(private val accepted: Boolean) {
        val submitted = mutableListOf<CommandNumber>()

        fun write(command: CommandNumber): Boolean {
            submitted += command
            return accepted
        }
    }

    private fun dispatchOnce(
        gate: GattWriteDeliveryGate<CommandNumber>,
        gatt: FakeGatt,
        command: CommandNumber,
        expectsCallback: Boolean,
    ): GattWriteAction {
        check(gate.begin(command, expectsCallback))
        return gate.submitted(gatt.write(command))
    }

    @Test
    fun `false submission plus late callback never executes non-idempotent command twice`() {
        val gate = GattWriteDeliveryGate<CommandNumber>()
        val gatt = FakeGatt(accepted = false)
        val command = CommandNumber.RUN_HAPTICS_PATTERN
        val confirmed = WhoopBleClient.requiresConfirmedGattWrite(command, requestedWithResponse = false)

        assertTrue("one-shot haptic must request a correlatable callback", confirmed)
        assertEquals(
            GattWriteAction.WAIT_FOR_UNCERTAIN_CALLBACK,
            dispatchOnce(gate, gatt, command, expectsCallback = confirmed),
        )
        assertEquals(listOf(command), gatt.submitted)

        // The queue is still occupied, so even an eager caller cannot submit the command a second time.
        assertFalse(gate.begin(command, expectsCallback = true))
        assertEquals(1, gatt.submitted.size)

        // A vendor stack may report one late success despite returning false. It completes the original
        // attempt, enters callback quarantine, and a duplicate callback is ignored.
        assertEquals(command, gate.callback())
        assertNull(gate.callback())
        assertTrue(gate.isBusy())
        assertEquals(command, gate.paced())
        assertFalse(gate.isBusy())
        assertEquals("the late callback must not cause a replay", 1, gatt.submitted.size)
    }

    @Test
    fun `false no-response submission fails closed and ignores late callback`() {
        val gate = GattWriteDeliveryGate<CommandNumber>()
        val gatt = FakeGatt(accepted = false)
        val command = CommandNumber.GET_BATTERY_LEVEL

        assertEquals(
            GattWriteAction.FAIL_CLOSED,
            dispatchOnce(gate, gatt, command, expectsCallback = false),
        )
        assertFalse(gate.isBusy())
        assertNull(gate.callback())
        assertEquals(1, gatt.submitted.size)
    }

    @Test
    fun `callback timeout consumes attempt and a later callback cannot complete another command`() {
        val gate = GattWriteDeliveryGate<CommandNumber>()
        val gatt = FakeGatt(accepted = true)
        val command = CommandNumber.REBOOT_STRAP

        assertEquals(
            GattWriteAction.WAIT_FOR_CALLBACK,
            dispatchOnce(gate, gatt, command, expectsCallback = true),
        )
        assertEquals(command, gate.timeout())
        assertFalse(gate.isBusy())
        assertNull("callback after fail-closed timeout belongs to the closed GATT", gate.callback())
        assertEquals(1, gatt.submitted.size)
    }

    @Test
    fun `all physical one-shot commands force confirmed delivery`() {
        for (command in listOf(
            CommandNumber.RUN_HAPTICS_PATTERN,
            CommandNumber.RUN_HAPTIC_PATTERN_MAVERICK,
            CommandNumber.RUN_ALARM,
            CommandNumber.REBOOT_STRAP,
            CommandNumber.POWER_CYCLE_STRAP,
        )) {
            assertEquals(command.toString(), GattWriteIdempotency.NON_IDEMPOTENT,
                WhoopBleClient.commandWriteIdempotency(command))
            assertTrue(command.toString(),
                WhoopBleClient.requiresConfirmedGattWrite(command, requestedWithResponse = false))
        }
    }

    @Test
    fun `idempotent commands preserve requested write type but are still never replayed after false`() {
        for (command in listOf(
            CommandNumber.TOGGLE_REALTIME_HR,
            CommandNumber.SET_CLOCK,
            CommandNumber.GET_DATA_RANGE,
            CommandNumber.HISTORICAL_DATA_RESULT,
            CommandNumber.SET_ALARM_TIME,
        )) {
            assertEquals(command.toString(), GattWriteIdempotency.IDEMPOTENT,
                WhoopBleClient.commandWriteIdempotency(command))
            assertFalse(command.toString(),
                WhoopBleClient.requiresConfirmedGattWrite(command, requestedWithResponse = false))
            assertTrue(command.toString(),
                WhoopBleClient.requiresConfirmedGattWrite(command, requestedWithResponse = true))
        }
    }
}
