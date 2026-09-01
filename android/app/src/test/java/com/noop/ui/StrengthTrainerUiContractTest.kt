package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Source and resource contracts for the production Strength Trainer. */
class StrengthTrainerUiContractTest {
    private fun source(relative: String): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/$relative"),
            File(root, "app/src/main/java/com/noop/ui/$relative"),
            File(root, "android/app/src/main/java/com/noop/ui/$relative"),
        ).firstOrNull(File::isFile)?.readText()
    }

    private fun resource(relative: String): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/res/$relative"),
            File(root, "app/src/main/res/$relative"),
            File(root, "android/app/src/main/res/$relative"),
        ).firstOrNull(File::isFile)
    }

    private fun strengthStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(strength_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }

    @Test
    fun workoutsEntryAndHonestManualContractStayMounted() {
        val workouts = source("WorkoutsScreen.kt")
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("Strength sources unavailable", workouts != null && trainer != null)

        assertTrue(workouts!!.contains("showStrengthTrainer = true"))
        assertTrue(workouts.contains("R.string.strength_title"))
        assertTrue(trainer!!.contains("R.string.strength_manual_authority_body"))
        assertTrue(trainer.contains("R.string.strength_numbers_meaning_body"))
        assertTrue(trainer.contains("containerColor = Palette.surfaceBase"))
        assertTrue(trainer.contains("SceneScreenBackground(maxAlpha = 0.82f)"))
        assertTrue(trainer.contains("Icons.Filled.Bedtime"))
        assertFalse(trainer.contains("Text(\""))
        assertFalse(trainer.contains("contentDescription = \""))
    }

    @Test
    fun editorCannotDismissBeforeAConfirmedSave() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)
        val text = trainer!!

        assertTrue(text.contains("target != SheetValue.Hidden"))
        assertTrue(
            text.contains(
                "if (editor == null && routineEditor == null && !customExerciseEditor) onDismiss()",
            ),
        )
        assertTrue(text.contains("if (persist() != null) onClose()"))
        assertTrue(text.contains("var pendingSave by remember"))
        assertTrue(text.contains("} while (pendingSave)"))
        assertTrue(text.contains("var blocks by remember(initial.session.id)"))
        assertTrue(text.contains("val completedAt = session.endedAt ?: now"))
    }

    @Test
    fun restTargetIsNormalizedAndAutosaved() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)
        val text = trainer!!

        assertTrue(text.contains("StrengthWorkoutPlanner.resolvedRestSeconds("))
        assertTrue(text.contains("continuesSuperset = continuesSuperset"))
        assertTrue(text.contains("first.restSeconds ?: prescription?.restSeconds ?: 120"))
        assertTrue(text.contains("restSeconds = block.restSeconds"))
        assertTrue(text.contains("sets = candidate.sets.map { it.copy(restSeconds = seconds) }"))
        assertTrue(text.contains("autosave()"))
    }

    @Test
    fun recentSessionTotalsExcludeWarmupSets() {
        val trainer = source("StrengthTrainerScreen.kt")
        assumeTrue("StrengthTrainerScreen.kt unavailable", trainer != null)

        assertTrue(
            Regex(
                """val completed = item\.sets\.filter\s*\{\s*"""
                    + """it\.completedAt != null && it\.setType != "warmup"\s*\}""",
            ).containsMatchIn(trainer!!),
        )
    }

    @Test
    fun strengthResourcesHaveExactNineLocaleParity() {
        val folders = listOf(
            "values",
            "values-de",
            "values-es",
            "values-fr",
            "values-it",
            "values-pt-rPT",
            "values-ru",
            "values-zh",
            "values-zh-rTW",
        )
        val files = folders.associateWith { resource("$it/strings.xml") }
        assumeTrue("Strength locale resources unavailable", files.values.all { it != null })
        val values = files.mapValues { strengthStrings(it.value!!) }
        val base = values.getValue("values")

        assertEquals(133, base.size)
        val placeholder = Regex("""%\d+\$[dsf]""")
        for ((folder, localized) in values) {
            assertEquals("$folder Strength key parity", base.keys, localized.keys)
            for (key in base.keys) {
                assertEquals(
                    "$folder placeholder parity for $key",
                    placeholder.findAll(base.getValue(key)).map { it.value }.sorted().toList(),
                    placeholder.findAll(localized.getValue(key)).map { it.value }.sorted().toList(),
                )
                assertTrue("$folder has blank $key", localized.getValue(key).isNotBlank())
            }
        }

        assertEquals("Schiena", values.getValue("values-it").getValue("strength_descriptor_back"))
        assertEquals("Подход %1\$d", values.getValue("values-ru").getValue("strength_set_number"))
        assertEquals("彈力帶", values.getValue("values-zh-rTW").getValue("strength_descriptor_band"))
    }
}
