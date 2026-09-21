package com.noop.ui

import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Keeps the managed Friends surface translated without restoring legacy setup copy. */
class FriendsLocalizationContractTest {
    private fun root(): File = File(System.getProperty("user.dir") ?: ".")

    private fun first(vararg candidates: String): File? =
        candidates.map { File(root(), it) }.firstOrNull(File::isFile)

    private data class ResourceValue(
        val body: String,
        val placeholders: List<String>,
    )

    private fun resources(file: File): Map<String, ResourceValue> {
        val element = Regex(
            """<(string|plurals)\s+name="([^"]+)"[^>]*>(.*?)</\1>""",
            setOf(RegexOption.DOT_MATCHES_ALL),
        )
        val placeholder = Regex("""%(?:\d+\$)?[a-zA-Z]""")
        return element.findAll(file.readText()).associate { match ->
            "${match.groupValues[1]}:${match.groupValues[2]}" to ResourceValue(
                body = match.groupValues[3].trim(),
                placeholders = placeholder.findAll(match.groupValues[3])
                    .map { it.value }
                    .distinct()
                    .sorted()
                    .toList(),
            )
        }
    }

    @Test
    fun friendsResourcesHaveExactNineLocaleParity() {
        val expectedKeys = setOf(
            "string:friends_action_cancel",
            "string:friends_action_ok",
            "string:friends_display_name",
            "string:friends_title",
            "string:friends_working",
            "string:managed_friends_allow_audio_calls",
            "string:managed_friends_allow_messages",
            "string:managed_friends_allow_photos",
            "string:managed_friends_allow_video_calls",
            "string:managed_friends_communication_detail",
            "string:managed_friends_communication_permissions",
            "string:nav_friends",
        )
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
            first(
                "src/main/res/$folder/friends.xml",
                "app/src/main/res/$folder/friends.xml",
                "android/app/src/main/res/$folder/friends.xml",
            )
        }
        assumeTrue("Friends locale resources unavailable", files.values.all { it != null })

        val localized = files.mapValues { resources(it.value!!) }
        val base = localized.getValue("values")
        assertEquals("Managed Friends resource allowlist", expectedKeys, base.keys)
        for ((folder, values) in localized) {
            assertEquals("$folder Friends key parity", base.keys, values.keys)
            for (key in base.keys) {
                assertTrue("$folder has blank $key", values.getValue(key).body.isNotBlank())
                assertEquals(
                    "$folder placeholder parity for $key",
                    base.getValue(key).placeholders,
                    values.getValue(key).placeholders,
                )
            }
        }
    }

    @Test
    fun communicationRowsExposeOneMergedSwitchSemanticNode() {
        val source = first(
            "src/main/java/com/noop/ui/ManagedFriendsScreen.kt",
            "app/src/main/java/com/noop/ui/ManagedFriendsScreen.kt",
            "android/app/src/main/java/com/noop/ui/ManagedFriendsScreen.kt",
        )!!.readText()
        val start = source.indexOf("private fun ManagedToggleRow(")
        val end = source.indexOf("@OptIn(ExperimentalLayoutApi::class)", start)
        assertTrue("ManagedToggleRow source unavailable", start >= 0 && end > start)
        val row = source.substring(start, end)

        assertTrue(row.contains(".toggleable("))
        assertTrue(row.contains("role = Role.Switch"))
        assertTrue(row.contains(".semantics(mergeDescendants = true)"))
        assertTrue(row.contains("contentDescription = label"))
        assertTrue(row.contains("onCheckedChange = null"))
        assertFalse(row.contains("NoopToggleSwitch(checked = checked, onCheckedChange = onCheckedChange)"))
    }

    @Test
    fun deletionEligibilityFormattingUsesLocaleAndTimeZone() {
        val raw = "2026-09-21T01:30:00Z"
        val zone = ZoneId.of("America/Chicago")
        val locale = Locale.ITALIAN
        val expected = DateTimeFormatter
            .ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withLocale(locale)
            .withZone(zone)
            .format(Instant.parse(raw))

        val formatted = managedDeletionEligibilityTime(raw, zone, locale)
        assertEquals(expected, formatted)
        assertFalse(formatted.orEmpty().contains(raw))
        assertNull(managedDeletionEligibilityTime("not-an-instant", zone, locale))
    }
}
