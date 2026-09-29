package com.noop.ui

import com.noop.ble.LiveHeartRateNotificationPolicy
import com.noop.ble.veepoo.VeepooAdapterState
import com.noop.ble.veepoo.VeepooDisplayState
import com.noop.data.SourceKind
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupplierDisplayHeartRatePolicyTest {
    private val liveDisplay = VeepooDisplayState(
        deviceId = "supplier-band",
        adapterState = VeepooAdapterState.LIVE_DISPLAY_ONLY,
        heartRate = 72,
        phoneReceiptMilliseconds = 100_000L,
        active = true,
    )

    @Test
    fun exactFreshnessBoundaryIsVisibleThenExpires() {
        assertEquals(
            72,
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                100_000L + LiveHeartRateNotificationPolicy.FRESHNESS_MS,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                100_001L + LiveHeartRateNotificationPolicy.FRESHNESS_MS,
            ),
        )
    }

    @Test
    fun futureReceiptTimeFailsClosed() {
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay.copy(phoneReceiptMilliseconds = 100_001L),
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay.copy(phoneReceiptMilliseconds = 100_001L),
                nowMillis = 100_000L,
            ),
        )
    }

    @Test
    fun unchangedDisplayStateExpiresAfterASilentStall() {
        assertEquals(
            LiveHeartRateNotificationPolicy.FRESHNESS_MS + 1L,
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay,
                nowMillis = 100_000L,
            ),
        )
        assertNull(
            SupplierDisplayHeartRatePolicy.visibleBpm(
                liveDisplay,
                nowMillis = 100_000L +
                    LiveHeartRateNotificationPolicy.FRESHNESS_MS +
                    1L,
            ),
        )
        assertEquals(
            0L,
            SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis(
                liveDisplay,
                nowMillis = 100_000L +
                    LiveHeartRateNotificationPolicy.FRESHNESS_MS +
                    1L,
            ),
        )
    }

    @Test
    fun liveScreenRendersOnlyTheBoundedPhoneReceiptPolicyOutput() {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        val source = listOf(
            File(userDir, "src/main/java/com/noop/ui/LiveScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/LiveScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/LiveScreen.kt"),
        ).firstOrNull(File::isFile) ?: error("Could not locate LiveScreen.kt from $userDir")
        val supplierScreen = source.readText()
            .substringAfter("private fun SupplierBandLiveScreen(")
            .substringBefore("// MARK: - Console header")

        assertEquals(
            LiveHeartRateNotificationPolicy.FRESHNESS_MS + 1L,
            SUPPLIER_HEART_RATE_MAX_EXPIRY_DELAY_MS,
        )
        assertTrue(supplierScreen.contains("display.phoneReceiptMilliseconds"))
        assertTrue(supplierScreen.contains("SupplierDisplayHeartRatePolicy.visibleBpm("))
        assertTrue(supplierScreen.contains("SupplierDisplayHeartRatePolicy.expiryCheckDelayMillis("))
        assertTrue(
            supplierScreen.contains(
                "wait.coerceAtMost(SUPPLIER_HEART_RATE_MAX_EXPIRY_DELAY_MS)",
            ),
        )
        assertTrue(supplierScreen.contains("visibleHeartRate?.toString()"))
        assertFalse(supplierScreen.contains("display.heartRate?.toString()"))
    }

    @Test
    fun supplierBatteryIsHiddenUntilTheConnectionIsLive() {
        assertNull(
            visibleSupplierBatteryPercent(
                liveDisplay.copy(
                    adapterState = VeepooAdapterState.RECONNECTING,
                    batteryPercent = 81,
                ),
            ),
        )
        assertEquals(
            81,
            visibleSupplierBatteryPercent(liveDisplay.copy(batteryPercent = 81)),
        )
    }

    @Test
    fun supplierDeviceCardUsesOnlyTheSupplierConnectionAndBatteryState() {
        val projection = deviceCardLiveProjection(
            deviceId = "supplier-band",
            sourceKind = SourceKind.veepoo.name,
            isActive = true,
            standardConnected = false,
            standardBatteryPct = 12.0,
            supplierDisplay = liveDisplay.copy(batteryPercent = 81),
        )

        assertTrue(projection.connected)
        assertEquals(81, projection.batteryPercent)
    }

    @Test
    fun staleStandardStateCannotMakeAnIdleSupplierCardLookLive() {
        val projection = deviceCardLiveProjection(
            deviceId = "supplier-band",
            sourceKind = SourceKind.veepoo.name,
            isActive = true,
            standardConnected = true,
            standardBatteryPct = 91.0,
            supplierDisplay = VeepooDisplayState(),
        )

        assertFalse(projection.connected)
        assertNull(projection.batteryPercent)
    }

    @Test
    fun standardDeviceCardKeepsTheExistingLiveProjection() {
        val projection = deviceCardLiveProjection(
            deviceId = "my-whoop",
            sourceKind = SourceKind.liveBLE.name,
            isActive = true,
            standardConnected = true,
            standardBatteryPct = 64.6,
            supplierDisplay = liveDisplay.copy(batteryPercent = 81),
        )

        assertTrue(projection.connected)
        assertEquals(65, projection.batteryPercent)
    }

    @Test
    fun anotherSupplierCannotInheritThePreviousSuppliersLiveState() {
        val projection = deviceCardLiveProjection(
            deviceId = "supplier-band-b",
            sourceKind = SourceKind.veepoo.name,
            isActive = true,
            standardConnected = false,
            standardBatteryPct = null,
            supplierDisplay = liveDisplay,
        )

        assertFalse(projection.connected)
        assertNull(projection.batteryPercent)
    }

    @Test
    fun durableSupplierSourceKeepsSupplierControlsWhenDisplayResetsIdle() {
        val resetDisplay = VeepooDisplayState()

        assertEquals(VeepooAdapterState.IDLE, resetDisplay.adapterState)
        assertEquals(
            LiveControlMode.SUPPLIER,
            liveControlMode(ActiveDeviceSourceState.SUPPLIER),
        )
    }

    @Test
    fun transientSupplierDisplayCannotReplaceWhoopControls() {
        assertEquals(VeepooAdapterState.LIVE_DISPLAY_ONLY, liveDisplay.adapterState)
        assertEquals(
            LiveControlMode.STANDARD,
            liveControlMode(ActiveDeviceSourceState.STANDARD),
        )
    }

    @Test
    fun unresolvedDurableSourceDoesNotExposeWhoopControls() {
        assertEquals(
            LiveControlMode.RESOLVING,
            liveControlMode(ActiveDeviceSourceState.UNRESOLVED),
        )
    }

    @Test
    fun confirmedNoActiveDeviceStillOffersStandardConnectionControls() {
        assertEquals(
            LiveControlMode.STANDARD,
            liveControlMode(ActiveDeviceSourceState.NO_ACTIVE_DEVICE),
        )
    }

    @Test
    fun liveScreenRoutesBeforeCreatingTheWhoopConnectAction() {
        val source = liveScreenSource().readText()
        val routingBlock = source
            .substringAfter("fun LiveScreen(")
            .substringBefore("val live by viewModel.live.collectAsStateWithLifecycle()")

        assertTrue(
            routingBlock.contains(
                "viewModel.activeDeviceSourceState.collectAsStateWithLifecycle()",
            ),
        )
        assertTrue(routingBlock.contains("when (liveControlMode(activeSourceState))"))
        assertTrue(routingBlock.contains("ResolvingLiveSourceScreen(onManageDevices)"))
        assertTrue(routingBlock.contains("SupplierBandLiveScreen(supplierDisplay, onManageDevices)"))
        assertFalse(routingBlock.contains("supplierDisplay.adapterState"))
        val supplierRoute =
            source.indexOf("SupplierBandLiveScreen(supplierDisplay, onManageDevices)")
        val whoopConnect = source.indexOf("rememberRequestScan { viewModel.connect() }")
        assertTrue(supplierRoute >= 0)
        assertTrue(whoopConnect > supplierRoute)
    }

    @Test
    fun devicesScreenObservesTheSupplierDisplayStream() {
        val source = devicesScreenSource().readText()
        val screen = source
            .substringAfter("fun DevicesScreen(")
            .substringBefore("internal data class DeviceCardLiveProjection")

        assertTrue(
            screen.contains(
                "viewModel.supplierBandDisplay.collectAsStateWithLifecycle()",
            ),
        )
        assertTrue(screen.contains("deviceCardLiveProjection("))
    }

    private fun liveScreenSource(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/LiveScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/LiveScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/LiveScreen.kt"),
        ).firstOrNull(File::isFile) ?: error("Could not locate LiveScreen.kt from $userDir")
    }

    private fun devicesScreenSource(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/DevicesScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/DevicesScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/DevicesScreen.kt"),
        ).firstOrNull(File::isFile) ?: error("Could not locate DevicesScreen.kt from $userDir")
    }
}
