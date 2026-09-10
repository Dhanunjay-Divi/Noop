package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bed
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Hexagon
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timeline
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import com.noop.BuildConfig
import com.noop.R
import com.noop.analytics.FusionSource
import com.noop.analytics.HydrationStore
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// MARK: - Navigation model
//
// The macOS app's sidebar holds many sections; on Android (mirroring the iOS RootTabView) we surface
// them through a unified floating "glass" bottom bar (Today · Trends · Workouts · Sleep · More) for the everyday
// screens, with a "More" sheet that lists the full grouped set - so every destination is one tap away
// without a global hamburger/drawer. Destinations are grouped exactly as the sidebar groups them.
// Routes whose screens belong to later waves point at a ComingSoon placeholder so the app compiles today.

/** A single drawer destination: stable route, display title (localized via [titleRes]), sidebar icon. */
private enum class Destination(
    val route: String,
    @StringRes val titleRes: Int,
    val icon: ImageVector,
) {
    // Group: Today
    Today("today", R.string.nav_today, Icons.Filled.Home),
    Intelligence("intelligence", R.string.nav_intelligence, Icons.Filled.Psychology),
    Calendar("calendar", R.string.appwide_calendar_your_month, Icons.Filled.CalendarMonth),
    Profile("profile", R.string.l10n_settings_screen_profile_ff4fc027, Icons.Filled.AccountCircle),
    BandAccount("band_account", R.string.ownership_screen_title, Icons.Filled.Badge),
    // Optional, default-OFF (task #43): the Coupled view (WHOOP-style day read). Reached ONLY via the
    // Today dashboard "Coupled view" card tap-through, so it is deliberately NOT in any [DrawerGroup].
    CoupledView("coupled_view", R.string.nav_coupled_view, Icons.Filled.Hexagon),

    // Group: Live
    Live("live", R.string.nav_live, Icons.Filled.FavoriteBorder),
    Intervals("intervals", R.string.nav_intervals, Icons.Filled.Timeline),

    // Group: Recovery
    Sleep("sleep", R.string.nav_sleep, Icons.Filled.Bedtime),
    Breathe("breathe", R.string.nav_breathe, Icons.Filled.Air),
    Stress("stress", R.string.nav_stress, Icons.Filled.Spa),

    // Group: Activity
    Workouts("workouts", R.string.nav_workouts, Icons.Filled.FitnessCenter),
    Nutrition("nutrition", R.string.nav_nutrition, Icons.Filled.Restaurant),
    Trends("trends", R.string.nav_trends, Icons.AutoMirrored.Filled.TrendingUp),

    // Group: Insight
    Coach("coach", R.string.nav_coach, Icons.Filled.AutoAwesome),
    InsightsHub("insights_hub", R.string.nav_insights_hub, Icons.Filled.Insights),
    Insights("insights", R.string.nav_insights, Icons.Filled.Insights),
    Explore("explore", R.string.nav_explore, Icons.Filled.Explore),
    Compare("compare", R.string.nav_compare, Icons.AutoMirrored.Filled.CompareArrows),

    // Group: Health
    Health("health", R.string.nav_health, Icons.Filled.MonitorHeart),
    Friends("friends", R.string.nav_friends, Icons.Filled.People),
    Hydration("hydration", R.string.nav_hydration, Icons.Filled.WaterDrop),
    VitalSigns("vital_signs", R.string.nav_vital_signs, Icons.Filled.HealthAndSafety),
    VitalSignsDetail("vital_detail/{key}", R.string.nav_vital_signs, Icons.Filled.HealthAndSafety),
    LabBook("lab_book", R.string.nav_lab_book, Icons.Filled.HealthAndSafety),
    Rhythm("rhythm", R.string.nav_rhythm, Icons.Filled.MonitorHeart),
    AppleHealth("apple_health", R.string.nav_apple_health, Icons.Filled.HealthAndSafety),

    // Group: System
    Automations("automations", R.string.nav_automations, Icons.Filled.Bolt),
    // "Sleep Planner" is the ONE sleep-schedule surface (#766): tonight's plan, the phone Wake Window
    // with guaranteed OS backup, the strap firmware alarm, and the wind-down reminder in one place.
    // Route id stays "smart_alarm" (display string only).
    SmartAlarm("smart_alarm", R.string.nav_alarms, Icons.Filled.Alarm),
    Safety("safety", R.string.nav_safety, Icons.Filled.Shield),
    Devices("devices", R.string.nav_devices, Icons.Filled.Watch),
    DataSources("data_sources", R.string.nav_data_sources, Icons.Filled.Storage),
    NoopPlus("noop_plus", R.string.managed_cloud_brand, Icons.Filled.Cloud),
    BackupSync("backup_sync", R.string.nav_backup_sync, Icons.Filled.CloudSync),
    FusedRecord("fused_record", R.string.nav_fused_record, Icons.AutoMirrored.Filled.CompareArrows),
    Notifications("notifications", R.string.nav_notifications, Icons.Filled.Notifications),
    Updates("updates", R.string.l10n_app_root_updates_c76d1807, Icons.Filled.AutoAwesome),
    Settings("settings", R.string.nav_settings, Icons.Filled.Settings),
    TestCentre("test_centre", R.string.nav_test_centre, Icons.Filled.BugReport),

    // The "More" tab: its own navigated page (mirroring the iOS More tab) that hosts the full
    // grouped destination list. It is NOT itself in any [DrawerGroup] — it's the door to them.
    More("more", R.string.nav_more, Icons.Filled.MoreHoriz);

    companion object {
        /** Resolve the destination owning the current back-stack route (defaults to Today). */
        fun forRoute(route: String?): Destination =
            entries.firstOrNull {
                // Match parameterised routes (e.g. "vital_detail/rhr" vs "vital_detail/{key}") by
                // base path so the top-bar title resolves correctly on a detail screen, not "Today".
                it.route == route || it.route.substringBefore('/') == route?.substringBefore('/')
            } ?: Today
    }
}

private val primaryTabDestinations = setOf(
    Destination.Today,
    Destination.Trends,
    Destination.Workouts,
    Destination.Sleep,
    Destination.More,
)

/** Resolve the tab that owns a route entered without an existing tab stack. Nested pushes retain the
 * selected tab at the call site; only a direct launch/deep link needs this fallback ownership. */
private fun primaryTabForRoute(route: String?): Destination = when (val destination = Destination.forRoute(route)) {
    Destination.Today, Destination.Calendar -> Destination.Today
    Destination.Trends, Destination.Workouts, Destination.Sleep, Destination.More -> destination
    else -> Destination.More
}

/** More-page groups, mirroring the iOS More tab exactly: Insights · Body · Data · App. `defaultExpanded`
 *  mirrors the iOS S2 default: Insights + Body open at rest, Data + App collapsed to just their header. */
// [header] is the STABLE persistence key (stored in SharedPreferences and kept byte-identical to iOS's
// `more.expandedSections` CSV — see [MoreSectionPrefs]); it must NEVER be localized. [headerRes] is the
// localized DISPLAY label the More page shows. Decoupling the two lets the label translate without
// touching the persisted open/closed state or the iOS parity of the stored string.
private data class DrawerGroup(
    val header: String,
    @StringRes val headerRes: Int,
    val items: List<Destination>,
    val defaultExpanded: Boolean,
)

// Mirrors the iOS RootTabView `moreTab` grouping + order. Today / Trends / Workouts / Sleep are NOT
// listed (they're bottom-bar tabs). Android-only screens (Vital Signs, Wake Window,
// Notifications, Devices) are slotted into the matching iOS group.
private val drawerGroups: List<DrawerGroup> = listOf(
    DrawerGroup("Insights", R.string.more_group_insights, listOf(
        Destination.Calendar, Destination.InsightsHub, Destination.Intelligence, Destination.Coach,
        Destination.Insights, Destination.Explore, Destination.Compare,
    ), defaultExpanded = true),
    DrawerGroup("Body", R.string.more_group_body, listOf(
        Destination.Profile, Destination.BandAccount, Destination.Friends, Destination.Devices,
        Destination.Live, Destination.Nutrition,
        Destination.Health, Destination.VitalSigns,
        Destination.LabBook, Destination.Stress, Destination.Breathe, Destination.Intervals,
        Destination.Rhythm,
    ), defaultExpanded = true),
    DrawerGroup("Data", R.string.more_group_data, listOf(
        Destination.FusedRecord, Destination.AppleHealth, Destination.DataSources,
        Destination.NoopPlus, Destination.BackupSync,
    ), defaultExpanded = false),
    DrawerGroup("App", R.string.more_group_app, listOf(
        Destination.Safety, Destination.SmartAlarm, Destination.Automations, Destination.Notifications,
        Destination.Updates, Destination.TestCentre, Destination.Settings,
    ), defaultExpanded = false),
)

/** The headers open by default at first run, derived from [drawerGroups.defaultExpanded] (Insights +
 *  Body), so the seed lives in one place and the persistence default can't drift from the UI default. */
private fun defaultExpandedHeaders(): Set<String> =
    drawerGroups.filter { it.defaultExpanded }.map { it.header }.toSet()

/**
 * Persisted open/closed state of the More page's collapsible groups (#860 item 2) - the Android twin of
 * the iOS `MoreSectionPrefs`. The set of EXPANDED group headers is stored as one sorted comma-joined
 * string under a single SharedPreferences key, encoded identically to iOS (same `more.expandedSections`
 * suffix, same CSV-of-headers, same Insights+Body default) so the two platforms behave the same. An empty
 * stored string is a valid state (everything collapsed), distinct from "never set" (which yields the seed).
 */
internal object MoreSectionPrefs {
    const val KEY = "noop.more.expandedSections"

    /** Read the expanded-header set; returns [default] when the key was never written (first run). */
    fun read(prefs: android.content.SharedPreferences, default: Set<String>): Set<String> {
        val raw = prefs.getString(KEY, null) ?: return default
        return decode(raw)
    }

    /** Persist the expanded-header set as a sorted, comma-joined string. */
    fun write(prefs: android.content.SharedPreferences, headers: Set<String>) {
        prefs.edit().putString(KEY, encode(headers)).apply()
    }

    /** Encode the set of expanded headers to a sorted, comma-joined string. */
    fun encode(headers: Set<String>): String = headers.sorted().joinToString(",")

    /** Decode the stored string to a set of expanded headers; blank tokens dropped, empty string -> empty set. */
    fun decode(raw: String): Set<String> =
        raw.split(",").map { it.trim() }.filter { it.isNotEmpty() }.toSet()
}

/**
 * App shell: a single [Scaffold] with a floating [GlassBottomBar] (Today · Trends · Workouts · Sleep · More)
 * driving one [NavHost], mirroring the iOS RootTabView. There is NO global toolbar and no nav drawer
 * - every screen self-titles via [ScreenScaffold], and the "More" sheet (opened from the bar) reaches
 * every destination in [drawerGroups], so nothing is lost. A single [AppViewModel] is created here and
 * shared with every screen, so the BLE connection and cached metrics stay app-wide singletons.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    viewModel: AppViewModel = viewModel(),
    initialRoute: String? = null,
) {
    val nav = rememberNavController()
    val startRoute = remember(initialRoute) {
        val requested = initialRoute?.trim()?.lowercase()
        Destination.entries.firstOrNull { destination ->
            destination.route == requested && !destination.route.contains('{')
        }?.route ?: Destination.Today.route
    }

    val backStack by nav.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    var selectedTabRoute by rememberSaveable(startRoute) {
        mutableStateOf(primaryTabForRoute(startRoute).route)
    }
    val selectedTab = Destination.forRoute(selectedTabRoute)
    var showQuickActions by remember { mutableStateOf(false) }
    val demoStrengthGuideExerciseId = remember(initialRoute) {
        initialRoute
            ?.takeIf { BuildConfig.DEBUG && it.startsWith("strength-guide:") }
            ?.substringAfter(':')
            ?.takeIf { it.isNotBlank() }
    }
    var quickOverlay by remember(initialRoute) {
        mutableStateOf<QuickActionKind?>(
            if (
                BuildConfig.DEBUG &&
                (initialRoute == "strength" || demoStrengthGuideExerciseId != null)
            ) {
                QuickActionKind.STRENGTH
            } else {
                null
            },
        )
    }
    // The Updates inbox sheet (opened by the Today header bell). The store is a process singleton so
    // the Today cards and the import path post to the same inbox this sheet renders.
    val context = androidx.compose.ui.platform.LocalContext.current
    val updateStore = remember { UpdateStore.from(context) }
    var showUpdatesInbox by remember { mutableStateOf(false) }
    val contextualActions by ContextualActionCenter.actions.collectAsStateWithLifecycle()
    val contextualProcessingIds by ContextualActionCenter.processingIds.collectAsStateWithLifecycle()
    var expandedContextualActionId by rememberSaveable { mutableStateOf<String?>(null) }
    var hydrationConfirmationMl by remember { mutableIntStateOf(0) }
    val contextualActionScope = rememberCoroutineScope()
    val density = LocalDensity.current
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0

    fun openTopLevel(route: String) {
        selectedTabRoute = primaryTabForRoute(route).route
        if (route != currentRoute) nav.navigateTopLevel(route)
    }

    fun performContextualAction(action: ContextualAction) {
        when (action.kind) {
            ContextualActionKind.HYDRATION -> {
                if (!ContextualActionCenter.begin(context, action)) return
                contextualActionScope.launch {
                    val amount = action.amountMl ?: 250
                    val succeeded = runCatching {
                        HydrationStore.log(viewModel.repo, amount)
                    }.isSuccess
                    ContextualActionCenter.finish(context, action, succeeded)
                    if (!succeeded) return@launch
                    expandedContextualActionId = null
                    hydrationConfirmationMl = amount
                    delay(1_350L)
                    hydrationConfirmationMl = 0
                }
            }
            ContextualActionKind.BREATHE -> {
                ContextualActionCenter.complete(context, action)
                expandedContextualActionId = null
                openTopLevel(Destination.Breathe.route)
            }
            ContextualActionKind.JOURNAL -> {
                ContextualActionCenter.complete(context, action)
                expandedContextualActionId = null
                openTopLevel(Destination.Insights.route)
            }
            ContextualActionKind.WIND_DOWN,
            ContextualActionKind.RECOVERY,
            -> {
                ContextualActionCenter.complete(context, action)
                expandedContextualActionId = null
                openTopLevel(Destination.Sleep.route)
            }
        }
    }

    LaunchedEffect(context, initialRoute) {
        ContextualActionCenter.refresh(context)
        if (BuildConfig.DEBUG && initialRoute == "context-actions") {
            ContextualActionCenter.applyDemoActions(context)
        }
    }

    // System Back can leave a top-level destination and reveal a different tab root. Keep the persistent
    // selection synchronized only for exact roots; a nested route deliberately retains its owning tab.
    LaunchedEffect(currentRoute) {
        com.noop.AppDiagnosticsRecorder.setScreen(currentRoute)
        Destination.entries
            .firstOrNull { it.route == currentRoute && it in primaryTabDestinations }
            ?.let { selectedTabRoute = it.route }
    }

    // Notification route bridge: StateFlow emits immediately, so this consumes a cold-launch route that
    // arrived before AppRoot mounted; later emissions handle warm SINGLE_TOP taps. Only trusted top-level
    // routes can enter the bridge, and consumePending removes each request before navigation.
    LaunchedEffect(nav, context) {
        NotificationRouteBridge.routeRequests.collect {
            NotificationRouteBridge.consumePending(context)?.let { route ->
                openTopLevel(route.navRoute)
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = Palette.surfaceBase,
            bottomBar = {
                // One translucent navigation island plus a separate persistent quick-add circle. The
                // action stays reachable from every tab without crowding a page-specific header.
                GlassBottomBar(
                    selected = selectedTab,
                    onTabSelected = { dest ->
                        val reselected = selectedTabRoute == dest.route
                        selectedTabRoute = dest.route
                        if (reselected) {
                            nav.returnToTabRoot(dest.route)
                        } else if (dest.route != currentRoute) {
                            nav.navigateTopLevel(dest.route)
                        }
                    },
                    onQuickActions = { showQuickActions = true },
                )
            },
        ) { inner ->
            NavHost(
                navController = nav,
                startDestination = startRoute,
                modifier = Modifier.padding(inner),
                // README motion: top-level destinations crossfade (~240ms) on the calm,
                // decelerating global easing — nothing slides or bounces between tabs. The
                // same fade is used for back (pop) so the bar never feels jerky. Drill-ins
                // (e.g. vital_detail) are pushed by the same NavHost, so they inherit the
                // same restrained crossfade rather than a hard cut.
                enterTransition = { fadeIn(navFadeSpec) },
                exitTransition = { fadeOut(navFadeSpec) },
                popEnterTransition = { fadeIn(navFadeSpec) },
                popExitTransition = { fadeOut(navFadeSpec) },
            ) {
                // --- Live, working screens (existing waves) ---
                composable(Destination.Today.route) {
                    TodayScreen(
                        viewModel = viewModel,
                        // The Updates "ringer" - the bell sits before the +, and opens the inbox
                        // sheet AppRoot presents (it owns the nav for deep-links).
                        updateStore = updateStore,
                        onOpenUpdates = { showUpdatesInbox = true },
                        // The leading profile avatar opens Settings (where the photo is set/changed),
                        // mirroring iOS's avatar-leading Today header. The drawer hamburger is unchanged.
                        onOpenSettings = { openTopLevel(Destination.Settings.route) },
                        // The opt-in Hydration card (only shown when Hydration tracking is on) pushes its
                        // detail. A normal push so the back-stack returns to Today.
                        onOpenHydration = { nav.navigate(Destination.Hydration.route) },
                        // #706/#684: the dashboard cards draw a tappable chevron; wire each to its detail,
                        // matching iOS. Stress + the vitals are pushes; Sleep is a top-level tab switch.
                        onOpenStress = { nav.navigate(Destination.Stress.route) },
                        onOpenHealth = { nav.navigate(Destination.Health.route) },
                        // Every metric/vital card opens its OWN focused detail trend (vital_detail/<key>),
                        // not the shared Health hub (2026-07-03). Mirrors the iOS liquidCard metricDetail.
                        onOpenMetric = { key -> nav.navigate("vital_detail/$key") },
                        onOpenSleep = { openTopLevel(Destination.Sleep.route) },
                        // Optional Coupled view card (task #43): a normal push so back returns to Today.
                        onOpenCoupled = { nav.navigate(Destination.CoupledView.route) },
                        // The "workout in progress" indicator: raise the one-shot the Live screen consumes to
                        // re-open the in-exercise overlay, then route to Live. One tap from Today (iOS parity).
                        onOpenActiveWorkout = {
                            viewModel.openActiveWorkout()
                            nav.navigate(Destination.Live.route)
                        },
                        // The liquid header's strap battery ring taps through to Devices (iOS parity: the
                        // battery ring → router.openDevices()).
                        onOpenDevices = { openTopLevel(Destination.Devices.route) },
                        // #627: the journal-reminder card opens the journal (hosted in Insights), same
                        // destination the Sleep screen's morning sheet uses.
                        onOpenJournal = { openTopLevel(Destination.Insights.route) },
                        onOpenCalendar = { nav.navigate(Destination.Calendar.route) },
                        demoPlannedWorkout =
                            BuildConfig.DEBUG && initialRoute == DEMO_PLANNED_WORKOUT_ROUTE,
                    )
                }
                composable(Destination.Calendar.route) {
                    CalendarMonthScreen(vm = viewModel)
                }
                composable(Destination.Live.route) {
                    LiveScreen(
                        viewModel = viewModel,
                        onManageDevices = { openTopLevel(Destination.Devices.route) },
                    )
                }
                composable(Destination.Sleep.route) {
                    SleepScreen(vm = viewModel)
                }
                composable(Destination.CoupledView.route) {
                    CoupledScreen(
                        vm = viewModel,
                        // Tapping Sleep in the coupled read opens the full Sleep screen (iOS parity).
                        onOpenSleep = { openTopLevel(Destination.Sleep.route) },
                    )
                }
                composable(Destination.Intervals.route) { IntervalsScreen(viewModel) }
                composable(Destination.Breathe.route) { BreatheScreen(viewModel) }
                composable(Destination.Coach.route) { CoachScreen() }
                composable(Destination.Explore.route) { TrendsExploreScreen(viewModel) }
                composable(Destination.Automations.route) { AutomationsScreen(viewModel) }
                composable(Destination.SmartAlarm.route) { SmartAlarmScreen(viewModel) }
                composable(Destination.Safety.route) { SafetyCenterScreen() }
                composable(Destination.Workouts.route) { WorkoutsScreen(viewModel) }
                composable(Destination.Nutrition.route) { NutritionLogScreen(viewModel) }
                composable(Destination.Intelligence.route) { IntelligenceScreen(viewModel) }

                // --- Placeholder routes (later waves fill these in) ---
                composable(Destination.Stress.route) {
                    StressScreen(
                        vm = viewModel,
                        onBreathe = { openTopLevel(Destination.Breathe.route) },
                    )
                }
                composable(Destination.Trends.route) { TrendsScreen(viewModel) }
                composable(Destination.Insights.route) { InsightsScreen(viewModel, onOpenInsightsHub = { openTopLevel(Destination.InsightsHub.route) }) }
                composable(Destination.Compare.route) { CompareScreen(viewModel) }
                composable(Destination.Health.route) {
                    HealthScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                        onOpenLabBook = { openTopLevel(Destination.LabBook.route) },
                        onOpenFusedRecord = { openTopLevel(Destination.FusedRecord.route) },
                    )
                }
                composable(Destination.Friends.route) {
                    FriendsScreen(
                        onOpenBackupSync = {
                            openTopLevel(Destination.BackupSync.route)
                        },
                    )
                }
                composable(Destination.Hydration.route) { HydrationScreen(viewModel) }
                composable(Destination.VitalSigns.route) {
                    VitalSignsScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                    )
                }
                composable(Destination.VitalSignsDetail.route) { backStackEntry ->
                    VitalDetailScreen(
                        vm = viewModel,
                        key = backStackEntry.arguments?.getString("key").orEmpty(),
                    )
                }
                // --- v5 pillar screens (Wave 3 wiring) ---
                composable(Destination.InsightsHub.route) { InsightsHubScreen(viewModel) }
                composable(Destination.LabBook.route) { LabBookScreen(viewModel) }
                composable(Destination.Rhythm.route) {
                    // EXPERIMENTAL: computes the latest on-device night only after the screen's own
                    // consent clickwrap is accepted. Descriptive visualization only; never an alert.
                    RhythmRoute(viewModel)
                }
                composable(Destination.FusedRecord.route) { FusedRecordRoute(viewModel) }
                composable(Destination.AppleHealth.route) { AppleHealthScreen(viewModel) }
                composable(Destination.Devices.route) {
                    DevicesScreen(
                        viewModel,
                        onUseFileImport = { openTopLevel(Destination.DataSources.route) },
                    )
                }
                composable(Destination.Profile.route) {
                    SettingsScreen(
                        viewModel,
                        profileEntry = true,
                    )
                }
                composable(Destination.BandAccount.route) { OwnershipAccountScreen() }
                composable(Destination.DataSources.route) { DataSourcesScreen(viewModel) }
                composable(Destination.NoopPlus.route) { NoopPlusScreen() }
                composable(Destination.BackupSync.route) { BackupSyncScreen() }
                composable(Destination.Notifications.route) { NotificationsSettingsScreen(viewModel) }
                composable(Destination.Updates.route) {
                    WhatsNewSheet(
                        onClose = { nav.popBackStack() },
                        presentation = WhatsNewPresentation.History,
                    )
                }
                composable(Destination.Settings.route) {
                    SettingsScreen(
                        viewModel,
                        onOpenTestCentre = { nav.navigate(Destination.TestCentre.route) },
                        onOpenBackupSync = { nav.navigate(Destination.BackupSync.route) },
                    )
                }
                composable(Destination.TestCentre.route) { TestCentreScreen(viewModel) }
                // The "More" page - the iOS More tab's twin: a navigated ScreenScaffold page hosting the
                // full grouped destination list. Rows push inside More's owned stack so re-tapping More
                // can always return to this root, exactly like iOS clearing that tab's NavigationPath.
                composable(Destination.More.route) {
                    MoreScreen(onNavigate = {
                        nav.navigate(it) { launchSingleTop = true }
                    })
                }
            }
        }

        if (!keyboardVisible && contextualActions.isNotEmpty()) {
            ContextualActionRail(
                actions = contextualActions,
                processingIds = contextualProcessingIds,
                expandedId = expandedContextualActionId,
                onExpandedChange = { expandedContextualActionId = it },
                onPrimary = ::performContextualAction,
                onDismiss = { ContextualActionCenter.dismiss(context, it) },
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .navigationBarsPadding()
                    .padding(
                        end = 12.dp,
                        bottom = if (hydrationConfirmationMl > 0) 128.dp else 68.dp,
                    ),
            )
        }

        if (!keyboardVisible && hydrationConfirmationMl > 0) {
            HydrationLoggedConfirmation(
                amountMl = hydrationConfirmationMl,
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .navigationBarsPadding()
                    .padding(end = 12.dp, bottom = 68.dp),
            )
        }

        // Compact 3x3 launcher opened by the persistent floating +. Long forms still live on their
        // existing screens; this is a stable one-tap index, not a second implementation of each tool.
        if (showQuickActions) {
            ModalBottomSheet(
                onDismissRequest = { showQuickActions = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = Palette.surfaceOverlay,
                contentColor = Palette.textPrimary,
            ) {
                QuickActionLauncher(
                    unreadUpdates = updateStore.unreadCount,
                    onUpdates = {
                        showQuickActions = false
                        showUpdatesInbox = true
                    },
                    onPick = { action ->
                        showQuickActions = false
                        when (action.kind) {
                            QuickActionKind.STRENGTH,
                            QuickActionKind.HRV -> quickOverlay = action.kind
                            else -> action.route?.let { route ->
                                if (route != currentRoute) openTopLevel(route)
                            }
                        }
                    },
                )
            }
        }

        when (quickOverlay) {
            QuickActionKind.STRENGTH -> {
                StrengthTrainerSheet(
                    vm = viewModel,
                    onDismiss = { quickOverlay = null },
                    initialGuideExerciseId = demoStrengthGuideExerciseId,
                )
            }
            QuickActionKind.HRV -> {
                Dialog(
                    onDismissRequest = { quickOverlay = null },
                    properties = DialogProperties(usePlatformDefaultWidth = false),
                ) {
                    Surface(
                        modifier = Modifier.fillMaxSize(),
                        color = Palette.surfaceBase,
                    ) {
                        HrvSnapshotScreen(
                            viewModel = viewModel,
                            onClose = { quickOverlay = null },
                        )
                    }
                }
            }
            else -> Unit
        }

        // The Updates inbox (opened by the Today header bell). Presented here so it has the nav for
        // deep-links - a row's "trends" key switches the bottom tab, mirroring the iOS NavRouter route.
        if (showUpdatesInbox) {
            ModalBottomSheet(
                onDismissRequest = { showUpdatesInbox = false },
                // Open full-height (no half-pull) so it reads like the iOS Updates sheet, and use the
                // BEIGE surfaceBase so the white NoopCards POP — surfaceRaised made white cards sit on a
                // white sheet (no contrast), which is why the Android inbox looked flat vs iOS.
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = Palette.surfaceBase,
                contentColor = Palette.textPrimary,
            ) {
                UpdatesInboxScreen(
                    store = updateStore,
                    onClose = { showUpdatesInbox = false },
                    onDeepLink = { key ->
                        // Map the inbox deep-link key to a route (only known keys route). "trends" is
                        // the one real poster's target today; unknown keys just close the sheet.
                        val route = when (key) {
                            "trends" -> Destination.Trends.route
                            else -> null
                        }
                        if (route != null && route != currentRoute) openTopLevel(route)
                    },
                    onRestore = { cardId ->
                        // Flip the shared dismissed flag back off so the card reappears, and signal a
                        // mounted Today to re-read it immediately (SharedPreferences isn't reactive).
                        TodayCardDismissal.setDismissed(context, cardId, false)
                        updateStore.restoreRequest = cardId
                    },
                )
            }
        }
    }
}

// MARK: - More page
//
// The "More" tab's destination - a full navigated page (mirroring the iOS More tab's NavigationStack
// List), replacing the old pull-up ModalBottomSheet. It hosts the SAME grouped destinations
// ([drawerGroups]) inside a [ScreenScaffold], with the exact section-header + row styling the sheet
// used (uppercase [Overline] group labels, icon + label [NavigationDrawerItem] rows) — now with a
// trailing chevron so each row reads as a navigation push, matching the iOS disclosure rows. Tapping a
// row navigates top-level; there is no sheet to dismiss. The floating bottom bar stays visible because
// this is just another NavHost destination under the same Scaffold.

/** The full grouped destination list as a navigated page (the iOS More tab's twin). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MoreScreen(onNavigate: (String) -> Unit) {
    // S2 parity: each group's open/closed state, seeded from `defaultExpanded` (Insights + Body open,
    // Data + App collapsed). PERSISTED (#860 item 2): the user's open/closed choice must survive leaving
    // and re-entering the More page (and relaunch), not reset to the seed every visit. Backed by
    // [MoreSectionPrefs] (a CSV of expanded headers in SharedPreferences), mirroring the iOS
    // @AppStorage("more.expandedSections"). Seeded ONCE from the stored value so first run still shows the
    // Insights+Body default; every toggle writes through so the next visit reflects the saved state.
    val context = androidx.compose.ui.platform.LocalContext.current
    val expanded = remember {
        val stored = MoreSectionPrefs.read(NoopPrefs.of(context), defaultExpandedHeaders())
        androidx.compose.runtime.mutableStateMapOf<String, Boolean>().apply {
            drawerGroups.forEach { put(it.header, stored.contains(it.header)) }
        }
    }
    // Day-cycle sky backdrop + sky-behind-cards, the SAME two gates every other tab honours (Today /
    // Trends / Sleep / metric detail) — More was the one tab still on the flat canvas, so switching to
    // it visibly "lost" the theme. SharedPreferences isn't reactive; read once like the other tabs.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    ScreenScaffold(
        title = uiString(R.string.l10n_app_root_more_4bab2d8f),
        subtitle = "Everything else, one tap away",
        trailing = { MoreAppearanceMenu() },
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down.
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        NoopPlusEntry(onNavigate = onNavigate)
        MoreQuickAccess(onNavigate = onNavigate)

        // Mirror the iOS More page: each group is a tappable UPPERCASE overline header (with a disclosure
        // chevron) over a single grouped white NoopCard whose rows are tight (accent icon + title +
        // chevron) and separated by inset hairlines (NOT loose NavigationDrawerItems on the bare surface).
        drawerGroups.forEach { group ->
            val isOpen = expanded[group.header] ?: group.defaultExpanded
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                MoreGroupHeader(
                    title = stringResource(group.headerRes),
                    expanded = isOpen,
                    onToggle = {
                        expanded[group.header] = !isOpen
                        // Persist the new open set so the choice survives leaving + re-entering the page
                        // and relaunch (#860 item 2), mirroring the iOS @AppStorage write.
                        val open = drawerGroups.map { it.header }.filter { expanded[it] == true }.toSet()
                        MoreSectionPrefs.write(NoopPrefs.of(context), open)
                    },
                )
                if (isOpen) {
                    NoopCard(padding = 0.dp) {
                        Column(modifier = Modifier.fillMaxWidth()) {
                            group.items.forEachIndexed { i, dest ->
                                MoreRow(dest = dest, onClick = { onNavigate(dest.route) })
                                if (i < group.items.lastIndex) {
                                    HorizontalDivider(
                                        color = Palette.hairline,
                                        modifier = Modifier.padding(start = 50.dp),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** An always-visible NOOP+ door. Managed storage used to be discoverable only after expanding Data
 * and opening Backup & Sync, which also made an unavailable build look as though NOOP+ did not exist. */
@Composable
private fun NoopPlusEntry(onNavigate: (String) -> Unit) {
    val title = stringResource(R.string.managed_cloud_brand)
    NoopCard(
        modifier = Modifier
            .clickable { onNavigate(Destination.NoopPlus.route) }
            .semantics { contentDescription = title }
            .testTag("noop.more.noop_plus_entry"),
        padding = 0.dp,
        tint = Palette.accent,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(Palette.surfaceInset.copy(alpha = 0.86f))
                    .border(0.8.dp, Palette.hairline, RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Cloud,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(19.dp),
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    title,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.managed_cloud_summary),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun MoreAppearanceMenu() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val selected = AppearancePrefs.mode
    val selectedLabel = stringResource(selected.labelRes)
    val appearanceLabel = stringResource(R.string.app_appearance_accessibility)
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(
            modifier = Modifier
                .size(44.dp)
                .clip(CircleShape)
                .background(Palette.surfaceRaised.copy(alpha = 0.82f))
                .border(0.8.dp, Palette.hairlineStrong.copy(alpha = 0.78f), CircleShape)
                .clickable { expanded = true }
                .semantics {
                    contentDescription = appearanceLabel
                    stateDescription = selectedLabel
                },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                when (selected) {
                    AppearanceMode.SYSTEM -> Icons.Filled.Contrast
                    AppearanceMode.LIGHT -> Icons.Filled.LightMode
                    AppearanceMode.DARK -> Icons.Filled.DarkMode
                    AppearanceMode.BLACK -> Icons.Outlined.Circle
                },
                contentDescription = null,
                tint = Palette.textPrimary,
                modifier = Modifier.size(18.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            AppearanceMode.entries.forEach { mode ->
                DropdownMenuItem(
                    text = {
                        Text(
                            stringResource(mode.labelRes),
                            color = if (mode == selected) Palette.accent else Palette.textPrimary,
                        )
                    },
                    onClick = {
                        AppearancePrefs.set(context, mode)
                        expanded = false
                    },
                )
            }
        }
    }
}

private data class MoreQuickAccessItem(
    @StringRes val titleRes: Int,
    val icon: ImageVector,
    val route: String,
    val critical: Boolean = false,
)

private val moreQuickAccessItems = listOf(
    MoreQuickAccessItem(R.string.nav_safety, Icons.Filled.Shield, Destination.Safety.route, critical = true),
    MoreQuickAccessItem(
        R.string.l10n_settings_screen_profile_ff4fc027,
        Icons.Filled.AccountCircle,
        Destination.Profile.route,
    ),
    MoreQuickAccessItem(R.string.nav_devices, Icons.Filled.Watch, Destination.Devices.route),
    MoreQuickAccessItem(R.string.nav_friends, Icons.Filled.People, Destination.Friends.route),
)

/** Same two-column shortcut rail as iOS More. Safety is the only status-colored shortcut on either
 * platform; every other icon remains neutral navigation chrome. */
@Composable
private fun MoreQuickAccess(onNavigate: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("Quick Access", modifier = Modifier.weight(1f), color = Palette.textSecondary)
            Text(
                stringResource(R.string.more_everyday_tools),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
        moreQuickAccessItems.chunked(2).forEach { pair ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                pair.forEach { item ->
                    val title = stringResource(item.titleRes)
                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .height(58.dp)
                            .clip(RoundedCornerShape(16.dp))
                            .background(Palette.surfaceRaised.copy(alpha = 0.92f))
                            .border(
                                0.8.dp,
                                Palette.hairlineStrong.copy(alpha = 0.8f),
                                RoundedCornerShape(16.dp),
                            )
                            .clickable { onNavigate(item.route) }
                            .padding(horizontal = 13.dp)
                            .semantics {
                                contentDescription = title
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(11.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(34.dp)
                                .clip(RoundedCornerShape(10.dp))
                                .background(Palette.surfaceInset.copy(alpha = 0.86f))
                                .border(0.8.dp, Palette.hairline, RoundedCornerShape(10.dp)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                item.icon,
                                contentDescription = null,
                                tint = if (item.critical) Palette.statusCritical else Palette.textPrimary,
                                modifier = Modifier.size(17.dp),
                            )
                        }
                        Text(
                            title,
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

/** A tappable group header for the More page (S2): the same UPPERCASE [Overline] label as before, now
 *  with a trailing chevron that rotates between open (0deg) and closed (-90deg), mirroring the iOS
 *  collapsible More sections. Tapping toggles the group; the whole row is the tap target. */
@Composable
private fun MoreGroupHeader(title: String, expanded: Boolean, onToggle: () -> Unit) {
    val rotation by animateFloatAsState(
        targetValue = if (expanded) 0f else -90f,
        animationSpec = tween(durationMillis = 240, easing = NavEasing),
        label = uiString(R.string.l10n_app_root_moregroupchevron_b2b36ec6),
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onToggle)
            .semantics {
                contentDescription = title
                stateDescription = if (expanded) "Expanded" else "Collapsed"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Overline(title, modifier = Modifier.weight(1f), color = Palette.textTertiary)
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier
                .size(Metrics.iconSmall)
                .rotate(rotation),
        )
    }
}

/** One tappable destination row in the More page — accent icon + title + trailing chevron in a
 *  comfortable tap target, mirroring the iOS MoreRow. */
@Composable
private fun MoreRow(dest: Destination, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("noop.more.${dest.route}")
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(Palette.surfaceInset.copy(alpha = 0.86f))
                .border(0.8.dp, Palette.hairline, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                dest.icon,
                contentDescription = null,
                tint = if (dest == Destination.Safety) Palette.statusCritical else Palette.textPrimary,
                modifier = Modifier.size(17.dp),
            )
        }
        Spacer(Modifier.width(14.dp))
        Text(stringResource(dest.titleRes), style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
    }
}

// MARK: - Glass bottom bar
//
// The signature shell is one translucent five-tab island plus a separate circular quick-add control.
// Both float over the page, preserving the user's requested glass treatment without turning the entire
// navigation-safe area into an opaque slab.

/** A single bottom-bar nav slot: the destination it switches to, plus the bar-specific icon/label. */
private data class BarTab(val dest: Destination, val icon: ImageVector, @StringRes val labelRes: Int)

/** The nav slots in iOS order. More is appended at the call site because its selected
 * state also represents destinations reached through the complete index. */
private val barLeadingTabs = listOf(
    BarTab(Destination.Today, Icons.Outlined.GridView, R.string.nav_today),
    // chart.line.uptrend.xyaxis on iOS — the rising-trend glyph, not a flat bar chart.
    BarTab(Destination.Trends, Icons.AutoMirrored.Filled.TrendingUp, R.string.nav_trends),
    BarTab(Destination.Workouts, Icons.AutoMirrored.Filled.DirectionsRun, R.string.nav_workouts),
)
private val barTrailingTabs = listOf(
    BarTab(Destination.Sleep, Icons.Filled.Bed, R.string.nav_sleep),
)

internal fun bottomBarShowsVisualLabels(
    fontScale: Float,
    availableSlotWidthPx: Int = Int.MAX_VALUE,
    widestLabelWidthPx: Int = 0,
    horizontalSafetyPaddingPx: Int = 0,
): Boolean = fontScale <= 1.30f &&
    widestLabelWidthPx + horizontalSafetyPaddingPx <= availableSlotWidthPx

@Composable
internal fun rememberBottomBarShowsVisualLabels(
    labels: List<String>,
    availableWidth: Dp,
    horizontalContentPadding: Dp = 0.dp,
    interItemSpacing: Dp = 0.dp,
    labelHorizontalSafetyPadding: Dp = 6.dp,
    labelFontSize: TextUnit = 10.sp,
): Boolean {
    if (labels.isEmpty()) return false

    val density = LocalDensity.current
    val textMeasurer = rememberTextMeasurer(cacheSize = labels.size * 2)
    val labelStyle = NoopType.footnote.copy(
        fontSize = labelFontSize,
        fontWeight = FontWeight.SemiBold,
    )
    val usableWidth = (availableWidth - horizontalContentPadding - interItemSpacing)
        .coerceAtLeast(0.dp)
    val availableSlotWidthPx = with(density) {
        (usableWidth.value / labels.size).dp.roundToPx()
    }
    val widestLabelWidthPx = labels.maxOf { label ->
        textMeasurer.measure(
            text = label,
            style = labelStyle,
            softWrap = false,
            maxLines = 1,
        ).size.width
    }
    val horizontalSafetyPaddingPx = with(density) {
        labelHorizontalSafetyPadding.roundToPx()
    }

    return bottomBarShowsVisualLabels(
        fontScale = density.fontScale,
        availableSlotWidthPx = availableSlotWidthPx,
        widestLabelWidthPx = widestLabelWidthPx,
        horizontalSafetyPaddingPx = horizontalSafetyPaddingPx,
    )
}

@Composable
private fun GlassBottomBar(
    selected: Destination,
    onTabSelected: (Destination) -> Unit,
    onQuickActions: () -> Unit,
) {
    val barShape = RoundedCornerShape(50)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 12.dp)
            .padding(top = 4.dp, bottom = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 548.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .height(48.dp)
                    .navigationGlassSurface(barShape),
            ) {
                val tabLabels = buildList {
                    barLeadingTabs.forEach { add(stringResource(it.labelRes)) }
                    barTrailingTabs.forEach { add(stringResource(it.labelRes)) }
                    add(stringResource(R.string.nav_more))
                }
                val showVisualLabels = rememberBottomBarShowsVisualLabels(
                    labels = tabLabels,
                    availableWidth = maxWidth,
                    horizontalContentPadding = 12.dp,
                    interItemSpacing = 4.dp,
                )
                Row(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(1.dp),
                ) {
                    barLeadingTabs.forEach { tab ->
                        BarSlot(
                            icon = tab.icon,
                            label = stringResource(tab.labelRes),
                            active = selected == tab.dest,
                            testTag = "noop.tab.${tab.dest.route}",
                            showLabel = showVisualLabels,
                            modifier = Modifier.weight(1f),
                            onClick = { onTabSelected(tab.dest) },
                        )
                    }
                    barTrailingTabs.forEach { tab ->
                        BarSlot(
                            icon = tab.icon,
                            label = stringResource(tab.labelRes),
                            active = selected == tab.dest,
                            testTag = "noop.tab.${tab.dest.route}",
                            showLabel = showVisualLabels,
                            modifier = Modifier.weight(1f),
                            onClick = { onTabSelected(tab.dest) },
                        )
                    }
                    BarSlot(
                        icon = Icons.Filled.MoreHoriz,
                        label = stringResource(R.string.nav_more),
                        active = selected == Destination.More,
                        testTag = "noop.tab.more",
                        showLabel = showVisualLabels,
                        modifier = Modifier.weight(1f),
                        onClick = { onTabSelected(Destination.More) },
                    )
                }
            }
            FloatingQuickAddButton(onClick = onQuickActions)
        }
    }
}

@Composable
private fun FloatingQuickAddButton(onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val quickActionsLabel = stringResource(
        R.string.l10n_today_screen_quick_actions_e47e8042,
    )
    Box(
        modifier = Modifier
            .size(48.dp)
            .testTag("noop.quick-actions")
            .navigationGlassSurface(
                shape = CircleShape,
                accentRim = if (Palette.isLight) {
                    Color.Black.copy(alpha = 0.10f)
                } else {
                    Palette.chargeColor.copy(alpha = 0.46f)
                },
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = quickActionsLabel },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Add,
            contentDescription = null,
            tint = if (Palette.isLight) {
                Color.Black.copy(alpha = 0.90f)
            } else {
                Palette.chargeColor
            },
            modifier = Modifier.size(20.dp),
        )
    }
}

/**
 * Static Android counterpart to iOS navigation glass. The fixed smoke, specular and lower-rim
 * layers keep the rail lens-like without adding a render effect to every content scroll frame.
 */
internal fun Modifier.navigationGlassSurface(
    shape: androidx.compose.ui.graphics.Shape,
    accentRim: Color? = null,
): Modifier = composed {
    val light = Palette.isLight
    val base = if (light) {
        Color.White.copy(alpha = 0.72f)
    } else {
        Palette.surfaceRaised.copy(alpha = 0.72f)
    }
    val smoke = if (light) {
        Color.Black.copy(alpha = 0.025f)
    } else {
        Color.Black.copy(alpha = 0.13f)
    }
    val topSpecular = if (light) {
        Color.White.copy(alpha = 0.62f)
    } else {
        Color.White.copy(alpha = 0.12f)
    }
    val midSpecular = if (light) {
        Color.White.copy(alpha = 0.15f)
    } else {
        Color.White.copy(alpha = 0.025f)
    }
    val lowerShade = if (light) {
        Color.Black.copy(alpha = 0.055f)
    } else {
        Color.Black.copy(alpha = 0.18f)
    }
    val rimTop = accentRim ?: if (light) {
        Color.White.copy(alpha = 0.52f)
    } else {
        Color.White.copy(alpha = 0.12f)
    }
    val rimBottom = if (light) {
        Color.Black.copy(alpha = 0.07f)
    } else {
        Color.Black.copy(alpha = 0.20f)
    }

    this
        .shadow(
            elevation = if (light) 8.dp else 11.dp,
            shape = shape,
            clip = false,
        )
        .clip(shape)
        .drawWithCache {
            val radius = CornerRadius(size.minDimension / 2f)
            val body = Brush.verticalGradient(
                colorStops = arrayOf(
                    0f to topSpecular,
                    0.20f to midSpecular,
                    0.52f to base,
                    1f to lowerShade,
                ),
            )
            val diagonalGlint = Brush.linearGradient(
                colors = listOf(
                    Color.White.copy(alpha = if (light) 0.20f else 0.055f),
                    Color.Transparent,
                    Color.Black.copy(alpha = if (light) 0.02f else 0.08f),
                ),
                start = Offset.Zero,
                end = Offset(size.width, size.height),
            )
            val rim = Brush.verticalGradient(
                colors = listOf(rimTop, midSpecular, rimBottom),
            )
            onDrawBehind {
                drawRoundRect(color = base, cornerRadius = radius)
                drawRoundRect(color = smoke, cornerRadius = radius)
                drawRoundRect(brush = body, cornerRadius = radius)
                drawRoundRect(brush = diagonalGlint, cornerRadius = radius)
                drawRoundRect(
                    brush = rim,
                    cornerRadius = radius,
                    style = Stroke(width = 0.7.dp.toPx()),
                )
            }
        }
}

/** One nav slot: an icon over a small label. Active = gold accent (semibold), inactive = textSecondary.
 *  The selected capsule and green ink mirror iOS's expanded FloatingTabBar. */
@Composable
private fun BarSlot(
    icon: ImageVector,
    label: String,
    active: Boolean,
    testTag: String,
    showLabel: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tint = if (active) Palette.chargeColor else Palette.textSecondary
    val shape = RoundedCornerShape(50)
    val selectedTabLiftLabel = stringResource(R.string.nav_selected_tab_animation_label)
    val selectedScale by animateFloatAsState(
        targetValue = if (active) 1.08f else 1f,
        animationSpec = tween(durationMillis = 260, easing = NavEasing),
        label = selectedTabLiftLabel,
    )
    Column(
        modifier = modifier
            .height(44.dp)
            .testTag(testTag)
            .clip(shape)
            .background(
                if (active) Palette.textPrimary.copy(alpha = 0.15f) else Color.Transparent,
                shape,
            )
            .then(
                if (active) {
                    Modifier.border(
                        0.6.dp,
                        Palette.textPrimary.copy(alpha = 0.11f),
                        shape,
                    )
                } else {
                    Modifier
                },
            )
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            )
            .padding(vertical = 3.dp)
            .semantics {
                contentDescription = label
                selected = active
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier
                .size(if (showLabel) Metrics.iconSmall else 22.dp)
                .graphicsLayer {
                    scaleX = selectedScale
                    scaleY = selectedScale
                    translationY = if (active) -1.dp.toPx() else 0f
                },
        )
        if (showLabel) {
            Text(
                label,
                style = NoopType.footnote.copy(
                    fontSize = 10.sp,
                    fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
                ),
                color = tint,
                maxLines = 1,
            )
        }
    }
}

private enum class QuickActionKind {
    WORKOUT,
    STRENGTH,
    NUTRITION,
    JOURNAL,
    HYDRATION,
    HRV,
    BREATHE,
    INTERVALS,
    LIVE,
}

private data class QuickAction(
    val title: String,
    val icon: ImageVector,
    val kind: QuickActionKind,
    val route: String? = null,
)

private val quickActions: List<QuickAction> = listOf(
    QuickAction("Workout", Icons.AutoMirrored.Filled.DirectionsRun, QuickActionKind.WORKOUT, Destination.Workouts.route),
    QuickAction("Strength", Icons.Filled.FitnessCenter, QuickActionKind.STRENGTH),
    QuickAction("Meal", Icons.Filled.Restaurant, QuickActionKind.NUTRITION, Destination.Nutrition.route),
    QuickAction("Journal", Icons.Filled.Edit, QuickActionKind.JOURNAL, Destination.Insights.route),
    QuickAction("Hydration", Icons.Filled.WaterDrop, QuickActionKind.HYDRATION, Destination.Hydration.route),
    QuickAction("HRV", Icons.Filled.MonitorHeart, QuickActionKind.HRV),
    QuickAction("Breathe", Icons.Filled.Air, QuickActionKind.BREATHE, Destination.Breathe.route),
    QuickAction("Intervals", Icons.Filled.Timeline, QuickActionKind.INTERVALS, Destination.Intervals.route),
    QuickAction("Live HR", Icons.Filled.FavoriteBorder, QuickActionKind.LIVE, Destination.Live.route),
)

@Composable
private fun QuickActionLauncher(
    unreadUpdates: Int,
    onUpdates: () -> Unit,
    onPick: (QuickAction) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("Quick actions", color = Palette.textTertiary)
            Spacer(Modifier.weight(1f))
            UpdatesLauncherButton(unreadUpdates = unreadUpdates, onClick = onUpdates)
        }
        quickActions.chunked(3).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                row.forEach { action ->
                    QuickActionTile(
                        action = action,
                        modifier = Modifier.weight(1f),
                        onClick = { onPick(action) },
                    )
                }
            }
        }
    }
}

@Composable
private fun QuickActionTile(
    action: QuickAction,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tint = when (action.kind) {
        QuickActionKind.WORKOUT -> Palette.effortColor
        QuickActionKind.STRENGTH -> Palette.metricPurple
        QuickActionKind.NUTRITION -> Palette.statusPositive
        QuickActionKind.JOURNAL -> Palette.accent
        QuickActionKind.HYDRATION -> Palette.metricCyan
        QuickActionKind.HRV, QuickActionKind.LIVE -> Palette.metricRose
        QuickActionKind.BREATHE -> Palette.restColor
        QuickActionKind.INTERVALS -> Palette.statusWarning
    }
    Column(
        modifier = modifier
            .height(88.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .semantics { contentDescription = action.title },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .clip(CircleShape)
                .background(Palette.surfaceInset)
                .border(0.8.dp, Palette.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                action.icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(20.dp),
            )
        }
        Spacer(Modifier.height(7.dp))
        Text(
            action.title,
            style = NoopType.footnote.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun UpdatesLauncherButton(unreadUpdates: Int, onClick: () -> Unit) {
    val updatesLabel = stringResource(R.string.l10n_app_root_updates_c76d1807)
    val unreadUpdatesLabel = stringResource(
        R.string.appwide_shell_updates_unread_format,
        unreadUpdates,
    )
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .semantics {
                contentDescription = if (unreadUpdates > 0) {
                    unreadUpdatesLabel
                } else {
                    updatesLabel
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            Icons.Filled.Notifications,
            contentDescription = null,
            tint = Palette.textSecondary,
            modifier = Modifier.size(21.dp),
        )
        if (unreadUpdates > 0) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(18.dp)
                    .clip(CircleShape)
                    .background(Palette.statusCritical),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (unreadUpdates > 9) "9+" else unreadUpdates.toString(),
                    style = NoopType.captionNumber.copy(fontSize = 9.sp),
                    color = Color.White,
                    maxLines = 1,
                )
            }
        }
    }
}

// MARK: - Navigation motion (README §Motion)
//
// The global easing is the calm, decelerating cubic-bezier(0.22, 1, 0.36, 1) — nothing
// bounces or overshoots. Top-level destination switches crossfade over ~240ms (README
// "Tab crossfade"); the same spec drives back navigation so the bar never feels jerky.

/** The calm global easing curve from the handoff (cubic-bezier 0.22, 1, 0.36, 1). */
private val NavEasing = CubicBezierEasing(0.22f, 1f, 0.36f, 1f)

/** ~240ms crossfade on the calm easing - the README "Tab crossfade" between roots. */
private val navFadeSpec = tween<Float>(durationMillis = 240, easing = NavEasing)

/** Canonical NOOP monogram: the same geometric NO / OP obsidian tile used by iOS. */
@Composable
internal fun BrandMark(size: Dp = 22.dp) {
    Canvas(
        modifier = Modifier
            .size(size)
            .semantics { contentDescription = "NOOP" },
    ) {
        val edge = this.size.minDimension
        val ox = (this.size.width - edge) / 2f
        val oy = (this.size.height - edge) / 2f
        fun x(fraction: Float) = ox + edge * fraction
        fun y(fraction: Float) = oy + edge * fraction
        val tile = Color(0xFF050505)
        val letter = Color(0xFFF4F1EA)
        val radius = edge * 0.235f
        val rim = maxOf(0.5.dp.toPx(), edge * 0.006f)

        drawRoundRect(
            color = tile,
            topLeft = Offset(ox, oy),
            size = Size(edge, edge),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
        )
        drawRoundRect(
            color = Color.White.copy(alpha = 0.10f),
            topLeft = Offset(ox, oy),
            size = Size(edge, edge),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
            style = Stroke(width = rim),
        )

        val monogram = Path().apply {
            fillType = PathFillType.EvenOdd

            moveTo(x(0.210f), y(0.205f))
            lineTo(x(0.305f), y(0.205f))
            lineTo(x(0.405f), y(0.340f))
            lineTo(x(0.405f), y(0.205f))
            lineTo(x(0.490f), y(0.205f))
            lineTo(x(0.490f), y(0.490f))
            lineTo(x(0.397f), y(0.490f))
            lineTo(x(0.303f), y(0.358f))
            lineTo(x(0.303f), y(0.490f))
            lineTo(x(0.210f), y(0.490f))
            close()

            addOval(Rect(x(0.515f), y(0.200f), x(0.810f), y(0.492f)))
            addOval(Rect(x(0.604f), y(0.287f), x(0.721f), y(0.408f)))
            addOval(Rect(x(0.207f), y(0.500f), x(0.503f), y(0.787f)))
            addOval(Rect(x(0.296f), y(0.579f), x(0.415f), y(0.707f)))

            moveTo(x(0.516f), y(0.505f))
            lineTo(x(0.680f), y(0.505f))
            cubicTo(x(0.756f), y(0.505f), x(0.802f), y(0.546f), x(0.802f), y(0.608f))
            cubicTo(x(0.802f), y(0.670f), x(0.756f), y(0.711f), x(0.680f), y(0.711f))
            lineTo(x(0.614f), y(0.711f))
            lineTo(x(0.614f), y(0.780f))
            lineTo(x(0.516f), y(0.780f))
            close()

            moveTo(x(0.614f), y(0.576f))
            lineTo(x(0.678f), y(0.576f))
            cubicTo(x(0.707f), y(0.576f), x(0.724f), y(0.589f), x(0.724f), y(0.608f))
            cubicTo(x(0.724f), y(0.627f), x(0.707f), y(0.641f), x(0.678f), y(0.641f))
            lineTo(x(0.614f), y(0.641f))
            close()
        }
        drawPath(monogram, color = letter)

        val incisionWidth = maxOf(1.dp.toPx(), edge * 0.014f)
        val incisionHeight = edge * 0.095f
        val incisionCenter = Offset(x(0.707f), y(0.253f))
        rotate(degrees = 35f, pivot = incisionCenter) {
            drawRect(
                color = tile,
                topLeft = Offset(
                    incisionCenter.x - incisionWidth / 2f,
                    incisionCenter.y - incisionHeight / 2f,
                ),
                size = Size(incisionWidth, incisionHeight),
            )
        }
    }
}

/** Navigate to a top-level destination with single-top + state save/restore. */
private fun NavHostController.navigateTopLevel(route: String) {
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

/** Re-selecting the active tab is a root command, not another state-restoring tab switch. Prefer popping
 * the live stack so the root instance survives; if the root is not live (for example a direct deep link),
 * rebuild that one root without restoring a previously saved detail destination. */
private fun NavHostController.returnToTabRoot(route: String) {
    if (currentDestination?.route == route) return
    if (popBackStack(route, inclusive = false)) return
    navigate(route) {
        popUpTo(graph.findStartDestination().id) { saveState = false }
        launchSingleTop = true
        restoreState = false
    }
}

/**
 * Loader for the v5 "Your Data, Fused" screen: assembles today's [FusedRecord] off the repository via
 * [AppViewModel.fusedRecordForToday] (the pure FusionResolver per metric) and hands the pure
 * [FusedRecordScreen] its read-model. Keeps the screen itself I/O-free + previewable. Re-loads on entry.
 */
@Composable
private fun FusedRecordRoute(viewModel: AppViewModel) {
    var record by remember {
        mutableStateOf(FusedRecord(rows = emptyList(), dayOwner = null as FusionSource?, contributingSourceCount = 0))
    }
    LaunchedEffect(Unit) {
        record = runCatching { viewModel.fusedRecordForToday() }.getOrDefault(record)
    }
    FusedRecordScreen(record = record)
}

/**
 * Placeholder screen for routes later waves will build. Uses [ScreenScaffold] so the
 * dark, instrument-grade chrome is already correct when a real screen replaces it.
 */
@Composable
fun ComingSoon(text: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        NoopCard(padding = 28.dp) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Filled.Sensors,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                )
                Spacer(Modifier.height(4.dp))
                Text(text, style = NoopType.title2, color = Palette.textPrimary, textAlign = TextAlign.Center)
                Overline("Coming soon", color = Palette.textSecondary)
                Text(
                    uiString(R.string.l10n_app_root_this_section_is_on_the_way_ca7c4a32),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}
