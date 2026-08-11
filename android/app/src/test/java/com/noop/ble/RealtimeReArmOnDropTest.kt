package com.noop.ble

import com.noop.protocol.CommandNumber
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #312 legacy recovery contract: only a lost TOGGLE_REALTIME_HR may alter the realtime latch. The
 * production queue now fail-closes an ambiguous submission instead of retrying/dropping it; reset clears
 * the latch and reconnect re-arms live R-R from the surviving user intent. A 5/MG whose toggle loses a
 * write race therefore recovers without ever replaying haptics, alarms, trim ACKs, or other commands.
 *
 * Pins the pure decision [WhoopBleClient.shouldReArmRealtimeAfterDrop] — the full drop→re-arm behaviour
 * needs a live GATT stack the unit harness can't fake (no Robolectric; see GattCrashSafetyTest's INFRA NOTE),
 * so, matching that file's pattern, this pins the predicate the drop path is built on.
 */
class RealtimeReArmOnDropTest {

    @Test
    fun `dropped realtime toggle re-arms`() {
        assertTrue(WhoopBleClient.shouldReArmRealtimeAfterDrop(CommandNumber.TOGGLE_REALTIME_HR))
    }

    @Test
    fun `other dropped commands never poke the realtime latch`() {
        // Each has its own recovery; clearing realtimeArmed for them would spuriously re-send the toggle.
        for (cmd in listOf(
            CommandNumber.RUN_HAPTICS_PATTERN,
            CommandNumber.SEND_HISTORICAL_DATA,
            CommandNumber.HISTORICAL_DATA_RESULT,
            CommandNumber.SET_CLOCK,
            CommandNumber.SET_ALARM_TIME,
            CommandNumber.GET_BATTERY_LEVEL,
        )) {
            assertFalse("$cmd must not re-arm realtime", WhoopBleClient.shouldReArmRealtimeAfterDrop(cmd))
        }
    }

    @Test
    fun `an untagged (null-command) dropped frame does not re-arm`() {
        assertFalse(WhoopBleClient.shouldReArmRealtimeAfterDrop(null))
    }
}
