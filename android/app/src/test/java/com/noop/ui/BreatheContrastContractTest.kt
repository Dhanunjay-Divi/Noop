package com.noop.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BreatheContrastContractTest {
    @Test
    fun stopSessionUsesTheSemanticContrastResolver() {
        val source = source().readText()
        val controls = source
            .substringAfter("// Controls.")
            .substringBefore("// Calm one-line outcome")

        assertTrue(
            controls.contains(
                "contentColor = if (running) {\n" +
                    "                        contrastInk(Palette.statusCritical)",
            ),
        )
    }

    @Test
    fun destructiveFillInkMeetsLabelContrastInEveryDarkAppearance() {
        listOf(
            DarkTokens.statusCritical,
            BlackTokens.statusCritical,
            ClassicDark.statusCritical,
        ).forEach { criticalFill ->
            val ink = contrastInk(criticalFill)
            assertEquals(Color.Black, ink)
            assertTrue(
                contrastRatio(ink, criticalFill) >= 4.5,
            )
        }
    }

    private fun contrastRatio(first: Color, second: Color): Double {
        val lighter = maxOf(first.luminance(), second.luminance())
        val darker = minOf(first.luminance(), second.luminance())
        return (lighter + 0.05) / (darker + 0.05)
    }

    private fun source(): File {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/com/noop/ui/BreatheScreen.kt"),
            File(userDir, "app/src/main/java/com/noop/ui/BreatheScreen.kt"),
            File(userDir, "android/app/src/main/java/com/noop/ui/BreatheScreen.kt"),
        ).firstOrNull(File::isFile)
            ?: error("Could not locate BreatheScreen.kt from $userDir")
    }
}
