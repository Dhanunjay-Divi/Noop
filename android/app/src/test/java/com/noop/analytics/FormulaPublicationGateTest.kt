package com.noop.analytics

import com.noop.testing.FakeSharedPreferences
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.test.runTest

class FormulaPublicationGateTest {
    @Test
    fun computedPublicationRequiresBothCurrentMarkers() {
        assertFalse(FormulaPublicationGate.computedDerivedReady(null, null))
        assertFalse(
            FormulaPublicationGate.computedDerivedReady(
                ChargeFormulaUpgradeGate.CURRENT_REVISION,
                null,
            ),
        )
        assertFalse(
            FormulaPublicationGate.computedDerivedReady(
                "noop-charge-v1",
                RestFormulaUpgradeGate.CURRENT_REVISION,
            ),
        )
        assertTrue(
            FormulaPublicationGate.computedDerivedReady(
                ChargeFormulaUpgradeGate.CURRENT_REVISION,
                RestFormulaUpgradeGate.CURRENT_REVISION,
            ),
        )
    }

    @Test
    fun persistedMarkersRemainFailClosedUntilBothComplete() {
        val preferences = FakeSharedPreferences()
        preferences.edit()
            .putString(
                ChargeFormulaUpgradeGate.COMPLETED_REVISION_KEY,
                ChargeFormulaUpgradeGate.CURRENT_REVISION,
            )
            .apply()

        assertFalse(FormulaPublicationGate.computedDerivedReady(preferences))

        preferences.edit()
            .putString(
                RestFormulaUpgradeGate.COMPLETED_REVISION_KEY,
                RestFormulaUpgradeGate.CURRENT_REVISION,
            )
            .apply()

        assertTrue(FormulaPublicationGate.computedDerivedReady(preferences))
    }

    @Test
    fun onlyComputedDerivedPublicationIsDeferred() {
        listOf(
            "strap_measured",
            "official_reference",
            "noop_journal",
            "apple_health_import",
            "health_connect_import",
            "activity_file_import",
            "wearable_import",
        ).forEach { sourceKind ->
            assertTrue(
                FormulaPublicationGate.shouldPublishDerived(
                    sourceKind,
                    computedDerivedReady = false,
                ),
            )
        }
        assertFalse(
            FormulaPublicationGate.shouldPublishDerived(
                FormulaPublicationGate.COMPUTED_SOURCE_KIND,
                computedDerivedReady = false,
            ),
        )
        assertTrue(
            FormulaPublicationGate.shouldPublishDerived(
                FormulaPublicationGate.COMPUTED_SOURCE_KIND,
                computedDerivedReady = true,
            ),
        )
    }

    @Test
    fun managedGateRemovesOnlyComputedDerivedSummaries() {
        val all = listOf(
            "essential_timeseries",
            "raw_auxiliary",
            "raw_ppg",
            "raw_motion",
            FormulaPublicationGate.MANAGED_DERIVED_DATA_CLASS,
        )

        assertEquals(
            all.dropLast(1),
            FormulaPublicationGate.managedDataClasses(
                FormulaPublicationGate.COMPUTED_SOURCE_KIND,
                all,
                computedDerivedReady = false,
            ),
        )
        assertEquals(
            all,
            FormulaPublicationGate.managedDataClasses(
                "apple_health",
                all,
                computedDerivedReady = false,
            ),
        )
        assertEquals(
            mapOf(
                "computed_derived" to "deferred",
                "reason" to "formula_migration",
            ),
            FormulaPublicationGate.DEFERRED_DIAGNOSTIC_FIELDS,
        )
    }

    @Test
    fun socialSummaryPublicationWaitsForFormulaMigration() {
        assertFalse(
            FormulaPublicationGate.shouldPublishSocialSummaries(
                computedDerivedReady = false,
            ),
        )
        assertTrue(
            FormulaPublicationGate.shouldPublishSocialSummaries(
                computedDerivedReady = true,
            ),
        )
    }

    @Test
    fun managedSocialSummaryUploadBodyWaitsForFormulaMigration() = runTest {
        var uploadAttempts = 0
        val deferred = FormulaPublicationGate.publishSocialSummariesIfReady(
            computedDerivedReady = false,
        ) {
            uploadAttempts += 1
            7
        }
        assertEquals(null, deferred)
        assertEquals(0, uploadAttempts)

        val published = FormulaPublicationGate.publishSocialSummariesIfReady(
            computedDerivedReady = true,
        ) {
            uploadAttempts += 1
            7
        }
        assertEquals(7, published)
        assertEquals(1, uploadAttempts)
    }

    @Test
    fun uploadPathsUseTheSharedFailClosedGate() {
        val remoteCoordinator = source(
            "src/main/java/com/noop/sync/RemoteSyncCoordinator.kt",
            "app/src/main/java/com/noop/sync/RemoteSyncCoordinator.kt",
            "android/app/src/main/java/com/noop/sync/RemoteSyncCoordinator.kt",
        )
        val remoteService = source(
            "src/main/java/com/noop/sync/RemoteSyncService.kt",
            "app/src/main/java/com/noop/sync/RemoteSyncService.kt",
            "android/app/src/main/java/com/noop/sync/RemoteSyncService.kt",
        )
        val managedService = source(
            "src/main/java/com/noop/managed/ManagedCloudService.kt",
            "app/src/main/java/com/noop/managed/ManagedCloudService.kt",
            "android/app/src/main/java/com/noop/managed/ManagedCloudService.kt",
        )

        assertTrue(remoteCoordinator.contains("computedDerivedDeferred"))
        assertTrue(remoteCoordinator.contains(
            "hasMoreDerivedRows = namespace.includeDerived && sendDerived",
        ))
        assertTrue(remoteService.contains("FormulaPublicationGate.computedDerivedReady"))
        assertTrue(remoteService.contains("FormulaPublicationGate.DEFERRED_DIAGNOSTIC_FIELDS"))
        assertTrue(remoteService.contains("hasDeferredComputedDerived"))
        assertTrue(remoteService.contains("!hasDeferredComputedDerived"))
        assertTrue(managedService.contains("FormulaPublicationGate.managedDataClasses"))
        assertTrue(managedService.contains(
            "FormulaPublicationGate.publishSocialSummariesIfReady",
        ))
        assertTrue(managedService.contains("dataClasses = dataClasses"))
    }

    private fun source(vararg candidates: String): String {
        val root = File(System.getProperty("user.dir") ?: ".")
        return candidates
            .asSequence()
            .map { File(root, it) }
            .firstOrNull(File::isFile)
            ?.readText()
            ?: error("Could not locate ${candidates.joinToString()}")
    }
}
