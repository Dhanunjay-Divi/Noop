package com.noop.widget

import com.noop.ui.BlackTokens
import com.noop.ui.DarkTokens
import com.noop.ui.LightTokens
import org.junit.Assert.assertEquals
import org.junit.Test

class NoopWidgetStyleTest {
    @Test
    fun explicitAppearanceAlwaysWinsOverSystem() {
        assertEquals(NoopWidgetAppearance.LIGHT, resolveNoopWidgetAppearance("light"))
        assertEquals(NoopWidgetAppearance.DARK, resolveNoopWidgetAppearance("dark"))
        assertEquals(NoopWidgetAppearance.BLACK, resolveNoopWidgetAppearance("black"))
    }

    @Test
    fun systemAndUnknownValuesRemainAdaptive() {
        assertEquals(NoopWidgetAppearance.SYSTEM, resolveNoopWidgetAppearance("system"))
        assertEquals(NoopWidgetAppearance.SYSTEM, resolveNoopWidgetAppearance("future-mode"))
        assertEquals(NoopWidgetAppearance.SYSTEM, resolveNoopWidgetAppearance(null))
    }

    @Test
    fun systemWidgetCarriesBothDayAndNightTokensWhileExplicitModesStayFixed() {
        val system = noopWidgetTokenPair(NoopWidgetAppearance.SYSTEM)
        assertEquals(LightTokens, system.day)
        assertEquals(DarkTokens, system.night)

        val black = noopWidgetTokenPair(NoopWidgetAppearance.BLACK)
        assertEquals(BlackTokens, black.day)
        assertEquals(BlackTokens, black.night)

        assertEquals(LightTokens.surfaceBase, noopWidgetColorValues(NoopWidgetAppearance.SYSTEM, false).surface)
        assertEquals(DarkTokens.surfaceBase, noopWidgetColorValues(NoopWidgetAppearance.SYSTEM, true).surface)
    }

    @Test
    fun onlyASystemFollowingNightModeFlipRequestsARefresh() {
        assertEquals(true, shouldRefreshSystemWidgetsForNightMode(false, true, followsSystem = true))
        assertEquals(true, shouldRefreshSystemWidgetsForNightMode(true, false, followsSystem = true))
        assertEquals(false, shouldRefreshSystemWidgetsForNightMode(false, false, followsSystem = true))
        assertEquals(false, shouldRefreshSystemWidgetsForNightMode(false, true, followsSystem = false))
        assertEquals(false, shouldRefreshSystemWidgetsForNightMode(null, true, followsSystem = true))
    }

    @Test
    fun widgetColorsAreSourcedFromTheSameAppearanceAndSemanticTokensAsTheApp() {
        val light = noopWidgetColorValues(NoopWidgetAppearance.LIGHT)
        assertEquals(LightTokens.surfaceBase, light.surface)
        assertEquals(LightTokens.statusPositive, light.positive)
        assertEquals(LightTokens.restColor, light.sleep)
        assertEquals(LightTokens.effortColor, light.effort)

        val dark = noopWidgetColorValues(NoopWidgetAppearance.DARK)
        assertEquals(DarkTokens.surfaceBase, dark.surface)
        assertEquals(DarkTokens.statusCritical, dark.critical)

        val black = noopWidgetColorValues(NoopWidgetAppearance.BLACK)
        assertEquals(BlackTokens.surfaceBase, black.surface)
        assertEquals(BlackTokens.hairline, black.hairline)
        assertEquals(BlackTokens.statusWarning, black.warning)
    }
}
