package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source/resource contract for Nutrition localization, TalkBack semantics, and tab-bar clearance. */
class NutritionLocalizationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun first(vararg candidates: String): File? =
        candidates.map { File(root(), it) }.firstOrNull(File::isFile)

    private fun nutritionStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(nutrition_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    @Test
    fun nutritionResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values", "values-de", "values-es", "values-fr", "values-it",
            "values-pt-rPT", "values-ru", "values-zh", "values-zh-rTW",
        )
        val files = folders.associateWith { folder ->
            first(
                "src/main/res/$folder/nutrition.xml",
                "app/src/main/res/$folder/nutrition.xml",
                "android/app/src/main/res/$folder/nutrition.xml",
            )
        }
        assumeTrue("Nutrition locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { nutritionStrings(it.value!!) }
        val base = values.getValue("values")
        assertEquals(99, base.size)

        val placeholder = Regex("""%\d+\$[ds]""")
        for ((folder, localized) in values) {
            assertEquals("$folder Nutrition key parity", base.keys, localized.keys)
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
    fun nutritionScreenUsesResourcesAndCompleteTalkBackSemantics() {
        val screen = first(
            "src/main/java/com/noop/ui/NutritionLogScreen.kt",
            "app/src/main/java/com/noop/ui/NutritionLogScreen.kt",
            "android/app/src/main/java/com/noop/ui/NutritionLogScreen.kt",
        )
        assumeTrue("Nutrition source unavailable", screen != null)
        val text = screen!!.readText()

        assertTrue(text.contains("R.string.nutrition_title"))
        assertTrue(text.contains("R.string.nutrition_entries_saved_title"))
        assertTrue(text.contains("semantics(mergeDescendants = true)"))
        assertTrue(text.contains("R.string.nutrition_repeat_action_format"))
        assertTrue(text.contains("userFacingNutritionMessage(context: Context)"))
        assertFalse(text.contains("title = \"Nutrition\""))
        assertFalse(text.contains("Text(\"Imported total prevents double counting\")"))
        assertFalse(text.contains("Recent manual meals only. You can edit the new entry afterward."))
    }
}
