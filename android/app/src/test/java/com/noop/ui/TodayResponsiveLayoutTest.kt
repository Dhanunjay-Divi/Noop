package com.noop.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TodayResponsiveLayoutTest {
    @Test
    fun compactGeometryRequiresPhoneWidthAndOrdinaryText() {
        assertTrue(todayUsesCompactLayout(screenWidthDp = 360, fontScale = 1.0f))
        assertTrue(todayUsesCompactLayout(screenWidthDp = 599, fontScale = 1.30f))
        assertFalse(todayUsesCompactLayout(screenWidthDp = 600, fontScale = 1.0f))
        assertFalse(todayUsesCompactLayout(screenWidthDp = 360, fontScale = 1.31f))
    }

    @Test
    fun weatherKeepsTemperatureButDropsPlaceholderTextAtLargeScale() {
        assertTrue(todayWeatherShowsVisualText(hasSnapshot = false, fontScale = 1.30f))
        assertFalse(todayWeatherShowsVisualText(hasSnapshot = false, fontScale = 1.31f))
        assertTrue(todayWeatherShowsVisualText(hasSnapshot = true, fontScale = 2.0f))

        val today = source("com/noop/ui/TodayScreen.kt")
        val block = today.substring(
            today.indexOf("private fun TodayWeatherChip("),
            today.indexOf("@Composable\nprivate fun TodayWeatherDetailsDialog("),
        )
        assertTrue(block.contains(".sizeIn(minWidth = 48.dp, minHeight = 48.dp)"))
        assertTrue(block.contains("val expandForLargeText = snapshot != null && fontScale > 1.30f"))
        assertTrue(block.contains(".widthIn(min = 82.dp)"))
        assertTrue(block.contains(".heightIn(min = 34.dp)"))
    }

    @Test
    fun stackedDailySignalHeaderDoesNotForceIdentityAndStatusIntoOneRow() {
        val today = source("com/noop/ui/TodayScreen.kt")
        val start = today.indexOf("private fun DailySignalHeader(")
        val end = today.indexOf(
            "@Composable\nprivate fun DailySignalSourceBadgeLive(",
            startIndex = start,
        )
        val block = today.substring(start, end)
        val fallback = block.substring(block.indexOf("} else {"))

        assertTrue(fallback.contains("DailySignalIdentity(status = status, tint = tint)"))
        assertTrue(fallback.contains("modifier = Modifier.align(Alignment.End)"))
        assertFalse(fallback.contains("Row("))
    }

    private fun source(relative: String): String {
        val userDir = checkNotNull(System.getProperty("user.dir"))
        return listOf(
            File(userDir, "src/main/java/$relative"),
            File(userDir, "app/src/main/java/$relative"),
            File(userDir, "android/app/src/main/java/$relative"),
        ).firstOrNull(File::isFile)?.readText()
            ?: error("Could not locate $relative from $userDir")
    }
}
