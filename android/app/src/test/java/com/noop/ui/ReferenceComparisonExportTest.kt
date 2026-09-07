package com.noop.ui

import com.noop.analytics.ReferenceMetricObservation
import com.noop.analytics.WhoopComparableMetric
import com.noop.analytics.WhoopReferenceCalibration
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReferenceComparisonExportTest {
    private fun report() = WhoopReferenceCalibration.report(
        metric = WhoopComparableMetric.RECOVERY_SCORE,
        observations = (1..30).flatMap { index ->
            val day = "2026-01-${index.toString().padStart(2, '0')}"
            listOf(
                ReferenceMetricObservation.officialExport(
                    day,
                    WhoopComparableMetric.RECOVERY_SCORE,
                    40.0 + index,
                    "whoop-csv-import-v5",
                ),
                ReferenceMetricObservation.noopComputed(
                    day,
                    WhoopComparableMetric.RECOVERY_SCORE,
                    38.0 + index,
                    "noop-charge-v2",
                ),
            )
        },
        noopAlgorithmVersion = "noop-charge-v2",
    )

    @Test
    fun summaryScopeOmitsDatesAndDailyValues() {
        val exported = requireNotNull(
            ReferenceComparisonExport.makePackage(
                report(),
                "Recovery",
                "0-100 score",
                "9.2.1",
                "Android",
                "whoop-csv-import-v5",
                ReferenceComparisonExport.Scope.SUMMARY_ONLY,
                "260907-1200",
            ),
        )

        assertEquals(listOf("summary.txt"), exported.entries.map { it.first })
        val summary = exported.entries.single().second.decodeToString()
        assertFalse(summary.contains("2026-01-01"))
        assertFalse(summary.contains("official_provider_value"))
        assertTrue(summary.contains("Paired days: 30"))
    }

    @Test
    fun exactScopeIncludesReviewedPairCsv() {
        val exported = requireNotNull(
            ReferenceComparisonExport.makePackage(
                report(),
                "Recovery",
                "0-100 score",
                "9.2.1",
                "Android",
                "whoop-csv-import-v5",
                ReferenceComparisonExport.Scope.EXACT_DAILY_PAIRS,
                "260907-1200",
            ),
        )

        assertEquals(listOf("summary.txt", "daily_pairs.csv"), exported.entries.map { it.first })
        val csv = exported.entries.last().second.decodeToString()
        assertTrue(csv.startsWith("day,official_provider_value,noop_value,noop_minus_official\n"))
        assertTrue(csv.contains("2026-01-01,41,39,-2"))
        assertTrue(exported.suggestedName.contains("exact-daily-pairs-android-v9-2-1"))
    }
}
