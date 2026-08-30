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
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.ChevronRight
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.noop.R
import com.noop.analytics.FusionSource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
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
    BackupSync("backup_sync", R.string.nav_backup_sync, Icons.Filled.CloudSync),
    FusedRecord("fused_record", R.string.nav_fused_record, Icons.AutoMirrored.Filled.CompareArrows),
    Notifications("notifications", R.string.nav_notifications, Icons.Filled.Notifications),
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
        Destination.Profile, Destination.Friends, Destination.Devices, Destination.Live, Destination.Nutrition,
        Destination.Health, Destination.VitalSigns,
        Destination.LabBook, Destination.Stress, Destination.Breathe, Destination.Intervals,
        Destination.Rhythm,
    ), defaultExpanded = true),
    DrawerGroup("Data", R.string.more_group_data, listOf(
        Destination.FusedRecord, Destination.AppleHealth, Destination.DataSources,
        Destination.BackupSync,
    ), defaultExpanded = false),
    DrawerGroup("App", R.string.more_group_app, listOf(
        Destination.Safety, Destination.SmartAlarm, Destination.Automations, Destination.Notifications,
        Destination.TestCentre, Destination.Settings,
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
    val current = Destination.forRoute(currentRoute)
    var showQuickActions by remember { mutableStateOf(false) }
    var quickOverlay by remember { mutableStateOf<QuickActionKind?>(null) }
    // The Updates inbox sheet (opened by the Today header bell). The store is a process singleton so
    // the Today cards and the import path post to the same inbox this sheet renders.
    val context = androidx.compose.ui.platform.LocalContext.current
    val updateStore = remember { UpdateStore.from(context) }
    var showUpdatesInbox by remember { mutableStateOf(false) }

    // Notification route bridge: StateFlow emits immediately, so this consumes a cold-launch route that
    // arrived before AppRoot mounted; later emissions handle warm SINGLE_TOP taps. Only trusted top-level
    // routes can enter the bridge, and consumePending removes each request before navigation.
    LaunchedEffect(nav, context) {
        NotificationRouteBridge.routeRequests.collect {
            NotificationRouteBridge.consumePending(context)?.let { route ->
                nav.navigateTopLevel(route.navRoute)
            }
        }
    }

    run {
        Scaffold(
            containerColor = Palette.surfaceBase,
            bottomBar = {
                // One translucent navigation island plus a separate persistent quick-add circle. The
                // action stays reachable from every tab without crowding a page-specific header.
                GlassBottomBar(
                    current = current,
                    onTabSelected = { dest ->
                        if (dest.route != currentRoute) nav.navigateTopLevel(dest.route)
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
                        onOpenSettings = { nav.navigateTopLevel(Destination.Settings.route) },
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
                        onOpenSleep = { nav.navigateTopLevel(Destination.Sleep.route) },
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
                        onOpenDevices = { nav.navigateTopLevel(Destination.Devices.route) },
                        // #627: the journal-reminder card opens the journal (hosted in Insights), same
                        // destination the Sleep screen's morning sheet uses.
                        onOpenJournal = { nav.navigateTopLevel(Destination.Insights.route) },
                        onOpenCalendar = { nav.navigate(Destination.Calendar.route) },
                    )
                }
                composable(Destination.Calendar.route) {
                    CalendarMonthScreen(vm = viewModel)
                }
                composable(Destination.Live.route) {
                    LiveScreen(
                        viewModel = viewModel,
                        onManageDevices = { nav.navigateTopLevel(Destination.Devices.route) },
                    )
                }
                composable(Destination.Sleep.route) {
                    SleepScreen(vm = viewModel)
                }
                composable(Destination.CoupledView.route) {
                    CoupledScreen(
                        vm = viewModel,
                        // Tapping Sleep in the coupled read opens the full Sleep screen (iOS parity).
                        onOpenSleep = { nav.navigateTopLevel(Destination.Sleep.route) },
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
                        onBreathe = { nav.navigateTopLevel(Destination.Breathe.route) },
                    )
                }
                composable(Destination.Trends.route) { TrendsScreen(viewModel) }
                composable(Destination.Insights.route) { InsightsScreen(viewModel, onOpenInsightsHub = { nav.navigateTopLevel(Destination.InsightsHub.route) }) }
                composable(Destination.Compare.route) { CompareScreen(viewModel) }
                composable(Destination.Health.route) {
                    HealthScreen(
                        vm = viewModel,
                        onVitalClick = { nav.navigate("vital_detail/$it") },
                        onOpenLabBook = { nav.navigateTopLevel(Destination.LabBook.route) },
                        onOpenFusedRecord = { nav.navigateTopLevel(Destination.FusedRecord.route) },
                    )
                }
                composable(Destination.Friends.route) {
                    FriendsScreen(
                        onOpenBackupSync = {
                            nav.navigateTopLevel(Destination.BackupSync.route)
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
                        onUseFileImport = { nav.navigateTopLevel(Destination.DataSources.route) },
                    )
                }
                composable(Destination.Profile.route) {
                    SettingsScreen(
                        viewModel,
                        profileEntry = true,
                    )
                }
                composable(Destination.DataSources.route) { DataSourcesScreen(viewModel) }
                composable(Destination.BackupSync.route) { BackupSyncScreen() }
                composable(Destination.Notifications.route) { NotificationsSettingsScreen(viewModel) }
                composable(Destination.Settings.route) {
                    SettingsScreen(
                        viewModel,
                        onOpenTestCentre = { nav.navigate(Destination.TestCentre.route) },
                        onOpenBackupSync = { nav.navigate(Destination.BackupSync.route) },
                    )
                }
                composable(Destination.TestCentre.route) { TestCentreScreen(viewModel) }
                // The "More" page - the iOS More tab's twin: a navigated ScreenScaffold page hosting the
                // full grouped destination list (was a pull-up sheet). A row navigates top-level.
                composable(Destination.More.route) {
                    MoreScreen(onNavigate = { nav.navigateTopLevel(it) })
                }
            }
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
                                if (route != currentRoute) nav.navigateTopLevel(route)
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
                        if (route != null && route != currentRoute) nav.navigateTopLevel(route)
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

@Composable
private fun MoreAppearanceMenu() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val selected = AppearancePrefs.mode
    val selectedLabel = stringResource(selected.labelRes)
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
                    contentDescription = "App appearance"
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
            Text("Everyday tools", style = NoopType.caption, color = Palette.textTertiary)
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

@Composable
private fun GlassBottomBar(
    current: Destination,
    onTabSelected: (Destination) -> Unit,
    onQuickActions: () -> Unit,
) {
    val barShape = RoundedCornerShape(50)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 6.dp)
            .padding(top = 4.dp, bottom = Metrics.space12),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 548.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Surface(
                shape = barShape,
                color = Palette.surfaceRaised.copy(alpha = 0.64f),
                tonalElevation = 1.dp,
                shadowElevation = 4.dp,
                modifier = Modifier
                    .weight(1f)
                    .border(
                        0.7.dp,
                        Palette.hairlineStrong.copy(alpha = 0.58f),
                        barShape,
                    ),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 5.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(1.dp),
                ) {
                    barLeadingTabs.forEach { tab ->
                        BarSlot(
                            icon = tab.icon,
                            label = stringResource(tab.labelRes),
                            active = current == tab.dest ||
                                (tab.dest == Destination.Today && current == Destination.Calendar),
                            testTag = "noop.tab.${tab.dest.route}",
                            modifier = Modifier.weight(1f),
                            onClick = { onTabSelected(tab.dest) },
                        )
                    }
                    barTrailingTabs.forEach { tab ->
                        BarSlot(
                            icon = tab.icon,
                            label = stringResource(tab.labelRes),
                            active = current == tab.dest,
                            testTag = "noop.tab.${tab.dest.route}",
                            modifier = Modifier.weight(1f),
                            onClick = { onTabSelected(tab.dest) },
                        )
                    }
                    BarSlot(
                        icon = Icons.Filled.MoreHoriz,
                        label = stringResource(R.string.nav_more),
                        active = current != Destination.Today && current != Destination.Trends &&
                            current != Destination.Workouts && current != Destination.Sleep &&
                            current != Destination.Calendar,
                        testTag = "noop.tab.more",
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
            .size(54.dp)
            .testTag("noop.quick-actions")
            .clip(CircleShape)
            .background(Palette.surfaceRaised.copy(alpha = 0.66f))
            .border(
                0.7.dp,
                Palette.hairlineStrong.copy(alpha = 0.62f),
                CircleShape,
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
            tint = Palette.textPrimary,
            modifier = Modifier.size(22.dp),
        )
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
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val tint = if (active) Palette.chargeColor else Palette.textSecondary
    val shape = RoundedCornerShape(50)
    Column(
        modifier = modifier
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
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(Metrics.iconSmall))
        Text(
            label,
            style = NoopType.footnote.copy(
                fontSize = 10.sp,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
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

/**
 * BrandMark — the NOOP logo glyph at a small in-app size: an OPEN recovery ring (≈80%
 * arc, round caps, starting at −90° / 12 o'clock, clockwise) in the gold gradient with a
 * solid gold core dot at the centre. This is the same brand glyph the RecoveryRing hero
 * carries (the "O" of NOOP), shrunk for the top bar / drawer header so the logo reads in
 * app. CLEAN/flat per the v3 restraint brief — no bloom, no halo, just the gradient ring.
 * Token-only (gold gradient + hairline track); decorative, so it carries no content label.
 */
@Composable
internal fun BrandMark(size: Dp = 22.dp) {
    Canvas(modifier = Modifier.size(size)) {
        val stroke = this.size.minDimension * 0.13f          // ~2px-equivalent at 22dp
        val radius = (this.size.minDimension - stroke) / 2f
        val topLeft = Offset(center.x - radius, center.y - radius)
        val arcSize = Size(radius * 2f, radius * 2f)
        val capStroke = Stroke(width = stroke, cap = StrokeCap.Round)

        // Faint full-ring track (navy hairline) behind the open arc.
        drawCircle(
            color = Palette.hairline.copy(alpha = 0.5f),
            radius = radius,
            center = center,
            style = capStroke,
        )
        // Open recovery-ring arc: ~80% (288°), −90° start (12 o'clock), clockwise.
        drawArc(
            color = Palette.chargeColor,
            startAngle = -90f,
            sweepAngle = 288f,
            useCenter = false,
            topLeft = topLeft,
            size = arcSize,
            style = capStroke,
        )
        // Solid WHITE "on-device core" dot at the centre (green ring + white core - iOS parity, no gold).
        drawCircle(color = Color.White, radius = stroke * 0.62f, center = center)
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
