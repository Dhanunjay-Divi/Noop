package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Pins the daily navigation hierarchy shared with the Apple shell. */
class PrimaryNavigationContractTest {
    private fun appRootSource(): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/AppRoot.kt"),
            File(root, "app/src/main/java/com/noop/ui/AppRoot.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/AppRoot.kt"),
        ).firstOrNull(File::isFile)?.readText()
    }

    @Test
    fun localizedLabelWidthsChooseStableSingleLineFit() {
        val englishLabels = listOf("Today", "Trends", "Workouts", "Sleep", "More")
        val englishWidths = mapOf(
            "Today" to 28,
            "Trends" to 34,
            "Workouts" to 44,
            "Sleep" to 29,
            "More" to 25,
        )
        assertEquals(
            BottomBarLabelLayout(
                maxLines = 1,
                barHeightDp = 56,
                labelScaleMultiplier = 1f,
            ),
            bottomBarLabelLayout(
                labels = englishLabels,
                fontScale = 1.0f,
                availableWidthPx = 300,
                horizontalContentPaddingPx = 6,
                interItemSpacingPx = 1,
                labelHorizontalSafetyPaddingPx = 1,
                measureLabelWidthPx = { label, multiplier ->
                    (englishWidths.getValue(label) * multiplier).toInt()
                },
            ),
        )

        val shippedLocalizedLabels = listOf(
            listOf("Aujourd'hui", "Tendances", "Entraînements", "Sommeil", "Plus") to
                mapOf(
                    "Aujourd'hui" to 58,
                    "Tendances" to 49,
                    "Entraînements" to 76,
                    "Sommeil" to 42,
                    "Plus" to 23,
                ),
            listOf("Hoy", "Tendencias", "Entrenamientos", "Sueño", "Más") to
                mapOf(
                    "Hoy" to 19,
                    "Tendencias" to 52,
                    "Entrenamientos" to 78,
                    "Sueño" to 31,
                    "Más" to 22,
                ),
        )
        shippedLocalizedLabels.forEach { (labels, widths) ->
            val layout = bottomBarLabelLayout(
                labels = labels,
                fontScale = 1.0f,
                availableWidthPx = 300,
                horizontalContentPaddingPx = 6,
                interItemSpacingPx = 1,
                labelHorizontalSafetyPaddingPx = 1,
                measureLabelWidthPx = { label, multiplier ->
                    (widths.getValue(label) * multiplier).toInt()
                },
            )
            val widestWidth = widths.values.max().toFloat()
            assertEquals(1, layout.maxLines)
            assertEquals(56, layout.barHeightDp)
            assertEquals(
                1f * (54.8f / widestWidth) * 0.98f,
                layout.labelScaleMultiplier,
                0.0001f,
            )
            assertTrue(layout.labelScaleMultiplier > BottomBarLabelEffectiveScaleFloor)
            assertTrue(widestWidth * layout.labelScaleMultiplier <= 54.8f)
        }
    }

    @Test
    fun accessibilityTextKeepsVisibleLabelsWithCappedNavigationScale() {
        val labels = listOf("Heute", "Trends", "Workouts", "Schlaf", "Mehr")
        val accessibilityText = bottomBarLabelLayout(
            labels = labels,
            fontScale = 3f,
            availableWidthPx = 600,
            horizontalContentPaddingPx = 6,
            interItemSpacingPx = 1,
            labelHorizontalSafetyPaddingPx = 1,
            measureLabelWidthPx = { _, multiplier ->
                (60 * multiplier * 3f).toInt()
            },
        )
        assertEquals(1, accessibilityText.maxLines)
        assertEquals(56, accessibilityText.barHeightDp)
        assertTrue(
            accessibilityText.labelScaleMultiplier * 3f <=
                BottomBarLabelFontScaleCap,
        )
        assertTrue(
            accessibilityText.labelScaleMultiplier * 3f >=
                BottomBarLabelEffectiveScaleFloor,
        )

        val unusuallyLongLabels = bottomBarLabelLayout(
            labels = labels,
            fontScale = 1f,
            availableWidthPx = 300,
            horizontalContentPaddingPx = 6,
            interItemSpacingPx = 1,
            labelHorizontalSafetyPaddingPx = 1,
            measureLabelWidthPx = { _, multiplier ->
                (140 * multiplier).toInt()
            },
        )
        assertEquals(1, unusuallyLongLabels.maxLines)
        assertEquals(56, unusuallyLongLabels.barHeightDp)
        assertTrue(unusuallyLongLabels.labelScaleMultiplier < 1f)
        assertEquals(
            BottomBarLabelEffectiveScaleFloor,
            unusuallyLongLabels.labelScaleMultiplier,
            0.0001f,
        )

        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!
        assertTrue(text.contains("rememberTextMeasurer(cacheSize = labels.size.coerceAtLeast(1))"))
        assertTrue(text.contains("availableWidth = maxWidth"))
        assertFalse(text.contains("@Suppress(\"UNUSED_PARAMETER\")"))
        val barSlot = text
            .substringAfter("private fun BarSlot(")
            .substringBefore("\n}\n\nprivate enum class QuickActionKind")

        assertTrue(barSlot.contains("contentDescription = label"))
        assertTrue(barSlot.contains(".selectable("))
        assertTrue(barSlot.contains("selected = active"))
        assertTrue(barSlot.contains("role = Role.Tab"))
        assertTrue(barSlot.contains("minLines = labelMaxLines"))
        assertTrue(barSlot.contains("maxLines = labelMaxLines"))
        assertTrue(barSlot.contains("softWrap = false"))
        assertTrue(barSlot.contains("overflow = TextOverflow.Ellipsis"))
        assertTrue(barSlot.contains("fontSize = (10f * labelScaleMultiplier).sp"))
        assertFalse(barSlot.contains("overflow = TextOverflow.Clip"))
        assertFalse(barSlot.contains("showVisualLabel"))

        val bottomBar = text
            .substringAfter("private fun GlassBottomBar(")
            .substringBefore("\n@Composable\nprivate fun FloatingQuickAddButton")
        assertTrue(bottomBar.contains(".selectableGroup()"))
        assertTrue(bottomBar.contains(".height(labelLayout.barHeightDp.dp)"))
        assertTrue(bottomBar.contains(
            "labelScaleMultiplier = labelLayout.labelScaleMultiplier",
        ))
        assertFalse(bottomBar.contains("showVisualLabel"))
        assertTrue(text.contains("BottomBarSingleLineHeightDp = 56"))
        assertFalse(text.contains("BottomBarTwoLineHeightDp"))
        assertTrue(text.contains("CompactBottomBarWidthDp = 360"))
        assertTrue(bottomBar.contains(
            "val outerHorizontalPadding = if (compactNavigation) 8.dp else 12.dp",
        ))
        assertTrue(bottomBar.contains(
            "val quickActionSpacing = if (compactNavigation) 4.dp else 8.dp",
        ))
        assertTrue(bottomBar.contains(
            "val barContentPadding = if (compactNavigation) 4.dp else 6.dp",
        ))
    }

    @Test
    fun workoutsStayPrimaryAndMoreDoesNotClaimTheirSelection() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains(
            "BarTab(Destination.Workouts, Icons.AutoMirrored.Filled.DirectionsRun, R.string.nav_workouts)"
        ))
        assertTrue(text.contains("active = selected == Destination.More"))
        assertFalse(text.contains(
            "Destination.Live, Destination.Workouts, Destination.Nutrition"
        ))
        assertTrue(text.contains(
            "composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }"
        ))
    }

    @Test
    fun privateFriendsIsReachableFromTheCompleteIndex() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains(
            "Friends(\"friends\", R.string.nav_friends, Icons.Filled.People)"
        ))
        assertTrue(text.contains(
            "Destination.Profile, Destination.BandAccount, Destination.Friends, Destination.Devices"
        ))
        assertTrue(text.contains(
            "BandAccount(\"band_account\", R.string.ownership_screen_title, Icons.Filled.Badge)"
        ))
        assertTrue(text.contains(
            "composable(Destination.BandAccount.route) { OwnershipAccountScreen() }"
        ))
        assertTrue(text.contains("composable(Destination.Friends.route)"))
        assertTrue(text.contains("FriendsScreen("))
    }

    @Test
    fun noopPlusIsAlwaysDiscoverableAndHasItsOwnRoute() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains(
            "NoopPlus(\"noop_plus\", R.string.managed_cloud_brand, Icons.Filled.Cloud)"
        ))
        assertTrue(text.contains("Destination.NoopPlus, Destination.BackupSync"))
        assertTrue(text.contains("NoopPlusEntry(onNavigate = onNavigate)"))
        assertTrue(text.contains(
            "composable(Destination.NoopPlus.route) { NoopPlusScreen() }"
        ))
    }

    @Test
    fun nestedDetailsKeepTheirTabOwnerAndReselectPopsToRoot() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains("var selectedTabRoute by rememberSaveable(startRoute)"))
        assertTrue(text.contains("val reselected = selectedTabRoute == dest.route"))
        assertTrue(text.contains("nav.returnToTabRoot(dest.route)"))
        assertTrue(text.contains("if (popBackStack(route, inclusive = false)) return"))
        assertTrue(text.contains("restoreState = false"))
        assertTrue(text.contains("nav.navigate(it) { launchSingleTop = true }"))
        assertFalse(text.contains("MoreScreen(onNavigate = { nav.navigateTopLevel(it) })"))
    }
}
