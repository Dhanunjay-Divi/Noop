package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.Locale
import java.util.TimeZone

class HydrationAccessibilityContractTest {
    private val englishCopy = HydrationAccessibilityCopy(
        litresFormat = "%1\$s litres",
        statusFormat = "%1\$s. %2\$s. %3\$s",
        missingWithGoalFormat = "%1\$s. %2\$s. Goal %3\$s.",
        progressFormat = "%1\$s. Logged: %2\$s. Goal: %3\$s. %4\$d percent of goal.",
        historyFormat = "%1\$s. %2\$s.",
        historyDayFormat = "%1\$s: %2\$s",
    )

    private val germanCopy = HydrationAccessibilityCopy(
        litresFormat = "%1\$s Liter",
        statusFormat = "%1\$s. %2\$s. %3\$s",
        missingWithGoalFormat = "%1\$s. %2\$s. Ziel: %3\$s.",
        progressFormat = "%1\$s. Erfasst: %2\$s. Ziel: %3\$s. %4\$d Prozent des Ziels.",
        historyFormat = "%1\$s. %2\$s.",
        historyDayFormat = "%1\$s: %2\$s",
    )

    @Test
    fun heroDescriptionIncludesStateGoalAndProgress() {
        assertEquals(
            "Hydration today. Unavailable. Goal 3.2 litres.",
            hydrationHeroDescription(
                totalMl = null,
                goalMl = 3_200,
                missingText = "Unavailable",
                targetUnavailableText = "Confirm your adult profile.",
                dayDescription = "Hydration today",
                locale = Locale.US,
                copy = englishCopy,
            ),
        )
        assertEquals(
            "Hydration today. Logged: 1.2 litres. Goal: 3.2 litres. 37 percent of goal.",
            hydrationHeroDescription(
                totalMl = 1_200.0,
                goalMl = 3_200,
                missingText = "Not logged",
                targetUnavailableText = "Confirm your adult profile.",
                dayDescription = "Hydration today",
                locale = Locale.US,
                copy = englishCopy,
            ),
        )
        assertEquals(
            "Hydration today. 1.2 litres. Confirm your adult profile.",
            hydrationHeroDescription(
                totalMl = 1_200.0,
                goalMl = null,
                missingText = "Not logged",
                targetUnavailableText = "Confirm your adult profile.",
                dayDescription = "Hydration today",
                locale = Locale.US,
                copy = englishCopy,
            ),
        )
    }

    @Test
    fun descriptionsUseLocaleDecimalAndWeekdayFormatting() {
        assertEquals(
            "1,3 Liter",
            hydrationLitresText(1_250.0, Locale.GERMANY, germanCopy.litresFormat),
        )
        val description = hydrationHistoryDescription(
            history = listOf(
                "2026-09-07" to null,
                "2026-09-08" to 1_250.0,
            ),
            missingText = "Nicht protokolliert",
            title = "Letzte 7 Tage",
            locale = Locale.GERMANY,
            copy = germanCopy,
        )

        assertTrue(description.contains("Montag: Nicht protokolliert"))
        assertTrue(description.contains("Dienstag: 1,3 Liter"))
        assertEquals("一", hydrationWeekdayLabel("2026-09-07", Locale.SIMPLIFIED_CHINESE))
        assertNotEquals("M", hydrationWeekdayLabel("2026-09-07", Locale.SIMPLIFIED_CHINESE))
    }

    @Test
    fun entryTimeUsesTheUsersShortClockFormat() {
        assertEquals(
            "4:00 PM",
            hydrationEntryTime(57_600L, Locale.US, TimeZone.getTimeZone("UTC")),
        )
    }

    @Test
    fun hydrationResourcesHaveExactNineLocaleParity() {
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
        val files = folders.associateWith { folder ->
            firstResource("src/main/res/$folder/hydration_screen.xml")
        }
        assumeTrue("Hydration locale resources unavailable", files.values.all { it != null })

        val values = files.mapValues { hydrationStrings(it.value!!) }
        val base = values.getValue("values")
        val placeholder = Regex("""%\d+\$[sd]""")
        for ((folder, localized) in values) {
            assertEquals("$folder hydration key parity", base.keys, localized.keys)
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
    fun hydrationSourceDoesNotReintroduceEnglishOrUsSpecificSemantics() {
        val source = firstResource("src/main/java/com/noop/ui/HydrationScreen.kt")
        assumeTrue("HydrationScreen.kt unavailable", source != null)
        val text = source!!.readText()

        assertFalse(text.contains("Locale.US"))
        assertFalse(text.contains("Overline(\"Last 7 days\")"))
        assertFalse(text.contains("onClickLabel = \"Log"))
        assertFalse(text.contains("\"of %.1f L\""))
    }

    private fun firstResource(relative: String): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, relative),
            File(root, "app/$relative"),
            File(root, "android/app/$relative"),
        ).firstOrNull(File::isFile)
    }

    private fun hydrationStrings(file: File): Map<String, String> {
        val pattern = Regex(
            """<string\s+name="(hydration_screen_[^"]+)"[^>]*>(.*?)</string>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        return pattern.findAll(file.readText()).associate {
            it.groupValues[1] to it.groupValues[2].trim()
        }
    }
}
