package com.noop.ui

import java.io.File
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source/resource contract for generated app-wide copy shared across all surfaces. */
class AppWideLocalizationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun first(vararg candidates: String): File? =
        candidates.map { File(root(), it) }.firstOrNull(File::isFile)

    private fun appWideStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(appwide_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    private fun canonicalKeys(file: File): Set<String> =
        JSONObject(file.readText())
            .keys()
            .asSequence()
            .map { it.replace('.', '_') }
            .toSet()

    @Test
    fun appWideResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        )
        val files = folders.associateWith { folder ->
            first(
                "src/main/res/$folder/appwide.xml",
                "app/src/main/res/$folder/appwide.xml",
                "android/app/src/main/res/$folder/appwide.xml",
            )
        }
        assumeTrue("App-wide locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { appWideStrings(it.value!!) }
        val base = values.getValue("values")
        val canonical = first(
            "Tools/AppWideLocalization/appwide_strings.json",
            "../Tools/AppWideLocalization/appwide_strings.json",
            "../../Tools/AppWideLocalization/appwide_strings.json",
        )
        assertTrue("Canonical app-wide localization source unavailable", canonical != null)
        assertEquals(
            "Android base keys match the canonical source",
            canonicalKeys(canonical!!),
            base.keys,
        )
        assertEquals(
            "Confirm your adult profile details to see a personalized goal.",
            base["appwide_hydration_target_unavailable"],
        )
        assertEquals("Clear %1\$s", base["appwide_hydration_clear_day"])
        assertEquals("Logged %1\$s", base["appwide_hydration_logged_day"])
        assertEquals("Steady", base["appwide_daily_signal_status_aligned"])
        assertEquals("Watch", base["appwide_daily_signal_status_recheck"])
        assertEquals(
            "Imported sleep not included",
            base["appwide_weekly_digest_imported_sleep_not_included"],
        )
        assertEquals(
            "Live heart-rate coaching uses heart rate while today\\'s Recovery is unavailable.",
            base["appwide_live_session_start_detail_unavailable"],
        )
        assertTrue("Removed key must not remain generated", "appwide_live_session_start_detail_calibrating" !in base)
        assertEquals(
            "Only Recovery, Effort, Sleep Score, sleep duration, HRV, and resting heart rate " +
                "can be shared. Raw streams, locations, journals, routes, workouts, and sleep " +
                "stages are excluded.",
            base["appwide_friends_data_boundary"],
        )
        assertEquals(
            "NOOP and Apple Health records may overlap and cannot be matched reliably. " +
                "The displayed total uses the larger source total instead of adding them.",
            base["appwide_hydration_source_merge_apple_health"],
        )
        assertEquals(
            "NOOP and Health Connect records may overlap and cannot be matched reliably. " +
                "The displayed total uses the larger source total instead of adding them.",
            base["appwide_hydration_source_merge_health_connect"],
        )
        assertEquals(
            "Available recorded intake from NOOP and Apple Health · %1\$s.",
            base["appwide_hydration_subtitle_apple_health_format"],
        )
        assertEquals(
            "Available recorded intake from NOOP and Health Connect · %1\$s.",
            base["appwide_hydration_subtitle_health_connect_format"],
        )
        assertEquals("On-device", base["appwide_source_on_device"])
        assertEquals("Imported", base["appwide_source_imported"])
        assertEquals("Apple Health", base["appwide_source_apple_health"])
        assertEquals("Health Connect", base["appwide_source_health_connect"])
        assertEquals("Oura Ring", base["appwide_source_oura_ring"])
        assertEquals("NOOP Band is coming", base["appwide_terms_title"])
        assertTrue(
            base.getValue("appwide_terms_subtitle")
                .contains("compatible band you own"),
        )
        assertEquals(
            "Recovery scores: %1\$d of %2\$d days. One score per day is used in the average.",
            base["appwide_trends_recovery_coverage_format"],
        )
        assertTrue(
            base.getValue("appwide_trends_recovery_descriptor")
                .contains("overnight HRV"),
        )
        assertEquals(
            "Computed on device from HRV against your baseline, resting heart rate, Sleep Score, " +
                "breathing rate and skin temperature deviation when available.",
            base["appwide_metric_education_recovery_method"],
        )
        assertTrue(
            "Recovery education must not claim an unwired load input",
            !base.getValue("appwide_metric_education_recovery_method")
                .contains("recent load", ignoreCase = true),
        )
        assertEquals(
            "Recovery weighs HRV against your personal baseline (about 55 percent), resting heart " +
                "rate (about 20 percent), Sleep Score (about 15 percent), breathing rate (about 5 " +
                "percent), and skin-temperature deviation (about 5 percent) when those inputs are " +
                "available. Effort is a 0–%1\$s cardiovascular-load score from time in heart-rate " +
                "zones. Sleep Score combines available duration, efficiency, stages, and consistency. " +
                "Some displayed days may come from local imports. NOOP-derived scores are calculated " +
                "locally from the listed available inputs; they are not clinical measures, and missing " +
                "inputs stay missing.",
            base["appwide_intelligence_explainer_format"],
        )
        assertEquals(
            "Only the positional Effort maximum may remain as an Android format token",
            "",
            base.getValue("appwide_intelligence_explainer_format")
                .replace("%1\$s", "")
                .filter { it == '%' },
        )
        assertTrue(
            "Intelligence copy must not claim every displayed value is calculated locally",
            !base.getValue("appwide_intelligence_explainer_format")
                .contains("displays values calculated", ignoreCase = true),
        )

        val placeholder = Regex("""%\d+\$[ds]""")
        for ((folder, localized) in values) {
            assertEquals("$folder app-wide key parity", base.keys, localized.keys)
            for (key in base.keys) {
                assertTrue("$folder has blank $key", localized.getValue(key).isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    placeholder.findAll(base.getValue(key)).map { it.value }.sorted().toList(),
                    placeholder.findAll(localized.getValue(key)).map { it.value }.sorted().toList(),
                )
            }
        }
    }

}
