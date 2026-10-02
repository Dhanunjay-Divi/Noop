package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.Alarm
import androidx.compose.material.icons.filled.Apps
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
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Explore
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Hexagon
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.LightMode
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.NightsStay
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
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.outlined.Circle
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.rememberSaveable
import com.noop.BuildConfig
import com.noop.R
import com.noop.analytics.FusionSource
import com.noop.analytics.HydrationStore
import com.noop.notif.AdaptiveDayNotifier
import com.noop.notif.AdaptivePlannedWorkoutDecision
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
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
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
import kotlin.math.roundToInt

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
        Destination.Profile, Destination.Friends, Destination.Devices,
        Destination.Live, Destination.Nutrition,
        Destination.Health, Destination.VitalSigns,
        Destination.LabBook, Destination.Stress, Destination.Breathe, Destination.Intervals,
        Destination.Rhythm,
    ), defaultExpanded = true),
    DrawerGroup("Data", R.string.more_group_data, listOf(
        Destination.FusedRecord, Destination.AppleHealth, Destination.DataSources,
        Destination.NoopPlus,
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
    onRequestAppReport: () -> Unit,
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
    var showLighterWorkoutOptions by rememberSaveable { mutableStateOf(false) }
    var breathingNotificationStartRequest by remember { mutableLongStateOf(0L) }
    var showMovementBreak by rememberSaveable { mutableStateOf(false) }
    var movementBreakStartedAtMs by rememberSaveable { mutableLongStateOf(0L) }
    var movementBreakStartedRecorded by rememberSaveable { mutableStateOf(false) }
    var movementBreakTerminalOutcome by rememberSaveable { mutableStateOf<String?>(null) }
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
                NotificationRouteBridge.journalDayOffset(action.journalDay)?.let {
                    viewModel.requestJournalDay(it)
                }
                openTopLevel(Destination.Insights.route)
            }
            ContextualActionKind.WIND_DOWN -> {
                ContextualActionCenter.complete(context, action)
                expandedContextualActionId = null
                openTopLevel(Destination.Sleep.route)
            }
            ContextualActionKind.RECOVERY -> {
                if (action.isPlannedWorkoutDecision()) {
                    val fingerprint = action.fingerprint() ?: return
                    contextualActionScope.launch {
                        if (!AdaptiveDayNotifier.acknowledgePlannedWorkoutDecision(
                            context,
                            fingerprint,
                            AdaptivePlannedWorkoutDecision.REVIEW_OPTIONS,
                        )) {
                            return@launch
                        }
                        expandedContextualActionId = null
                        openTopLevel(action.resolvedRecoveryRoute().navRoute)
                        com.noop.AppDiagnosticsRecorder.record(
                            "adaptive_day.lighter_options_presented",
                            fields = mapOf("source" to "in_app"),
                        )
                        showLighterWorkoutOptions = true
                    }
                    return
                } else {
                    ContextualActionCenter.complete(context, action)
                }
                expandedContextualActionId = null
                openTopLevel(action.resolvedRecoveryRoute().navRoute)
            }
        }
    }

    fun keepCurrentWorkoutPlan(action: ContextualAction) {
        if (!action.isPlannedWorkoutDecision()) return
        val fingerprint = action.fingerprint() ?: return
        contextualActionScope.launch {
            if (AdaptiveDayNotifier.acknowledgePlannedWorkoutDecision(
                context,
                fingerprint,
                AdaptivePlannedWorkoutDecision.KEEP_CURRENT,
            )) {
                expandedContextualActionId = null
            }
        }
    }

    LaunchedEffect(context, initialRoute) {
        AdaptiveDayNotifier.recoverResolvedPlannedWorkoutDecision(context)
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
            NotificationRouteBridge.consumePendingRequest(context)?.let { request ->
                NotificationRouteBridge.journalDayOffset(request)?.let {
                    viewModel.requestJournalDay(it)
                }
                openTopLevel(request.route.navRoute)
                if (
                    request.presentation ==
                    NotificationRoutePresentation.LIGHTER_WORKOUT_OPTIONS
                ) {
                    com.noop.AppDiagnosticsRecorder.record(
                        "adaptive_day.lighter_options_presented",
                        fields = mapOf("source" to "notification"),
                    )
                    showLighterWorkoutOptions = true
                } else if (
                    request.presentation ==
                    NotificationRoutePresentation.START_BREATHING
                ) {
                    breathingNotificationStartRequest += 1L
                } else if (
                    request.presentation ==
                    NotificationRoutePresentation.LOG_HYDRATION
                ) {
                    com.noop.AppDiagnosticsRecorder.record(
                        "wellness_notification.action_started",
                        fields = mapOf(
                            "action" to "log_hydration",
                            "outcome" to "opened",
                        ),
                    )
                } else if (
                    request.presentation ==
                    NotificationRoutePresentation.MOVEMENT_BREAK
                ) {
                    movementBreakStartedAtMs = android.os.SystemClock.elapsedRealtime()
                    movementBreakStartedRecorded = false
                    movementBreakTerminalOutcome = null
                    showMovementBreak = true
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = Palette.surfaceBase,
            bottomBar = {
                // One translucent five-destination dock. The movable NOOP action lens is composed
                // separately below so it never reads as a sixth tab.
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
                        onOpenHydration = { dayKey -> nav.navigate(hydrationRoute(dayKey)) },
                        // #706/#684: the dashboard cards draw a tappable chevron; wire each to its detail,
                        // matching iOS. Stress + the vitals are pushes; Sleep is a top-level tab switch.
                        onOpenStress = { nav.navigate(Destination.Stress.route) },
                        onOpenHealth = { nav.navigate(Destination.Health.route) },
                        // Every metric/vital card opens its OWN focused detail trend (vital_detail/<key>),
                        // not the shared Health hub (2026-07-03). Mirrors the iOS liquidCard metricDetail.
                        onOpenMetric = { key -> nav.navigate("vital_detail/$key") },
                        onOpenMetricHistory = { openTopLevel(Destination.Explore.route) },
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
                composable(Destination.Breathe.route) {
                    BreatheScreen(
                        viewModel,
                        notificationStartRequest =
                            breathingNotificationStartRequest,
                        onNotificationStartConsumed = {
                            breathingNotificationStartRequest = 0L
                        },
                    )
                }
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
                    FriendsScreen()
                }
                composable(Destination.Hydration.route) {
                    HydrationScreen(
                        viewModel = viewModel,
                        dayKey = HydrationStore.dayKey(),
                    )
                }
                composable(HYDRATION_ROUTE_PATTERN) { backStackEntry ->
                    HydrationScreen(
                        viewModel = viewModel,
                        dayKey = backStackEntry.arguments?.getString(HYDRATION_DAY_ARGUMENT),
                    )
                }
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
                composable(Destination.TestCentre.route) {
                    TestCentreScreen(
                        vm = viewModel,
                        onRequestAppReport = onRequestAppReport,
                    )
                }
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

        if (!keyboardVisible && !showQuickActions) {
            MovableNoopCommandLens(
                onClick = { showQuickActions = true },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (!keyboardVisible && contextualActions.isNotEmpty()) {
            ContextualActionRail(
                actions = contextualActions,
                processingIds = contextualProcessingIds,
                expandedId = expandedContextualActionId,
                onExpandedChange = { expandedContextualActionId = it },
                onPrimary = ::performContextualAction,
                onSecondary = ::keepCurrentWorkoutPlan,
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
                NoopModalSystemBars()
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

        if (showLighterWorkoutOptions) {
            ModalBottomSheet(
                onDismissRequest = { showLighterWorkoutOptions = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                containerColor = Palette.surfaceOverlay,
                contentColor = Palette.textPrimary,
            ) {
                LighterWorkoutOptionsSheet(
                    onOpenWorkouts = {
                        showLighterWorkoutOptions = false
                        com.noop.AppDiagnosticsRecorder.record(
                            "adaptive_day.lighter_options_action",
                            fields = mapOf("destination" to "workouts"),
                        )
                        openTopLevel(Destination.Workouts.route)
                    },
                    onOpenStrength = {
                        showLighterWorkoutOptions = false
                        com.noop.AppDiagnosticsRecorder.record(
                            "adaptive_day.lighter_options_action",
                            fields = mapOf("destination" to "strength"),
                        )
                        quickOverlay = QuickActionKind.STRENGTH
                    },
                    onDismiss = { showLighterWorkoutOptions = false },
                )
            }
        }

        if (showMovementBreak) {
            fun finishMovementBreak() {
                val outcome =
                    if (
                        ActionableWellnessPolicy.movementRemainingSeconds(
                            movementBreakStartedAtMs,
                            android.os.SystemClock.elapsedRealtime(),
                        ) == 0
                    ) {
                        "completed"
                    } else {
                        "dismissed"
                    }
                if (movementBreakTerminalOutcome == null) {
                    movementBreakTerminalOutcome = outcome
                    com.noop.AppDiagnosticsRecorder.record(
                        "wellness_notification.movement_break",
                        fields = mapOf("outcome" to outcome),
                    )
                }
                showMovementBreak = false
            }
            LaunchedEffect(movementBreakStartedAtMs) {
                if (!movementBreakStartedRecorded) {
                    movementBreakStartedRecorded = true
                    com.noop.AppDiagnosticsRecorder.record(
                        "wellness_notification.movement_break",
                        fields = mapOf("outcome" to "started"),
                    )
                }
            }
            ModalBottomSheet(
                onDismissRequest = ::finishMovementBreak,
                sheetState = rememberModalBottomSheetState(
                    skipPartiallyExpanded = true,
                ),
                containerColor = Palette.surfaceOverlay,
                contentColor = Palette.textPrimary,
            ) {
                NoopModalSystemBars()
                MovementBreakSheet(
                    startedAtElapsedRealtimeMs = movementBreakStartedAtMs,
                    onDismiss = ::finishMovementBreak,
                )
            }
        }
    }
}

@Composable
private fun NoopModalSystemBars() {
    val view = LocalView.current
    val dark = !Palette.isLight
    val navigationBarColor = Palette.surfaceOverlay.toArgb()

    DisposableEffect(view, dark, navigationBarColor) {
        val window = (view.parent as? DialogWindowProvider)?.window
            ?: return@DisposableEffect onDispose {}
        val previousColor = window.navigationBarColor
        val controller = WindowCompat.getInsetsController(window, view)

        window.navigationBarColor = navigationBarColor
        controller.isAppearanceLightNavigationBars = !dark

        onDispose {
            window.navigationBarColor = previousColor
        }
    }
}

@Composable
private fun LighterWorkoutOptionsSheet(
    onOpenWorkouts: () -> Unit,
    onOpenStrength: () -> Unit,
    onDismiss: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .navigationBarsPadding()
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(
                    R.string.appwide_adaptive_day_guidance_lighter_options_title,
                ),
                style = NoopType.title2,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onDismiss) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = stringResource(R.string.appwide_action_dismiss),
                    tint = Palette.textSecondary,
                )
            }
        }
        Text(
            text = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_intro,
            ),
            style = NoopType.body,
            color = Palette.textSecondary,
        )
        LighterWorkoutOptionRow(
            icon = Icons.Filled.Bolt,
            title = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_intensity_title,
            ),
            detail = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_intensity_detail,
            ),
        )
        HorizontalDivider(color = Palette.hairline)
        LighterWorkoutOptionRow(
            icon = Icons.Filled.Timer,
            title = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_duration_title,
            ),
            detail = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_duration_detail,
            ),
        )
        HorizontalDivider(color = Palette.hairline)
        LighterWorkoutOptionRow(
            icon = Icons.Filled.Spa,
            title = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_recovery_title,
            ),
            detail = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_recovery_detail,
            ),
        )
        Text(
            text = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_disclaimer,
            ),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        NoopButton(
            text = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_open_workouts,
            ),
            leadingIcon = Icons.AutoMirrored.Filled.DirectionsRun,
            kind = NoopButtonKind.Primary,
            fullWidth = true,
            onClick = onOpenWorkouts,
        )
        NoopButton(
            text = stringResource(
                R.string.appwide_adaptive_day_guidance_lighter_options_open_strength,
            ),
            leadingIcon = Icons.Filled.FitnessCenter,
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            onClick = onOpenStrength,
        )
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun LighterWorkoutOptionRow(
    icon: ImageVector,
    title: String,
    detail: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(Palette.chargeColor.copy(alpha = 0.12f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = Palette.chargeColor,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(title, style = NoopType.headline, color = Palette.textPrimary)
            Text(detail, style = NoopType.footnote, color = Palette.textSecondary)
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
        MoreAccountDataAccess(onNavigate = onNavigate)
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

/** Account ownership and data continuity stay above the collapsible catalogue. Their destinations
 * remain unchanged; this card only removes duplicate entry points and clarifies hierarchy. */
@Composable
private fun MoreAccountDataAccess(onNavigate: (String) -> Unit) {
    NoopCard(
        modifier = Modifier.testTag("noop.more.account_data"),
        padding = 0.dp,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            MoreRow(
                dest = Destination.BandAccount,
                onClick = { onNavigate(Destination.BandAccount.route) },
            )
            HorizontalDivider(
                color = Palette.hairline,
                modifier = Modifier.padding(start = 50.dp),
            )
            MoreRow(
                dest = Destination.BackupSync,
                onClick = { onNavigate(Destination.BackupSync.route) },
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
        R.string.nav_insights,
        Icons.Filled.Insights,
        Destination.Insights.route,
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
// The signature shell is one compact translucent five-tab dock plus a separate movable action lens.
// Both float over the page, preserving the glass treatment without turning the navigation-safe area
// into an opaque slab or making an app-wide command look like a sixth destination.

/** A single bottom-bar nav slot: the destination it switches to, plus the bar-specific icon/label. */
private data class BarTab(val dest: Destination, val icon: ImageVector, @StringRes val labelRes: Int)

/** The five persistent destinations, in the same order as iOS. */
private val bottomBarTabs = listOf(
    BarTab(Destination.Today, Icons.Filled.MonitorHeart, R.string.nav_today),
    BarTab(Destination.Trends, Icons.Filled.Hub, R.string.nav_trends),
    BarTab(Destination.Workouts, Icons.Filled.FitnessCenter, R.string.nav_workouts),
    BarTab(Destination.Sleep, Icons.Filled.NightsStay, R.string.nav_sleep),
    BarTab(Destination.More, Icons.Filled.Apps, R.string.nav_more),
)

private fun bottomBarAccent(destination: Destination): Color = when (destination) {
    Destination.Today -> Palette.chargeColor
    Destination.Trends -> Palette.metricCyan
    Destination.Workouts -> Palette.metricAmber
    Destination.Sleep -> Palette.restColor
    else -> Palette.textPrimary
}

internal data class BottomBarLabelLayout(
    val maxLines: Int,
    val barHeightDp: Int,
    val labelScaleMultiplier: Float,
)

internal const val BottomBarLabelFontScaleCap = 1.30f
internal const val BottomBarLabelEffectiveScaleFloor = 0.68f
private const val BottomBarSingleLineHeightDp = 56
private const val CompactBottomBarWidthDp = 360

internal fun bottomBarLabelLayout(
    labels: List<String>,
    fontScale: Float,
    availableWidthPx: Int,
    horizontalContentPaddingPx: Int,
    interItemSpacingPx: Int,
    labelHorizontalSafetyPaddingPx: Int,
    measureLabelWidthPx: (String, Float) -> Int,
): BottomBarLabelLayout {
    val normalizedScale = fontScale.coerceAtLeast(1f)
    val cappedScaleMultiplier = minOf(
        1f,
        BottomBarLabelFontScaleCap / normalizedScale,
    )
    val minimumScaleMultiplier = minOf(
        cappedScaleMultiplier,
        BottomBarLabelEffectiveScaleFloor / normalizedScale,
    )
    val gapCount = (labels.size - 1).coerceAtLeast(0)
    val fixedWidthPx =
        (horizontalContentPaddingPx.coerceAtLeast(0) * 2) +
            (interItemSpacingPx.coerceAtLeast(0) * gapCount)
    val slotWidthPx = if (labels.isEmpty()) {
        availableWidthPx.coerceAtLeast(0).toFloat()
    } else {
        (availableWidthPx - fixedWidthPx)
            .coerceAtLeast(0)
            .toFloat() / labels.size
    }
    val singleLineLabelWidthPx = (
        slotWidthPx - (labelHorizontalSafetyPaddingPx.coerceAtLeast(0) * 2)
    ).coerceAtLeast(0f)
    val widestLabelPx = labels.maxOfOrNull { label ->
        measureLabelWidthPx(label, cappedScaleMultiplier)
    }?.toFloat() ?: 0f
    val fitMultiplier = if (
        widestLabelPx > singleLineLabelWidthPx &&
        widestLabelPx > 0f
    ) {
        cappedScaleMultiplier *
            (singleLineLabelWidthPx / widestLabelPx) *
            0.98f
    } else {
        cappedScaleMultiplier
    }
    return BottomBarLabelLayout(
        maxLines = 1,
        barHeightDp = BottomBarSingleLineHeightDp,
        labelScaleMultiplier = fitMultiplier.coerceIn(
            minimumScaleMultiplier,
            cappedScaleMultiplier,
        ),
    )
}

@Composable
internal fun rememberBottomBarLabelLayout(
    labels: List<String>,
    availableWidth: Dp,
    horizontalContentPadding: Dp = 0.dp,
    interItemSpacing: Dp = 0.dp,
    labelHorizontalSafetyPadding: Dp = 6.dp,
    labelFontSize: TextUnit = 10.sp,
): BottomBarLabelLayout {
    val density = LocalDensity.current
    val textMeasurer = rememberTextMeasurer(cacheSize = labels.size.coerceAtLeast(1))
    return bottomBarLabelLayout(
        labels = labels,
        fontScale = density.fontScale,
        availableWidthPx = with(density) { availableWidth.roundToPx() },
        horizontalContentPaddingPx = with(density) {
            horizontalContentPadding.roundToPx()
        },
        interItemSpacingPx = with(density) { interItemSpacing.roundToPx() },
        labelHorizontalSafetyPaddingPx = with(density) {
            labelHorizontalSafetyPadding.roundToPx()
        },
        measureLabelWidthPx = { label, scaleMultiplier ->
            textMeasurer.measure(
                text = label,
                style = NoopType.footnote.copy(
                    fontSize = (labelFontSize.value * scaleMultiplier).sp,
                    lineHeight = (12f * scaleMultiplier).sp,
                    fontWeight = FontWeight.SemiBold,
                ),
                softWrap = false,
                maxLines = 1,
            ).size.width
        },
    )
}

@Composable
private fun GlassBottomBar(
    selected: Destination,
    onTabSelected: (Destination) -> Unit,
) {
    val barShape = RoundedCornerShape(Metrics.navigationBarRadius)
    val barLabels = bottomBarTabs.map { stringResource(it.labelRes) }
    val reduceMotion = rememberReduceMotion()
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding(),
        contentAlignment = Alignment.Center,
    ) {
        val compactNavigation = maxWidth < CompactBottomBarWidthDp.dp
        val outerHorizontalPadding = if (compactNavigation) 8.dp else 12.dp
        val barContentPadding = if (compactNavigation) 4.dp else 7.dp
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 500.dp)
                .padding(horizontal = outerHorizontalPadding)
                .padding(top = 4.dp, bottom = 8.dp),
        ) {
            val labelLayout = rememberBottomBarLabelLayout(
                labels = barLabels,
                availableWidth = maxWidth,
                horizontalContentPadding = barContentPadding,
                interItemSpacing = 1.dp,
                labelHorizontalSafetyPadding = 1.dp,
            )
            val barHeight = labelLayout.barHeightDp.dp + Metrics.space12
            val slotWidth = (
                maxWidth - (barContentPadding * 2)
            ) / bottomBarTabs.size
            val selectedIndex = bottomBarTabs
                .indexOfFirst { it.dest == selected }
                .coerceAtLeast(0)
            val lensOffset by animateDpAsState(
                targetValue = barContentPadding +
                    (slotWidth * selectedIndex) +
                    ((slotWidth - Metrics.navigationLensSize) / 2),
                animationSpec = if (reduceMotion) snap() else NoopMotion.value(),
                label = "Selected tab lens position",
            )
            val lensAccent by animateColorAsState(
                targetValue = bottomBarAccent(selected),
                animationSpec = if (reduceMotion) {
                    snap()
                } else {
                    tween(durationMillis = 180, easing = NavEasing)
                },
                label = "Selected tab lens color",
            )
            Box(
                modifier = Modifier
                    .height(barHeight)
                    .fillMaxWidth()
            ) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .height(labelLayout.barHeightDp.dp)
                        .fillMaxWidth()
                        .navigationGlassSurface(
                            shape = barShape,
                            accentRim = lensAccent.copy(alpha = 0.26f),
                        ),
                )
                Box(
                    modifier = Modifier
                        .offset(x = lensOffset)
                        .size(Metrics.navigationLensSize)
                        .raisedNavigationLens(lensAccent),
                )
                Row(
                    modifier = Modifier
                        .height(barHeight)
                        .fillMaxWidth()
                        .padding(horizontal = barContentPadding)
                        .selectableGroup(),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(1.dp),
                ) {
                    bottomBarTabs.forEach { tab ->
                    BarSlot(
                        icon = tab.icon,
                        label = stringResource(tab.labelRes),
                        active = selected == tab.dest,
                        accent = bottomBarAccent(tab.dest),
                        testTag = "noop.tab.${tab.dest.route}",
                        labelMaxLines = labelLayout.maxLines,
                        labelScaleMultiplier = labelLayout.labelScaleMultiplier,
                        modifier = Modifier.weight(1f),
                        onClick = { onTabSelected(tab.dest) },
                    )
                }
                }
            }
        }
    }
}

private fun Modifier.raisedNavigationLens(accent: Color): Modifier = composed {
    val light = Palette.isLight
    val body = Brush.linearGradient(
        colors = listOf(
            accent.copy(
                alpha = if (light) {
                    Metrics.navigationLensBodyLightStartAlpha
                } else {
                    Metrics.navigationLensBodyDarkStartAlpha
                },
            ),
            accent.copy(
                alpha = if (light) {
                    Metrics.navigationLensBodyLightEndAlpha
                } else {
                    Metrics.navigationLensBodyDarkEndAlpha
                },
            ),
        ),
        start = Offset.Zero,
        end = Offset.Infinite,
    )
    this
        .shadow(
            elevation = Metrics.navigationLensShadowRadius,
            shape = CircleShape,
            clip = false,
        )
        .clip(CircleShape)
        .drawWithCache {
            val rimWidth = Metrics.navigationLensStrokeWidth.toPx()
            val highlightWidth = Metrics.navigationLensHighlightWidth.toPx()
            val highlightInset = Metrics.navigationLensHighlightInset.toPx()
            onDrawBehind {
                drawCircle(brush = body)
                drawCircle(
                    color = accent.copy(
                        alpha = if (light) {
                            Metrics.navigationLensRimLightAlpha
                        } else {
                            Metrics.navigationLensRimDarkAlpha
                        },
                    ),
                    style = Stroke(width = rimWidth),
                )
                drawArc(
                    color = Color.White.copy(
                        alpha = if (light) {
                            Metrics.navigationLensHighlightLightAlpha
                        } else {
                            Metrics.navigationLensHighlightDarkAlpha
                        },
                    ),
                    startAngle = Metrics.navigationLensHighlightStartAngle,
                    sweepAngle = Metrics.navigationLensHighlightSweepAngle,
                    useCenter = false,
                    style = Stroke(width = highlightWidth, cap = StrokeCap.Round),
                    topLeft = Offset(highlightInset, highlightInset),
                    size = Size(
                        this.size.width - (highlightInset * 2),
                        this.size.height - (highlightInset * 2),
                    ),
                )
            }
        }
}

internal enum class NoopCommandLensEdge {
    START,
    END,
}

internal object NoopCommandLensPrefs {
    const val FILE = "noop.commandLens"
    const val EDGE = "edge"
    const val VERTICAL_FRACTION = "verticalFraction"
    const val DEFAULT_VERTICAL_FRACTION = 0.76f

    fun readEdge(prefs: android.content.SharedPreferences): NoopCommandLensEdge =
        runCatching {
            NoopCommandLensEdge.valueOf(
                prefs.getString(EDGE, NoopCommandLensEdge.END.name)
                    ?: NoopCommandLensEdge.END.name,
            )
        }.getOrDefault(NoopCommandLensEdge.END)

    fun readVerticalFraction(prefs: android.content.SharedPreferences): Float =
        prefs.getFloat(VERTICAL_FRACTION, DEFAULT_VERTICAL_FRACTION).coerceIn(0f, 1f)

    fun write(
        prefs: android.content.SharedPreferences,
        edge: NoopCommandLensEdge,
        verticalFraction: Float,
    ) {
        prefs.edit()
            .putString(EDGE, edge.name)
            .putFloat(VERTICAL_FRACTION, verticalFraction.coerceIn(0f, 1f))
            .apply()
    }
}

internal fun noopCommandLensRestingOffset(
    containerWidthPx: Int,
    containerHeightPx: Int,
    touchWidthPx: Int,
    touchHeightPx: Int,
    topInsetPx: Int,
    bottomClearancePx: Int,
    edge: NoopCommandLensEdge,
    verticalFraction: Float,
): IntOffset {
    val minimumX = 2
    val maximumX = (containerWidthPx - touchWidthPx - 2).coerceAtLeast(minimumX)
    val minimumY = topInsetPx.coerceAtLeast(0)
    val maximumY = (
        containerHeightPx - bottomClearancePx - touchHeightPx
    ).coerceAtLeast(minimumY)
    return IntOffset(
        x = if (edge == NoopCommandLensEdge.START) minimumX else maximumX,
        y = (
            minimumY +
                (maximumY - minimumY) * verticalFraction.coerceIn(0f, 1f)
            ).roundToInt(),
    )
}

internal fun noopCommandLensClampOffset(
    x: Float,
    y: Float,
    containerWidthPx: Int,
    containerHeightPx: Int,
    touchWidthPx: Int,
    touchHeightPx: Int,
    topInsetPx: Int,
    bottomClearancePx: Int,
): IntOffset {
    val minimumX = 2
    val maximumX = (containerWidthPx - touchWidthPx - 2).coerceAtLeast(minimumX)
    val minimumY = topInsetPx.coerceAtLeast(0)
    val maximumY = (
        containerHeightPx - bottomClearancePx - touchHeightPx
    ).coerceAtLeast(minimumY)
    return IntOffset(
        x = x.roundToInt().coerceIn(minimumX, maximumX),
        y = y.roundToInt().coerceIn(minimumY, maximumY),
    )
}

internal fun noopCommandLensVerticalFraction(
    yPx: Int,
    containerHeightPx: Int,
    touchHeightPx: Int,
    topInsetPx: Int,
    bottomClearancePx: Int,
): Float {
    val minimumY = topInsetPx.coerceAtLeast(0)
    val maximumY = (
        containerHeightPx - bottomClearancePx - touchHeightPx
    ).coerceAtLeast(minimumY)
    val span = (maximumY - minimumY).coerceAtLeast(1)
    return ((yPx - minimumY).toFloat() / span).coerceIn(0f, 1f)
}

@Composable
private fun MovableNoopCommandLens(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember(context) {
        context.getSharedPreferences(
            NoopCommandLensPrefs.FILE,
            android.content.Context.MODE_PRIVATE,
        )
    }
    var storedEdge by rememberSaveable {
        mutableStateOf(NoopCommandLensPrefs.readEdge(prefs).name)
    }
    var verticalFraction by rememberSaveable {
        mutableStateOf(NoopCommandLensPrefs.readVerticalFraction(prefs))
    }
    var dragOffset by remember { mutableStateOf(Offset.Zero) }
    val edge = runCatching {
        NoopCommandLensEdge.valueOf(storedEdge)
    }.getOrDefault(NoopCommandLensEdge.END)
    val interaction = remember { MutableInteractionSource() }
    val quickActionsLabel = stringResource(
        R.string.l10n_today_screen_quick_actions_e47e8042,
    )
    val moveLeftLabel = stringResource(R.string.noop_command_lens_move_left)
    val moveRightLabel = stringResource(R.string.noop_command_lens_move_right)
    val moveUpLabel = stringResource(R.string.noop_command_lens_move_up)
    val moveDownLabel = stringResource(R.string.noop_command_lens_move_down)
    val edgeLabel = stringResource(
        if (edge == NoopCommandLensEdge.START) {
            R.string.noop_command_lens_left_edge
        } else {
            R.string.noop_command_lens_right_edge
        },
    )

    fun updatePosition(nextEdge: NoopCommandLensEdge, nextFraction: Float) {
        val boundedFraction = nextFraction.coerceIn(0f, 1f)
        storedEdge = nextEdge.name
        verticalFraction = boundedFraction
        NoopCommandLensPrefs.write(prefs, nextEdge, boundedFraction)
    }

    BoxWithConstraints(modifier = modifier) {
        val density = LocalDensity.current
        val touchWidth = 48.dp
        val touchHeight = 52.dp
        val touchWidthPx = with(density) { touchWidth.roundToPx() }
        val touchHeightPx = with(density) { touchHeight.roundToPx() }
        val topInsetPx =
            WindowInsets.statusBars.getTop(density) + with(density) { 18.dp.roundToPx() }
        val bottomClearancePx =
            WindowInsets.navigationBars.getBottom(density) + with(density) { 82.dp.roundToPx() }
        val containerWidthPx = constraints.maxWidth
        val containerHeightPx = constraints.maxHeight
        val restingOffset = noopCommandLensRestingOffset(
            containerWidthPx = containerWidthPx,
            containerHeightPx = containerHeightPx,
            touchWidthPx = touchWidthPx,
            touchHeightPx = touchHeightPx,
            topInsetPx = topInsetPx,
            bottomClearancePx = bottomClearancePx,
            edge = edge,
            verticalFraction = verticalFraction,
        )
        val displayOffset = noopCommandLensClampOffset(
            x = restingOffset.x + dragOffset.x,
            y = restingOffset.y + dragOffset.y,
            containerWidthPx = containerWidthPx,
            containerHeightPx = containerHeightPx,
            touchWidthPx = touchWidthPx,
            touchHeightPx = touchHeightPx,
            topInsetPx = topInsetPx,
            bottomClearancePx = bottomClearancePx,
        )
        val lensShape = RoundedCornerShape(
            topStart = if (edge == NoopCommandLensEdge.START) 7.dp else 16.dp,
            bottomStart = if (edge == NoopCommandLensEdge.START) 7.dp else 16.dp,
            topEnd = if (edge == NoopCommandLensEdge.END) 7.dp else 16.dp,
            bottomEnd = if (edge == NoopCommandLensEdge.END) 7.dp else 16.dp,
        )

        Box(
            modifier = Modifier
                .offset { displayOffset }
                .width(touchWidth)
                .height(touchHeight)
                .testTag("noop.quick-actions")
                .pointerInput(
                    restingOffset,
                    containerWidthPx,
                    containerHeightPx,
                    topInsetPx,
                    bottomClearancePx,
                ) {
                    detectDragGestures(
                        onDragEnd = {
                            val finalOffset = noopCommandLensClampOffset(
                                x = restingOffset.x + dragOffset.x,
                                y = restingOffset.y + dragOffset.y,
                                containerWidthPx = containerWidthPx,
                                containerHeightPx = containerHeightPx,
                                touchWidthPx = touchWidthPx,
                                touchHeightPx = touchHeightPx,
                                topInsetPx = topInsetPx,
                                bottomClearancePx = bottomClearancePx,
                            )
                            val finalEdge =
                                if (finalOffset.x + touchWidthPx / 2 < containerWidthPx / 2) {
                                    NoopCommandLensEdge.START
                                } else {
                                    NoopCommandLensEdge.END
                                }
                            updatePosition(
                                finalEdge,
                                noopCommandLensVerticalFraction(
                                    yPx = finalOffset.y,
                                    containerHeightPx = containerHeightPx,
                                    touchHeightPx = touchHeightPx,
                                    topInsetPx = topInsetPx,
                                    bottomClearancePx = bottomClearancePx,
                                ),
                            )
                            dragOffset = Offset.Zero
                        },
                        onDragCancel = { dragOffset = Offset.Zero },
                    ) { change, amount ->
                        change.consume()
                        dragOffset += amount
                    }
                }
                .clickable(
                    interactionSource = interaction,
                    indication = null,
                    onClick = onClick,
                )
                .semantics {
                    contentDescription = quickActionsLabel
                    stateDescription = edgeLabel
                    customActions = listOf(
                        CustomAccessibilityAction(moveLeftLabel) {
                            updatePosition(NoopCommandLensEdge.START, verticalFraction)
                            true
                        },
                        CustomAccessibilityAction(moveRightLabel) {
                            updatePosition(NoopCommandLensEdge.END, verticalFraction)
                            true
                        },
                        CustomAccessibilityAction(moveUpLabel) {
                            updatePosition(edge, verticalFraction - 0.10f)
                            true
                        },
                        CustomAccessibilityAction(moveDownLabel) {
                            updatePosition(edge, verticalFraction + 0.10f)
                            true
                        },
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .width(18.dp)
                    .height(38.dp)
                    .offset(
                        x = if (edge == NoopCommandLensEdge.START) (-18).dp else 18.dp,
                    )
                    .navigationGlassSurface(
                        shape = lensShape,
                        accentRim = Palette.metricCyan.copy(alpha = 0.30f),
                    )
                    .border(
                        width = 0.75.dp,
                        brush = Brush.verticalGradient(
                            listOf(
                                Color.White.copy(alpha = if (Palette.isLight) 0.52f else 0.24f),
                                Palette.metricCyan.copy(alpha = 0.58f),
                                Palette.chargeColor.copy(alpha = 0.34f),
                            ),
                        ),
                        shape = lensShape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Box(
                    modifier = Modifier.offset(
                        x = if (edge == NoopCommandLensEdge.START) 1.dp else (-1).dp,
                    ),
                    contentAlignment = Alignment.Center,
                ) {
                    NoopCommandNMark()
                }
                Box(
                    modifier = Modifier
                        .align(
                            if (edge == NoopCommandLensEdge.START) {
                                Alignment.CenterStart
                            } else {
                                Alignment.CenterEnd
                            },
                        )
                        .padding(
                            start = if (edge == NoopCommandLensEdge.START) 3.dp else 0.dp,
                            end = if (edge == NoopCommandLensEdge.END) 3.dp else 0.dp,
                        )
                        .width(1.5.dp)
                        .height(12.dp)
                        .clip(CircleShape)
                        .background(Palette.textSecondary.copy(alpha = 0.56f)),
                )
            }
        }
    }
}

@Composable
private fun NoopCommandNMark() {
    Canvas(modifier = Modifier.size(14.dp)) {
        val strokeWidth = 2.5.dp.toPx()
        val inset = maxOf(2.2.dp.toPx(), size.width * 0.18f)
        val left = inset
        val right = size.width - inset
        val top = inset
        val bottom = size.height - inset
        val path = Path().apply {
            moveTo(left, bottom)
            lineTo(left, top)
            lineTo(right, bottom)
            lineTo(right, top)
        }
        drawPath(
            path = path,
            brush = Brush.linearGradient(
                colors = listOf(
                    Palette.chargeBright,
                    Palette.metricCyan,
                    Palette.chargeColor,
                ),
                start = Offset(left, bottom),
                end = Offset(right, top),
            ),
            style = Stroke(
                width = strokeWidth,
                cap = StrokeCap.Round,
                join = StrokeJoin.Round,
            ),
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
        Color.White.copy(alpha = 0.66f)
    } else {
        Palette.surfaceRaised.copy(alpha = 0.56f)
    }
    val smoke = if (light) {
        Color.Black.copy(alpha = 0.025f)
    } else {
        Color.Black.copy(alpha = 0.08f)
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
        Color.Black.copy(alpha = 0.12f)
    }
    val rimTop = accentRim ?: if (light) {
        Color.White.copy(alpha = 0.52f)
    } else {
        Color.White.copy(alpha = 0.12f)
    }
    val rimBottom = if (light) {
        Color.Black.copy(alpha = 0.07f)
    } else {
        Color.Black.copy(alpha = 0.15f)
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

/** One nav slot: an icon over a small label. Active = green accent (semibold), inactive =
 * textSecondary. The icon-sized halo mirrors iOS without filling the whole touch target. */
@Composable
private fun BarSlot(
    icon: ImageVector,
    label: String,
    active: Boolean,
    accent: Color,
    testTag: String,
    labelMaxLines: Int,
    labelScaleMultiplier: Float,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val reduceMotion = rememberReduceMotion()
    val tint by animateColorAsState(
        targetValue = if (active) accent else Palette.textSecondary,
        animationSpec = if (reduceMotion) {
            snap()
        } else {
            tween(durationMillis = 180, easing = NavEasing)
        },
        label = "Bottom navigation item color",
    )
    val selectedTabLiftLabel = stringResource(R.string.nav_selected_tab_animation_label)
    val selectedScale by animateFloatAsState(
        targetValue = if (active) Metrics.navigationLensSelectedScale else 1f,
        animationSpec = if (reduceMotion) {
            snap()
        } else {
            tween(durationMillis = 260, easing = NavEasing)
        },
        label = selectedTabLiftLabel,
    )
    Column(
        modifier = modifier
            .fillMaxHeight()
            .testTag(testTag)
            .selectable(
                selected = active,
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Tab,
                onClick = onClick,
            )
            .padding(vertical = Metrics.navigationLensHighlightInset)
            .semantics {
                contentDescription = label
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Top,
    ) {
        Box(
            modifier = Modifier
                .width(Metrics.navigationLensSize)
                .height(Metrics.navigationLensSize - Metrics.space2),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier
                    .size(Metrics.navigationLensIconSize)
                    .graphicsLayer {
                        scaleX = selectedScale
                        scaleY = selectedScale
                        translationY = if (active) {
                            -Metrics.navigationLensActiveOffset.toPx()
                        } else {
                            0f
                        }
                    },
            )
        }
        Text(
            label,
            style = NoopType.footnote.copy(
                fontSize = (10f * labelScaleMultiplier).sp,
                lineHeight = (12f * labelScaleMultiplier).sp,
                fontWeight = if (active) FontWeight.SemiBold else FontWeight.Medium,
            ),
            color = tint,
            minLines = labelMaxLines,
            maxLines = labelMaxLines,
            softWrap = false,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .offset(y = -Metrics.navigationLensLabelOffset)
                .padding(horizontal = 1.dp),
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
            Overline("How can NOOP help?", color = Palette.textTertiary)
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
                .clip(RoundedCornerShape(15.dp))
                .background(
                    brush = Brush.linearGradient(
                        listOf(tint.copy(alpha = 0.20f), Palette.surfaceInset),
                    ),
                    shape = RoundedCornerShape(15.dp),
                )
                .border(
                    0.8.dp,
                    tint.copy(alpha = 0.32f),
                    RoundedCornerShape(15.dp),
                ),
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
    val metricDataVersion by viewModel.metricDataVersion.collectAsStateWithLifecycle()
    val activeDeviceId by viewModel.selectedDeviceId.collectAsStateWithLifecycle()
    var record by remember {
        mutableStateOf(FusedRecord(rows = emptyList(), dayOwner = null as FusionSource?, contributingSourceCount = 0))
    }
    LaunchedEffect(metricDataVersion, activeDeviceId) {
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
