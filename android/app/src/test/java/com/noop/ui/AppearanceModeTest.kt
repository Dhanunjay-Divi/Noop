package com.noop.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AppearanceModeTest {
    @Test
    fun storageRoundTripsEverySupportedModeAndFallsBackSafely() {
        AppearanceMode.entries.forEach { mode ->
            assertEquals(mode, AppearanceMode.fromStorage(mode.storageValue))
        }
        assertEquals(AppearanceMode.SYSTEM, AppearanceMode.fromStorage(null))
        assertEquals(AppearanceMode.SYSTEM, AppearanceMode.fromStorage("future-mode"))
    }

    @Test
    fun resolverKeepsSystemDarkDistinctFromExplicitBlack() {
        assertSame(LightTokens, appearanceTokens(AppearanceMode.SYSTEM, systemDark = false))
        assertSame(DarkTokens, appearanceTokens(AppearanceMode.SYSTEM, systemDark = true))
        assertSame(BlackTokens, appearanceTokens(AppearanceMode.BLACK, systemDark = false))
        assertSame(BlackTokens, appearanceTokens(AppearanceMode.BLACK, systemDark = true))
    }

    @Test
    fun blackUsesTrueBlackChromeWithoutChangingHealthSemantics() {
        assertEquals(Color(0xFF000000), BlackTokens.surfaceBase)
        assertNotEquals(DarkTokens.surfaceBase, BlackTokens.surfaceBase)
        assertNotEquals(BlackTokens.surfaceBase, BlackTokens.surfaceRaised)
        assertEquals(DarkTokens.recovery100, BlackTokens.recovery100)
        assertEquals(DarkTokens.strain100, BlackTokens.strain100)
        assertEquals(DarkTokens.sleepDeep, BlackTokens.sleepDeep)
    }

    @Test
    fun titaniumTokensMatchTheCanonicalCrossPlatformPalette() {
        assertEquals(Color(0xFF111111), LightTokens.accent)
        assertEquals(Color(0xFFFFFFFF), LightTokens.accentInk)
        assertEquals(Color(0xFFF7F7F5), DarkTokens.accent)
        assertEquals(Color(0xFF070707), DarkTokens.accentInk)
        assertEquals(Color(0xFFC0392B), LightTokens.recovery000)
        assertEquals(Color(0xFF0F9D62), LightTokens.recovery100)
        assertEquals(Color(0xFFC13EC1), LightTokens.sleepDeep)
        assertEquals(Color(0xFFFD96FD), DarkTokens.sleepDeep)
        assertEquals(Color(0xFF0F9D62), LightTokens.chargeColor)
        assertEquals(Color(0xFF2A78C8), LightTokens.effortColor)
        assertEquals(Color(0xFF5E7896), LightTokens.restColor)
        assertEquals(Color(0xFFC7891A), LightTokens.stressColor)
    }

    @Test
    fun moderateRecoveryGaugeCannotDriftIntoPrimedGreen() {
        val (base, tip) = Palette.recoveryGaugeColors(69.0)
        assertEquals(Palette.recoveryColor(55.0), base)
        assertEquals(Palette.signalYellow, tip)
        assertEquals(listOf(0.0f to base, 1.0f to tip), Palette.recoveryGaugeStops(69.0))
    }

    @Test
    fun semanticStatusTextMatchesAppleAndMeetsPearlContrast() {
        assertEquals(Color(0xFF19734A), LightTokens.statusPositiveText)
        assertEquals(Color(0xFF895900), LightTokens.statusWarningText)
        assertEquals(Color(0xFFA83D21), LightTokens.statusCriticalText)
        assertEquals(Color(0xFFB33A2F), ClassicLight.statusCriticalText)

        listOf(
            LightTokens.statusPositiveText,
            LightTokens.statusWarningText,
            LightTokens.statusCriticalText,
            ClassicLight.statusPositiveText,
            ClassicLight.statusWarningText,
            ClassicLight.statusCriticalText,
        ).forEach { foreground ->
            assertTrue(
                "${foreground} must clear 4.5:1 on Pearl raised cards",
                contrastRatio(foreground, LightTokens.surfaceRaised) >= 4.5,
            )
        }

        // Graphic/gauge status colours stay bright, while Graphite/OLED retain their established ink.
        assertEquals(Color(0xFF1F8A5B), LightTokens.statusPositive)
        assertEquals(Color(0xFFC2792E), LightTokens.statusWarning)
        assertEquals(Color(0xFFC84E1E), LightTokens.statusCritical)
        assertEquals(DarkTokens.statusPositive, DarkTokens.statusPositiveText)
        assertEquals(DarkTokens.statusWarning, DarkTokens.statusWarningText)
        assertEquals(DarkTokens.statusCritical, DarkTokens.statusCriticalText)
        assertEquals(BlackTokens.statusPositive, BlackTokens.statusPositiveText)
    }

    @Test
    fun systemDoesNotDoubleSelectAnExplicitPreview() {
        AppearanceMode.entries.filter { it != AppearanceMode.SYSTEM }.forEach { preview ->
            assertFalse(isAppearancePreviewSelected(AppearanceMode.SYSTEM, preview))
        }
        assertTrue(isAppearancePreviewSelected(AppearanceMode.BLACK, AppearanceMode.BLACK))
        assertFalse(isAppearancePreviewSelected(AppearanceMode.DARK, AppearanceMode.BLACK))
    }

    @Test
    fun everyAppearanceHasLocalizedLabelAndDetailResources() {
        AppearanceMode.entries.forEach { mode ->
            assertNotEquals(0, mode.labelRes)
            assertNotEquals(0, mode.detailRes)
        }
    }

    @Test
    fun segmentedControlKeepsCompactChromeButAccessibleTouchTargets() {
        assertTrue(SegmentedControlTouchTarget >= 48.dp)
        assertTrue(SegmentedControlVisualHeight < SegmentedControlTouchTarget)
    }

    @Test
    fun appearancePreviewUsesTheCandidateThemesOwnAccent() {
        assertEquals(LightTokens.accent, themeSwatchAccent(LightTokens))
        assertEquals(DarkTokens.accent, themeSwatchAccent(DarkTokens))
        assertEquals(BlackTokens.accent, themeSwatchAccent(BlackTokens))
        assertNotEquals(themeSwatchAccent(LightTokens), themeSwatchAccent(DarkTokens))
    }

    private fun contrastRatio(first: Color, second: Color): Double {
        val a = relativeLuminance(first)
        val b = relativeLuminance(second)
        return (maxOf(a, b) + 0.05) / (minOf(a, b) + 0.05)
    }

    private fun relativeLuminance(color: Color): Double {
        fun linear(component: Float): Double {
            val value = component.toDouble()
            return if (value <= 0.04045) value / 12.92
            else Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}
