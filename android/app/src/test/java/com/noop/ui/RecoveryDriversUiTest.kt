package com.noop.ui

import com.noop.R
import com.noop.analytics.ChargeDriverValueFormat
import com.noop.analytics.ScoreConfidence
import com.noop.data.DailyMetric
import java.io.File
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Locale
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the Today "What shaped it" wiring: [recoveryChargeDrivers] (folds the visible history
 * into baselines, then defers to RecoveryDrivers.chargeDrivers) and [chargeConfidenceTier] (surfaces the
 * existing ScoreConfidence). Pure JVM, no Robolectric. Mirrors the iOS chargeDrivers wiring tests.
 */
class RecoveryDriversUiTest {

    private fun day(
        d: String,
        hrv: Double? = 55.0,
        rhr: Int? = 55,
        resp: Double? = 15.0,
        recovery: Double? = null,
        efficiency: Double? = 0.9,
        sleepMin: Double? = 450.0,
        skinTempDevC: Double? = null,
    ) = DailyMetric(
        deviceId = "my-whoop-noop", day = d, avgHrv = hrv, restingHr = rhr, respRateBpm = resp,
        recovery = recovery, efficiency = efficiency, totalSleepMin = sleepMin, skinTempDevC = skinTempDevC,
    )

    /** A history long enough to make the HRV baseline usable, plus a scored "today". */
    private fun scoredHistory(): List<DailyMetric> {
        val past = (1..10).map { day("2026-01-%02d".format(it), hrv = 50.0 + (it % 3)) }
        val today = day("2026-01-20", hrv = 62.0, rhr = 51, resp = 15.0, recovery = 64.0, skinTempDevC = 0.2)
        return past + today
    }

    @Test fun scoredDayProducesDriverRows() {
        val days = scoredHistory()
        val drivers = recoveryChargeDrivers(days, days.last())
        assertTrue("a usable baseline should yield driver rows", drivers.isNotEmpty())
        val labels = drivers.map { it.label }
        assertTrue(labels.contains("Heart rate variability"))
        assertTrue(labels.contains("Resting heart rate"))
        // Skin-temp was supplied on the scored day, so its row is present.
        assertTrue(labels.contains("Skin temperature"))
    }

    @Test fun coldStartHistoryProducesNoRows() {
        // Two nights only: the HRV baseline is not usable yet, so there are no honest drivers.
        val days = listOf(
            day("2026-01-01", hrv = 55.0),
            day("2026-01-02", hrv = 58.0, recovery = null),
        )
        assertTrue(recoveryChargeDrivers(days, days.last()).isEmpty())
    }

    @Test fun confidenceTierIsSurfaced() {
        val days = scoredHistory()
        // A scored day on a now-usable baseline surfaces a non-calibrating tier.
        val tier = chargeConfidenceTier(days, days.last())
        assertTrue(tier == ScoreConfidence.BUILDING || tier == ScoreConfidence.SOLID)
        // A day with no recovery number surfaces CALIBRATING.
        assertEquals(ScoreConfidence.CALIBRATING, chargeConfidenceTier(days, day("2026-01-21", recovery = null)))
    }

    @Test fun nullDayProducesNoRows() {
        assertTrue(recoveryChargeDrivers(scoredHistory(), null).isEmpty())
    }

    @Test fun explanationRequiresComputedRecoveryProvenance() {
        assertTrue(canExplainRecovery("my-whoop-noop"))
        assertTrue(canExplainRecovery("strap-42-noop"))
        assertTrue(!canExplainRecovery("my-whoop"))
        assertTrue(!canExplainRecovery("apple-health"))
        assertTrue(!canExplainRecovery(null))
    }

    @Test fun driverPointLabelsUseExplicitSignsAndTrueMinus() {
        assertEquals("+3", chargeDriverPointLabel(3))
        assertEquals("−2", chargeDriverPointLabel(-2))
        assertEquals("0", chargeDriverPointLabel(0))
    }

    @Test fun recoveryDriverNumbersUseTheActiveLocaleAndPreserveSignedDeviation() {
        assertEquals(
            "15,2",
            recoveryDriverNumberText(
                15.2,
                ChargeDriverValueFormat.BREATHS_PER_MINUTE,
                Locale.GERMANY,
            ),
        )
        assertEquals(
            "+0,4",
            recoveryDriverNumberText(
                0.4,
                ChargeDriverValueFormat.CELSIUS_DEVIATION,
                Locale.GERMANY,
            ),
        )
        assertEquals(
            "−0,4",
            recoveryDriverNumberText(
                -0.4,
                ChargeDriverValueFormat.CELSIUS_DEVIATION,
                Locale.GERMANY,
            ),
        )
    }

    @Test fun germanRespiratoryAndSkinTemperatureOutputHasLocalizedUnitsAndNoEnglishBaselineSuffix() {
        val respiratory = renderResource(
            folder = "values-de",
            key = "ui_audit_recovery_driver_value_breaths_per_minute",
            argument = recoveryDriverNumberText(
                15.2,
                ChargeDriverValueFormat.BREATHS_PER_MINUTE,
                Locale.GERMANY,
            ),
        )
        val skinTemperature = renderResource(
            folder = "values-de",
            key = "ui_audit_recovery_driver_value_celsius_deviation",
            argument = recoveryDriverNumberText(
                -0.4,
                ChargeDriverValueFormat.CELSIUS_DEVIATION,
                Locale.GERMANY,
            ),
        )

        assertEquals("15,2 Atemzüge/min", respiratory)
        assertEquals("−0,4 °C", skinTemperature)
        assertFalse(respiratory.contains("br/min"))
        assertFalse(skinTemperature.contains("vs baseline", ignoreCase = true))
    }

    @Test fun everyDriverValueFormatHasALocalizedPresentationMapping() {
        val expected = mapOf(
            ChargeDriverValueFormat.MILLISECONDS to
                R.string.ui_audit_recovery_driver_value_milliseconds,
            ChargeDriverValueFormat.BEATS_PER_MINUTE to
                R.string.ui_audit_recovery_driver_value_beats_per_minute,
            ChargeDriverValueFormat.PERCENT to
                R.string.ui_audit_recovery_driver_value_percent,
            ChargeDriverValueFormat.BREATHS_PER_MINUTE to
                R.string.ui_audit_recovery_driver_value_breaths_per_minute,
            ChargeDriverValueFormat.CELSIUS_DEVIATION to
                R.string.ui_audit_recovery_driver_value_celsius_deviation,
        )

        expected.forEach { (format, resource) ->
            assertEquals(resource, recoveryDriverValueFormatRes(format))
        }
    }

    @Test fun everyCanonicalDriverLabelHasALocalizedPresentationMapping() {
        val expected = mapOf(
            "Heart rate variability" to R.string.appwide_day_overview_hrv,
            "Resting heart rate" to R.string.appwide_day_overview_resting_heart_rate,
            "Sleep Score" to R.string.appwide_day_overview_sleep,
            "Respiratory rate" to R.string.appwide_day_overview_respiratory_rate,
            "Skin temperature" to R.string.appwide_day_overview_skin_temperature,
        )

        expected.forEach { (label, resource) ->
            assertEquals(resource, recoveryDriverLabelRes(label))
        }
        assertEquals(null, recoveryDriverLabelRes("Future signal"))
    }

    @Test fun everyCanonicalDriverVerdictHasALocalizedPresentationMapping() {
        val expected = mapOf(
            "above baseline, supporting recovery" to
                R.string.ui_audit_recovery_driver_verdict_above_supporting,
            "at baseline" to R.string.ui_audit_recovery_driver_verdict_at_baseline,
            "below baseline, limiting recovery" to
                R.string.ui_audit_recovery_driver_verdict_below_limiting,
            "below baseline, supporting recovery" to
                R.string.ui_audit_recovery_driver_verdict_below_supporting,
            "above baseline, limiting recovery" to
                R.string.ui_audit_recovery_driver_verdict_above_limiting,
            "a typical night" to R.string.ui_audit_recovery_driver_verdict_typical_night,
            "Sleep Score supported recovery" to
                R.string.ui_audit_recovery_driver_verdict_sleep_supported,
            "Sleep Score was neutral" to
                R.string.ui_audit_recovery_driver_verdict_sleep_neutral,
            "Sleep Score limited recovery" to
                R.string.ui_audit_recovery_driver_verdict_sleep_limited,
            "near baseline" to R.string.ui_audit_recovery_driver_verdict_near_baseline,
            "warmer than baseline, limiting recovery" to
                R.string.ui_audit_recovery_driver_verdict_warmer_limiting,
            "cooler than baseline, limiting recovery" to
                R.string.ui_audit_recovery_driver_verdict_cooler_limiting,
        )

        expected.forEach { (verdict, resource) ->
            assertEquals(resource, recoveryDriverVerdictRes(verdict))
        }
        assertEquals(null, recoveryDriverVerdictRes("Future verdict"))
    }

    @Test fun displayedAndFutureRowsCannotRewriteExplanationBaseline() {
        val prior = (1..6).map { day("2026-01-%02d".format(it), hrv = 50.0, rhr = 60) }
        val displayed = day("2026-01-10", hrv = 100.0, rhr = 40, recovery = 70.0)
        val future = day("2026-01-11", hrv = 200.0, rhr = 30)

        val drivers = recoveryChargeDrivers(prior + displayed + future, displayed)

        assertEquals(
            50.0,
            drivers.first { it.label == "Heart rate variability" }.baseline!!,
            0.0,
        )
        assertEquals(
            60.0,
            drivers.first { it.label == "Resting heart rate" }.baseline!!,
            0.0,
        )
    }

    @Test fun explanationHonorsManualRecalibrationEpoch() {
        val old = (1..5).map { day("2026-01-%02d".format(it), hrv = 40.0, rhr = 70) }
        val currentEra = (6..10).map { day("2026-01-%02d".format(it), hrv = 70.0, rhr = 55) }
        val displayed = day("2026-01-11", hrv = 75.0, rhr = 52, recovery = 70.0)
        val epoch = LocalDate.parse("2026-01-06").atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()

        val drivers = recoveryChargeDrivers(
            old + currentEra + displayed,
            displayed,
            hrvBaselineEpoch = epoch,
            recoveryBaselineEpoch = epoch,
        )

        assertEquals(
            70.0,
            drivers.first { it.label == "Heart rate variability" }.baseline!!,
            0.0,
        )
        assertEquals(
            55.0,
            drivers.first { it.label == "Resting heart rate" }.baseline!!,
            0.0,
        )
    }

    private fun renderResource(folder: String, key: String, argument: String): String {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        val file = listOf(
            File(root, "src/main/res/$folder/appwide.xml"),
            File(root, "app/src/main/res/$folder/appwide.xml"),
            File(root, "android/app/src/main/res/$folder/appwide.xml"),
        ).firstOrNull(File::isFile)
        val xml = checkNotNull(file) { "Could not locate $folder/appwide.xml from $root" }.readText()
        val value = checkNotNull(
            Regex("""<string name="$key">(.*?)</string>""").find(xml)?.groupValues?.get(1),
        ) { "Missing $folder/$key" }
        return value.replace("%1\$s", argument).replace("%%", "%")
    }
}
