package com.noop.ui

import android.app.DatePickerDialog
import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.noop.analytics.CircadianEngine
import com.noop.analytics.CyclePhaseEngine
import com.noop.analytics.IllnessDistance
import com.noop.analytics.IllnessSignalEngine
import com.noop.data.CycleTrackingStore
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt

// MARK: - Skin-temperature suite cards (v5 pillar) — Compose twin
//
// Kotlin/Compose mirror of Strand/Screens/SkinTempCardsView.swift. Three self-contained,
// reusable cards driven entirely by a pure com.noop.analytics engine RESULT passed in
// (Wave 3 runs the engines in the analytics pass and mounts these in the Health hub):
//
//   • CycleAwarenessCard   — CyclePhaseEngine.Result. OPT-IN (the host gates on a default-OFF
//                            preference). Awareness only — NOT contraception, NOT a fertility/
//                            ovulation predictor, NOT a diagnosis. Phase + cycle-day RANGE +
//                            probabilistic next-period WINDOW (never a hard date).
//   • BodyClockCard        — CircadianEngine.PhaseEstimate (+ optional JetLagPlan). LIGHT +
//                            SLEEP TIMING only, never a supplement/drug.
//   • HeadsUpCard          — IllnessSignalEngine.Result. Confounder-suppressed illness
//                            "heads-up". On-device estimate - not a diagnosis.
//
// DESIGN-SYSTEM ONLY: NoopCard + Palette/DomainTheme tokens, NoopType, Metrics, StatePill.
// No raw hex, no ad-hoc cards. Privacy-forward copy (this data is incapable of leaving the
// device, said on every sensitive surface). Cards take VALUES not stores, so a slip stays
// local and the engines remain testable + I/O-free. Wave-3 wiring noted at the foot.

// MARK: - Shared chrome

/** The standing privacy promise repeated on every sensitive skin-temp surface. */
private const val SKIN_TEMP_PRIVACY_LINE =
    "This stays on your device. It is never uploaded, never synced, never shared."

@Composable
private fun PrivacyNote(text: String = SKIN_TEMP_PRIVACY_LINE) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.semantics { contentDescription = text },
    ) {
        Icon(
            Icons.Filled.Lock,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(11.dp),
        )
        Text(text, style = NoopType.footnote, color = Palette.textTertiary)
    }
}

/** A quiet tinted chip (fired signal / confounder / overline-adjacent tag). */
@Composable
private fun WhyChip(label: String, tint: Color) {
    Text(
        label,
        style = NoopType.captionNumber,
        color = tint,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

// MARK: - 1. Cycle awareness card (OPT-IN)

/**
 * Cycle phase awareness from the nightly skin-temperature shift. OPT-IN by design — the host
 * renders this only after the user enables cycle awareness (default OFF). Awareness only;
 * never contraception / fertility / diagnosis. Calm Rest indigo world — no valence, no red.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CycleAwarenessCard(
    result: CyclePhaseEngine.Result,
    onLogPeriod: (() -> Unit)? = null,
    onOpenDetail: (() -> Unit)? = null,
    // #801: symmetric off-control. When supplied, the card shows a "Turn off" action so the user can
    // disable cycle awareness from the SAME place they enabled it (Health), not only from Automations.
    onTurnOff: (() -> Unit)? = null,
) {
    val hue = Palette.restColor
    NoopCard(tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            // Header: overline + confidence pill.
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Cycle awareness")
                    Text(
                        uiString(
                            if (result.cycleDayLow == null) {
                                R.string.l10n_skin_temp_cards_screen_from_your_nightly_temperature_ff8cca1a
                            } else {
                                R.string.cycle_from_logs_and_temperature
                            }
                        ),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                StatePill(cycleConfidenceLabel(result.confidence), tone = cycleConfidenceTone(result.confidence))
            }

            // Headline phase + cycle-day RANGE.
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    cyclePhaseTitle(result.phase),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Spacer(Modifier.weight(1f))
                cycleDayText(result)?.let {
                    Text(it, style = NoopType.bodyNumber, color = Palette.textSecondary)
                }
            }

            Text(localizedCycleNote(result), style = NoopType.subhead, color = Palette.textSecondary)

            // Probabilistic next-period WINDOW, never a single date.
            result.nextPeriodWindow?.let { w ->
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Filled.CalendarMonth, contentDescription = null, tint = hue, modifier = Modifier.size(16.dp))
                    Text(
                        uiString(R.string.l10n_skin_temp_cards_screen_a_period_is_likely_between_prettyday_bc501b32, prettyDay(w.earliestDay)) +
                            "${prettyDay(w.latestDay)} (a window, not a fixed date).",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }

            // Actions.
            if (onLogPeriod != null || onOpenDetail != null || onTurnOff != null) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
                    verticalArrangement = Arrangement.spacedBy(Metrics.gap),
                ) {
                    if (onLogPeriod != null) {
                        OutlinedButton(onClick = onLogPeriod) { Text(uiString(R.string.l10n_skin_temp_cards_screen_log_period_start_c97241d0)) }
                    }
                    if (onOpenDetail != null) {
                        OutlinedButton(
                            onClick = onOpenDetail,
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                        ) { Text(uiString(R.string.l10n_skin_temp_cards_screen_view_detail_27af4b67)) }
                    }
                    // #801: symmetric off-control (turn cycle awareness off where it was turned on).
                    if (onTurnOff != null) {
                        OutlinedButton(onClick = onTurnOff) { Text(uiString(R.string.l10n_skin_temp_cards_screen_turn_off_8807c2b3)) }
                    }
                }
            }

            HorizontalDivider(color = Palette.hairline)

            // Standing awareness-only legal line (verbatim from the engine) + privacy promise.
            Text(CyclePhaseEngine.awarenessLine, style = NoopType.footnote, color = Palette.textTertiary)
            PrivacyNote()
        }
    }
}

/**
 * Shown in place of the card when the user has NOT opted in. A single calm opt-in card restating
 * the privacy promise at the point of consent (manual-first; default OFF).
 */
@Composable
fun CycleAwarenessOptInCard(onEnable: () -> Unit) {
    NoopCard(tint = Palette.restColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(Icons.Filled.Thermostat, contentDescription = null, tint = Palette.restColor, modifier = Modifier.size(18.dp))
                Text(uiString(R.string.l10n_skin_temp_cards_screen_cycle_awareness_ffb94783), style = NoopType.headline, color = Palette.textPrimary)
            }
            Text(
                uiString(R.string.l10n_skin_temp_cards_screen_noop_can_read_a_coarse_menstrual_c79e4b85) +
                    "entirely on your device. It is awareness only: not contraception, not a fertility " +
                    "predictor, not a medical service.",
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            PrivacyNote()
            OutlinedButton(onClick = onEnable) { Text(uiString(R.string.l10n_skin_temp_cards_screen_turn_on_cycle_awareness_7c2d328f)) }
        }
    }
}

// MARK: - Private cycle tracker

/** Honest no-data result used while the first local recompute is opening the tracker. */
internal fun cycleTrackingLearningResult() = CyclePhaseEngine.Result(
    phase = CyclePhaseEngine.Phase.LEARNING,
    confidence = CyclePhaseEngine.Confidence.LEARNING,
    cycleDayLow = null,
    cycleDayHigh = null,
    cycleLengthDays = null,
    nextPeriodWindow = null,
    shiftMarkers = emptyList(),
    note = "Log a period start and wear Noop Band overnight to begin a private estimate.",
    noteKinds = listOf(CyclePhaseEngine.NoteKind.START_LOGGING),
)

/**
 * Phase guide only. The arcs do not represent fertile or safe days; the rose marker exists only after
 * a confirmed day-1 log, and the outlined marker exists only when the engine has a bounded day range.
 */
@Composable
private fun CycleTimelineRing(
    result: CyclePhaseEngine.Result,
    hasLoggedStart: Boolean,
) {
    val cycleLength = maxOf(
        result.cycleLengthDays ?: CyclePhaseEngine.defaultCycleDays,
        result.cycleDayHigh ?: 1,
    )
    val shiftCenter = (cycleLength - 13).coerceIn(8, maxOf(8, cycleLength - 7))
    val midStart = maxOf(2, shiftCenter - 2)
    val midEnd = minOf(cycleLength - 1, shiftCenter + 2)
    val segments = listOf(
        Triple(0f, (midStart - 1f) / cycleLength, Palette.metricCyan),
        Triple((midStart - 1f) / cycleLength, midEnd.toFloat() / cycleLength, Palette.statusWarning),
        Triple(midEnd.toFloat() / cycleLength, 1f, Palette.restColor),
    )
    val currentFraction = result.cycleDayLow?.let { low ->
        result.cycleDayHigh?.let { high ->
            (((low + high) / 2f) - 1f).div(cycleLength).coerceIn(0f, 1f)
        }
    }
    val dayValue = when {
        result.cycleDayLow == null || result.cycleDayHigh == null ->
            stringResource(R.string.appwide_cycle_status_learning)
        result.cycleDayLow == result.cycleDayHigh -> result.cycleDayLow.toString()
        else -> "${result.cycleDayLow}-${result.cycleDayHigh}"
    }
    val phase = cyclePhaseTitle(result.phase)
    var accessibility = stringResource(R.string.appwide_cycle_ring_a11y_phase_format, phase)
    if (result.cycleDayLow != null && result.cycleDayHigh != null) {
        accessibility = if (result.cycleDayLow == result.cycleDayHigh) {
            stringResource(
                R.string.appwide_cycle_ring_a11y_day_format,
                accessibility,
                result.cycleDayLow,
            )
        } else {
            stringResource(
                R.string.appwide_cycle_ring_a11y_day_range_format,
                accessibility,
                result.cycleDayLow,
                result.cycleDayHigh,
            )
        }
    }
    result.cycleLengthDays?.let {
        accessibility = stringResource(
            R.string.appwide_cycle_ring_a11y_cadence_format,
            accessibility,
            it,
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(228.dp)
            .semantics { contentDescription = accessibility },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(214.dp)) {
            val strokeWidth = 18.dp.toPx()
            val ringSize = Size(size.width - strokeWidth, size.height - strokeWidth)
            val topLeft = Offset(strokeWidth / 2f, strokeWidth / 2f)
            val radius = ringSize.width / 2f
            val center = Offset(size.width / 2f, size.height / 2f)

            drawCircle(
                color = Palette.hairline.copy(alpha = 0.7f),
                radius = radius,
                center = center,
                style = Stroke(width = strokeWidth),
            )
            segments.forEach { (start, end, color) ->
                val gap = 3f
                drawArc(
                    color = color,
                    startAngle = -90f + start * 360f + gap / 2f,
                    sweepAngle = ((end - start) * 360f - gap).coerceAtLeast(0f),
                    useCenter = false,
                    topLeft = topLeft,
                    size = ringSize,
                    style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
                )
            }
            if (hasLoggedStart) {
                drawCircle(
                    color = Palette.metricRose,
                    radius = 4.5.dp.toPx(),
                    center = Offset(center.x, center.y - radius),
                )
            }
            currentFraction?.let { fraction ->
                val angle = 2.0 * PI * fraction - PI / 2.0
                val marker = Offset(
                    center.x + cos(angle).toFloat() * radius,
                    center.y + sin(angle).toFloat() * radius,
                )
                drawCircle(Palette.surfaceBase, radius = 7.dp.toPx(), center = marker)
                drawCircle(
                    Palette.textPrimary,
                    radius = 7.dp.toPx(),
                    center = marker,
                    style = Stroke(width = 2.dp.toPx()),
                )
            }
        }

        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                stringResource(
                    if (result.cycleDayLow == null) {
                        R.string.appwide_cycle_ring_cycle
                    } else {
                        R.string.appwide_cycle_ring_estimated_day
                    },
                ),
                style = NoopType.overline,
                color = Palette.textTertiary,
            )
            Text(
                dayValue,
                style = NoopType.number(if (result.cycleDayLow == null) 22f else 32f),
                color = Palette.textPrimary,
                maxLines = 1,
            )
            Text(
                phase,
                style = NoopType.footnote,
                color = Palette.textSecondary,
                maxLines = 2,
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun CycleTimelineLegend(hasLoggedStart: Boolean) {
    val items = buildList {
        add(stringResource(R.string.appwide_cycle_phase_follicular) to Palette.metricCyan)
        add(stringResource(R.string.appwide_cycle_phase_mid_cycle_shift) to Palette.statusWarning)
        add(stringResource(R.string.appwide_cycle_phase_luteal) to Palette.restColor)
        if (hasLoggedStart) {
            add(stringResource(R.string.appwide_cycle_ring_logged_day_one) to Palette.metricRose)
        }
    }
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.appwide_cycle_ring_guide),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items.forEach { (label, color) ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(7.dp).clip(CircleShape).background(color))
                    Text(label, style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
        }
    }
}

/**
 * On-device cycle history. Period starts anchor [CyclePhaseEngine]; optional daily flow and symptoms
 * remain context-only and never become fertility, contraception, or diagnosis outputs. All mutations
 * are suspend callbacks so the host persists before republishing visible history.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CycleTrackerSheet(
    result: CyclePhaseEngine.Result,
    periodStarts: List<String>,
    dailyLogs: List<CycleTrackingStore.DailyLog>,
    onLogPeriodStart: suspend (String) -> Boolean,
    onDeletePeriodStart: suspend (String) -> Boolean,
    onDeleteAllPeriodStarts: suspend () -> Boolean,
    onSaveDailyLog: suspend (
        String,
        CycleTrackingStore.Flow?,
        Set<CycleTrackingStore.Symptom>,
    ) -> Boolean,
    onDeleteDailyLog: suspend (String) -> Boolean,
    onDeleteAllDailyLogs: suspend () -> Boolean,
    onDismiss: () -> Unit,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var selectedDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var operationInFlight by remember { mutableStateOf(false) }
    var operationFailed by remember { mutableStateOf(false) }
    var confirmDeleteAll by remember { mutableStateOf(false) }
    var confirmDeleteAllDetails by remember { mutableStateOf(false) }
    var flowMenuOpen by remember { mutableStateOf(false) }
    var selectedFlow by remember { mutableStateOf<CycleTrackingStore.Flow?>(null) }
    var selectedSymptoms by remember {
        mutableStateOf<Set<CycleTrackingStore.Symptom>>(emptySet())
    }
    val starts = remember(periodStarts) { periodStarts.distinct().sortedDescending() }
    val details = remember(dailyLogs) { dailyLogs.sortedByDescending { it.day } }
    val alreadyLogged = selectedDay in starts
    val selectedLog = details.firstOrNull { it.day == selectedDay }

    LaunchedEffect(selectedDay, dailyLogs) {
        selectedFlow = selectedLog?.flow
        selectedSymptoms = selectedLog?.symptoms ?: emptySet()
    }

    fun runMutation(block: suspend () -> Boolean) {
        if (operationInFlight) return
        scope.launch {
            operationInFlight = true
            val succeeded = runCatching { block() }.getOrDefault(false)
            operationInFlight = false
            if (!succeeded) operationFailed = true
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Palette.surfaceBase,
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(Metrics.sectionGap),
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = Metrics.screenPadding, vertical = Metrics.gap),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(uiString(R.string.cycle_tracker_title), style = NoopType.title2, color = Palette.textPrimary)
                    Text(uiString(R.string.cycle_tracker_private_dates), style = NoopType.footnote, color = Palette.textTertiary)
                }
                TextButton(onClick = onDismiss) { Text(uiString(R.string.l10n_whoop_model_comparison_screen_done_e9b450d1)) }
            }

            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Overline(stringResource(R.string.appwide_cycle_ring_current_estimate))
                        Spacer(Modifier.weight(1f))
                        StatePill(
                            cycleConfidenceLabel(result.confidence),
                            tone = cycleConfidenceTone(result.confidence),
                        )
                    }
                    CycleTimelineRing(result, hasLoggedStart = starts.isNotEmpty())
                    CycleTimelineLegend(hasLoggedStart = starts.isNotEmpty())
                    Text(localizedCycleNote(result), style = NoopType.subhead, color = Palette.textSecondary)
                    result.nextPeriodWindow?.let { window ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Icon(
                                Icons.Filled.CalendarMonth,
                                contentDescription = null,
                                tint = Palette.metricRose,
                                modifier = Modifier.size(14.dp),
                            )
                            Text(
                                stringResource(
                                    R.string.appwide_cycle_period_window_format,
                                    prettyPeriodStartDay(window.earliestDay),
                                    prettyPeriodStartDay(window.latestDay),
                                ),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                    }
                }
            }

            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Overline("Log a period start")
                    OutlinedButton(
                        enabled = !operationInFlight,
                        modifier = Modifier.fillMaxWidth(),
                        onClick = {
                            val selected = LocalDate.parse(selectedDay)
                            DatePickerDialog(
                                context,
                                { _, year, month, dayOfMonth ->
                                    selectedDay = LocalDate.of(year, month + 1, dayOfMonth).toString()
                                },
                                selected.year,
                                selected.monthValue - 1,
                                selected.dayOfMonth,
                            ).apply {
                                datePicker.maxDate = System.currentTimeMillis()
                            }.show()
                        },
                    ) {
                        Icon(Icons.Filled.CalendarMonth, contentDescription = null, modifier = Modifier.size(17.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(prettyPeriodStartDay(selectedDay))
                    }
                    Button(
                        enabled = !operationInFlight && !alreadyLogged,
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.restColor,
                            contentColor = Palette.surfaceBase,
                        ),
                        onClick = { runMutation { onLogPeriodStart(selectedDay) } },
                    ) {
                        if (operationInFlight) {
                            CircularProgressIndicator(
                                color = Palette.surfaceBase,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(16.dp),
                            )
                            Spacer(Modifier.width(8.dp))
                        }
                        Text(
                            if (alreadyLogged) uiString(R.string.cycle_tracker_already_logged)
                            else uiString(R.string.l10n_skin_temp_cards_screen_log_period_start_c97241d0),
                        )
                    }
                    Text(
                        uiString(R.string.cycle_tracker_period_start_help),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            NoopCard(tint = Palette.restColor) {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Overline("Daily details")
                    Text(
                        prettyPeriodStartDay(selectedDay),
                        style = NoopType.bodyNumber,
                        color = Palette.textPrimary,
                    )
                    Box {
                        OutlinedButton(
                            modifier = Modifier.fillMaxWidth(),
                            enabled = !operationInFlight,
                            onClick = { flowMenuOpen = true },
                        ) {
                            Text(
                                "Flow: ${selectedFlow?.let(::cycleFlowLabel) ?: "Not entered"}",
                            )
                        }
                        DropdownMenu(
                            expanded = flowMenuOpen,
                            onDismissRequest = { flowMenuOpen = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("Not entered") },
                                onClick = {
                                    selectedFlow = null
                                    flowMenuOpen = false
                                },
                            )
                            CycleTrackingStore.Flow.entries.forEach { flow ->
                                DropdownMenuItem(
                                    text = { Text(cycleFlowLabel(flow)) },
                                    onClick = {
                                        selectedFlow = flow
                                        flowMenuOpen = false
                                    },
                                )
                            }
                        }
                    }

                    Text("Symptoms", style = NoopType.overline, color = Palette.textTertiary)
                    CycleTrackingStore.Symptom.entries.forEach { symptom ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable(enabled = !operationInFlight) {
                                    selectedSymptoms = if (symptom in selectedSymptoms) {
                                        selectedSymptoms - symptom
                                    } else {
                                        selectedSymptoms + symptom
                                    }
                                },
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = symptom in selectedSymptoms,
                                onCheckedChange = null,
                            )
                            Text(
                                cycleSymptomLabel(symptom),
                                style = NoopType.body,
                                color = Palette.textPrimary,
                            )
                        }
                    }

                    Button(
                        enabled = !operationInFlight &&
                            (selectedFlow != null || selectedSymptoms.isNotEmpty()),
                        modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Palette.restColor,
                            contentColor = Palette.surfaceBase,
                        ),
                        onClick = {
                            runMutation {
                                onSaveDailyLog(selectedDay, selectedFlow, selectedSymptoms)
                            }
                        },
                    ) {
                        Text(if (selectedLog == null) "Save daily details" else "Update daily details")
                    }
                    if (selectedLog != null) {
                        TextButton(
                            enabled = !operationInFlight,
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                runMutation { onDeleteDailyLog(selectedDay) }
                            },
                        ) {
                            Text("Clear this day", color = Palette.statusCritical)
                        }
                    }
                    Text(
                        "Optional context only. These entries do not diagnose a condition, predict safe or fertile days, or trigger an emergency alert.",
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
            }

            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Overline("Logged starts")
                        Spacer(Modifier.weight(1f))
                        if (starts.isNotEmpty()) {
                            TextButton(
                                enabled = !operationInFlight,
                                onClick = { confirmDeleteAll = true },
                            ) { Text(uiString(R.string.cycle_tracker_delete_all), color = Palette.statusCritical) }
                        }
                    }

                    if (starts.isEmpty()) {
                        Text(uiString(R.string.cycle_tracker_empty), style = NoopType.subhead, color = Palette.textSecondary)
                    } else {
                        starts.forEachIndexed { index, day ->
                            if (index > 0) HorizontalDivider(color = Palette.hairline)
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Icon(
                                    Icons.Filled.WaterDrop,
                                    contentDescription = null,
                                    tint = Palette.restColor,
                                    modifier = Modifier.size(17.dp),
                                )
                                Text(
                                    prettyPeriodStartDay(day),
                                    style = NoopType.bodyNumber,
                                    color = Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                IconButton(
                                    enabled = !operationInFlight,
                                    onClick = { runMutation { onDeletePeriodStart(day) } },
                                ) {
                                    Icon(
                                        Icons.Filled.Delete,
                                        contentDescription = uiString(R.string.cycle_tracker_delete_date, prettyPeriodStartDay(day)),
                                        tint = Palette.statusCritical,
                                    )
                                }
                            }
                        }
                    }
                }
            }

            if (details.isNotEmpty()) {
                NoopCard {
                    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Overline("Daily history")
                            Spacer(Modifier.weight(1f))
                            TextButton(
                                enabled = !operationInFlight,
                                onClick = { confirmDeleteAllDetails = true },
                            ) {
                                Text("Delete all", color = Palette.statusCritical)
                            }
                        }
                        details.take(14).forEachIndexed { index, log ->
                            if (index > 0) HorizontalDivider(color = Palette.hairline)
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                                verticalAlignment = Alignment.Top,
                            ) {
                                Text(
                                    prettyPeriodStartDay(log.day),
                                    style = NoopType.bodyNumber,
                                    color = Palette.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                Text(
                                    cycleDailySummary(log),
                                    style = NoopType.footnote,
                                    color = Palette.textSecondary,
                                    modifier = Modifier.weight(1.3f),
                                )
                            }
                        }
                    }
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(CyclePhaseEngine.awarenessLine, style = NoopType.footnote, color = Palette.textTertiary)
                PrivacyNote(
                    "Cycle dates and daily details stay in NOOP's local database on this phone unless you explicitly export your data."
                )
            }
        }
    }

    if (confirmDeleteAll) {
        AlertDialog(
            onDismissRequest = { if (!operationInFlight) confirmDeleteAll = false },
            title = { Text(uiString(R.string.cycle_tracker_delete_all_title)) },
            text = { Text(uiString(R.string.cycle_tracker_delete_all_message)) },
            dismissButton = {
                TextButton(onClick = { confirmDeleteAll = false }) { Text(uiString(R.string.l10n_sleep_screen_cancel_77dfd213)) }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDeleteAll = false
                        runMutation { onDeleteAllPeriodStarts() }
                    },
                ) { Text(uiString(R.string.cycle_tracker_delete_all), color = Palette.statusCritical) }
            },
        )
    }

    if (operationFailed) {
        AlertDialog(
            onDismissRequest = { operationFailed = false },
            title = { Text(uiString(R.string.cycle_tracker_update_failed_title)) },
            text = { Text(uiString(R.string.cycle_tracker_update_failed_message)) },
            confirmButton = {
                TextButton(onClick = { operationFailed = false }) { Text("OK") }
            },
        )
    }

    if (confirmDeleteAllDetails) {
        AlertDialog(
            onDismissRequest = { if (!operationInFlight) confirmDeleteAllDetails = false },
            title = { Text("Delete all daily cycle details?") },
            text = {
                Text("This permanently removes flow and symptom entries. Period-start dates and wearable history are unchanged.")
            },
            dismissButton = {
                TextButton(onClick = { confirmDeleteAllDetails = false }) {
                    Text(uiString(R.string.l10n_sleep_screen_cancel_77dfd213))
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmDeleteAllDetails = false
                        runMutation { onDeleteAllDailyLogs() }
                    },
                ) {
                    Text("Delete all details", color = Palette.statusCritical)
                }
            },
        )
    }
}

private fun cycleFlowLabel(flow: CycleTrackingStore.Flow): String = when (flow) {
    CycleTrackingStore.Flow.NONE -> "No bleeding"
    CycleTrackingStore.Flow.SPOTTING -> "Spotting"
    CycleTrackingStore.Flow.LIGHT -> "Light"
    CycleTrackingStore.Flow.MEDIUM -> "Medium"
    CycleTrackingStore.Flow.HEAVY -> "Heavy"
}

private fun cycleSymptomLabel(symptom: CycleTrackingStore.Symptom): String = when (symptom) {
    CycleTrackingStore.Symptom.CRAMPS -> "Cramps"
    CycleTrackingStore.Symptom.HEADACHE -> "Headache"
    CycleTrackingStore.Symptom.FATIGUE -> "Fatigue"
    CycleTrackingStore.Symptom.BLOATING -> "Bloating"
    CycleTrackingStore.Symptom.MOOD_CHANGES -> "Mood changes"
    CycleTrackingStore.Symptom.BREAST_TENDERNESS -> "Breast tenderness"
    CycleTrackingStore.Symptom.ACNE -> "Acne"
    CycleTrackingStore.Symptom.NAUSEA -> "Nausea"
    CycleTrackingStore.Symptom.BACK_PAIN -> "Back pain"
    CycleTrackingStore.Symptom.CRAVINGS -> "Cravings"
}

private fun cycleDailySummary(log: CycleTrackingStore.DailyLog): String {
    val parts = mutableListOf<String>()
    log.flow?.let { parts += cycleFlowLabel(it) }
    if (log.symptoms.isNotEmpty()) {
        parts += log.symptoms
            .sortedBy { it.ordinal }
            .joinToString(", ", transform = ::cycleSymptomLabel)
    }
    return parts.joinToString(" · ")
}

// MARK: - 2. Body Clock card

/**
 * Estimated body-clock phase + an optional jet-lag / shift plan. LIGHT + SLEEP TIMING only —
 * never a supplement. Behavioural awareness, approximate.
 */
@Composable
fun BodyClockCard(
    estimate: CircadianEngine.PhaseEstimate,
    plan: CircadianEngine.JetLagPlan? = null,
    onOpenPlanner: (() -> Unit)? = null,
) {
    val hue = Palette.restColor
    NoopCard(tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Body clock")
                    Text(uiString(R.string.l10n_skin_temp_cards_screen_light_sleep_timing_only_df2a1552), style = NoopType.footnote, color = Palette.textTertiary)
                }
                StatePill(bodyClockConfidenceLabel(estimate.confidence), tone = bodyClockConfidenceTone(estimate.confidence))
            }

            Text(bodyClockOffsetTitle(estimate), style = NoopType.title2, color = Palette.textPrimary)

            Text(estimate.note, style = NoopType.subhead, color = Palette.textSecondary)

            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(Icons.Filled.NightsStay, contentDescription = null, tint = hue, modifier = Modifier.size(14.dp))
                Text(
                    uiString(R.string.l10n_skin_temp_cards_screen_estimated_body_clock_low_around_clockstring_fb0f0790, clockString(estimate.tempMinHour)),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }

            val firstDay = plan?.days?.firstOrNull()
            if (plan != null && plan.direction != CircadianEngine.ShiftDirection.NONE && firstDay != null) {
                HorizontalDivider(color = Palette.hairline)
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Overline("Plan · ${plan.estimatedDays}-day shift")
                    Text(
                        uiString(R.string.l10n_skin_temp_cards_screen_day_1_bright_light_clockstring_firstday_43b5fe87, clockString(firstDay.brightLightStartHour)) +
                            "${clockString(firstDay.brightLightEndHour)}, lights-out around " +
                            "${clockString(firstDay.targetSleepHour)}.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                    Text(plan.note, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (onOpenPlanner != null) {
                OutlinedButton(
                    onClick = onOpenPlanner,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Palette.accent),
                ) { Text(if (plan == null) "Plan a trip or shift" else "View the full plan") }
            }
        }
    }
}

// MARK: - 3. Heads-Up card (illness early-warning, confounder-suppressed)

/**
 * The confounder-suppressed illness "heads-up". Renders the engine's already-decided level +
 * copy; the host only mounts it when the engine returns a non-quiet level. On-device estimate
 * — not a diagnosis. Mirrors the existing amber alert treatment.
 */
@Composable
fun HeadsUpCard(
    result: IllnessSignalEngine.Result,
    // Optional parallel Mahalanobis distance (IllnessDistance), computed on the SAME z-vector. It does
    // NOT gate this card (the engine's level already did); when the level is raised and a distance is
    // present we append a subtle "Confidence" line so the user can gauge how strong the signal is.
    distance: IllnessDistance.Result? = null,
) {
    val hue = headsUpHue(result.level)
    NoopCard(padding = 14.dp, tint = hue) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    modifier = Modifier
                        .size(30.dp)
                        .clip(CircleShape)
                        .background(hue.copy(alpha = 0.16f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(headsUpGlyph(result.level), contentDescription = null, tint = hue, modifier = Modifier.size(15.dp))
                }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(headsUpTitle(result.level), style = NoopType.headline, color = Palette.textPrimary)
                    Text(result.copy, style = NoopType.subhead, color = Palette.textSecondary)
                }
            }

            // The visible "why": which signals fired.
            if (result.firedSignals.isNotEmpty()) {
                WhyRow("Signals up", result.firedSignals, hue)
            }
            // Nearby context can move the same signals; surface it without claiming causation.
            if (result.suppressedBy.isNotEmpty()) {
                WhyRow("Also logged", result.suppressedBy, Palette.textTertiary)
            }
            // Optional confidence read from the parallel Mahalanobis distance, only when the level is
            // raised. Subtle by design: it augments, never gates (the engine already decided to raise).
            headsUpConfidenceLine(result.level, distance)?.let { line ->
                Text(line, style = NoopType.caption, color = Palette.textTertiary)
            }
        }
    }
}

/**
 * A subtle confidence read from the parallel Mahalanobis distance, surfaced ONLY on the RAISED state (and
 * when a distance is present). null otherwise. The already-unwell state is driven purely by the user's own
 * log and can have a near-zero distance (0-1 present features), giving a misleading "Confidence: slight
 * (distance 0.0)", so it's excluded. The raised path always has >= 2 present features, so its distance is
 * meaningful. The band mirrors iOS exactly. Augment-only, never gates.
 */
private fun headsUpConfidenceLine(
    level: IllnessSignalEngine.Level,
    distance: IllnessDistance.Result?,
): String? {
    if (level != IllnessSignalEngine.Level.RAISED) return null
    val d = distance ?: return null
    return "Confidence: ${illnessConfidenceBand(d.distance)} (distance ${illnessConfidenceFormatted(d.distance)})"
}

/**
 * Maps the parallel Mahalanobis distance to a plain confidence word. Presentation-only: NEVER decides
 * whether the Heads-Up card shows (the engine's level already did). Bands: >= 3.5 strong, >= 2.5
 * moderate, else slight. Identical to the Swift twin (IllnessConfidence.band).
 */
private fun illnessConfidenceBand(distance: Double): String = when {
    distance >= 3.5 -> "strong"
    distance >= 2.5 -> "moderate"
    else -> "slight"
}

/** One-decimal display value for the distance, locale-independent. Mirrors iOS String(format: "%.1f"). */
private fun illnessConfidenceFormatted(distance: Double): String =
    String.format(java.util.Locale.US, "%.1f", distance)

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WhyRow(label: String, values: List<String>, tint: Color) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.semantics {
            contentDescription = uiString(R.string.skin_temp_reason_summary, label, values.joinToString(", "))
        },
    ) {
        Overline(label)
        // Chips wrap to the next line rather than overflowing the card on a long confounder list.
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            values.forEach { WhyChip(it, tint) }
        }
    }
}

// MARK: - Derived copy / presentation (mirror the Swift card exactly)

private fun cyclePhaseTitle(phase: CyclePhaseEngine.Phase): String = when (phase) {
    CyclePhaseEngine.Phase.FOLLICULAR -> uiString(R.string.appwide_cycle_phase_follicular)
    CyclePhaseEngine.Phase.PERI_OVULATORY -> uiString(R.string.appwide_cycle_phase_mid_cycle_shift)
    CyclePhaseEngine.Phase.LUTEAL -> uiString(R.string.appwide_cycle_phase_luteal)
    CyclePhaseEngine.Phase.UNKNOWN -> uiString(R.string.appwide_cycle_phase_no_clear_pattern)
    CyclePhaseEngine.Phase.LEARNING -> uiString(R.string.appwide_cycle_phase_building_pattern)
}

@Composable
private fun localizedCycleNote(result: CyclePhaseEngine.Result): String {
    if (result.noteKinds.isEmpty()) return result.note
    val parts = mutableListOf<String>()
    for (kind in result.noteKinds) {
        parts += when (kind) {
            CyclePhaseEngine.NoteKind.LEARNING_NIGHTLY ->
                stringResource(R.string.appwide_cycle_note_learning_nightly)
            CyclePhaseEngine.NoteKind.NO_CLEAR_PATTERN ->
                stringResource(R.string.appwide_cycle_note_no_clear_pattern)
            CyclePhaseEngine.NoteKind.NO_CLEAR_CONTEXT ->
                stringResource(R.string.appwide_cycle_note_no_clear_context)
            CyclePhaseEngine.NoteKind.LOG_SHIFT_MISMATCH ->
                stringResource(R.string.appwide_cycle_note_log_shift_mismatch)
            CyclePhaseEngine.NoteKind.PHASE_FOLLICULAR ->
                stringResource(R.string.appwide_cycle_note_phase_follicular)
            CyclePhaseEngine.NoteKind.PHASE_MID_CYCLE ->
                stringResource(R.string.appwide_cycle_note_phase_mid_cycle)
            CyclePhaseEngine.NoteKind.PHASE_LUTEAL ->
                stringResource(R.string.appwide_cycle_note_phase_luteal)
            CyclePhaseEngine.NoteKind.STALE_LOG ->
                stringResource(R.string.appwide_cycle_note_stale_log)
            CyclePhaseEngine.NoteKind.UNRELIABLE_LOGS ->
                stringResource(R.string.appwide_cycle_note_unreliable_logs)
            CyclePhaseEngine.NoteKind.FORECAST_PASSED ->
                stringResource(R.string.appwide_cycle_note_forecast_passed)
            CyclePhaseEngine.NoteKind.BROAD_PRIOR ->
                stringResource(R.string.appwide_cycle_note_broad_prior)
            CyclePhaseEngine.NoteKind.PERSONAL_INTERVALS ->
                stringResource(R.string.appwide_cycle_note_personal_intervals)
            CyclePhaseEngine.NoteKind.START_LOGGING ->
                stringResource(R.string.appwide_cycle_note_start_logging)
            CyclePhaseEngine.NoteKind.TURN_ON_AWARENESS ->
                stringResource(R.string.appwide_cycle_note_turn_on_awareness)
        }
    }
    return parts.joinToString(" ")
}

/** "~day 18–22" - always a RANGE, never a single point. */
private fun cycleDayText(r: CyclePhaseEngine.Result): String? {
    val lo = r.cycleDayLow ?: return null
    val hi = r.cycleDayHigh ?: return null
    return if (lo == hi) "· ~day $lo" else "· ~day $lo - $hi"
}

private fun cycleConfidenceLabel(c: CyclePhaseEngine.Confidence): String = when (c) {
    CyclePhaseEngine.Confidence.LEARNING -> uiString(R.string.appwide_cycle_status_learning)
    CyclePhaseEngine.Confidence.BUILDING -> uiString(R.string.appwide_cycle_status_building)
    CyclePhaseEngine.Confidence.SOLID -> uiString(R.string.appwide_cycle_status_solid)
}

private fun cycleConfidenceTone(c: CyclePhaseEngine.Confidence): StrandTone = when (c) {
    CyclePhaseEngine.Confidence.LEARNING -> StrandTone.Neutral
    CyclePhaseEngine.Confidence.BUILDING -> StrandTone.Accent
    CyclePhaseEngine.Confidence.SOLID -> StrandTone.Accent
}

/** "About 25 min later than your schedule" - a plain, skimmable headline. */
private fun bodyClockOffsetTitle(e: CircadianEngine.PhaseEstimate): String {
    if (e.confidence == CircadianEngine.PhaseConfidence.UNREADABLE) return "Hard to read right now"
    val mins = abs(e.offsetVsScheduleMinutes).roundToInt()
    if (mins <= 20) return "About in sync with your schedule"
    val dir = if (e.offsetVsScheduleMinutes > 0) "later" else "earlier"
    return "About $mins min $dir than your schedule"
}

private fun bodyClockConfidenceLabel(c: CircadianEngine.PhaseConfidence): String = when (c) {
    CircadianEngine.PhaseConfidence.UNREADABLE -> "Calibrating"
    CircadianEngine.PhaseConfidence.WIDE -> "Building"
    CircadianEngine.PhaseConfidence.SOLID -> "Solid"
}

private fun bodyClockConfidenceTone(c: CircadianEngine.PhaseConfidence): StrandTone = when (c) {
    CircadianEngine.PhaseConfidence.UNREADABLE -> StrandTone.Neutral
    CircadianEngine.PhaseConfidence.WIDE -> StrandTone.Accent
    CircadianEngine.PhaseConfidence.SOLID -> StrandTone.Accent
}

/** Card hue follows the level: raised / already-unwell = amber warning (matches the shipped
 *  banner); suppressed / mild = a calmer neutral so it never scares. */
private fun headsUpHue(level: IllnessSignalEngine.Level): Color = when (level) {
    IllnessSignalEngine.Level.RAISED, IllnessSignalEngine.Level.ALREADY_UNWELL -> Palette.statusWarning
    else -> Palette.restColor
}

private fun headsUpGlyph(level: IllnessSignalEngine.Level): ImageVector = when (level) {
    IllnessSignalEngine.Level.RAISED -> Icons.Filled.Warning
    IllnessSignalEngine.Level.ALREADY_UNWELL -> Icons.Filled.NightsStay
    IllnessSignalEngine.Level.SUPPRESSED -> Icons.Filled.Info
    IllnessSignalEngine.Level.MILD -> Icons.Filled.MonitorHeart
    IllnessSignalEngine.Level.QUIET -> Icons.Filled.CheckCircle
}

private fun headsUpTitle(level: IllnessSignalEngine.Level): String = when (level) {
    IllnessSignalEngine.Level.RAISED -> "Heads-up"
    IllnessSignalEngine.Level.ALREADY_UNWELL -> "Rest up"
    IllnessSignalEngine.Level.SUPPRESSED -> "Related context found"
    IllnessSignalEngine.Level.MILD -> "A few signals are up"
    IllnessSignalEngine.Level.QUIET -> "Nothing notable"
}

// MARK: - Formatting helpers (locale-free, matching the engine's own helpers)

/** Render a fractional clock hour as "HH:MM". */
private fun clockString(hour: Double): String {
    var h = hour % 24.0
    if (h < 0) h += 24.0
    var hh = h.toInt()
    var mm = ((h - hh) * 60.0).roundToInt()
    if (mm == 60) { mm = 0; hh = (hh + 1) % 24 }
    return "%02d:%02d".format(hh, mm)
}

/** "12 Jun" from a "yyyy-MM-dd" key (display only; the engine math stays UTC). */
private fun prettyDay(key: String): String {
    val parts = key.split("-")
    if (parts.size != 3) return key
    val m = parts[1].toIntOrNull() ?: return key
    val d = parts[2].toIntOrNull() ?: return key
    if (m !in 1..12) return key
    val months = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    return "$d ${months[m - 1]}"
}

/** Full date for period-start history, where entries can span multiple years. */
internal fun prettyPeriodStartDay(key: String): String = runCatching {
    LocalDate.parse(key).format(DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.getDefault()))
}.getOrDefault(key)
