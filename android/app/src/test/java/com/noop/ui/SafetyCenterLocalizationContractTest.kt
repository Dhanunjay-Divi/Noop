package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source/resource contract for Safety Center localization and TalkBack semantics. */
class SafetyCenterLocalizationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun first(vararg candidates: String): File? =
        candidates.map { File(root(), it) }.firstOrNull(File::isFile)

    private fun safetyStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(safety_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    @Test
    fun safetyResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        )
        val files = folders.associateWith { folder ->
            first(
                "src/main/res/$folder/safety.xml",
                "app/src/main/res/$folder/safety.xml",
                "android/app/src/main/res/$folder/safety.xml",
            )
        }
        assumeTrue("Safety locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { safetyStrings(it.value!!) }
        val base = values.getValue("values")
        assertEquals(198, base.size)

        val placeholder = Regex("""%\d+\$[ds]""")
        for ((folder, localized) in values) {
            assertEquals("$folder Safety key parity", base.keys, localized.keys)
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

    @Test
    fun safetyScreenUsesResourcesAndCompleteTalkBackLabels() {
        val screen = first(
            "src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
            "android/app/src/main/java/com/noop/ui/SafetyCenterScreen.kt",
        )
        val components = first(
            "src/main/java/com/noop/ui/Components.kt",
            "app/src/main/java/com/noop/ui/Components.kt",
            "android/app/src/main/java/com/noop/ui/Components.kt",
        )
        assumeTrue("Safety sources unavailable", screen != null && components != null)

        val safety = screen!!.readText()
        val shared = components!!.readText()
        assertTrue(safety.contains("copy = safetyShareCopy"))
        assertTrue(safety.contains("accessibilityLabel = {"))
        assertTrue(safety.contains("role = Role.Switch"))
        assertTrue(safety.contains("semantics(mergeDescendants = true)"))
        assertFalse(safety.contains("title = \"Safety\""))
        assertFalse(safety.contains("Text(\"If danger is immediate\")"))
        assertTrue(shared.contains("accessibilityLabel: (T) -> String = label"))
        assertTrue(shared.contains("contentDescription = accessibilityLabel(item)"))
    }
}
