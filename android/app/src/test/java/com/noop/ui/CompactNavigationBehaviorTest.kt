package com.noop.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompactNavigationBehaviorTest {
    @Test
    fun compactOverlayAddsScrollTailWithoutChangingTheViewport() {
        assertEquals(
            24.dp,
            navigationScrollTailPadding(base = 24.dp, overlayClearance = 0.dp),
        )
        assertEquals(
            24.dp + CompactNavigationOverlayFootprint,
            navigationScrollTailPadding(
                base = 24.dp,
                overlayClearance = CompactNavigationOverlayFootprint,
            ),
        )
        assertEquals(
            24.dp,
            navigationScrollTailPadding(base = 24.dp, overlayClearance = (-8).dp),
        )
    }

    @Test
    fun physicalEdgesPersistAcrossLayoutDirectionsAndDragPhysically() {
        assertEquals(
            CompactNavigationDockEdge.LEFT,
            compactNavigationDockEdgeFromStoredValue("LEFT", LayoutDirection.Ltr),
        )
        assertEquals(
            CompactNavigationDockEdge.LEFT,
            compactNavigationDockEdgeFromStoredValue("LEFT", LayoutDirection.Rtl),
        )
        assertEquals(
            CompactNavigationDockEdge.RIGHT,
            compactNavigationDockEdgeFromStoredValue("RIGHT", LayoutDirection.Ltr),
        )
        assertEquals(
            CompactNavigationDockEdge.RIGHT,
            compactNavigationDockEdgeFromStoredValue("RIGHT", LayoutDirection.Rtl),
        )

        // Legacy logical values migrate to whichever physical edge they represented at read time.
        assertEquals(
            CompactNavigationDockEdge.LEFT,
            compactNavigationDockEdgeFromStoredValue("START", LayoutDirection.Ltr),
        )
        assertEquals(
            CompactNavigationDockEdge.RIGHT,
            compactNavigationDockEdgeFromStoredValue("START", LayoutDirection.Rtl),
        )
        assertEquals(
            CompactNavigationDockEdge.RIGHT,
            compactNavigationDockEdgeFromStoredValue("END", LayoutDirection.Ltr),
        )
        assertEquals(
            CompactNavigationDockEdge.LEFT,
            compactNavigationDockEdgeFromStoredValue("END", LayoutDirection.Rtl),
        )

        assertEquals(
            CompactNavigationDockEdge.RIGHT,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.LEFT,
                horizontalDragPx = 48f,
                thresholdPx = 44f,
            ),
        )
        assertEquals(
            CompactNavigationDockEdge.LEFT,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.RIGHT,
                horizontalDragPx = -48f,
                thresholdPx = 44f,
            ),
        )
    }

    @Test
    fun hysteresisCountsOnlyConsumedVerticalTravel() {
        val initial = CompactNavigationHysteresisState(
            compact = false,
            directionalTravelPx = 0f,
        )
        val noMovement = updateCompactNavigationHysteresis(
            current = initial,
            consumed = Offset.Zero,
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertEquals(initial, noMovement)

        val first = updateCompactNavigationHysteresis(
            current = initial,
            consumed = Offset(0f, -40f),
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertFalse(first.compact)
        assertEquals(-40f, first.directionalTravelPx, 0.0001f)

        val collapsed = updateCompactNavigationHysteresis(
            current = first,
            consumed = Offset(0f, -35f),
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertTrue(collapsed.compact)
        assertEquals(0f, collapsed.directionalTravelPx, 0.0001f)

        val expanded = updateCompactNavigationHysteresis(
            current = collapsed,
            consumed = Offset(0f, 52f),
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertFalse(expanded.compact)
        assertEquals(0f, expanded.directionalTravelPx, 0.0001f)
    }

    @Test
    fun hysteresisResetsOnDirectionChangeAndIgnoresHorizontalTravel() {
        val upward = CompactNavigationHysteresisState(
            compact = false,
            directionalTravelPx = -40f,
        )
        val reversed = updateCompactNavigationHysteresis(
            current = upward,
            consumed = Offset(0f, 12f),
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertEquals(12f, reversed.directionalTravelPx, 0.0001f)

        val horizontal = updateCompactNavigationHysteresis(
            current = reversed,
            consumed = Offset(100f, -40f),
            source = NestedScrollSource.UserInput,
            compactThresholdPx = 72f,
            expandThresholdPx = 52f,
        )
        assertEquals(reversed, horizontal)
    }

    @Test
    fun primaryRouteChangeExpandsNavigationAndClearsTravel() {
        val compact = CompactNavigationHysteresisState(
            compact = true,
            directionalTravelPx = -24f,
        )
        assertEquals(
            CompactNavigationHysteresisState(
                compact = false,
                directionalTravelPx = 0f,
            ),
            compactNavigationStateAfterPrimaryRouteChange(
                current = compact,
                selectedTabRoute = "more",
                revealedPrimaryTabRoute = "today",
            ),
        )
        assertEquals(
            compact,
            compactNavigationStateAfterPrimaryRouteChange(
                current = compact,
                selectedTabRoute = "today",
                revealedPrimaryTabRoute = "today",
            ),
        )
    }
}
