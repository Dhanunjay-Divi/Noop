package com.noop.ble

import com.noop.protocol.DeviceFamily

/** The only battery source that is valid for the currently established transport family. */
internal enum class BatterySource {
    DEFER,
    CUSTOM_COMMAND,
    STANDARD_CHARACTERISTIC,
}

/**
 * The family field can still describe the previous connection until service discovery completes.
 * Defer instead of accepting a plausible but incorrect WHOOP 4 standard-battery stub.
 */
internal fun batterySource(
    familyEstablished: Boolean,
    family: DeviceFamily,
): BatterySource = when {
    !familyEstablished -> BatterySource.DEFER
    family == DeviceFamily.WHOOP4 -> BatterySource.CUSTOM_COMMAND
    else -> BatterySource.STANDARD_CHARACTERISTIC
}
