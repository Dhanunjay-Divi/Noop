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
    fun largeTextKeepsStableSingleLineEllipsizedLabels() {
        assertEquals(
            BottomBarLabelLayout(maxLines = 1, barHeightDp = 56),
            bottomBarLabelLayout(fontScale = 1.0f),
        )
        val largeText = bottomBarLabelLayout(fontScale = 2.0f)
        assertEquals(1, largeText.maxLines)
        assertTrue(largeText.barHeightDp > 56)

        val source = appRootSource()
        assumeTrue("AppRoot.kt unavailable from ${System.getProperty("user.dir")}", source != null)
        val text = source!!
        assertTrue(text.contains("rememberBottomBarLabelLayout()"))
        val barSlot = text
            .substringAfter("private fun BarSlot(")
            .substringBefore("\n}\n\nprivate enum class QuickActionKind")

        assertTrue(barSlot.contains("contentDescription = label"))
        assertTrue(barSlot.contains(".selectable("))
        assertTrue(barSlot.contains("selected = active"))
        assertTrue(barSlot.contains("role = Role.Tab"))
        assertTrue(barSlot.contains("maxLines = labelMaxLines"))
        assertTrue(barSlot.contains("softWrap = false"))
        assertTrue(barSlot.contains("overflow = TextOverflow.Ellipsis"))
        assertFalse(barSlot.contains("overflow = TextOverflow.Clip"))
        assertFalse(barSlot.contains("if (showLabel)"))

        val bottomBar = text
            .substringAfter("private fun GlassBottomBar(")
            .substringBefore("\n@Composable\nprivate fun FloatingQuickAddButton")
        assertTrue(bottomBar.contains(".selectableGroup()"))
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
