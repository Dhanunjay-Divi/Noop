package com.noop.ingest

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WhoopReferenceImportManifestTest {
    @Test
    fun replaceIsRangeAndManagedKeyScoped() {
        val manifest = WhoopReferenceImportManifest.forTesting(
            FakeSharedPreferences(),
            "test.reference",
        )
        val device = "wearable-import"
        manifest.replaceOfficialMetrics(
            entries = listOf(
                "2026-04-01" to "recovery",
                "2026-04-02" to "recovery",
                "2026-04-02" to "hrv",
            ),
            deviceId = device,
            schemaRevision = "v1",
            from = "2026-04-01",
            to = "2026-04-02",
            managedKeys = setOf("recovery", "hrv"),
        )
        manifest.replaceOfficialMetrics(
            entries = listOf("2026-04-02" to "recovery", "2026-04-03" to "recovery"),
            deviceId = device,
            schemaRevision = "v2",
            from = "2026-04-02",
            to = "2026-04-03",
            managedKeys = setOf("recovery"),
        )

        assertEquals(
            setOf("2026-04-02", "2026-04-03"),
            manifest.verifiedDays(device, "v2", "recovery"),
        )
        assertEquals(
            setOf("2026-04-01"),
            manifest.verifiedDays(device, "v1", "recovery"),
        )
        assertEquals(
            setOf("2026-04-02"),
            manifest.verifiedDays(device, "v1", "hrv"),
        )
    }

    @Test
    fun invalidInputsNeverCreateVerification() {
        val manifest = WhoopReferenceImportManifest.forTesting(FakeSharedPreferences())
        manifest.replaceOfficialMetrics(
            entries = listOf("2026-02-31" to "recovery", "2026-02-01" to "bad-key!"),
            deviceId = "wearable-import",
            schemaRevision = "v1",
            from = "2026-02-01",
            to = "2026-02-28",
            managedKeys = setOf("recovery", "bad-key!"),
        )

        assertTrue(
            manifest.verifiedDays("wearable-import", "v1", "recovery").isEmpty(),
        )
    }

    @Test
    fun invalidationClearsOnlyTheManagedRange() {
        val manifest = WhoopReferenceImportManifest.forTesting(
            FakeSharedPreferences(),
            "test.reference",
        )
        val device = "wearable-import"
        assertTrue(
            manifest.replaceOfficialMetrics(
                entries = listOf(
                    "2026-04-01" to "recovery",
                    "2026-04-02" to "recovery",
                    "2026-04-02" to "hrv",
                ),
                deviceId = device,
                schemaRevision = "v1",
                from = "2026-04-01",
                to = "2026-04-02",
                managedKeys = setOf("recovery", "hrv"),
            ),
        )

        assertTrue(
            manifest.invalidateOfficialMetrics(
                deviceId = device,
                schemaRevision = "v1",
                from = "2026-04-02",
                to = "2026-04-02",
                managedKeys = setOf("recovery"),
            ),
        )

        assertEquals(
            setOf("2026-04-01"),
            manifest.verifiedDays(device, "v1", "recovery"),
        )
        assertEquals(
            setOf("2026-04-02"),
            manifest.verifiedDays(device, "v1", "hrv"),
        )
    }
}
