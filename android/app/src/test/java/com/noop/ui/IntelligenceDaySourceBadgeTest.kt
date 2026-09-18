package com.noop.ui

import com.noop.R
import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the By-Day source badge (Sleep overhaul §2.6). The card used to hard-code "NOOP-computed" on
 * EVERY row — even days an import won the dashboard merge — so a user couldn't tell a strap-scored
 * night from an imported one. The badge now derives from the merged DailyMetric's WINNING deviceId:
 *   - computed "<id>-noop" -> generated On-device resource
 *   - imported compatible export -> generated Imported resource
 *   - apple-health / health-connect -> distinct generated platform resources
 */
class IntelligenceDaySourceBadgeTest {

    @Test
    fun computedNoopRow_isOnDevice() {
        assertEquals(R.string.appwide_source_on_device, daySourceBadge("my-whoop-noop").first)
    }

    @Test
    fun anyNoopSuffix_isOnDevice() {
        // A non-default strap id keeps the "-noop" computed suffix convention.
        assertEquals(R.string.appwide_source_on_device, daySourceBadge("strap-abc123-noop").first)
    }

    @Test
    fun whoopImportRow_isImported() {
        // The merged row keeps the legacy imported source id when a compatible export wins the merge.
        assertEquals(R.string.appwide_source_imported, daySourceBadge("my-whoop").first)
    }

    @Test
    fun appleHealthRow_isAppleHealth() {
        assertEquals(
            R.string.appwide_source_apple_health,
            daySourceBadge(WhoopRepository.APPLE_HEALTH_SOURCE).first,
        )
    }

    @Test
    fun healthConnectRow_isHealthConnect() {
        assertEquals(
            R.string.appwide_source_health_connect,
            daySourceBadge(WhoopRepository.HEALTH_CONNECT_SOURCE).first,
        )
    }

    @Test
    fun computedTintDiffersFromImportTint() {
        // Computed rows keep the charge tint; imports use the accent tint so they stand out.
        assertEquals(Palette.chargeColor, daySourceBadge("my-whoop-noop").second)
        assertEquals(Palette.accent, daySourceBadge("my-whoop").second)
    }

    @Test
    fun everyBadgeLabelUsesAGeneratedAppWideResource() {
        val generatedLabels = setOf(
            R.string.appwide_source_on_device,
            R.string.appwide_source_imported,
            R.string.appwide_source_apple_health,
            R.string.appwide_source_health_connect,
            R.string.appwide_source_oura_ring,
        )
        for (
            id in listOf(
                "my-whoop-noop",
                "my-whoop",
                "apple-health",
                "health-connect",
                "oura-api",
            )
        ) {
            assertTrue(daySourceBadge(id).first in generatedLabels)
        }
    }
}
