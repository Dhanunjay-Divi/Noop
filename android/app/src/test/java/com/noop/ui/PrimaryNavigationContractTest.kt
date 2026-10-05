package com.noop.ui

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** Pins the daily navigation hierarchy shared with the Apple shell. */
@OptIn(ExperimentalCoroutinesApi::class)
class PrimaryNavigationContractTest {
    private fun appRootSource(): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/AppRoot.kt"),
            File(root, "app/src/main/java/com/noop/ui/AppRoot.kt"),
            File(root, "android/app/src/main/java/com/noop/ui/AppRoot.kt"),
        ).firstOrNull(File::isFile)?.readText()
    }

    private fun uiSource(name: String): File? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/java/com/noop/ui/$name"),
            File(root, "app/src/main/java/com/noop/ui/$name"),
            File(root, "android/app/src/main/java/com/noop/ui/$name"),
        ).firstOrNull(File::isFile)
    }

    private fun resourceSource(localeDirectory: String = "values"): String? {
        val root = File(System.getProperty("user.dir") ?: ".")
        return listOf(
            File(root, "src/main/res/$localeDirectory/strings.xml"),
            File(root, "app/src/main/res/$localeDirectory/strings.xml"),
            File(root, "android/app/src/main/res/$localeDirectory/strings.xml"),
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
                barHeightDp = 50,
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
            assertEquals(50, layout.barHeightDp)
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
    fun accessibilityKeepsTabSemanticsWithFivePersistentLabels() {
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
        assertEquals(50, accessibilityText.barHeightDp)
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
        assertEquals(50, unusuallyLongLabels.barHeightDp)
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
        assertTrue(barSlot.contains("selected = selected"))
        assertTrue(barSlot.contains("role = Role.Tab"))
        assertTrue(barSlot.contains(".heightIn(min = Metrics.controlHeight)"))
        assertTrue(barSlot.contains("Text("))
        assertFalse(barSlot.contains("Spacer(modifier = Modifier.fillMaxSize())"))
        assertTrue(barSlot.contains("minLines = labelMaxLines"))
        assertTrue(barSlot.contains("maxLines = labelMaxLines"))
        assertTrue(barSlot.contains("softWrap = false"))
        assertTrue(barSlot.contains("overflow = TextOverflow.Ellipsis"))
        assertTrue(barSlot.contains("fontSize = (10f * labelScaleMultiplier).sp"))
        assertFalse(barSlot.contains("overflow = TextOverflow.Clip"))
        assertFalse(barSlot.contains("showVisualLabel"))

        val bottomBar = text
            .substringAfter("private fun ExpandedGlassBottomBarHost(")
            .substringBefore("\ninternal enum class NoopCommandLensEdge")
        assertTrue(bottomBar.contains(".selectableGroup()"))
        assertTrue(bottomBar.contains("val barHeight = labelLayout.barHeightDp.dp + Metrics.space8"))
        assertTrue(bottomBar.contains(
            "labelScaleMultiplier = labelLayout.labelScaleMultiplier",
        ))
        assertFalse(bottomBar.contains("showVisualLabel"))
        assertTrue(text.contains("BottomBarSingleLineHeightDp = 50"))
        assertFalse(text.contains("BottomBarTwoLineHeightDp"))
        assertTrue(text.contains("CompactBottomBarWidthDp = 360"))
        assertTrue(bottomBar.contains(
            "val outerHorizontalPadding = if (compactNavigation) 8.dp else 12.dp",
        ))
        assertTrue(bottomBar.contains("val barContentPadding = bottomBarContentPadding("))
        assertTrue(bottomBar.contains("minimumTabWidth = Metrics.controlHeight.value"))
        assertTrue(bottomBar.contains("preferredPadding = Metrics.space24.value"))
        assertTrue(bottomBar.contains("MeniscusNavigationRail("))
        assertTrue(bottomBar.contains("MeniscusNavigationBead("))
        assertTrue(bottomBar.contains("private fun CompactBottomBar("))
        assertTrue(bottomBar.contains("private fun FloatingCompactBottomBar("))
        assertTrue(bottomBar.contains(".testTag(\"noop.tab.compact\")"))
        assertTrue(bottomBar.contains("R.string.compact_navigation_show"))
        assertTrue(bottomBar.contains("contentDescription = showNavigation"))
        assertTrue(bottomBar.contains("R.string.compact_navigation_state"))
        assertTrue(text.contains("CompactNavigationControlWidth = 136.dp"))
        assertTrue(text.contains("CompactNavigationDockPrefs.write("))
        assertTrue(bottomBar.contains("animateDpAsState("))
        assertTrue(bottomBar.contains("detectHorizontalDragGestures("))
        assertTrue(bottomBar.contains("R.string.noop_command_lens_move_left"))
        assertTrue(bottomBar.contains("R.string.noop_command_lens_move_right"))
        assertTrue(bottomBar.contains("CustomAccessibilityAction(moveLeft)"))
        assertTrue(bottomBar.contains("CustomAccessibilityAction(moveRight)"))
        assertTrue(bottomBar.contains(".height(Metrics.navigationBarReservedHeight)"))
        assertTrue(text.contains("bottomBarVisuallyCompact = bottomBarCompact && density.fontScale < 1.6f"))
        assertTrue(text.contains("if (bottomBarVisuallyCompact)"))
        assertTrue(text.contains("Spacer("))
        assertTrue(text.contains("modifier = Modifier.align(Alignment.BottomCenter)"))
        assertTrue(bottomBar.contains("val compactBeadDiameter = 34.dp"))
        assertTrue(bottomBar.contains("val beadCanvasSize = 42.dp"))
        assertTrue(bottomBar.contains("selectedCenter = animatedLensCenter"))
        assertTrue(bottomBar.contains("beadDiameter = compactBeadDiameter"))
        assertTrue(bottomBar.contains("animationSpec = if (reduceMotion) snap() else NoopMotion.card()"))
        assertTrue(bottomBar.contains("val railCornerRadius = 18.dp"))
        assertTrue(bottomBar.contains("var scrubPreviewIndex by remember"))
        assertTrue(bottomBar.contains("detectHorizontalDragGestures("))
        assertTrue(bottomBar.contains("bottomBarNearestTabIndex("))
        assertTrue(bottomBar.contains("active = displayIndex == index"))
        assertTrue(bottomBar.contains("selected = selected == tab.dest"))
        assertFalse(bottomBar.contains("BottomNavigationMeniscusShape"))
        assertFalse(bottomBar.contains("raisedNavigationLens"))
        assertTrue(text.contains("private fun MeniscusNavigationRail("))
        assertTrue(text.contains("private fun MeniscusNavigationBead("))
        assertTrue(text.contains("Canvas(modifier = modifier)"))
        assertFalse(bottomBar.contains("MovableNoopCommandLens("))
        assertTrue(text.contains("MovableNoopCommandLens("))
        assertTrue(text.contains("NestedScrollConnection"))
        assertTrue(text.contains(".nestedScroll(bottomBarScrollConnection)"))
        assertTrue(text.contains("override fun onPostScroll("))
        assertTrue(text.contains("consumed = consumed"))
        assertFalse(text.contains("override fun onPreScroll("))
        assertTrue(text.contains("with(density) { 72.dp.toPx() }"))
        assertTrue(text.contains("with(density) { 52.dp.toPx() }"))
        assertTrue(text.contains("updateCompactNavigationHysteresis("))
        assertTrue(text.contains("LocalNavigationScrollTailClearance provides"))
        assertTrue(text.contains("CompactNavigationOverlayFootprint"))
        val components = uiSource("Components.kt")?.readText()
        assumeTrue("Components.kt unavailable from ${System.getProperty("user.dir")}", components != null)
        assertTrue(components!!.contains("LocalNavigationScrollTailClearance.current"))
        assertTrue(components.contains("bottom = bottomTailPadding"))
    }

    @Test
    fun meniscusRailUsesFiveFixedCentersAndSmoothBoundedShoulders() {
        assertEquals(
            24f,
            bottomBarContentPadding(344f, 5, 48f, 1f, 24f),
            0.0001f,
        )
        val compactPadding = bottomBarContentPadding(264f, 5, 48f, 1f, 24f)
        assertEquals(10f, compactPadding, 0.0001f)
        assertEquals(
            48f,
            (
                264f -
                    compactPadding * 2f -
                    1f * (5 - 1)
                ) / 5f,
            0.0001f,
        )
        val centers = (0 until 5).map { selectedIndex ->
            bottomBarTabCenter(
                availableWidth = 344f,
                horizontalContentPadding = 24f,
                interItemSpacing = 1f,
                tabCount = 5,
                selectedIndex = selectedIndex,
            )
        }
        listOf(53.2f, 112.6f, 172f, 231.4f, 290.8f)
            .zip(centers)
            .forEach { (expected, actual) ->
                assertEquals(expected, actual, 0.0001f)
            }
        assertEquals(59.4f, centers.zipWithNext().first().let { it.second - it.first }, 0.0001f)

        centers.forEach { center ->
            val geometry = bottomBarMeniscusGeometry(
                widthPx = 344f,
                heightPx = 68f,
                selectedCenterXPx = center,
                beadDiameterPx = 36f,
                cornerRadiusPx = 50f,
            )
            assertEquals(center, geometry.centerXPx, 0.0001f)
            assertEquals(26.44f, geometry.cornerRadiusPx, 0.0001f)
            assertTrue(geometry.startXPx >= geometry.cornerRadiusPx)
            assertTrue(geometry.startXPx <= geometry.leftShoulderXPx)
            assertTrue(geometry.leftShoulderXPx <= geometry.centerXPx)
            assertTrue(geometry.centerXPx <= geometry.rightShoulderXPx)
            assertTrue(geometry.rightShoulderXPx <= geometry.endXPx)
            assertTrue(geometry.endXPx <= 344f - geometry.cornerRadiusPx)
            assertTrue(geometry.shoulderYPx < geometry.baselineYPx)
            assertTrue(geometry.baselineYPx < geometry.recessBottomYPx)
            assertEquals(15.12f, geometry.baselineYPx, 0.0001f)
            assertEquals(12.96f, geometry.shoulderYPx, 0.0001f)
            assertEquals(30.24f, geometry.recessBottomYPx, 0.0001f)
        }

        assertEquals(
            centers.first(),
            bottomBarTabCenter(344f, 24f, 1f, 5, -4),
            0.0001f,
        )
        assertEquals(
            centers.last(),
            bottomBarTabCenter(344f, 24f, 1f, 5, 12),
            0.0001f,
        )

        val rtlCenters = (0 until 5).map { selectedIndex ->
            bottomBarPhysicalTabCenter(
                availableWidth = 344f,
                horizontalContentPadding = 24f,
                interItemSpacing = 1f,
                tabCount = 5,
                selectedIndex = selectedIndex,
                isRtl = true,
            )
        }
        centers.reversed().zip(rtlCenters).forEach { (expected, actual) ->
            assertEquals(expected, actual, 0.0001f)
        }
        assertEquals(
            0,
            bottomBarNearestTabIndex(20f, 344f, 24f, 1f, 5, isRtl = false),
        )
        assertEquals(
            2,
            bottomBarNearestTabIndex(172f, 344f, 24f, 1f, 5, isRtl = false),
        )
        assertEquals(
            4,
            bottomBarNearestTabIndex(330f, 344f, 24f, 1f, 5, isRtl = false),
        )
        assertEquals(
            4,
            bottomBarNearestTabIndex(20f, 344f, 24f, 1f, 5, isRtl = true),
        )
        assertEquals(
            0,
            bottomBarNearestTabIndex(330f, 344f, 24f, 1f, 5, isRtl = true),
        )
    }

    @Test
    fun workoutsStayPrimaryAndMoreDoesNotClaimTheirSelection() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains(
            "BarTab(Destination.Workouts, Icons.Filled.FitnessCenter, R.string.nav_workouts)"
        ))
        assertTrue(text.contains(
            "BarTab(Destination.Today, Icons.Filled.MonitorHeart, R.string.nav_today)"
        ))
        assertTrue(text.contains(
            "BarTab(Destination.Trends, Icons.Filled.Hub, R.string.nav_trends)"
        ))
        assertTrue(text.contains(
            "BarTab(Destination.Sleep, Icons.Filled.NightsStay, R.string.nav_sleep)"
        ))
        assertTrue(text.contains(
            "BarTab(Destination.More, Icons.Filled.Apps, R.string.nav_more)"
        ))
        assertTrue(text.contains("active = displayIndex == index"))
        assertTrue(text.contains("selected = selected == tab.dest"))
        assertFalse(text.contains(
            "Destination.Live, Destination.Workouts, Destination.Nutrition"
        ))
        assertTrue(text.contains(
            "composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }"
        ))
    }

    @Test
    fun compactNavigationSnapsOnlyAfterAnInwardCornerDrag() {
        assertEquals(
            CompactNavigationDockEdge.END,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.START,
                horizontalDragPx = 48f,
                thresholdPx = 44f,
            ),
        )
        assertEquals(
            CompactNavigationDockEdge.START,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.END,
                horizontalDragPx = -48f,
                thresholdPx = 44f,
            ),
        )
        assertEquals(
            CompactNavigationDockEdge.START,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.START,
                horizontalDragPx = 20f,
                thresholdPx = 44f,
            ),
        )
        assertEquals(
            CompactNavigationDockEdge.END,
            compactNavigationDockDestination(
                current = CompactNavigationDockEdge.END,
                horizontalDragPx = 20f,
                thresholdPx = 44f,
            ),
        )
    }

    @Test
    fun movableCommandLensClampsPersistsAndSnapsAtTheNearestEdge() {
        val left = noopCommandLensRestingOffset(
            containerWidthPx = 1_080,
            containerHeightPx = 2_400,
            touchWidthPx = 144,
            touchHeightPx = 168,
            topInsetPx = 120,
            bottomClearancePx = 260,
            edge = NoopCommandLensEdge.START,
            verticalFraction = 0.5f,
        )
        val right = noopCommandLensRestingOffset(
            containerWidthPx = 1_080,
            containerHeightPx = 2_400,
            touchWidthPx = 144,
            touchHeightPx = 168,
            topInsetPx = 120,
            bottomClearancePx = 260,
            edge = NoopCommandLensEdge.END,
            verticalFraction = 0.5f,
        )
        assertEquals(0, left.x)
        assertEquals(936, right.x)
        assertEquals(left.y, right.y)

        val clamped = noopCommandLensClampOffset(
            x = 2_000f,
            y = 3_000f,
            containerWidthPx = 1_080,
            containerHeightPx = 2_400,
            touchWidthPx = 144,
            touchHeightPx = 168,
            topInsetPx = 120,
            bottomClearancePx = 260,
        )
        assertEquals(right.x, clamped.x)
        assertEquals(1_972, clamped.y)
        assertEquals(
            1f,
            noopCommandLensVerticalFraction(
                yPx = clamped.y,
                containerHeightPx = 2_400,
                touchHeightPx = 168,
                topInsetPx = 120,
                bottomClearancePx = 260,
            ),
            0.0001f,
        )

        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!
        assertTrue(text.contains("private fun NoopCommandNMark()"))
        assertTrue(text.contains("NoopCommandNMark()"))
        assertTrue(text.contains("lineTo(right, bottom)"))
        assertTrue(text.contains("join = StrokeJoin.Round"))
        assertFalse(text.contains("sweepAngle = 288f"))
        val lens = text
            .substringAfter("private fun MovableNoopCommandLens(")
            .substringBefore("\n/**")
        assertTrue(lens.contains("pointerInput("))
        assertTrue(lens.contains("detectDragGestures("))
        assertTrue(lens.contains("NoopCommandLensPrefs.write("))
        assertTrue(lens.contains("CustomAccessibilityAction(moveLeftLabel)"))
        assertTrue(lens.contains("CustomAccessibilityAction(moveRightLabel)"))
        assertTrue(lens.contains("CustomAccessibilityAction(moveUpLabel)"))
        assertTrue(lens.contains("CustomAccessibilityAction(moveDownLabel)"))
        assertTrue(lens.contains("NoopCommandLensBubbleShape(edge)"))
        assertTrue(lens.contains("val bubbleWidth = 30.dp"))
        assertTrue(lens.contains("val bubbleHeight = 34.dp"))
        assertTrue(lens.contains(".size(width = bubbleWidth, height = bubbleHeight)"))
        assertTrue(lens.contains("val bubbleEdgePull = (touchWidth - bubbleWidth) / 2"))
        assertTrue(lens.contains("NoopCommandLensBubbleHighlight(edge)"))
        assertFalse(lens.contains("RoundedCornerShape("))
        assertFalse(lens.contains(".width(1.5.dp)"))
        assertTrue(lens.contains("val touchWidth = 48.dp"))
        assertTrue(lens.contains("val touchHeight = 52.dp"))
        assertTrue(text.contains("DEFAULT_VERTICAL_FRACTION = 0.76f"))
    }

    @Test
    fun commandLensBubbleKeepsAFlatEdgeDockAndMirroredBody() {
        val left = noopCommandLensBubbleGeometry(
            widthPx = 32f,
            heightPx = 36f,
            edge = NoopCommandLensEdge.START,
        )
        val right = noopCommandLensBubbleGeometry(
            widthPx = 32f,
            heightPx = 36f,
            edge = NoopCommandLensEdge.END,
        )

        assertEquals(0f, left.edgeX, 0.0001f)
        assertEquals(32f, left.outerX, 0.0001f)
        assertEquals(32f, right.edgeX, 0.0001f)
        assertEquals(0f, right.outerX, 0.0001f)
        assertEquals(left.neckTopY, right.neckTopY, 0.0001f)
        assertEquals(left.neckBottomY, right.neckBottomY, 0.0001f)
        assertTrue(left.neckTopY > left.bodyTopY)
        assertTrue(left.neckBottomY < left.bodyBottomY)
        assertEquals(36f, left.neckTopY + left.neckBottomY, 0.0001f)
        assertEquals(36f, left.bodyTopY + left.bodyBottomY, 0.0001f)

        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!
        assertTrue(text.contains("Outline.Generic(noopCommandLensBubblePath(size, edge))"))
        assertTrue(text.contains("moveTo(geometry.edgeX, geometry.neckTopY)"))
        assertTrue(text.contains("geometry.outerX"))
        assertTrue(text.contains("geometry.bodyTopY"))
        assertTrue(text.contains("geometry.bodyBottomY"))
        assertTrue(text.contains("geometry.neckBottomY"))
        assertTrue(text.contains("Palette.navigationLensHighlight.copy("))
        assertTrue(text.contains("bottomClearancePx ="))
        assertTrue(text.contains("WindowInsets.navigationBars.getBottom(density)"))
    }

    @Test
    fun privateFriendsIsReachableFromTheCompleteIndex() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!
        val managedScreen = uiSource("ManagedFriendsScreen.kt")

        assertTrue(text.contains(
            "Friends(\"friends\", R.string.nav_friends, Icons.Filled.People)"
        ))
        assertTrue(text.contains(
            "Destination.Profile, Destination.Friends, Destination.Devices"
        ))
        assertTrue(text.contains(
            "BandAccount(\"band_account\", R.string.ownership_screen_title, Icons.Filled.Badge)"
        ))
        assertTrue(text.contains(
            "composable(Destination.BandAccount.route) { OwnershipAccountScreen() }"
        ))
        assertTrue(text.contains("composable(Destination.Friends.route)"))
        assertTrue(text.contains("FriendsScreen("))
        assertTrue("ManagedFriendsScreen.kt is missing", managedScreen != null)
        assertTrue(managedScreen!!.readText().contains("ManagedCloudService"))
        assertFalse(managedScreen.readText().contains("FriendsViewModel"))
        assertFalse(
            "Retired self-hosted Friends presentation source remains",
            uiSource("FriendsViewModel.kt")?.exists() == true,
        )
    }

    @Test
    fun accountDataAndNoopPlusHaveOneClearHierarchy() {
        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!

        assertTrue(text.contains(
            "NoopPlus(\"noop_plus\", R.string.managed_cloud_brand, Icons.Filled.Cloud)"
        ))
        assertTrue(text.contains("MoreAccountDataAccess(onNavigate = onNavigate)"))
        assertTrue(text.contains("dest = Destination.BandAccount"))
        assertTrue(text.contains("dest = Destination.BackupSync"))
        assertTrue(text.contains(
            "Destination.FusedRecord, Destination.AppleHealth, Destination.DataSources,\n" +
                "        Destination.NoopPlus,"
        ))
        assertFalse(text.contains("NoopPlusEntry(onNavigate = onNavigate)"))
        assertTrue(text.contains("R.string.nav_insights"))
        assertTrue(text.contains("Destination.Insights.route"))
        assertTrue(text.contains(
            "composable(Destination.NoopPlus.route) { NoopPlusScreen() }"
        ))
    }

    @Test
    fun dataSyncKeepsLocalControlsPrimaryAndSelfHostingAdvanced() {
        val screenFile = uiSource("BackupSyncScreen.kt")
        assertTrue("BackupSyncScreen.kt is missing", screenFile != null)
        val screen = screenFile!!.readText()
        val english = resourceSource() ?: error("English strings.xml is missing")

        assertTrue(english.contains(
            """<string name="nav_backup_sync">Data &amp; Sync</string>"""
        ))
        assertTrue(english.contains("""<string name="data_sync_subtitle">"""))
        assertTrue(screen.contains("subtitle = uiString(R.string.data_sync_subtitle)"))
        assertTrue(screen.contains("var advancedServerOpen by rememberSaveable"))
        assertTrue(screen.contains("val selfHostedServerCard: @Composable () -> Unit"))
        assertTrue(screen.contains("if (advancedServerOpen)"))
        assertTrue(screen.contains("selfHostedServerCard()"))
        assertTrue(screen.contains("R.string.appwide_a11y_expanded"))
        assertTrue(screen.contains("R.string.appwide_a11y_collapsed"))

        val folder = screen.indexOf("// 1 · Destination folder")
        val restore = screen.indexOf("// 4 · Restore")
        val advanced = screen.indexOf("// Legacy self-hosted decoded-data upload")
        assertTrue(folder >= 0)
        assertTrue(restore > folder)
        assertTrue(advanced > restore)
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

    @Test
    fun managedVerificationCodeAcceptsFourToEightLocalizedDigits() {
        assertEquals("1234567", sanitizeManagedVerificationCode(" 12a3-4567 "))
        assertEquals("123456", sanitizeManagedVerificationCode("١٢٣456"))
        assertEquals("123456", sanitizeManagedVerificationCode("１２３456"))
        assertEquals("1234", sanitizeManagedVerificationCode("123456", 4))
        assertEquals("", sanitizeManagedVerificationCode("123", 0))
        assertTrue(isManagedVerificationCodeComplete("1234"))
        assertTrue(isManagedVerificationCodeComplete("12345678"))
        assertFalse(isManagedVerificationCodeComplete("123"))
        assertFalse(isManagedVerificationCodeComplete("123456789"))
    }

    @Test
    fun navigationAndOtpUseSharedMotionWithAccessibleFallbacks() {
        val root = appRootSource()
        assumeTrue("AppRoot.kt unavailable", root != null)
        val appRoot = root!!
        val bottomBar = appRoot
            .substringAfter("private fun GlassBottomBar(")
            .substringBefore("\ninternal enum class NoopCommandLensEdge")

        assertTrue(bottomBar.contains("animateDpAsState("))
        assertTrue(bottomBar.contains("MeniscusNavigationRail("))
        assertTrue(bottomBar.contains("MeniscusNavigationBead("))
        assertTrue(bottomBar.contains("NoopMotion.card()"))
        assertTrue(bottomBar.contains("rememberReduceMotion()"))
        assertTrue(bottomBar.contains("if (reduceMotion) snap()"))
        assertTrue(bottomBar.contains("detectHorizontalDragGestures("))
        assertTrue(bottomBar.contains("bottomBarNearestTabIndex("))
        assertTrue(bottomBar.contains(".selectableGroup()"))
        assertFalse(bottomBar.contains("raisedNavigationLens"))
        assertFalse(bottomBar.contains("BottomNavigationMeniscusShape"))
        assertTrue(appRoot.contains("role = Role.Tab"))

        val managed = uiSource("ManagedCloudCard.kt")
        assertTrue("ManagedCloudCard.kt is missing", managed != null)
        val text = managed!!.readText()
        assertTrue(text.contains("BasicTextField("))
        assertTrue(text.contains("AutofillType.SmsOtpCode"))
        assertTrue(text.contains("ManagedVerificationSuccessOverlay("))
        assertTrue(text.contains("ManagedCloudPhase.CONSENT_REQUIRED"))
        assertTrue(text.contains("rememberReduceMotion()"))
        assertTrue(text.contains("verificationSuccessVisible"))
        assertTrue(text.contains("Modifier.clearAndSetSemantics"))
        assertTrue(text.contains("LiveRegionMode.Assertive"))
        assertTrue(text.contains("paneTitle = verifiedLabel"))
        assertTrue(text.contains("password()"))
        assertTrue(text.contains(".testTag(\"noop.noop-plus.verified\")"))
        assertTrue(
            text.contains(
                "ManagedVerificationSuccessDurationMillis = 3_000L"
            )
        )
        assertTrue(
            text.contains(
                "scope.launchManagedVerificationSuccessDismissal"
            )
        )
        val phaseLifecycle = text
            .substringAfter("LaunchedEffect(state.phase)")
            .substringBefore("NoopBottomSheet(")
        assertTrue(
            phaseLifecycle
                .split("verificationSuccessJob?.cancel()")
                .size - 1 >= 2
        )
        val disposalLifecycle = text
            .substringAfter("DisposableEffect(Unit)")
            .substringBefore("LaunchedEffect(state.phase)")
        assertTrue(
            disposalLifecycle.contains("verificationSuccessJob?.cancel()")
        )
        assertFalse(text.contains("verificationSuccessCode"))

        val clearsCode = text.indexOf("code = \"\"")
        val refreshesOverview = text.indexOf(
            "service.refreshOverview()",
            startIndex = clearsCode + 1,
        )
        assertTrue(clearsCode >= 0)
        assertTrue(refreshesOverview > clearsCode)

        assertTrue(appRoot.contains("Metrics.navigationLensStrokeWidth"))
        assertTrue(appRoot.contains("Metrics.navigationLensHighlightWidth"))
        assertFalse(bottomBar.contains("Metrics.navigationLensShadowRadius"))
        assertFalse(bottomBar.contains(".shadow("))
        assertTrue(appRoot.contains("Metrics.navigationLensIconSize"))
        assertTrue(appRoot.contains("Metrics.navigationLensActiveOffset"))
        assertTrue(appRoot.contains("Metrics.navigationLensLabelOffset"))
        assertTrue(appRoot.contains("Palette.navigationLensHighlight"))
        assertTrue(appRoot.contains("Metrics.navigationLensItemSpacing"))
        assertFalse(appRoot.contains("interItemSpacing = 1.dp"))
        assertFalse(appRoot.contains("Arrangement.spacedBy(1.dp)"))
    }

    @Test
    fun managedVerificationSuccessWaitsForTheFullWindow() = runTest {
        var dismissed = false
        val job = launchManagedVerificationSuccessDismissal {
            dismissed = true
        }

        runCurrent()
        assertFalse(dismissed)
        advanceTimeBy(ManagedVerificationSuccessDurationMillis - 1)
        runCurrent()
        assertFalse(dismissed)
        advanceTimeBy(1)
        runCurrent()

        assertTrue(dismissed)
        job.join()
    }

    @Test
    fun managedVerificationSuccessCancellationSuppressesDismissal() = runTest {
        var dismissed = false
        val job = launchManagedVerificationSuccessDismissal {
            dismissed = true
        }

        runCurrent()
        job.cancel()
        advanceTimeBy(ManagedVerificationSuccessDurationMillis)
        runCurrent()

        assertFalse(dismissed)
        job.join()
    }
}
