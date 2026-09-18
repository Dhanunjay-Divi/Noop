package com.noop.ui

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class BrandLocalizationContractTest {
    private val repoRoot: Path by lazy {
        sequenceOf(Paths.get("."), Paths.get(".."), Paths.get("../.."))
            .map { it.toAbsolutePath().normalize() }
            .first {
                Files.exists(
                    it.resolve(
                        "android/app/src/main/res/values/brand_localization.xml",
                    ),
                )
            }
    }

    @Test
    fun allShippingLocalesContainTheBrandStatusResource() {
        val localeDirectories = listOf(
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

        val localizedValues = localeDirectories.associateWith { directory ->
            val path = repoRoot.resolve(
                "android/app/src/main/res/$directory/brand_localization.xml",
            )
            val document = DocumentBuilderFactory.newInstance()
                .newDocumentBuilder()
                .parse(path.toFile())
            val strings = document.getElementsByTagName("string")
            val values = (0 until strings.length).associate { index ->
                val node = strings.item(index)
                node.attributes.getNamedItem("name").nodeValue to node.textContent
            }

            assertTrue(
                values.getValue("brand_band_accepted_all_r22_flags").isNotBlank(),
                "$directory must provide the localized R22 completion status",
            )
            values.getValue("brand_band_accepted_all_r22_flags")
        }

        val english = localizedValues.getValue("values")
        localeDirectories.drop(1).forEach { directory ->
            assertNotEquals(
                english,
                localizedValues.getValue(directory),
                "$directory must not copy the English fallback",
            )
        }
    }

    @Test
    fun settingsUsesTheResourceInsteadOfEnglishInlineCopy() {
        val source = Files.readString(
            repoRoot.resolve(
                "android/app/src/main/java/com/noop/ui/SettingsScreen.kt",
            ),
        )

        assertTrue(
            source.contains(
                "stringResource(R.string.brand_band_accepted_all_r22_flags)",
            ),
        )
        assertFalse(source.contains("\"✓ Noop Band accepted all 15 R22 flags\""))
        assertEquals(
            1,
            Regex("brand_band_accepted_all_r22_flags").findAll(source).count(),
        )
    }
}
