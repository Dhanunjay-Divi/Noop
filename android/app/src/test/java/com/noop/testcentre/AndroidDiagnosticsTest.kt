package com.noop.testcentre

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The pure half of the Android env-header block (spec section 3.4). [AndroidDiagnostics.summaryLines]
 * itself reads live system services (PowerManager, BatteryManager, permission grants) and so needs a
 * real Context, which the Robolectric-free suite (junit only, see DebugExportSchedulerTest /
 * DeviceRegistryTest) does not provide. The Context-touching path is exercised centrally on-device; here
 * we pin the one piece of decision logic a bug would silently break: the OEM aggressive-vendor heuristic.
 */
class AndroidDiagnosticsTest {

    @Test fun aggressiveVendorsAreFlagged() {
        for (vendor in listOf("Xiaomi", "OPPO", "vivo", "HUAWEI", "OnePlus", "realme", "Meizu")) {
            val text = AndroidDiagnostics.oemKillHeuristic(vendor)
            assertTrue("$vendor should flag as aggressive", text.startsWith("aggressive vendor"))
            assertTrue("$vendor heuristic should advise whitelisting", text.contains("whitelist NOOP"))
        }
    }

    @Test fun standardVendorsAreNotFlagged() {
        for (vendor in listOf("Google", "Samsung", "Sony", "Motorola")) {
            assertEquals("standard", AndroidDiagnostics.oemKillHeuristic(vendor))
        }
    }

    @Test fun heuristicIsCaseInsensitive() {
        assertTrue(AndroidDiagnostics.oemKillHeuristic("XIAOMI").startsWith("aggressive vendor"))
        assertTrue(AndroidDiagnostics.oemKillHeuristic("xiaomi").startsWith("aggressive vendor"))
    }

    @Test fun summaryIncludesNotificationLifecycleLedger() {
        val root = File(System.getProperty("user.dir") ?: ".")
        val source = listOf(
            File(root, "src/main/java/com/noop/testcentre/AndroidDiagnostics.kt"),
            File(root, "app/src/main/java/com/noop/testcentre/AndroidDiagnostics.kt"),
            File(root, "android/app/src/main/java/com/noop/testcentre/AndroidDiagnostics.kt"),
        ).firstOrNull(File::isFile)
        assumeTrue("AndroidDiagnostics source unavailable", source != null)

        assertTrue(
            source!!.readText().contains(
                "NotificationLifecycleLedger.diagnosticLines(context)",
            ),
        )
    }
}
