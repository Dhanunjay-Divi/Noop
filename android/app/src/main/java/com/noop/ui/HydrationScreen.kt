package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.LocalDrink
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.HydrationGoal
import com.noop.analytics.HydrationStore
import com.noop.notif.HydrationReminderPrefs
import com.noop.notif.HydrationReminderScheduler
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.math.RoundingMode
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Date
import java.util.Locale

// MARK: - Hydration detail (MVP, opt-in, local-only) — LIQUID restyle
//
// Liquid finish (matching the liquid Today pilot — TodayScreen.kt / LiquidScreenSky.kt / LiquidPrimitives.kt):
// the day-of-sky settles behind the header (LiquidScreenSky, gated on the same showDayCycleBackground pref),
// the headline fill becomes a LiquidVessel (water in a vessel — the literal fit) with the litre figure
// counting up over it, the daily goal reads as a LiquidTube, and the quick-log controls are liquid-press
// tiles. Everything below stays crisp: the 7-day mini bars are a multi-bar chart (not a single value, so no
// tube), the flat cards keep the frosted surface. The pure HydrationGoal engine remains unchanged, while
// local NOOP logs are shown as durable entries that can be edited or deleted for the selected day.

/** Neutral app chrome; hydration/data colour remains inside the liquid visualization. */
private val hydrationAccent: Color
    @Composable get() = Palette.accent

// MARK: - Liquid hero tokens (shared with the liquid Today hero card)
//
// The frosted translucent near-black the hydration vessel floats on (mock rgba(13,14,20,.80)), so the vessel
// + the white count-up litre figure read crisp over the day-of-sky. Radius 26 + a white@0.11 hairline give
// the frosted-glass edge. Same numbers as the liquid Today heroCard (TodayScreen.kt LIQUID_HERO_*).
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS = 26.dp

/** Upper bound (ml) for a single custom hydration log (#798) - a sane cap so a stray digit can't bank an
 *  absurd 50-litre day. A 3-litre container covers any realistic bottle/jug. Mirrors the iOS clamp. */
private const val MAX_CUSTOM_ML: Int = 3000

private enum class HydrationUIFailure { LOAD, SAVE }

internal enum class HydrationDetailReadStatus {
    LOADING,
    READY,
    UNAVAILABLE,
}

internal data class HydrationDetailReadState(
    val dayKey: String,
    val reading: HydrationStore.Reading?,
    val history: List<Pair<String, Double?>>,
    val entries: List<HydrationStore.Entry>,
    val status: HydrationDetailReadStatus,
)

internal fun hydrationDetailStateForDay(
    state: HydrationDetailReadState?,
    dayKey: String,
): HydrationDetailReadState =
    state?.takeIf { it.dayKey == dayKey }
        ?: HydrationDetailReadState(
            dayKey = HydrationStore.requireDayKey(dayKey),
            reading = null,
            history = emptyList(),
            entries = emptyList(),
            status = HydrationDetailReadStatus.LOADING,
        )

internal fun hydrationDetailStateAfterFailure(
    state: HydrationDetailReadState?,
    dayKey: String,
): HydrationDetailReadState =
    state?.takeIf {
        it.dayKey == dayKey &&
            it.status == HydrationDetailReadStatus.READY &&
            it.reading != null
    } ?: HydrationDetailReadState(
        dayKey = HydrationStore.requireDayKey(dayKey),
        reading = null,
        history = emptyList(),
        entries = emptyList(),
        status = HydrationDetailReadStatus.UNAVAILABLE,
    )

internal const val HYDRATION_DAY_ARGUMENT = "day"
internal const val HYDRATION_ROUTE_PATTERN = "hydration/{$HYDRATION_DAY_ARGUMENT}"

internal fun hydrationRoute(dayKey: String): String =
    "hydration/${HydrationStore.requireDayKey(dayKey)}"

internal fun hydrationRouteDay(rawDay: String?): String? =
    runCatching { HydrationStore.requireDayKey(rawDay.orEmpty()) }.getOrNull()

internal fun hydrationDayTitle(
    dayKey: String,
    todayKey: String,
    todayLabel: String = "Today",
    locale: Locale = Locale.getDefault(),
): String {
    val day = LocalDate.parse(HydrationStore.requireDayKey(dayKey))
    return if (dayKey == HydrationStore.requireDayKey(todayKey)) {
        todayLabel
    } else {
        day.format(DateTimeFormatter.ofPattern("EEE, d MMM", locale))
    }
}

/** Parse a custom-amount field to a whole-ml value in 1..[MAX_CUSTOM_ML]. Out-of-range input is rejected
 *  rather than silently rewritten so the stored value always matches the user's confirmed value. */
internal fun parseCustomHydrationMl(text: String): Int? {
    val n = text.trim().toIntOrNull() ?: return null
    return n.takeIf { it in 1..MAX_CUSTOM_ML }
}

internal data class CustomHydrationInputState(
    val amountMl: Int?,
    val showValidation: Boolean,
) {
    val canConfirm: Boolean
        get() = amountMl != null
}

internal fun customHydrationInputState(text: String): CustomHydrationInputState {
    val amountMl = parseCustomHydrationMl(text)
    return CustomHydrationInputState(
        amountMl = amountMl,
        showValidation = text.isNotBlank() && amountMl == null,
    )
}

internal data class HydrationAccessibilityCopy(
    val litresFormat: String,
    val statusFormat: String,
    val missingWithGoalFormat: String,
    val progressFormat: String,
    val historyFormat: String,
    val historyDayFormat: String,
)

private fun hydrationLitreNumberFormat(locale: Locale): NumberFormat =
    NumberFormat.getNumberInstance(locale).apply {
        minimumFractionDigits = 1
        maximumFractionDigits = 1
        isGroupingUsed = false
        roundingMode = RoundingMode.HALF_UP
    }

private fun localizedHydrationFormat(
    locale: Locale,
    template: String,
    vararg args: Any,
): String = String.format(locale, template, *args)

internal fun hydrationLitresText(
    amountMl: Double,
    locale: Locale,
    format: String,
): String = localizedHydrationFormat(
    locale,
    format,
    hydrationLitreNumberFormat(locale).format(amountMl / 1000.0),
)

internal fun hydrationHeroDescription(
    totalMl: Double?,
    goalMl: Int?,
    missingText: String,
    targetUnavailableText: String,
    dayDescription: String,
    locale: Locale,
    copy: HydrationAccessibilityCopy,
): String {
    val confirmed = HydrationStore.confirmedTotal(totalMl)
    if (confirmed == null) {
        return if (goalMl == null) {
            localizedHydrationFormat(
                locale,
                copy.statusFormat,
                dayDescription,
                missingText,
                targetUnavailableText,
            )
        } else {
            localizedHydrationFormat(
                locale,
                copy.missingWithGoalFormat,
                dayDescription,
                missingText,
                hydrationLitresText(goalMl.coerceAtLeast(0).toDouble(), locale, copy.litresFormat),
            )
        }
    }
    if (goalMl == null) {
        return localizedHydrationFormat(
            locale,
            copy.statusFormat,
            dayDescription,
            hydrationLitresText(confirmed, locale, copy.litresFormat),
            targetUnavailableText,
        )
    }
    val percent = if (goalMl > 0) {
        kotlin.math.min(100, ((confirmed / goalMl) * 100).toInt())
    } else {
        0
    }
    return localizedHydrationFormat(
        locale,
        copy.progressFormat,
        dayDescription,
        hydrationLitresText(confirmed, locale, copy.litresFormat),
        hydrationLitresText(goalMl.coerceAtLeast(0).toDouble(), locale, copy.litresFormat),
        percent,
    )
}

internal fun hydrationHistoryDescription(
    history: List<Pair<String, Double?>>,
    missingText: String,
    title: String,
    locale: Locale,
    copy: HydrationAccessibilityCopy,
): String {
    if (history.isEmpty()) {
        return localizedHydrationFormat(locale, copy.historyFormat, title, missingText)
    }
    val days = history.joinToString(separator = " · ") { (dayKey, value) ->
        val label = runCatching {
            LocalDate.parse(dayKey)
                .dayOfWeek
                .getDisplayName(TextStyle.FULL, locale)
        }.getOrDefault(dayKey)
        val amount = HydrationStore.confirmedTotal(value)?.let {
            hydrationLitresText(it, locale, copy.litresFormat)
        } ?: missingText
        localizedHydrationFormat(locale, copy.historyDayFormat, label, amount)
    }
    return localizedHydrationFormat(locale, copy.historyFormat, title, days)
}

internal fun hydrationEntryTime(
    loggedAt: Long,
    locale: Locale = Locale.getDefault(),
    timeZone: java.util.TimeZone = java.util.TimeZone.getDefault(),
): String =
    java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT, locale)
        .apply { this.timeZone = timeZone }
        .format(Date(Math.multiplyExact(loggedAt, 1_000L)))

/**
 * The Hydration detail screen for one explicit local day. The goal's effort bump uses that day's
 * Effort/strain (0..100; null leaves the bump at 0). Reads and every correction stay on [dayKey].
 */
@Composable
fun HydrationScreen(
    viewModel: AppViewModel,
    dayKey: String? = HydrationStore.dayKey(),
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val locale = context.resources.configuration.locales[0] ?: Locale.getDefault()
    val selectedDayKey = remember(dayKey) { hydrationRouteDay(dayKey) }
    if (selectedDayKey == null) {
        InvalidHydrationDayScreen()
        return
    }

    val today by viewModel.today.collectAsStateWithLifecycle()
    val recentDays by viewModel.recentDays.collectAsStateWithLifecycle()
    val todayKey = HydrationStore.dayKey()
    val selectedRow = remember(recentDays, today, selectedDayKey) {
        recentDays.lastOrNull { it.day == selectedDayKey }
            ?: today?.takeIf { it.day == selectedDayKey }
    }
    val strain = selectedRow?.strain
    val selectedDayTitle = remember(selectedDayKey, todayKey) {
        hydrationDayTitle(
            dayKey = selectedDayKey,
            todayKey = todayKey,
            todayLabel = context.getString(R.string.appwide_gym_tab_today),
        )
    }
    val isToday = selectedDayKey == todayKey

    val profile = remember { ProfileStore.from(context) }
    // Body weight can personalise the baseline, and Effort can adjust it modestly. Wrist skin temperature
    // is deliberately excluded because it is not validated evidence of an individual's fluid requirement.
    val goalMl = remember(profile.ageMetricStateToken, strain) {
        HydrationGoal.personalizedDailyGoalMl(
            age = profile.age,
            ageConfirmed = profile.ageInputConfirmed,
            sex = profile.sex,
            sexConfirmed = profile.sexInputConfirmed,
            weightKg = profile.weightKg,
            weightConfirmed = profile.weightInputConfirmed,
            effort = strain,
        )
    }

    // The liquid sky backdrop honours the SAME opt-out pref as the liquid Today (a user who turned the
    // day-cycle sky off gets the flat canvas here too). Mirrors iOS `showDayCycleBackground ? ... : nil`.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    val notLoggedText = uiString(R.string.appwide_hydration_not_logged)
    val unavailableText = uiString(R.string.appwide_hydration_unavailable)
    val loadFailedText = uiString(R.string.appwide_hydration_load_failed)
    val saveFailedText = uiString(R.string.appwide_hydration_save_failed)
    val retryHydrationText = uiString(R.string.appwide_hydration_retry)
    val dismissText = uiString(R.string.appwide_action_dismiss)
    val targetUnavailableText = uiString(R.string.appwide_hydration_target_unavailable)
    val sourceHeading = uiString(R.string.appwide_hydration_source)
    val sourcesHeading = uiString(R.string.appwide_hydration_sources)
    val noopSourceLabel = uiString(R.string.appwide_hydration_source_noop)
    val healthConnectSourceLabel = uiString(R.string.appwide_hydration_source_health_connect)
    val editText = uiString(R.string.hydration_screen_edit_entry)
    val saveText = uiString(R.string.hydration_screen_save)
    val sipLabel = uiString(R.string.hydration_screen_sip)
    val cupLabel = uiString(R.string.hydration_screen_cup)
    val bottleLabel = uiString(R.string.hydration_screen_bottle)
    val lastSevenDaysText = uiString(R.string.hydration_screen_last_seven_days)
    val shortLitresFormat = uiString(R.string.hydration_screen_litres_short_format)
    val litreNumberFormat = remember(locale) { hydrationLitreNumberFormat(locale) }
    val hydrationAccessibilityCopy = HydrationAccessibilityCopy(
        litresFormat = uiString(R.string.hydration_screen_litres_accessibility_format),
        statusFormat = uiString(R.string.hydration_screen_hero_status_accessibility_format),
        missingWithGoalFormat =
            uiString(R.string.hydration_screen_hero_missing_with_goal_accessibility_format),
        progressFormat = uiString(R.string.hydration_screen_hero_progress_accessibility_format),
        historyFormat = uiString(R.string.hydration_screen_history_accessibility_format),
        historyDayFormat = uiString(R.string.hydration_screen_history_day_accessibility_format),
    )
    val provenanceStrings = HydrationStore.ProvenanceStrings(
        noopOnlyLabel = noopSourceLabel,
        externalOnlyLabel = healthConnectSourceLabel,
        bothLabel = uiString(R.string.appwide_hydration_source_noop_and_health_connect),
        bothExplanation = uiString(R.string.appwide_hydration_source_merge_health_connect),
    )
    val subtitle = uiString(
        R.string.appwide_hydration_subtitle_health_connect_format,
        selectedDayTitle,
    )

    // The selected day's running total + trailing history, refreshed after a scoped mutation. State is
    // keyed by day so a slow/failing replacement read cannot display another day's confirmed value.
    var detailReadState by remember { mutableStateOf<HydrationDetailReadState?>(null) }
    val displayedDetailRead = hydrationDetailStateForDay(detailReadState, selectedDayKey)
    val reading = displayedDetailRead.reading
    val totalMl = reading?.valueMl
    val history = displayedDetailRead.history
    val entries = displayedDetailRead.entries
    val provenance = reading?.let { HydrationStore.run { it.provenance(provenanceStrings) } }
    var hydrationFailure by remember { mutableStateOf<HydrationUIFailure?>(null) }
    // A simple reload key the log taps bump so the LaunchedEffect re-reads the store.
    var reloadTick by remember { mutableStateOf(0) }
    LaunchedEffect(selectedDayKey, reloadTick, strain, goalMl) {
        hydrationFailure = null
        try {
            val loadedReading = HydrationStore.readingForDay(viewModel.repo, selectedDayKey)
            val loadedEntries = HydrationStore.entriesForDay(viewModel.repo, selectedDayKey)
            val loadedHistory = HydrationStore.historyThroughDay(
                repo = viewModel.repo,
                days = 7,
                throughDay = selectedDayKey,
            )
            detailReadState = HydrationDetailReadState(
                dayKey = selectedDayKey,
                reading = loadedReading,
                history = loadedHistory,
                entries = loadedEntries,
                status = HydrationDetailReadStatus.READY,
            )
            val reminders = HydrationReminderPrefs.config(context)
            if (isToday && reminders.adaptiveEnabled) {
                val changed = HydrationReminderPrefs.updateAdaptiveContext(
                    context = context,
                    effort = strain,
                    consumedMl = loadedReading?.valueMl,
                    goalMl = loadedReading?.let { goalMl },
                )
                if (changed && reminders.enabled) HydrationReminderScheduler.reconcile(context)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            detailReadState = hydrationDetailStateAfterFailure(detailReadState, selectedDayKey)
            hydrationFailure = HydrationUIFailure.LOAD
        }
    }

    var showCustom by remember { mutableStateOf(false) }
    var editingEntry by remember { mutableStateOf<HydrationStore.Entry?>(null) }

    val log: (Int) -> Unit = { amount ->
        scope.launch {
            try {
                HydrationStore.logForDay(viewModel.repo, amount, selectedDayKey)
                hydrationFailure = null
                reloadTick += 1
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                hydrationFailure = HydrationUIFailure.SAVE
            }
        }
    }
    val updateEntry: (HydrationStore.Entry, Int) -> Unit = { entry, amount ->
        scope.launch {
            try {
                HydrationStore.updateEntryForDay(
                    viewModel.repo,
                    entry.id,
                    amount,
                    selectedDayKey,
                )
                hydrationFailure = null
                reloadTick += 1
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                hydrationFailure = HydrationUIFailure.SAVE
            }
        }
    }
    val deleteEntry: (HydrationStore.Entry) -> Unit = { entry ->
        scope.launch {
            try {
                HydrationStore.deleteEntryForDay(viewModel.repo, entry.id, selectedDayKey)
                hydrationFailure = null
                reloadTick += 1
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                hydrationFailure = HydrationUIFailure.SAVE
            }
        }
    }
    val clearEntries: () -> Unit = {
        scope.launch {
            try {
                HydrationStore.clearEntriesForDay(viewModel.repo, selectedDayKey)
                hydrationFailure = null
                reloadTick += 1
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                hydrationFailure = HydrationUIFailure.SAVE
            }
        }
    }

    val fraction = if (goalMl != null && goalMl > 0) {
        ((totalMl ?: 0.0) / goalMl).toFloat()
    } else {
        0f
    }
    val observedTotalMl = totalMl
    val missingStateText = when (displayedDetailRead.status) {
        HydrationDetailReadStatus.LOADING,
        HydrationDetailReadStatus.UNAVAILABLE -> unavailableText
        HydrationDetailReadStatus.READY -> notLoggedText
    }
    val accent = hydrationAccent

    // #798 - the amount editor. New custom amounts use the same additive entry path as quick logs;
    // existing entries retain their ID/day and update only their persisted amount.
    if (showCustom || editingEntry != null) {
        val entry = editingEntry
        CustomAmountDialog(
            accent = accent,
            title = if (entry == null) {
                uiString(R.string.hydration_screen_custom_amount)
            } else {
                editText
            },
            confirmText = if (entry == null) {
                uiString(R.string.hydration_screen_log)
            } else {
                saveText
            },
            initialAmountMl = entry?.amountML,
            onDismiss = {
                showCustom = false
                editingEntry = null
            },
            onConfirm = { ml ->
                showCustom = false
                editingEntry = null
                if (entry == null) log(ml) else updateEntry(entry, ml)
            },
        )
    }

    // PERF (#707): lazy scaffold — each top-level section is one `item { }`. Order + spacing unchanged
    // (LazyColumn reproduces the eager `spacedBy(20.dp)`); only on-screen cards compose + are
    // accessibility-walked. All children are unconditional, so every wrap is a bare `item { }`.
    //
    // LIQUID: the day-of-sky sits behind the header via the scaffold's topBackground slot (the pilot
    // pattern — LiquidScreenSky.kt), replacing the classic flat canvas. Gated on the day-cycle pref, so an
    // opted-out user still gets the plain surface. Mirrors the liquid Today scaffold.
    LazyScreenScaffold(
        title = uiString(R.string.appwide_day_overview_hydration),
        subtitle = subtitle,
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        hydrationFailure?.let { failure ->
            item {
                NoopCard(padding = 14.dp) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(
                            Icons.Filled.WaterDrop,
                            contentDescription = null,
                            tint = Palette.statusWarning,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            if (failure == HydrationUIFailure.LOAD) loadFailedText else saveFailedText,
                            style = NoopType.subhead,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        IconButton(
                            onClick = {
                                if (failure == HydrationUIFailure.LOAD) {
                                    reloadTick += 1
                                } else {
                                    hydrationFailure = null
                                }
                            },
                        ) {
                            Icon(
                                if (failure == HydrationUIFailure.LOAD) {
                                    Icons.Filled.Refresh
                                } else {
                                    Icons.Filled.Close
                                },
                                contentDescription =
                                    if (failure == HydrationUIFailure.LOAD) {
                                        retryHydrationText
                                    } else {
                                        dismissText
                                    },
                                tint = Palette.accent,
                            )
                        }
                    }
                }
            }
        }

        // HERO — the day's intake as a LiquidVessel (water in a vessel: the literal fit), with the litre
        // figure counting up over it, floating on the frosted translucent-black liquid hero card so it reads
        // crisp on the day-of-sky. The daily goal is a LiquidTube beneath. Same fraction math + accent +
        // litre values as the GlowRing this replaced. Mirrors the iOS liquid hero idiom (HeroScoreVessel).
        item {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                    .background(LIQUID_HERO_FILL.copy(alpha = LIQUID_HERO_FILL.alpha * CardAppearance.opacity))
                    .border(1.dp, Color.White.copy(alpha = 0.11f * CardAppearance.opacity), RoundedCornerShape(LIQUID_HERO_RADIUS))
                    .padding(20.dp)
                    .clearAndSetSemantics {
                        contentDescription = hydrationHeroDescription(
                            totalMl = observedTotalMl,
                            goalMl = goalMl,
                            missingText = missingStateText,
                            targetUnavailableText = targetUnavailableText,
                            dayDescription = uiString(
                                R.string.appwide_hydration_a11y_day_format,
                                selectedDayTitle,
                            ),
                            locale = locale,
                            copy = hydrationAccessibilityCopy,
                        )
                    },
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        // The vessel fills to the goal fraction in the hydration accent. It runs LIVE (per-frame
                        // slosh + tilt) once anything is logged today; a fresh empty day poses it static so the
                        // launch isn't fighting a live canvas. Honours Reduce Motion internally.
                        LiquidVessel(
                            value = fraction.toDouble().coerceIn(0.0, 1.0),
                            tint = accent,
                            animated = observedTotalMl != null,
                            modifier = Modifier.size(184.dp),
                        )
                        // The litre count-up over the vessel — white, tabular, a soft shadow for legibility,
                        // hit-transparent (clearAndSetSemantics + no clickable) so a tap falls THROUGH to the
                        // vessel (LiquidVessel owns its own tap→splash+haptic). Mirrors the iOS HeroScoreCell.
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.clearAndSetSemantics {},
                        ) {
                            if (observedTotalMl == null) {
                                Text(
                                    missingStateText,
                                    style = NoopType.headline,
                                    color = Color.White,
                                )
                            } else {
                                CountUpText(
                                    value = observedTotalMl / 1000.0,
                                    format = {
                                        localizedHydrationFormat(
                                            locale,
                                            shortLitresFormat,
                                            litreNumberFormat.format(it),
                                        )
                                    },
                                    style = NoopType.number(40f, weight = FontWeight.Bold).copy(
                                        shadow = Shadow(
                                            color = Color.Black.copy(alpha = 0.5f),
                                            offset = Offset(0f, 1f),
                                            blurRadius = 6f,
                                        ),
                                    ),
                                    color = Color.White,
                                )
                            }
                            if (goalMl != null) {
                                Text(
                                    uiString(
                                        R.string.hydration_screen_goal_visible_format,
                                        localizedHydrationFormat(
                                            locale,
                                            shortLitresFormat,
                                            litreNumberFormat.format(goalMl / 1000.0),
                                        ),
                                    ),
                                    style = NoopType.subhead,
                                    color = Color.White.copy(alpha = 0.72f),
                                )
                            }
                        }
                    }
                    // DAILY GOAL — a genuine single-value progress bar, so it reads as a LiquidTube (static:
                    // it sits in a detail hero, not a live surface). Same goal fraction as the vessel.
                    if (goalMl != null) {
                        LiquidTube(
                            frac = fraction.toDouble().coerceIn(0.0, 1.0),
                            tint = accent,
                            height = Metrics.progressHeight,
                            animated = false,
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics {
                                    contentDescription = uiString(
                                        R.string.appwide_hydration_goal_progress_format,
                                        kotlin.math.min(100, (fraction * 100).toInt()),
                                        selectedDayTitle,
                                    )
                                },
                        )
                    }
                    Text(
                        if (goalMl == null) {
                            targetUnavailableText
                        } else if (observedTotalMl == null) {
                            missingStateText
                        } else {
                            uiString(
                                R.string.appwide_hydration_goal_progress_format,
                                kotlin.math.min(100, (fraction * 100).toInt()),
                                selectedDayTitle,
                            )
                        },
                        style = NoopType.footnote,
                        color = Color.White.copy(alpha = 0.6f),
                    )
                }
            }
        }

        // LOG TILES — Sip / Cup / Bottle, as liquid-press tiles (the log controls). Each owns its own
        // interactionSource wired to BOTH its clickable and liquidPress, so the whole tile settles inward on
        // press (the iOS LiquidPressStyle feel), routing the SAME `log(...)` amounts as before.
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                LiquidLogTile(
                    label = sipLabel,
                    onClickLabel = uiString(R.string.hydration_screen_log_accessibility_format, sipLabel),
                    icon = Icons.Filled.WaterDrop,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.SIP_ML) }
                LiquidLogTile(
                    label = cupLabel,
                    onClickLabel = uiString(R.string.hydration_screen_log_accessibility_format, cupLabel),
                    icon = Icons.Filled.LocalDrink,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.CUP_ML) }
                LiquidLogTile(
                    label = bottleLabel,
                    onClickLabel = uiString(R.string.hydration_screen_log_accessibility_format, bottleLabel),
                    icon = Icons.Filled.LocalDrink,
                    accent = accent,
                    modifier = Modifier.weight(1f),
                ) { log(HydrationGoal.BOTTLE_ML) }
            }
        }
        // #798 - "Custom" (a bespoke container size). Full-width secondary button under the quick-add tiles;
        // opens the custom-amount dialog so any ml the presets don't cover can be logged. (Kept as a
        // NoopButton — it carries its own press feedback and this is a secondary affordance, not a quick-log.)
        item {
            NoopButton(
                text = uiString(R.string.hydration_screen_custom_amount),
                leadingIcon = Icons.Filled.Add,
                kind = NoopButtonKind.Secondary,
                modifier = Modifier.fillMaxWidth(),
            ) { showCustom = true }
        }
        item {
            Text(
                uiString(
                    R.string.hydration_screen_quick_amounts_format,
                    sipLabel,
                    uiString(R.string.appwide_hydration_millilitres_format, HydrationGoal.SIP_ML),
                    cupLabel,
                    uiString(R.string.appwide_hydration_millilitres_format, HydrationGoal.CUP_ML),
                    bottleLabel,
                    uiString(R.string.appwide_hydration_millilitres_format, HydrationGoal.BOTTLE_ML),
                ),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }

        // 7-DAY HISTORY — flat mini bars, today on the right. Kept CRISP: this is a multi-bar mini chart
        // (one bar per day), not a single-value progress bar, so a tube would flatten it — leave it as-is.
        item {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Overline(lastSevenDaysText)
                    HydrationHistoryBars(
                        history = history,
                        goalMl = goalMl,
                        accent = accent,
                        missingText = missingStateText,
                        title = lastSevenDaysText,
                        locale = locale,
                        accessibilityCopy = hydrationAccessibilityCopy,
                    )
                }
            }
        }

        // Exact persisted entries plus the source-resolved aggregate. Imported Health Connect intake stays
        // read-only and separate; local controls render only for durable NOOP rows.
        item {
            NoopCard(padding = 18.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Overline(
                        uiString(
                            R.string.appwide_hydration_drinks_on_format,
                            selectedDayTitle,
                        ),
                    )
                    if (observedTotalMl == null) {
                        Text(
                            missingStateText,
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    } else {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(
                                Icons.Filled.WaterDrop,
                                contentDescription = null,
                                tint = accent,
                                modifier = Modifier.size(18.dp),
                            )
                            Spacer(Modifier.width(10.dp))
                            Text(
                                if (isToday) {
                                    uiString(
                                        R.string.appwide_hydration_logged_day,
                                        selectedDayTitle,
                                    )
                                } else {
                                    uiString(
                                        R.string.appwide_hydration_logged_day,
                                        selectedDayTitle,
                                    )
                                },
                                style = NoopType.subhead,
                                color = Palette.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                uiString(
                                    R.string.appwide_hydration_millilitres_format,
                                    observedTotalMl.toInt(),
                                ),
                                style = NoopType.headline.copy(fontWeight = FontWeight.SemiBold),
                                color = Palette.textPrimary,
                            )
                        }
                        provenance?.let { presentation ->
                            HorizontalDivider(color = Palette.hairline)
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .semantics(mergeDescendants = true) {},
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Text(
                                    if (presentation.sourceTotals.isEmpty()) {
                                        sourceHeading
                                    } else {
                                        sourcesHeading
                                    },
                                    style = NoopType.footnote,
                                    color = Palette.textTertiary,
                                )
                                Spacer(Modifier.weight(1f))
                                Text(
                                    presentation.sourceLabel,
                                    style = NoopType.footnote.copy(fontWeight = FontWeight.SemiBold),
                                    color = Palette.textSecondary,
                                    textAlign = TextAlign.End,
                                )
                            }
                            presentation.sourceTotals.forEach { sourceTotal ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .semantics(mergeDescendants = true) {},
                                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        when (sourceTotal.source) {
                                            HydrationStore.ReadingSource.NOOP -> noopSourceLabel
                                            HydrationStore.ReadingSource.HEALTH_CONNECT ->
                                                healthConnectSourceLabel
                                            HydrationStore.ReadingSource.BOTH ->
                                                presentation.sourceLabel
                                        },
                                        style = NoopType.footnote,
                                        color = Palette.textSecondary,
                                    )
                                    Spacer(Modifier.weight(1f))
                                    Text(
                                        uiString(
                                            R.string.appwide_hydration_millilitres_format,
                                            sourceTotal.valueMl.toInt(),
                                        ),
                                        style = NoopType.footnote.copy(fontWeight = FontWeight.SemiBold),
                                        color = Palette.textPrimary,
                                    )
                                }
                            }
                            presentation.explanation?.let { explanation ->
                                Text(
                                    explanation,
                                    style = NoopType.footnote,
                                    color = Palette.textTertiary,
                                )
                            }
                        }
                        entries.forEach { entry ->
                            val entryAmountText = uiString(
                                R.string.appwide_hydration_millilitres_format,
                                entry.amountML,
                            )
                            HorizontalDivider(color = Palette.hairline)
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        entryAmountText,
                                        style = NoopType.subhead.copy(fontWeight = FontWeight.SemiBold),
                                        color = Palette.textPrimary,
                                    )
                                    Text(
                                        hydrationEntryTime(entry.loggedAt),
                                        style = NoopType.footnote,
                                        color = Palette.textTertiary,
                                    )
                                }
                                IconButton(onClick = { editingEntry = entry }) {
                                    Icon(
                                        Icons.Filled.Edit,
                                        contentDescription = uiString(
                                            R.string.appwide_hydration_edit_entry_accessibility_format,
                                            entryAmountText,
                                        ),
                                        tint = Palette.accent,
                                    )
                                }
                                IconButton(onClick = { deleteEntry(entry) }) {
                                    Icon(
                                        Icons.Filled.Delete,
                                        contentDescription = uiString(
                                            R.string.appwide_hydration_delete_entry_accessibility_format,
                                            entryAmountText,
                                        ),
                                        tint = Palette.statusWarning,
                                    )
                                }
                            }
                        }
                        if (entries.isNotEmpty()) {
                            NoopButton(
                                text = uiString(
                                    R.string.appwide_hydration_clear_day,
                                    selectedDayTitle,
                                ),
                                leadingIcon = Icons.Filled.Delete,
                                kind = NoopButtonKind.Secondary,
                                modifier = Modifier.fillMaxWidth(),
                            ) { clearEntries() }
                        }
                    }
                }
            }
        }

        item {
            Text(
                uiString(R.string.hydration_screen_guidance),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.Start,
            )
        }
    }
}

@Composable
private fun InvalidHydrationDayScreen() {
    LazyScreenScaffold(
        title = uiString(R.string.appwide_day_overview_hydration),
        subtitle = stringResource(R.string.appwide_hydration_unavailable),
    ) {
        item {
            NoopCard(padding = 18.dp) {
                Text(
                    stringResource(R.string.appwide_hydration_load_failed),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

/**
 * One quick-log tile (Sip / Cup / Bottle) as a liquid-press control. The tile owns a single
 * [MutableInteractionSource] wired to BOTH its `clickable` and `Modifier.liquidPress`, so the whole tile
 * settles inward (0.975 scale / 0.86 alpha) on press — the iOS LiquidPressStyle feel — then fires [onLog].
 * A frosted card surface + an accent-tinted icon tile keep it on the liquid palette. Mirrors the iOS
 * hydration quick-add button.
 */
@Composable
private fun LiquidLogTile(
    label: String,
    onClickLabel: String,
    icon: ImageVector,
    accent: Color,
    modifier: Modifier = Modifier,
    onLog: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Column(
        modifier = modifier
            .liquidPress(interaction)
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .frostedCardSurface(cornerRadius = Metrics.cardRadius)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClickLabel = onClickLabel,
                onClick = onLog,
            )
            .padding(vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(accent.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = accent, modifier = Modifier.size(17.dp))
        }
        Text(
            label,
            style = NoopType.headline.copy(fontWeight = FontWeight.SemiBold),
            color = Palette.textPrimary,
        )
    }
}

/**
 * The 7-day mini bar history: one flat rounded bar per day, height = day total ÷ goal (clamped to 1), with
 * the weekday initial beneath. Today's bar is the accent blue; prior days a muted accent. Empty days render
 * a faint track. Pure Compose Canvas + a row of labels (design-reset flat style, no gridlines/axes).
 */
@Composable
private fun HydrationHistoryBars(
    history: List<Pair<String, Double?>>,
    goalMl: Int?,
    accent: Color,
    missingText: String,
    title: String,
    locale: Locale,
    accessibilityCopy: HydrationAccessibilityCopy,
) {
    if (history.isEmpty()) {
        Text(missingText, style = NoopType.footnote, color = Palette.textTertiary)
        return
    }
    val goal = (goalMl ?: 0).coerceAtLeast(1).toDouble()
    val track = Palette.textPrimary.copy(alpha = 0.10f)
    val priorBar = accent.copy(alpha = 0.45f)
    val lastIndex = history.lastIndex
    val maxMl = history.mapNotNull { it.second }.maxOrNull() ?: 0.0
    // Scale the bars to the LARGER of the goal and the biggest day, so an over-goal day doesn't clip.
    val ceiling = kotlin.math.max(goal, maxMl).coerceAtLeast(1.0)

    Column(
        verticalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.clearAndSetSemantics {
            contentDescription = hydrationHistoryDescription(
                history = history,
                missingText = missingText,
                title = title,
                locale = locale,
                copy = accessibilityCopy,
            )
        },
    ) {
        Canvas(modifier = Modifier.fillMaxWidth().height(96.dp)) {
            val n = history.size
            val gap = 10.dp.toPx()
            val barW = (size.width - gap * (n - 1)) / n
            val corner = 6.dp.toPx()
            history.forEachIndexed { i, (_, ml) ->
                val x = i * (barW + gap)
                // Track (full-height faint bar).
                drawRoundRectBar(x, 0f, barW, size.height, corner, track)
                val frac = ((ml ?: 0.0) / ceiling).toFloat().coerceIn(0f, 1f)
                if (frac > 0f) {
                    val h = size.height * frac
                    val color = if (i == lastIndex) accent else priorBar
                    drawRoundRectBar(x, size.height - h, barW, h, corner, color)
                }
            }
        }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            history.forEach { (dayKey, _) ->
                Text(
                    hydrationWeekdayLabel(dayKey, locale),
                    style = NoopType.overline.copy(letterSpacing = 0.sp),
                    color = Palette.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/** Draw one rounded-rect bar via the Canvas draw scope (small helper so the bar loop stays readable). */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawRoundRectBar(
    x: Float,
    y: Float,
    w: Float,
    h: Float,
    corner: Float,
    color: Color,
) {
    drawRoundRect(
        color = color,
        topLeft = Offset(x, y),
        size = Size(w, h),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(corner, corner),
    )
}

/** The locale's narrow weekday label for a yyyy-MM-dd key, or "·" when unparseable. */
internal fun hydrationWeekdayLabel(
    dayKey: String,
    locale: Locale = Locale.getDefault(),
): String =
    runCatching {
        LocalDate.parse(dayKey)
            .dayOfWeek
            .getDisplayName(TextStyle.NARROW_STANDALONE, locale)
    }.getOrDefault("·")

/**
 * #798 - the hydration amount dialog used for both new logs and entry edits. Confirm remains disabled
 * until the text parses to a positive whole-ml value (1..MAX_CUSTOM_ML via [parseCustomHydrationMl]).
 * Tokens-only on the hydration-blue field; mirrors the iOS custom-amount sheet.
 */
@Composable
private fun CustomAmountDialog(
    accent: Color,
    title: String,
    confirmText: String,
    initialAmountMl: Int? = null,
    onDismiss: () -> Unit,
    onConfirm: (Int) -> Unit,
) {
    var text by remember(initialAmountMl) {
        mutableStateOf(initialAmountMl?.toString().orEmpty())
    }
    val inputState = customHydrationInputState(text)
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.WaterDrop,
                    contentDescription = null,
                    tint = accent,
                    modifier = Modifier.size(20.dp),
                )
                Spacer(Modifier.width(10.dp))
                Text(title, style = NoopType.title2, color = Palette.textPrimary)
            }
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = text,
                    onValueChange = { new -> text = new.filter { it.isDigit() }.take(5) },
                    label = {
                        Text(
                            uiString(R.string.hydration_screen_amount_label),
                            style = NoopType.footnote,
                        )
                    },
                    singleLine = true,
                    isError = inputState.showValidation,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Palette.textPrimary,
                        unfocusedTextColor = Palette.textPrimary,
                        cursorColor = accent,
                        focusedBorderColor = accent,
                        unfocusedBorderColor = Palette.hairline,
                        focusedLabelColor = accent,
                        unfocusedLabelColor = Palette.textSecondary,
                        focusedContainerColor = Palette.surfaceInset,
                        unfocusedContainerColor = Palette.surfaceInset,
                        errorTextColor = Palette.textPrimary,
                        errorCursorColor = Palette.statusWarning,
                        errorBorderColor = Palette.statusWarning,
                        errorLabelColor = Palette.statusWarning,
                        errorContainerColor = Palette.surfaceInset,
                    ),
                    supportingText = {
                        Text(
                            uiString(
                                R.string.hydration_screen_amount_range_format,
                                MAX_CUSTOM_ML,
                            ),
                            style = NoopType.footnote,
                            color = if (inputState.showValidation) {
                                Palette.statusWarning
                            } else {
                                Palette.textTertiary
                            },
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { inputState.amountMl?.let(onConfirm) },
                enabled = inputState.canConfirm,
            ) {
                Text(
                    confirmText,
                    color = if (inputState.canConfirm) accent else Palette.textTertiary,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(
                    uiString(R.string.hydration_screen_cancel),
                    color = Palette.textSecondary,
                )
            }
        },
    )
}
