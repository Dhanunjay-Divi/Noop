package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Keeps Android's complete and intentionally feature-scoped locale sets honest. */
class AndroidLocalizationPolicyTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun resourceFile(folder: String): File? = listOf(
        File(root(), "src/main/res/$folder/strings.xml"),
        File(root(), "app/src/main/res/$folder/strings.xml"),
        File(root(), "android/app/src/main/res/$folder/strings.xml"),
    ).firstOrNull(File::isFile)

    private fun resourceRoot(): File? = listOf(
        File(root(), "src/main/res"),
        File(root(), "app/src/main/res"),
        File(root(), "android/app/src/main/res"),
    ).firstOrNull(File::isDirectory)

    private data class ResourceValue(
        val value: String,
        val placeholders: List<String>,
    )

    private fun resources(file: File): Map<String, ResourceValue> {
        val pattern = Regex(
            """<(string|plurals)\s+name="([^"]+)"[^>]*>(.*?)</\1>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        val placeholder = Regex("""%(?:\d+\$)?[a-zA-Z]""")
        return pattern.findAll(file.readText()).associate { match ->
            val key = "${match.groupValues[1]}:${match.groupValues[2]}"
            val value = match.groupValues[3].trim()
            key to ResourceValue(
                value = value,
                placeholders = placeholder.findAll(value).map { it.value }.sorted().toList(),
            )
        }
    }

    @Test
    fun completeLocalesContainEveryDefaultResource() {
        val baseFile = resourceFile("values")
        val localizedFiles = listOf(
            "values-de",
            "values-es",
            "values-fr",
            "values-pt-rPT",
            "values-zh",
        ).associateWith(::resourceFile)
        assumeTrue(
            "Complete locale resources unavailable",
            baseFile != null && localizedFiles.values.all { it != null },
        )

        val base = resources(baseFile!!)
        val translatableKeys = base.keys.filterNot { it == "string:app_name" }.toSet()
        for ((folder, file) in localizedFiles) {
            val localized = resources(file!!)
            val missing = translatableKeys - localized.keys
            assertTrue("$folder is missing complete-locale resources: $missing", missing.isEmpty())
            assertTrue(
                "$folder has blank values: ${localized.filterValues { it.value.isBlank() }.keys}",
                localized.values.none { it.value.isBlank() },
            )
        }
    }

    @Test
    fun partialLocalesHaveExactFeatureAndPlaceholderParity() {
        val baseFile = resourceFile("values")
        val partialFiles = listOf(
            "values-it",
            "values-ru",
            "values-zh-rTW",
        ).associateWith(::resourceFile)
        assumeTrue(
            "Partial locale resources unavailable",
            baseFile != null && partialFiles.values.all { it != null },
        )

        val base = resources(baseFile!!)
        val partial = partialFiles.mapValues { resources(it.value!!) }
        val expectedKeys = partial.getValue("values-it").keys
        val allowed = Regex(
            """string:(wind_down_|sleep_planner_|strength_|key_metrics_(selection_|show_)|hydration_(adaptive_timing_|base_interval_label)).*|""" +
                """string:(widget_hrv|trends_effort|l10n_today_screen_(recovery_ea924f72|sleep_3cac34e6|resting_hr_26677094|blood_oxygen_a8ad9ff5|respiratory_1cd8c175|steps_cdde4f20|weight_69c0b815|calories_3e62ecfe))|""" +
                """string:(nav_alarms|today_calibration_valid_hrv_progress)""",
        )

        assertTrue(
            "Partial strings.xml contains an unscoped key",
            expectedKeys.all { allowed.matches(it) },
        )
        for ((folder, localized) in partial) {
            assertEquals("$folder feature key parity", expectedKeys, localized.keys)
            for (key in expectedKeys) {
                assertTrue("$folder key $key is absent from default resources", key in base)
                assertTrue("$folder has blank $key", localized.getValue(key).value.isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    base.getValue(key).placeholders,
                    localized.getValue(key).placeholders,
                )
            }
        }
    }

    @Test
    fun userVisibleResourcesContainNoEmDash() {
        val resources = resourceRoot()
        assumeTrue("Android resources unavailable", resources != null)
        val forbidden = '\u2014'
        val offenders = resources!!
            .walkTopDown()
            .filter { file ->
                file.isFile &&
                    file.extension == "xml" &&
                    file.parentFile?.name?.startsWith("values") == true
            }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (forbidden in line) {
                        "${file.relativeTo(resources).path}:${index + 1}"
                    } else {
                        null
                    }
                }
            }
            .toList()

        assertTrue(
            "User-visible Android resources contain em dashes: $offenders",
            offenders.isEmpty(),
        )
    }
}
