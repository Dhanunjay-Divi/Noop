package com.noop.ui

import java.io.File
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
        assertEquals(136, base.size)
        assertEquals("NOOP Band is coming", base["appwide_terms_title"])
        assertTrue(
            base.getValue("appwide_terms_subtitle")
                .contains("compatible WHOOP band you own"),
        )
        assertEquals(
            "Recovery scores: %1\$d of %2\$d days. One score per day is used in the average.",
            base["appwide_trends_recovery_coverage_format"],
        )
        assertTrue(
            base.getValue("appwide_trends_recovery_descriptor")
                .contains("overnight HRV"),
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
