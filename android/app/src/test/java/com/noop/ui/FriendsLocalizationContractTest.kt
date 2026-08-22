package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Keeps the complete Friends privacy and invitation surface translated as one contract. */
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
        assertTrue("Friends resource set unexpectedly small", base.size >= 90)
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
}
