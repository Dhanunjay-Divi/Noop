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
            .substringBefore("\ninternal enum class NoopCommandLensEdge")
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
            "val barContentPadding = if (compactNavigation) 4.dp else 7.dp",
        ))
        assertTrue(bottomBar.contains(
            "RoundedCornerShape(Metrics.navigationBarRadius)"
        ))
        assertFalse(bottomBar.contains("MovableNoopCommandLens("))
        assertTrue(text.contains("MovableNoopCommandLens("))
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
        assertTrue(text.contains("active = selected == tab.dest"))
        assertFalse(text.contains(
            "Destination.Live, Destination.Workouts, Destination.Nutrition"
        ))
        assertTrue(text.contains(
            "composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }"
        ))
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
        assertEquals(2, left.x)
        assertEquals(934, right.x)
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
        assertTrue(lens.contains(".width(18.dp)"))
        assertTrue(lens.contains(".height(38.dp)"))
        assertTrue(lens.contains("(-18).dp else 18.dp"))
        assertTrue(lens.contains("val touchWidth = 48.dp"))
        assertTrue(lens.contains("val touchHeight = 52.dp"))
        assertTrue(text.contains("DEFAULT_VERTICAL_FRACTION = 0.76f"))
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
        assertTrue(bottomBar.contains("raisedNavigationLens(lensAccent)"))
        assertTrue(bottomBar.contains("rememberReduceMotion()"))
        assertTrue(bottomBar.contains("if (reduceMotion) snap()"))
        assertTrue(bottomBar.contains(".selectableGroup()"))
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
        assertTrue(appRoot.contains("Metrics.navigationLensShadowRadius"))
        assertTrue(appRoot.contains("Metrics.navigationLensIconSize"))
        assertTrue(appRoot.contains("Metrics.navigationLensActiveOffset"))
        assertTrue(appRoot.contains("Metrics.navigationLensLabelOffset"))
    }
}
