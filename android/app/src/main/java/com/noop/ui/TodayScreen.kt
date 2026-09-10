package com.noop.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.annotation.StringRes
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.TrendingDown
import androidx.compose.material.icons.automirrored.filled.TrendingFlat
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Accessibility
import androidx.compose.material.icons.filled.AccessTime
import androidx.compose.material.icons.filled.AcUnit
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Thunderstorm
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.zIndex
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.withFrameNanos
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import android.view.HapticFeedbackConstants
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.noop.R
import com.noop.analytics.Baselines
import com.noop.analytics.AgeMetricProfile
import com.noop.analytics.BatteryEstimator
import com.noop.analytics.ChargeDriver
import com.noop.analytics.DailyActionPlanner
import com.noop.analytics.DailyEffortGuidance
import com.noop.analytics.DailySignalStatus
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.analytics.IllnessSignalEngine
import com.noop.analytics.ReadinessEngine
import com.noop.analytics.ScoreConfidence
import com.noop.analytics.StepsEstimateEngine
import com.noop.analytics.StrainScorer
import com.noop.analytics.VitalBands
import com.noop.calendar.PlannedWorkoutCalendarStore
import com.noop.data.DailyMetric
import com.noop.data.HrBucket
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import com.noop.ingest.HealthConnectImporter
import com.noop.notif.StrainTargetNotifier
import com.noop.ble.HistorySyncPresentationPolicy
import com.noop.ble.HistorySyncPresentationState
import com.noop.ble.HistorySyncDurableProgressPolicy
import com.noop.weather.TodayWeatherCode
import com.noop.weather.TodayWeatherCondition
import com.noop.weather.TodayWeatherState
import com.noop.weather.TodayWeatherStatus
import com.noop.weather.TodayWeatherStore
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Control Center, the home dashboard. A recovery ring + plain-English synthesis
 * hero, an illness banner when the watch fires, and a tile grid of the day's key
 * metrics, each tile carrying a 14-day sparkline. Ports the macOS TodayView
 * composition (Strand/Screens/TodayView.swift) with the same locked components.
 *
 * Sparkline series are built off the view model's `recentDays` (oldest → newest,
 * all from the compatible-wearable import source). Missing current-day values render as explicit
 * "No Data" states instead of raw dashes, so old imports do not look like today.
 */

/** Stable Today info-card ids (the dismissed-flag suffix + the inbox `restorePayload`). Match the
 *  iOS card ids so an export/import round-trips. */
private const val CARD_SCORES_BUILDING = "scoresBuilding"
private const val CARD_NEW_HERE = "newHere"
// #827: the "Building your baseline, N more nights" calibrating note is dismissible-into-the-inbox like
// the other Today info-cards, so a returning user who has read it once isn't nagged with it every day
// through the multi-night calibration window. Same id on both platforms so it round-trips an export/import.
private const val CARD_CALIBRATING = "calibratingBaseline"
// The "Latest sleep · <date>" / "Last night · <date>" carry-over note (ScoreState.CarriedLastNight). iOS
// has nothing in this slot, so on Android it's dismissible-into-the-inbox like the other Today info-cards:
// a small × tucks it into Updates (restorable), so it never sits permanently between the header and the
// hero throwing off the compact liquid look. Local-only id (iOS has no twin), matching the dismiss plumbing.
private const val CARD_CARRIED_SLEEP = "carriedSleep"

internal suspend fun <T> loadTodayRestWithRetry(
    maxAttempts: Int = 3,
    pause: suspend (Long) -> Unit = { delay(it) },
    load: suspend () -> T,
): T {
    require(maxAttempts > 0)
    var lastFailure: Throwable? = null
    repeat(maxAttempts) { attempt ->
        currentCoroutineContext().ensureActive()
        try {
            val result = load()
            currentCoroutineContext().ensureActive()
            return result
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            lastFailure = failure
            if (attempt + 1 < maxAttempts) {
                pause(if (attempt == 0) 150L else 500L)
            }
        }
    }
    throw checkNotNull(lastFailure)
}

/** Best-effort UI read that never converts structured cancellation into an empty/stale publication. */
internal data class TodayBestEffortRead<out T>(
    val value: T?,
    val succeeded: Boolean,
)

internal suspend fun <T> loadTodayBestEffortResult(
    load: suspend () -> T,
): TodayBestEffortRead<T> =
    try {
        TodayBestEffortRead(value = load(), succeeded = true)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        TodayBestEffortRead(value = null, succeeded = false)
    }

internal suspend fun <T> loadTodayBestEffort(load: suspend () -> T): T? =
    loadTodayBestEffortResult(load).value

internal fun todayRestResultBucket(count: Int): String = when {
    count <= 0 -> "empty"
    count <= 30 -> "up_to_30"
    count <= 365 -> "31_to_365"
    else -> "over_365"
}

/** #860 item 1: process-lifetime guard for the launch snap-to-today. `selectedDayOffset` is rememberSaveable
 *  so a tab-away keeps the user's chosen day (#614/#739). The same persistence, however, rides the
 *  saved-instance-state bundle across a system-initiated process kill + restore (common after an app UPDATE),
 *  so a user who was browsing an OLD day when the process died - or a calibrating user the now-retired
 *  #605/#739 auto-land would have snapped to an old day - reopened the app pinned to that day instead of
 *  today. A top-level var = one value per LAUNCH (reset only on a genuine fresh process), so we run the pure
 *  `launchDayOffset` policy exactly once per launch (forcing today) and leave in-session tab-away/restore
 *  behaviour untouched. iOS parity: TodayView's selectedDayOffset is plain @State, which is never persisted
 *  and so already re-inits to 0 on every fresh launch, reaching the same offset through the same helper. */
private var todayDidSnapToTodayThisLaunch = false

// MARK: - Liquid hero tokens (the liquid Today restyle)
//
// The hero card the score vessels float on, ported from the iOS LiquidTodayView. `heroFill` is a
// translucent near-black (mock rgba(13,14,20,.80)) so it floats over the day-of-sky; the vessels + white
// count-up numbers read crisp on it. Phone radius 24 / roomy radius 26 plus a white@0.11 hairline give
// the frosted-glass edge.
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_BASE: Color = Color(red = 7f / 255f, green = 9f / 255f, blue = 8f / 255f, alpha = 1f)
private val LIQUID_HERO_COMPACT_RADIUS: Dp = 24.dp
private val LIQUID_HERO_ROOMY_RADIUS: Dp = 26.dp
private val DAILY_SIGNAL_ALERT_TINT = Color(0xFFFF453A)

internal fun todayUsesCompactLayout(screenWidthDp: Int, fontScale: Float): Boolean =
    screenWidthDp < 600 && fontScale <= 1.30f

internal fun todayWeatherShowsVisualText(hasSnapshot: Boolean, fontScale: Float): Boolean =
    hasSnapshot || fontScale <= 1.30f

@Composable
private fun currentTodayLayoutIsCompact(): Boolean =
    todayUsesCompactLayout(
        screenWidthDp = LocalConfiguration.current.screenWidthDp,
        fontScale = LocalDensity.current.fontScale,
    )

private fun Modifier.liquidTodayHeroSurface(tint: Color): Modifier = composed {
    val opacity = CardAppearance.opacity
    val compactLayout = currentTodayLayoutIsCompact()
    val shape = RoundedCornerShape(
        if (compactLayout) LIQUID_HERO_COMPACT_RADIUS else LIQUID_HERO_ROOMY_RADIUS,
    )
    this
        .shadow(
            elevation = ((if (compactLayout) 18f else 22f) * opacity).dp,
            shape = shape,
            clip = false,
        )
        .clip(shape)
        .background(LIQUID_HERO_BASE.copy(alpha = opacity))
        .background(
            Brush.linearGradient(
                colors = listOf(
                    tint.copy(alpha = 0.16f * opacity),
                    tint.copy(alpha = 0.045f * opacity),
                    Color.Transparent,
                ),
            ),
        )
        .background(
            Brush.linearGradient(
                colors = listOf(
                    Color.White.copy(alpha = 0.07f * opacity),
                    Color.Transparent,
                    Color.Black.copy(alpha = 0.24f * opacity),
                ),
            ),
        )
        .border(
            width = 0.9.dp,
            brush = Brush.linearGradient(
                colors = listOf(
                    tint.copy(alpha = 0.34f * opacity),
                    Color.White.copy(alpha = 0.08f * opacity),
                    Color.Black.copy(alpha = 0.86f * opacity),
                ),
            ),
            shape = shape,
        )
}

private fun Modifier.liquidTodayCompactSurface(): Modifier = composed {
    val opacity = CardAppearance.opacity
    val shape = RoundedCornerShape(18.dp)
    this
        .shadow(elevation = (16f * opacity).dp, shape = shape, clip = false)
        .clip(shape)
        .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * opacity))
        .background(
            Brush.linearGradient(
                colors = listOf(
                    Color.White.copy(alpha = 0.06f * opacity),
                    Color.Transparent,
                    Color.Black.copy(alpha = 0.18f * opacity),
                ),
            ),
        )
        .border(
            width = 0.85.dp,
            brush = Brush.linearGradient(
                colors = listOf(
                    Color.White.copy(alpha = 0.20f * opacity),
                    Color.White.copy(alpha = 0.055f * opacity),
                    Color.Black.copy(alpha = 0.84f * opacity),
                ),
            ),
            shape = shape,
        )
}

// The Vitality vessel purple (#9b7bff) — no exact Palette token in this theme, so a fixed brand literal
// matching the iOS liquid Today's `liquidPurple` (Color(.sRGB, red:0x9b, green:0x7b, blue:0xff)). Used by
// the mini "Your cards" vessel so Vitality reads the same purple as iOS.
private val LIQUID_PURPLE: Color = Color(red = 0x9b / 255f, green = 0x7b / 255f, blue = 0xff / 255f, alpha = 1f)

internal data class PlannedWorkoutTodayDemoContext(
    val nowSec: Long,
    val recentSleep: List<DailyActionPlanner.SleepDay>,
    val workout: DailyActionPlanner.PlannedWorkout,
)

internal fun plannedWorkoutTodayDemoContext(
    dayKey: String,
    zoneId: ZoneId = ZoneId.systemDefault(),
): PlannedWorkoutTodayDemoContext? {
    val day = runCatching { LocalDate.parse(dayKey) }.getOrNull()
        ?.takeIf { it.toString() == dayKey }
        ?: return null
    val now = day.atTime(9, 41).atZone(zoneId)
    val start = day.atTime(17, 30).atZone(zoneId)
    val recentSleep = buildList {
        add(DailyActionPlanner.SleepDay(dayKey, 6.0 * 60.0 + 12.0))
        for (offset in 1L..7L) {
            add(
                DailyActionPlanner.SleepDay(
                    day = day.minusDays(offset).toString(),
                    minutes = 7.0 * 60.0 + 30.0,
                ),
            )
        }
    }
    return PlannedWorkoutTodayDemoContext(
        nowSec = now.toEpochSecond(),
        recentSleep = recentSleep,
        workout = DailyActionPlanner.PlannedWorkout(
            day = dayKey,
            startSec = start.toEpochSecond(),
            endSec = start.plusHours(1).toEpochSecond(),
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayScreen(
    viewModel: AppViewModel,
    updateStore: UpdateStore? = null,
    onOpenUpdates: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
    onOpenHydration: () -> Unit = {},
    // #706/#684: the "Your cards" dashboard rows are tappable on iOS but only Hydration navigated on Android.
    // These push each card's detail (Stress card -> Stress; Sleep -> Sleep), matching the iOS pinnedCardRow
    // destinations. Defaulted to no-ops so the call site stays compiling; AppRoot binds them to nav.navigate(...)
    // like onOpenHydration.
    onOpenStress: () -> Unit = {},
    onOpenHealth: () -> Unit = {},
    // Every metric/vital card (HRV, Resting HR, Respiratory, SpO₂, Skin Temp, Fitness age, Vitality, Steps,
    // Calories) opens ITS OWN focused detail trend, not the shared Health hub (2026-07-03: cards were
    // wrongly dumping into the Health monitor). Mirrors the iOS liquidCard `metricDetail(key)`. Takes the
    // vital_detail key; defaults to the Health screen so an unbound caller keeps the old behaviour.
    onOpenMetric: (String) -> Unit = { onOpenHealth() },
    onOpenSleep: () -> Unit = {},
    // Optional Coupled view card (task #43): a tap-through to the WHOOP-style day screen. Defaulted to a
    // no-op so the call site stays compiling; AppRoot binds it to nav.navigate(CoupledView).
    onOpenCoupled: () -> Unit = {},
    // The "workout in progress" indicator card routes to Live and re-opens the in-exercise overlay. Defaulted
    // to a no-op so the call site stays compiling; AppRoot binds it to openActiveWorkout() + nav.navigate(Live).
    onOpenActiveWorkout: () -> Unit = {},
    // The liquid header battery ring taps through to Devices (iOS parity: the battery ring → router.openDevices()).
    // Defaulted to fall back to Settings so the call site stays compiling; AppRoot binds it to the Devices route.
    onOpenDevices: () -> Unit = onOpenSettings,
    // The #627 journal-reminder card links straight to the journal (Insights). Defaulted to a no-op so
    // the call site stays compiling; AppRoot binds it to nav.navigateTopLevel(Insights), same as Sleep.
    onOpenJournal: () -> Unit = {},
    // The calendar icon opens the same month-at-a-glance history surface as iOS.
    onOpenCalendar: () -> Unit = {},
    // Debug-only deterministic visual fixture; AppRoot enables it only for the private demo route.
    demoPlannedWorkout: Boolean = false,
) {
    val today by viewModel.today.collectAsStateWithLifecycle()
    val alert by viewModel.healthAlert.collectAsStateWithLifecycle()
    val healthSignals by viewModel.v5Signals.collectAsStateWithLifecycle()
    val illnessWatchEnabled by viewModel.illnessWatchEnabled.collectAsStateWithLifecycle()
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val sleepTargetMinutes by viewModel.windDownSleepNeedMinutes.collectAsStateWithLifecycle()
    val activeStrapId by viewModel.selectedDeviceId.collectAsStateWithLifecycle()
    val liveSnap by viewModel.dashboardLive.collectAsStateWithLifecycle()
    val historyBackfilling by viewModel.historyBackfillActive.collectAsStateWithLifecycle()
    // The in-flight manual workout (single source of truth, survives an app kill via rehydration), so the
    // indicator card auto-appears/clears off this alone. Null↔non-null + the start drive the card; the
    // per-second clock ticks inside the card's own LaunchedEffect, never recomposing the Today body.
    val activeWorkout by viewModel.activeWorkout.collectAsStateWithLifecycle()
    // The root observes only stable connection/battery fields plus the boolean history-write edge.
    // Exact batch/row progress is rendered by small leaves below and cannot invalidate this dashboard.
    val deferHistoricalQueries = rememberHistoryQueryGate(historyBackfilling)
    // #849: seed from the ViewModel cache so a re-mount (tab-return / post-import) restores the last footer
    // immediately instead of flashing empty while the heavy reload is (now) skipped for unchanged data.
    var footer by remember(activeStrapId) {
        mutableStateOf(
            viewModel.todayFooterCache.takeIf {
                viewModel.todayFooterLoadedDeviceId == activeStrapId
            } ?: TodayFooterState(),
        )
    }
    // rememberSaveable (not plain remember): the bottom-tab NavHost (AppRoot) navigates with
    // saveState/restoreState, which only restores rememberSaveable-backed state. With plain remember a
    // tab-away wiped the chosen day back to 0, so on return the dashboard "shifted" off the day the user was
    // looking at (#614 follow-up). Persisting it across the save/restore keeps the chosen day put. The
    // launch snap-to-today is a separate process-lifetime flag (todayDidSnapToTodayThisLaunch below).
    var selectedDayOffset by rememberSaveable { mutableIntStateOf(0) }
    // #860 item 1: on a GENUINE fresh process (not a tab-away/recomposition), force the selected day back to
    // today via the pure `launchDayOffset` policy. rememberSaveable restores selectedDayOffset from the
    // saved-instance-state bundle, which the system reuses across a process kill + restore (the after-an-update
    // case in the report); without this, a user who was viewing an old day when the process died - OR a
    // calibrating user the retired auto-land would have snapped to an old day - reopened the app stranded
    // there. The top-level guard is false exactly once per launch, so `launchDayOffset(isFreshLaunch = true)`
    // forces today a single time and never fights the in-session tab-away day-memory (#614/#739) afterwards.
    // Done in composition (not a LaunchedEffect) so the stale restored day never paints for a frame. iOS uses
    // plain @State (re-inits to 0 every launch) and reaches the same offset through the same helper.
    if (!todayDidSnapToTodayThisLaunch) {
        todayDidSnapToTodayThisLaunch = true
        val landed = launchDayOffset(
            isFreshLaunch = true,
            savedOffset = selectedDayOffset,
            hasTodayData = today != null,
            latestDataDayBack = selectedDayOffset,
        )
        if (selectedDayOffset != landed) selectedDayOffset = landed
    }
    // Anchor offset-0 to the LOGICAL day (rolls at 04:00 local), so between midnight and 4am "Today"
    // still resolves to the prior calendar day's banked row instead of an empty new-calendar-day row
    // that blanks the dashboard (#144). Past offsets count back from this anchor. Presentation-only.
    val todayDate = logicalDayNow()
    // #860 item 1: the launch auto-land (#605/#739 "snap to the most recent data day when today is empty")
    // is RETIRED. It fired on a fresh process when today had no row yet, and for a calibrating user whose
    // newest data was a few days back it stranded them on that old day, overriding the snap-to-today above.
    // A fresh launch now lands on today via `launchDayOffset` (the inline guard above), and in-session day
    // memory (#739/#614) is preserved because nothing rewrites `selectedDayOffset` after launch. iOS parity
    // in TodayView (which retired the same block).
    val selectedDay = remember(selectedDayOffset, todayDate) { todayDate.minusDays(selectedDayOffset.toLong()) }
    // The key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    // follows the resolver's `today?.day` so it tracks the row actually surfaced, including the non-UTC
    // pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one. Falls
    // back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    val selectedDayKey = remember(selectedDay, today, selectedDayOffset) {
        if (selectedDayOffset == 0) today?.day ?: selectedDay.toString() else selectedDay.toString()
    }
    val historicalMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val displayMetric = remember(today, historicalMetric, selectedDayOffset) {
        if (selectedDayOffset == 0) today ?: historicalMetric else historicalMetric
    }
    // Keep the explicit calendar date visible alongside Today/Yesterday so the logical-day remap stays
    // honest, between midnight and 04:00 "Today" still points at the prior calendar date, and showing
    // that date makes it obvious which day's row is on screen (#144).
    val dayLabel = remember(selectedDayOffset, selectedDay, selectedDayKey) {
        // Date the label by the row ACTUALLY on screen, not the raw logical date. `selectedDayKey` already
        // follows the resolver's `today?.day` at offset 0, so when the resolver surfaces yesterday's
        // complete row (today not scored yet) the date now reads that row's day, instead of stamping
        // "Today · <today>" over yesterday's values, which disagreed with the Intelligence History row for
        // the same data (#434). iOS/Mac already label by the shown row's day; this brings Android to parity.
        val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
        val date = keyDate.format(DateTimeFormatter.ofPattern("EEE, d MMM", Locale.US))
        when (selectedDayOffset) {
            0 -> "Today · $date"
            1 -> "Yesterday · $date"
            else -> date
        }
    }
    // Display-only units + the SI profile weight, read once like every other Settings-backed
    // preference (SharedPreferences isn't reactive, a Settings write triggers recomposition).
    val context = LocalContext.current
    val plannedWorkoutSnapshot by PlannedWorkoutCalendarStore.snapshot.collectAsStateWithLifecycle()
    val weatherStore = remember(context.applicationContext) {
        TodayWeatherStore(context.applicationContext)
    }
    val weatherState by weatherStore.state.collectAsStateWithLifecycle()
    var showWeatherDetails by rememberSaveable { mutableStateOf(false) }
    val weatherPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        weatherStore.onPermissionResult(granted)
        if (!granted) showWeatherDetails = true
    }
    DisposableEffect(weatherStore) {
        onDispose { weatherStore.close() }
    }
    LaunchedEffect(weatherStore) {
        weatherStore.startIfEnabled()
    }
    val temperatureUnit = UnitPrefs.temperature(context)
    val massUnit = UnitPrefs.mass(context)
    val reportsAvailableInitially = reportNotificationsAvailable(context)
    val strainTargetInitiallyEnabled = NoopPrefs.strainTargetEnabled(context)
    var strainTargetEnabled by remember {
        mutableStateOf(strainTargetInitiallyEnabled && reportsAvailableInitially)
    }
    var strainTargetPermissionDenied by remember {
        mutableStateOf(strainTargetInitiallyEnabled && !reportsAvailableInitially)
    }
    var dailyActionCheckIn by remember(selectedDayKey, selectedDayOffset) {
        mutableStateOf(
            if (selectedDayOffset == 0) {
                NoopPrefs.dailyActionCheckIn(context, selectedDayKey)
            } else {
                DailyActionPlanner.CheckIn.UNANSWERED
            }
        )
    }
    val dailyActionReadiness = remember(days, selectedDayKey) {
        ReadinessEngine.evaluate(days, today = selectedDayKey)
    }
    val plannedWorkoutDemo = remember(
        demoPlannedWorkout,
        selectedDayKey,
        selectedDayOffset,
    ) {
        if (com.noop.BuildConfig.DEBUG && demoPlannedWorkout && selectedDayOffset == 0) {
            plannedWorkoutTodayDemoContext(selectedDayKey)
        } else {
            null
        }
    }
    var planningClockRevision by remember { mutableLongStateOf(0L) }
    val planningNowSec = remember(
        plannedWorkoutSnapshot?.revision,
        selectedDayKey,
        planningClockRevision,
        plannedWorkoutDemo,
    ) {
        plannedWorkoutDemo?.nowSec ?: System.currentTimeMillis() / 1_000L
    }

    fun buildDailyActionPlan(checkIn: DailyActionPlanner.CheckIn): DailyActionPlanner.Plan =
        DailyActionPlanner.plan(
            today = selectedDayKey,
            readiness = dailyActionReadiness,
            checkIn = checkIn,
            recentEffort = days.map {
                DailyActionPlanner.EffortDay(day = it.day, effort = it.strain)
            },
            recentSleep = plannedWorkoutDemo?.recentSleep ?: days.map {
                DailyActionPlanner.SleepDay(day = it.day, minutes = it.totalSleepMin)
            },
            sleepTargetMinutes = sleepTargetMinutes,
            plannedWorkout = plannedWorkoutDemo?.workout
                ?: if (selectedDayOffset == 0) {
                    plannedWorkoutSnapshot?.asPlannedWorkout(selectedDayKey)
                } else {
                    null
                },
            nowSec = planningNowSec,
        )

    fun applyStrainTargetPreference(enabled: Boolean, permissionDenied: Boolean = false) {
        strainTargetEnabled = enabled
        strainTargetPermissionDenied = permissionDenied
        NoopPrefs.setStrainTargetEnabled(context, enabled)
        if (!enabled) {
            StrainTargetNotifier.cancel(context)
        } else {
            StrainTargetNotifier.onStrainTarget(
                context = context,
                day = selectedDayKey,
                dayEffort = displayMetric?.strain,
                targetRange = buildDailyActionPlan(
                    NoopPrefs.dailyActionCheckIn(context, selectedDayKey),
                ).target,
            )
        }
    }

    val strainTargetPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val allowed = granted &&
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        applyStrainTargetPreference(allowed, permissionDenied = !allowed)
    }

    LaunchedEffect(Unit) {
        if (strainTargetInitiallyEnabled && !reportsAvailableInitially) {
            applyStrainTargetPreference(false, permissionDenied = true)
        }
    }
    val currentIllnessResult = if (selectedDayOffset == 0 && illnessWatchEnabled) {
        healthSignals?.illness
    } else {
        null
    }
    val dailySignalStatus = remember(dailyActionReadiness, currentIllnessResult) {
        DailySignalStatus.resolve(dailyActionReadiness, currentIllnessResult)
    }
    val dailyActionPlan = remember(
        days,
        selectedDayKey,
        selectedDayOffset,
        dailyActionCheckIn,
        dailyActionReadiness,
        plannedWorkoutSnapshot?.revision,
        sleepTargetMinutes,
        planningNowSec,
    ) {
        buildDailyActionPlan(dailyActionCheckIn)
    }
    LaunchedEffect(dailyActionPlan.workoutAdjustment?.startSec) {
        if (plannedWorkoutDemo != null) return@LaunchedEffect
        val startSec = dailyActionPlan.workoutAdjustment?.startSec ?: return@LaunchedEffect
        val delayMillis = (startSec * 1_000L - System.currentTimeMillis()).coerceAtLeast(0L)
        if (delayMillis > 0L) delay(delayMillis)
        planningClockRevision += 1L
    }
    val updateDailyActionCheckIn: (DailyActionPlanner.CheckIn) -> Unit = { value ->
        if (selectedDayOffset == 0) {
            NoopPrefs.setDailyActionCheckIn(
                context = context,
                day = selectedDayKey,
                value = value,
            )
            dailyActionCheckIn = value
            viewModel.onAdaptiveDayInputsChanged()
        }
    }
    // Effort display scale (#268), drives the Effort tile's value + caption. Display-only.
    val effortScale = UnitPrefs.effortScale(context)
    val profileWeightKg = remember { ProfileStore.from(context).weightKg }
    // Body profile for the live Effort computation below, age/sex/HR-max-override drive the same
    // StrainScorer call the daily pass uses. Read once like every other Settings-backed value. (#402)
    val profileStore = remember { ProfileStore.from(context) }
    val displayNameVersion by ProfileStore.displayNameChanges.collectAsStateWithLifecycle()
    val displayName = remember(displayNameVersion) { profileStore.displayName }
    val ageMetricProfileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val ageMetricState = remember(ageMetricProfileVersion) { profileStore.ageMetricStateToken }
    val ageMetricDataVersion by viewModel.ageMetricDataVersion.collectAsStateWithLifecycle()
    val restDataVersion by viewModel.restDataVersion.collectAsStateWithLifecycle()
    val workoutDataVersion by viewModel.workoutDataVersion.collectAsStateWithLifecycle()

    // Editable Key-Metrics layout (#251), an ordered list of the pinned tiles, persisted display-only.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showMetricsEditor by remember { mutableStateOf(false) }
    var enabledKeyMetrics by remember { mutableStateOf(KeyMetricPrefs.enabled(context)) }
    // Detailed Key-Metrics tiles (squarer + trend graph), set from the same editor, plus the chosen
    // trend window (2 days / 1 week / 2 weeks) the detailed graphs cover.
    var keyMetricsDetailed by remember { mutableStateOf(KeyMetricPrefs.detailed(context)) }
    var keyMetricsWindowDays by remember { mutableStateOf(KeyMetricPrefs.detailWindowDays(context)) }
    // #today-layout: the user-ordered below-hero section list + its editor dialog flag. Read once (prefs
    // aren't reactive) and re-read on the editor's save, exactly like enabledKeyMetrics above.
    var showLayoutEditor by remember { mutableStateOf(false) }
    var sectionOrder by remember { mutableStateOf(TodayLayoutPrefs.order(context)) }
    // #today-layout (hold-to-drag): the hoisted list state (the drag math needs layoutInfo + scrollBy) and
    // the live drag state. The frame loop below runs ONLY while a section is lifted: each frame it retries
    // the swap (so a card held still at a viewport edge keeps reordering as the list scrolls under it —
    // onDrag alone only fires while the finger moves) and applies the edge auto-scroll velocity that
    // TodayReorderableSection's onDrag computed.
    val todayListState = rememberLazyListState()
    val sectionDrag = remember { TodaySectionDragState() }
    val sectionDragActive = sectionDrag.key != null
    LaunchedEffect(sectionDragActive) {
        // Auto-scroll is TIME-based (px/second × real frame delta), not per-frame: a per-frame step runs
        // twice as fast on a 120 Hz panel and reads as jarring — the first on-device feedback. dt is
        // clamped so a dropped/backgrounded frame can't produce one giant jump.
        var lastFrameNanos = 0L
        while (sectionDrag.key != null) {
            val frameNanos = withFrameNanos { it }
            val dtSec = if (lastFrameNanos == 0L) 0f
            else ((frameNanos - lastFrameNanos) / 1_000_000_000f).coerceAtMost(0.05f)
            lastFrameNanos = frameNanos
            swapTargetForDraggedSection(todayListState, sectionDrag, sectionOrder)?.let { (dragged, target) ->
                // Freeze the scroll anchor across the reorder. LazyColumn re-anchors the viewport to the
                // FIRST VISIBLE item's key — when a swap involves that item (usual while dragging near the
                // top of the screen), the whole content leaps by the two cards' height difference in a
                // single frame (the on-device "not smooth with other cards" report). Re-pinning the same
                // positional index+offset around the move keeps the viewport still; a swap far below the
                // anchor re-pins to the identical spot (visual no-op).
                val anchorIndex = todayListState.firstVisibleItemIndex
                val anchorOffset = todayListState.firstVisibleItemScrollOffset
                sectionOrder = sectionOrder.movedTodaySection(dragged, target)
                todayListState.scrollToItem(anchorIndex, anchorOffset)
            }
            if (sectionDrag.autoScrollPxPerSecond != 0f && dtSec > 0f) {
                todayListState.scrollBy(sectionDrag.autoScrollPxPerSecond * dtSec)
            }
        }
    }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard"), a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only, these cards read the SAME values the rest of Today already loads.
    // SharedPreferences isn't reactive, so it's mirrored into local state and re-read when the editor saves.
    var showDashboardEditor by remember { mutableStateOf(false) }
    var enabledDashboardCards by remember { mutableStateOf(DashboardCardPrefs.enabled(context)) }

    // The pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced on Today so the buried
    // Explore features sit on the home screen (#582). The same merged resolvedSeries reads their detail
    // screens use; null simply renders a dash on that card. Mirror the iOS Today lane's stressToday /
    // fitnessAgeToday / vitalityToday loads (last resolved value over all history). Loaded off the main
    // thread; re-read as the data grows.
    // #849: seed from the ViewModel cache so a re-mount restores the pinned-card numbers instead of flashing
    // dashes while the heavy history-wide read is (now) skipped for unchanged data.
    val cardsSig = days.hashCode()
    var stressToday by remember(activeStrapId) {
        mutableStateOf(
            viewModel.todayStressCache.takeIf {
                viewModel.todayCardsLoadedDeviceId == activeStrapId
            },
        )
    }
    var fitnessAgeToday by remember(ageMetricState, activeStrapId) {
        mutableStateOf(viewModel.todayFitnessAgeCache.takeIf {
            viewModel.todayCardsLoadedSig == cardsSig &&
                viewModel.todayCardsLoadedDeviceId == activeStrapId &&
                viewModel.todayCardsLoadedProfileSig == ageMetricState &&
                viewModel.todayCardsLoadedAgeMetricVersion == ageMetricDataVersion
        })
    }
    var vitalityToday by remember(ageMetricState, activeStrapId) {
        mutableStateOf(viewModel.todayVitalityCache.takeIf {
            viewModel.todayCardsLoadedSig == cardsSig &&
                viewModel.todayCardsLoadedDeviceId == activeStrapId &&
                viewModel.todayCardsLoadedProfileSig == ageMetricState &&
                viewModel.todayCardsLoadedAgeMetricVersion == ageMetricDataVersion
        })
    }
    LaunchedEffect(
        days,
        activeStrapId,
        ageMetricProfileVersion,
        ageMetricDataVersion,
        deferHistoricalQueries,
    ) {
        if (deferHistoricalQueries) return@LaunchedEffect
        // #849 re-mount guard: skip the whole-history scan when `days` is content-identical to the last load
        // (data class hashCode is a stable structural signature). The marker + cached values live on the
        // long-lived ViewModel, so a tab-return / post-import re-mount restores the numbers without re-reading.
        val sig = cardsSig
        if (viewModel.todayCardsLoadedSig == sig &&
            viewModel.todayCardsLoadedDeviceId == activeStrapId &&
            viewModel.todayCardsLoadedProfileSig == ageMetricState &&
            viewModel.todayCardsLoadedAgeMetricVersion == ageMetricDataVersion
        ) return@LaunchedEffect
        // Read each pinned card from the SAME source its own detail screen reads, the proven path that
        // already shows real numbers there (and the resolution iOS's exploreSeries uses). Stress is derived
        // from the imported strap data (StressScreen reads "my-whoop"); Fitness age + Vitality are
        // NOOP-COMPUTED weekly scores the IntelligenceEngine writes under "<activeStrapId>-noop". Read them
        // through the computed UNION (active strap's sibling + canonical "my-whoop-noop"), the same helper
        // HealthScreen uses - a hardcoded "my-whoop-noop" misses a live-BLE strap's "whoop-<mac>-noop" (#349).
        // Take the latest value (series are day-ascending), null → the card shows a dash, never a fabricated number.
        // #753: build the SAME StressModel the detail screen (StressScreen) shows and take `model.score`,
        // rather than the stress series' last banked row. StressModel.build prefers today's stored stress row
        // but otherwise DERIVES today's score from the live `days` RHR/HRV baseline; the old `.lastOrNull()`
        // read returned the latest *banked* day, so on a day with no stored stress row the pinned card sat on
        // yesterday's number (e.g. "2") while the detail page moved on. Reading the stored series the same way
        // StressScreen does (day → value, clamped 0–3) and feeding the same `days` ties the two together; both
        // recompute off `days`, so the pinned card stays in sync. null (no usable signal) keeps the honest
        // "Calibrating" placeholder, matching StressScreen's empty state.
        val requestDeviceId = activeStrapId
        val loadedStress = loadTodayBestEffortResult {
            val stored = viewModel.repo.metricSeries("my-whoop", "stress", "0000-01-01", "9999-12-31")
                .associate { it.day to it.value.coerceIn(0.0, 3.0) }
            StressModel.build(days, stored)?.score
        }
        val newFitnessAge = loadTodayBestEffortResult {
            viewModel.repo.latestMetricComputedUnion(requestDeviceId, "fitness_age")?.value
        }
        val newVitality = loadTodayBestEffortResult {
            viewModel.repo.latestMetricComputedUnion(requestDeviceId, "vitality")?.value
        }
        val fitnessProfile = loadTodayBestEffortResult {
            viewModel.repo.latestMetricComputedUnion(
                requestDeviceId, AgeMetricProfile.FITNESS_AGE_KEY,
            )?.value
        }
        val vitalityProfile = loadTodayBestEffortResult {
            viewModel.repo.latestMetricComputedUnion(
                requestDeviceId, AgeMetricProfile.VITALITY_KEY,
            )?.value
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId != requestDeviceId) return@LaunchedEffect
        val allPinnedCardReadsSucceeded = listOf(
            loadedStress,
            newFitnessAge,
            newVitality,
            fitnessProfile,
            vitalityProfile,
        ).all { it.succeeded }
        if (!allPinnedCardReadsSucceeded) return@LaunchedEffect
        stressToday = loadedStress.value
        fitnessAgeToday = newFitnessAge.value.takeIf {
            profileStore.acceptsFitnessAge(fitnessProfile.value)
        }
        vitalityToday = newVitality.value.takeIf {
            profileStore.acceptsVitality(vitalityProfile.value)
        }
        // Cache the computed triple + signature so a later re-mount with unchanged data restores them and
        // short-circuits the history-wide read above.
        viewModel.todayStressCache = stressToday
        viewModel.todayFitnessAgeCache = fitnessAgeToday
        viewModel.todayVitalityCache = vitalityToday
        viewModel.todayCardsLoadedSig = sig
        viewModel.todayCardsLoadedDeviceId = activeStrapId
        viewModel.todayCardsLoadedProfileSig = ageMetricState
        viewModel.todayCardsLoadedAgeMetricVersion = ageMetricDataVersion
    }

    // #713, strap battery runtime estimate ("~X left") for the Data-sources battery row. The battery lane
    // banks a SoC time series; here we read it and run the SHARED BatteryEstimator (the iOS twin computes the
    // same value off LiveState.batteryEstimate). Rated-life fallback is chosen by strap generation: WHOOP 5/MG
    // gets the ~12-day figure, WHOOP 4.0 the ~4.5-day one. Recomputed when the banked series grows (a new
    // reading lands ~every 8 min), when the link comes/goes, or when the strap generation resolves. Charging
    // hides it (no "X left" while topping up); a too-short discharge run returns null and the badge shows just
    // the %. Display rule: hours < 48 -> "~Nh left", else "~N days left"; null hides the estimate.
    var batteryEstimateText by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(
        liveSnap.connected,
        liveSnap.batteryPct,
        liveSnap.isGeneration5,
        liveSnap.charging,
        deferHistoricalQueries,
    ) {
        if (deferHistoricalQueries) return@LaunchedEffect
        batteryEstimateText = if (!liveSnap.connected || liveSnap.charging == true) {
            null
        } else {
            runCatching {
                val now = System.currentTimeMillis() / 1000
                // A wide window: SoC readings are sparse (~8 min apart), so a few days back is plenty for the
                // estimator to find the trailing discharge run and still cheap to load.
                val from = now - 14L * 86_400
                val samples = viewModel.repo.batterySamples("my-whoop", from, now, limit = 2_000)
                    .mapNotNull { s -> s.soc?.let { s.ts to it } }
                val rated = if (liveSnap.isGeneration5) BatteryEstimator.ratedLifeHoursWhoop5
                            else BatteryEstimator.ratedLifeHoursWhoop4
                // Battery test mode (Test Centre #713): emit the discharge-run / fitted-slope / gate ANALYSIS
                // trace, not only the per-reading "bank soc=" line. This LaunchedEffect re-runs on a natural
                // throttle (battery% / connection / charging changes), never a tight loop, and reuses the
                // samples + rated just loaded, so there is no extra Room read. estimateTrace returns the SAME
                // Estimate the badge shows, so no displayed number changes. Gated zero-cost when the mode is off
                // (one SharedPreferences bool read) and routed to the .battery-tagged strap log via externalLog.
                if (com.noop.testcentre.TestCentre.from(context)
                        .active(com.noop.testcentre.TestDomain.BATTERY)) {
                    for (line in BatteryEstimator.estimateTrace(samples, rated).second) {
                        viewModel.ble.externalLog(line, com.noop.testcentre.TestDomain.BATTERY)
                    }
                }
                BatteryEstimator.estimate(samples, rated)?.let { est ->
                    val hours = est.hoursRemaining
                    if (!hours.isFinite() || hours <= 0.0) null
                    else if (hours < 48) "~${hours.roundToInt()}h left"
                    else {
                        val daysLeft = (hours / 24).roundToInt()
                        "~$daysLeft day${if (daysLeft == 1) "" else "s"} left"
                    }
                }
            }.getOrNull()
        }
    }

    // #616: ONE calorie definition across the card, the Key-Metrics tile and the detail — resolve per day,
    // IMPORTED-FIRST (the phone's Apple/Health-Connect activeKcal, the figure these surfaces already showed),
    // falling back to NOOP's on-device HR estimate (activeKcalEst) only for days the phone didn't cover.
    // Keyed by day; `caloriesByDay` feeds the SELECTED-day value the dashboard card + Key-Metrics tile both
    // read — day-scoped like every other card, and like steps.
    var caloriesByDay by remember(activeStrapId) {
        mutableStateOf<Map<String, Double>>(emptyMap())
    }
    LaunchedEffect(days, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val loaded = loadTodayBestEffort {
            val onDevice = viewModel.repo.resolvedSeries("active_kcal", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = activeStrapId).points.associate { it.day to it.value }
            val imported = LinkedHashMap<String, Double>()
            for (r in viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31") +
                viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31")) {
                r.activeKcal?.takeIf { it > 0 }?.let { imported.putIfAbsent(r.day, it) }
            }
            (onDevice.keys + imported.keys)
                .mapNotNull { day -> (imported[day] ?: onDevice[day])?.let { day to it } }.toMap()
        } ?: return@LaunchedEffect
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) caloriesByDay = loaded
    }

    // #616: the Calories tile's 14-day sparkline — the IMPORTED-FIRST resolved series (caloriesByDay),
    // windowed to the trailing calendar window, so a Health-Connect / Apple-only calorie user gets a trend
    // that matches the tile's value (not the on-device estimate alone). Mirrors restCompositeSpark's build.
    var caloriesSpark by remember { mutableStateOf<List<Double>>(emptyList()) }
    LaunchedEffect(caloriesByDay, selectedDay, keyMetricsWindowDays) {
        val cutoff = selectedDay.minusDays((keyMetricsWindowDays - 1).toLong()).toString()
        val end = selectedDay.toString()
        caloriesSpark = caloriesByDay.entries
            .filter { it.key in cutoff..end }
            .sortedBy { it.key }
            .map { it.value }
    }

    // HYDRATION (opt-in, default OFF), the Today "Hydration" card + its detail are hidden unless the user
    // turns Hydration tracking on in Settings. When on, the card reads today's logged total (ml, from the
    // local-only HydrationStore series) against the pure HydrationGoal (sex baseline + today's Effort bump).
    // Both are loaded off the main thread and re-read as the day's data grows; SharedPreferences isn't
    // reactive, so the toggle is read once into local state.
    val hydrationEnabled = remember { NoopPrefs.hydrationTracking(context) }
    // Day-cycle scene backdrop (#698). Default ON. When off, Today drops the SceneScreenBackground and
    // the scaffold paints the plain dark surface canvas instead. SharedPreferences isn't reactive, so
    // this is read once into local state (mirrors iOS @AppStorage in TodayView).
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    // "Sky behind cards" (opt-in, default OFF): extend the day-cycle sky behind the WHOLE scroll so the
    // Card-transparency slider reveals it under every card (no effect when the scene is off). Read once.
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    var hydrationTotalMl by remember { mutableStateOf(0.0) }
    // #989: `days` only changes on a data refresh, which a hydration write never causes, so the card sat
    // stale after logging a drink until an unrelated sync landed. Keying on the store's mutationSeq too
    // re-reads the one metric row the moment a drink is logged / edited / deleted. Mirrors the iOS
    // Repository.hydrationSeq trigger.
    val hydrationSeq by HydrationStore.mutationSeq.collectAsStateWithLifecycle()
    LaunchedEffect(days, hydrationEnabled, hydrationSeq) {
        hydrationTotalMl = if (hydrationEnabled) {
            runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0)
        } else 0.0
    }
    // The day's Effort/strain (0..100) drives the goal's effort bump. Prefer the live in-progress Effort
    // for today (floored at the stored value, mirroring the Effort gauge) so the goal reflects a hard day
    // as it accrues; null leaves the bump at 0. Computed below where liveTodayStrain is in scope.
    val hydrationGoalMl = remember(displayMetric, profileStore) {
        if (!hydrationEnabled) 0 else HydrationGoal.dailyGoalMl(profileStore.sex, displayMetric?.strain)
    }

    // "How your scores work" guide, opened from the per-score ⓘ affordances and the one-time
    // first-run card. `guideSection` carries which score to deep-link to (null = open at the top);
    // `showGuide` gates the presenting Dialog. The first-run card's seen-state lives in
    // ScoringGuidePrefs and is read once (SharedPreferences isn't reactive), then driven locally.
    var showGuide by remember { mutableStateOf(false) }
    var guideSection by remember { mutableStateOf<ScoreSection?>(null) }
    val openGuide: (ScoreSection?) -> Unit = { section ->
        guideSection = section
        showGuide = true
    }
    // A1 (#514/#706): the Charge breakdown sheet, opened by tapping the hero Charge ring. Hosts the
    // existing RecoveryDriversSection (gated to the calibration countdown when the night can't score) plus
    // the folded Readiness card (S4). Not persisted, so it reopens closed. Mirrors iOS showChargeBreakdown.
    var showChargeBreakdown by remember { mutableStateOf(false) }
    // LIVE SESSIONS (beta, default ON): the "Start session" entry under the hero + its full-screen Dialog
    // (the same presentation the live-workout overlay / Charge breakdown use — deliberately NOT a nav
    // destination, so dismissing it leaves the session's runner coaching and this entry is the way back
    // in). Gated on the Settings `live_sessions_beta` flag; SharedPreferences isn't reactive, so it's read
    // once into local state like the hydration/day-cycle gates above. The ACTIVE runner is also collected
    // here (null ↔ runner only — the per-second snapshot is scoped inside the entry card) so a running
    // session keeps its way-back-in card even if the beta flag was just switched off.
    var showLiveSession by remember { mutableStateOf(false) }
    val liveSessionsEnabled = remember { LiveSessionPrefs.enabled(context) }
    val activeLiveSession by LiveSessionRunner.active.collectAsStateWithLifecycle()
    // The journal widget's own opt-out (default ON). Read here too so its reorderable section emits no
    // item when disabled — an always-present zero-height slot would leave a blank draggable gap. Same
    // remember-once idiom the card uses; a resume/recompose re-reads it. (#656)
    val journalReminderOn = remember { NoopPrefs.journalReminderEnabled(context) }
    // S4: the Synthesis card collapses to a one-liner that expands on tap (default collapsed). Mirrors iOS.
    var synthesisExpanded by remember { mutableStateOf(false) }
    // Key Metrics always shows the complete catalog with the user's three-to-five pins first. Data Sources
    // still collapses to its summary.
    var sourcesExpanded by remember { mutableStateOf(false) }
    var scoringCardSeen by remember { mutableStateOf(ScoringGuidePrefs.cardSeen(context)) }

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // via the shared TodayCardDismissal key. Read once (SharedPreferences isn't reactive), driven locally.
    var scoresBuildingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_SCORES_BUILDING))
    }
    var newHereDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_NEW_HERE))
    }
    // #827: the calibrating note's own dismissed flag, read once from the same shared store.
    var calibratingDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_CALIBRATING))
    }
    // The carried "Latest sleep · <date>" note's dismissed flag (iOS has no such card; on Android it's
    // dismissible so it doesn't sit permanently above the hero and break the compact look). Read once.
    var carriedSleepDismissed by remember {
        mutableStateOf(TodayCardDismissal.isDismissed(context, CARD_CARRIED_SLEEP))
    }
    // Dismiss a Today info-card INTO the inbox: persist its flag, hide it, and post a restorable
    // `.dismissedCard` update carrying the card id. Mirrors the iOS `dismissTodayCard`.
    val dismissTodayCard: (String, String, String) -> Unit = { id, title, message ->
        TodayCardDismissal.setDismissed(context, id, true)
        when (id) {
            CARD_SCORES_BUILDING -> scoresBuildingDismissed = true
            CARD_NEW_HERE -> newHereDismissed = true
            CARD_CALIBRATING -> calibratingDismissed = true
            CARD_CARRIED_SLEEP -> carriedSleepDismissed = true
        }
        updateStore?.post(
            UpdateItem(
                kind = UpdateKind.DISMISSED_CARD,
                title = title,
                message = message,
                restorePayload = id,
            ),
        )
    }
    // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the card
    // reappears (the inbox also cleared the shared pref directly, but this re-reads it into local state
    // for an already-mounted Today). Cleared once handled. Mirrors the iOS restoreRequest observer.
    val restoreSignal = updateStore?.restoreRequest
    LaunchedEffect(restoreSignal) {
        if (updateStore != null && restoreSignal != null) {
            when (restoreSignal) {
                CARD_SCORES_BUILDING -> scoresBuildingDismissed = false
                CARD_NEW_HERE -> newHereDismissed = false
                CARD_CALIBRATING -> calibratingDismissed = false
                CARD_CARRIED_SLEEP -> carriedSleepDismissed = false
            }
            updateStore.restoreRequest = null
        }
    }

    // Announce NEW history to the inbox only when the NEWEST day-key (max yyyy-MM-dd) moves strictly
    // forward, not on a count change (#521). A background recompute rebuilds the window via
    // delete-then-reinsert, so the count momentarily dips and recovers while the newest key is unchanged
    //, keying off the count mistook that churn for new history and re-posted "New data added" on a
    // loop. The baseline is PERSISTED in SharedPreferences (not `remember`), so a relaunch over the same
    // history never re-announces. Empty baseline = first sight → record silently, never announce
    // historical data. The "added" count is the distinct days strictly above the old watermark, real,
    // never fabricated. Deep-links to Trends. Mirrors the Swift `announceNewDaysIfNeeded`.
    LaunchedEffect(days, updateStore, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val store = updateStore ?: return@LaunchedEffect
        val newestKey = days.maxOfOrNull { it.day } ?: return@LaunchedEffect   // no history yet
        val previousKey = NewDataWatermark.lastAnnouncedKey(context)
        NewDataWatermark.setLastAnnouncedKey(context, newestKey)
        if (previousKey.isEmpty()) return@LaunchedEffect            // first sight → silent baseline
        if (newestKey <= previousKey) return@LaunchedEffect         // recompute churn, not new history
        val added = days.map { it.day }.toSet().count { it > previousKey }
        if (added <= 0) return@LaunchedEffect
        val daysWord = if (added == 1) "day" else "days"
        store.post(
            UpdateItem(
                kind = UpdateKind.READING,
                title = uiString(R.string.l10n_today_screen_new_data_added_e59345b4),
                message = "$added new $daysWord of history is ready in Trends.",
                deepLink = "trends",
            ),
        )
    }

    // The newest Apple Health / Health Connect body weight, loaded off the main thread. Null until the
    // load runs or when neither source carries a weight, the Weight tile then falls back to the profile.
    var weightKg by remember(activeStrapId) { mutableStateOf<Double?>(null) }
    LaunchedEffect(days, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val loaded = loadTodayBestEffort {
            latestWeightKg(
                viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31"),
                viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31"),
            )
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) weightKg = loaded
    }

    // Steps for the selected day from imported Apple Health / Health Connect data, the Today Steps
    // tile's measured source. A WHOOP 4.0 DOES count
    // steps (in the official WHOOP app), but NOOP can't yet read them off the strap over Bluetooth, so
    // on a 4.0 the tile shows your imported steps instead of "No Data". Reloads as the day selector
    // moves. This measured count outranks WHOOP 5/MG's @57 motion estimate. (#150)
    var importedStepsForDay by remember(activeStrapId) { mutableStateOf<Int?>(null) }
    var importedStepsByDay by remember(activeStrapId) {
        mutableStateOf<Map<String, Int>>(emptyMap())
    }
    LaunchedEffect(days, selectedDayKey, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        // Today's steps keep moving after the manual one-shot HC import, so the stored row goes
        // stale within minutes, top it up with ONE live StepsRecord read before the stored-row
        // read below. Best-effort: any HC hiccup just falls through to whatever is stored. (#150)
        if (selectedDayOffset == 0) {
            try {
                HealthConnectImporter.refreshTodaySteps(context, viewModel.repo)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) { /* best-effort */ }
        }
        val apple = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31")
        val healthConnect = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31")
        val loaded = (apple + healthConnect).filter { it.steps != null }
            .groupBy { it.day }.mapValues { (_, rows) -> rows.mapNotNull { it.steps }.max() }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) {
            importedStepsByDay = loaded
            importedStepsForDay = loaded[selectedDayKey]
        }
    }

    // On-device steps ESTIMATE for the selected day (key "steps_est", computed "-noop" source). The
    // Steps tile prefers a measured phone import, then the @57 motion-derived value; only when a day has
    // neither does it fall back to this calibrated estimate. Every strap-derived path is labelled as an
    // estimate. resolvedSeries reads the computed source for the my-whoop key, exactly like
    // the Explore "steps_est" metric. Null until loaded / no estimate for the day. (#150)
    var stepsEstForDay by remember(activeStrapId) { mutableStateOf<Int?>(null) }
    var stepsEstByDay by remember(activeStrapId) {
        mutableStateOf<Map<String, Int>>(emptyMap())
    }
    LaunchedEffect(days, selectedDayKey, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val byDay = loadTodayBestEffort {
            viewModel.repo.resolvedSeries("steps_est", "my-whoop", "0000-00-00", "9999-99-99",
                strapDeviceId = activeStrapId)
                .values.associate { it.first to it.second }
        } ?: return@LaunchedEffect
        val loaded = byDay.mapValues { Math.round(it.value).toInt() }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) {
            stepsEstByDay = loaded
            stepsEstForDay = loaded[selectedDayKey]
        }
    }

    // The selected day's representative activity class for the Steps tile icon (#316 / @63). Reads the day's
    // step samples (now carrying `activityClass` after the v13 column) over the local-day window and takes the
    // LAST non-null class as "what the wrist was doing most recently today" (0=still, 1=walk, 2=run). null when
    // the day has no classed sample (a 4.0 strap, a pre-v13 row, or every record's @63 byte was invalid), then
    // the tile shows NO icon. Mirrors the iOS Today step-activity read exactly. Best-effort: a read hiccup just
    // drops the optional icon.
    var stepActivityClassForDay by remember(activeStrapId) { mutableStateOf<Int?>(null) }
    LaunchedEffect(days, selectedDay, today, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDayOffset == 0) now else (nextStart - 1)
        // #908 family: read the active strap ∪ canonical "my-whoop" union, NOT a hardcoded "my-whoop". A strap
        // re-added through the device manager banks its live step samples (which carry the @63 class) under its
        // own fresh id, so a pinned "my-whoop" read dropped the tile icon for a re-added strap. Single-WHOOP ⇒
        // one id ⇒ byte-identical read. Mirrors the iOS Repository.stepActivityClassLatest union.
        val loaded = loadTodayBestEffort {
            viewModel.repo.stepActivityClassLatestUnion(activeStrapId, start, end)
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) stepActivityClassForDay = loaded
    }

    // Rest number + sparkline share one resolved history read. The day/value map lives on the ViewModel so
    // a tab return restores it without touching Room, and changing the selected day only filters memory.
    val restCompositeKey = TodayRestCompositeCacheKey(
        dailyDataSignature = days.hashCode(),
        activeStrapId = activeStrapId,
        restDataVersion = restDataVersion,
    )
    var restCompositeByDay by remember(activeStrapId) {
        mutableStateOf(
            viewModel.todayRestCompositeCache.takeIf {
                viewModel.todayRestCompositeLoadedKey?.activeStrapId ==
                    restCompositeKey.activeStrapId
            } ?: emptyMap(),
        )
    }
    LaunchedEffect(days, activeStrapId, restDataVersion, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        if (viewModel.todayRestCompositeLoadedKey == restCompositeKey) {
            restCompositeByDay = viewModel.todayRestCompositeCache
            com.noop.AppDiagnosticsRecorder.record(
                "today.rest_composite_load",
                fields = mapOf(
                    "outcome" to "cache_restore",
                    "result_bucket" to todayRestResultBucket(restCompositeByDay.size),
                ),
            )
            return@LaunchedEffect
        }
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation(
            "today.rest_composite_load",
        )
        var diagnosticOutcome = "cancelled"
        var diagnosticFields = emptyMap<String, String>()
        try {
            val loaded = loadTodayRestWithRetry {
                viewModel.repo.resolvedSeries(
                    "sleep_performance",
                    "my-whoop",
                    "0000-00-00",
                    "9999-99-99",
                    strapDeviceId = activeStrapId,
                ).values.associate { it.first to it.second }
            }
            restCompositeByDay = loaded
            viewModel.todayRestCompositeCache = loaded
            viewModel.todayRestCompositeLoadedKey = restCompositeKey
            diagnosticOutcome = "success"
            diagnosticFields = mapOf(
                "result_bucket" to todayRestResultBucket(loaded.size),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            diagnosticOutcome = "failed"
        } finally {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = diagnosticOutcome,
                fields = diagnosticFields,
            )
        }
    }

    // #977: the tail fallback is freshness-gated, so an old scored night cannot pose as today's Rest.
    val restScoreForDay = remember(restCompositeByDay, selectedDayKey, selectedDayOffset) {
        val latest = restCompositeByDay.entries.maxByOrNull { it.key }
        freshRestScore(
            todayValue = restCompositeByDay[selectedDayKey],
            lastDay = latest?.key,
            lastValue = latest?.value,
            isTodaySelected = selectedDayOffset == 0,
            today = selectedDayKey,
        )
    }

    // The Rest tile plots the same 0–100 composite as its number, trailing the selected calendar window.
    val restCompositeSpark = remember(restCompositeByDay, selectedDay, keyMetricsWindowDays) {
        val cutoff = selectedDay.minusDays((keyMetricsWindowDays - 1).toLong()).toString()
        val end = selectedDay.toString()
        restCompositeByDay.entries
            .filter { it.key in cutoff..end }
            .sortedBy { it.key }
            .map { it.value }
    }

    // Calibrated SpO2 can come from a wearable import, Apple Health, or Health Connect. The live band
    // stream intentionally stores raw red/IR ADC only, so use the cross-source resolver and never turn
    // those raw channels into a percentage.
    var resolvedSpo2Window by remember(activeStrapId) {
        mutableStateOf(ResolvedSpo2Window())
    }
    val resolvedSpo2ByDay = if (resolvedSpo2Window.anchorDay == selectedDayKey) {
        resolvedSpo2Window.values
    } else {
        emptyMap()
    }
    LaunchedEffect(
        days,
        selectedDayKey,
        keyMetricsWindowDays,
        activeStrapId,
        deferHistoricalQueries,
    ) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val anchor = runCatching { LocalDate.parse(selectedDayKey) }.getOrDefault(selectedDay)
        val lookbackDays = maxOf(30, keyMetricsWindowDays)
        val values = loadTodayBestEffort {
            viewModel.repo.resolvedSeries(
                key = "spo2",
                preferredSource = "my-whoop",
                from = anchor.minusDays((lookbackDays - 1).toLong()).toString(),
                to = anchor.toString(),
                strapDeviceId = activeStrapId,
            ).points
                .filter { it.value.isFinite() && it.value > 0.0 && it.value <= 100.0 }
                .associate { it.day to it.value }
        } ?: return@LaunchedEffect
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) {
            resolvedSpo2Window = ResolvedSpo2Window(selectedDayKey, values)
        }
    }

    // Provenance (COMPONENT 4): the REAL per-metric merge winner for the selected day's three hero scores,
    // keyed by metric key ("recovery" / "strain" / "sleep_performance"); each value is the RAW source id the resolver
    // returned (e.g. "my-whoop", "my-whoop-noop", "apple-health"). resolvedSeries applies the SAME
    // imported-WHOOP > NOOP-computed > Apple-Health precedence the dashboard merge uses field-by-field
    // (WhoopRepository.mergeDaily), so the card-level badge names the sources that ACTUALLY supplied
    // that day's scores rather than making a blanket day-level claim. Mirrors the Swift Today lane's
    // `provenanceByMetric` resolution exactly (the winner is the last resolved point on selectedDayKey).
    var provenanceByMetric by remember(activeStrapId) {
        mutableStateOf<Map<String, String>>(emptyMap())
    }
    LaunchedEffect(days, selectedDayKey, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val resolved = mutableMapOf<String, String>()
        for (key in listOf("recovery", "strain", "sleep_performance")) {
            val win = loadTodayBestEffort {
                viewModel.repo.resolvedSeries(key, "my-whoop", selectedDayKey, selectedDayKey,
                    strapDeviceId = activeStrapId)
                    .points.lastOrNull { it.day == selectedDayKey }?.source
            }
            if (win != null) resolved[key] = win
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) provenanceByMetric = resolved
    }

    // LIVE in-progress Effort for TODAY (#402), mirrors the iOS TodayView live-Effort fix. The stored
    // `day?.strain` lags: early in the day it shows yesterday's completed Effort (or a stale 0.0) until the
    // heavy daily pass re-scores. So for offset 0 only, integrate today's raw HR over the SAME window the
    // HR trend uses (the logical day's local-midnight → now) through StrainScorer with the SAME params the
    // daily pass persists (Tanaka HR-max from age, or the manual override, the day's resting HR else the
    // default, profile sex), and prefer it on the Effort gauge. StrainScorer returns null below
    // `minReadings`, so before there's enough HR the gauge falls back to the stored value and never shows a
    // fabricated number. Any past day → null (the gauge uses the stored strain). Keyed on the same inputs
    // as the day-scoped loads so it reloads as the selector moves and as a sync/import grows the HR window.
    var liveTodayStrain by remember(activeStrapId) { mutableStateOf<Double?>(null) }
    LaunchedEffect(
        days,
        selectedDayKey,
        selectedDayOffset,
        activeStrapId,
        deferHistoricalQueries,
    ) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val loaded = if (selectedDayOffset == 0) {
            val zone = ZoneId.systemDefault()
            val start = selectedDay.atStartOfDay(zone).toEpochSecond()
            val now = System.currentTimeMillis() / 1000
            // #908: read the active strap ∪ canonical "my-whoop" union, NOT a hardcoded "my-whoop". A strap
            // re-added through the device manager banks its live HR under its own fresh id, so a pinned
            // "my-whoop" read returned nothing and Effort integrated to 0 off an empty series. Single-WHOOP
            // install resolves to "my-whoop" ⇒ one id ⇒ byte-identical read.
            val todayHr = loadTodayBestEffort {
                viewModel.repo.hrSamplesUnion(activeStrapId, start, now)
            } ?: emptyList()
            // effMaxHR resolution matches AnalyticsEngine: manual HR-max override first, else Tanaka from age.
            val effMaxHR = profileStore.hrMaxOverride.takeIf { it > 0 }?.toDouble()
                ?: if (profileStore.age > 0) StrainScorer.tanakaHRmax(profileStore.age.toDouble()) else null
            StrainScorer.strain(
                hr = todayHr,
                maxHR = effMaxHR,
                restingHR = displayMetric?.restingHr?.toDouble() ?: StrainScorer.defaultRestingHR,
                sex = profileStore.sex,
            )
        } else {
            null
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) liveTodayStrain = loaded
    }

    // Resolve once for every read-out: today's live value may lead the daily row, while the stored row
    // remains the never-decreasing floor when sparse live HR under-reads.
    val effortForDay = StrainScorer.effectiveEffort(
        live = if (selectedDayOffset == 0) liveTodayStrain else null,
        stored = displayMetric?.strain,
    )

    // Recovery cold-start: recovery is null until the HRV baseline crosses the seed gate
    // (Baselines.minNightsSeed valid nights). Show honest "calibrating, N of 4 nights" progress
    // instead of a bare "No Data" so a new BLE-only user knows scores are coming, not broken. (PR #85)
    val recoveryCalibration: Int? = if (selectedDayOffset == 0) {
        // Thread the persisted "Recalibrate HRV baseline" epoch (0 = none) so N folds the SAME
        // epoch-aware history the recovery engine folds — otherwise a post-recalibration user's pre-epoch
        // nights inflate the count past the seed gate and the score side wrongly reads NeedsStrap (Bug B).
        val hrvEpoch = NoopPrefs.of(context).getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble()
        recoveryCalibrationNights(
            days,
            beforeDay = selectedDayKey,
            hasRecovery = displayMetric?.recovery != null,
            hrvBaselineEpoch = hrvEpoch,
        )
    } else {
        null
    }

    // The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    // been scored yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    // night isn't scored until you wear it tonight), so a baseline-established user, past calibration, so
    // recoveryCalibration is null, saw the WHOLE recovery side blank ("No Data" Charge AND blank HRV /
    // resting-HR / respiratory / SpO₂ tiles + Synthesis + Contributors) while live HR kept ticking, which
    // reads as broken. This is the ONE prior row every recovery-derived read-out carries over from, the
    // way WHOOP keeps showing last recovery until the new one lands, it NEVER fabricates a number for the
    // new day, each carried read shows the REAL prior value labelled as prior, and any metric the prior
    // row genuinely lacks still falls through to "No Data". Non-null only when: it's today, today has no
    // recovery, and we're not mid-calibration (calibration owns its own copy). days is oldest→newest;
    // exclude the (still-null) today key so we never echo "today". Mirrors iOS lastScoredRecoveryDay.
    // #547 carry-over upper bound: the LATER of the logical "today" (rolls at 04:00) and the local
    // calendar day. Using the later key means a legitimate just-after-midnight carry-over of yesterday's
    // logical day is NOT dropped, while any FUTURE-dated row (a bad strap clock) still sorts past it and
    // is excluded. ISO date strings compare chronologically.
    val carryOverTodayKey = remember(todayDate) {
        maxOf(todayDate.toString(), java.time.LocalDate.now().toString())
    }
    val lastScoredRecoveryDay: DailyMetric? = remember(days, selectedDayKey, recoveryCalibration, selectedDayOffset, displayMetric, carryOverTodayKey) {
        lastScoredRecoveryDay(
            days = days,
            selectedDayKey = selectedDayKey,
            isToday = selectedDayOffset == 0,
            todayScored = displayMetric?.recovery != null,
            isCalibrating = recoveryCalibration != null,
            today = carryOverTodayKey,
        )
    }
    // The freshest STRICTLY-PRIOR night carrying a real overnight VITAL (HRV / resting-HR / respiratory),
    // recovery-INDEPENDENT (#543 follow-up). HRV/RHR/resp exist without a recovery score, so a post-update
    // re-analysis that nulls last night's recovery while preserving its avgHrv/restingHr must NOT fall back
    // to an OLDER recovery-scored day for the vitals (that's the tile-vs-card mismatch: the per-field tiles
    // already keep last night's real value; the whole-row card was discarding it). The vitals read PER-FIELD
    // today-first with THIS carry as the fallback, kept separate from lastScoredRecoveryDay (Charge ring /
    // Synthesis / Contributors / Readiness stay recovery-gated). Future-clock-safe: the upper bound is the
    // LATER of the resolved today row's own key and carryOverTodayKey, mirroring lastScoredRecoveryDay's
    // #547 guard. Non-null only on today (offset 0). Mirrors iOS Repository.lastVitalsDay.
    val lastVitalsDay: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastVitalsRow(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    // PER-FIELD SpO₂ / skin-temp carries, the twin of lastVitalsDay for the two fields its predicate does
    // NOT check. The on-device engine writes spo2Pct = null (only raw spo2Red/spo2Ir), so every computed
    // "-noop" row lacks a percentage; only imported rows carry one. A whole-row carry (lastScoredRecoveryDay
    // or lastVitalsDay) therefore lands on a row with null spo2Pct/skinTempDevC and the Blood Oxygen /
    // Skin Temp cards read "No Data" even though an imported row holds a real reading. Resolving the two
    // fields independently (last strictly-prior row with the field non-null) mirrors iOS
    // TodayView.lastSpo2Day / lastSkinTempDay. Same #547 future-clock bound; non-null only on today.
    val lastSpo2Day: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastSpo2Row(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    val resolvedSpo2Day: DailyMetric? = remember(
        resolvedSpo2ByDay, selectedDayKey, selectedDayOffset,
    ) {
        val entry = resolvedSpo2ByDay[selectedDayKey]?.let { selectedDayKey to it }
            ?: if (selectedDayOffset == 0) {
                resolvedSpo2ByDay.entries
                    .filter { it.key <= selectedDayKey }
                    .maxByOrNull { it.key }
                    ?.let { it.key to it.value }
            } else {
                null
            }
        entry?.let { (day, value) ->
            DailyMetric(deviceId = "resolved-spo2", day = day, spo2Pct = value)
        }
    }
    val displaySpo2Day = resolvedSpo2Day ?: lastSpo2Day
    val lastSkinTempDay: DailyMetric? = remember(days, carryOverTodayKey, selectedDayOffset, displayMetric) {
        if (selectedDayOffset == 0) lastSkinTempRow(days, maxOf(displayMetric?.day ?: "", carryOverTodayKey)) else null
    }
    // Carry-over Charge for TODAY, the prior scored row's recovery + its "Last night · <date>" caption.
    // Derived from lastScoredRecoveryDay so Charge and every other recovery tile carry the SAME prior day.
    val lastScoredCharge: LastCharge? = remember(lastScoredRecoveryDay) {
        lastScoredRecoveryDay?.let { prior ->
            prior.recovery?.let { LastCharge(it, carriedCaption(prior.day, carryOverTodayKey)) }
        }
    }
    var carriedRecoverySource by remember(activeStrapId) { mutableStateOf<String?>(null) }
    LaunchedEffect(lastScoredRecoveryDay?.day, activeStrapId, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val carriedDay = lastScoredRecoveryDay?.day
        val loaded = if (carriedDay == null) {
            null
        } else {
            loadTodayBestEffort {
                viewModel.repo.resolvedSeries("recovery", "my-whoop", carriedDay, carriedDay,
                    strapDeviceId = activeStrapId)
                    .points.lastOrNull { it.day == carriedDay }
                    ?.source
            }
        }
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId == activeStrapId) carriedRecoverySource = loaded
    }

    // Explainability (COMPONENT 2): the honest state of the score side for TODAY, scored / calibrating /
    // carried-last-night / needs-strap. One state, never a bare blank, and never a fabricated number. Only
    // computed for today (offset 0); a past day shows its own row, not a "needs the strap" prompt.
    val scoreState: ScoreState = remember(displayMetric, recoveryCalibration, lastScoredRecoveryDay, selectedDayOffset, carryOverTodayKey) {
        if (selectedDayOffset == 0) {
            scoreStateForToday(
                todayRecovery = displayMetric?.recovery,
                calibratingNights = recoveryCalibration,
                carriedDay = lastScoredRecoveryDay,
                today = carryOverTodayKey,
            )
        } else {
            ScoreState.Scored(displayMetric?.recovery ?: 0.0)
        }
    }

    // One honest card-level badge, matching LiquidTodayView: identical winners collapse to one label;
    // mixed winners show at most two sources in Charge / Effort / Rest order so the pill stays compact.
    val heroSourceLabel = remember(
        provenanceByMetric,
        carriedRecoverySource,
        displayMetric?.recovery,
        lastScoredCharge,
        activeStrapId,
    ) {
        scoreHeroSourceLabel(
            provenanceByMetric = provenanceByMetric,
            carriedRecoverySource = carriedRecoverySource,
            usesCarriedRecovery = displayMetric?.recovery == null && lastScoredCharge != null,
            deviceId = activeStrapId,
        )
    }

    // 14-day trailing calendar window ending on the phone's actual local day.
    // Old imports stay in history, but they do not fill the Today trend tiles.
    val window = rememberTrendWindow(
        days, selectedDay, keyMetricsWindowDays, importedStepsByDay, stepsEstByDay,
        resolvedSpo2ByDay,
    )

    LaunchedEffect(days, activeStrapId, workoutDataVersion, deferHistoricalQueries) {
        if (deferHistoricalQueries) return@LaunchedEffect
        // #849: this footer pass is the heavy one. It derives HR per imported workout from raw strap samples
        // (fillWorkoutHrFromStrap = potentially hundreds of raw-HR reads) and counts every workout / Apple /
        // Health-Connect row across ALL history. A bare Today re-mount (tab-away + return, or an Apple-Health
        // import that recreates the screen) re-fires this LaunchedEffect with the screen's `remember` state
        // reset, so it re-ran the full pass for byte-identical data every time: the lag users see returning
        // to Today after an import. The signature is `days` (a `data class` list, so its structural
        // hashCode is a stable content signature) PLUS the 14-day cross-source workout union: `days`
        // alone missed workouts imported without touching the Whoop day summaries (e.g. a Health
        // Connect session recorded today), so the "Last Workouts" feed stayed stale until the next
        // Whoop cycle bumped `days`. The union is a cheap windowed SELECT; only the heavy strap-HR
        // derivation and all-history counts below are skipped on a signature match. The marker lives
        // on the long-lived ViewModel, so it survives the re-mount that reset the screen state. A real
        // data change bumps the signature and re-runs, so no real update is dropped.
        val now = System.currentTimeMillis() / 1000
        val recentCutoff = LocalDate.now()
            .minusDays(13)
            .atStartOfDay(ZoneId.systemDefault())
            .toEpochSecond()
        val recentUnion = viewModel.repo.workoutsAllSources(activeStrapId, recentCutoff, now)
            .sortedByDescending { it.startTs }
        val sig = 31 * days.hashCode() + recentUnion.hashCode()
        if (viewModel.todayFooterLoadedSig == sig &&
            viewModel.todayFooterLoadedDeviceId == activeStrapId
        ) return@LaunchedEffect
        // Union of the active strap id + legacy "my-whoop" (#814), NOT the literal id alone: after a
        // re-pair the fresh recordings live under "whoop-<id>", and a pinned read undercounted them
        // in the Whoop pill exactly like the feed dropped them from "Latest Workouts".
        val whoopWorkouts = viewModel.repo.workoutsUnion(activeStrapId, 0L, now)
        // Apple Health and Health Connect are separate sources (since #34), keep them separate in the
        // provenance footer too, so Health Connect data isn't mislabelled under the "Apple Health" pill
        // (issue #53). The recent-workouts list below still unions all sources for a combined feed.
        val appleWorkouts = viewModel.repo.workouts("apple-health", 0L, now)
        val hcWorkouts = viewModel.repo.workouts("health-connect", 0L, now)
        val appleDaysCount = viewModel.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31").size
        val hcDaysCount = viewModel.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31").size
        val loadedFooter = TodayFooterState(
            // fillWorkoutHrFromStrap: imported sessions carry no HR, derive it from strap samples (#77).
            // #510: strap-native rows now read HR under their OWN recording strap (inside the fill), so a 2nd
            // WHOOP's workouts reconcile Avg HR + Effort from their own trace; imported rows keep the default.
            recentWorkouts = viewModel.repo.fillWorkoutHrFromStrap(recentUnion),
            whoopDays = days.size,
            whoopWorkouts = whoopWorkouts.size,
            appleDays = appleDaysCount,
            appleWorkouts = appleWorkouts.size,
            hcDays = hcDaysCount,
            hcWorkouts = hcWorkouts.size,
        )
        currentCoroutineContext().ensureActive()
        if (viewModel.activeStrapId != activeStrapId) return@LaunchedEffect
        footer = loadedFooter
        // Cache the result + record the signature so a later re-mount with unchanged data restores the footer
        // and short-circuits the heavy reload above.
        viewModel.todayFooterCache = footer
        viewModel.todayFooterLoadedSig = sig
        viewModel.todayFooterLoadedDeviceId = activeStrapId
    }

    // #817 - horizontal swipe to change day, alongside the header chevrons. `detectHorizontalDragGestures`
    // only claims HORIZONTAL drags, so the LazyColumn keeps its vertical scroll; we accumulate the drag and
    // resolve the day ONCE on lift via the pure `dayNavSwipeTarget` (rightward = older, leftward = newer,
    // clamped at today). The threshold is density-scaled from DAY_NAV_SWIPE_THRESHOLD_DP so a small wobble
    // during a scroll doesn't flip the day. Mirrors the iOS day-nav swipe lane.
    val swipeThresholdPx = with(LocalDensity.current) { DAY_NAV_SWIPE_THRESHOLD_DP.dp.toPx() }
    val daySwipeModifier = Modifier.pointerInput(Unit) {
        var accumulatedX = 0f
        detectHorizontalDragGestures(
            onDragStart = { accumulatedX = 0f },
            onDragEnd = {
                selectedDayOffset = dayNavSwipeTarget(selectedDayOffset, accumulatedX, swipeThresholdPx)
            },
            onHorizontalDrag = { _, dragAmount -> accumulatedX += dragAmount },
        )
    }
    val canPullToSync = todayPullToSyncEnabled(liveSnap.connected, liveSnap.bonded, historyBackfilling)
    val pullToSyncState = rememberPullToRefreshState()
    var pullToSyncRefreshing by remember { mutableStateOf(false) }
    LaunchedEffect(pullToSyncRefreshing, canPullToSync) {
        if (pullToSyncRefreshing) {
            if (canPullToSync) viewModel.syncNow()
            // Historical offloads can run for a while; the existing sync chip/note owns ongoing progress.
            pullToSyncRefreshing = false
        }
    }
    val hasCachedTodayContent = days.isNotEmpty()

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pullToRefresh(
                isRefreshing = pullToSyncRefreshing,
                state = pullToSyncState,
                enabled = canPullToSync,
                onRefresh = { pullToSyncRefreshing = true },
            ),
    ) {
    LazyScreenScaffold(
        modifier = daySwipeModifier,
        // title = null suppresses the big scaffold header (the nullable-title path); the compact
        // WHOOP-style top bar below replaces it, mirroring the iOS Today screen (todayTopBar).
        title = null,
        // Tighten the top inset now the big title is gone (Compose forbids negative padding, so this
        // expresses iOS's `.padding(top: -16)` as a smaller scaffold top padding).
        topPadding = 12.dp,
        // FIX 6 (compactness): the liquid Today matches the iOS Today's tight `VStack(spacing: 12)` section
        // rhythm rather than the app-wide 20dp row gap, so the whole screen reads as compact/slick as iOS.
        // Scoped to this scaffold — no other screen's rhythm changes.
        rowSpacing = 12.dp,
        // #today-layout (hold-to-drag): the hoisted list state the section drag reads (layoutInfo/scrollBy).
        listState = todayListState,
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky sits
        // behind the WHOLE top region, the liquid header + wordmark AND the hero vessels, full-bleed (full-width, up
        // behind the status bar via the scaffold's topBackground plumbing), top-aligned, settling into the
        // flat canvas over its lower half so the cards float OVER it on the theme surface. This is the
        // Android equivalent of the iOS `ScreenScaffold(topBackground: liquidScaffoldSky())`: it replaces
        // the classic day-cycle SceneScreenBackground with the liquid day-of-sky (LiquidSkyStatic — no
        // per-frame cost on this scroll-heavy screen). The other liquid screens drop in the SAME
        // LiquidScreenSky() slot verbatim.
        // #698, gated on the "Day-cycle background" setting (default ON). Off passes null, so the scaffold
        // paints the plain dark surface canvas instead, mirroring iOS's `showDayCycleBackground ? ... : nil`.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way down.
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        item {
        // LIQUID Today header (iOS LiquidTodayView.scene parity), a full structural rebuild to mirror the
        // iOS liquid Today element-for-element (NOT the old numeric-date + recording-light + bell header):
        //   LEFT  - a tappable title block: the big rounded-bold day title ("Today" / "Yesterday" / the
        //           weekday) over a human date line ("Friday, 3 July"). Tap opens month history.
        //   RIGHT — exactly the iOS four controls, in order: a filled HEART (→ Support), the PROFILE
        //           AVATAR (→ Settings), a "+" ADD button (→ quick actions), and the strap BATTERY RING.
        // The recording-status light and the notifications BELL are GONE from the header (iOS has neither);
        // the Updates inbox is relocated into the "+" quick-actions sheet (AppRoot), so the feature stays one
        // tap away without sitting in the Today header. Staggered in as the first section (index 0).
        val dayTitle = when (selectedDayOffset) {
            0 -> "Today"
            1 -> "Yesterday"
            else -> {
                val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
                keyDate.format(DateTimeFormatter.ofPattern("EEEE", Locale.US))
            }
        }
        // Human date line under the title - "Friday, 3 July" (weekday + day + month), NOT a numeric date.
        // Dated by the row ACTUALLY on screen (selectedDayKey follows the resolver at offset 0), matching
        // the iOS `dateLine` (EEEE, d MMMM). Mirrors iOS's date-under-title block.
        val humanDate = run {
            val keyDate = runCatching { LocalDate.parse(selectedDayKey) }.getOrNull() ?: selectedDay
            keyDate.format(DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale.US))
        }
        val headline = if (selectedDayOffset == 0) {
            uiString(R.string.appwide_today_greeting_format, greetingWord(), displayName)
        } else {
            dayTitle
        }
        LiquidTodayHeader(
            headline = headline,
            dateLine = humanDate,
            connected = liveSnap.connected,
            batteryPct = if (liveSnap.connected) liveSnap.batteryPct else null,
            charging = liveSnap.charging,
            syncStatus = { TodayHeaderSyncStatus(viewModel) },
            weatherState = weatherState.takeIf { selectedDayOffset == 0 },
            temperatureUnit = temperatureUnit,
            onWeatherClick = {
                when {
                    weatherState.snapshot != null ||
                        weatherState.status == TodayWeatherStatus.DENIED ||
                        weatherState.status == TodayWeatherStatus.UNAVAILABLE ||
                        weatherState.status == TodayWeatherStatus.FAILED -> {
                        showWeatherDetails = true
                    }
                    weatherState.status != TodayWeatherStatus.LOCATING -> {
                        weatherStore.enableAndRefresh {
                            weatherPermissionLauncher.launch(
                                Manifest.permission.ACCESS_COARSE_LOCATION,
                            )
                        }
                    }
                }
            },
            onOpenCalendar = onOpenCalendar,
            onOpenSettings = onOpenSettings,
            onOpenDevices = onOpenDevices,
            onArrange = { showLayoutEditor = true },
            onDashboardCards = { showDashboardEditor = true },
            onKeyMetrics = { showMetricsEditor = true },
            modifier = Modifier.staggeredAppear(0),
        )
        }

        // A "workout in progress" indicator whenever a manual workout is active (iOS parity: the Today
        // ActiveWorkoutIndicator). A tap routes to Live and re-opens the in-exercise overlay. Gated purely on
        // `activeWorkout`, so it auto-appears/clears with no extra lifecycle wiring. Its per-second clock
        // ticks inside the card's own LaunchedEffect, never recomposing the Today body.
        activeWorkout?.let { w ->
            item {
                WorkoutInProgressCard(workout = w, onReturn = onOpenActiveWorkout)
            }
        }

        item {
            TodaySyncingHistoryStatus(
                viewModel = viewModel,
                hasCachedContent = hasCachedTodayContent,
            )
        }

        // Design Reset (iOS parity): the "New here?" first-run card is off the Today dashboard for the
        // clean look, the scoring guide stays reachable from the i on each score and in Settings.

        // When there is no daily score yet (today's recovery is null / no history),
        // lead with the "live now, history one import away" note so the empty tiles
        // below are explained rather than just dashed out. A small × dismisses it INTO
        // the Updates inbox (restorable from there). Only anchored to today (offset 0).
        if (displayMetric?.recovery == null) {
            item {
            // Explained score state (COMPONENT 2): when there's no own number to show, say WHY and WHAT to
            // do. "Calibrating" (N more nights, no fake number), "Last night · <date>" (#802 carry-over)
            // or "Needs the strap" (no data overnight). The carried Charge now draws a dimmed filled ring on
            // the hero with NO in-ring caption, so its "Last night ..." note renders BELOW the rings here,
            // matching iOS explainedScoreNote. Today only; never a fabricated value.
            //
            // #827: NeedsStrap ALWAYS shows (a today-blocking state, not a recurring nag).
            if (selectedDayOffset == 0 && scoreState is ScoreState.NeedsStrap) {
                ScoreStateNote(scoreState)
            }
            // The carried "Latest sleep · <date>" / "Last night · <date>" note. iOS has NOTHING in this slot,
            // and the maintainer flagged it as breaking the compact liquid look sitting permanently above the
            // hero. So on Android it's dismissible-into-the-inbox (restorable) like the calibrating note: a
            // small × tucks it into Updates so it isn't a fixed fixture between the header and the hero.
            if (selectedDayOffset == 0 && scoreState is ScoreState.CarriedLastNight && !carriedSleepDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    ScoreStateNote(scoreState)
                    if (updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_CARRIED_SLEEP,
                                    scoreState.title,
                                    scoreState.detail,
                                )
                            },
                        )
                    }
                }
            }
            // #827: recurring baseline guidance is dismissible into the inbox. The completed seed night
            // has its own BaselineReady state rather than being coerced back to "1 more night".
            if (selectedDayOffset == 0 &&
                (scoreState is ScoreState.Calibrating || scoreState is ScoreState.BaselineReady) &&
                !calibratingDismissed
            ) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    ScoreStateNote(scoreState)
                    if (updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_CALIBRATING,
                                    scoreState.title,
                                    scoreState.detail,
                                )
                            },
                        )
                    }
                }
            }
            if (selectedDayOffset != 0 || !scoresBuildingDismissed) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    DataPendingNote(
                        title = uiString(R.string.l10n_today_screen_live_now_your_scores_are_building_cb05a4e8),
                        body = "Your live heart rate is working from Noop Band, and recovery, strain " +
                            "and sleep build from it over your next few nights of wear, sharpening as it " +
                            "learns your baseline. Want your full history instantly? Import your wearable " +
                            "export in Data Sources and it backfills in about a minute.",
                    )
                    // The × is only meaningful for today's card (a past day's note isn't dismissed).
                    if (selectedDayOffset == 0 && updateStore != null) {
                        TodayCardDismissButton(
                            modifier = Modifier.align(Alignment.TopEnd),
                            onClick = {
                                dismissTodayCard(
                                    CARD_SCORES_BUILDING,
                                    "Live now. Your scores are building.",
                                    "Recovery, Effort and Sleep build over your next few nights of wear.",
                                )
                            },
                        )
                    }
                }
            }
            }
        }

        if (alert != null) {
            item {
                IllnessBanner(
                    message = alert!!,
                    alreadyUnwell =
                        currentIllnessResult?.level == IllnessSignalEngine.Level.ALREADY_UNWELL,
                    onOpen = onOpenHealth,
                )
            }
        }

        // #486: the "Arrange" affordance moved UP into the header/wordmark cluster (see above) so it no
        // longer sits alone in its own full-width band here. It stays pinned; only its position changed.

        // #today-layout: EVERY Today section — including the Charge/Effort/Rest hero and the Start-session
        // entry — renders in the user's saved order (TodayLayoutPrefs); only the top bar + this Arrange
        // affordance stay pinned. Each section is ONE keyed item wrapped in [TodayReorderableSection]:
        // LONG-PRESS anywhere on a section and drag — it lifts (haptic), follows the finger, swaps
        // neighbours as it crosses their centres (the screen-level frame loop also auto-scrolls at the
        // viewport edges and keeps swapping while it does), and the order persists on drop. The stagger
        // index follows the section's live position.
        sectionOrder.forEach { section ->
            // Entrance stagger keyed on the section's FIXED default position, not its live position: the
            // stagger only matters on first appearance (staggeredAppear latches), and a live-position
            // stagger changes every moved section's content lambda on every mid-drag swap — recomposing
            // the heavy sections (Key Metrics grid, HR chart) while the finger is down (drag jank).
            val stagger = TodaySection.defaultOrder.indexOf(section) + 1
            // A gated-off section (Start session outside today / beta-off; Your Cards outside today or
            // empty) emits NO item at all: an always-present zero-height item would double the 12dp row
            // gap around its slot — visible on the DEFAULT layout, where Start session sits right under
            // the hero and the beta flag is off for most users. The section keeps its place in the saved
            // order; its item simply reappears when eligible.
            val visibleDashboardCards = enabledDashboardCards.filter {
                it != DashboardCard.HYDRATION || hydrationEnabled
            }
            val sectionVisible = when (section) {
                TodaySection.LIVE_SESSION ->
                    selectedDayOffset == 0 && (liveSessionsEnabled || activeLiveSession != null)
                TodaySection.YOUR_CARDS ->
                    selectedDayOffset == 0 && visibleDashboardCards.isNotEmpty()
                TodaySection.JOURNAL ->
                    selectedDayOffset == 0 && journalReminderOn
                TodaySection.TARGET ->
                    selectedDayOffset == 0
                else -> true
            }
            if (!sectionVisible) return@forEach
            item(key = TODAY_SECTION_KEY_PREFIX + section.raw) {
                TodayReorderableSection(
                    section = section,
                    listState = todayListState,
                    drag = sectionDrag,
                    onDrop = { TodayLayoutPrefs.setOrder(context, sectionOrder) },
                ) {
                    when (section) {
                        // HERO, three equal Charge / Effort / Rest liquid vessels in the compact pinned-dark
                        // card used by LiquidTodayView. Effort prefers today's live in-progress strain and
                        // falls back to the stored value (#402); the floating badge names the real score
                        // sources. The honest "why is Effort 0?" caption (#482/#480) travels WITH the hero
                        // (folded into this section) so wherever the vessels sit, their explanation follows.
                        TodaySection.HERO -> Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            val heroRecovery = displayMetric?.recovery ?: lastScoredCharge?.value
                            val heroTone = heroRecovery?.let(Palette::recoveryGaugeColors)?.first
                                ?: Palette.chargeColor
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidTodayHeroSurface(heroTone)
                                    .staggeredAppear(stagger),
                            ) {
                                Column {
                                    DailySignalHeader(
                                        status = dailySignalStatus,
                                        sourceLabel = heroSourceLabel,
                                        viewModel = viewModel,
                                        onOpen = onOpenHealth,
                                    )
                                    ScoreHeroRow(
                                        day = displayMetric,
                                        restScore = restScoreForDay,
                                        recoveryCalibration = recoveryCalibration,
                                        lastScoredCharge = lastScoredCharge,
                                        effortScale = effortScale,
                                        liveTodayStrain = if (selectedDayOffset == 0) liveTodayStrain else null,
                                        fitnessAge = fitnessAgeToday,
                                        profileAge = profileStore.age.takeIf { profileStore.ageInputConfirmed },
                                        fitnessCalibration = if (!profileStore.fitnessInputsConfirmed) {
                                            "Complete age and sex in your profile"
                                        } else {
                                            val recent = days.takeLast(7)
                                            val rhrDays = recent.count { it.restingHr != null }
                                            val activityDays = recent.count { it.strain != null }
                                            "RHR ${rhrDays.coerceAtMost(4)} of 4 nights · activity ${activityDays.coerceAtMost(4)} of 4 days"
                                        },
                                        showFitnessAge = selectedDayOffset == 0,
                                        onScoreInfo = openGuide,
                                        onChargeTap = { showChargeBreakdown = true },
                                        onFitnessAgeTap = { onOpenMetric("fitness_age") },
                                    )
                                }
                            }
                            // Honest "why is Effort 0?" caption - only when today's Effort is a real
                            // near-zero (HR present but never crossed the cardio zone). Effort accrues over
                            // a day and must never visibly drop: floor the in-progress value at the day's
                            // already-earned strain (#489/#506).
                            val todayEffort = if (selectedDayOffset == 0) effortForDay else null
                            if (todayEffort != null && todayEffort < 1.0) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 2.dp),
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.Top,
                                ) {
                                    Icon(
                                        Icons.Filled.Info,
                                        contentDescription = null,
                                        tint = Palette.effortColor,
                                        modifier = Modifier.size(Metrics.iconSmall),
                                    )
                                    Text(
                                        uiString(R.string.l10n_today_screen_no_cardio_load_yet_effort_builds_e952006c) +
                                            "zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.",
                                        style = NoopType.footnote,
                                        color = Palette.textTertiary,
                                    )
                                }
                            }
                        }
                        // LIVE SESSIONS (beta): the compact "Start session · BETA" entry. Today only
                        // (offset 0 — a session is a now-thing), gated on the Settings beta flag; a RUNNING
                        // session keeps the card visible regardless (it is the designed way back into the
                        // dismissed session dialog, see LiveSessionRunner's lifetime note). The gate lives
                        // at the loop level (sectionVisible) so a gated-off section emits no item.
                        TodaySection.LIVE_SESSION -> LiveSessionEntryCard(
                            onOpen = {
                                // Opening a new coach shows its pre-session guide first. An existing
                                // runner still resumes directly, including an unseen end summary.
                                showLiveSession = true
                            },
                        )
                        TodaySection.WHY -> DailyPlanWhySection(
                            readiness = dailyActionReadiness,
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                        )
                        TodaySection.TARGET -> DailyPlanTargetSection(
                            plan = dailyActionPlan,
                            checkIn = dailyActionCheckIn,
                            onCheckIn = updateDailyActionCheckIn,
                            currentEffort = displayMetric?.strain,
                            notificationEnabled = strainTargetEnabled,
                            notificationPermissionDenied = strainTargetPermissionDenied,
                            showNotificationControl = selectedDayOffset == 0,
                            onNotificationEnabledChange = { enabled ->
                                if (!enabled) {
                                    applyStrainTargetPreference(false)
                                } else if (reportNotificationsAvailable(context)) {
                                    strainTargetEnabled = true
                                    strainTargetPermissionDenied = false
                                    NoopPrefs.setStrainTargetEnabled(context, true)
                                    StrainTargetNotifier.onStrainTarget(
                                        context,
                                        selectedDayKey,
                                        displayMetric?.strain,
                                        dailyActionPlan.target,
                                    )
                                } else if (
                                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                    ContextCompat.checkSelfPermission(
                                        context,
                                        Manifest.permission.POST_NOTIFICATIONS,
                                    ) != PackageManager.PERMISSION_GRANTED
                                ) {
                                    strainTargetPermissionLauncher.launch(
                                        Manifest.permission.POST_NOTIFICATIONS,
                                    )
                                } else {
                                    applyStrainTargetPreference(
                                        false,
                                        permissionDenied = true,
                                    )
                                }
                            },
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                        )
                        TodaySection.WATCH -> DailyPlanWatchSection(
                            readiness = dailyActionReadiness,
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                        )
                        // The plain-English read-out, the Charge-tinted Synthesis card. Mirrors the iOS
                        // Synthesis InsightCard; carries the last scored day's read at the rollover (#543).
                        TodaySection.SYNTHESIS -> Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                            SynthesisHeroCard(
                                day = displayMetric,
                                recoveryCalibration = recoveryCalibration,
                                carriedDay = lastScoredRecoveryDay,
                                days = days,
                                displayName = displayName,
                                synthesisExpanded = synthesisExpanded,
                                onToggleSynthesis = { synthesisExpanded = !synthesisExpanded },
                                onOpenReadiness = { showChargeBreakdown = true },
                            )
                        }
                        // METRICS: header + Edit affordance (#251) + the tile grid. Previously two
                        // LazyColumn items; merged into ONE (a section must be a single keyed item for the
                        // drag), spaced by the scaffold's 12dp row gap so the rhythm is pixel-identical.
                        TodaySection.KEY_METRICS -> Column(
                            modifier = Modifier.fillMaxWidth(),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Row(verticalAlignment = Alignment.Top) {
                                Box(modifier = Modifier.weight(1f)) {
                                    SectionHeader("Key Metrics", overline = dayLabel, trailing = trendWindowLabel(keyMetricsWindowDays))
                                }
                                TodayEditAction(
                                    onClick = { showMetricsEditor = true },
                                    contentDescription = uiString(R.string.l10n_today_screen_edit_key_metrics_f95e61a4),
                                    contentAlignment = Alignment.TopCenter,
                                )
                            }
                            Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                                MetricGrid(
                                    d = displayMetric,
                                    w = window,
                                    recoveryCalibration = recoveryCalibration,
                                    lastScoredCharge = lastScoredCharge,
                                    carriedDay = lastScoredRecoveryDay,
                                    spo2CarryDay = displaySpo2Day,
                                    massUnit = massUnit,
                                    effortScale = effortScale,
                                    effortForDay = effortForDay,
                                    latestWeightKg = weightKg,
                                    profileWeightKg = profileWeightKg,
                                    importedStepsForDay = importedStepsForDay,
                                    estimatedStepsForDay = stepsEstForDay,
                                    caloriesForDay = caloriesByDay[selectedDayKey],   // #616: imported-first per day
                                    caloriesSpark = caloriesSpark,                    // #616: imported-first trend
                                    stepActivityClassForDay = stepActivityClassForDay,
                                    stepsEstimateCaption = stepsEstimateCaption(profileStore),
                                    restScore = restScoreForDay,
                                    restSpark = restCompositeSpark,
                                    enabledMetrics = enabledKeyMetrics,
                                    isToday = selectedDayOffset == 0,
                                    onScoreInfo = openGuide,
                                    detailed = keyMetricsDetailed,
                                    onOpenMetric = onOpenMetric,
                                )
                            }
                        }
                        // #991: TodayWorkoutsSection emits header + card as two siblings; spaced Column.
                        TodaySection.WORKOUTS -> Column(
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            TodayWorkoutsSection(footer.recentWorkouts)
                        }
                        // HEART RATE, the live HR thread / trend card. #991: header + card in a Column.
                        TodaySection.HEART_RATE -> Column(
                            modifier = Modifier.fillMaxWidth().staggeredAppear(stagger),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            HeartRateTrendCard(
                                viewModel = viewModel,
                                days = days,
                                selectedDay = selectedDay,
                                today = todayDate,
                                activeDeviceId = activeStrapId,
                                displayMetric = displayMetric,
                                effortScale = effortScale,
                                effortForDay = effortForDay,
                            )
                        }
                        // The three hero vitals, HRV / Resting HR / Respiratory. Carried day (#543).
                        TodaySection.RECOVERY_VITALS -> Box(modifier = Modifier.fillMaxWidth().staggeredAppear(stagger)) {
                            HeroMetricRows(day = displayMetric, carriedDay = lastScoredRecoveryDay, vitalsDay = lastVitalsDay)
                        }
                        // YOUR CARDS, the user-customisable dashboard (WHOOP "My Dashboard"). Hydration is
                        // hidden when its tracking is OFF (the editor still offers it, so the choice
                        // persists). Per-field carried-day fallbacks (#543) stop rollover "No Data" blanks.
                        // The today/non-empty gate lives at the loop level (sectionVisible) so a gated-off
                        // section emits no item; visibleDashboardCards is the loop-level filtered list.
                        TodaySection.YOUR_CARDS -> YourCardsSection(
                            cards = visibleDashboardCards,
                            day = displayMetric,
                            carriedDay = lastScoredRecoveryDay,
                            vitalsDay = lastVitalsDay,
                            spo2Day = displaySpo2Day,
                            skinTempDay = lastSkinTempDay,
                            stress = stressToday,
                            fitnessAge = fitnessAgeToday,
                            vitality = vitalityToday,
                            importedStepsForDay = importedStepsForDay,
                            estimatedStepsForDay = stepsEstForDay,
                            caloriesForDay = caloriesByDay[selectedDayKey],
                            hydrationTotalMl = hydrationTotalMl,
                            hydrationGoalMl = hydrationGoalMl,
                            onOpenHydration = onOpenHydration,
                            onOpenStress = onOpenStress,
                            onOpenMetric = onOpenMetric,
                            onOpenSleep = onOpenSleep,
                            onOpenCoupled = onOpenCoupled,
                            onCustomise = { showDashboardEditor = true },
                        )
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — hold-drag or Arrange moves it. Today-only
                        // and enabled-gated at the loop level (sectionVisible) so it never leaves a blank
                        // draggable slot. Twin of iOS LiquidTodayView's `.journal` arm.
                        TodaySection.JOURNAL -> JournalReminderCard(
                            viewModel = viewModel,
                            days = days,
                            onOpenJournal = onOpenJournal,
                        )
                    }
                }
            }
        }
        // Auto-detect workouts (MVP, fresh installs default to approval-first Ask), a NON-DESTRUCTIVE
        // "looks like a workout?" card for sustained-elevated-HR bouts. Renders nothing in Off mode or
        // when there is no suggestion. Save → a manual "Workout" row; × → dismissed forever.
        if (selectedDayOffset == 0) {
            item { AutoWorkoutNudgeCard(viewModel = viewModel, days = days) }
        }
        // Strap battery only while the link is up AND a real reading exists, a stale % from a
        // dropped connection must not present as live (#159).
        item {
            TodaySourcesSectionLive(
                viewModel = viewModel,
                footer = footer,
                strapBatteryPct = if (liveSnap.connected) liveSnap.batteryPct?.roundToInt() else null,
                strapBatteryEstimate = if (liveSnap.connected) batteryEstimateText else null,
                expanded = sourcesExpanded,
                onToggle = { sourcesExpanded = !sourcesExpanded },
            )
        }
    }
        // Material3's pull indicator draws its circle even at rest (progress 0, not
        // refreshing), so an idle Today showed a permanent grey dot at the top (#582). Compose it only
        // while a pull is in progress or its short handoff is running. The gesture is owned by the Box's
        // modifier above, so gating this visual cannot disable pull-to-sync.
        if (pullToSyncState.distanceFraction > 0f || pullToSyncRefreshing) {
            PullToRefreshDefaults.Indicator(
                state = pullToSyncState,
                isRefreshing = pullToSyncRefreshing,
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }
    }

    if (showWeatherDetails) {
        TodayWeatherDetailsDialog(
            state = weatherState,
            temperatureUnit = temperatureUnit,
            onDismiss = { showWeatherDetails = false },
            onEnable = {
                weatherStore.enableAndRefresh {
                    weatherPermissionLauncher.launch(
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    )
                }
            },
            onRefresh = weatherStore::refresh,
            onOpenSettings = {
                runCatching {
                    context.startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${context.packageName}"),
                        ),
                    )
                }
            },
            onOpenAttribution = {
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(TodayWeatherStore.ATTRIBUTION_URL)),
                    )
                }
            },
        )
    }

    // Scoring guide sheet, full-screen Dialog, mirroring Settings' What's-new presentation. Opened
    // by the per-score ⓘ (deep-linked via guideSection) and the first-run card (guideSection = null).
    if (showGuide) {
        Dialog(
            onDismissRequest = { showGuide = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
                ScoringGuideScreen(
                    onClose = { showGuide = false },
                    initialSection = guideSection,
                )
            }
        }
    }

    // A1/S4: the Charge breakdown sheet, opened by tapping the hero Charge ring. A full-screen Dialog
    // (mirroring the scoring guide's presentation) hosting the existing What-shaped-it breakdown, the
    // Contributors bars and the Readiness card, built only when shown (#819 lazy). A calibrating night
    // (empty drivers) falls through to the existing countdown inside RecoveryDriversSection's own gate.
    if (showChargeBreakdown) {
        Dialog(
            onDismissRequest = { showChargeBreakdown = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ChargeBreakdownSheet(
                days = days,
                displayDay = displayMetric,
                carriedDay = lastScoredRecoveryDay,
                recoverySource = if (lastScoredRecoveryDay != null) {
                    carriedRecoverySource
                } else {
                    provenanceByMetric["recovery"]
                },
                showReadiness = selectedDayOffset == 0,
                onClose = { showChargeBreakdown = false },
                // "How Charge is calculated" → close the breakdown and open the scoring guide at the Charge
                // section, the same target the per-ring ⓘ buttons use. Mirrors the iOS NavigationLink to
                // ScoringGuideView(initialSection: .charge) whose onClose dismisses the breakdown.
                onHowCalculated = {
                    showChargeBreakdown = false
                    openGuide(ScoreSection.CHARGE)
                },
            )
        }
    }

    // LIVE SESSIONS (beta): the full-screen session dialog — the same presentation the live-workout
    // overlay uses on Live (Dialog, usePlatformDefaultWidth = false). Dismissing it only HIDES the
    // screen: the runner (held in LiveSessionRunner.active, ticking on the app-wide viewModelScope)
    // keeps guarding, and the entry card above re-opens the same session. Only "End session" + the
    // summary's "Done" (inside the screen) actually finish and clear it.
    if (showLiveSession) {
        Dialog(
            onDismissRequest = { showLiveSession = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            LiveSessionScreen(vm = viewModel, onClose = { showLiveSession = false })
        }
    }

    // Key-Metrics layout editor (#251), a Today-local dialog (no new nav destination). Saves the layout
    // and re-reads it into local state so the grid updates immediately and survives relaunch.
    if (showMetricsEditor) {
        KeyMetricsEditorDialog(
            initial = enabledKeyMetrics,
            initialDetailed = keyMetricsDetailed,
            initialWindowDays = keyMetricsWindowDays,
            onDismiss = { showMetricsEditor = false },
            onSave = { metrics, detailed, windowDays ->
                KeyMetricPrefs.setEnabled(context, metrics)
                KeyMetricPrefs.setDetailed(context, detailed)
                KeyMetricPrefs.setDetailWindowDays(context, windowDays)
                enabledKeyMetrics = metrics
                keyMetricsDetailed = detailed
                keyMetricsWindowDays = windowDays
                showMetricsEditor = false
            },
        )
    }

    // "Your cards" dashboard editor (WHOOP "My Dashboard" ✎), a Today-local dialog (no new nav
    // destination): toggle which cards show + reorder them with up/down arrows. Saves the selection and
    // re-reads it into local state so the dashboard updates immediately and survives relaunch. Mirrors the
    // iOS DashboardCardsEditorSheet. (No reorder lib is added, simple arrow buttons, like KeyMetricsEditor.)
    if (showDashboardEditor) {
        DashboardCardsEditorDialog(
            initial = enabledDashboardCards,
            onDismiss = { showDashboardEditor = false },
            onSave = { cards ->
                DashboardCardPrefs.setEnabled(context, cards)
                enabledDashboardCards = cards
                showDashboardEditor = false
            },
        )
    }

    // #today-layout: the section-order editor (reorder the below-hero sections). Saves the order and
    // re-reads it into local state so Today re-lays-out immediately and survives relaunch.
    if (showLayoutEditor) {
        TodayLayoutEditorDialog(
            initial = sectionOrder,
            onDismiss = { showLayoutEditor = false },
            onSave = { order ->
                TodayLayoutPrefs.setOrder(context, order)
                sectionOrder = order
                showLayoutEditor = false
            },
        )
    }
}

// MARK: - Evidence-gated Daily Action

/// Joins ALREADY-localized fragments for an accessibility description. Exists so composed a11y strings
/// never appear as literals inside `semantics { }`, which the i18n audit treats as un-extracted copy.
/// Byte-equivalent to the Swift `descriptorScopeHint` helper.
private fun joinLocalizedFragments(vararg parts: String): String =
    parts.filter { it.isNotBlank() }.joinToString(" ")

@Composable
private fun DailyPlanSectionHeader(
    title: String,
    trailing: String,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space2)
            .padding(top = Metrics.space4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Text(
            title,
            modifier = Modifier.weight(1f),
            style = NoopType.overline,
            color = Palette.textSecondary,
        )
        Text(
            trailing,
            style = NoopType.caption,
            color = Palette.textSecondary,
            textAlign = TextAlign.End,
        )
    }
}

@Composable
private fun DailyPlanWhySection(
    readiness: ReadinessEngine.Readiness,
    modifier: Modifier = Modifier,
) {
    val signals = readiness.signals.filter { it.key in setOf("hrv", "rhr", "respRate") }
    val readinessHeadline = localizedReadinessHeadline(readiness)
    val readinessSummary = localizedReadinessSummary(readiness)
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        DailyPlanSectionHeader(
            title = stringResource(R.string.daily_plan_why_title),
            trailing = readinessHeadline,
        )
        NoopCard {
            if (signals.isEmpty()) {
                DailyPlanEmptyRow(
                    icon = Icons.Filled.MonitorHeart,
                    text = stringResource(R.string.daily_plan_why_unavailable),
                )
            } else {
                Column {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = Metrics.space10)
                            .semantics(mergeDescendants = true) {},
                        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                        verticalAlignment = Alignment.Top,
                    ) {
                        MetricGlyph(
                            icon = dailyPlanReadinessIcon(readiness.level),
                            size = 28.dp,
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                        ) {
                            Text(
                                readinessHeadline,
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                readinessSummary,
                                style = NoopType.subhead,
                                color = Palette.textSecondary,
                            )
                            readiness.limitations.firstOrNull()?.let { limitation ->
                                Text(
                                    localizedReadinessLimitation(limitation, readiness),
                                    style = NoopType.caption,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                    }
                    signals.forEachIndexed { index, signal ->
                        HorizontalDivider(color = Palette.hairline)
                        DailyPlanSignalRow(signal)
                    }
                }
            }
        }
    }
}

@Composable
private fun DailyPlanTargetSection(
    plan: DailyActionPlanner.Plan,
    checkIn: DailyActionPlanner.CheckIn,
    onCheckIn: (DailyActionPlanner.CheckIn) -> Unit,
    currentEffort: Double?,
    notificationEnabled: Boolean,
    notificationPermissionDenied: Boolean,
    showNotificationControl: Boolean,
    onNotificationEnabledChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    var detailsExpanded by rememberSaveable(plan.day) { mutableStateOf(false) }
    val detailsHint = stringResource(R.string.daily_plan_details_hint)
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        DailyPlanSectionHeader(
            title = stringResource(R.string.daily_plan_target_title),
            trailing = stringResource(dailyPlanTargetStatusResource(plan)),
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space14)) {
                Text(
                    stringResource(R.string.daily_plan_check_in_question),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    DailyPlanCheckInOption(
                        label = stringResource(R.string.daily_plan_check_in_as_usual),
                        selected = checkIn == DailyActionPlanner.CheckIn.AS_USUAL,
                        onClick = { onCheckIn(DailyActionPlanner.CheckIn.AS_USUAL) },
                    )
                    DailyPlanCheckInOption(
                        label = stringResource(R.string.daily_plan_check_in_below_usual),
                        selected = checkIn == DailyActionPlanner.CheckIn.BELOW_USUAL,
                        onClick = { onCheckIn(DailyActionPlanner.CheckIn.BELOW_USUAL) },
                    )
                    DailyPlanCheckInOption(
                        label = stringResource(R.string.daily_plan_check_in_pain_unwell),
                        selected = checkIn == DailyActionPlanner.CheckIn.PAIN_OR_UNWELL,
                        onClick = { onCheckIn(DailyActionPlanner.CheckIn.PAIN_OR_UNWELL) },
                    )
                }

                HorizontalDivider(color = Palette.hairline)
                when (plan.availability) {
                    DailyActionPlanner.Availability.CHECK_IN_NEEDED -> DailyPlanStateRow(
                        icon = Icons.Filled.Check,
                        title = stringResource(R.string.daily_plan_state_check_in_title),
                        body = stringResource(R.string.daily_plan_state_check_in_body),
                        tint = Palette.textTertiary,
                    )
                    DailyActionPlanner.Availability.CALIBRATING -> DailyPlanStateRow(
                        icon = Icons.Filled.Autorenew,
                        title = stringResource(R.string.daily_plan_state_calibrating_title),
                        body = stringResource(R.string.daily_plan_state_calibrating_body),
                        action = dailyPlanActionLabel(plan.action),
                        tint = Palette.statusWarning,
                    )
                    DailyActionPlanner.Availability.RECOVERY_SHIFT -> DailyPlanStateRow(
                        icon = Icons.AutoMirrored.Filled.DirectionsWalk,
                        title = stringResource(R.string.daily_plan_state_recovery_shift_title),
                        body = stringResource(R.string.daily_plan_state_recovery_shift_body),
                        action = dailyPlanActionLabel(plan.action),
                        tint = Palette.statusWarning,
                    )
                    DailyActionPlanner.Availability.STOP -> DailyPlanStateRow(
                        icon = Icons.Filled.Warning,
                        title = stringResource(R.string.daily_plan_state_stop_title),
                        body = stringResource(R.string.daily_plan_state_stop_body),
                        action = dailyPlanActionLabel(plan.action),
                        tint = Palette.statusCritical,
                    )
                    DailyActionPlanner.Availability.READY -> {
                        val target = plan.target
                        if (target == null) {
                            DailyPlanStateRow(
                                icon = Icons.Filled.Autorenew,
                                title = stringResource(R.string.daily_plan_state_calibrating_title),
                                body = stringResource(R.string.daily_plan_state_calibrating_body),
                                tint = Palette.statusWarning,
                            )
                        } else {
                            val guidance = DailyEffortGuidance.evaluate(currentEffort, target)
                            Column(
                                verticalArrangement = Arrangement.spacedBy(Metrics.space10),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.Bottom,
                                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                                ) {
                                    Text(
                                        stringResource(
                                            R.string.appwide_range_format,
                                            target.lower,
                                            target.upper,
                                        ),
                                        style = NoopType.number(30f),
                                        color = Palette.textPrimary,
                                    )
                                    Text(
                                        stringResource(R.string.daily_plan_effort_scale),
                                        style = NoopType.overline,
                                        color = Palette.textTertiary,
                                    )
                                }
                                Text(
                                    stringResource(R.string.daily_plan_state_ready_body),
                                    style = NoopType.subhead,
                                    color = Palette.textSecondary,
                                )
                                if (guidance.state != DailyEffortGuidance.State.UNAVAILABLE) {
                                    DailyPlanEffortProgress(guidance)
                                }
                                DailyPlanActionRow(
                                    text = dailyPlanActionLabel(plan.action),
                                    tint = Palette.accent,
                                )
                                if (showNotificationControl) {
                                    HorizontalDivider(color = Palette.hairline)
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clickable {
                                                onNotificationEnabledChange(!notificationEnabled)
                                            }
                                            .padding(vertical = Metrics.space4),
                                        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                                        verticalAlignment = Alignment.CenterVertically,
                                    ) {
                                        Column(
                                            modifier = Modifier.weight(1f),
                                            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                                        ) {
                                            Text(
                                                stringResource(R.string.daily_plan_notification_toggle),
                                                style = NoopType.subhead,
                                                color = Palette.textPrimary,
                                            )
                                            Text(
                                                stringResource(R.string.daily_plan_notification_help),
                                                style = NoopType.footnote,
                                                color = Palette.textTertiary,
                                            )
                                        }
                                        NoopToggleSwitch(
                                            checked = notificationEnabled,
                                            onCheckedChange = null,
                                        )
                                    }
                                    if (notificationPermissionDenied) {
                                        Text(
                                            stringResource(R.string.appwide_notifications_system_disabled),
                                            style = NoopType.footnote,
                                            color = Palette.statusCritical,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                plan.workoutAdjustment?.let { adjustment ->
                    HorizontalDivider(color = Palette.hairline)
                    DailyPlanWorkoutAdjustment(adjustment)
                }

                TextButton(
                    onClick = { detailsExpanded = !detailsExpanded },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .semantics {
                            contentDescription = detailsHint
                        },
                ) {
                    Text(
                        stringResource(
                            if (detailsExpanded) R.string.daily_plan_details_hide
                            else R.string.daily_plan_details_show
                        ),
                        style = NoopType.caption,
                    )
                    Spacer(Modifier.weight(1f))
                    Icon(
                        if (detailsExpanded) Icons.Filled.KeyboardArrowUp
                        else Icons.Filled.KeyboardArrowDown,
                        contentDescription = null,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }

                if (detailsExpanded) {
                    DailyPlanEvidence(plan)
                }
            }
        }
    }
}

@Composable
private fun DailyPlanWorkoutAdjustment(
    adjustment: DailyActionPlanner.WorkoutAdjustment,
) {
    val startTime = remember(adjustment.startSec) {
        DateTimeFormatter
            .ofLocalizedTime(FormatStyle.SHORT)
            .withLocale(Locale.getDefault())
            .format(
                Instant.ofEpochSecond(adjustment.startSec)
                    .atZone(ZoneId.systemDefault()),
            )
    }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.CalendarMonth,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(Metrics.iconSmall),
            )
            Text(
                stringResource(R.string.daily_plan_workout_adjustment_title),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            adjustment.measuredSleepMinutes?.let { minutes ->
                DailyPlanWorkoutMetric(
                    icon = Icons.Filled.Bedtime,
                    label = stringResource(R.string.daily_plan_workout_adjustment_sleep_label),
                    value = dailyPlanDuration(minutes),
                    modifier = Modifier.weight(1f),
                )
            }
            DailyPlanWorkoutMetric(
                icon = Icons.Filled.AccessTime,
                label = stringResource(R.string.daily_plan_workout_adjustment_workout_label),
                value = startTime,
                modifier = Modifier.weight(1f),
            )
        }
        dailyPlanSleepDeficit(adjustment)?.let { deficit ->
            Text(
                deficit,
                style = NoopType.subhead.copy(fontWeight = FontWeight.SemiBold),
                color = Palette.textPrimary,
            )
        }
        Text(
            stringResource(dailyPlanWorkoutAdjustmentBodyResource(adjustment.reason)),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
    }
}

@Composable
private fun dailyPlanSleepDeficit(
    adjustment: DailyActionPlanner.WorkoutAdjustment,
): String? {
    val deficit = adjustment.sleepDeficitMinutes?.takeIf { it > 0 } ?: return null
    val reference = adjustment.sleepReference ?: return null
    val hours = deficit / 60
    val minutes = deficit % 60
    val resource = when {
        reference == DailyActionPlanner.SleepReference.PERSONAL_USUAL && hours > 0 ->
            R.string.daily_plan_workout_adjustment_deficit_usual_hours_minutes
        reference == DailyActionPlanner.SleepReference.PERSONAL_USUAL ->
            R.string.daily_plan_workout_adjustment_deficit_usual_minutes
        hours > 0 ->
            R.string.daily_plan_workout_adjustment_deficit_target_hours_minutes
        else ->
            R.string.daily_plan_workout_adjustment_deficit_target_minutes
    }
    return if (hours > 0) {
        stringResource(resource, hours, minutes)
    } else {
        stringResource(resource, minutes)
    }
}

@Composable
private fun DailyPlanWorkoutMetric(
    icon: ImageVector,
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space2)) {
            Text(label, style = NoopType.overline, color = Palette.textTertiary)
            Text(value, style = NoopType.subhead, color = Palette.textPrimary)
        }
    }
}

@Composable
private fun dailyPlanDuration(minutes: Int): String {
    val bounded = minutes.coerceAtLeast(0)
    val hours = bounded / 60
    val remainder = bounded % 60
    return if (hours > 0) {
        stringResource(
            R.string.appwide_day_overview_duration_hours_minutes_format,
            hours,
            remainder,
        )
    } else {
        stringResource(R.string.appwide_day_overview_duration_minutes_format, remainder)
    }
}

@StringRes
private fun dailyPlanWorkoutAdjustmentBodyResource(
    reason: DailyActionPlanner.WorkoutAdjustmentReason,
): Int = when (reason) {
    DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_DEFICIT ->
        R.string.daily_plan_workout_adjustment_sleep_deficit
    DailyActionPlanner.WorkoutAdjustmentReason.RECOVERY_SHIFT ->
        R.string.daily_plan_workout_adjustment_recovery_shift
    DailyActionPlanner.WorkoutAdjustmentReason.SLEEP_AND_RECOVERY ->
        R.string.daily_plan_workout_adjustment_sleep_and_recovery
}

@Composable
private fun DailyPlanEffortProgress(guidance: DailyEffortGuidance.Result) {
    val current = guidance.current?.roundToInt() ?: return
    val range = guidance.range ?: return
    val tint = when (guidance.state) {
        DailyEffortGuidance.State.IN_RANGE -> Palette.statusPositive
        DailyEffortGuidance.State.ABOVE_RANGE -> Palette.statusWarning
        DailyEffortGuidance.State.BELOW_RANGE -> Palette.accent
        DailyEffortGuidance.State.UNAVAILABLE -> Palette.textTertiary
    }
    val status = when (guidance.state) {
        DailyEffortGuidance.State.BELOW_RANGE -> stringResource(
            R.string.daily_plan_progress_below,
            kotlin.math.ceil(guidance.remainingToLower ?: 0.0).toInt(),
        )
        DailyEffortGuidance.State.IN_RANGE ->
            stringResource(R.string.daily_plan_progress_in_range)
        DailyEffortGuidance.State.ABOVE_RANGE ->
            stringResource(R.string.daily_plan_progress_above)
        DailyEffortGuidance.State.UNAVAILABLE -> ""
    }
    val accessibility = stringResource(
        R.string.daily_plan_progress_accessibility,
        current,
        range.lower,
        range.upper,
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) {
                // Both fragments are ALREADY localized, so this is not translatable copy. Joined via a
                // helper rather than a string template so no literal sits in a semantics block: the i18n
                // audit rightly treats literals there as un-extracted UI copy. Mirrors the Swift twin's
                // descriptorScopeHint.
                contentDescription = joinLocalizedFragments(accessibility, status)
            },
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(
                stringResource(R.string.daily_plan_progress_current),
                modifier = Modifier.weight(1f),
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
            Text(
                current.toString(),
                style = NoopType.number(18f),
                color = tint,
            )
        }
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .height(12.dp)
                .clip(CircleShape)
                .background(Palette.textTertiary.copy(alpha = 0.18f)),
        ) {
            val lowerX = maxWidth * (range.lower / 100f)
            val rangeWidth = maxWidth * ((range.upper - range.lower) / 100f)
            val markerSize = 12.dp
            val markerX = (maxWidth * guidance.progress.toFloat() - markerSize / 2)
                .coerceIn(0.dp, (maxWidth - markerSize).coerceAtLeast(0.dp))
            Box(
                Modifier
                    .offset(x = lowerX)
                    .width(rangeWidth.coerceAtLeast(4.dp))
                    .fillMaxHeight()
                    .background(Palette.accent.copy(alpha = 0.16f)),
            )
            Box(
                Modifier
                    .fillMaxWidth(guidance.progress.toFloat().coerceIn(0f, 1f))
                    .fillMaxHeight()
                    .background(tint.copy(alpha = 0.42f)),
            )
            Box(
                Modifier
                    .offset(x = markerX)
                    .size(markerSize)
                    .clip(CircleShape)
                    .background(tint)
                    .border(2.dp, Palette.surfaceBase, CircleShape),
            )
        }
        Text(status, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun DailyPlanWatchSection(
    readiness: ReadinessEngine.Readiness,
    modifier: Modifier = Modifier,
) {
    val evaluated = readiness.signals
    val watch = readiness.signals.filter {
        it.flag == ReadinessEngine.Flag.WATCH || it.flag == ReadinessEngine.Flag.BAD
    }
    val trailing = when {
        evaluated.isEmpty() -> stringResource(R.string.daily_plan_confidence_calibrating)
        watch.isEmpty() -> stringResource(R.string.daily_plan_watch_clear)
        else -> stringResource(R.string.daily_plan_watch_attention)
    }
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        DailyPlanSectionHeader(
            title = stringResource(R.string.daily_plan_watch_title),
            trailing = trailing,
        )
        NoopCard {
            when {
                evaluated.isEmpty() -> DailyPlanEmptyRow(
                    icon = Icons.Filled.MonitorHeart,
                    text = stringResource(R.string.daily_plan_watch_unavailable),
                )
                watch.isEmpty() -> DailyPlanEmptyRow(
                    icon = Icons.Filled.Check,
                    text = stringResource(R.string.daily_plan_watch_none),
                )
                else -> Column {
                    watch.forEachIndexed { index, signal ->
                        if (index > 0) HorizontalDivider(color = Palette.hairline)
                        DailyPlanSignalRow(signal)
                    }
                }
            }
        }
    }
}

@Composable
private fun DailyPlanCheckInOption(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(if (selected) Palette.accent.copy(alpha = 0.12f) else Color.Transparent)
            .border(
                1.dp,
                if (selected) Palette.accent.copy(alpha = 0.45f) else Palette.hairline,
                shape,
            )
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics(mergeDescendants = true) {
                this.selected = selected
                role = Role.RadioButton
            }
            .padding(horizontal = Metrics.space12, vertical = Metrics.space8),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(20.dp)
                .clip(CircleShape)
                .background(if (selected) Palette.accent else Color.Transparent)
                .border(1.dp, if (selected) Palette.accent else Palette.textTertiary, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) {
                Icon(
                    Icons.Filled.Check,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        Text(
            label,
            modifier = Modifier.weight(1f),
            style = NoopType.subhead,
            color = Palette.textPrimary,
        )
    }
}

@Composable
private fun DailyPlanStateRow(
    icon: ImageVector,
    title: String,
    body: String,
    tint: Color,
    action: String? = null,
) {
    Column(
        modifier = Modifier.semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(Metrics.space10),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(24.dp),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Metrics.space4),
            ) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(body, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
        if (action != null) {
            DailyPlanActionRow(text = action, tint = tint)
        }
    }
}

@Composable
private fun DailyPlanActionRow(text: String, tint: Color) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.Check,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(Metrics.iconSmall),
        )
        Text(text, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

@Composable
private fun DailyPlanEvidence(plan: DailyActionPlanner.Plan) {
    Column(
        modifier = Modifier.semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Text(
            stringResource(R.string.daily_plan_evidence_title),
            style = NoopType.overline,
            color = Palette.textTertiary,
        )
        plan.evidence.forEach { evidence ->
            DailyPlanActionRow(
                text = stringResource(dailyPlanEvidenceResource(evidence.source)),
                tint = Palette.textTertiary,
            )
        }
        Text(
            stringResource(R.string.daily_plan_limitation),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

@Composable
private fun DailyPlanEmptyRow(icon: ImageVector, text: String) {
    Row(
        modifier = Modifier.semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MetricGlyph(
            icon = icon,
            size = 26.dp,
        )
        Text(
            text,
            modifier = Modifier.weight(1f),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
    }
}

@Composable
private fun DailyPlanSignalRow(signal: ReadinessEngine.Signal) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = Metrics.space10)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        MetricGlyph(
            icon = dailyPlanSignalIcon(signal.key),
            size = 28.dp,
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                verticalAlignment = Alignment.Top,
            ) {
                Text(
                    dailyPlanSignalLabel(signal),
                    modifier = Modifier.weight(1f),
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                )
                Text(
                    dailyPlanSignalStatus(signal.flag),
                    style = NoopType.overline,
                    color = dailyPlanSignalTint(signal.flag),
                )
            }
            Text(signal.detail, style = NoopType.caption, color = Palette.textSecondary)
            signal.evidence?.let {
                Text(it, style = NoopType.captionNumber, color = Palette.textTertiary)
            }
        }
    }
}

private fun dailyPlanSignalIcon(key: String): ImageVector = when (key) {
    "hrv" -> Icons.Filled.MonitorHeart
    "rhr" -> Icons.Filled.Favorite
    "respRate" -> Icons.Filled.Air
    "effortVariety" -> Icons.Filled.Functions
    else -> Icons.Filled.TrackChanges
}

private fun dailyPlanReadinessIcon(level: ReadinessEngine.Level): ImageVector = when (level) {
    ReadinessEngine.Level.PRIMED -> Icons.Filled.CheckCircle
    ReadinessEngine.Level.BALANCED -> Icons.Filled.Check
    ReadinessEngine.Level.STRAINED -> Icons.Filled.Warning
    ReadinessEngine.Level.RUNDOWN -> Icons.Filled.Warning
    ReadinessEngine.Level.INSUFFICIENT -> Icons.Filled.MonitorHeart
}

private fun dailyPlanReadinessTint(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED,
    ReadinessEngine.Level.BALANCED,
    -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.statusCritical
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

@Composable
private fun dailyPlanSignalLabel(signal: ReadinessEngine.Signal): String {
    return when (signal.key) {
        "hrv" -> stringResource(R.string.daily_plan_signal_hrv)
        "rhr" -> stringResource(R.string.daily_plan_signal_rhr)
        "respRate" -> stringResource(R.string.daily_plan_signal_respiration)
        "effortVariety" -> stringResource(R.string.daily_plan_signal_variety)
        else -> signal.label
    }
}

@Composable
private fun dailyPlanSignalStatus(flag: ReadinessEngine.Flag): String = stringResource(
    when (flag) {
        ReadinessEngine.Flag.GOOD -> R.string.daily_plan_signal_good
        ReadinessEngine.Flag.NEUTRAL -> R.string.daily_plan_signal_neutral
        ReadinessEngine.Flag.WATCH -> R.string.daily_plan_signal_watch
        ReadinessEngine.Flag.BAD -> R.string.daily_plan_signal_shifted
    }
)

private fun dailyPlanSignalTint(flag: ReadinessEngine.Flag): Color = when (flag) {
    ReadinessEngine.Flag.GOOD -> Palette.statusPositive
    ReadinessEngine.Flag.NEUTRAL -> Palette.textTertiary
    ReadinessEngine.Flag.WATCH -> Palette.statusWarning
    ReadinessEngine.Flag.BAD -> Palette.statusCritical
}

private fun dailyPlanConfidenceResource(confidence: ScoreConfidence): Int = when (confidence) {
    ScoreConfidence.CALIBRATING -> R.string.daily_plan_confidence_calibrating
    ScoreConfidence.BUILDING -> R.string.daily_plan_confidence_building
    ScoreConfidence.SOLID -> R.string.daily_plan_confidence_solid
}

private fun dailyPlanTargetStatusResource(plan: DailyActionPlanner.Plan): Int =
    when (plan.availability) {
        DailyActionPlanner.Availability.READY,
        DailyActionPlanner.Availability.CALIBRATING -> dailyPlanConfidenceResource(plan.confidence)
        DailyActionPlanner.Availability.CHECK_IN_NEEDED,
        DailyActionPlanner.Availability.RECOVERY_SHIFT,
        DailyActionPlanner.Availability.STOP -> R.string.daily_plan_target_withheld
    }

@Composable
private fun dailyPlanActionLabel(action: DailyActionPlanner.Action): String = stringResource(
    when (action) {
        DailyActionPlanner.Action.COMPLETE_CHECK_IN -> R.string.daily_plan_action_complete_check_in
        DailyActionPlanner.Action.KEEP_SLEEP_WINDOW -> R.string.daily_plan_action_keep_sleep_window
        DailyActionPlanner.Action.PROTECT_EXTRA_SLEEP -> R.string.daily_plan_action_protect_extra_sleep
        DailyActionPlanner.Action.CHOOSE_EASY_DAY -> R.string.daily_plan_action_choose_easy_day
        DailyActionPlanner.Action.STOP_AND_ASSESS -> R.string.daily_plan_action_stop_and_assess
    }
)

private fun dailyPlanEvidenceResource(source: DailyActionPlanner.EvidenceSource): Int = when (source) {
    DailyActionPlanner.EvidenceSource.SELF_CHECK -> R.string.daily_plan_evidence_self_check
    DailyActionPlanner.EvidenceSource.READINESS_BASELINE -> R.string.daily_plan_evidence_readiness
    DailyActionPlanner.EvidenceSource.PERSONAL_EFFORT_HISTORY ->
        R.string.daily_plan_evidence_effort_history
    DailyActionPlanner.EvidenceSource.SLEEP_PLAN -> R.string.daily_plan_evidence_sleep_plan
}

/**
 * The accent quick-action "+" in the Today header's top-right. Moved off the bottom bar (now four clean
 * tabs) to balance the header and open the existing quick-action sheet. A small CONTAINED accent disc,  * the accented primary among an otherwise-neutral icon set, ~36dp, no float and no glow: a flat reset-blue
 * accent fill with a hairline rim, the "+" glyph in crisp white. Mirrors the iOS quick-action + (a glyph on
 * Circle().fill(StrandPalette.accent)).
 */
/**
 * Today "workout in progress" indicator (iOS parity: ActiveWorkoutIndicatorCard). A metricRose-tinted card
 * with a decorative live dot + "WORKOUT IN PROGRESS" overline, a live H:MM:SS clock, the sport label, and a
 * "Return to workout" button. The whole card is tappable; [onReturn] routes to Live and re-opens the
 * in-exercise overlay. The clock ticks in this card's OWN LaunchedEffect (reading [ActiveWorkout.startMs]),
 * so the per-second update recomposes only this card, never the Today body. Design tokens only, no glow.
 */
@Composable
private fun WorkoutInProgressCard(
    workout: AppViewModel.ActiveWorkout,
    onReturn: () -> Unit,
) {
    // Live clock: re-read wall-clock every second and recompute elapsed off the workout's start. Keyed on
    // startMs so a fresh session restarts the loop. Mirrors the iOS TimelineView(.periodic(by: 1)).
    var nowMs by remember { mutableStateOf(System.currentTimeMillis()) }
    LaunchedEffect(workout.startMs) {
        while (true) {
            nowMs = System.currentTimeMillis()
            kotlinx.coroutines.delay(1000)
        }
    }
    // A failed Room commit leaves the exact ended workout visible for Retry. Freeze its clock at End;
    // never make a retained save error look as though recording silently continued.
    val elapsedS = (((workout.endMs ?: nowMs) - workout.startMs) / 1000).coerceAtLeast(0)
    val elapsed = elapsedClock(elapsedS)
    val sportLabel = workout.sport.name

    // liquidPress on the whole tappable "return to workout" card (same interactionSource on clickable + press).
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        tint = Palette.metricRose,
        // Combine into ONE actionable element so TalkBack reads "Workout in progress, $sport, $elapsed,
        // Return to workout" as a single Button, not five stops; the decorative dot is omitted by clearing
        // child semantics. The whole card is the tap target.
        modifier = Modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onReturn)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_today_screen_workout_in_progress_sportlabel_elapsed_return_95ce4bda, sportLabel, elapsed)
            },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                // Decorative "live" dot, hidden from TalkBack (the merged card reads the full state).
                Box(
                    modifier = Modifier
                        .size(Metrics.space8)
                        .clip(CircleShape)
                        .background(Palette.metricRose)
                        .clearAndSetSemantics {},
                )
                Spacer(Modifier.width(Metrics.space8))
                Text(
                    uiString(R.string.l10n_today_screen_workout_in_progress_af2322c9),
                    style = NoopType.overline,
                    color = Palette.metricRose,
                )
                Spacer(Modifier.weight(1f))
                Text(elapsed, style = NoopType.number(15f), color = Palette.textPrimary)
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    sportLabel,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    // Take the free space (and ellipsize a long sport name) so the button stays its intrinsic
                    // width on the trailing edge, mirroring the iOS ViewThatFits label + trailing button.
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Metrics.space8))
                Button(
                    onClick = onReturn,
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Palette.accent, contentColor = Palette.surfaceBase,
                    ),
                ) {
                    Text(uiString(R.string.l10n_today_screen_return_to_workout_30dc5509), style = NoopType.captionNumber)
                    Spacer(Modifier.width(Metrics.space6))
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
        }
    }
}

/**
 * The compact Silent Guardian entry under the hero. Three honest states off the
 * process-wide [LiveSessionRunner.active]: no session → start affordance; session running → the way back
 * into the dismissed session dialog (with a live elapsed clock); session ended but its summary not yet
 * Done-dismissed → "See the summary". The runner's 1 Hz snapshot is collected INSIDE this card only, so
 * the per-second tick recomposes this card, never the Today body (the WorkoutInProgressCard idiom).
 * The whole card is one tap target; [onOpen] presents the guide or returns to the active session.
 */
@Composable
private fun LiveSessionEntryCard(onOpen: () -> Unit) {
    val active by LiveSessionRunner.active.collectAsStateWithLifecycle()
    val runner = active
    var running = false
    var summaryWaiting = false
    var elapsed = ""
    if (runner != null) {
        val snap by runner.snapshot.collectAsStateWithLifecycle()
        running = !snap.ended
        summaryWaiting = snap.ended
        elapsed = elapsedClock(snap.elapsedSec.toLong())
    }
    val teal = Palette.metricCyan
    val startTitle = stringResource(R.string.appwide_live_session_start)
    val startDetail = stringResource(R.string.appwide_live_session_start_detail)
    val title = when {
        running -> "Silent Guardian running"
        summaryWaiting -> "Silent Guardian ended"
        else -> startTitle
    }
    val detail = when {
        running -> "Guarding - silence means you're on track."
        summaryWaiting -> "See the summary of your last session."
        else -> startDetail
    }

    // liquidPress on the whole tappable card (same interactionSource on clickable + press), matching the
    // workout-in-progress card above. Merged semantics so TalkBack reads one Button, not four stops.
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .liquidTodayCompactSurface()
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onOpen)
            .semantics(mergeDescendants = true) {
                contentDescription = uiString(R.string.l10n_today_screen_title_beta_detail_6b39ae21, title, detail)
            }
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        Icon(
            Icons.Filled.Shield,
            contentDescription = null,
            tint = teal,
            modifier = Modifier.size(16.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Text(
                    title,
                    style = NoopType.subhead,
                    color = Palette.onDarkPrimary,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Text(
                    stringResource(R.string.today_beta_badge),
                    style = NoopType.overline.copy(fontSize = 8.5.sp),
                    color = Palette.onDarkSecondary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(Color.White.copy(alpha = 0.05f))
                        .border(1.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(50))
                        .padding(horizontal = 8.dp, vertical = 2.5.dp),
                )
            }
            Text(
                detail,
                style = NoopType.footnote,
                color = Palette.onDarkSecondary,
            )
        }
        if (running) {
            Text(elapsed, style = NoopType.number(15f), color = Palette.onDarkPrimary)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.onDarkTertiary,
            modifier = Modifier.size(12.dp),
        )
    }
}

/**
 * A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
 * [DataPendingNote]). Matches the "New here?" card's × styling. Dismisses the card into the inbox.
 */
@Composable
private fun TodayCardDismissButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    IconButton(
        onClick = onClick,
        modifier = modifier
            .size(Metrics.iconButton)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_dismiss_to_updates_2c7915b8) },
    ) {
        Icon(
            Icons.Filled.Close,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(14.dp),
        )
    }
}

// MARK: - Scoring-guide affordances (ⓘ + first-run card)

/**
 * The small ⓘ that opens the scoring guide. Used on the Charge ring and the Effort / Rest tiles.
 * [section] only tunes the accessibility label; the deep-link target is carried by [onClick]'s
 * call site. Icon-only, so it always carries a content description. [compact] shrinks the hit-target
 * for the tile headers (where a full 36dp button would crowd the fixed-height tile).
 */
@Composable
private fun ScoreInfoButton(
    section: ScoreSection?,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val label = section?.let { "How ${it.label} is calculated" } ?: "How this score is calculated"
    val button = if (compact) 24.dp else Metrics.iconButton
    val glyph = if (compact) 16.dp else Metrics.iconSmall
    IconButton(onClick = onClick, modifier = modifier.size(button)) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = label,
            tint = Palette.textTertiary,
            modifier = Modifier.size(glyph),
        )
    }
}

/**
 * One-time "New here?" card pointing first-run users at the scoring guide. A NoopCard in the Today
 * flow, never a dialog, with a primary "See how it works" action and a ✕ dismiss; both set the
 * seen-flag at the call site so the card never returns. Copy verbatim from the approved source.
 */
@Composable
private fun ScoringGuideIntroCard(onOpen: () -> Unit, onDismiss: () -> Unit) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Outlined.Info,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(uiString(R.string.l10n_today_screen_new_here_b81f2e17), style = NoopType.headline, color = Palette.textPrimary)
                Spacer(Modifier.weight(1f))
                IconButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .size(Metrics.iconButton)
                        .semantics { contentDescription = uiString(R.string.l10n_today_screen_dismiss_70afe9ef) },
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(Metrics.iconSmall),
                    )
                }
            }
            Text(
                uiString(R.string.l10n_today_screen_see_how_charge_effort_and_rest_80243197),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onOpen) {
                    Text(uiString(R.string.l10n_today_screen_see_how_it_works_f7b38f07), style = NoopType.captionNumber, color = Palette.accent)
                }
            }
        }
    }
}

// MARK: - Liquid Today header (iOS LiquidTodayView.scene parity)
//
// Brand masthead + selected-day greeting, matching LiquidTodayView.scene. Quick actions stay in the
// persistent floating + beside bottom navigation; page layout controls live in one conventional overflow.

@Composable
private fun LiquidTodayHeader(
    headline: String,
    dateLine: String,
    connected: Boolean,
    batteryPct: Double?,
    charging: Boolean?,
    syncStatus: @Composable () -> Unit,
    weatherState: TodayWeatherState? = null,
    temperatureUnit: TemperatureUnit,
    onWeatherClick: () -> Unit,
    onOpenCalendar: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenDevices: () -> Unit,
    onArrange: () -> Unit,
    onDashboardCards: () -> Unit,
    onKeyMetrics: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var showMenu by remember { mutableStateOf(false) }
    val compactLayout = currentTodayLayoutIsCompact()
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(
            if (compactLayout) Metrics.space12 else Metrics.space16,
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        ) {
            LiquidWordmark(compact = true)
            Spacer(Modifier.weight(1f))
            HeaderIconButton(
                icon = Icons.Filled.CalendarMonth,
                description = "History calendar",
                onClick = onOpenCalendar,
            )
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(Palette.surfaceRaised.copy(alpha = 0.82f))
                    .border(1.dp, Palette.hairlineStrong.copy(alpha = 0.72f), CircleShape)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onOpenSettings,
                    )
                    .semantics {
                        contentDescription =
                            uiString(R.string.l10n_today_screen_profile_and_settings_9b3d12f2)
                    },
                contentAlignment = Alignment.Center,
            ) {
                if (ProfileAvatarStore.hasAvatar) {
                    ProfileAvatar(size = 34.dp)
                } else {
                    Icon(
                        Icons.Outlined.AccountCircle,
                        contentDescription = null,
                        tint = Palette.textPrimary,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            LiquidBandBatteryButton(
                connected = connected,
                batteryPct = batteryPct,
                charging = charging,
                onClick = onOpenDevices,
            )
            Box {
                HeaderIconButton(
                    icon = Icons.Filled.MoreHoriz,
                    description = "Customize Today",
                    onClick = { showMenu = true },
                )
                DropdownMenu(
                    expanded = showMenu,
                    onDismissRequest = { showMenu = false },
                ) {
                    DropdownMenuItem(
                        text = {
                            Text(uiString(R.string.l10n_today_screen_arrange_today_sections_9675862b))
                        },
                        leadingIcon = { Icon(Icons.Filled.SwapVert, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onArrange()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.appwide_today_dashboard_cards)) },
                        leadingIcon = { Icon(Icons.Filled.Functions, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onDashboardCards()
                        },
                    )
                    DropdownMenuItem(
                        text = { Text(uiString(R.string.l10n_today_screen_edit_key_metrics_f95e61a4)) },
                        leadingIcon = { Icon(Icons.Filled.Tune, contentDescription = null) },
                        onClick = {
                            showMenu = false
                            onKeyMetrics()
                        },
                    )
                }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClickLabel = "Change day",
                    onClick = onOpenCalendar,
                )
                .semantics {
                    contentDescription = uiString(
                        R.string.l10n_today_screen_daytitle_humandate_tap_to_pick_a_7e12ce96,
                        headline,
                        dateLine,
                    )
                },
            verticalArrangement = Arrangement.spacedBy(Metrics.space4),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Text(
                    dateLine.uppercase(Locale.getDefault()),
                    style = NoopType.overline.copy(
                        shadow = Shadow(
                            color = Color.Black.copy(alpha = 0.35f),
                            offset = Offset(0f, 1f),
                            blurRadius = 8f,
                        ),
                    ),
                    color = Color.White.copy(alpha = 0.62f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                syncStatus()
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Text(
                    headline,
                    style = NoopType.number(
                        if (compactLayout) 28f else 30f,
                        weight = FontWeight.Bold,
                    ).copy(
                        shadow = Shadow(
                            color = Color.Black.copy(alpha = 0.4f),
                            offset = Offset(0f, 1f),
                            blurRadius = 10f,
                        ),
                    ),
                    color = Color.White,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (weatherState != null) {
                    TodayWeatherChip(
                        state = weatherState,
                        temperatureUnit = temperatureUnit,
                        onClick = onWeatherClick,
                    )
                }
            }
        }
    }
}

@Composable
private fun TodayWeatherChip(
    state: TodayWeatherState,
    temperatureUnit: TemperatureUnit,
    onClick: () -> Unit,
) {
    val compactLayout = currentTodayLayoutIsCompact()
    val snapshot = state.snapshot
    val fontScale = LocalDensity.current.fontScale
    val showVisualText = todayWeatherShowsVisualText(
        hasSnapshot = snapshot != null,
        fontScale = fontScale,
    )
    val expandForLargeText = snapshot != null && fontScale > 1.30f
    val condition = snapshot?.let { TodayWeatherCode.condition(it.weatherCode) }
    val conditionLabel = condition?.let { todayWeatherConditionLabel(it) }
    val accessibilityLabel = when {
        snapshot != null && conditionLabel != null -> {
            "$conditionLabel, ${
                UnitFormatter.temperatureFromCelsius(
                    snapshot.temperatureC,
                    temperatureUnit,
                    decimals = 0,
                )
            }"
        }
        state.status == TodayWeatherStatus.DENIED ->
            stringResource(R.string.today_weather_location_off_accessibility)
        else -> stringResource(R.string.today_weather_enable_accessibility)
    }
    val tint = if (snapshot == null) Palette.textSecondary else Palette.chargeBright
    val interaction = remember { MutableInteractionSource() }

    Box(
        modifier = Modifier
            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .liquidPress(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .testTag("noop.today.weather")
            .semantics {
                contentDescription = accessibilityLabel
                role = Role.Button
            },
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .then(
                    if (expandForLargeText) {
                        Modifier
                            .widthIn(min = 82.dp)
                            .heightIn(min = 34.dp)
                    } else {
                        Modifier
                            .width(
                                when {
                                    !showVisualText -> if (compactLayout) 32.dp else 34.dp
                                    compactLayout -> 76.dp
                                    else -> 82.dp
                                },
                            )
                            .height(if (compactLayout) 32.dp else 34.dp)
                    },
                )
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.055f))
                .border(
                    width = 0.8.dp,
                    color = if (snapshot == null) {
                        Palette.hairlineStrong.copy(alpha = 0.72f)
                    } else {
                        Palette.chargeColor.copy(alpha = 0.34f)
                    },
                    shape = CircleShape,
                )
                .then(
                    if (expandForLargeText) {
                        Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                    } else {
                        Modifier
                    },
                ),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                state.status == TodayWeatherStatus.LOCATING -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        color = tint,
                        strokeWidth = 1.5.dp,
                    )
                    if (showVisualText) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = stringResource(R.string.today_weather),
                            style = NoopType.captionNumber,
                            color = tint,
                            maxLines = 1,
                        )
                    }
                }
                snapshot != null && condition != null -> {
                    Icon(
                        imageVector = todayWeatherIcon(condition),
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(16.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = weatherCompactTemperature(snapshot.temperatureC, temperatureUnit),
                        style = NoopType.captionNumber,
                        color = tint,
                        maxLines = 1,
                    )
                }
                state.status == TodayWeatherStatus.DENIED -> {
                    Icon(
                        imageVector = Icons.Filled.LocationOff,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(16.dp),
                    )
                    if (showVisualText) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = stringResource(R.string.today_weather),
                            style = NoopType.captionNumber,
                            color = tint,
                            maxLines = 1,
                        )
                    }
                }
                else -> {
                    Icon(
                        imageVector = Icons.Filled.Cloud,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(16.dp),
                    )
                    if (showVisualText) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = stringResource(R.string.today_weather),
                            style = NoopType.captionNumber,
                            color = tint,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TodayWeatherDetailsDialog(
    state: TodayWeatherState,
    temperatureUnit: TemperatureUnit,
    onDismiss: () -> Unit,
    onEnable: () -> Unit,
    onRefresh: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenAttribution: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 360.dp),
            shape = RoundedCornerShape(8.dp),
            color = Palette.surfaceRaised,
            tonalElevation = 0.dp,
        ) {
            Column(
                modifier = Modifier.padding(Metrics.space20),
                verticalArrangement = Arrangement.spacedBy(Metrics.space12),
            ) {
                val snapshot = state.snapshot
                when {
                    snapshot != null -> {
                        val condition = TodayWeatherCode.condition(snapshot.weatherCode)
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                imageVector = todayWeatherIcon(condition),
                                contentDescription = null,
                                tint = Palette.chargeBright,
                                modifier = Modifier.size(28.dp),
                            )
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(
                                    text = todayWeatherConditionLabel(condition),
                                    style = NoopType.headline,
                                    color = Palette.textPrimary,
                                )
                                Text(
                                    text = UnitFormatter.temperatureFromCelsius(
                                        snapshot.temperatureC,
                                        temperatureUnit,
                                        decimals = 0,
                                    ),
                                    style = NoopType.number(24f),
                                    color = Palette.textPrimary,
                                )
                            }
                        }
                        val updated = remember(snapshot.observedAtMs) {
                            Instant.ofEpochMilli(snapshot.observedAtMs)
                                .atZone(ZoneId.systemDefault())
                                .format(
                                    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
                                        .withLocale(Locale.getDefault()),
                                )
                        }
                        Text(
                            text = stringResource(R.string.today_weather_updated_format, updated),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                        TextButton(onClick = onRefresh) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = null,
                                modifier = Modifier.size(17.dp),
                            )
                            Spacer(Modifier.width(7.dp))
                            Text(stringResource(R.string.today_weather_refresh))
                        }
                        TextButton(onClick = onOpenAttribution) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                                contentDescription = null,
                                modifier = Modifier.size(17.dp),
                            )
                            Spacer(Modifier.width(7.dp))
                            Text(stringResource(R.string.today_weather_data_attribution))
                        }
                    }
                    state.status == TodayWeatherStatus.DENIED -> {
                        Icon(
                            imageVector = Icons.Filled.LocationOff,
                            contentDescription = null,
                            tint = Palette.textSecondary,
                            modifier = Modifier.size(28.dp),
                        )
                        Text(
                            text = stringResource(R.string.today_weather_location_off),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Button(onClick = onOpenSettings) {
                            Text(stringResource(R.string.today_weather_open_settings))
                        }
                        TextButton(onClick = onRefresh) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = null,
                                modifier = Modifier.size(17.dp),
                            )
                            Spacer(Modifier.width(7.dp))
                            Text(stringResource(R.string.today_weather_retry))
                        }
                    }
                    state.status == TodayWeatherStatus.FAILED ||
                        state.status == TodayWeatherStatus.UNAVAILABLE -> {
                        Icon(
                            imageVector = Icons.Filled.Cloud,
                            contentDescription = null,
                            tint = Palette.textSecondary,
                            modifier = Modifier.size(28.dp),
                        )
                        Text(
                            text = stringResource(R.string.today_weather_unavailable),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Button(onClick = onRefresh) {
                            Text(stringResource(R.string.today_weather_retry))
                        }
                    }
                    state.status == TodayWeatherStatus.LOCATING -> {
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp),
                                strokeWidth = 2.dp,
                            )
                            Text(
                                text = stringResource(R.string.today_weather_current),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                        }
                    }
                    else -> {
                        Icon(
                            imageVector = Icons.Filled.Cloud,
                            contentDescription = null,
                            tint = Palette.textSecondary,
                            modifier = Modifier.size(28.dp),
                        )
                        Text(
                            text = stringResource(R.string.today_weather_current),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            text = stringResource(R.string.today_weather_privacy),
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                        Button(onClick = onEnable) {
                            Text(stringResource(R.string.today_weather_enable))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun todayWeatherConditionLabel(condition: TodayWeatherCondition): String =
    stringResource(
        when (condition) {
            TodayWeatherCondition.CLEAR -> R.string.today_weather_condition_clear
            TodayWeatherCondition.MOSTLY_CLEAR -> R.string.today_weather_condition_mostly_clear
            TodayWeatherCondition.PARTLY_CLOUDY -> R.string.today_weather_condition_partly_cloudy
            TodayWeatherCondition.OVERCAST -> R.string.today_weather_condition_overcast
            TodayWeatherCondition.FOG -> R.string.today_weather_condition_fog
            TodayWeatherCondition.DRIZZLE -> R.string.today_weather_condition_drizzle
            TodayWeatherCondition.RAIN -> R.string.today_weather_condition_rain
            TodayWeatherCondition.SNOW -> R.string.today_weather_condition_snow
            TodayWeatherCondition.THUNDERSTORM ->
                R.string.today_weather_condition_thunderstorm
            TodayWeatherCondition.UNKNOWN -> R.string.today_weather_condition_unknown
        },
    )

private fun todayWeatherIcon(condition: TodayWeatherCondition): ImageVector = when (condition) {
    TodayWeatherCondition.CLEAR,
    TodayWeatherCondition.MOSTLY_CLEAR -> Icons.Filled.WbSunny
    TodayWeatherCondition.RAIN,
    TodayWeatherCondition.DRIZZLE -> Icons.Filled.WaterDrop
    TodayWeatherCondition.SNOW -> Icons.Filled.AcUnit
    TodayWeatherCondition.THUNDERSTORM -> Icons.Filled.Thunderstorm
    TodayWeatherCondition.PARTLY_CLOUDY,
    TodayWeatherCondition.OVERCAST,
    TodayWeatherCondition.FOG,
    TodayWeatherCondition.UNKNOWN -> Icons.Filled.Cloud
}

private fun weatherCompactTemperature(
    celsius: Double,
    unit: TemperatureUnit,
): String {
    val value = if (unit == TemperatureUnit.FAHRENHEIT) {
        UnitFormatter.celsiusToFahrenheit(celsius)
    } else {
        celsius
    }
    return "${value.roundToInt()}°"
}

@Composable
private fun HeaderIconButton(
    icon: ImageVector,
    description: String,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = Modifier
            .size(34.dp)
            .liquidPress(interaction)
            .clip(CircleShape)
            .background(Palette.surfaceRaised.copy(alpha = 0.82f))
            .border(1.dp, Palette.hairlineStrong.copy(alpha = 0.72f), CircleShape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(17.dp),
        )
    }
}

@Composable
private fun TodayHeaderSyncStatus(viewModel: AppViewModel) {
    val status by viewModel.historySyncStatus.collectAsStateWithLifecycle()
    SyncStatusChip(
        backfilling = status.backfilling,
        chunks = status.batches,
        lastSyncAt = status.lastSyncAt,
        historySyncExperimental = status.experimental,
    )
}

/**
 * Owns exact history progress and its elapsed clock inside one list item. The Today root observes only
 * the boolean write edge, so a new batch or row count cannot rebuild the dashboard while it is scrolled.
 */
@Composable
private fun TodaySyncingHistoryStatus(
    viewModel: AppViewModel,
    hasCachedContent: Boolean,
) {
    val status by viewModel.historySyncStatus.collectAsStateWithLifecycle()
    var now by remember(
        status.backfilling,
        status.startedAt,
        status.lastDurableProgressAt,
        hasCachedContent,
    ) {
        mutableLongStateOf(System.currentTimeMillis() / 1_000L)
    }
    LaunchedEffect(
        status.backfilling,
        status.startedAt,
        status.lastDurableProgressAt,
        hasCachedContent,
    ) {
        now = System.currentTimeMillis() / 1_000L
        val startedAt = status.startedAt
        if (status.backfilling && startedAt != null) {
            val progressReference = status.lastDurableProgressAt ?: startedAt
            val deadlines = listOf(
                startedAt + HistorySyncPresentationPolicy.EXPANDED_FOR_SECONDS,
                progressReference + HistorySyncDurableProgressPolicy.STALLED_AFTER_SECONDS,
            ).filter { it > now }.sorted()
            for (deadline in deadlines) {
                val remaining = (deadline - System.currentTimeMillis() / 1_000L).coerceAtLeast(0)
                if (remaining > 0) delay(remaining * 1_000L)
                now = System.currentTimeMillis() / 1_000L
            }
        }
    }
    val presentation = HistorySyncPresentationPolicy.state(
        isSyncing = status.backfilling,
        hasCachedContent = hasCachedContent,
        startedAt = status.startedAt,
        lastDurableProgressAt = status.lastDurableProgressAt,
        now = now,
    )
    if (
        status.backfilling &&
        (
            presentation == HistorySyncPresentationState.EXPANDED ||
                presentation == HistorySyncPresentationState.ATTENTION
            )
    ) {
        SyncingHistoryNote(
            chunks = status.batches,
            rows = status.rows,
            newestDataUnix = status.newestDataUnix,
            startedAt = status.startedAt,
            lastDurableProgressAt = status.lastDurableProgressAt,
        )
    }
}

/** #245: compact sync-status chip for the Today top bar, shown to EVERY user. The full-width
 *  SyncingHistoryNote is gated on `recovery == null`, so an established user (and especially a WHOOP 5/MG
 *  owner, whose history offloads are rare) saw no sync feedback on Today. THREE states so the ABSENCE of
 *  active syncing reads as "caught up", not "missing indicator" (the real #245 confusion): actively
 *  offloading → ⟳ N; idle with a known last-sync → ✓ Xm; a 5/MG whose history sync is experimental
 *  (live-connected, no completed offload yet) → ✓ live. Nothing shows only on a true cold start (the
 *  building-scores note owns that). Twin of iOS SyncStatusChip. DRAFT (#245): final styling/wording TBD. */
@Composable
private fun SyncStatusChip(
    backfilling: Boolean,
    chunks: Int,
    lastSyncAt: Long?,
    historySyncExperimental: Boolean,
) {
    when {
        backfilling -> ChipCapsule(
            Icons.Filled.Autorenew, "$chunks", Palette.accent, "Syncing Noop Band history, $chunks chunks")
        lastSyncAt != null -> ChipCapsule(
            Icons.Filled.Check, shortSyncAgo(lastSyncAt), Palette.textSecondary,
            "Noop Band history synced ${shortSyncAgo(lastSyncAt)} ago")
        historySyncExperimental -> ChipCapsule(
            Icons.Filled.Check, "live", Palette.textSecondary,
            "Connected; Noop Band history sync is experimental on this firmware")
        // else: cold start — render nothing; the building-scores note covers it.
    }
}

/** The shared sync-chip capsule (icon + terse label). Twin of the iOS `SyncStatusChip.chip`. */
@Composable
private fun ChipCapsule(icon: ImageVector, text: String, tint: Color, desc: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(Palette.surfaceInset)
            .padding(horizontal = 8.dp, vertical = 5.dp),
    ) {
        Icon(icon, contentDescription = desc, tint = tint, modifier = Modifier.size(14.dp))
        Text(text, style = NoopType.caption, color = tint)
    }
}

/** Compact relative age for the header chip ("now" / "Nm" / "Nh" / "Nd") from a unix-SECONDS timestamp -
 *  deliberately terse. Twin of the iOS `SyncStatusChip.shortAgo`. */
private fun shortSyncAgo(unixSec: Long): String {
    val secs = (System.currentTimeMillis() / 1000L - unixSec).coerceAtLeast(0)
    return when {
        secs < 60 -> "now"
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}

/** Exact Android twin of iOS LiquidBatteryButton. A single 70x34 NOOP status capsule replaces the
 * second profile-like circle and distinguishes disconnected, awaiting-reading, charging, and current
 * percentage states without presenting a stale battery value as live. */
@Composable
private fun LiquidBandBatteryButton(
    connected: Boolean,
    batteryPct: Double?,
    charging: Boolean?,
    onClick: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val value = when {
        !connected -> "OFF"
        batteryPct != null -> "${batteryPct.roundToInt()}%"
        charging == true -> "CHG"
        else -> "SYNC"
    }
    val tone = when {
        !connected -> Palette.textTertiary
        charging == true -> Palette.chargeColor
        batteryPct == null -> Palette.textSecondary
        batteryPct < 15 -> Palette.statusCritical
        batteryPct < 35 -> Palette.statusWarning
        else -> Palette.chargeColor
    }
    val label = when {
        !connected -> stringResource(R.string.today_band_battery_disconnected)
        batteryPct == null && charging == true ->
            stringResource(R.string.today_band_battery_charging_no_reading)
        batteryPct == null -> stringResource(R.string.today_band_battery_no_reading)
        charging == true ->
            stringResource(R.string.today_band_battery_percent_charging, batteryPct.roundToInt())
        else -> stringResource(R.string.today_band_battery_percent, batteryPct.roundToInt())
    }
    Row(
        modifier = Modifier
            .width(70.dp)
            .height(34.dp)
            .liquidPress(interaction)
            .clip(RoundedCornerShape(50))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        Palette.surfaceRaised.copy(alpha = 0.92f),
                        Palette.surfaceOverlay.copy(alpha = 0.74f),
                    ),
                ),
            )
            .border(
                1.dp,
                Brush.linearGradient(
                    colors = listOf(
                        Palette.hairlineStrong.copy(alpha = 0.82f),
                        Palette.hairline.copy(alpha = 0.52f),
                    ),
                ),
                RoundedCornerShape(50),
            )
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HorizontalBandBatteryGlyph(
            level = when {
                batteryPct != null -> (batteryPct / 100.0).toFloat().coerceIn(0f, 1f)
                connected && charging == true -> 1f
                else -> 0f
            },
            charging = connected && charging == true,
            tone = tone,
        )
        Spacer(Modifier.width(5.dp))
        Column(verticalArrangement = Arrangement.spacedBy((-1).dp)) {
            Text(
                "NOOP",
                style = NoopType.caption.copy(fontSize = 6.sp, fontWeight = FontWeight.Bold),
                color = Palette.textSecondary,
                maxLines = 1,
            )
            Text(
                value,
                style = NoopType.number(10f, weight = FontWeight.Bold),
                color = tone,
                maxLines = 1,
            )
        }
    }
}

/** SF Battery-style horizontal silhouette used by iOS in the matching masthead control. */
@Composable
private fun HorizontalBandBatteryGlyph(
    level: Float,
    charging: Boolean,
    tone: Color,
) {
    Box(
        modifier = Modifier.size(width = 16.dp, height = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.matchParentSize()) {
            val stroke = 1.25.dp.toPx()
            val bodyTop = 3.dp.toPx()
            val bodyHeight = 8.dp.toPx()
            val bodyLeft = stroke / 2f
            val terminalWidth = 1.45.dp.toPx()
            val terminalGap = 0.7.dp.toPx()
            val bodyWidth = size.width - bodyLeft - terminalWidth - terminalGap - stroke
            val radius = 2.dp.toPx()

            drawRoundRect(
                color = tone,
                topLeft = Offset(bodyLeft, bodyTop),
                size = Size(bodyWidth, bodyHeight),
                cornerRadius = CornerRadius(radius, radius),
                style = Stroke(width = stroke),
            )
            drawRoundRect(
                color = tone,
                topLeft = Offset(bodyLeft + bodyWidth + terminalGap, bodyTop + 2.1.dp.toPx()),
                size = Size(terminalWidth, 3.8.dp.toPx()),
                cornerRadius = CornerRadius(terminalWidth / 2f, terminalWidth / 2f),
            )

            if (level > 0f) {
                val inset = 2.dp.toPx()
                val available = (bodyWidth - inset * 2f).coerceAtLeast(0f)
                drawRoundRect(
                    color = tone,
                    topLeft = Offset(bodyLeft + inset, bodyTop + inset),
                    size = Size((available * level).coerceAtLeast(1.dp.toPx()), bodyHeight - inset * 2f),
                    cornerRadius = CornerRadius(0.8.dp.toPx(), 0.8.dp.toPx()),
                )
            }
        }
        if (charging) {
            Icon(
                Icons.Filled.Bolt,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(7.5.dp),
            )
        }
    }
}

// MARK: - NOOP wordmark (iOS LiquidWordmark parity — centred, with a tap easter egg)
//
// The subtle "N O O P" wordmark that sits on the sky between the header and the hero. Built as a row of
// letters (not one tracked string, which adds a trailing gap after the last glyph and pushes the word
// off-centre), so it sits DEAD centre, white @ ~50% opacity. A tap plays one of several random one-shot
// animations — wiggle / shake / flip / spin / bounce / jelly squash. Mirrors iOS LiquidWordmark.

@Composable
private fun LiquidWordmark(
    modifier: Modifier = Modifier,
    compact: Boolean = false,
) {
    val reduced = rememberReduceMotion()
    var rot by remember { mutableStateOf(0f) }        // z-rotation (wiggle / spin)
    var scaleX by remember { mutableStateOf(1f) }     // horizontal scale (jelly squash)
    var scaleY by remember { mutableStateOf(1f) }     // vertical scale (bounce / jelly)
    var dx by remember { mutableStateOf(0f) }         // horizontal offset (shake)
    var egg by remember { mutableIntStateOf(0) }      // which egg to play (drives the LaunchedEffect)

    val view = LocalView.current
    val animRot by animateFloatAsState(rot, tween(durationMillis = if (reduced) 0 else 520), label = uiString(R.string.l10n_today_screen_wordmark_rot_21de874b))
    val animScaleX by animateFloatAsState(scaleX, tween(durationMillis = if (reduced) 0 else 380), label = uiString(R.string.l10n_today_screen_wordmark_sx_68fa7b60))
    val animScaleY by animateFloatAsState(scaleY, tween(durationMillis = if (reduced) 0 else 380), label = uiString(R.string.l10n_today_screen_wordmark_sy_7b8bd743))
    val animDx by animateFloatAsState(dx, tween(durationMillis = if (reduced) 0 else 420), label = uiString(R.string.l10n_today_screen_wordmark_dx_d428284f))

    // On each tap, kick a value to an extreme then settle it back so the animateFloatAsState eases through
    // to rest — a natural wobble without hand-authored keyframes. Six variants, chosen at random per tap.
    LaunchedEffect(egg) {
        if (egg == 0) return@LaunchedEffect
        when ((0..5).random()) {
            0 -> { rot = -12f; kotlinx.coroutines.delay(90); rot = 0f }            // wiggle
            1 -> { dx = -12f; kotlinx.coroutines.delay(90); dx = 0f }              // shake
            2 -> { rot += 360f }                                                    // spin
            3 -> { scaleX = 1.28f; scaleY = 1.28f; kotlinx.coroutines.delay(90); scaleX = 1f; scaleY = 1f } // bounce
            4 -> { scaleX = 1.35f; scaleY = 0.7f; kotlinx.coroutines.delay(90); scaleX = 1f; scaleY = 1f }  // jelly
            else -> { rot += 360f }                                                 // flip (spin twin)
        }
    }

    Row(
        modifier = (if (compact) modifier.width(70.dp) else modifier.fillMaxWidth())
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) {
                egg += 1
                view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
            }
            .graphicsLayer {
                rotationZ = animRot
                this.scaleX = animScaleX
                this.scaleY = animScaleY
                translationX = animDx
            }
            .clearAndSetSemantics {}, // decorative wordmark — invisible to TalkBack
        horizontalArrangement = Arrangement.spacedBy(
            if (compact) 6.dp else 14.dp,
            Alignment.CenterHorizontally,
        ),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        "NOOP".forEach { ch ->
            Text(
                ch.toString(),
                style = NoopType.number(if (compact) 13f else 16f, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.25f), offset = Offset(0f, 1f), blurRadius = 6f)),
                color = Color.White.copy(alpha = if (compact) 0.88f else 0.72f),
            )
        }
    }
}

// MARK: - Daily Signal header

internal fun dailySignalHeaderFitsSingleRow(
    fontScale: Float,
    availableWidthPx: Int,
    identityTextWidthPx: Int,
    stateTextWidthPx: Int,
    sourceTextWidthPx: Int?,
    fixedContentWidthPx: Int,
): Boolean {
    val requiredWidthPx = identityTextWidthPx +
        stateTextWidthPx +
        (sourceTextWidthPx ?: 0) +
        fixedContentWidthPx
    return fontScale <= 1.15f && requiredWidthPx <= availableWidthPx
}

@Composable
private fun DailySignalHeader(
    status: DailySignalStatus,
    sourceLabel: String?,
    viewModel: AppViewModel,
    onOpen: () -> Unit,
) {
    val tint = when (status) {
        DailySignalStatus.STEADY -> Palette.statusPositive
        DailySignalStatus.WATCH -> Palette.statusWarning
        DailySignalStatus.ALERT -> DAILY_SIGNAL_ALERT_TINT
        DailySignalStatus.BUILDING -> Palette.onDarkSecondary.copy(alpha = 0.72f)
    }
    val label = when (status) {
        DailySignalStatus.STEADY -> uiString(R.string.appwide_daily_signal_status_aligned)
        DailySignalStatus.WATCH -> uiString(R.string.appwide_daily_signal_status_recheck)
        DailySignalStatus.ALERT -> uiString(R.string.appwide_daily_signal_status_check_in)
        DailySignalStatus.BUILDING -> uiString(R.string.appwide_daily_signal_status_building)
    }

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onOpen,
            )
            .padding(start = Metrics.space16, end = Metrics.space16, top = Metrics.space14),
    ) {
        val density = LocalDensity.current
        val textMeasurer = rememberTextMeasurer(cacheSize = 6)
        val identityText = uiString(R.string.appwide_daily_signal_label).uppercase()
        val stateText = label.uppercase()
        val sourceText = sourceLabel?.uppercase()
        val identityTextWidthPx = textMeasurer.measure(
            text = identityText,
            style = NoopType.overline,
            softWrap = false,
            maxLines = 1,
        ).size.width
        val stateTextWidthPx = textMeasurer.measure(
            text = stateText,
            style = NoopType.overline,
            softWrap = false,
            maxLines = 1,
        ).size.width
        val sourceTextWidthPx = sourceText?.let {
            textMeasurer.measure(
                text = it,
                style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 0.sp),
                softWrap = false,
                maxLines = 1,
            ).size.width
        }
        val outerGapCount = if (sourceText == null) 2 else 3
        val fixedContentWidth = (
            30f + // waveform
                Metrics.space8.value + // identity's internal gap
                20f + // state pill horizontal padding
                (Metrics.space8.value * outerGapCount) +
                (if (sourceText == null) 0f else Metrics.space16.value) +
                Metrics.space4.value // rounding and font-renderer safety
            ).dp
        val fitsSingleRow = dailySignalHeaderFitsSingleRow(
            fontScale = density.fontScale,
            availableWidthPx = with(density) { maxWidth.roundToPx() },
            identityTextWidthPx = identityTextWidthPx,
            stateTextWidthPx = stateTextWidthPx,
            sourceTextWidthPx = sourceTextWidthPx,
            fixedContentWidthPx = with(density) { fixedContentWidth.roundToPx() },
        )
        val semantics = Modifier.semantics {
            contentDescription = uiString(
                R.string.appwide_a11y_state_format,
                uiString(R.string.appwide_daily_signal_label),
                label,
            )
            role = Role.Button
        }
        if (fitsSingleRow) {
            Row(
                modifier = semantics.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                DailySignalIdentity(status = status, tint = tint)
                Spacer(Modifier.weight(1f))
                if (sourceLabel != null) {
                    DailySignalSourceBadgeLive(
                        text = sourceLabel,
                        viewModel = viewModel,
                    )
                }
                DailySignalStatePill(title = label, tint = tint)
            }
        } else {
            Column(
                modifier = semantics.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(Metrics.space4),
            ) {
                DailySignalIdentity(status = status, tint = tint)
                DailySignalStatePill(
                    title = label,
                    tint = tint,
                    modifier = Modifier.align(Alignment.End),
                )
                if (sourceLabel != null) {
                    DailySignalSourceBadgeLive(
                        text = sourceLabel,
                        viewModel = viewModel,
                        modifier = Modifier.align(Alignment.End),
                    )
                }
            }
        }
    }
}

@Composable
private fun DailySignalSourceBadgeLive(
    text: String,
    viewModel: AppViewModel,
    modifier: Modifier = Modifier,
) {
    val status by viewModel.historySyncStatus.collectAsStateWithLifecycle()
    DailySignalSourceBadge(
        text = text,
        bandBackfilling = status.backfilling,
        bandSyncChunks = status.batches,
        bandLastSyncAt = status.lastSyncAt,
        modifier = modifier,
    )
}

@Composable
private fun DailySignalIdentity(
    status: DailySignalStatus,
    tint: Color,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DailySignalWaveform(status = status, tint = tint)
        Text(
            uiString(R.string.appwide_daily_signal_label).uppercase(),
            style = NoopType.overline,
            color = Palette.onDarkSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * The hero's source is provenance, not a permanent connection indicator. It stays neutral at rest, uses
 * an indeterminate green sweep only while a real history offload is active, then briefly confirms success
 * in green. The band protocol has no total pending count, so this deliberately never renders a percentage.
 */
@Composable
private fun DailySignalSourceBadge(
    text: String,
    bandBackfilling: Boolean,
    bandSyncChunks: Int,
    bandLastSyncAt: Long?,
    modifier: Modifier = Modifier,
) {
    val interactionInProgress = LocalLiquidInteractionInProgress.current
    val isBand = sourceLabelIncludesCompatibleBand(text)
    val syncingRaw = isBand && bandBackfilling
    var presentingSync by remember(isBand) { mutableStateOf(false) }
    var justSynced by remember(isBand) { mutableStateOf(false) }
    var syncStartedAt by remember(isBand) { mutableStateOf<Long?>(null) }

    LaunchedEffect(isBand, syncingRaw, bandLastSyncAt) {
        if (!isBand) {
            presentingSync = false
            justSynced = false
            syncStartedAt = null
        } else if (syncingRaw) {
            if (!presentingSync) syncStartedAt = bandLastSyncAt
            presentingSync = true
            justSynced = false
        } else if (presentingSync) {
            // Backfilling briefly flips false between chunks. Settle only after a quiet interval, then require
            // a real HISTORY_COMPLETE timestamp advance before showing the green success confirmation.
            kotlinx.coroutines.delay(3_000)
            val completed = bandSyncCompletionAdvanced(syncStartedAt, bandLastSyncAt)
            presentingSync = false
            justSynced = completed
            syncStartedAt = null
            if (!completed) return@LaunchedEffect
            kotlinx.coroutines.delay(1_800)
            justSynced = false
        }
    }

    if (!isBand) {
        SourceBadge(text = text, tint = Palette.onDarkSecondary, modifier = modifier)
        return
    }

    val syncing = presentingSync
    val tone = if (syncing || justSynced) Palette.statusPositive else Palette.onDarkSecondary
    val shape = RoundedCornerShape(50)
    val description = when {
        syncing && bandSyncChunks > 0 ->
            stringResource(R.string.appwide_today_band_sync_progress_format, bandSyncChunks)
        syncing -> stringResource(R.string.appwide_today_band_sync_syncing)
        justSynced -> stringResource(R.string.appwide_today_band_sync_synced)
        else -> text
    }

    Box(
        modifier = modifier
            .heightIn(min = Metrics.sourceBadgeHeight)
            .clip(shape)
            .background(Palette.onDarkSecondary.copy(alpha = 0.14f))
            .border(0.75.dp, Palette.onDarkSecondary.copy(alpha = 0.20f), shape)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        if (syncing && !rememberPoseStill() && !interactionInProgress) {
            DailySignalBandSyncSweep(Modifier.matchParentSize())
        }
        Text(
            text = text.uppercase(),
            style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 0.sp),
            color = tone,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = Metrics.space8),
        )
    }
}

/** Isolated so no infinite animation clock exists while the band is idle. */
private const val DAILY_SIGNAL_BAND_SYNC_TRANSITION = "daily-signal-band-sync"
private const val DAILY_SIGNAL_BAND_SYNC_PHASE = "daily-signal-band-sync-phase"

@Composable
private fun DailySignalBandSyncSweep(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = DAILY_SIGNAL_BAND_SYNC_TRANSITION)
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1_200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = DAILY_SIGNAL_BAND_SYNC_PHASE,
    )
    Canvas(modifier = modifier) {
        val sweepWidth = (size.width * 0.48f).coerceAtLeast(22.dp.toPx())
        val left = -sweepWidth + (size.width + sweepWidth) * phase
        drawRect(
            brush = Brush.horizontalGradient(
                colors = listOf(
                    Color.Transparent,
                    Palette.statusPositive.copy(alpha = 0.30f),
                    Color.Transparent,
                ),
                startX = left,
                endX = left + sweepWidth,
            ),
            topLeft = Offset(left, 0f),
            size = Size(sweepWidth, size.height),
        )
    }
}

@Composable
private fun DailySignalStatePill(
    title: String,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(50)
    Text(
        text = title,
        style = NoopType.overline,
        color = tint,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        textAlign = TextAlign.Center,
        modifier = modifier
            .clip(shape)
            .background(tint.copy(alpha = 0.12f))
            .border(0.75.dp, tint.copy(alpha = 0.24f), shape)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = title },
    )
}

@Composable
private fun DailySignalWaveform(
    status: DailySignalStatus,
    tint: Color,
) {
    val posed = rememberPoseStill()
    val interactionInProgress = LocalLiquidInteractionInProgress.current
    val progress = remember { Animatable(1f) }
    val sweepMillis = if (status == DailySignalStatus.ALERT) 550 else 780
    val restMillis = when (status) {
        DailySignalStatus.ALERT -> 1_050L
        DailySignalStatus.WATCH -> 1_850L
        DailySignalStatus.STEADY -> 3_200L
        DailySignalStatus.BUILDING -> 4_000L
    }

    LaunchedEffect(status, posed, interactionInProgress) {
        progress.snapTo(1f)
        if (posed || interactionInProgress) return@LaunchedEffect
        while (true) {
            progress.snapTo(0f)
            progress.animateTo(
                1f,
                animationSpec = tween(sweepMillis, easing = FastOutSlowInEasing),
            )
            kotlinx.coroutines.delay(restMillis)
        }
    }

    Canvas(
        modifier = Modifier
            .width(30.dp)
            .height(17.dp)
            .clearAndSetSemantics {},
    ) {
        val normalized = listOf(
            0.00f to 0.53f,
            0.13f to 0.53f,
            0.20f to 0.39f,
            0.27f to 0.69f,
            0.36f to 0.10f,
            0.45f to 0.84f,
            0.54f to 0.47f,
            0.65f to 0.53f,
            0.75f to 0.53f,
            0.82f to 0.40f,
            0.89f to 0.53f,
            1.00f to 0.53f,
        )
        val path = Path().apply {
            normalized.forEachIndexed { index, point ->
                val offset = Offset(point.first * size.width, point.second * size.height)
                if (index == 0) moveTo(offset.x, offset.y) else lineTo(offset.x, offset.y)
            }
        }
        val stroke = Stroke(width = 1.4.dp.toPx(), cap = StrokeCap.Round)
        drawPath(
            path = path,
            color = tint.copy(alpha = if (status == DailySignalStatus.BUILDING) 0.34f else 0.28f),
            style = stroke,
        )
        val right = progress.value * size.width
        val left = ((progress.value - 0.34f).coerceAtLeast(0f)) * size.width
        clipRect(left = left, right = right) {
            drawPath(
                path = path,
                color = tint,
                style = Stroke(width = 1.9.dp.toPx(), cap = StrokeCap.Round),
            )
        }
    }
}

// MARK: - Score hero
//
// One Recovery headline plus Sleep/Effort satellites, matching iOS LiquidTodayView. All values still
// resolve through the same imported/computed/carry rules; this changes hierarchy only.

@Composable
private fun ScoreHeroRow(
    day: DailyMetric?,
    restScore: Double?,
    recoveryCalibration: Int?,
    lastScoredCharge: LastCharge? = null,
    effortScale: EffortScale,
    liveTodayStrain: Double? = null,
    fitnessAge: Double? = null,
    profileAge: Int? = null,
    fitnessCalibration: String? = null,
    showFitnessAge: Boolean = false,
    onScoreInfo: (ScoreSection) -> Unit,
    onChargeTap: (() -> Unit)? = null,
    onFitnessAgeTap: (() -> Unit)? = null,
) {
    val compactLayout = currentTodayLayoutIsCompact()
    val heroSize = if (compactLayout) 136.dp else 156.dp
    val satelliteSize = if (compactLayout) 54.dp else 60.dp
    val ownRecovery = day?.recovery
    val recovery = ownRecovery ?: lastScoredCharge?.value
    val recoveryColors = recovery?.let(Palette::recoveryGaugeColors)
        ?: (Palette.chargeColor to Palette.chargeBright)
    val recoveryCaption = when {
        recovery != null -> Palette.recoveryState(recovery)
            .lowercase(Locale.getDefault())
            .replaceFirstChar { it.titlecase(Locale.getDefault()) }
        recoveryCalibration != null ->
            "Calibrating $recoveryCalibration of ${Baselines.minNightsSeed}"
        else -> "No data"
    }

    val strain = StrainScorer.effectiveEffort(live = liveTodayStrain, stored = day?.strain)
    val effortMax = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0
    val effortValue = strain?.let { UnitFormatter.effortValue(it, effortScale) }
    val sleepBase = when {
        restScore == null -> Palette.restColor
        restScore < 50 -> Palette.recoveryColor(0.0)
        restScore < 70 -> Palette.statusWarning
        else -> Palette.restColor
    }
    val sleepTip = when {
        restScore == null -> Palette.restBright
        restScore < 50 -> Palette.recoveryColor(30.0)
        restScore < 70 -> Palette.recoveryColor(55.0)
        else -> Palette.restBright
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                horizontal = if (compactLayout) Metrics.space14 else Metrics.space16,
                vertical = if (compactLayout) Metrics.space10 else Metrics.space12,
            ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(
            if (compactLayout) Metrics.space12 else Metrics.space16,
        ),
    ) {
        V2HeroArc(
            label = uiString(R.string.l10n_today_screen_recovery_ea924f72),
            value = recovery,
            base = recoveryColors.first,
            tip = recoveryColors.second,
            caption = recoveryCaption,
            size = heroSize,
            modifier = Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = { onChargeTap?.invoke() ?: onScoreInfo(ScoreSection.CHARGE) },
            ),
        )

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(
                if (compactLayout) 24.dp else 28.dp,
                Alignment.CenterHorizontally,
            ),
            verticalAlignment = Alignment.Top,
        ) {
            V2SatelliteRing(
                label = uiString(R.string.l10n_today_screen_sleep_3cac34e6),
                value = restScore,
                maximum = 100.0,
                base = sleepBase,
                tip = sleepTip,
                size = satelliteSize,
                onClick = { onScoreInfo(ScoreSection.REST) },
            )
            V2SatelliteRing(
                label = uiString(R.string.l10n_health_screen_effort_8c974bc6),
                value = effortValue,
                maximum = effortMax,
                base = Palette.effortColor,
                tip = Palette.effortBright,
                size = satelliteSize,
                decimals = if (effortScale == EffortScale.WHOOP) 1 else 0,
                onClick = { onScoreInfo(ScoreSection.EFFORT) },
            )
        }

        if (showFitnessAge) {
            HorizontalDivider(color = Palette.onDarkSecondary.copy(alpha = 0.20f))
            FitnessAgeHeroLane(
                age = fitnessAge,
                profileAge = profileAge,
                calibration = fitnessCalibration,
                onClick = onFitnessAgeTap,
            )
        }
    }
}

@Composable
private fun V2HeroArc(
    label: String,
    value: Double?,
    base: Color,
    tip: Color,
    caption: String?,
    size: Dp,
    modifier: Modifier = Modifier,
    maximum: Double = 100.0,
) {
    val fraction = if (value != null && maximum > 0) {
        (value / maximum).coerceIn(0.0, 1.0).toFloat()
    } else {
        0f
    }
    Box(
        modifier = modifier
            .size(size)
            .semantics {
                contentDescription = if (value == null) {
                    uiString(
                        R.string.appwide_a11y_state_format,
                        label,
                        caption ?: uiString(R.string.appwide_v4_not_calculated),
                    )
                } else {
                    uiString(
                        R.string.appwide_a11y_state_format,
                        label,
                        uiString(
                            R.string.appwide_v4_value_out_of_with_context_format,
                            value.roundToInt(),
                            maximum.roundToInt(),
                            caption.orEmpty(),
                        ),
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.matchParentSize()) {
            val inset = 10.dp.toPx()
            val stroke = 16.dp.toPx()
            val arcSize = Size(width = this.size.width - inset * 2, height = this.size.height - inset * 2)
            drawArc(
                color = Palette.onDarkSecondary.copy(alpha = 0.16f),
                startAngle = 135f,
                sweepAngle = 270f,
                useCenter = false,
                topLeft = Offset(inset, inset),
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            if (fraction > 0f) {
                drawArc(
                    brush = Brush.sweepGradient(listOf(base, tip)),
                    startAngle = 135f,
                    sweepAngle = 270f * fraction,
                    useCenter = false,
                    topLeft = Offset(inset, inset),
                    size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = value?.roundToInt()?.toString() ?: "-",
                style = NoopType.number(
                    if (value == null) 48f else 56f,
                    weight = FontWeight.Bold,
                ),
                color = if (value == null) {
                    Palette.onDarkSecondary.copy(alpha = 0.64f)
                } else {
                    Color.White
                },
                maxLines = 1,
            )
            Text(label.uppercase(Locale.getDefault()), style = NoopType.overline, color = Palette.onDarkSecondary)
            caption?.let {
                Text(
                    text = it,
                    style = NoopType.caption,
                    color = if (value == null) Palette.onDarkSecondary.copy(alpha = 0.64f) else base,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun V2SatelliteRing(
    label: String,
    value: Double?,
    maximum: Double,
    base: Color,
    tip: Color,
    size: Dp,
    decimals: Int = 0,
    onClick: () -> Unit,
) {
    val fraction = if (value != null && maximum > 0) {
        (value / maximum).coerceIn(0.0, 1.0).toFloat()
    } else {
        0f
    }
    val interaction = remember { MutableInteractionSource() }
    Column(
        modifier = Modifier
            .width(92.dp)
            .liquidPress(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics {
                contentDescription = if (value == null) {
                    uiString(
                        R.string.appwide_a11y_state_format,
                        label,
                        uiString(R.string.appwide_calendar_legend_no_data),
                    )
                } else {
                    uiString(
                        R.string.appwide_a11y_state_format,
                        label,
                        uiString(
                            R.string.appwide_v4_value_text_out_of_text_format,
                            value.toString(),
                            maximum.toString(),
                        ),
                    )
                }
            },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(modifier = Modifier.size(size), contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.matchParentSize()) {
                val stroke = 8.dp.toPx()
                val inset = stroke / 2
                val arcSize = Size(this.size.width - stroke, this.size.height - stroke)
                drawArc(
                    color = Palette.onDarkSecondary.copy(alpha = 0.16f),
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = Offset(inset, inset),
                    size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
                if (fraction > 0f) {
                    drawArc(
                        brush = Brush.sweepGradient(listOf(base, tip)),
                        startAngle = -90f,
                        sweepAngle = 360f * fraction,
                        useCenter = false,
                        topLeft = Offset(inset, inset),
                        size = arcSize,
                        style = Stroke(width = stroke, cap = StrokeCap.Round),
                    )
                }
            }
            Text(
                text = value?.let { formatSatelliteValue(it, decimals) } ?: "-",
                style = NoopType.number(
                    if (value == null) 18f else 21f,
                    weight = FontWeight.Bold,
                ),
                color = if (value == null) {
                    Palette.onDarkSecondary.copy(alpha = 0.64f)
                } else {
                    Color.White
                },
                maxLines = 1,
            )
        }
        Text(
            label.uppercase(Locale.getDefault()),
            style = NoopType.overline,
            color = Palette.onDarkSecondary.copy(alpha = 0.72f),
        )
    }
}

private fun formatSatelliteValue(value: Double, decimals: Int): String =
    if (decimals > 0) String.format(Locale.getDefault(), "%.${decimals}f", value)
    else value.roundToInt().toString()

@Composable
private fun FitnessAgeHeroLane(
    age: Double?,
    profileAge: Int?,
    calibration: String?,
    onClick: (() -> Unit)?,
) {
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = Metrics.space4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(0.dp),
    ) {
        Row(
            modifier = Modifier
                .weight(1f)
                .then(
                    if (onClick != null) {
                        Modifier
                            .liquidPress(interaction)
                            .clickable(
                                interactionSource = interaction,
                                indication = null,
                                onClick = onClick,
                            )
                    } else {
                        Modifier
                    },
                ),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            verticalAlignment = Alignment.Top,
        ) {
            MetricGlyph(
                icon = Icons.AutoMirrored.Filled.DirectionsRun,
                size = 34.dp,
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        uiString(R.string.l10n_health_screen_fitness_age_12383b4a)
                            .uppercase(Locale.getDefault()),
                        style = NoopType.overline.copy(fontSize = 10.sp),
                        color = Palette.onDarkSecondary,
                        maxLines = 1,
                    )
                    Text(
                        stringResource(R.string.appwide_fitness_age_weekly),
                        style = NoopType.overline.copy(fontSize = 8.sp),
                        color = Palette.onDarkSecondary,
                        maxLines = 1,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(Palette.chargeColor.copy(alpha = 0.14f))
                            .padding(horizontal = 6.dp, vertical = 3.dp),
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = age?.let(FitnessAgePresentation::value)
                            ?: uiString(R.string.appwide_cycle_status_learning),
                        style = NoopType.number(18f),
                        color = Palette.onDarkPrimary,
                        maxLines = 1,
                    )
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Palette.onDarkSecondary,
                        modifier = Modifier.size(11.dp),
                    )
                }
                Text(
                    text = if (age != null && profileAge != null) {
                        FitnessAgePresentation.localizedComparison(age, profileAge)
                    } else {
                        calibration ?: uiString(R.string.appwide_fitness_age_needs_rhr_activity)
                    },
                    style = NoopType.footnote,
                    color = Palette.onDarkSecondary.copy(alpha = 0.82f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        val infoShape = RoundedCornerShape(8.dp)
        IconButton(
            onClick = { onClick?.invoke() },
            enabled = onClick != null,
            modifier = Modifier.size(36.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(24.dp)
                    .clip(infoShape)
                    .background(Palette.chargeColor.copy(alpha = 0.12f))
                    .border(1.dp, Palette.chargeColor.copy(alpha = 0.45f), infoShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Info,
                    contentDescription = stringResource(
                        R.string.l10n_health_screen_how_accurate_is_this_fitness_age_935c9a6d,
                    ),
                    tint = Palette.chargeColor,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

// Kept temporarily for screenshot comparison while the v2 hierarchy settles; no production call site.

@Composable
private fun LegacyScoreHeroRow(
    day: DailyMetric?,
    restScore: Double?,
    recoveryCalibration: Int?,
    lastScoredCharge: LastCharge? = null,
    effortScale: EffortScale,
    liveTodayStrain: Double? = null,
    // One card-level provenance label derived from the three REAL per-metric merge winners upstream.
    heroSourceLabel: String? = null,
    onScoreInfo: (ScoreSection) -> Unit,
    // A1 (#514/#706): tapping the Charge ring opens the breakdown sheet. A small chevron cue overlays the
    // ring's bottom edge INSIDE the ring frame, so it adds no stacked height (the #762 self-sizing parity).
    onChargeTap: (() -> Unit)? = null,
) {
    val recovery = day?.recovery
    // Prefer the live in-progress Effort for today, but never BELOW the day's already-earned strain
    // (#489/#506: a live under-read replaced today's real Effort with 0). The effective value drives the
    // gauge number AND the has-data / "No Data" branch, so the ring only reads "No Data" when neither
    // exists. Mirrors the iOS live-Effort gauge. (#402)
    val strain = StrainScorer.effectiveEffort(live = liveTodayStrain, stored = day?.strain)
    // Effort honours the 0–100 / WHOOP-0–21 toggle (#313). The stored strain is on NOOP's 0–100 Effort
    // axis; render it on the user's selected scale so the arc and centre number match the app's Effort.
    val effortOutOf = if (effortScale == EffortScale.WHOOP) 21.0 else 100.0
    val effortVal = strain?.let { UnitFormatter.effortValue(it, effortScale) } ?: 0.0

    // The vessels run LIVE (per-frame slosh + tilt) once the row has any real score to show; a wholly
    // empty/calibrating hero poses them static so a brand-new user's launch churn isn't fighting live
    // canvases (the Android equivalent of the iOS `dataLoaded` gate on HeroScoreCell). LiquidVessel + the
    // count-up both honour Reduce Motion internally, so this is purely a "don't animate an empty hero" cost
    // gate. A carried Charge counts as data (its dimmed vessel should slosh like the Rest one).
    val animated = recovery != null || strain != null || restScore != null || lastScoredCharge != null

    Box(
        modifier = Modifier
            .fillMaxWidth(),
    ) {
        // iOS parity: the hero rings float DIRECTLY on the SCREEN-level day-cycle scene (the scaffold's
        // topBackground), not on any per-hero atmosphere or the old scenic indigo gradient, matching
        // TodayView, which moved the scene to a screen-level SceneScreenBackground and dropped the
        // per-hero scene/ScenicHeroBackground.
        BoxWithConstraints(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Metrics.gap, vertical = Metrics.space16),
        ) {
            // iOS parity (TodayView.scoreHeroRow): three EQUAL rings in CHARGE · EFFORT · REST order, no
            // enlarged centre, filling the width as one balanced row. Ring stroke 0.10 (WHOOP weight).
            val ringGap = 14.dp
            val ring = ((maxWidth - ringGap * 2) / 3.1f).coerceIn(90.dp, 112.dp)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(ringGap, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.Top,
            ) {
                // CHARGE, recovery 0–100, as a liquid VESSEL with the value counting up over it. Honest
                // empty / calibrating overlay; badges its recovery winner.
                HeroRingColumn(
                    domain = DomainTheme.Charge,
                    onInfo = { onScoreInfo(ScoreSection.CHARGE) },
                    onRingTap = onChargeTap,
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        // #802: when today has no Charge yet but a prior night's value is carried, draw a
                        // DIMMED (0.8 opacity) REAL vessel filled to the carried value, matching the Rest
                        // vessel, rather than a bare number on an empty vessel (which read as broken). Same
                        // diameter so the self-sizing hero row is untouched; the dim + the carried "Last
                        // night · <date>" caption mark it as carried, not today's fresh score. Mirrors iOS.
                        val carried = if (recovery == null && recoveryCalibration == null) lastScoredCharge else null
                        if (carried != null) {
                            HeroScoreVessel(
                                modifier = Modifier.alpha(0.8f),
                                fraction = carried.value / 100.0,
                                value = carried.value,
                                tint = Palette.recoveryGaugeColors(carried.value).first,
                                diameter = ring,
                                animated = animated,
                                showsValue = true,
                            )
                        } else {
                            // Calibration is genuine bounded progress toward the minimum baseline window,
                            // not a provisional Recovery score. Fill the vessel to N / required nights while
                            // the overlay below continues to say "Calibrating · N of M" and no score number
                            // is shown.
                            val recoveryProgress = when {
                                recovery != null -> recovery / 100.0
                                recoveryCalibration != null ->
                                    recoveryCalibration.toDouble() / Baselines.minNightsSeed.toDouble()
                                else -> 0.0
                            }.coerceIn(0.0, 1.0)
                            HeroScoreVessel(
                                fraction = recoveryProgress,
                                value = recovery ?: 0.0,
                                tint = recovery?.let { Palette.recoveryGaugeColors(it).first }
                                    ?: Palette.chargeColor,
                                diameter = ring,
                                animated = animated,
                                showsValue = recovery != null,
                            )
                            // Empty vessel + calibrating / no-data overlay (the carried case is above).
                            if (recovery == null) RingEmptyOverlay(recoveryCalibration, diameter = ring)
                        }
                        // No in-vessel tap cue: the single tap affordance is the CHARGE-label chevron below
                        // the vessel (HeroRingColumn), matching iOS where the in-ring cue was removed.
                    }
                }
                // EFFORT, strain on the gauge, on the user's selected scale, as a liquid vessel.
                HeroRingColumn(domain = DomainTheme.Effort, onInfo = { onScoreInfo(ScoreSection.EFFORT) }) {
                    Box(contentAlignment = Alignment.Center) {
                        HeroScoreVessel(
                            fraction = if (effortOutOf > 0) effortVal / effortOutOf else 0.0,
                            value = effortVal,
                            tint = Palette.effortTint((strain ?: 0.0) / 100.0),
                            diameter = ring,
                            animated = animated,
                            showsValue = strain != null,
                            format = { if (effortScale == EffortScale.WHOOP) String.format(Locale.US, "%.1f", it) else it.toInt().toString() },
                        )
                        if (strain == null) RingNoData()
                    }
                }
                // REST, sleep composite 0–100. Its fixed-width box also anchors the card-level source badge:
                // the badge may grow leftward, but its trailing edge always matches the Rest vessel.
                Box(modifier = Modifier.width(ring)) {
                    HeroRingColumn(
                        domain = DomainTheme.Rest,
                        onInfo = { onScoreInfo(ScoreSection.REST) },
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            HeroScoreVessel(
                                fraction = (restScore ?: 0.0) / 100.0,
                                value = restScore ?: 0.0,
                                tint = Palette.recoveryColor(restScore ?: 0.0),
                                diameter = ring,
                                animated = animated,
                                showsValue = restScore != null,
                            )
                            // #898: an aggregate-import user (a daily HRV/RHR import, no in-bed session) gets a
                            // Charge from WatchRecovery but NO sleep_performance, so Rest used to read a bare
                            // "No Data" next to a lit Charge , reading as broken. When a Charge IS present for the
                            // day but Rest is absent, say WHY honestly ("Needs a tracked night") instead. We do
                            // NOT fabricate a Rest number , an aggregate genuinely has no scored night. A day with
                            // no Charge either (truly empty) keeps the plain "No Data". Mirrors iOS restRing.
                            if (restScore == null) {
                                if (recovery != null) RingNeedsTrackedNight() else RingNoData()
                            }
                        }
                    }
                    if (heroSourceLabel != null) {
                        SourceBadge(
                            text = heroSourceLabel,
                            tint = Palette.onDarkSecondary,
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                // Measure the full label even when it is wider than the Rest vessel, then
                                // let it overflow left while preserving the vessel-aligned trailing edge.
                                .wrapContentWidth(unbounded = true, align = Alignment.End)
                                // #486: the vessel row starts one space16 inside the card, so lifting by
                                // exactly space16 puts the badge's TOP on the card's top edge — it tucks
                                // into the top-right corner and hangs into the gap above the vessels. The
                                // previous "+ half the badge height" centred it ON the border, where it read
                                // as a pill floating detached above the card (two users flagged it).
                                .offset(y = -Metrics.space16)
                                .semantics { contentDescription = uiString(R.string.l10n_today_screen_source_herosourcelabel_d3363687, heroSourceLabel) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * One hero ring column: the ring, with a tappable UPPERCASE domain label + chevron beneath it (the
 * WHOOP affordance) that opens the matching scoring-guide section. Provenance belongs to the whole hero
 * card and is rendered once by [ScoreHeroRow], so this column only owns score content and navigation.
 */
@Composable
private fun HeroRingColumn(
    domain: DomainTheme,
    onInfo: () -> Unit,
    // A1: when non-null (Charge), the ring is tappable and opens the breakdown sheet. The chevron cue is
    // overlaid by the caller INSIDE the ring box so it adds no stacked height (#762 self-sizing parity).
    onRingTap: (() -> Unit)? = null,
    ring: @Composable () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (onRingTap != null) {
            // liquidPress on the tappable Charge vessel so it settles inward on press (the vessel itself
            // also splashes via LiquidVessel's own tap). Same interactionSource on the clickable + press.
            val ringInteraction = remember { MutableInteractionSource() }
            Box(
                modifier = Modifier
                    .liquidPress(ringInteraction)
                    .clip(CircleShape)
                    .clickable(
                        interactionSource = ringInteraction,
                        indication = null,
                        onClickLabel = "See what shaped your ${domain.label}",
                        onClick = onRingTap,
                    ),
            ) { ring() }
        } else {
            ring()
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .clickable { onInfo() }
                .padding(horizontal = 6.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // #937 parity: an invisible LEADING twin of the trailing chevron. The word + chevron used to
            // centre as ONE block, which sat the word visibly off the ring's axis (worst on short labels
            // like REST). Balancing the row with a same-sized alpha-0 chevron re-centres the WORD itself
            // under the ring while the real chevron stays on the trailing side. alpha(0f) keeps its layout
            // slot, the clickable Row (the tap target) only ever grows, and the Row stays plain
            // start-to-end content, no offset maths, so RTL mirrors identically (the icon is AutoMirrored
            // anyway). Null description keeps it out of TalkBack: it is a spacer, not content.
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = Palette.onDarkSecondary.copy(alpha = 0.68f),
                modifier = Modifier
                    .size(14.dp)
                    .alpha(0f),
            )
            // #74: never wrap the hero label onto a second line — at a larger font/screen-zoom (Samsung
            // One UI defaults) "REST" could wrap, growing the whole hero card. One line, ellipsis if forced.
            Text(domain.label.uppercase(), style = NoopType.overline, color = Palette.onDarkSecondary,
                 maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = uiString(R.string.l10n_today_screen_how_domain_label_is_calculated_8897768c, domain.label),
                tint = Palette.onDarkSecondary.copy(alpha = 0.68f),
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/**
 * One hero score as a liquid VESSEL with the value counting up over it — the signature liquid Today hero
 * element. A [LiquidVessel] (Compose primitive, LiquidPrimitives.kt) fills to [fraction] (0..1) in the
 * domain [tint], sized to [diameter]; over it a [CountUpText] rolls the number up to [value] (white,
 * tabular, a soft shadow so it reads on the vessel), matching the iOS `HeroScoreCell` (a count-up number
 * over a filling vessel). The number is hit-transparent (clearAndSetSemantics + no clickable) so a tap
 * falls THROUGH to the vessel — LiquidVessel owns its own tap→splash+haptic; the enclosing HeroRingColumn
 * adds the Charge breakdown tap. When [showsValue] is false (no score yet) the vessel draws empty and the
 * caller overlays the calibrating / No-Data text, so the number is simply omitted here.
 *
 * The number size tracks the diameter (≈ 0.27×, capped) so the three equal vessels stay balanced; it
 * mirrors the iOS 96dp-vessel → 26pt-number ratio. Values/bindings are UNCHANGED from the GlowRing this
 * replaced — same fraction, same value, same value-sampled tint.
 */
@Composable
private fun HeroScoreVessel(
    fraction: Double,
    value: Double,
    tint: Color,
    diameter: Dp,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
    showsValue: Boolean = true,
    format: (Double) -> String = { it.roundToInt().toString() },
) {
    Box(modifier = modifier.size(diameter), contentAlignment = Alignment.Center) {
        LiquidVessel(
            value = fraction.coerceIn(0.0, 1.0),
            tint = tint,
            animated = animated,
            modifier = Modifier.size(diameter),
        )
        if (showsValue) {
            // Count-up number over the vessel — white, tabular, a soft shadow for legibility, hit-transparent
            // so the tap reaches the vessel (splash). Size ≈ diameter × 0.27 (iOS 96→26 ratio), capped.
            val numberSp = (diameter.value * 0.27f).coerceIn(20f, 30f)
            CountUpText(
                value = value,
                format = format,
                style = NoopType.number(numberSp, weight = FontWeight.Bold)
                    .copy(shadow = Shadow(color = Color.Black.copy(alpha = 0.5f), offset = Offset(0f, 1f), blurRadius = 6f)),
                color = Color.White,
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
    }
}

/**
 * The plain-English Synthesis card, the Charge-tinted [InsightCard] read-out under the ring hero, with a
 * WHITE headline (the key iOS Design-Reset change, `statusColor: textPrimary`, not the recovery/charge
 * colour), carrying the greeting + the SOLID / CALIBRATING data-confidence pill in its top-right. Mirrors
 * the iOS Synthesis InsightCard (which moved here when the big RecoveryRing hero that owned the pill went).
 */
@Composable
private fun SynthesisHeroCard(
    day: DailyMetric?,
    recoveryCalibration: Int?,
    carriedDay: DailyMetric? = null,
    // S4: the day history (for the one-word readiness read), whether the Synthesis card is expanded, and the
    // taps to toggle it / open the Charge breakdown (where the full Readiness card lives). Defaults keep old
    // call sites compiling; the Today call site supplies them.
    days: List<DailyMetric> = emptyList(),
    displayName: String = ProfileStore.DEFAULT_DISPLAY_NAME,
    synthesisExpanded: Boolean = true,
    onToggleSynthesis: () -> Unit = {},
    onOpenReadiness: () -> Unit = {},
) {
    // The row the synthesis reads from: today's own when it carries recovery, else the carried-over last
    // scored day (#543) so the card mirrors the carried Charge ring instead of blanking to "No Data". When
    // carrying, the detail line gets a "Last night · <date>" provenance so the prior read isn't passed off
    // as today's. today's own read wins the instant tonight is scored.
    val readDay = carriedDay ?: day
    val recovery = readDay?.recovery
    val seedComplete = recoveryCalibration != null &&
        recoveryCalibration >= Baselines.minNightsSeed
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // The greeting + SOLID/CALIBRATING data-confidence pill ride in their OWN header row ABOVE the
        // card, not as a top-end overlay over it (#527). The old overlay sat over the card's "SYNTHESIS"
        // overline + big status word and, on a narrow phone, collided with them, and squeezing the
        // status into the leftover width force-broke a single word ("Calibrating" → "Calibrati/ng").
        // A separate row CAN'T overlap, and the card keeps its FULL width so the status stays one line.
        // Mirrors the iOS Synthesis header-row layout (TodayView heroSection).
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The greeting yields/ellipsises first; the pill keeps its full width (#527).
            Text(
                uiString(R.string.appwide_today_greeting_format, greetingWord(), displayName),
                style = NoopType.subhead,
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.weight(1f))
            // S4 (#205): the one-word readiness read kept on the hero now the full Readiness card folded
            // into the Charge-ring tap. Aligned / Within range / Recheck / Multiple shifts; hidden when
            // there isn't enough history.
            // Tapping it opens the Charge breakdown, where the full Readiness card now lives.
            val readinessLevel = remember(days) {
                if (days.isEmpty()) ReadinessEngine.Level.INSUFFICIENT
                else ReadinessEngine.evaluate(days, today = logicalDayKeyNow()).level
            }
            readinessWord(readinessLevel)?.let { word ->
                ReadinessHeroPill(word = word, level = readinessLevel, onTap = onOpenReadiness)
            }
            // SOLID only when TODAY's own row carries a settled recovery, a carried prior-day read is
            // honestly still CALIBRATING for today, matching the iOS pill (keyed on displayDay.recovery).
            val todayRecovery = day?.recovery
            StatePill(
                title = when {
                    todayRecovery != null -> "SOLID"
                    seedComplete -> ScoreState.BaselineReady.title.uppercase()
                    else -> "CALIBRATING"
                },
                tone = if (todayRecovery != null) StrandTone.Accent else StrandTone.Neutral,
            )
        }
        // S4: the Synthesis card collapses to a one-liner that expands on tap. The headline (the status) is
        // the SAME in both states, only the detail body and chrome fold, never the read (#506).
        val status = when {
            seedComplete -> ScoreState.BaselineReady.title
            recoveryCalibration != null -> "Calibrating"
            else -> synthesisWord(recovery)
        }
        val detail = if (recoveryCalibration != null) {
            if (seedComplete) {
                ScoreState.BaselineReady.detail
            } else {
                // #612: if the baseline aged out silently, say why rather than only "learning".
                val stale = Baselines.nightsSinceNewestValidNight(
                    days.map { it.day },
                    days.map { it.avgHrv },
                    logicalDayKeyNow(),
                )
                if (stale != null && stale > Baselines.staleDays) {
                    uiString(R.string.l10n_today_screen_no_new_nights_from_your_strap_for_stale_days_8863bcfe, stale)
                } else {
                    "Learning your baseline, $recoveryCalibration of " +
                        "${Baselines.minNightsSeed} valid HRV nights."
                }
            }
        } else if (carriedDay != null) {
            // Carried prior-day read, summarise that day + stamp it so it isn't passed off as today's.
            synthesisDetail(carriedDay) + " ${carriedCaption(carriedDay.day)}."
        } else {
            synthesisDetail(day)
        }
        if (synthesisExpanded) {
            val expandedInteraction = remember { MutableInteractionSource() }
            Box(
                modifier = Modifier
                    .liquidPress(expandedInteraction)
                    .clickable(
                        interactionSource = expandedInteraction,
                        indication = null,
                        onClickLabel = "Collapse",
                        onClick = onToggleSynthesis,
                    ),
            ) {
                InsightCard(
                    modifier = Modifier.fillMaxWidth(),
                    category = "Synthesis",
                    status = status,
                    detail = detail,
                    // The SYNTHESIS headline reads WHITE (textPrimary), not the recovery/charge colour, the
                    // key iOS Design-Reset change (TodayView.synthesisSection passes statusColor textPrimary).
                    statusColor = Palette.textPrimary,
                    // FLAT card to match iOS (no navy-bevel gradient / border): identity comes from the white
                    // headline alone. tint = null routes to the neutral FLAT surfaceRaised + hairline path.
                    tint = null,
                )
            }
        } else {
            // Collapsed: a one-liner with the SYNTHESIS overline, the status headline and a down-chevron.
            val collapsedInteraction = remember { MutableInteractionSource() }
            NoopCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidPress(collapsedInteraction)
                    .clickable(
                        interactionSource = collapsedInteraction,
                        indication = null,
                        onClickLabel = "Expand for the full read",
                        onClick = onToggleSynthesis,
                    ),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_today_screen_synthesis_876bc749), style = NoopType.overline, color = Palette.textTertiary)
                        Text(
                            status,
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Icon(
                        Icons.Filled.KeyboardArrowDown,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

/**
 * S4 (#205): the one-word readiness pill on the hero (Push / Maintain / Rest). A small tinted capsule
 * matching the score-pill chrome, coloured by the readiness level; tapping opens the Charge breakdown sheet
 * where the full Readiness card lives. Mirrors the iOS readinessHeroPill.
 */
@Composable
private fun ReadinessHeroPill(word: String, level: ReadinessEngine.Level, onTap: () -> Unit) {
    val tone = readinessColor(level)
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tone.copy(alpha = 0.12f))
            .border(1.dp, tone.copy(alpha = 0.32f), RoundedCornerShape(50))
            .clickable(onClickLabel = "See your full readiness", onClick = onTap)
            .padding(horizontal = 10.dp, vertical = 5.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_readiness_word_749b3330, word) },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(word.uppercase(), style = NoopType.overline, color = tone)
    }
}

/** Honest overlay shown over the Charge ring when today's recovery is null: either the calibrating count
 *  or No data. The carried last-scored Charge case is NOT handled here anymore: it's intercepted earlier
 *  and drawn as a dimmed FILLED ring in the carried branch (matching iOS chargeRing), so this overlay only
 *  covers the calibrating and no-data cases. Mirrors iOS TodayView.ringEmptyOverlay. */
@Composable
private fun RingEmptyOverlay(
    calibratingNights: Int?,
    diameter: Dp,
) {
    if (calibratingNights != null) {
        val seedComplete = calibratingNights >= Baselines.minNightsSeed
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                if (seedComplete) ScoreState.BaselineReady.title
                else uiString(R.string.l10n_today_screen_calibrating_37c2c9bd),
                style = NoopType.headline,
                color = Palette.textTertiary,
                maxLines = if (seedComplete) 2 else 1,
                textAlign = TextAlign.Center,
            )
            Text(
                uiString(
                    R.string.today_calibration_valid_hrv_progress,
                    calibratingNights,
                    Baselines.minNightsSeed,
                ),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 1,
            )
        }
    } else {
        RingNoData()
    }
}

@Composable
private fun RingNoData() {
    Text(NO_DATA, style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
}

/** #898: the Rest ring's overlay when a Charge exists for the day but there's no scored sleep (the
 *  aggregate-import case , a daily HRV/RHR import carries no in-bed session). Says WHY Rest is blank
 *  instead of a bare "No Data", without fabricating a number. Mirrors iOS restRing's needs-a-night branch. */
@Composable
private fun RingNeedsTrackedNight() {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(uiString(R.string.l10n_today_screen_calibrating_37c2c9bd), style = NoopType.headline, color = Palette.textTertiary, maxLines = 1)
        Text(
            uiString(R.string.l10n_today_screen_needs_a_tracked_night_ccfd532a),
            style = NoopType.footnote,
            color = Palette.textSecondary,
            maxLines = 1,
        )
    }
}

// MARK: - Hero vitals metric rows, HRV / Resting HR / Respiratory, re-homed below the ring hero
//
// The WHOOP-style redesign (#23) dropped the big gold RecoveryRing hero that used to carry these; the
// three vitals now read directly below the three-ring hero + Synthesis card. [HeroMetricRows] is the
// README "Metric row" card; the SOLID/CALIBRATING pill + Synthesis insight moved into [SynthesisHeroCard].

/** The three hero vitals as README metric rows, HRV (teal) · Resting HR (rose) · Respiratory (blue).
 *  Reads PER-FIELD today-first with a recovery-INDEPENDENT vitals carry ([vitalsDay]) as the fallback
 *  (#543 follow-up), so a night whose recovery was nulled post-update still shows its OWN preserved HRV /
 *  RHR / respiratory rather than an older recovery-scored day's numbers (or "No Data"). This aligns the
 *  card to the Key-Metrics tiles, which already read per-field. Each row still falls through to "No Data"
 *  for a vital neither today nor the carry supplies. */
@Composable
private fun HeroMetricRows(day: DailyMetric?, carriedDay: DailyMetric? = null, vitalsDay: DailyMetric? = null) {
    // Per-field, today-first: today's own value wins; the vitals carry only fills a field today lacks.
    val hrv = day?.avgHrv ?: vitalsDay?.avgHrv
    val rhr = day?.restingHr ?: vitalsDay?.restingHr
    val resp = day?.respRateBpm ?: vitalsDay?.respRateBpm
    // The caption reflects the row the shown vitals actually came from: if today supplied ANY of them the
    // values are today's own, so don't stamp them as a prior "Last night · <date>"; only when EVERY shown
    // vital is carried do we stamp the carry's date (relabelled "Latest sleep · <date>" when weeks-old).
    val carriedFromVitals = day?.avgHrv == null && day?.restingHr == null && day?.respRateBpm == null &&
        (hrv != null || rhr != null || resp != null) && vitalsDay != null
    // iOS `recoveryVitalsSection`: a frosted card with a "RECOVERY VITALS" header + a "last night · <date>"
    // on the right, then three `vitalRow`s (dimensional MetricGlyph + label + value).
    NoopCard(padding = Metrics.space16) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline("Recovery vitals", modifier = Modifier.weight(1f))
                // iOS `lastNightLine` - today's own "Last night · <date>" unless the shown vitals are a carry.
                Text(
                    if (carriedFromVitals) carriedCaption(vitalsDay!!.day) else heroVitalsLastNightLine(),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_heart_rate_variability_a137586d),
                value = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                icon = Icons.Filled.MonitorHeart,
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_resting_heart_rate_348928d6),
                value = rhr?.let { "$it bpm" } ?: NO_DATA,
                icon = Icons.Filled.Favorite,
            )
            HeroVitalRow(
                label = uiString(R.string.l10n_today_screen_breaths_per_minute_2b197c54),
                value = resp?.let { String.format(Locale.US, "%.1f rpm", it) } ?: NO_DATA,
                icon = Icons.Filled.Air,
            )
        }
    }
}

/** iOS `lastNightLine` - "Last night · <date>" where <date> is yesterday in "d MMM" form. */
private fun heroVitalsLastNightLine(): String {
    val d = LocalDate.now().minusDays(1)
    return "Last night · ${d.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))}"
}

/** One iOS `vitalRow`: a 28dp dimensional metric glyph, label, and tabular value. */
@Composable
private fun HeroVitalRow(label: String, value: String, icon: ImageVector) {
    val hasValue = value != NO_DATA
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_label_value_b781d590, label, value) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        MetricGlyph(icon = icon, size = 28.dp)
        Text(label, style = NoopType.subhead, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(
            value,
            style = NoopType.number(15f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
        )
    }
}

// MARK: - "Your cards" dashboard (WHOOP "My Dashboard"), iOS yourCardsSection parity
//
// A persisted, reorderable selection of metric cards surfaced on Today as flat WHOOP metric ROWS. The
// section header carries the "Your cards" overline + a right-aligned BLUE "CUSTOMISE" text action; each row
// is a leading tinted icon tile + UPPERCASE tracked label over a grey baseline caption on the left, and the
// big white value + small unit + chevron on the right. A card with no value yet renders a dash rather than
// vanishing. Mirrors iOS TodayView.yourCardsSection / pinnedCardRow / dashboardValue / dashboardTint.

/** Shared Today section edit affordance. The 48dp box keeps the whole control easy to tap while its
 *  visible content stays pinned to the overline instead of centring against a two-line header. */
@Composable
private fun TodayEditAction(
    contentDescription: String,
    onClick: () -> Unit,
    contentAlignment: Alignment = Alignment.Center,
) {
    Box(
        modifier = Modifier
            .height(48.dp)
            .clickable(onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = Metrics.space12),
    ) {
        Row(
            modifier = Modifier.align(contentAlignment),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.Tune,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(Metrics.space4))
            Text(
                uiString(R.string.l10n_today_screen_edit_5301648d).uppercase(Locale.getDefault()),
                style = NoopType.overline.copy(letterSpacing = 0.sp),
                color = Palette.accent,
            )
        }
    }
}

@Composable
private fun YourCardsSection(
    cards: List<DashboardCard>,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
    onOpenHydration: () -> Unit,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenCoupled: () -> Unit,
    onCustomise: () -> Unit,
) {
    Box(modifier = Modifier.fillMaxWidth().staggeredAppear(2)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: "YOUR CARDS" overline + a right-aligned blue EDIT action (the WHOOP ✎ affordance).
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline("Your cards", modifier = Modifier.weight(1f))
                TodayEditAction(
                    onClick = onCustomise,
                    contentDescription = uiString(R.string.l10n_today_screen_customise_your_cards_2428d761),
                )
            }
            cards.forEach { card ->
                DashboardCardRow(
                    card = card,
                    value = dashboardCardValue(
                        card = card,
                        day = day,
                        carriedDay = carriedDay,
                        vitalsDay = vitalsDay,
                        spo2Day = spo2Day,
                        skinTempDay = skinTempDay,
                        stress = stress,
                        fitnessAge = fitnessAge,
                        vitality = vitality,
                        importedStepsForDay = importedStepsForDay,
                        estimatedStepsForDay = estimatedStepsForDay,
                        caloriesForDay = caloriesForDay,
                        hydrationTotalMl = hydrationTotalMl,
                        hydrationGoalMl = hydrationGoalMl,
                    ),
                    tint = dashboardCardTint(card),
                    // #110: label the sleep row with its source + night (this section renders at offset 0
                    // only, so it IS last night), so a WHOOP-imported figure is never silently shown as
                    // "last night" with no provenance. iOS TodayView.sleepSourceSubtitle twin.
                    subtitleOverride = when (card) {
                        DashboardCard.SLEEP -> sleepSourceSubtitle(card, day)
                        DashboardCard.STEPS -> stepsSourceCaption(
                            motionDerived = day?.steps,
                            imported = importedStepsForDay,
                            calibratedEstimate = estimatedStepsForDay,
                        )
                        else -> null
                    },
                    // #706/#684: every card now opens its OWN detail, matching iOS. The Stress card -> Stress;
                    // the overnight vitals (HRV / Resting HR / Respiratory / SpO₂ / Skin Temp) + Fitness age /
                    // Vitality / Steps / Calories -> each metric's focused trend (vital_detail/<key>, the iOS
                    // metricDetail twin); Sleep -> Sleep; Hydration -> Hydration. Whole row is the button.
                    onClick = dashboardCardDestination(
                        card = card,
                        onOpenStress = onOpenStress,
                        onOpenMetric = onOpenMetric,
                        onOpenSleep = onOpenSleep,
                        onOpenHydration = onOpenHydration,
                        onOpenCoupled = onOpenCoupled,
                    ),
                )
            }
        }
    }
}

/** #110: the sleep row's value is `totalSleepMin` — WHOOP's imported TST, which can legitimately differ
 *  from the Sleep tab's on-device re-staged night (WHOOP CSV + Apple Health both imported). Label the row
 *  with its source (the SAME `daySourceBadge` winner the Sleep tab's `MainSleepFooter` uses) + "last
 *  night" - `YourCardsSection` renders at offset 0 only, so the row IS last night - so a WHOOP figure is
 *  never silently shown as "last night" with no provenance. null → the card keeps its static subtitle
 *  (not the sleep card, or no banked sleep). Twin of iOS `TodayView.sleepSourceSubtitle`; the source
 *  mechanism differs per platform (Android keys on the day's session source, iOS on `importedSleep`),
 *  exactly as the two Sleep-tab badges already do, so the label — not the wiring — is what stays in parity. */
private fun sleepSourceSubtitle(card: DashboardCard, day: DailyMetric?): String? {
    if (card != DashboardCard.SLEEP) return null
    val d = day ?: return null
    if (d.totalSleepMin == null) return null
    val source = daySourceBadge(d.deviceId).first
    return "$source · last night"
}

/** The `vital_detail/<key>` key a metric/vital card opens, or null when the card has its OWN dedicated
 *  screen (Stress / Sleep / Hydration / Coupled) rather than a metric-detail trend. Mirrors the iOS
 *  `liquidCard` switch, where every metric/vital card opens `metricDetail(key)` (its own focused trend),
 *  NOT the shared Health hub (2026-07-03). Keys are the Android VitalDetailScreen keys. */
private fun dashboardCardMetricKey(card: DashboardCard): String? = when (card) {
    DashboardCard.HRV -> "hrv"
    DashboardCard.RESTING_HR -> "rhr"
    DashboardCard.RESPIRATORY -> "resp"
    DashboardCard.BLOOD_OXYGEN -> "spo2"
    DashboardCard.SKIN_TEMP -> "skin"
    DashboardCard.FITNESS_AGE -> "fitness_age"
    DashboardCard.VITALITY -> "vitality"
    DashboardCard.STEPS -> "steps_est"
    DashboardCard.CALORIES -> "active_kcal"
    // These carry their own full screen, not a per-metric trend.
    DashboardCard.STRESS, DashboardCard.SLEEP, DashboardCard.HYDRATION, DashboardCard.COUPLED -> null
}

/** The destination callback a dashboard card opens when tapped. Mirrors the iOS dashboardCardRow switch:
 *  Stress -> Stress; Sleep -> Sleep; Hydration -> Hydration; Coupled -> the WHOOP-style day screen; every
 *  metric/vital card -> its OWN focused trend (`vital_detail/<key>` via [onOpenMetric]), matching the iOS
 *  `metricDetail(key)`. Every card resolves to a destination, so the chevron is always honest (#706/#684). */
private fun dashboardCardDestination(
    card: DashboardCard,
    onOpenStress: () -> Unit,
    onOpenMetric: (String) -> Unit,
    onOpenSleep: () -> Unit,
    onOpenHydration: () -> Unit,
    onOpenCoupled: () -> Unit,
): () -> Unit = when (card) {
    DashboardCard.STRESS -> onOpenStress
    DashboardCard.SLEEP -> onOpenSleep
    DashboardCard.HYDRATION -> onOpenHydration
    // The Coupled view card (#43) taps through to the full WHOOP-style day screen.
    DashboardCard.COUPLED -> onOpenCoupled
    // Every overnight vital + Fitness age / Vitality / Steps / Calories opens its own metric-detail trend.
    else -> {
        val key = dashboardCardMetricKey(card)
        if (key != null) ({ onOpenMetric(key) }) else ({})
    }
}

/** A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals take
 *  their biometric hue; everything else the blue accent. No gold (WHOOP), tokens only. Mirrors iOS
 *  dashboardTint. This drives the card's restrained wash, so it follows the iOS `liquidCard`
 *  per-card tints: Stress=accent, Fitness age=charge-green, Vitality=liquid-purple, HRV=cyan,
 *  Resting HR=rose, Respiratory=accent, Steps=cyan, Sleep=rest, Coupled=charge. */
private fun dashboardCardTint(card: DashboardCard): Color = when (card) {
    // iOS `liquidCard`: stress → StrandPalette.accent (blue), not the Effort orange.
    DashboardCard.STRESS -> Palette.accent
    DashboardCard.FITNESS_AGE -> Palette.chargeColor
    // iOS vitality → liquidPurple (#9b7bff).
    DashboardCard.VITALITY -> LIQUID_PURPLE
    // iOS hrv → metricCyan (this theme's metricPurple is a blue, cyan reads as the iOS HRV teal).
    DashboardCard.HRV -> Palette.metricCyan
    DashboardCard.RESTING_HR -> Palette.metricRose
    DashboardCard.RESPIRATORY -> Palette.accent
    DashboardCard.BLOOD_OXYGEN -> Palette.metricCyan
    DashboardCard.SKIN_TEMP -> Palette.metricAmber
    DashboardCard.SLEEP -> Palette.restColor
    DashboardCard.STEPS -> Palette.metricCyan
    DashboardCard.CALORIES -> Palette.metricAmber
    DashboardCard.HYDRATION -> Palette.metricCyan
    DashboardCard.COUPLED -> Palette.chargeColor
}

/**
 * Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
 * suffix appended. Returns a dash when the value isn't available yet, never a fabricated number. Reuses
 * the SAME reads the rest of Today uses (displayMetric vitals, the pinned Stress / Fitness age / Vitality,
 * steps, calories, sleep duration). Mirrors iOS dashboardValue.
 *
 * The three overnight vitals (HRV / Resting HR / Respiratory) read PER-FIELD today-first with the
 * recovery-INDEPENDENT [vitalsDay] carry (#543 follow-up), so a night whose recovery was nulled post-update
 * still shows its OWN preserved value rather than an older recovery-scored day's (the tile-vs-card fix).
 * SpO₂ / Skin Temp / Sleep keep the recovery-gated `carriedDay ?: day` carry. Steps / Calories stay on
 * today's own row (they accrue through the day, never a carry). Stress / Fitness age / Vitality come from
 * their own resolved loads.
 */
private fun dashboardCardValue(
    card: DashboardCard,
    day: DailyMetric?,
    carriedDay: DailyMetric?,
    vitalsDay: DailyMetric?,
    spo2Day: DailyMetric?,
    skinTempDay: DailyMetric?,
    stress: Double?,
    fitnessAge: Double?,
    vitality: Double?,
    importedStepsForDay: Int?,
    estimatedStepsForDay: Int?,
    caloriesForDay: Double?,
    hydrationTotalMl: Double,
    hydrationGoalMl: Int,
): String {
    fun withUnit(s: String): String =
        if (s == NO_DATA) NO_DATA else if (card.unit.isEmpty()) s else "$s ${card.unit}"

    // SpO₂ / Skin Temp / Sleep carry over from the last scored night; today's accruing totals do not.
    val vd = carriedDay ?: day

    return when (card) {
        DashboardCard.HRV ->
            withUnit((day?.avgHrv ?: vitalsDay?.avgHrv)?.let { it.roundToInt().toString() } ?: NO_DATA)
        DashboardCard.RESTING_HR ->
            withUnit((day?.restingHr ?: vitalsDay?.restingHr)?.toString() ?: NO_DATA)
        DashboardCard.RESPIRATORY ->
            withUnit((day?.respRateBpm ?: vitalsDay?.respRateBpm)?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA)
        DashboardCard.BLOOD_OXYGEN ->
            // PER-FIELD carry: the whole-row carries (vd) land on rows whose spo2Pct is null (the engine
            // writes spo2Pct = null on computed rows), so fall through to the last row that HAS one.
            (vd?.spo2Pct ?: spo2Day?.spo2Pct)?.let { String.format(Locale.US, "%.0f%%", it) } ?: NO_DATA
        DashboardCard.SKIN_TEMP ->
            // The overloaded field is either a signed local deviation or an absolute WHOOP import.
            // Prefix only the deviation; "+34°" would falsely claim a 34-degree change.
            (vd?.skinTempDevC ?: skinTempDay?.skinTempDevC)?.let {
                if (VitalBands.isAbsoluteSkinTemp(it)) {
                    String.format(Locale.US, "%.1f°", it)
                } else {
                    String.format(Locale.US, "%+.1f°", it)
                }
            } ?: NO_DATA
        DashboardCard.SLEEP -> sleepValue(vd)
        DashboardCard.STEPS -> {
            val real = importedStepsForDay?.let { intStringGrouped(it.toDouble()) }
                ?: day?.steps?.let { intStringGrouped(it.toDouble()) }
            val est = estimatedStepsForDay?.let { intStringGrouped(it.toDouble()) }
            real ?: est ?: NO_DATA
        }
        DashboardCard.CALORIES ->
            withUnit(caloriesForDay?.let { intStringGrouped(it) } ?: NO_DATA)
        DashboardCard.STRESS ->
            // #706/#684: Stress is baseline-relative, so until the strap has banked enough worn nights to
            // seed the 30-day RHR/HRV baseline StressScreen reads, the front card has no number to show. The
            // old `?: NO_DATA` rendered a bare dash that read like a broken card; show the honest calibrating
            // state instead, matching the owner's reply on #706 and the StressScreen empty/calibrating copy.
            stress?.let { it.roundToInt().toString() } ?: STRESS_CALIBRATING
        DashboardCard.FITNESS_AGE ->
            fitnessAge?.let(FitnessAgePresentation::value) ?: NO_DATA
        DashboardCard.VITALITY ->
            vitality?.let { it.roundToInt().toString() } ?: NO_DATA
        DashboardCard.HYDRATION ->
            // "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L". Always shows a value (a fresh
            // day reads "0.0 / 3.2 L"), since the goal is always derivable from the profile.
            String.format(
                Locale.US, "%.1f / %.1f L",
                hydrationTotalMl / 1000.0, hydrationGoalMl / 1000.0,
            )
        DashboardCard.COUPLED ->
            // A tap-through row with no metric value of its own, the row shows just the chevron. An empty
            // string (not NO_DATA) renders no number and leaves it un-dimmed. Mirrors iOS dashboardValue.
            ""
    }
}

/**
 * One WHOOP "My Dashboard" metric row: a thin-line tinted icon tile, an UPPERCASE tracked label over a grey
 * baseline caption, the big white value + small unit, and a chevron, on the flat frosted card surface (no
 * glow), tokens only. Mirrors iOS pinnedCardRow. The whole row is the tap target: when [onClick] is set it
 * pushes that card's detail (the chevron is the hint), matching iOS (#706/#684).
 */
@Composable
private fun DashboardCardRow(
    card: DashboardCard,
    value: String,
    tint: Color,
    // #110: a per-card dynamic subtitle (currently the sleep row's source + night); null keeps the
    // card's static description.
    subtitleOverride: String? = null,
    onClick: (() -> Unit)? = null,
) {
    // A real number renders white; a placeholder (No Data, or the Stress calibrating state) renders dimmed.
    val hasValue = value != NO_DATA && value != STRESS_CALIBRATING
    val rowShape = RoundedCornerShape(Metrics.cardRadius)
    // liquidPress: the tappable card settles inward on press (the iOS LiquidPressStyle feel). The SAME
    // interactionSource feeds the clickable and the press modifier, so it responds to the actual touch.
    // It is applied OUTSIDE the frosted surface so the whole card (surface + content) scales/dims as one.
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onClick != null) it.liquidPress(interaction) else it }
            .clip(rowShape)
            .frostedCardSurface(
                tint = tint,
                cornerRadius = Metrics.cardRadius,
                washStrength = 0.60f,
            )
            .let {
                if (onClick != null) {
                    it.clickable(interactionSource = interaction, indication = null, onClick = onClick)
                } else it
            }
            // iOS row padding: 14h / 11v (tighter than the old 13/11 icon-box row).
            .padding(horizontal = 14.dp, vertical = 11.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_card_title_value_e4bb76b3, card.title, value) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        MetricGlyph(icon = card.icon, size = 32.dp)
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            // iOS: overline 11 / +1.0 tracking, textPrimary.
            Text(
                card.title.uppercase(),
                style = NoopType.overline.copy(fontSize = 11.sp, letterSpacing = 0.sp),
                color = Palette.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitleOverride ?: card.subtitle,
                style = NoopType.caption,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        // iOS value = number(17), textPrimary.
        Text(
            value,
            style = NoopType.number(17f),
            color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
            maxLines = 1,
        )
        // iOS chevron = 12.
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(12.dp),
        )
    }
}

/** #760/#792: the caption under an ESTIMATED Steps tile: "est. · <status detail>", where the detail is the
 *  engine's own STATUS line (manual k, or k=… from N days + confidence tier) built from the SAME persisted
 *  calibration the estimate used. So a WHOOP 4.0 user can see WHY the number reads as it does (and why it may
 *  look frozen at low confidence) right where they notice the "est." flag. Falls back to a bare "est." when no
 *  coefficient is recorded yet. Mirrors iOS `stepsEstimateCaption`. */
private fun stepsEstimateCaption(profileStore: ProfileStore): String {
    if (profileStore.stepsCalibrationCoefficient <= 0.0) return "est."
    val status: StepsEstimateEngine.CalibrationStatus = if (profileStore.stepsCalibrationManual) {
        StepsEstimateEngine.CalibrationStatus.Manual(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
        )
    } else {
        StepsEstimateEngine.CalibrationStatus.Calibrated(
            coefficient = profileStore.stepsCalibrationCoefficient,
            sampleDays = profileStore.stepsCalibrationSampleDays,
            confidence = profileStore.stepsCalibrationConfidence,
        )
    }
    return "est. · ${status.detail}"
}

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. A
 *  file-internal twin of the private [intString] so the dashboard rows format steps/calories identically. */
private fun intStringGrouped(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

// MARK: - "Your cards" dashboard editor (WHOOP "My Dashboard" ✎)
//
// A Today-local dialog for choosing WHICH dashboard cards show and in what order. Display-only: it edits the
// persisted selection, never any stored metric. Enabled cards first (saved order), then the disabled
// remainder in canonical order, so toggling one on drops it at the end of the visible set and every known
// card is listed once. Toggle hides/shows a card; up/down arrows reorder it (no reorder lib, simple arrow
// buttons, matching KeyMetricsEditorDialog). Mirrors iOS DashboardCardsEditorSheet. At least one card must
// stay enabled (an empty dashboard reads as a bug).

@Composable
private fun DashboardCardsEditorDialog(
    initial: List<DashboardCard>,
    onDismiss: () -> Unit,
    onSave: (List<DashboardCard>) -> Unit,
) {
    val items = remember {
        val enabledSet = initial.toHashSet()
        mutableStateListOf<EditableDashboardCard>().apply {
            initial.forEach { add(EditableDashboardCard(it, true)) }
            DashboardCard.canonicalOrder.filter { it !in enabledSet }.forEach { add(EditableDashboardCard(it, false)) }
        }
    }

    fun move(from: Int, to: Int) {
        if (from in items.indices && to in items.indices) {
            val item = items.removeAt(from)
            items.add(to, item)
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_today_screen_my_dashboard_a7a19e72), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_today_screen_choose_which_cards_show_on_today_f79942e1) +
                            "Cards with no value yet show a dash.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                Column(
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    items.forEachIndexed { index, item ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            NoopToggleSwitch(
                                checked = item.enabled,
                                onCheckedChange = { items[index] = item.copy(enabled = it) },
                                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_today_screen_show_item_card_title_7844540d, item.card.title) },
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                item.card.title,
                                style = NoopType.body,
                                color = if (item.enabled) Palette.textPrimary else Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { move(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowUp,
                                    contentDescription = uiString(R.string.l10n_today_screen_move_item_card_title_up_61a1b306, item.card.title),
                                    tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                            IconButton(
                                onClick = { move(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowDown,
                                    contentDescription = uiString(R.string.l10n_today_screen_move_item_card_title_down_abd8549a, item.card.title),
                                    tint = if (index < items.lastIndex) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline, thickness = 1.dp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            // Reset to the canonical default: the default selection enabled, rest disabled.
                            items.clear()
                            val enabledSet = DashboardCard.defaultSelection.toHashSet()
                            DashboardCard.defaultSelection.forEach { items.add(EditableDashboardCard(it, true)) }
                            DashboardCard.canonicalOrder.filter { it !in enabledSet }
                                .forEach { items.add(EditableDashboardCard(it, false)) }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.filter { it.enabled }.map { it.card }) },
                        // At least one card must stay visible, an empty dashboard reads as a bug, not a choice.
                        enabled = items.any { it.enabled },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}

/** One row's working state in the dashboard editor: the card + whether it's currently enabled. */
private data class EditableDashboardCard(val card: DashboardCard, val enabled: Boolean)

// #today-layout (hold-to-drag): LazyColumn key prefix for the reorderable section items, so the drag can
// tell a section item from the pinned rows around it.
private const val TODAY_SECTION_KEY_PREFIX = "todaySection:"

/**
 * Live drag state for the Today hold-to-drag section reorder (#today-layout). One instance per screen.
 * `key`/`distance` are snapshot state (they drive the lifted card's translation each frame); the rest are
 * plain fields written by the gesture and read on the same (main) thread.
 */
private class TodaySectionDragState {
    /** LazyColumn key of the section being dragged; null when idle. */
    var key by mutableStateOf<String?>(null)

    /** Accumulated finger travel since pickup (px). */
    var distance by mutableFloatStateOf(0f)

    /** The dragged item's viewport offset at pickup (px) — with [distance], the finger-anchored position. */
    var pickedUpAt = 0f

    /** Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time, so the speed is
     *  identical on 60/90/120 Hz displays), set by onDrag from edge proximity; 0 outside the edge zones. */
    var autoScrollPxPerSecond = 0f
}

/** This order with [section] moved to [target]'s position (the classic list move). */
private fun List<TodaySection>.movedTodaySection(section: TodaySection, target: TodaySection): List<TodaySection> {
    val from = indexOf(section)
    val to = indexOf(target)
    if (from == -1 || to == -1 || from == to) return this
    return toMutableList().apply { add(to, removeAt(from)) }
}

/**
 * The (dragged, target) pair to swap right now, or null. The lifted card's finger-anchored middle
 * (`pickedUpAt + distance + size/2`, viewport space) must sit over another section item AND have crossed
 * that item's CENTRE in the direction of travel — the centre gate stops a tall card over a short one from
 * ping-ponging (an immediate swap-back would require crossing back over the centre).
 *
 * The direction is derived from [order] (the section list, the source of truth), NOT from layout offsets:
 * after a swap the state updates immediately but layoutInfo lags one frame, and an offset-derived direction
 * on that stale frame re-derives the SAME swap and undoes it (a visible oscillation). Order-derived
 * direction flips with the swap, so the stale re-check fails the centre gate and the move sticks; a
 * genuine user reversal still passes once the finger crosses back over the centre. Pure read; the caller
 * applies the move.
 */
private fun swapTargetForDraggedSection(
    listState: LazyListState,
    drag: TodaySectionDragState,
    order: List<TodaySection>,
): Pair<TodaySection, TodaySection>? {
    val key = drag.key ?: return null
    val info = listState.layoutInfo
    val current = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return null
    val middle = drag.pickedUpAt + drag.distance + current.size / 2f
    val target = info.visibleItemsInfo.firstOrNull { item ->
        item.key != key && (item.key as? String)?.startsWith(TODAY_SECTION_KEY_PREFIX) == true &&
            middle >= item.offset && middle <= item.offset + item.size
    } ?: return null
    val dragged = TodaySection.fromRaw(key.removePrefix(TODAY_SECTION_KEY_PREFIX)) ?: return null
    val tgt = TodaySection.fromRaw((target.key as String).removePrefix(TODAY_SECTION_KEY_PREFIX)) ?: return null
    val targetCentre = target.offset + target.size / 2f
    val movingDown = order.indexOf(tgt) > order.indexOf(dragged)
    if (movingDown && middle < targetCentre) return null
    if (!movingDown && middle > targetCentre) return null
    return dragged to tgt
}

/**
 * #today-layout (hold-to-drag): the per-section drag wrapper. LONG-PRESS anywhere on the section lifts it
 * (haptic; the card raises + follows the finger via graphicsLayer, translation computed against the item's
 * CURRENT layout offset so a mid-drag reorder or auto-scroll can't teleport it). onDrag only accumulates
 * finger travel + the edge auto-scroll velocity — the screen-level frame loop owns the swap + scroll, one
 * code path whether the finger is moving or parked at an edge. Taps/scrolls pass through untouched (the
 * detector waits for a long press), so every card keeps its own tap behaviour. No reorder library.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LazyItemScope.TodayReorderableSection(
    section: TodaySection,
    listState: LazyListState,
    drag: TodaySectionDragState,
    onDrop: () -> Unit,
    content: @Composable () -> Unit,
) {
    val key = TODAY_SECTION_KEY_PREFIX + section.raw
    val isDragging = drag.key == key
    val haptics = LocalHapticFeedback.current
    // Drop SETTLE: on release the lifted card is usually mid-air between slots; killing the translation
    // outright snapped it into place (part of the on-device "not smooth" report). Instead the residual
    // offset animates to 0 so the card glides into its slot. `settling` keeps the lifted chrome (zIndex)
    // during the glide; a new pickup cancels it.
    val settleScope = rememberCoroutineScope()
    val settle = remember { Animatable(0f) }
    var settling by remember { mutableStateOf(false) }
    fun releaseWithSettle() {
        val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key }
        val residual = if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
        onDrop()
        drag.key = null
        drag.distance = 0f
        drag.autoScrollPxPerSecond = 0f
        if (residual != 0f) {
            settling = true
            settleScope.launch {
                settle.snapTo(residual)
                settle.animateTo(0f, tween(durationMillis = 220, easing = FastOutSlowInEasing))
                settling = false
            }
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .zIndex(if (isDragging || settling) 1f else 0f)
            .then(
                if (isDragging || settling) {
                    Modifier.graphicsLayer {
                        translationY = if (isDragging) {
                            // Finger-anchored viewport position minus wherever layout currently placed it.
                            val current = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == key }
                            if (current != null) drag.pickedUpAt + drag.distance - current.offset else 0f
                        } else {
                            settle.value
                        }
                        shadowElevation = if (isDragging) 12f else 6f
                        scaleX = 1.01f
                        scaleY = 1.01f
                    }
                } else {
                    // Non-dragged sections animate to their new slot as the lifted card crosses them — a
                    // calm, deterministic ease (the default placement spring read abrupt when a tall card
                    // displaced a short one; first on-device feedback).
                    Modifier.animateItemPlacement(tween(durationMillis = 260, easing = FastOutSlowInEasing))
                },
            )
            .pointerInput(key) {
                detectDragGesturesAfterLongPress(
                    onDragStart = {
                        settling = false
                        drag.key = key
                        drag.distance = 0f
                        drag.pickedUpAt = listState.layoutInfo.visibleItemsInfo
                            .firstOrNull { it.key == key }?.offset?.toFloat() ?: 0f
                        drag.autoScrollPxPerSecond = 0f
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    },
                    onDragEnd = { releaseWithSettle() },
                    onDragCancel = {
                        // The list already reordered live; persist what the user sees rather than
                        // silently reverting on a system-cancelled gesture.
                        releaseWithSettle()
                    },
                    onDrag = onDrag@{ change, amount ->
                        change.consume()
                        drag.distance += amount.y
                        val info = listState.layoutInfo
                        val current = info.visibleItemsInfo.firstOrNull { it.key == key } ?: return@onDrag
                        // Edge auto-scroll velocity (px/SECOND — the frame loop scales by real frame time)
                        // from the lifted card's proximity to the viewport edges; ramps linearly across the
                        // zone with an eased-in feel via the squared fraction, so entering the zone starts
                        // gently instead of at speed.
                        val zone = 112.dp.toPx()
                        val maxV = 620.dp.toPx()
                        val top = drag.pickedUpAt + drag.distance
                        val bottom = top + current.size
                        drag.autoScrollPxPerSecond = when {
                            bottom > info.viewportEndOffset - zone -> {
                                val f = ((bottom - (info.viewportEndOffset - zone)) / zone).coerceAtMost(1f)
                                maxV * f * f
                            }
                            top < info.viewportStartOffset + zone -> {
                                val f = (((info.viewportStartOffset + zone) - top) / zone).coerceAtMost(1f)
                                -maxV * f * f
                            }
                            else -> 0f
                        }
                    },
                )
            },
    ) { content() }
}

/**
 * #today-layout: reorder the below-hero Today sections (Synthesis / Key Metrics / Workouts / Heart Rate /
 * Recovery Vitals / Your Cards) by LONG-PRESSING a row and dragging it — a Today-local dialog, no new nav
 * destination. Every section always shows (this reorders, never hides), so there are no toggles, only order.
 * Hand-rolled fixed-height drag (no reorder lib, matching the project's "no reorder lib" stance). Twin of
 * the macOS TodayLayoutEditor. The sheet remains as the tap-based alternative to the live on-feed drag.
 */
@Composable
private fun TodayLayoutEditorDialog(
    initial: List<TodaySection>,
    onDismiss: () -> Unit,
    onSave: (List<TodaySection>) -> Unit,
) {
    val items = remember { mutableStateListOf<TodaySection>().apply { addAll(initial) } }
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    // Fixed row height makes the long-press drag deterministic: the dragged row swaps with its neighbour
    // once its accumulated offset crosses HALF a row, then the offset resets by one row so it keeps
    // tracking the finger. `draggingIndex` is the dragged section's CURRENT index (updated on each swap).
    val rowHeight = 52.dp
    val rowHeightPx = with(density) { rowHeight.toPx() }
    var draggingIndex by remember { mutableStateOf<Int?>(null) }
    var dragOffsetY by remember { mutableFloatStateOf(0f) }

    Dialog(onDismissRequest = onDismiss) {
        Surface(color = Palette.surfaceOverlay, shape = RoundedCornerShape(16.dp)) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_today_screen_arrange_today_6b699147), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.l10n_today_screen_hold_a_section_and_drag_it_1d6e2441),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }

                // 6 fixed-height rows fit without scrolling (drag + inner scroll would fight); each row is
                // picked up on long-press and follows the finger, swapping neighbours as it crosses them.
                Column {
                    items.forEachIndexed { index, section ->
                        val isDragging = draggingIndex == index
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(rowHeight)
                                .zIndex(if (isDragging) 1f else 0f)
                                .graphicsLayer {
                                    if (isDragging) {
                                        translationY = dragOffsetY
                                        shadowElevation = 8f
                                        scaleX = 1.02f
                                        scaleY = 1.02f
                                    }
                                }
                                .background(
                                    if (isDragging) Palette.surfaceRaised else Color.Transparent,
                                    RoundedCornerShape(10.dp),
                                )
                                .pointerInput(section) {
                                    detectDragGesturesAfterLongPress(
                                        onDragStart = {
                                            draggingIndex = index
                                            dragOffsetY = 0f
                                            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                        },
                                        onDragEnd = { draggingIndex = null; dragOffsetY = 0f },
                                        onDragCancel = { draggingIndex = null; dragOffsetY = 0f },
                                        onDrag = { change, amount ->
                                            change.consume()
                                            dragOffsetY += amount.y
                                            val cur = draggingIndex
                                            if (cur != null) {
                                                if (dragOffsetY > rowHeightPx / 2f && cur < items.lastIndex) {
                                                    items.add(cur + 1, items.removeAt(cur))
                                                    draggingIndex = cur + 1
                                                    dragOffsetY -= rowHeightPx
                                                } else if (dragOffsetY < -rowHeightPx / 2f && cur > 0) {
                                                    items.add(cur - 1, items.removeAt(cur))
                                                    draggingIndex = cur - 1
                                                    dragOffsetY += rowHeightPx
                                                }
                                            }
                                        },
                                    )
                                }
                                .padding(horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Filled.DragHandle,
                                contentDescription = null,
                                tint = Palette.textTertiary,
                                modifier = Modifier.size(Metrics.iconSmall),
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                section.title,
                                style = NoopType.body,
                                color = Palette.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            items.clear()
                            items.addAll(TodaySection.defaultOrder)
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.toList()) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.accent,
                            contentColor = Palette.surfaceBase,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}

/**
 * A1/S4: the Charge breakdown sheet opened by tapping the hero Charge ring. A full-screen surface with a
 * titled top bar (Close) and a scrollable body hosting the existing What-shaped-it breakdown, the
 * Contributors bars and (S4) the folded Readiness card. Built only when shown (the caller gates on
 * showChargeBreakdown), so the heavy rows materialise on tap (#819). Nothing is recomputed here, it reuses
 * the existing sections, which read the SAME carried/today row the ring shows. Mirrors iOS chargeBreakdownSheet.
 * `internal` (not private) so the Coupled view's hero ring (task #43) opens THIS same sheet, one breakdown,
 * never a duplicate.
 */
@Composable
internal fun ChargeBreakdownSheet(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric?,
    recoverySource: String?,
    showReadiness: Boolean,
    onClose: () -> Unit,
    onHowCalculated: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Metrics.screenPadding, vertical = Metrics.gap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    uiString(R.string.l10n_today_screen_what_shaped_your_charge_9f53a2b3),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = uiString(R.string.l10n_today_screen_close_bbfa773e), tint = Palette.textSecondary)
                }
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Metrics.screenPadding)
                    .padding(bottom = Metrics.sectionGap),
                verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            ) {
                // The breakdown self-gates: a calibrating night (empty drivers) renders nothing here, the
                // Contributors + Readiness below still give an honest read, never a blank sheet.
                val readDay = carriedDay ?: displayDay
                if (canExplainRecovery(recoverySource)) {
                    RecoveryDriversSection(
                        days = days,
                        displayDay = displayDay,
                        carriedDay = carriedDay,
                    )
                    RecoveryContributorsSection(day = displayDay, carriedDay = carriedDay)
                } else if (readDay?.recovery != null) {
                    NoopCard {
                        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                            Text(
                                stringResource(R.string.appwide_source_imported),
                                style = NoopType.headline,
                                color = Palette.textPrimary,
                            )
                            Text(
                                uiString(
                                    R.string.l10n_today_screen_the_method_behind_the_score_not_5bc68508,
                                ),
                                style = NoopType.subhead,
                                color = Palette.textSecondary,
                            )
                        }
                    }
                }
                // S4: the SEPARATE Readiness block now lives here behind the Charge-ring tap (today-only,
                // matching the old inline gate). A one-word read (Push / Maintain / Rest) stays on the hero.
                if (showReadiness) ReadinessSection(days, carriedDay = carriedDay)
                // Everything above is what shaped YOUR Charge today; this opens the general METHOD behind the
                // score, so the two are clearly separated, not conflated. Opens the scoring guide at the
                // Charge section, the same target the per-ring ⓘ buttons use. Mirrors the iOS chargeBreakdown
                // "How Charge is calculated" NavigationLink to ScoringGuideView(initialSection: .charge).
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .clickable(
                            onClickLabel = "How Recovery is calculated",
                            onClick = onHowCalculated,
                        )
                        .background(Palette.surfaceInset)
                        .padding(14.dp)
                        .semantics {
                            contentDescription = uiString(R.string.l10n_today_screen_how_charge_is_calculated_the_method_3ea7548b)
                        },
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(
                        Icons.Filled.Functions,
                        contentDescription = null,
                        tint = DomainTheme.Charge.color,
                        modifier = Modifier.size(14.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                    ) {
                        Text(
                            uiString(R.string.l10n_today_screen_how_charge_is_calculated_142d5e8e),
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                        )
                        Text(
                            uiString(R.string.l10n_today_screen_the_method_behind_the_score_not_5bc68508),
                            style = NoopType.caption,
                            color = Palette.textTertiary,
                        )
                    }
                    Icon(
                        Icons.AutoMirrored.Filled.KeyboardArrowRight,
                        contentDescription = null,
                        tint = Palette.textTertiary,
                        modifier = Modifier.size(12.dp),
                    )
                }
            }
        }
    }
}

// MARK: - "What shaped it" the engine-computed Charge driver breakdown
//
// The SHARED-CONTRACT driver rows under the Charge ring: one row per REAL term the recovery scorer used,
// each carrying its signed point contribution (deltaPoints), the night's value, the personal baseline it
// was scored against, and a short plain-English verdict. Computed by RecoveryDrivers.chargeDrivers from
// the SAME inputs the Charge ring reads, so a row can never describe a term the score did not use; a
// missing input yields NO row (never a faked zero). The confidence dot + tier tag SURFACE the existing
// ScoreConfidence.forCharge: they are read, not recomputed. Hidden entirely when the day can't score
// (cold-start / no drivers). Byte-aligned with the iOS "What shaped it" section. No em-dashes.

@Composable
private fun RecoveryDriversSection(
    days: List<DailyMetric>,
    displayDay: DailyMetric?,
    carriedDay: DailyMetric? = null,
) {
    // Read the row the Charge ring itself reads: today's own when scored, else the carried last-scored
    // day (#543) so the breakdown matches the carried ring instead of vanishing at the rollover.
    val readDay = carriedDay ?: displayDay
    val context = LocalContext.current
    val prefs = NoopPrefs.of(context)
    val hrvEpoch = prefs.getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble()
    val recoveryEpoch = prefs.getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble()
    val drivers = remember(days, readDay, hrvEpoch, recoveryEpoch) {
        recoveryChargeDrivers(days, readDay, hrvEpoch, recoveryEpoch)
    }
    if (drivers.isEmpty()) return

    val tier = remember(days, readDay, hrvEpoch) { chargeConfidenceTier(days, readDay, hrvEpoch) }
    val overline = carriedDay?.let { "Recovery · ${carriedCaption(it.day)}" } ?: "Recovery"

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        // Header row: section title + the SURFACED confidence pill (dot + tier tag) on the right.
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("What shaped it", overline = overline, trailing = "vs your baseline")
            }
            ChargeConfidencePill(tier)
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                drivers.forEach { DriverRow(it) }
                Text(
                    uiString(R.string.l10n_today_screen_each_line_is_how_many_points_dec2c062) +
                        "on-device baseline. Approximate, not medical advice.",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The SURFACED Charge confidence pill (dot + tier tag). Reads the existing ScoreConfidence, never
 *  recomputes it. SOLID = gold/accent, BUILDING = the blue warning tone, CALIBRATING = neutral slate. */
@Composable
private fun ChargeConfidencePill(tier: ScoreConfidence) {
    val (label, tone) = when (tier) {
        ScoreConfidence.SOLID -> "SOLID" to StrandTone.Accent
        ScoreConfidence.BUILDING -> "BUILDING" to StrandTone.Warning
        ScoreConfidence.CALIBRATING -> "CALIBRATING" to StrandTone.Neutral
    }
    StatePill(title = label, tone = tone)
}

/** One "What shaped it" driver row: an up/down delta chip (signed points, green up / red down),
 *  the label + verdict, and the value over its baseline. Mirrors the iOS driver row layout. */
@Composable
private fun DriverRow(driver: ChargeDriver) {
    val positive = driver.deltaPoints >= 0
    // A zero delta reads neutral (no green/red), not a misleading "good".
    val tone = when {
        driver.deltaPoints > 0 -> Palette.statusPositive
        driver.deltaPoints < 0 -> Palette.statusCritical
        else -> Palette.textTertiary
    }
    val signed = if (driver.deltaPoints > 0) "+${driver.deltaPoints}" else "${driver.deltaPoints}"
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.semantics {
            contentDescription =
                uiString(R.string.l10n_today_screen_driver_label_driver_valuetext_driver_baselinetext_067bc963, driver.label, driver.valueText, driver.baselineText) +
                    "$signed points, ${driver.verdict}"
        },
    ) {
        // Signed-point delta chip with a direction glyph.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(tone.copy(alpha = 0.12f))
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            if (driver.deltaPoints != 0) {
                Icon(
                    if (positive) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                    contentDescription = null,
                    tint = tone,
                    modifier = Modifier.size(14.dp),
                )
            }
            Text(uiString(R.string.l10n_today_screen_signed_pts_5ea85678, signed), style = NoopType.captionNumber, color = tone)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(driver.label, style = NoopType.headline, color = Palette.textPrimary)
            Text(driver.verdict, style = NoopType.footnote, color = Palette.textSecondary)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(driver.valueText, style = NoopType.captionNumber, color = Palette.textPrimary)
            Text(driver.baselineText, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

// MARK: - Recovery contributors (README screen #5), labelled progress bars
//
// "CONTRIBUTORS", what drove today's Charge, each as a labelled progress bar in the shared stage/zone
// bar style (inset track, round-capped metric-hue fill, right-aligned read-out). Design-Reset tokens
// (iOS RecoveryContributorsSection parity): HRV reads teal (metricCyan), Resting HR the recovery/Charge
// world (chargeColor), Sleep and Respiratory the blue sleep world. Each bar's fraction is a
// presentation-only normalisation of the day's value to a typical adult span, no scoring/logic change.
// Suppressed entirely until at least one contributor has a value.

@Composable
private fun RecoveryContributorsSection(day: DailyMetric?, carriedDay: DailyMetric? = null) {
    // The row the contributors read from: today's own when it carries recovery, else the carried last
    // scored day (#543) so the bars don't all read "No Data" at the rollover while live HR ticks. The
    // overline stamps "Last night · <date>" when carrying so the prior read isn't passed off as today's.
    val cd = carriedDay ?: day
    val hrv = cd?.avgHrv
    val rhr = cd?.restingHr?.toDouble()
    val sleepMin = cd?.totalSleepMin
    val resp = cd?.respRateBpm
    if (hrv == null && rhr == null && sleepMin == null && resp == null) return

    val overline = carriedDay?.let { "Recovery · ${carriedCaption(it.day)}" } ?: "Recovery"
    SectionHeader("Contributors", overline = overline, trailing = "What drove Recovery")
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            // HRV, higher is better; map a typical 20–120 ms span. Teal (its biometric hue; iOS metricCyan).
            ContributorBar(
                label = "HRV",
                readout = hrv?.let { "${it.roundToInt()} ms" } ?: NO_DATA,
                fraction = hrv?.let { ((it - 20.0) / 100.0) },
                color = Palette.metricCyan,
            )
            // Resting HR, lower is better, so invert a typical 40–80 bpm span. Charge/recovery world (iOS
            // chargeColor, the recovery contributor reads on the WHOOP-green Charge world, not gold).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_resting_hr_26677094),
                readout = rhr?.let { "${it.roundToInt()} bpm" } ?: NO_DATA,
                fraction = rhr?.let { 1.0 - ((it - 40.0) / 40.0) },
                color = Palette.chargeColor,
            )
            // Sleep, hours in bed against an 8h target. Blue (sleep world).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_sleep_3cac34e6),
                readout = sleepMin?.let { sleepValue(cd) } ?: NO_DATA,
                fraction = sleepMin?.let { (it / 60.0) / 8.0 },
                color = Palette.sleepLight,
            )
            // Respiratory, stability around a typical 12–20 rpm span. Deep blue (sleep world).
            ContributorBar(
                label = uiString(R.string.l10n_today_screen_respiratory_1cd8c175),
                readout = resp?.let { String.format(Locale.US, "%.1f rpm", it) } ?: NO_DATA,
                fraction = resp?.let { 1.0 - ((it - 12.0) / 8.0) },
                color = Palette.sleepDeep,
            )
            Text(
                uiString(R.string.l10n_today_screen_baselines_learned_on_device_over_14_359f6812) +
                    "signal against a typical adult range, not medical advice.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** One labelled contributor bar: a label + right-aligned read-out over a liquid TUBE filled to [fraction].
 *  These ARE genuine single-value progress bars (each signal against a typical adult span), so the liquid
 *  finish reads well here (matching how the iOS liquid Today draws its single-value goal/strain bars as
 *  tubes). Static (not per-frame) — they sit in the tapped-open Charge breakdown, not a live surface, so
 *  `animated = false` keeps the sheet cheap. A null fraction renders an empty tube. */
@Composable
private fun ContributorBar(label: String, readout: String, fraction: Double?, color: Color) {
    val fillFrac = fraction?.coerceIn(0.0, 1.0) ?: 0.0
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(readout, style = NoopType.captionNumber, color = Palette.textPrimary)
        }
        LiquidTube(
            frac = fillFrac,
            tint = color,
            height = Metrics.progressHeight,
            animated = false,
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = uiString(R.string.l10n_today_screen_label_readout_3f166607, label, readout) },
        )
    }
}

// ════════════════════════════════════════════════════════════════════════════════════════════════════
// Explainability layer, COMPONENTS 2, 3, 4 (spec: 2026-06-20-sleep-guidance-explainability.md)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Every uncertain or derived read-out on
// Today gets a clear state, a plain-English reason and a next step, and we NEVER fabricate a number:
// calibrating / needs-strap show NO value, carried values are always stamped with their date, and the
// provenance badge reflects the REAL per-day merge winner. The copy here is VERBATIM and must match the
// Swift today lane word-for-word (ScoreState / RecordingState). No em-dashes anywhere.
// ════════════════════════════════════════════════════════════════════════════════════════════════════

// ── COMPONENT 2, explained score states ─────────────────────────────────────────────────────────────

/** The honest score-state note shown in the Today flow when there is no own number to render, the
 *  state title + one what-to-do line, no fabricated value. [ScoreState.Scored] renders nothing (the
 *  tiles carry the real number). The whole card is the spec's "never a bare blank". Mirrors the iOS
 *  ScoreStateNote. */
@Composable
private fun ScoreStateNote(state: ScoreState) {
    if (state is ScoreState.Scored) return
    val icon = when (state) {
        is ScoreState.Calibrating -> Icons.Filled.Tune
        ScoreState.BaselineReady -> Icons.Filled.CheckCircle
        is ScoreState.CarriedLastNight -> Icons.Filled.History
        ScoreState.NeedsStrap -> Icons.Filled.Warning
        is ScoreState.Scored -> Icons.Filled.Info
    }
    val tint = when (state) {
        ScoreState.NeedsStrap -> Palette.statusWarning
        ScoreState.BaselineReady -> Palette.statusPositive
        else -> Palette.textTertiary
    }
    NoopCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = uiString(R.string.l10n_today_screen_state_title_state_detail_f5380609, state.title, state.detail) },
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier
                    .padding(top = 1.dp)
                    .size(Metrics.iconSmall),
            )
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(state.title, style = NoopType.headline, color = Palette.textPrimary)
                Text(state.detail, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

// ── COMPONENT 3, recording status ───────────────────────────────────────────────────────────────────

/** The Today/Live recording chip: a tinted StatePill with the status word (a pulsing dot while live),
 *  plus the one-line what-it-means below. Honest, never claims "Recording" without a live stream.
 *  Tapping a not-recording chip routes to connect (Settings). Mirrors the iOS RecordingStatusChip. */
@Composable
private fun RecordingStatusChip(state: RecordingState, onConnect: () -> Unit) {
    val clickable = state is RecordingState.NotRecording || state is RecordingState.LastSynced
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(
                if (clickable) {
                    Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClick = onConnect,
                    )
                } else {
                    Modifier
                },
            )
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_state_title_state_detail_f5380609, state.title, state.detail) },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        StatePill(
            title = state.title,
            tone = state.tone,
            showsDot = true,
            pulsing = state is RecordingState.Recording,
        )
        Text(
            state.detail,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            modifier = Modifier.weight(1f),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

// ── COMPONENT 4, provenance badge ───────────────────────────────────────────────────────────────────

// NOTE: the blanket day-level `TodayProvenanceBadge` was removed. Today provenance now resolves the real
// per-metric field-by-field winners, deduplicates them, and renders one card-level SourceBadge aligned to
// the Rest vessel (see heroSourceLabel + ScoreHeroRow). The pure `dayOwnerSource` /
// `provenanceBadgeLabel` By-Day mappers are kept (Intelligence/Trends + tests still use that vocabulary).

/**
 * The full 14-day metric grid, mirroring the macOS LazyVGrid order:
 * Charge, Effort, Rest, HRV, Resting HR, Blood Oxygen, Respiratory,
 * Steps, Weight, Calories. Each tile is a fixed-height [SparkStatTile] so the
 * grid tiles perfectly with no empty cells.
 */
@Composable
private fun MetricGrid(
    d: DailyMetric?,
    w: Window,
    recoveryCalibration: Int? = null,
    lastScoredCharge: LastCharge? = null,
    carriedDay: DailyMetric? = null,
    // PER-FIELD SpO₂ carry (see lastSpo2Row): carriedDay is recovery-gated and lands on rows whose
    // spo2Pct is null (computed rows never carry one), so the Blood Oxygen tile falls through to the
    // last row that actually has a reading. Mirrors iOS TodayView.lastSpo2Day (carriedVital's per-field fallback).
    spo2CarryDay: DailyMetric? = null,
    massUnit: MassUnit = MassUnit.KILOGRAMS,
    effortScale: EffortScale = EffortScale.HUNDRED,
    effortForDay: Double? = null,
    latestWeightKg: Double? = null,
    profileWeightKg: Double = 75.0,
    importedStepsForDay: Int? = null,
    estimatedStepsForDay: Int? = null,
    // #616: the selected day's calorie value resolved imported-first (imported Apple/Health-Connect
    // activeKcal ?: NOOP's on-device estimate), so the Calories tile matches the card + detail instead of
    // reading the on-device estimate alone (which left it NO_DATA / inconsistent). Mirrors the steps params.
    caloriesForDay: Double? = null,
    // #616: the Calories tile's imported-first 14-day trend (see caloriesSpark above) — threaded like
    // restSpark because it isn't a plain DailyMetric column (it unions the imported + on-device series).
    caloriesSpark: List<Double> = emptyList(),
    // #316 / @63, the selected day's representative activity class (0=still, 1=walk, 2=run), shown beside
    // the WHOOP 5/MG motion estimate. null hides it when no classed sample exists for the day.
    stepActivityClassForDay: Int? = null,
    // #760/#792: the caption under an ESTIMATED Steps tile: the engine's STATUS line (manual k, or
    // k=… from N days + confidence tier) so a frozen-looking estimate self-explains. Built from the SAME
    // persisted calibration the estimate used; defaults to a bare "est." for callers that don't supply it.
    stepsEstimateCaption: String = "est.",
    restScore: Double? = null,
    // The Rest tile's sparkline: the trailing-window Rest composite (0–100, `sleep_performance`), so the
    // mini-graph tracks the Rest SCORE rather than raw sleep minutes (#614 follow-up). Other tiles still
    // read their series off `w` (the DailyMetric windows).
    restSpark: List<Double> = emptyList(),
    enabledMetrics: List<KeyMetric> = KeyMetric.defaultOrder,
    isToday: Boolean = false,
    onScoreInfo: (ScoreSection) -> Unit = {},
    // Detailed tiles (the #251 editor's switch): squarer tiles with a 14-day trend graph under the bar.
    detailed: Boolean = false,
    // Tile drill-ins: every tile opens its focused trend timeline (vital_detail/<key>, the Sleep
    // night-detail pattern) via [onOpenMetric].
    onOpenMetric: (String) -> Unit = {},
) {
    // Current iOS parity: two readable columns, a dimensional semantic glyph, large value, and either a
    // real trend or a bounded-score liquid rail. The editor's pin order still leads the complete catalog.
    val descriptors: Map<KeyMetric, KeyTileData> = mapOf(
        KeyMetric.CHARGE to run {
            val v = d?.recovery ?: lastScoredCharge?.value
            // A scored/carried Recovery uses its 0–100 axis. During calibration the visible N/M copy is
            // backed by the same bounded N/M liquid progress; it never becomes a fabricated Recovery score.
            val progress = when {
                d?.recovery != null -> d.recovery / 100.0
                recoveryCalibration != null ->
                    recoveryCalibration.toDouble() / Baselines.minNightsSeed.toDouble()
                lastScoredCharge != null -> lastScoredCharge.value / 100.0
                else -> null
            }
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_recovery_ea924f72),
                value = d?.recovery?.let { "${it.roundToInt()}" }
                    ?: recoveryCalibration?.let { "$it/${Baselines.minNightsSeed}" }
                    ?: lastScoredCharge?.let { "${it.value.roundToInt()}" } ?: NO_DATA,
                unit = if (d?.recovery != null || lastScoredCharge != null) "%" else "",
                tint = v?.let { Palette.recoveryGaugeColors(it).first } ?: Palette.chargeColor,
                frac = progress?.coerceIn(0.0, 1.0),
                spark = w.recovery,
            )
        },
        KeyMetric.EFFORT to KeyTileData(
            label = uiString(R.string.l10n_today_screen_strain_79fe380e),
            value = (effortForDay ?: d?.strain)?.let { UnitFormatter.effortDisplay(it, effortScale) } ?: NO_DATA,
            // #492: Strain/Effort is a load index (0–21 WHOOP / 0–100 NOOP), NOT a percentage - the "%"
            // was wrong (esp. on the 0–21 scale). Recovery/Rest ARE 0–100 % and keep it. iOS shows the
            // strain axis as an "of 21"/"of 100" caption with no % (TodayView effort tile); match that.
            unit = "",
            tint = (effortForDay ?: d?.strain)?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.effortColor,
            frac = (effortForDay ?: d?.strain)?.let { (it / 100.0).coerceIn(0.0, 1.0) },
            spark = w.strain,
        ),
        KeyMetric.REST to KeyTileData(
            label = uiString(R.string.l10n_today_screen_rest_b79e5f48),
            value = restScore?.let { "${it.roundToInt()}" } ?: NO_DATA,
            unit = if (restScore != null) "%" else "",
            tint = restScore?.let { Palette.recoveryColor(it) } ?: Palette.restColor,
            frac = restScore?.let { (it / 100.0).coerceIn(0.0, 1.0) },
            spark = restSpark,
        ),
        KeyMetric.HRV to run {
            val v = d?.avgHrv ?: carriedDay?.avgHrv
            KeyTileData(
                label = "HRV",
                value = v?.let { "${it.roundToInt()}" } ?: NO_DATA,
                unit = if (v != null) "ms" else "",
                tint = Palette.metricCyan,
                frac = null,
                spark = w.hrv,
            )
        },
        KeyMetric.RESTING_HR to run {
            val v = d?.restingHr ?: carriedDay?.restingHr
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_rest_hr_04005617),
                value = v?.toString() ?: NO_DATA,
                unit = if (v != null) "bpm" else "",
                tint = Palette.metricRose,
                frac = null,
                spark = w.rhr,
            )
        },
        KeyMetric.BLOOD_OXYGEN to run {
            val v = d?.spo2Pct ?: carriedDay?.spo2Pct ?: spo2CarryDay?.spo2Pct
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_blood_oxygen_a8ad9ff5),
                value = v?.let { String.format(Locale.US, "%.0f", it) } ?: NO_DATA,
                unit = if (v != null) "%" else "",
                tint = Palette.metricCyan,
                frac = null,
                spark = w.spo2,
            )
        },
        KeyMetric.RESPIRATORY to run {
            val v = d?.respRateBpm ?: carriedDay?.respRateBpm
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_respiratory_1cd8c175),
                value = v?.let { String.format(Locale.US, "%.1f", it) } ?: NO_DATA,
                unit = if (v != null) "rpm" else "",
                tint = Palette.accent,
                frac = null,
                spark = w.resp,
            )
        },
        KeyMetric.STEPS to run {
            // A measured phone count wins; @57 and calibration are explicitly motion-derived fallbacks.
            val steps = resolvedSteps(importedStepsForDay, d?.steps, estimatedStepsForDay)
            KeyTileData(
                label = stepsTileLabel(d?.steps, importedStepsForDay, estimatedStepsForDay),
                value = steps?.let { intString(it.toDouble()) } ?: NO_DATA,
                unit = "",
                tint = Palette.metricCyan,
                frac = null,
                spark = w.steps,   // #616: was missing → no trend line under the tile
            )
        },
        KeyMetric.WEIGHT to run {
            val weight = weightTile(latestWeightKg, profileWeightKg, massUnit)
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_weight_69c0b815),
                value = weight.value,
                unit = "",
                tint = Palette.accent,
                frac = null,
            )
        },
        KeyMetric.CALORIES to run {
            // #616: the per-day resolved calorie value (caloriesForDay = imported Apple/Health-Connect
            // first, else NOOP's on-device estimate) — one number across tile, card and detail.
            val kcal = caloriesForDay
            KeyTileData(
                label = uiString(R.string.l10n_today_screen_calories_3e62ecfe),
                value = kcal?.let { intString(it) } ?: NO_DATA,
                unit = if (kcal != null) "kcal" else "",
                tint = Palette.metricAmber,
                frac = null,
                spark = caloriesSpark,   // #616: imported-first trend (was missing → no trend line)
            )
        },
    )

    // Always show the complete catalog. The saved three-to-five pins only determine which tiles lead.
    val tiles = KeyMetricPrefs.catalogOrder(enabledMetrics)
        .mapNotNull { m -> descriptors[m]?.let { m to it } }
    // Tile tap -> its focused trend TIMELINE (the Sleep night-detail pattern), uniformly for every tile
    // with a windowed series: Recovery/Effort/Rest open their new trend details; the vitals +
    // Steps/Calories open the same vital_detail trends the Health cards use. Today's Charge DRIVERS stay
    // on the hero ring's breakdown sheet (its existing home) — the tile is the history view.
    // Weight has no windowed detail yet -> not tappable (null keeps the tile inert rather than lying).
    fun tapFor(metric: KeyMetric): (() -> Unit)? = when (metric) {
        KeyMetric.CHARGE -> ({ onOpenMetric("recovery") })
        KeyMetric.EFFORT -> ({ onOpenMetric("strain") })
        KeyMetric.REST -> ({ onOpenMetric("rest") })
        KeyMetric.HRV -> ({ onOpenMetric("hrv") })
        KeyMetric.RESTING_HR -> ({ onOpenMetric("rhr") })
        KeyMetric.BLOOD_OXYGEN -> ({ onOpenMetric("spo2") })
        KeyMetric.RESPIRATORY -> ({ onOpenMetric("resp") })
        KeyMetric.STEPS -> ({ onOpenMetric("steps_est") })
        KeyMetric.CALORIES -> ({ onOpenMetric("active_kcal") })
        KeyMetric.WEIGHT -> null
    }
    // iOS `keyMetricsSection` LazyVGrid: 2 columns, spacing 8. Build from rows so tile heights stay uniform
    // and a partial last row pads with empty weight so the columns stay aligned.
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        tiles.chunked(2).forEach { rowTiles ->
            // Detailed rows equalise heights (IntrinsicSize.Max + fillMaxHeight, the #399 idiom): a
            // graph-less tile (Steps/Weight/Calories) sharing a row with graphed neighbours must not
            // shrink its card. Compact rows keep the plain layout, byte-identical to before.
            Row(
                modifier = if (detailed) Modifier.height(IntrinsicSize.Max) else Modifier,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                rowTiles.forEach { (metric, tile) ->
                    LiquidKeyTile(
                        tile,
                        icon = metric.icon,
                        showsBoundedProgress = metric.isBoundedProgress,
                        onClick = tapFor(metric),
                        modifier = Modifier
                            .weight(1f)
                            .testTag("noop.today.metric.${metric.raw}")
                            .then(if (detailed) Modifier.fillMaxHeight() else Modifier),
                    )
                }
                repeat(2 - rowTiles.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

/** One compact Key-Metrics tile's data: iOS `ktile`(label, value, unit, tint, frac). [frac] is meaningful
 *  only for a [KeyMetric.isBoundedProgress] score; raw measurements leave it null. [spark] is the 14-day
 *  trend series (oldest→newest) the DETAILED tile style graphs; empty hides the graph. */
private data class KeyTileData(
    val label: String,
    val value: String,
    val unit: String,
    val tint: Color,
    val frac: Double?,
    val spark: List<Double> = emptyList(),
)

private enum class KeyMetricTrendDirection(
    @StringRes val labelRes: Int,
    val icon: ImageVector,
) {
    UP(R.string.today_trend_direction_up, Icons.AutoMirrored.Filled.TrendingUp),
    DOWN(R.string.today_trend_direction_down, Icons.AutoMirrored.Filled.TrendingDown),
    STEADY(R.string.today_trend_direction_steady, Icons.AutoMirrored.Filled.TrendingFlat),
}

/** Endpoint direction only, matching iOS's neutral tolerance and making no clinical claim. */
private fun keyMetricTrendDirection(values: List<Double>): KeyMetricTrendDirection? {
    val finite = values.filter(Double::isFinite)
    if (finite.size < 2) return null
    val first = finite.first()
    val last = finite.last()
    val delta = last - first
    val scale = maxOf(kotlin.math.abs(first), kotlin.math.abs(last), 1.0)
    val tolerance = maxOf(0.01, scale * 0.001)
    return when {
        kotlin.math.abs(delta) <= tolerance -> KeyMetricTrendDirection.STEADY
        delta > 0.0 -> KeyMetricTrendDirection.UP
        else -> KeyMetricTrendDirection.DOWN
    }
}

/** Current iOS `ktile`: a two-column dimensional glyph tile with a 24sp value and 26dp trend/progress lane. */
@Composable
private fun LiquidKeyTile(
    data: KeyTileData,
    icon: ImageVector,
    showsBoundedProgress: Boolean,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val hasValue = data.value != NO_DATA
    val trend = data.spark.takeLast(14)
    val showsTrend = trend.size >= 2
    // Tap -> the tile's focused trend detail (the Sleep night-detail tile idiom): liquidPress on the
    // tappable tile, indication = null so only the liquid settle shows. A null onClick keeps the tile
    // inert with zero modifier overhead (byte-identical to before).
    val interaction = remember { MutableInteractionSource() }
    val base = if (onClick != null) {
        modifier
            .liquidPress(interaction)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
    } else {
        modifier
    }
    Column(
        modifier = base
            .clip(RoundedCornerShape(20.dp))
            .frostedCardSurface(
                tint = data.tint,
                cornerRadius = 20.dp,
                washStrength = 0.76f,
            )
            .padding(horizontal = 12.dp, vertical = 12.dp)
            .semantics { contentDescription = uiString(R.string.l10n_today_screen_data_label_data_value_data_unit_27f6fd6b, data.label, data.value, data.unit).trim() },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (showsTrend) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MetricGlyph(icon = icon, size = 28.dp)
                Spacer(Modifier.weight(1f))
                keyMetricTrendDirection(trend)?.let { direction ->
                    val directionLabel = stringResource(direction.labelRes)
                    val directionDescription = stringResource(
                        R.string.today_14_day_direction,
                        directionLabel,
                    )
                    Row(
                        modifier = Modifier
                            .height(20.dp)
                            .clip(CircleShape)
                            .background(Palette.surfaceInset.copy(alpha = 0.78f))
                            .border(
                                width = 0.6.dp,
                                color = Palette.hairline.copy(alpha = 0.9f),
                                shape = CircleShape,
                            )
                            .padding(horizontal = 5.dp)
                            .semantics {
                                contentDescription = directionDescription
                            },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text(
                            stringResource(R.string.today_14_day_short),
                            style = NoopType.overline.copy(fontSize = 7.5.sp, letterSpacing = 0.sp),
                            color = Palette.textTertiary,
                        )
                        Icon(
                            imageVector = direction.icon,
                            contentDescription = null,
                            tint = Palette.textTertiary,
                            modifier = Modifier.size(10.dp),
                        )
                    }
                }
            }
            Text(
                data.label.uppercase(),
                style = NoopType.overline.copy(fontSize = 9.5.sp, letterSpacing = 0.sp),
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        } else {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                MetricGlyph(icon = icon, size = 28.dp)
                Text(
                    data.label.uppercase(),
                    style = NoopType.overline.copy(fontSize = 9.5.sp, letterSpacing = 0.sp),
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                data.value,
                style = NoopType.number(24f),
                color = if (hasValue) Palette.textPrimary else Palette.textTertiary,
                maxLines = 1,
            )
            if (data.unit.isNotEmpty() && hasValue) {
                Text(
                    uiString(R.string.l10n_today_screen_data_unit_c768ef8c, data.unit),
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                    maxLines = 1,
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(26.dp),
            contentAlignment = Alignment.Center,
        ) {
            when {
                showsTrend -> {
                Sparkline(
                    values = trend,
                    color = data.tint,
                    modifier = Modifier
                        .fillMaxWidth()
                            .height(26.dp),
                )
            }
                showsBoundedProgress -> {
                    LiquidTube(
                        frac = data.frac ?: 0.0,
                        tint = data.tint,
                        height = 7.dp,
                        animated = false,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                else -> Unit
            }
        }
    }
}

// Workouts across every recorded + imported source over [from, to]. Recorded sessions live under
// the ACTIVE strap id - "whoop-<id>" after a re-pair - unioned with the canonical legacy "my-whoop"
// via [WhoopRepository.workoutsUnion] (#814): this read was pinned to the literal "my-whoop", which
// stranded a re-paired strap's fresh recordings, so the "Latest Workouts" feed and the HR-graph
// glyphs silently dropped the newest sessions while the Workouts screen (already on the union, #28)
// still showed them. Apple Health and Health Connect imports are stored under their own device ids
// (since #34/#53). Both the "Last Workouts" feed and the HR-graph sport glyphs need the SAME union,
// or Health-Connect-imported sessions get no glyph on the Today trend, so they share this one seam.
// Deduped here (not per-consumer) with the Workouts screen's #687 semantics: a live strap recording
// and its thin Health Connect import collapse to the richer row, so neither the feed shows a
// duplicate card nor the HR trend a doubled sport glyph. dropDetectedShadows/filterDismissed are
// deliberately absent: `detected` rows live under `<deviceId>-noop`, which this union never queries.
private suspend fun WhoopRepository.workoutsAllSources(
    activeDeviceId: String,
    from: Long,
    to: Long,
): List<WorkoutRow> =
    WorkoutEditing.dedupCrossSource(
        workoutsUnion(activeDeviceId, from, to) +
            workouts("apple-health", from, to) +
            workouts("health-connect", from, to)
    )

// MARK: - Heart-rate trend (today's continuous HR off the strap's own ~1Hz history)
//
// A full-width 24h HR trend, plotted from 5-minute bucket means of the strap's hrSample history
// (offloaded even while the app was closed, so the day reads continuously). Hidden until there are at
// least two buckets, so a strap-only user with no wear today sees nothing rather than an empty chart.
// Mirrors the macOS TodayView.heartRateTrendSection. LineChart spaces points by index (no time axis),
// so the buckets, being uniform 5-min means in time order, read as an even left-to-right day curve.

/** The HR-window selector row, reusing the app's ONE SegmentedPillControl (house chrome, not the PR's
 *  bespoke control). Shared by the empty and populated card branches so the pills stay put whether or
 *  not the chosen window has data. */
@Composable
private fun HrWindowPills(selection: HrWindow, onSelect: (HrWindow) -> Unit) {
    SegmentedPillControl(
        items = HrWindow.entries.toList(),
        selection = selection,
        label = { it.label },
        onSelect = onSelect,
    )
}

@Composable
private fun HeartRateTrendCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    selectedDay: LocalDate,
    today: LocalDate,
    activeDeviceId: String,
    displayMetric: DailyMetric? = null,
    effortScale: EffortScale = EffortScale.HUNDRED,
    effortForDay: Double? = null,
) {
    // "Today" here is the LOGICAL day (rolls at 04:00 local), so in the small hours after midnight the
    // trend keeps the evening's curve, window start at the logical day's own midnight, "since midnight"
    // subtitle, "Today" label, rather than blanking to an empty new-calendar-day axis (#144).
    var buckets by remember(activeDeviceId) { mutableStateOf<List<HrBucket>>(emptyList()) }
    // The night's sleep session overlapping the HR window + the day's workouts, the Overview-HR
    // marker layers (sleep band, Charge at wake, sport glyphs at HR peaks). Loaded off the main
    // thread alongside the buckets; each marker self-hides when its data is absent. (PR #285)
    var sleepToday by remember(activeDeviceId) { mutableStateOf<SleepSession?>(null) }
    var workoutsToday by remember(activeDeviceId) { mutableStateOf<List<WorkoutRow>>(emptyList()) }
    // #985: the selected HR window. rememberSaveable ordinal so the choice survives rotation / process
    // death and feels sticky like a preference; 0 = TODAY, the unchanged full-day default. Forced to
    // TODAY on a past day (no "now" to anchor a rolling window - the pills don't render there either).
    // VIEW-ONLY (see HrWindow): it narrows the rendered buckets below; the LaunchedEffect read is untouched.
    var hrWindowOrdinal by rememberSaveable { mutableIntStateOf(0) }
    val hrWindow = if (selectedDay == today) HrWindow.entries[hrWindowOrdinal] else HrWindow.TODAY
    // #829 Android parity - the Today HR pinch/drag zoom window (unix seconds), null = the full loaded
    // day. Mirrors iOS TodayView.hrZoomDomain: VIEW-ONLY (it narrows which of the already-loaded buckets
    // render, never re-queries the DB), keyed on the selected day so stepping days always opens at full
    // scale, while a same-day live reload keeps the window (fresh buckets only ever extend the loaded
    // extent, so an existing window stays valid). Reset by double-tap on the chart or the Reset link.
    // Also keyed on the #985 window: changing the window re-frames the chart, so a pinch-zoom made
    // inside the old frame resets with it rather than surviving as a stale sub-range.
    var hrZoom by remember(activeDeviceId, selectedDay, hrWindowOrdinal) {
        mutableStateOf<LongRange?>(null)
    }
    // Raw HR can change without a DailyMetric revision. Refresh once after the history-write burst is
    // stably quiet; querying on every chunk was the measured write-contention path and repeatedly rebuilt
    // this chart while the user scrolled.
    val lastHistorySyncAt by viewModel.lastHistorySyncAt.collectAsStateWithLifecycle()
    val rawBackfilling by viewModel.historyBackfillActive.collectAsStateWithLifecycle()
    val deferHistoricalQueries = rememberHistoryQueryGate(rawBackfilling)
    LaunchedEffect(
        days,
        selectedDay,
        today,
        activeDeviceId,
        lastHistorySyncAt,
        deferHistoricalQueries,
    ) {
        if (deferHistoricalQueries) return@LaunchedEffect
        val requestDeviceId = activeDeviceId
        val diagnostic = com.noop.AppDiagnosticsRecorder.beginOperation("today.hr_trend_load")
        var outcome = "completed"
        var fields = emptyMap<String, String>()
        val zone = ZoneId.systemDefault()
        val start = selectedDay.atStartOfDay(zone).toEpochSecond()
        val nextStart = selectedDay.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val now = System.currentTimeMillis() / 1000
        val end = if (selectedDay == today) now else (nextStart - 1)
        try {
            val snapshot = coroutineScope {
                val loadedBuckets = async {
                    viewModel.repo.hrBucketsUnion(requestDeviceId, start, end, 300L)
                }
                val loadedSleep = async {
                    loadTodayBestEffort {
                        val overlapping = viewModel.repo
                            .sleepSessionsUnion(requestDeviceId, start - 18 * 3600L, end)
                            .filter { it.startTs <= end && it.endTs >= start }
                        val habitualMidsleepSec =
                            viewModel.repo.habitualMidsleepSec(requestDeviceId)
                        mainSleepSpan(overlapping, habitualMidsleepSec)?.let { (spanStart, spanEnd) ->
                            SleepSession(
                                deviceId = requestDeviceId,
                                startTs = spanStart,
                                endTs = spanEnd,
                            )
                        }
                    }
                }
                val loadedWorkouts = async {
                    loadTodayBestEffort {
                        viewModel.repo
                            .workoutsAllSources(requestDeviceId, start - 6 * 3600L, end)
                            .filter { it.startTs <= end && it.endTs >= start }
                    } ?: emptyList()
                }
                Triple(loadedBuckets.await(), loadedSleep.await(), loadedWorkouts.await())
            }
            currentCoroutineContext().ensureActive()
            if (viewModel.activeStrapId != requestDeviceId) {
                outcome = "superseded"
                return@LaunchedEffect
            }
            buckets = snapshot.first
            sleepToday = snapshot.second
            workoutsToday = snapshot.third
            fields = mapOf(
                "hr_bucket" to sleepHistoryResultBucket(snapshot.first.size),
                "workout_bucket" to workoutRecoveryResultBucket(snapshot.third.size),
            )
        } catch (cancelled: CancellationException) {
            outcome = "canceled"
            throw cancelled
        } catch (_: Exception) {
            outcome = "failed"
        } finally {
            com.noop.AppDiagnosticsRecorder.endOperation(
                diagnostic,
                outcome = outcome,
                fields = fields,
            )
        }
    }
    val selectedLabel = when (selectedDay) {
        today -> "Today"
        today.minusDays(1) -> "Yesterday"
        else -> selectedDay.format(DateTimeFormatter.ofPattern("d MMM", Locale.US))
    }

    // #985 view-only narrowing (the #829 rule): the selected window filters the loaded 5-minute buckets,
    // anchored at the wall clock when the inputs change. A live reload refreshes `buckets`, so the anchor
    // tracks the sync cadence — plenty for a card whose buckets are 5 minutes wide.
    val winBuckets = remember(buckets, hrWindow) {
        val now = System.currentTimeMillis() / 1000
        if (hrWindow == HrWindow.TODAY) buckets else buckets.filter { hrWindowKeeps(it.bucket, hrWindow, now) }
    }

    // #863: a sparse/empty selected day used to `return` here and render NOTHING, which read as "the graph
    // froze". Show an explicit calibrating/empty card instead so the user knows the curve is still filling in
    // (a calibrating 4.0 banks HR slowly) rather than that the screen broke. We intentionally do NOT silently
    // swap in a different day's curve here (that day-swap reload behaviour was rejected in #605, see above);
    // the honest empty state is the parity-matched fix. Mirrors the iOS Today HR card's empty branch.
    // #985: the check reads the WINDOWED subset, and the pills stay visible in the empty state, so a
    // too-narrow rolling window (say 1h with no recent offload) is never a dead end — the user widens it
    // or steps back to Today, and the message says which window came up empty.
    if (winBuckets.size < 2) {
        SectionHeader("Heart Rate", overline = selectedLabel)
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Overline("Beats per minute")
                if (selectedDay == today) {
                    HrWindowPills(hrWindow) { hrWindowOrdinal = it.ordinal }
                }
                Text(
                    when {
                        selectedDay != today ->
                            "No heart rate for this day. Step back to a day Noop Band was worn."
                        hrWindow != HrWindow.TODAY && buckets.size >= 2 ->
                            "No heart rate in the last ${hrWindow.label}. Try a wider window or Today."
                        else ->
                            "Calibrating, no heart rate banked yet today. Your curve fills in as Noop Band syncs."
                    },
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
        return
    }

    // #985: everything below (read-outs, zoom bounds, chart, footer) renders the WINDOWED subset — for
    // TODAY that is the identical full-buckets list, so the default path is byte-for-byte the old one.
    val bpm = remember(winBuckets) { winBuckets.map { it.avgBpm } }
    val latest = bpm.last().roundToInt()
    val min = bpm.min().roundToInt()
    val max = bpm.max().roundToInt()
    val avg = bpm.average().roundToInt()

    // #829 - the RENDERED subset: the zoom window narrows which of the loaded buckets draw (the gesture
    // handler only commits windows keeping >= 2 buckets, and the full-buckets fallback covers a same-day
    // reload reshaping the data underneath an open window, so the curve always stays drawable). Bounds =
    // the SELECTED window's bucket extent (#985) — the same full view the un-zoomed chart renders — so a
    // pinch-zoom pans within the chosen window, not out into buckets the window has hidden.
    val zoomBounds = winBuckets.first().bucket..winBuckets.last().bucket
    val visBuckets = remember(winBuckets, hrZoom) {
        val sub = hrZoom?.let { w -> winBuckets.filter { it.bucket in w } } ?: winBuckets
        if (sub.size >= 2) sub else winBuckets
    }
    val visBpm = remember(visBuckets) { visBuckets.map { it.avgBpm } }
    // The left y-rail tracks the RENDERED window (LineChart normalises to what it draws, the Deep
    // Timeline idiom), so a zoomed curve keeps honest max/avg/min beside it; the footer Min/Avg/Max row
    // below reads the whole SELECTED window (#985) — the full day for Today, or the rolling last-N-hours
    // span — so it matches the subtitle and stays stable while you pinch around within that window.
    val visMax = visBpm.max().roundToInt()
    val visAvg = visBpm.average().roundToInt()
    val visMin = visBpm.min().roundToInt()

    // Round wall-clock ticks for the RENDERED extent, shared by the gridlines (drawn inside
    // OverviewHRChart) and the axis-label strip below so they align.
    val timeTicks = remember(visBuckets) {
        chartTimeTicks(visBuckets.first().bucket, visBuckets.last().bucket, ZoneId.systemDefault())
    }
    val visTimestamps = remember(visBuckets) { visBuckets.map { it.bucket } }

    SectionHeader("Heart Rate", overline = selectedLabel)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Header, mirrors the macOS ChartCard (title + subtitle, trailing read-out).
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Beats per minute")
                    // #985: the buckets stay the same 5-minute means whatever the window (view-only
                    // narrowing, no re-read), so the resolution half of the label never changes — only
                    // the span half tells the truth about what's on screen.
                    val subtitle = when {
                        selectedDay != today -> "5-minute average | selected day"
                        hrWindow == HrWindow.TODAY -> "5-minute average | since midnight"
                        else -> "5-minute average | last ${hrWindow.label}"
                    }
                    Text(
                        subtitle,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text(uiString(R.string.l10n_today_screen_latest_bpm_e7bec767, latest), style = NoopType.chartValueLarge, color = Palette.metricRose)
            }
            // #985: the window selector, current day only — Today (since midnight, the default) or a
            // rolling last-N-hours cut of the same loaded buckets. A past day has no "now" → no selector.
            if (selectedDay == today) {
                HrWindowPills(hrWindow) { hrWindowOrdinal = it.ordinal }
            }
            // Chart with a max/avg/min Y-axis label column on the left and an HH:mm X-axis row below.
            // The line spaces points by index, but the X labels read each bucket's REAL timestamp in
            // local time (see below) so the axis reads true wall-clock even when the day has gaps (#544).
            Row(
                modifier = Modifier.height(IntrinsicSize.Min),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Column(
                    modifier = Modifier.height(Metrics.chartHeight),
                    verticalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(uiString(R.string.l10n_today_screen_vismax_80b2c2fc, visMax), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_today_screen_visavg_8c9a4746, visAvg), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                    Text(uiString(R.string.l10n_today_screen_vismin_5d665ceb, visMin), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                }
                // The HR line, with the Overview marker layers (sleep band · Charge · Effort · sport
                // glyphs) overlaid on top, markers are positioned by mapping each event's wall-clock
                // time onto the line's index spacing, so they sit on the same curve. (PR #285)
                // #829 - renders the zoom window's subset, with the pinch/pan/double-tap transform
                // detector attached (keyed on the #985-windowed buckets so its captured bounds track
                // both a reload and a window change — the pinch operates INSIDE the selected window).
                // The chart and its axis-label strip share this Column so both span exactly the
                // plot width (not the card width, which includes the y-rail) — a label centred at
                // a tick fraction lands under its gridline.
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    OverviewHRChart(
                        buckets = visBuckets,
                        bpm = visBpm,
                        sleep = sleepToday,
                        workouts = workoutsToday,
                        recovery = displayMetric?.recovery,
                        strain = effortForDay ?: displayMetric?.strain,
                        effortScale = effortScale,
                        timeTicks = timeTicks,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(Metrics.chartHeight)
                            .pointerInput(winBuckets) {
                                hrChartTransformGestures(
                                    buckets = winBuckets,
                                    bounds = zoomBounds,
                                    window = { hrZoom },
                                    onWindow = { hrZoom = it },
                                )
                            },
                    )
                    // X-axis: labels use the SAME timestamp interpolation as the line and markers,
                    // so the axis agrees with the curve even when the day has gaps (#544). "Now"
                    // only on the un-zoomed live day — a zoomed window's right edge is wherever
                    // the user panned it (#829).
                    HrTimeAxisLabels(
                        ticks = timeTicks,
                        timestamps = visTimestamps,
                        showNow = selectedDay == today && hrZoom == null,
                    )
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(Metrics.divider)
                    .background(Palette.hairline),
            )
            Row(modifier = Modifier.fillMaxWidth()) {
                listOf("Min" to min, "Avg" to avg, "Max" to max).forEach { (label, value) ->
                    Column(modifier = Modifier.weight(1f)) {
                        Overline(label, color = Palette.textTertiary)
                        Text(uiString(R.string.l10n_today_screen_value_bpm_8f3a90c3, value), style = NoopType.bodyNumber, color = Palette.textPrimary)
                    }
                }
            }
            // #829 - the pinch/drag affordance + Reset, mirroring the iOS hrZoomHint row: teaches the
            // gesture, and once zoomed shows a Reset link that mirrors the chart's own double-tap reset.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (hrZoom == null) "Pinch to zoom · drag to pan" else "Zoomed in · drag to pan",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                if (hrZoom != null) {
                    Text(
                        uiString(R.string.l10n_today_screen_reset_44c57abd),
                        style = NoopType.footnote,
                        color = Palette.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .clickable(onClickLabel = "Reset the heart rate zoom") { hrZoom = null }
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
        }
    }
}

// The Today HR x-axis label strip: one Text per round-time tick, centred under its gridline via
// the SAME per-bucket timestamp interpolation the chart uses (timestampFraction, Charts.kt) and
// clamped into the strip. "Now" keeps its right-edge slot; a tick label that would collide with
// it (or with its left neighbour) is skipped rather than overlapped.
@Composable
private fun HrTimeAxisLabels(
    ticks: List<Pair<Long, String>>,
    timestamps: List<Long>,
    showNow: Boolean,
) {
    Layout(
        modifier = Modifier.fillMaxWidth(),
        content = {
            ticks.forEach { (_, label) ->
                Text(label, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
            if (showNow) {
                Text(uiString(R.string.l10n_today_screen_now_e3b82040), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
        },
    ) { measurables, constraints ->
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val placeables = measurables.map { it.measure(loose) }
        val width = constraints.maxWidth
        val height = placeables.maxOfOrNull { it.height } ?: 0
        layout(width, height) {
            val nowPlaceable = if (showNow) placeables.last() else null
            val nowLeft = nowPlaceable?.let { width - it.width } ?: Int.MAX_VALUE
            nowPlaceable?.place(width - nowPlaceable.width, 0)
            var lastRight = Int.MIN_VALUE
            ticks.forEachIndexed { i, (ts, _) ->
                val p = placeables[i]
                val frac = timestampFraction(timestamps, ts) ?: return@forEachIndexed
                val x = (frac * width - p.width / 2f).roundToInt().coerceIn(0, (width - p.width).coerceAtLeast(0))
                // Skip a label that would overlap its neighbour or the "Now" marker.
                if (x > lastRight && x + p.width <= nowLeft - 8) {
                    p.place(x, 0)
                    lastRight = x + p.width + 8
                }
            }
        }
    }
}

// #829 Android parity - the Today HR chart's transform detector. The Deep Timeline's own
// detectTransformGestures claims EVERY drag on the chart, fine on its dedicated screen but here it would
// eat the Today feed's vertical scroll AND the LineChart's scrub-to-inspect. This detector reuses the
// Deep Timeline's pure window math (zoomedWindow / pannedWindow, Charts.kt) but watches the INITIAL
// pointer pass and claims only:
//   (a) any multi-finger gesture (pinch zooms about the centroid), always, and
//   (b) a single-finger HORIZONTAL-dominant drag while ZOOMED (pan). Un-zoomed, a horizontal drag stays
//       the LineChart's scrub-to-inspect exactly as before, matching iOS where an un-zoomed pan is a
//       visual no-op anyway.
// A vertical-dominant drag is never claimed, so the feed keeps scrolling over the chart. Claimed events
// are consumed in the Initial pass, which cancels the child scrub AND the page-level day-swipe for that
// gesture, the same chart-owns-its-frame exclusivity the iOS Today chart gets from masking the day-swipe
// over the chart frame. A motionless double tap resets to the full day, mirroring the iOS double-tap
// reset. Windows only commit when they keep >= 2 buckets visible (the curve stays drawable), and a
// window grown back to the full bounds normalises to null (un-zoomed), so the hint/Reset row recovers by
// pinching out too.
private suspend fun PointerInputScope.hrChartTransformGestures(
    buckets: List<HrBucket>,
    bounds: LongRange,
    window: () -> LongRange?,
    onWindow: (LongRange?) -> Unit,
) {
    // Two 5-minute buckets: the tightest window that still draws a line segment.
    val minSpanSeconds = 600L
    var lastTapAtMs = 0L
    var lastTapPos = Offset.Zero
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        var claimed = false   // ours: a pinch, or a horizontal pan while zoomed
        var ceded = false     // vertical-dominant: the feed's scroll owns it, just watch for the lift
        var moved = false
        var totalX = 0f
        var totalY = 0f
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            if (event.changes.none { it.pressed }) {
                // Lift-off. A short motionless single tap feeds the double-tap reset, only meaningful
                // while zoomed (the un-zoomed chart has nothing to reset, mirroring the iOS isZoomed
                // guard), and never consumed, so the LineChart's single-tap inspect keeps working.
                val up = event.changes.first()
                if (!claimed && !ceded && !moved && window() != null) {
                    val upAtMs = up.uptimeMillis
                    val isDoubleTap = upAtMs - lastTapAtMs <= viewConfiguration.doubleTapTimeoutMillis &&
                        (up.position - lastTapPos).getDistance() <= viewConfiguration.touchSlop * 4
                    if (isDoubleTap) {
                        onWindow(null)
                        lastTapAtMs = 0L
                    } else {
                        lastTapAtMs = upAtMs
                        lastTapPos = up.position
                    }
                }
                break
            }
            if (ceded) continue
            if (!claimed) {
                if (event.changes.count { it.pressed } > 1) {
                    claimed = true
                } else {
                    val pan = event.calculatePan()
                    totalX += pan.x
                    totalY += pan.y
                    if (abs(totalY) > viewConfiguration.touchSlop && abs(totalY) > abs(totalX)) {
                        ceded = true
                        moved = true
                        continue
                    }
                    if (abs(totalX) > viewConfiguration.touchSlop) {
                        moved = true
                        if (window() != null) claimed = true
                    }
                }
            }
            if (!claimed) continue
            val zoomChange = event.calculateZoom()
            val panChange = event.calculatePan()
            val width = size.width.toFloat().coerceAtLeast(1f)
            var w = window() ?: bounds
            if (zoomChange != 1f) {
                val frac = (event.calculateCentroid().x / width).coerceIn(0f, 1f)
                w = zoomedWindow(w, zoomChange, frac, bounds, minSpan = minSpanSeconds)
            }
            if (panChange.x != 0f) {
                val secPerPx = (w.last - w.first).toDouble() / width
                w = pannedWindow(w, (-panChange.x * secPerPx).toLong(), bounds)
            }
            if (buckets.count { it.bucket in w } >= 2) {
                onWindow(if (w.first <= bounds.first && w.last >= bounds.last) null else w)
            }
            event.changes.forEach { if (it.positionChanged()) it.consume() }
        }
    }
}

// MARK: - Overview HR chart (WHOOP-style day-in-review annotations)
//
// The 24h HR line, the shared index-spaced [LineChart], with marker layers drawn ON TOP:
//   (a) a sleep band shading the night's sleep span (indigo, behind the line conceptually but
//       drawn under the marker chrome so labels stay legible),
//   (b) a dashed Charge rule + label at wake time (sleep end), hidden while recovery calibrates,
//   (c) a dashed Effort rule + label at "now" (the latest sample), routed through the SAME
//       UnitFormatter.effortDisplay the Effort tile uses so it honours the 0–100 / 0–21 toggle (#268),
//   (d) a small sport glyph at each workout's in-window HR peak.
//
// LineChart plots points by LIST INDEX (evenly spaced, no time axis), so each marker's wall-clock
// time is mapped to a fractional list index by interpolating against the buckets' own timestamps, // markers then sit exactly on the rendered curve even when the strap history has gaps. Every layer
// self-hides when its data is absent (no sleep, calibrating Charge, no workouts). Mirrors the macOS
// OverviewHRChart (Packages/StrandDesign) in NOOP's own colour language. (PR #285)

@Composable
private fun OverviewHRChart(
    buckets: List<HrBucket>,
    bpm: List<Double>,
    sleep: SleepSession?,
    workouts: List<WorkoutRow>,
    recovery: Double?,
    strain: Double?,
    effortScale: EffortScale,
    modifier: Modifier,
    // Round wall-clock (epochSec, "HH:mm") ticks, each drawn as a dotted gridline under the curve.
    // The matching labels render OUTSIDE this plot-height composable (HrTimeAxisLabels), sharing
    // the same tick list + timestamp mapping so they align. Empty = no gridlines.
    timeTicks: List<Pair<Long, String>> = emptyList(),
) {
    // The line itself stays the existing shared component, unchanged, markers are a sibling overlay.
    val bucketTimestamps = remember(buckets) { buckets.map { it.bucket } }
    val minV = bpm.min()
    val maxV = bpm.max()
    val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
    val n = bpm.size

    // Geometry constants copied verbatim from LineChart/pointsFor so overlay positions land on the curve.
    val strokePx = 2.5f
    val topPad = strokePx + 4f
    val bottomPad = strokePx + 4f

    // Plot pixel size, captured from the Box that wraps both the line and the overlay.
    var plotW by remember { mutableStateOf(0f) }
    var plotH by remember { mutableStateOf(0f) }
    val density = LocalDensity.current

    // ── time → x helpers ──
    // Fractional list index for a wall-clock unix-seconds time, interpolating between bucket
    // timestamps; null when the time falls outside the loaded buckets.
    fun fracIndexFor(ts: Long): Float? {
        if (n < 2) return null
        val first = buckets.first().bucket
        val last = buckets.last().bucket
        if (ts <= first) return 0f
        if (ts >= last) return (n - 1).toFloat()
        val hi = buckets.indexOfFirst { it.bucket >= ts }
        if (hi <= 0) return 0f
        val lo = hi - 1
        val t0 = buckets[lo].bucket
        val t1 = buckets[hi].bucket
        val f = if (t1 > t0) (ts - t0).toFloat() / (t1 - t0).toFloat() else 0f
        return lo + f
    }
    fun xFor(ts: Long): Float? {
        val fi = fracIndexFor(ts) ?: return null
        return if (n > 1) plotW * fi / (n - 1) else null
    }
    // Strict variant for POINT markers (charge pill, peak, effort-now rule): null when the time
    // falls outside the RENDERED buckets, so a zoomed window hides out-of-window marks exactly like
    // iOS clips them, instead of pinning them to the window edge. The sleep BAND keeps the clamping
    // xFor: clamping a range to the visible window is the correct behaviour for a span.
    fun xForStrict(ts: Long): Float? {
        if (n < 2) return null
        if (ts < buckets.first().bucket || ts > buckets.last().bucket) return null
        return xFor(ts)
    }
    fun yForBpm(v: Double): Float {
        val usableH = (plotH - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((v - minV) / span).toFloat().coerceIn(0f, 1f)
        return topPad + (1f - norm) * usableH
    }

    // ── derived marker model (self-hiding) ──
    // Sleep band span clamped to the window; only drawn when it overlaps a visible stretch. Uses the
    // EFFECTIVE onset so a hand-edited bedtime moves the band. (PR #395)
    val sleepStartX = sleep?.let { xFor(it.effectiveStartTs) }
    val sleepEndX = sleep?.let { xFor(it.endTs) }
    // Charge marker sits at wake (sleep end), else the window start; hidden while recovery is null.
    val chargeX = recovery?.let { sleep?.let { s -> xForStrict(s.endTs) } }
    // Effort marker pinned to the latest sample (right edge) when a strain exists.
    val effortX = strain?.let { if (n > 1) plotW else null }

    // One combined TalkBack description for the overlay layers, so the markers (which are otherwise
    // small decorative pills) are announced. Only mentions the layers actually present.
    val markerDescription = remember(sleep, recovery, strain, workouts, effortScale) {
        buildList {
            add("24-hour heart rate")
            if (sleep != null) add("sleep band ${hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())}")
            if (recovery != null) add("${recovery.roundToInt()} percent Recovery at wake")
            if (strain != null) add("${UnitFormatter.effortDisplay(strain, effortScale)} Effort now")
            if (workouts.isNotEmpty()) add("${workouts.size} workout${if (workouts.size == 1) "" else "s"} marked")
        }.joinToString(", ")
    }

    Box(
        modifier = modifier
            .clipToBounds()
            .onSizeChanged { plotW = it.width.toFloat(); plotH = it.height.toFloat() }
            .semantics { contentDescription = markerDescription },
    ) {
        // #765 (z-order / background layering): the sleep band must sit BEHIND the HR curve, matching the
        // iOS OverviewHRChart whose RectangleMark is "drawn first so the HR line/area sit on top". Android
        // previously drew the band in the SAME Canvas as the dashed rules, AFTER the LineChart, so the
        // translucent indigo region washed OVER the HR line + its value markers (the reported "text behind
        // the chart" / muddied curve). Splitting the band into its OWN Canvas placed BEFORE the LineChart
        // puts it under the curve, exactly like iOS; the wake divider, Charge/Effort rules and glow end-cap
        // stay in the Canvas AFTER the line (iOS draws those marks after the LineMark too, so they read on
        // top). Only the fill moved; same geometry, same colours.
        // Dotted round-time gridlines, FIRST so everything (band, curve, markers) reads over them.
        if (plotW > 0f && plotH > 0f && timeTicks.isNotEmpty()) {
            val gridDash = remember { PathEffect.dashPathEffect(floatArrayOf(4f, 6f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                timeTicks.forEach { (ts, _) ->
                    val frac = timestampFraction(bucketTimestamps, ts) ?: return@forEach
                    val x = frac * size.width
                    drawLine(
                        color = Palette.hairline,
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1f,
                        pathEffect = gridDash,
                    )
                }
            }
        }
        if (plotW > 0f && plotH > 0f &&
            sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawRect(
                    color = Palette.sleepDeep.copy(alpha = 0.30f),
                    topLeft = Offset(sleepStartX, 0f),
                    size = Size(sleepEndX - sleepStartX, size.height),
                )
            }
        }

        // 1) The HR line (unchanged shared component, tap-to-inspect intact). Sits OVER the sleep band
        // (above) and UNDER the dashed rules + glow end-cap + marker pills (below), mirroring iOS.
        LineChart(
            values = bpm,
            modifier = Modifier.fillMaxSize(),
            color = Palette.metricRose,
            fill = true,
            selectionEnabled = true,
            // Scrub read-out: the timestamps prefix the sample's local clock time and the #463
            // formatter carries the unit - "14:32 · 87 bpm" instead of a bare "87".
            formatValue = { "${it.roundToInt()} bpm" },
            timestamps = bucketTimestamps,
        )

        // 2) Wake divider + dashed rules + glow end-cap, drawn in one Canvas ON TOP of the line.
        if (plotW > 0f && plotH > 0f) {
            val dash = remember { PathEffect.dashPathEffect(floatArrayOf(8f, 8f), 0f) }
            val wakeDash = remember { PathEffect.dashPathEffect(floatArrayOf(3f, 3f), 0f) }
            Canvas(modifier = Modifier.fillMaxSize()) {
                // Wake divider: the sleep-to-day boundary, so the band reads even before Charge calibrates.
                // On top of the line (matching iOS's wake RuleMark after the LineMark).
                if (sleepStartX != null && sleepEndX != null && sleepEndX > sleepStartX &&
                    sleepEndX > 0f && sleepEndX < size.width) {
                    drawLine(
                        color = Palette.sleepLight.copy(alpha = 0.5f),
                        start = Offset(sleepEndX, 0f),
                        end = Offset(sleepEndX, size.height),
                        strokeWidth = 1f,
                        pathEffect = wakeDash,
                    )
                }
                // Charge rule at wake.
                if (chargeX != null) {
                    drawLine(
                        color = Palette.recoveryColor(recovery).copy(alpha = 0.85f),
                        start = Offset(chargeX.coerceIn(0f, size.width), 0f),
                        end = Offset(chargeX.coerceIn(0f, size.width), size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }
                // Effort rule at now.
                if (effortX != null) {
                    val x = (size.width - 1f).coerceIn(0f, size.width)
                    drawLine(
                        color = Palette.effortTint(strain / StrainScorer.maxStrain).copy(alpha = 0.85f),
                        start = Offset(x, 0f),
                        end = Offset(x, size.height),
                        strokeWidth = 1.5f,
                        cap = StrokeCap.Round,
                        pathEffect = dash,
                    )
                }

                // Glowing endpoint at the latest HR sample (right edge), a Bevel chart end-cap:
                // a soft rose halo + white core sitting on the line's final point.
                if (n >= 2) {
                    val lastX = size.width
                    val lastY = yForBpm(bpm.last())
                    val end = Offset(lastX.coerceIn(0f, size.width), lastY)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.30f), radius = 9f, center = end)
                    drawCircle(color = Palette.metricRose.copy(alpha = 0.65f), radius = 5.5f, center = end)
                    drawCircle(color = Palette.tipCore, radius = 2.4f, center = end)
                }
            }

            // 3) Marker labels + sport glyphs, positioned composables (crisp text/icons vs Canvas).
            val topPadDp = 10.dp
            // Sleep duration pill at the band's leading edge.
            if (sleepStartX != null && (sleepEndX ?: 0f) > (sleepStartX)) {
                val durLabel = hrHoursMinutes((sleep.endTs - sleep.effectiveStartTs).toInt())
                ChartMarkerPill(
                    text = durLabel,
                    color = Palette.sleepLight,
                    leadingIcon = Icons.Filled.Bedtime,
                    modifier = Modifier.markerOffset(sleepStartX, density, topPadDp),
                )
            }
            if (chargeX != null) {
                ChartMarkerPill(
                    text = uiString(R.string.l10n_today_screen_recovery_roundtoint_charge_92fbaa5e, recovery.roundToInt()),
                    color = Palette.recoveryColor(recovery),
                    modifier = Modifier.markerOffset(chargeX, density, topPadDp),
                )
            }
            if (effortX != null) {
                ChartMarkerPill(
                    text = uiString(R.string.l10n_today_screen_unitformatter_effortdisplay_strain_effortscale_effort_53dbd951, UnitFormatter.effortDisplay(strain, effortScale)),
                    color = Palette.effortTint(strain / StrainScorer.maxStrain),
                    modifier = Modifier.markerOffset(plotW, density, topPadDp, alignEnd = true),
                )
            }
            // Sport glyph at each workout's in-window HR peak.
            workouts.forEach { w ->
                val peak = hrPeakIn(buckets, w.startTs, w.endTs)
                if (peak != null) {
                    val px = xForStrict(peak.bucket)
                    if (px != null) {
                        val py = yForBpm(peak.avgBpm)
                        WorkoutGlyph(
                            icon = sportIcon(w.sport),
                            modifier = Modifier.glyphOffset(px, py, plotW, plotH, density),
                        )
                    }
                }
            }
        }
    }
}

/** "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06"). Mirrors TodayView.hoursMinutes. */
private fun hrHoursMinutes(seconds: Int): String {
    val h = (if (seconds < 0) 0 else seconds) / 3600
    val m = ((if (seconds < 0) 0 else seconds) % 3600) / 60
    return "$h:${m.toString().padStart(2, '0')}"
}

/** The peak HR bucket whose timestamp falls inside [start, end]; null when none overlap. */
private fun hrPeakIn(buckets: List<HrBucket>, start: Long, end: Long): HrBucket? =
    buckets.filter { it.bucket in start..end }.maxByOrNull { it.avgBpm }

/** Offset a marker pill near plot-x [x] (px). End-aligned markers (Effort) tuck under the right
 *  edge; the rest centre roughly on their anchor. Coerced to ≥ 0 so a pill never starts off-screen. */
private fun Modifier.markerOffset(
    x: Float,
    density: androidx.compose.ui.unit.Density,
    topPad: androidx.compose.ui.unit.Dp,
    alignEnd: Boolean = false,
): Modifier = this.offset(
    x = with(density) {
        // Approx pill half-width for edge clamping (footnote ≈ 7px/char + chrome).
        val xDp = x.toDp()
        if (alignEnd) (xDp - 70.dp).coerceAtLeast(0.dp) else (xDp - 36.dp).coerceAtLeast(0.dp)
    },
    y = topPad,
)

/** Position a 22dp sport glyph centred on a plot point (px), clamped inside the plot. */
private fun Modifier.glyphOffset(
    x: Float,
    y: Float,
    plotW: Float,
    plotH: Float,
    density: androidx.compose.ui.unit.Density,
): Modifier = this.offset(
    x = with(density) { (x.toDp() - 11.dp).coerceIn(0.dp, (plotW.toDp() - 22.dp).coerceAtLeast(0.dp)) },
    y = with(density) { (y.toDp() - 26.dp).coerceIn(0.dp, (plotH.toDp() - 22.dp).coerceAtLeast(0.dp)) },
)

/** Small caps read-out pill for the Charge / Effort / sleep-duration markers. */
@Composable
private fun ChartMarkerPill(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.surfaceOverlay.copy(alpha = 0.92f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = color, modifier = Modifier.size(10.dp))
        }
        Text(text, style = NoopType.footnote, color = color, maxLines = 1)
    }
}

/** Sport glyph in a tinted badge, anchored above a workout's HR peak. */
@Composable
private fun WorkoutGlyph(icon: ImageVector, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(22.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.strain033),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(13.dp),
        )
    }
}

// MARK: - Today footer sections

@Composable
private fun TodayWorkoutsSection(workouts: List<WorkoutRow>) {
    // Single column, newest first: the 2x2 grid truncated durations on narrow phones and read as
    // unrelated stat tiles rather than a chronological feed. Full-width tiles have room for the
    // kcal chip, so the #332 compactDelta workaround is no longer needed here.
    val feed = lastWorkoutsFeed(workouts)
    if (feed.isEmpty()) return

    // "Latest Workouts", not "Last": "Last" read as "final". Mirrored on iOS (TodayView). Lives in
    // strings.xml (values + values-de) so the header is localizable like the nav labels.
    SectionHeader(stringResource(R.string.today_latest_workouts), overline = "Activity", trailing = "14 days")
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        feed.forEach { workout ->
            StatTile(
                modifier = Modifier.fillMaxWidth(),
                label = WorkoutEditing.displaySport(workout.sport),
                value = workoutDuration(workout),
                caption = workoutCaption(workout),
                accent = workout.strain?.let { Palette.effortTint(it / StrainScorer.maxStrain) } ?: Palette.textPrimary,
                delta = workout.energyKcal?.let { "${it.roundToInt()} kcal" },
                deltaColor = Palette.metricAmber,
            )
        }
    }
}

@Composable
private fun TodaySourcesSectionLive(
    viewModel: AppViewModel,
    footer: TodayFooterState,
    strapBatteryPct: Int? = null,
    strapBatteryEstimate: String? = null,
    expanded: Boolean = true,
    onToggle: () -> Unit = {},
) {
    val status by viewModel.historySyncStatus.collectAsStateWithLifecycle()
    TodaySourcesSection(
        footer = footer,
        strapBatteryPct = strapBatteryPct,
        strapBatteryEstimate = strapBatteryEstimate,
        bandBackfilling = status.backfilling,
        bandSyncBatches = status.batches,
        bandSyncRows = status.rows,
        bandSyncNewestAt = status.newestDataUnix,
        bandSyncStartedAt = status.startedAt,
        bandSyncLastDurableProgressAt = status.lastDurableProgressAt,
        expanded = expanded,
        onToggle = onToggle,
    )
}

@Composable
private fun TodaySourcesSection(
    footer: TodayFooterState,
    strapBatteryPct: Int? = null,
    strapBatteryEstimate: String? = null,
    bandBackfilling: Boolean = false,
    bandSyncBatches: Int = 0,
    bandSyncRows: Int = 0,
    bandSyncNewestAt: Long? = null,
    bandSyncStartedAt: Long? = null,
    bandSyncLastDurableProgressAt: Long? = null,
    // S5: collapse to a single "Synced from: ..." summary line by default; tapping expands the full
    // per-source rows + strap battery inline. Nothing is removed, only folded behind a tap.
    expanded: Boolean = true,
    onToggle: () -> Unit = {},
) {
    SectionHeader("Data Sources", overline = "Provenance")
    Spacer(Modifier.height(Metrics.gap))
    val whoopPresent = (footer.whoopDays ?: 0) > 0 || strapBatteryPct != null || bandBackfilling
    val applePresent = (footer.appleDays ?: 0) > 0 || (footer.appleWorkouts ?: 0) > 0
    val hcPresent = (footer.hcDays ?: 0) > 0 || (footer.hcWorkouts ?: 0) > 0
    var syncNow by remember(bandBackfilling, bandSyncStartedAt, bandSyncLastDurableProgressAt) {
        mutableStateOf(System.currentTimeMillis() / 1_000L)
    }
    LaunchedEffect(bandBackfilling, bandSyncStartedAt, bandSyncLastDurableProgressAt) {
        while (bandBackfilling) {
            kotlinx.coroutines.delay(1_000)
            syncNow = System.currentTimeMillis() / 1_000L
        }
    }
    val bandSyncDetail = if (bandBackfilling && bandSyncRows > 0) {
        val newestDate = bandSyncNewestAt?.let { unix ->
            Instant.ofEpochSecond(unix)
                .atZone(ZoneId.systemDefault())
                .toLocalDate()
                .format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault()))
        }
        if (newestDate != null) {
            stringResource(R.string.appwide_today_band_sync_rows_ready_format, bandSyncRows, newestDate)
        } else {
            stringResource(R.string.appwide_today_band_sync_rows_format, bandSyncRows)
        }
    } else {
        null
    }
    val bandSyncActivityDetail = if (bandBackfilling) {
        val activity = com.noop.ble.HistorySyncDurableProgressPolicy.activity(
            startedAt = bandSyncStartedAt,
            lastDurableProgressAt = bandSyncLastDurableProgressAt,
            now = syncNow,
        )
        val label = when (activity) {
            com.noop.ble.HistorySyncProgressActivity.STARTING ->
                stringResource(R.string.appwide_today_band_sync_activity_starting)
            com.noop.ble.HistorySyncProgressActivity.ADVANCING ->
                stringResource(R.string.appwide_today_band_sync_activity_advancing)
            com.noop.ble.HistorySyncProgressActivity.WAITING ->
                stringResource(R.string.appwide_today_band_sync_activity_waiting)
            com.noop.ble.HistorySyncProgressActivity.STALLED ->
                stringResource(R.string.appwide_today_band_sync_activity_stalled)
        }
        val elapsed = elapsedClock((syncNow - (bandSyncStartedAt ?: syncNow)).coerceAtLeast(0))
        label + " · " + stringResource(R.string.appwide_today_band_sync_elapsed_format, elapsed)
    } else {
        null
    }
    val combinedBandSyncDetail = listOfNotNull(bandSyncActivityDetail, bandSyncDetail)
        .takeIf { it.isNotEmpty() }
        ?.joinToString("\n")
    if (!expanded) {
        // Collapsed: one tappable "Synced from: ..." line. Each source is named for what it is -
        // Health Connect must NOT fold under "Apple Watch" (issue #176: Health-Connect-only users
        // saw "Synced from: Apple Watch"); the expanded card lists every source by name too.
        val collapsedInteraction = remember { MutableInteractionSource() }
        NoopCard(
            modifier = Modifier
                .fillMaxWidth()
                .liquidPress(collapsedInteraction)
                .clickable(
                    interactionSource = collapsedInteraction,
                    indication = null,
                    onClickLabel = "Show what NOOP is synced from",
                    onClick = onToggle,
                ),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    syncedFromSummary(hasWhoop = whoopPresent, hasApple = applePresent, hasHealthConnect = hcPresent, hasXiaomi = false),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        return
    }
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // A header row to collapse it back, an obvious "less" cue on the expanded card.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClickLabel = "Hide data source detail", onClick = onToggle),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(uiString(R.string.l10n_today_screen_synced_from_2aa7258b), style = NoopType.overline, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                Icon(
                    Icons.Filled.KeyboardArrowUp,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(16.dp),
                )
            }
            Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            SourceRow(
                badge = "Noop Band",
                tint = Palette.accent,
                // A live battery reading means the strap IS connected, even before the first banked
                // night, don't contradict it with "Not connected" (#159).
                present = whoopPresent,
                detail = if (bandBackfilling) {
                    if (bandSyncBatches > 0) {
                        stringResource(R.string.appwide_today_band_sync_batches_format, bandSyncBatches)
                    } else {
                        stringResource(R.string.appwide_today_band_sync_syncing)
                    }
                } else {
                    countDetail(footer.whoopDays, footer.whoopWorkouts, "workouts")
                },
                batteryPct = strapBatteryPct,
                batteryEstimate = strapBatteryEstimate,
                statusDetail = combinedBandSyncDetail,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Apple Health",
                tint = Palette.metricCyan,
                present = applePresent,
                detail = countDetail(footer.appleDays, footer.appleWorkouts, "workouts"),
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            SourceRow(
                badge = "Health Connect",
                tint = Palette.metricPurple,
                present = hcPresent,
                detail = countDetail(footer.hcDays, footer.hcWorkouts, "workouts"),
            )
        }
    }
}

@Composable
private fun SourceRow(
    badge: String,
    tint: Color,
    present: Boolean,
    detail: String,
    batteryPct: Int? = null,
    batteryEstimate: String? = null,
    statusDetail: String? = null,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SourceBadge(badge, tint = if (present) tint else Palette.textTertiary)
            // Compact strap-battery readout beside the source badge, same pill + tone bands as the
            // Settings Strap section; absent entirely when there's no live reading (#159).
            batteryPct?.let { pct ->
                Spacer(Modifier.width(8.dp))
                StatePill(title = uiString(R.string.l10n_today_screen_pct_ee63e247, pct), tone = batteryPillTone(pct), showsDot = false)
                // The "~X left" runtime estimate sits beside the %, dimmer, only when we have a trusted one (#713).
                batteryEstimate?.let { est ->
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = est,
                        style = NoopType.captionNumber,
                        color = Palette.textTertiary,
                        maxLines = 1,
                    )
                }
            }
            Spacer(Modifier.weight(1f))
            Text(
                text = if (present) detail else "Not connected",
                style = NoopType.captionNumber,
                color = if (present) Palette.textSecondary else Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        statusDetail?.let {
            Text(
                text = it,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.End,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

// MARK: - Readiness card (ported from TodayView.swift readinessSection)
//
// On-device training-readiness synthesis. Calls the analytics ReadinessEngine over the
// view model's day history and renders the macOS card: a colored level dot + headline,
// the plain-English summary, then one row per driving signal (a small flag-colored dot +
// label + detail). The whole card is suppressed until there is enough history
// (level == INSUFFICIENT), matching macOS.

@Composable
private fun ReadinessSection(days: List<DailyMetric>, carriedDay: DailyMetric? = null) {
    // Logical day (rolls at 04:00 local), so readiness keeps reading the evening's row in the small
    // hours instead of an empty new-calendar-day row (#144). Mirrors the Today-row resolution.
    //
    // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Right after the
    // rollover today has no scored row, so `evaluate` would read INSUFFICIENT and the whole card would
    // VANISH while live HR ticks, the same blank the carried Charge/Synthesis avoid. So when carrying,
    // anchor on the last scored day's key instead, and stamp the overline "Last night · <date>". Honest:
    // it's the real prior read; today's own readiness wins the instant tonight is scored.
    val anchorKey = carriedDay?.day ?: logicalDayKeyNow()
    val readiness = remember(days, anchorKey) { ReadinessEngine.evaluate(days, today = anchorKey) }
    if (readiness.level == ReadinessEngine.Level.INSUFFICIENT) return
    val readinessHeadline = localizedReadinessHeadline(readiness)
    val readinessSummary = localizedReadinessSummary(readiness)

    val overline = carriedDay?.let { carriedCaption(it.day) } ?: "How your signals compare"
    SectionHeader("Readiness", overline = overline)
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // Headline row: level dot + headline.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(readinessColor(readiness.level)),
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    readinessHeadline,
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
            }

            // Plain-English summary.
            Text(
                readinessSummary,
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )

            // Per-signal rows: flag dot + fixed-width label + detail.
            if (readiness.signals.isNotEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(Palette.hairline),
                )
                readiness.signals.forEach { signal ->
                    Row(verticalAlignment = Alignment.Top) {
                        Box(
                            modifier = Modifier
                                .padding(top = 5.dp)
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(flagColor(signal.flag)),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            signal.label,
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                            modifier = Modifier.width(104.dp),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(1.dp),
                        ) {
                            Text(
                                signal.detail,
                                style = NoopType.caption,
                                color = Palette.textTertiary,
                            )
                            // The numbers behind the read (e.g. "48 vs 55 ms"), as a small mono caption,                             // mirrors the macOS readiness card and the "load X.XX" numeric readout above.
                            signal.evidence?.let { evidence ->
                                Text(
                                    evidence,
                                    style = NoopType.captionNumber,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Level → color, mirroring TodayView.readinessColor. */
private fun readinessColor(level: ReadinessEngine.Level): Color = when (level) {
    ReadinessEngine.Level.PRIMED -> Palette.accent
    ReadinessEngine.Level.BALANCED -> Palette.statusPositive
    ReadinessEngine.Level.STRAINED -> Palette.statusWarning
    ReadinessEngine.Level.RUNDOWN -> Palette.metricRose
    ReadinessEngine.Level.INSUFFICIENT -> Palette.textTertiary
}

/** Flag → color, mirroring TodayView.flagColor. */
private fun flagColor(flag: ReadinessEngine.Flag): Color = when (flag) {
    ReadinessEngine.Flag.GOOD -> Palette.accent
    ReadinessEngine.Flag.NEUTRAL -> Palette.textTertiary
    ReadinessEngine.Flag.WATCH -> Palette.statusWarning
    ReadinessEngine.Flag.BAD -> Palette.metricRose
}

/**
 * #316 / @63, map a step-sample activity class (0=still, 1=walk, 2=run) to the still/walk/run icon + an
 * accessibility label. Mirrors the iOS Steps-tile glyph set (figure.stand / figure.walk / figure.run) and
 * semantics exactly (cross-platform parity). Returns (null, "") for any other code so an unmapped value
 * shows nothing rather than a wrong glyph.
 */
private fun stepActivityIconFor(activityClass: Int): Pair<ImageVector?, String> = when (activityClass) {
    0 -> Icons.Filled.Accessibility to "Still"
    1 -> Icons.AutoMirrored.Filled.DirectionsWalk to "Walking"
    2 -> Icons.AutoMirrored.Filled.DirectionsRun to "Running"
    else -> null to ""
}

// MARK: - SparkStatTile
//
// A fixed-height metric tile: overline label, big value + caption, and a 14-day
// Sparkline anchored along the bottom edge. Mirrors the macOS StatTile-with-sparkline
// while reusing the locked surfaces/typography (NoopCard, Overline, NoopType). Built
// here rather than mutating the shared StatTile so other screens keep the plain tile.

@Composable
private fun SparkStatTile(
    label: String,
    value: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    accent: Color = Palette.textPrimary,
    spark: List<Double> = emptyList(),
    sparkColor: Color = Palette.accent,
    onInfo: (() -> Unit)? = null,
    badge: String? = null,
    // #316 / @63, an optional activity-class code (0=still, 1=walk, 2=run) rendered as a small still/walk/run
    // glyph in the label row, tinted with the tile accent. null = no icon. Used by the Steps tile.
    trailingIcon: Int? = null,
) {
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14) {
        Column(modifier = Modifier.fillMaxWidth()) {
            // Label row carries the overline, an optional low-confidence [badge] (H9, e.g. "Estimated"
            // stages), an optional activity glyph ([trailingIcon], #316), and, for the three headline scores
            // only, a trailing ⓘ that opens the scoring guide at this score. Other tiles render as before.
            if (onInfo != null || badge != null || trailingIcon != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Overline(label)
                    if (badge != null) {
                        Spacer(Modifier.width(Metrics.space6))
                        // A tertiary-tinted pill, honest "this is estimated, not measured" signal, the same
                        // muted treatment as a provenance badge so it informs without alarming. (H9)
                        SourceBadge(badge, tint = Palette.textTertiary)
                    }
                    Spacer(Modifier.weight(1f))
                    // #316, still/walk/run glyph, before the optional ⓘ. Self-hides for an unknown code.
                    if (trailingIcon != null) {
                        val (vector, desc) = stepActivityIconFor(trailingIcon)
                        if (vector != null) {
                            Icon(
                                vector,
                                contentDescription = desc,
                                tint = accent,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                    if (onInfo != null) ScoreInfoButton(section = null, onClick = onInfo, compact = true)
                }
            } else {
                Overline(label)
            }
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    // Shrink-to-fit (down to 0.6×) so a value never ellipsizes to "100%"→"10…" /
                    // "15.5"→"15…" next to the inline sparkline, matching the Swift tile's
                    // minimumScaleFactor (#332). fillMaxWidth() is load-bearing: AutoSizeValue only
                    // shrinks when its Text is given a hard width to overflow against, without it the
                    // single-line Text takes its intrinsic width, `didOverflowWidth` never trips, and
                    // the value silently truncates at full size. The plain StatTile worked because it
                    // passes weight(1f) (a hard width); this column-child needs fillMaxWidth instead.
                    AutoSizeValue(
                        value,
                        style = NoopType.tileValueLarge,
                        color = accent,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (caption != null) {
                        Text(
                            caption,
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.padding(top = Metrics.space2),
                        )
                    }
                }
                if (spark.size >= 2) {
                    // Sparkline forces fillMaxWidth + a fixed height internally, so we
                    // bound it in a sized Box to keep it a compact inline trend.
                    SparkTailBox(wide = true) {
                        Sparkline(values = spark, color = sparkColor)
                    }
                }
            }
        }
    }
}

// MARK: - Illness banner (ported from HealthAlertBanner.swift)

@Composable
private fun IllnessBanner(
    message: String,
    alreadyUnwell: Boolean,
    onOpen: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(tint = DAILY_SIGNAL_ALERT_TINT, cornerRadius = Metrics.cardRadius)
            .clickable(onClick = onOpen)
            .padding(Metrics.space14),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(DAILY_SIGNAL_ALERT_TINT.copy(alpha = StrandAlpha.warningFill)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.MonitorHeart, contentDescription = null, tint = DAILY_SIGNAL_ALERT_TINT)
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                if (alreadyUnwell) {
                    uiString(R.string.appwide_daily_signal_alert_unwell_title)
                } else {
                    uiString(R.string.appwide_daily_signal_alert_title)
                },
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(message, style = NoopType.subhead, color = Palette.textSecondary)
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    uiString(R.string.appwide_daily_signal_alert_review),
                    style = NoopType.footnote,
                    color = DAILY_SIGNAL_ALERT_TINT,
                )
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = DAILY_SIGNAL_ALERT_TINT,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
    }
}

// MARK: - 14-day sparkline windows (built from recentDays)

/** The trailing-window series for each tile, oldest → newest. */
private data class Window(
    val recovery: List<Double>,
    val strain: List<Double>,
    val sleepMin: List<Double>,
    val hrv: List<Double>,
    val rhr: List<Double>,
    val spo2: List<Double>,
    val resp: List<Double>,
    // #616: the Steps tile carried no `spark` series, so it drew no trend line while every other tile did.
    // On-device DailyMetric.steps (the strap @57 motion-derived estimate) — the same signal the Steps tile VALUE reads
    // (on-device-first), matching iOS kSparks "steps". (Calories is imported-first, so its spark is threaded
    // separately as caloriesSpark, not read off a DailyMetric column here.)
    val steps: List<Double>,
)

private data class ResolvedSpo2Window(
    val anchorDay: String = "",
    val values: Map<String, Double> = emptyMap(),
)

/**
 * Build the trailing trend windows from `recentDays` over the chosen span (2 / 7 / 14 calendar days —
 * the editor's detailed-graph window). Each series drops null days from the trailing calendar window
 * only, so stale imports do not draw a current-day trend.
 */
@Composable
private fun rememberTrendWindow(
    days: List<com.noop.data.DailyMetric>,
    anchorDay: LocalDate,
    windowDays: Int,
    importedStepsByDay: Map<String, Int> = emptyMap(),
    calibratedStepsByDay: Map<String, Int> = emptyMap(),
    resolvedSpo2ByDay: Map<String, Double> = emptyMap(),
): Window =
    androidx.compose.runtime.remember(
        days, anchorDay, windowDays, importedStepsByDay, calibratedStepsByDay, resolvedSpo2ByDay,
    ) {
        // Trailing CALENDAR days ending today, NOT the last N stored rows, which on an old import
        // were months-old data shown as a fresh trend (issue #23). ISO yyyy-MM-dd sorts chronologically.
        val cutoff = anchorDay.minusDays((windowDays - 1).toLong()).toString()
        val end = anchorDay.toString()
        val recent = days.filter { it.day >= cutoff && it.day <= end }
        fun series(pick: (DailyMetric) -> Double?): List<Double> = recent.mapNotNull(pick)
        val motionStepsByDay = recent.mapNotNull { row -> row.steps?.let { row.day to it } }.toMap()
        val measuredWindow = importedStepsByDay.filterKeys { it >= cutoff && it <= end }
        val calibratedWindow = calibratedStepsByDay.filterKeys { it >= cutoff && it <= end }
        Window(
            recovery = series { it.recovery },
            strain = series { it.strain },
            sleepMin = series { it.totalSleepMin },
            hrv = series { it.avgHrv },
            rhr = series { it.restingHr?.toDouble() },
            spo2 = resolvedSpo2ByDay.entries
                .filter { it.key in cutoff..end }
                .sortedBy { it.key }
                .map { it.value }
                .ifEmpty { series { it.spo2Pct } },
            resp = series { it.respRateBpm },
            steps = resolvedStepsSeries(measuredWindow, motionStepsByDay, calibratedWindow).map { it.second },
        )
    }

// MARK: - Derived text (ported from TodayView.swift)

private fun greetingWord(): String {
    val h = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)
    return when {
        h < 12 -> uiString(R.string.appwide_today_greeting_morning)
        h < 17 -> uiString(R.string.appwide_today_greeting_afternoon)
        else -> uiString(R.string.appwide_today_greeting_evening)
    }
}

private fun synthesisWord(score: Double?): String {
    if (score == null) return "No Data"
    return when {
        score < 25 -> "Depleted"
        score < 50 -> "Low"
        score < 70 -> "Steady"
        score < 88 -> "Primed"
        else -> "Peak"
    }
}

private fun synthesisDetail(d: DailyMetric?): String {
    val rec = d?.recovery
        ?: return "No metrics yet. Import a wearable export or wear Noop Band to begin."
    val recPart = when {
        rec < 50 -> "Recovery is low"
        rec < 70 -> "Recovery is steady"
        else -> "Recovery is strong"
    }
    val sleepPart = d.totalSleepMin?.let { mins ->
        if (mins / 60.0 >= 7) " and sleep was consistent" else " but sleep ran short"
    } ?: ""
    return "$recPart$sleepPart."
}

private fun sleepValue(d: DailyMetric?): String {
    val m = d?.totalSleepMin ?: return NO_DATA
    val total = m.roundToInt()
    return "${total / 60}h ${total % 60}m"
}

/**
 * The Rest tile's caption, hours-in-bed for the day, the figure that used to be the tile's VALUE
 * before #248 moved the Rest score there. Falls back to the efficiency read-out when no duration is
 * banked, and to null so the tile shows no caption line when neither exists. Mirrors macOS restCaption.
 */
private fun restCaption(d: DailyMetric?): String? = when {
    d?.totalSleepMin != null -> sleepValue(d)
    d?.efficiency != null -> String.format(Locale.US, "%.0f%% eff", d.efficiency)
    else -> null
}

/** Group-separated integer display from a Double (e.g. 12 345 steps), matching the Apple Health tiles. */
private fun intString(v: Double): String {
    val n = v.roundToInt()
    return if (kotlin.math.abs(n) >= 1000) String.format(Locale.US, "%,d", n) else "$n"
}

private const val NO_DATA = "No Data"

/** The dashboard-card placeholder for a baseline-relative metric (Stress) that is still seeding its window,  *  an honest "building your baseline" state rather than a bare dash (#706/#684). Rendered dimmed like NO_DATA. */
private const val STRESS_CALIBRATING = "Calibrating"

private val workoutDateFmt: DateTimeFormatter =
    DateTimeFormatter.ofPattern("d MMM", Locale.US).withZone(ZoneId.systemDefault())
private val workoutTimeFmt: DateTimeFormatter =
    // Respect the device's 12-/24-hour locale (#337): "7:10 AM" where 12-hour is preferred, "19:10"
    // where 24-hour is, instead of forcing 24-hour on everyone.
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

private fun countDetail(days: Int?, workouts: Int?, workoutLabel: String): String {
    if (days == null || workouts == null) return "Counting..."
    return "${grouped(days)} days · ${grouped(workouts)} $workoutLabel"
}

/** Same bands as the Settings Strap battery pill, so the % reads the same colour everywhere (#159). */
private fun batteryPillTone(pct: Int): StrandTone = when {
    pct <= 15 -> StrandTone.Critical
    pct <= 30 -> StrandTone.Warning
    else -> StrandTone.Positive
}

private fun workoutDuration(row: WorkoutRow): String {
    val seconds = row.durationS ?: (row.endTs - row.startTs).coerceAtLeast(0L).toDouble()
    if (seconds <= 0.0) return NO_DATA
    val totalMinutes = (seconds / 60.0).roundToInt()
    return if (totalMinutes >= 60) {
        "${totalMinutes / 60}h ${totalMinutes % 60}m"
    } else {
        "${totalMinutes}m"
    }
}

/** "d MMM · HH:mm–HH:mm" (#157); start-only when the end isn't after the start (zero/unknown span). */
private fun workoutCaption(row: WorkoutRow): String {
    val date = workoutDateFmt.format(Instant.ofEpochSecond(row.startTs))
    val start = workoutTimeFmt.format(Instant.ofEpochSecond(row.startTs))
    return if (row.endTs > row.startTs) {
        "$date · $start - ${workoutTimeFmt.format(Instant.ofEpochSecond(row.endTs))}"
    } else {
        "$date · $start"
    }
}

private fun grouped(value: Int): String =
    String.format(Locale.US, "%,d", value)

// MARK: - Key-Metrics layout editor (#251)
//
// A Today-local dialog for choosing which Key-Metric tiles lead the Control Center and in what order.
// Display-only: it edits the persisted `today.keyMetrics` pins, never any stored metric. Every tile remains
// visible; switches pin three to five, and explicit arrows reorder them consistently on every device.
// Mirrors the Apple KeyMetricsEditorSheet.

/** The Key-Metrics header's trailing label for the chosen detailed-graph window. */
private fun trendWindowLabel(days: Int): String = when (days) {
    2 -> "2-day trend"
    7 -> "7-day trend"
    else -> "14-day trend"
}

/** One editor row with its current pinned flag. The working list is rebuilt on each edit. */
private data class EditableMetric(val metric: KeyMetric, val enabled: Boolean)

@Composable
private fun KeyMetricsEditorDialog(
    initial: List<KeyMetric>,
    initialDetailed: Boolean = false,
    initialWindowDays: Int = 14,
    onDismiss: () -> Unit,
    onSave: (List<KeyMetric>, Boolean, Int) -> Unit,
) {
    // Detailed tiles: taller/squarer with a trend graph under the fill bar (display-only), over the
    // chosen trailing window (2 days / 1 week / 2 weeks).
    var detailed by remember { mutableStateOf(initialDetailed) }
    var windowDays by remember { mutableStateOf(initialWindowDays) }
    // Working copy: pinned tiles first in saved order, then the unpinned remainder in canonical order.
    val items = remember {
        val enabledSet = initial.toHashSet()
        mutableStateListOf<EditableMetric>().apply {
            initial.forEach { add(EditableMetric(it, true)) }
            KeyMetric.defaultOrder.filter { it !in enabledSet }.forEach { add(EditableMetric(it, false)) }
        }
    }
    val selectedCount = items.count { it.enabled }

    fun move(from: Int, to: Int) {
        if (from in items.indices && to in items.indices) {
            val item = items.removeAt(from)
            items.add(to, item)
        }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(
            color = Palette.surfaceOverlay,
            shape = RoundedCornerShape(16.dp),
        ) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(uiString(R.string.l10n_today_screen_edit_key_metrics_f95e61a4), style = NoopType.title2, color = Palette.textPrimary)
                    Text(
                        uiString(R.string.key_metrics_selection_instructions),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                    Text(
                        uiString(
                            R.string.key_metrics_selection_count,
                            selectedCount,
                            KeyMetricPrefs.MAX_SELECTION_COUNT,
                        ),
                        style = NoopType.captionNumber,
                        color = if (selectedCount == KeyMetricPrefs.MAX_SELECTION_COUNT) {
                            Palette.accent
                        } else {
                            Palette.textTertiary
                        },
                    )
                }

                // Detailed tiles: the tile-style option (compact ktile vs squarer tile + 14-day graph).
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(uiString(R.string.l10n_today_screen_detailed_tiles_0801721b), style = NoopType.body, color = Palette.textPrimary)
                        Text(
                            uiString(R.string.l10n_today_screen_squarer_tiles_with_a_trend_graph_3c297dec),
                            style = NoopType.caption,
                            color = Palette.textSecondary,
                        )
                    }
                    NoopToggleSwitch(
                        checked = detailed,
                        onCheckedChange = { detailed = it },
                        modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_today_screen_detailed_tiles_0801721b) },
                    )
                }
                // The detailed graphs' trailing window — 2 days / 1 week / 2 weeks (the NOOP signature
                // segmented pill, same control the trend screens use). Only shown while Detailed is on.
                if (detailed) {
                    SegmentedPillControl(
                        items = listOf(2, 7, 14),
                        selection = windowDays,
                        label = { when (it) { 2 -> "2 days"; 7 -> "1 week"; else -> "2 weeks" } },
                        onSelect = { windowDays = it },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                HorizontalDivider(color = Palette.hairline, thickness = 1.dp)

                Column(
                    modifier = Modifier
                        .heightIn(max = 360.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    items.forEachIndexed { index, item ->
                        val metricTitle = uiString(item.metric.titleRes)
                        val toggleEnabled = if (item.enabled) {
                            selectedCount > KeyMetricPrefs.MIN_SELECTION_COUNT
                        } else {
                            selectedCount < KeyMetricPrefs.MAX_SELECTION_COUNT
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            NoopToggleSwitch(
                                checked = item.enabled,
                                onCheckedChange = { enabled ->
                                    items[index] = item.copy(enabled = enabled)
                                },
                                enabled = toggleEnabled,
                                modifier = Modifier.semantics { contentDescription = uiString(R.string.l10n_today_screen_show_item_metric_title_81803daf, metricTitle) },
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                metricTitle,
                                style = NoopType.body,
                                color = if (item.enabled) Palette.textPrimary else Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { move(index, index - 1) },
                                enabled = index > 0,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowUp,
                                    contentDescription = uiString(R.string.l10n_today_screen_move_item_metric_title_up_52d2104c, metricTitle),
                                    tint = if (index > 0) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                            IconButton(
                                onClick = { move(index, index + 1) },
                                enabled = index < items.lastIndex,
                                modifier = Modifier.size(Metrics.iconButton),
                            ) {
                                Icon(
                                    Icons.Filled.KeyboardArrowDown,
                                    contentDescription = uiString(R.string.l10n_today_screen_move_item_metric_title_down_890afe60, metricTitle),
                                    tint = if (index < items.lastIndex) Palette.textSecondary else Palette.textTertiary,
                                    modifier = Modifier.size(Metrics.iconSmall),
                                )
                            }
                        }
                        if (index < items.lastIndex) {
                            HorizontalDivider(color = Palette.hairline, thickness = 1.dp)
                        }
                    }
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = {
                            // Reset NOOP's three core pins; every other metric remains visible below them.
                            val defaults = KeyMetric.defaultSelection.toSet()
                            items.clear()
                            KeyMetric.defaultOrder.forEach {
                                items.add(EditableMetric(it, it in defaults))
                            }
                        },
                        colors = ButtonDefaults.textButtonColors(contentColor = Palette.textSecondary),
                    ) { Text(uiString(R.string.l10n_today_screen_reset_44c57abd), style = NoopType.body) }
                    Spacer(Modifier.weight(1f))
                    Button(
                        onClick = { onSave(items.filter { it.enabled }.map { it.metric }, detailed, windowDays) },
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.statusPositive,
                            contentColor = Palette.accentInk,
                        ),
                    ) { Text(uiString(R.string.l10n_today_screen_done_e9b450d1), style = NoopType.captionNumber) }
                }
            }
        }
    }
}
