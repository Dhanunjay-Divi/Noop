package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.ui.VITALITY_WELLNESS_AGE_INPUT_CLAIM
import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android parity guard for omitting un-sourced @57-derived DailyMetric steps from Wellness Age. */
class StepProvenanceSafetyTest {
    private fun day(index: Int) = DailyMetric(
        deviceId = "my-whoop-noop",
        day = "2026-07-%02d".format(index),
        totalSleepMin = 450.0,
        restingHr = 55,
        avgHrv = 42.0,
        recovery = 70.0,
        strain = 12.0,
        steps = 54_321,
        activeKcalEst = 500.0,
    )

    @Test
    fun vitalityInputsOmitUnprovenancedDailySteps() {
        val inputs = IntelligenceEngine.vitalityInputs((1..14).map(::day), chronoAge = 40.0)

        assertNull(inputs.steps)
        assertFalse(VitalityEngine.contributions(inputs).any { it.key == "steps" })
        assertNotNull(VitalityEngine.compute(inputs))
    }

    @Test
    fun userFacingVitalityClaimNamesOnlyCurrentV2Inputs() {
        val claim = VITALITY_WELLNESS_AGE_INPUT_CLAIM.lowercase()
        assertFalse(claim.contains("steps"))
        assertFalse(claim.contains("activity"))
        assertTrue(claim.contains("profile age"))
    }

    @Test
    fun unvalidatedMotionControlsCannotReenterProduction() {
        val root = sourceRoot()
        val settings = File(root, "ui/SettingsScreen.kt").readText()
        val viewModel = File(root, "ui/AppViewModel.kt").readText()
        val bleClient = File(root, "ble/WhoopBleClient.kt").readText()
        val todayLogic = File(root, "ui/TodayMetricsLogic.kt").readText()
        val workouts = File(root, "ui/WorkoutsScreen.kt").readText()
        val health = File(root, "ui/HealthScreen.kt").readText()

        assertFalse(settings.contains("l10n_settings_screen_step_calibration_351c09bf"))
        assertFalse(settings.contains("motionAwareWake"))
        assertFalse(viewModel.contains("useMotionAwareWake = PuffinExperiment"))
        assertFalse(viewModel.contains("repository.strapStepTicks"))
        assertFalse(bleClient.contains("useMotionAwareWake = PuffinExperiment"))
        assertFalse(todayLogic.contains("imported ?: motionDerived"))
        assertFalse(todayLogic.contains("imported ?: calibratedEstimate"))
        assertTrue(todayLogic.contains("internal fun resolvedSteps("))
        assertTrue(
            File(root, "ui/TodayScreen.kt").readText().contains(
                "resolvedSteps(\n                imported = importedStepsForDay,"
            )
        )
        assertFalse(workouts.contains("CLASSIFIED_BAND"))
        assertFalse(health.contains("resolvedSeries(\"steps\", \"my-whoop\""))
    }

    private fun sourceRoot(): File {
        val root = File(checkNotNull(System.getProperty("user.dir")))
        return listOf(
            File(root, "src/main/java/com/noop"),
            File(root, "app/src/main/java/com/noop"),
            File(root, "android/app/src/main/java/com/noop"),
        ).firstOrNull(File::isDirectory) ?: error("Could not locate source root from $root")
    }
}
