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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.CompareArrows
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Thermostat
import androidx.compose.material.icons.filled.TrackChanges
import androidx.compose.material.icons.filled.WaterDrop
import android.widget.Toast
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.noop.analytics.Baselines
import com.noop.analytics.AgeMetricProfile
import com.noop.analytics.IllnessSignalEngine
import com.noop.analytics.IntelligenceEngine
import com.noop.analytics.V5HealthSignals
import com.noop.analytics.FitnessAgeEngine
import com.noop.analytics.VitalityEngine
import com.noop.analytics.FitnessAgeReadiness
import com.noop.analytics.FitnessReadinessItem
import com.noop.analytics.FitnessReadinessRole
import com.noop.analytics.FitnessReadinessStatus
import com.noop.analytics.VitalBands
import com.noop.ble.LiveState
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

// MARK: - Health Monitor (ported from Strand/Screens/HealthView.swift)
//
// Live heart-rate hero (streaming HR + HR-zone read-out, derived from the strap's
// R-R stream when the HR field reads 0), then a uniform grid of the body's vital
// signs (respiratory rate, blood O2, resting HR, HRV, skin temp) as fixed-height
// StatTiles, each tinted and captioned with its in-range state. Re-skinned to the
// locked NOOP component system: every surface is a NoopCard/StatTile, every chart
// is a Canvas chart — no ad-hoc card heights or paddings.
//
// macOS parity note: live HR zone/%max reads the user's ProfileStore max heart rate,
// matching Settings/onboarding. SpO2 / respiratory / skin-temp are sleep-window
// aggregates, so the "Vital Signs" grid is sourced from today's DailyMetric.

internal fun Flow<LiveState>.healthConnectionChanges(): Flow<Boolean> =
    map { it.connected }.distinctUntilChanged()

@Composable
fun HealthScreen(
    vm: AppViewModel,
    onVitalClick: (String) -> Unit = {},
    onOpenLabBook: () -> Unit = {},
    onOpenFusedRecord: () -> Unit = {},
) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val profileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val metricDataVersion by vm.ageMetricDataVersion.collectAsStateWithLifecycle()
    val activeDeviceId by vm.selectedDeviceId.collectAsStateWithLifecycle()
    val cycleProfileEligible = remember(profileVersion) { cycleOptInApplies(profile.sex) }
    val today by vm.today.collectAsStateWithLifecycle()
    // Full merged daily history — feeds the personal-baseline banding of the vitals grid.
    val days by vm.recentDays.collectAsStateWithLifecycle()
    // v5 skin-temp suite engine results (Cycle / Body clock / Illness heads-up), recomputed each
    // analytics pass and published by the ViewModel. Cycle awareness gates on its opt-in pref.
    val v5Signals by vm.v5Signals.collectAsStateWithLifecycle()
    val cycleEnabled by vm.cycleTrackingEnabled.collectAsStateWithLifecycle()
    val periodStarts by vm.periodStarts.collectAsStateWithLifecycle()
    val cycleDailyLogs by vm.cycleDailyLogs.collectAsStateWithLifecycle()
    var cycleTrackerPresented by remember { mutableStateOf(false) }
    val cycleScope = rememberCoroutineScope()
    val hrMax = profile.hrMax

    // The parent observes one deduplicated Boolean for the first-run gate. HeartRateSection owns the
    // full ticking state, so sensor-only packets never recompose this query-heavy screen root.
    val connected by remember(vm.live) {
        vm.live.healthConnectionChanges()
    }.collectAsStateWithLifecycle(initialValue = false)

    // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles into
    // the theme canvas behind this screen's top region, full-bleed up behind the status bar via the
    // scaffold's topBackground plumbing, replacing the classic scene backdrop. Static (LiquidSkyStatic,
    // inside the helper) - never an animated sky behind a scrolling list. Gated on the shared "Day-cycle
    // background" pref (default ON) exactly like Today; OFF passes null so the scaffold paints the flat
    // surface canvas instead.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }

    LazyScreenScaffold(
        title = uiString(R.string.l10n_health_screen_health_monitor_c4abc3fc),
        subtitle = "Live vitals, streamed from Noop Band.",
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards fills the viewport so the transparent cards reveal the sky the whole way
        // down (Today / Trends / Sleep / metric-detail parity - same two prefs, same two behaviours).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        if (days.isEmpty() && !connected) {
            // Even with no history yet, a freshly-connected strap can be told to sync now (#364) — the
            // manual "Sync now" + honest status sits above the empty state so it's always reachable.
            item { SyncStatusSection(vm = vm, onSyncNow = { vm.syncNow() }) }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item { HealthEmptyState() }
            // Cycle setup is profile data, not wearable data. Keep it reachable before the first sync.
            if (cycleProfileEligible || cycleEnabled) {
                item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
                item {
                    SkinTempSuiteSection(
                        signals = v5Signals,
                        cycleEnabled = cycleEnabled,
                        cycleOptInApplies = cycleProfileEligible,
                        onEnableCycle = { vm.setCycleTrackingEnabled(true) },
                        onTurnOffCycle = { vm.setCycleTrackingEnabled(false) },
                        onLogPeriod = {
                            cycleScope.launch {
                                if (!vm.logPeriodStart(LocalDate.now().toString())) {
                                    Toast.makeText(
                                        context,
                                        "Couldn’t log the period start. Please try again.",
                                        Toast.LENGTH_SHORT,
                                    ).show()
                                }
                            }
                        },
                        onOpenCycleTracker = { cycleTrackerPresented = true },
                    )
                }
            }
        } else {
            // Manual "Sync now" + honest sync status (#364) - the first section so the strap-history
            // control is reachable above the live hero. Mirrors HealthView.swift's top Sync section.
            item { SyncStatusSection(vm = vm, onSyncNow = { vm.syncNow() }) }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            // ScreenScaffold applies a 20dp arrangement gap between its direct children;
            // a small top-up reaches the section gap (28dp) used between macOS sections.
            item { HeartRateSection(vm = vm, hrMax = hrMax) }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                val monitorVitals = latestVitals(days, UnitPrefs.temperature(LocalContext.current))
                    .filter { it.key in HEALTH_MONITOR_KEYS }
                VitalsSection(
                    title = uiString(R.string.l10n_health_screen_vital_signs_e7d9e1b1),
                    overline = "Latest readings",
                    trailing = null,
                    vitals = monitorVitals,
                    onVitalClick = onVitalClick,
                    captionMode = VitalCaptionMode.AS_OF,
                )
            }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                BodyCompositionSection(
                    vm = vm,
                    profile = profile,
                    refreshKey = metricDataVersion,
                    recentDays = days,
                    activeDeviceId = activeDeviceId,
                )
            }
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                BiomarkerTrendsSection(
                    vm = vm,
                    refreshKey = metricDataVersion,
                    recentDays = days,
                    activeDeviceId = activeDeviceId,
                    onVitalClick = onVitalClick,
                )
            }
            // FITNESS AGE — the weekly Saturday number from the engine (resting HR + activity vs your
            // age), with an honest readiness checklist behind a tap. Authoritative value comes from the
            // metricSeries the IntelligenceEngine writes; readiness is derived from what this screen sees.
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                FitnessAgeSection(
                    vm = vm,
                    days = days,
                    profile = profile,
                    activeDeviceId = activeDeviceId,
                )
            }
            item {
                VitalitySection(
                    vm = vm,
                    days = days,
                    profile = profile,
                    activeDeviceId = activeDeviceId,
                )
            }
            // SKIN TEMPERATURE (v5 pillar) — Cycle awareness (opt-in), Body clock + an illness heads-up,
            // each from a pure engine RESULT the ViewModel publishes. A section of Health, never its own
            // destination (umbrella §2.4). Non-clinical observations about your own numbers.
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                SkinTempSuiteSection(
                    signals = v5Signals,
                    cycleEnabled = cycleEnabled,
                    // #801: gate the cycle-awareness OPT-IN to profiles it can apply to (sex-gated, pure
                    // helper). Cycle phase is read from the menstrual skin-temperature shift, so the
                    // invitation is NOT offered for male profiles. Matches iOS SkinTempSection.cycleOptInApplies.
                    cycleOptInApplies = cycleProfileEligible,
                    onEnableCycle = { vm.setCycleTrackingEnabled(true) },
                    // #801: symmetric off-control. Cycle awareness could be turned ON here but only OFF from
                    // Automations; let the user turn it off in-place where they turned it on.
                    onTurnOffCycle = { vm.setCycleTrackingEnabled(false) },
                    onLogPeriod = {
                        cycleScope.launch {
                            if (!vm.logPeriodStart(LocalDate.now().toString())) {
                                Toast.makeText(context, "Couldn’t log the period start. Please try again.", Toast.LENGTH_SHORT).show()
                            }
                        }
                    },
                    onOpenCycleTracker = { cycleTrackerPresented = true },
                )
            }
            // CONTRIBUTORS (README screen #5, recovery detail) — the signals behind recovery as
            // labelled progress bars in the shared stage/zone bar style, mirroring Today's section.
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item { HealthContributorsSection(today) }
            // RECORDS & SOURCES (Swift parity) — deep-link rows into the local Lab Book and the
            // "Your Data, Fused" record, so both are discoverable from Health, not just the drawer.
            item { Spacer(Modifier.height(Metrics.selectorTopUp)) }
            item {
                RecordsAndSourcesSection(
                    onOpenLabBook = onOpenLabBook,
                    onOpenFusedRecord = onOpenFusedRecord,
                )
            }
        }
    }

    if (cycleTrackerPresented) {
        CycleTrackerSheet(
            result = v5Signals?.cycle ?: cycleTrackingLearningResult(),
            periodStarts = periodStarts,
            dailyLogs = cycleDailyLogs,
            onLogPeriodStart = { vm.logPeriodStart(it) },
            onDeletePeriodStart = { vm.deletePeriodStart(it) },
            onDeleteAllPeriodStarts = { vm.deleteAllPeriodStarts() },
            onSaveDailyLog = { day, flow, symptoms ->
                vm.saveCycleDailyLog(day, flow, symptoms)
            },
            onDeleteDailyLog = { vm.deleteCycleDailyLog(it) },
            onDeleteAllDailyLogs = { vm.deleteAllCycleDailyLogs() },
            onDismiss = { cycleTrackerPresented = false },
        )
    }
}

// MARK: - Body composition

private data class BodyCompositionReading(
    val value: Double,
    val day: String?,
    val source: String,
)

private data class BodyCompositionSnapshot(
    val weight: BodyCompositionReading? = null,
    val bmi: BodyCompositionReading? = null,
    val bodyFat: BodyCompositionReading? = null,
    val leanMass: BodyCompositionReading? = null,
)

/**
 * Honest whole-body summary inspired by the segmental reference. NOOP renders only measurements the
 * import actually carries; it never manufactures arm, leg, or trunk distribution without compatible
 * segmental hardware.
 */
@Composable
private fun BodyCompositionSection(
    vm: AppViewModel,
    profile: ProfileStore,
    refreshKey: Long,
    recentDays: List<DailyMetric>,
    activeDeviceId: String,
) {
    val context = LocalContext.current
    val massUnit = UnitPrefs.mass(context)
    var snapshot by remember { mutableStateOf(BodyCompositionSnapshot()) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(refreshKey, recentDays, activeDeviceId) {
        val (weight, bmi, bodyFat, leanMass) = coroutineScope {
            listOf("weight", "bmi", "body_fat", "lean_mass").map { key ->
                async {
                    runCatching {
                        vm.repo.resolvedSeries(
                            key = key,
                            preferredSource = "apple-health",
                            from = "0000-01-01",
                            to = "9999-12-31",
                            strapDeviceId = activeDeviceId,
                        ).points.lastOrNull()
                    }.getOrNull()
                }
            }.awaitAll()
        }
        snapshot = BodyCompositionSnapshot(
            weight = validBodyCompositionReading(weight, 20.0..400.0),
            bmi = validBodyCompositionReading(bmi, 5.0..100.0),
            bodyFat = validBodyCompositionReading(bodyFat, 0.0..100.0),
            leanMass = validBodyCompositionReading(leanMass, 5.0..400.0),
        )
        loaded = true
    }

    val currentWeight = snapshot.weight ?: BodyCompositionReading(
        value = profile.weightKg,
        day = null,
        source = "profile",
    )
    val currentBmi = snapshot.bmi ?: run {
        val metres = profile.heightCm / 100.0
        val value = if (metres > 0.0) currentWeight.value / (metres * metres) else Double.NaN
        value.takeIf { it.isFinite() && it in 5.0..100.0 }?.let {
            BodyCompositionReading(it, currentWeight.day, "profile")
        }
    }
    val latestDay = listOfNotNull(
        snapshot.weight?.day,
        snapshot.bmi?.day,
        snapshot.bodyFat?.day,
        snapshot.leanMass?.day,
    ).maxOrNull();

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = uiString(R.string.appwide_health_body_composition_title),
            overline = uiString(R.string.appwide_health_body_composition_overline),
            trailing = latestDay?.let { asOfLabel(it)?.removePrefix("as of ") },
        )
        NoopCard(tint = Palette.metricCyan) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space16),
                ) {
                    BodyCompositionVisual(snapshot.bodyFat?.value)
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                    ) {
                        Overline(uiString(R.string.appwide_health_body_composition_weight))
                        Text(
                            UnitFormatter.massFromKilograms(currentWeight.value, massUnit),
                            style = NoopType.number(30f),
                            color = Palette.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            bodyCompositionCaption(currentWeight),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }

                Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                ) {
                    BodyCompositionMetric(
                        label = uiString(R.string.appwide_health_body_composition_bmi),
                        value = currentBmi?.let { String.format(Locale.US, "%.1f", it.value) } ?: "-",
                        detail = currentBmi?.let(::bodyCompositionCaption)
                            ?: uiString(R.string.appwide_health_body_composition_no_value),
                        modifier = Modifier.weight(1f),
                    )
                    BodyCompositionMetric(
                        label = uiString(R.string.appwide_health_body_composition_body_fat),
                        value = snapshot.bodyFat?.let { formatBodyFatPct(it.value) } ?: "-",
                        detail = snapshot.bodyFat?.let(::bodyCompositionCaption)
                            ?: uiString(R.string.appwide_health_body_composition_no_measurement),
                        modifier = Modifier.weight(1f),
                    )
                    BodyCompositionMetric(
                        label = uiString(R.string.appwide_health_body_composition_lean_mass),
                        value = snapshot.leanMass?.let {
                            UnitFormatter.massFromKilograms(it.value, massUnit)
                        } ?: "-",
                        detail = snapshot.leanMass?.let(::bodyCompositionCaption)
                            ?: uiString(R.string.appwide_health_body_composition_no_measurement),
                        modifier = Modifier.weight(1f),
                    )
                }

                Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
                BodyTargetRow(
                    currentWeightKg = currentWeight.value,
                    targetWeightKg = profile.targetWeightKg,
                    massUnit = massUnit,
                )
            }
        }

        Text(
            uiString(R.string.appwide_health_body_composition_disclaimer),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
        if (!loaded) {
            Text(
                uiString(R.string.appwide_health_body_composition_loading),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun BodyCompositionVisual(bodyFatPct: Double?) {
    val fraction = ((bodyFatPct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
    Box(modifier = Modifier.size(108.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 8.dp.toPx()
            drawCircle(
                color = Palette.hairlineStrong,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            if (bodyFatPct != null) {
                drawArc(
                    color = Palette.metricAmber,
                    startAngle = -90f,
                    sweepAngle = 360f * fraction,
                    useCenter = false,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Metrics.space2),
        ) {
            Icon(
                Icons.Filled.Person,
                contentDescription = null,
                tint = Palette.metricCyan,
                modifier = Modifier.size(31.dp),
            )
            Text(
                bodyFatPct?.let(::formatBodyFatPct) ?: "-",
                style = NoopType.captionNumber,
                color = Palette.textPrimary,
            )
            Text(
                uiString(R.string.appwide_health_body_composition_whole_body),
                style = NoopType.overline,
                color = Palette.textTertiary,
                maxLines = 1,
            )
        }
    }
}

private fun formatBodyFatPct(value: Double): String =
    String.format(Locale.US, "%.1f%%", value)

@Composable
private fun BodyCompositionMetric(
    label: String,
    value: String,
    detail: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.heightIn(min = 68.dp),
        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        Text(
            label,
            style = NoopType.overline,
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            value,
            style = NoopType.number(18f),
            color = Palette.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            detail,
            style = NoopType.caption,
            color = Palette.textTertiary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun BodyTargetRow(
    currentWeightKg: Double,
    targetWeightKg: Double?,
    massUnit: MassUnit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .clip(RoundedCornerShape(Metrics.cornerSm))
                .background(Palette.accent.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.TrackChanges,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(19.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space2),
        ) {
            Overline(uiString(R.string.appwide_health_body_composition_target_weight))
            if (targetWeightKg != null) {
                val delta = currentWeightKg - targetWeightKg
                val distance = UnitFormatter.massFromKilograms(kotlin.math.abs(delta), massUnit)
                Text(
                    when {
                        kotlin.math.abs(delta) < 0.05 ->
                            uiString(R.string.appwide_health_body_composition_target_reached)
                        delta > 0 ->
                            uiString(R.string.appwide_health_body_composition_target_above, distance)
                        else ->
                            uiString(R.string.appwide_health_body_composition_target_below, distance)
                    },
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                )
                Text(
                    uiString(
                        R.string.appwide_health_body_composition_target_detail,
                        UnitFormatter.massFromKilograms(targetWeightKg, massUnit),
                    ),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            } else {
                Text(
                    uiString(R.string.appwide_health_body_composition_no_target),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Text(
                    uiString(R.string.appwide_health_body_composition_add_target),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

private fun validBodyCompositionReading(
    point: com.noop.data.WhoopRepository.ResolvedMetricPoint?,
    range: ClosedRange<Double>,
): BodyCompositionReading? {
    if (point == null || !point.value.isFinite() || point.value !in range) return null
    return BodyCompositionReading(point.value, point.day, point.source)
}

private fun bodyCompositionCaption(reading: BodyCompositionReading): String {
    val source = when (reading.source) {
        "apple-health" -> "Apple Health"
        "health-connect" -> "Health Connect"
        "profile" -> "Profile"
        else -> reading.source
    }
    return listOfNotNull(reading.day?.let { asOfLabel(it)?.removePrefix("as of ") }, source)
        .joinToString(" · ")
}

// MARK: - Biomarker trends

private data class BiomarkerTrend(
    val key: String,
    val title: String,
    val points: List<Pair<String, Double>>,
)

private data class BiomarkerTrendSnapshot(
    val latestDay: String? = null,
    val latestValue: Double? = null,
    val sparklineValues: List<Double>? = null,
    val stale: Boolean = false,
)

/**
 * Measured history shared with iOS. Every series uses the product-facing resolver, so a Health
 * Connect measurement fills a day when the preferred Apple/strap source has no value. Sparse or
 * stale observations retain their exact date but are never connected into a misleading line.
 */
@Composable
private fun BiomarkerTrendsSection(
    vm: AppViewModel,
    refreshKey: Long,
    recentDays: List<DailyMetric>,
    activeDeviceId: String,
    onVitalClick: (String) -> Unit,
) {
    val context = LocalContext.current
    val massUnit = UnitPrefs.mass(context)
    var trends by remember { mutableStateOf<List<BiomarkerTrend>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(refreshKey, recentDays, activeDeviceId) {
        val specs = listOf(
            "weight" to "Weight",
            "hrv" to "HRV",
            "rhr" to "Resting HR",
            "body_fat" to "Body Fat",
            "lean_mass" to "Lean Body Mass",
            "vo2max" to "VO₂ Max",
        )
        trends = coroutineScope {
            specs.map { (key, title) ->
                async {
                    val preferredSource =
                        if (key == "hrv" || key == "rhr") "my-whoop" else "apple-health"
                    val points = runCatching {
                        vm.repo.resolvedSeries(
                            key = key,
                            preferredSource = preferredSource,
                            from = "0000-01-01",
                            to = "9999-12-31",
                            strapDeviceId = activeDeviceId,
                        ).values
                    }.getOrDefault(emptyList())
                    BiomarkerTrend(key = key, title = title, points = points)
                }
            }.awaitAll()
        }
        loaded = true
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            uiString(R.string.appwide_health_biomarker_trends_title),
            overline = uiString(R.string.appwide_health_biomarker_trends_overline),
        )
        NoopCard(padding = 0.dp) {
            Column {
                trends.forEachIndexed { index, trend ->
                    BiomarkerTrendRow(
                        trend = trend,
                        massUnit = massUnit,
                        onClick = { onVitalClick(trend.key) },
                    )
                    if (index < trends.lastIndex) {
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .padding(start = 62.dp)
                                .height(1.dp)
                                .background(Palette.hairline),
                        )
                    }
                }
                if (!loaded) {
                    Text(
                        uiString(R.string.appwide_health_biomarker_trends_loading),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(Metrics.cardPadding),
                    )
                }
            }
        }
        Text(
            uiString(R.string.appwide_health_biomarker_trends_disclaimer),
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

@Composable
private fun BiomarkerTrendRow(
    trend: BiomarkerTrend,
    massUnit: MassUnit,
    onClick: () -> Unit,
) {
    val snapshot = remember(trend.points) { biomarkerTrendSnapshot(trend.points) };
    val color = biomarkerTrendColor(trend.key);
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Metrics.space16)
            .heightIn(min = 72.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Palette.surfaceInset),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = biomarkerTrendIcon(trend.key),
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(Metrics.space2),
        ) {
            Text(trend.title, style = NoopType.headline, color = Palette.textPrimary)
            Text(
                biomarkerTrendSubtitle(trend.key, snapshot, massUnit),
                style = NoopType.footnote,
                color = if (snapshot.latestValue == null) Palette.textTertiary else Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        val values = snapshot.sparklineValues
        if (values != null) {
            Sparkline(
                values = values,
                color = color,
                modifier = Modifier.width(82.dp).height(30.dp),
            )
        } else {
            Box(Modifier.width(64.dp).height(2.dp).background(Palette.hairlineStrong))
        }
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(16.dp),
        )
    }
}

private fun biomarkerTrendSnapshot(
    points: List<Pair<String, Double>>,
    today: LocalDate = LocalDate.now(),
): BiomarkerTrendSnapshot {
    val dated = points.mapNotNull { (day, value) ->
        val date = runCatching { LocalDate.parse(day) }.getOrNull()
        if (date == null || date.isAfter(today) || !value.isFinite()) null else Triple(day, value, date)
    }.sortedBy { it.third }
    val latest = dated.lastOrNull() ?: return BiomarkerTrendSnapshot()
    val ageDays = java.time.temporal.ChronoUnit.DAYS.between(latest.third, today).coerceAtLeast(0)
    val stale = ageDays > 30
    val recent = dated.filter { !it.third.isBefore(today.minusDays(90)) }
    val connected = !stale && recent.size > 1 &&
        recent.zipWithNext().all { (left, right) ->
            java.time.temporal.ChronoUnit.DAYS.between(left.third, right.third) in 0..3
        }
    return BiomarkerTrendSnapshot(
        latestDay = latest.first,
        latestValue = latest.second,
        sparklineValues = if (connected) recent.map { it.second } else null,
        stale = stale,
    )
}

private fun biomarkerTrendSubtitle(
    key: String,
    snapshot: BiomarkerTrendSnapshot,
    massUnit: MassUnit,
): String {
    val value = snapshot.latestValue ?: return "No recorded value"
    val day = snapshot.latestDay ?: return "No recorded value"
    val formatted = when (key) {
        "weight", "lean_mass" -> UnitFormatter.massFromKilograms(value, massUnit)
        "hrv" -> "${value.roundToInt()} ms"
        "rhr" -> "${value.roundToInt()} bpm"
        "body_fat" -> String.format(Locale.US, "%.1f%%", value)
        "vo2max" -> String.format(Locale.US, "%.1f ml/kg/min", value)
        else -> String.format(Locale.US, "%.1f", value)
    }
    val date = asOfLabel(day)?.removePrefix("as of ") ?: day
    return if (snapshot.stale) "$formatted · Last recorded $date" else "$formatted · $date"
}

private fun biomarkerTrendColor(key: String): Color = when (key) {
    "hrv" -> Palette.metricPurple
    "rhr" -> Palette.metricRose
    "vo2max" -> Palette.metricCyan
    "body_fat" -> Palette.metricAmber
    "lean_mass" -> Palette.statusPositive
    else -> Palette.accent
}

private fun biomarkerTrendIcon(key: String): ImageVector = when (key) {
    "hrv" -> Icons.Filled.MonitorHeart
    "rhr" -> Icons.Filled.Favorite
    "vo2max" -> Icons.Filled.Air
    "body_fat" -> Icons.Filled.WaterDrop
    else -> Icons.Filled.Person
}

// MARK: - Sync status + "Sync now" (#364)
//
// Manual "Sync now" control + honest sync status, mirroring HealthView.swift's SyncStatusSection (which
// itself mirrors this screen's Android Sync-now button). Reads only LiveState (connection + backfill +
// last-sync), so the ~1Hz HR hero doesn't drag it through re-renders. The button reaches the BLE engine's
// gated entry point (vm.syncNow → WhoopBleClient.syncNow) — a no-op when no strap is connected or a sync
// is already running, so it's safe regardless of state. The status line explains itself when no strap is
// connected; while a sync runs it shows the shared in-progress note + live chunk count; otherwise it
// shows when history last synced.

@Composable
private fun SyncStatusSection(vm: AppViewModel, onSyncNow: () -> Unit) {
    // PERF (#scroll-jank): collect the BLE live state HERE, inside the leaf, instead of receiving it
    // from the screen body. The live object identity changes ~1Hz with each HR tick; reading it at body
    // scope recomposed the whole Health screen. Scoping the collection to this section confines that
    // ~1Hz churn to the (cheap) sync card alone. The fields read below are slow-changing; only this
    // leaf re-runs per tick. Appearance + behaviour identical.
    val live by vm.live.collectAsStateWithLifecycle()
    // The strap link is usable for a manual offload kick (matches WhoopBleClient.syncNow's own gate).
    val canSync = live.connected && live.bonded && !live.backfilling
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            "Sync",
            overline = stringResource(R.string.appwide_health_band_history),
            trailing = if (live.connected) (if (live.bonded) "Connected" else "Pairing…") else "Offline",
        )

        NoopCard(tint = Palette.chargeColor) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                // Status line: an in-progress note while syncing (with the live chunk count), an honest
                // "not connected" pill, a last-synced read-out, else a "ready to sync"/"pairing" pill.
                when {
                    live.backfilling -> SyncingHistoryNote(
                        chunks = live.syncChunksThisSession,
                        rows = live.syncRowsThisSession,
                        newestDataUnix = live.syncDataNewestAt,
                        startedAt = live.syncStartedAt,
                        lastDurableProgressAt = live.syncLastDurableProgressAt,
                    )
                    !live.connected -> StatePill(
                        title = uiString(R.string.l10n_health_screen_no_strap_connected_fb37b99e),
                        tone = StrandTone.Neutral,
                        showsDot = false,
                    )
                    live.lastSyncError != null -> Column(
                        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
                    ) {
                        StatePill(
                            title = stringResource(R.string.health_sync_needs_attention),
                            tone = StrandTone.Warning,
                            showsDot = true,
                        )
                        Text(
                            live.lastSyncError!!,
                            style = NoopType.footnote,
                            color = Palette.statusWarning,
                        )
                    }
                    live.lastSyncAt != null -> Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                    ) {
                        StatePill(title = uiString(R.string.l10n_health_screen_history_synced_8339779d), tone = StrandTone.Positive)
                        Text(
                            relativeAgo(live.lastSyncAt!!),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    else -> StatePill(
                        title = if (live.bonded) "Ready to sync" else "Pairing…",
                        tone = StrandTone.Accent,
                        showsDot = true,
                        pulsing = !live.bonded,
                    )
                }

                // "Sync now" - routed through the unified NoopButton (Secondary, full-width) so the label
                // sits centred at the standard control height like every other primary control, matching
                // HealthView.swift's `NoopButton(..., kind: .secondary, fullWidth: true)`. Disabled unless
                // connected+bonded and not already syncing; the gated BLE entry point is a safe no-op
                // otherwise. (Total pending records are unknowable from the protocol, so no progress %.)
                NoopButton(
                    text = if (live.backfilling) "Syncing…" else "Sync now",
                    leadingIcon = Icons.Filled.Sync,
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = canSync,
                    modifier = Modifier.semantics {
                        contentDescription = if (canSync) {
                            "Sync now. Pulls Noop Band's stored history immediately, without waiting " +
                                "for the next automatic sync."
                        } else if (live.backfilling) {
                            "Sync now. A sync is already in progress."
                        } else {
                            "Sync now. Connect Noop Band first."
                        }
                    },
                    onClick = onSyncNow,
                )

                Text(
                    syncHelperText(live),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The helper line below the Sync-now button: explains the current state (syncing / offline / pairing /
 *  ready), copy-matched to HealthView.swift's SyncStatusSection.helperText. */
private fun syncHelperText(live: LiveState): String = when {
    live.backfilling -> "Pulling Noop Band's stored history. Rows appear as they are saved, and you can " +
        "keep using Noop while a deep oldest-first backlog continues across passes."
    !live.connected -> "Connect Noop Band to sync its stored history. Until then, only imported data " +
        "shows here."
    !live.bonded -> "Finishing the pairing handshake. Sync now becomes available once Noop Band is paired."
    live.lastSyncError != null -> "Your stored history remains on Noop Band. Tap Sync now to retry when " +
        "the connection is ready."
    else -> "Syncs Noop Band's stored history right away instead of waiting for the next automatic sync."
}

// MARK: - Records & sources (Swift parity) — discoverable deep-links into the on-device records
//
// Mirrors the Swift Health screen's "Records & sources" section: two clickable rows that route into
// the Lab Book (your own bloods / BP / body numbers) and the fused multi-source record ("Your Data,
// Fused"). Both live entirely on this phone, so the overline says so. Plain navigation rows in the
// house NoopCard style with an icon, a title/subtitle and a trailing chevron, each carrying a single
// combined contentDescription for screen readers.

@Composable
private fun RecordsAndSourcesSection(
    onOpenLabBook: () -> Unit,
    onOpenFusedRecord: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader("Records & sources", overline = "On this phone")
        RecordRow(
            icon = Icons.AutoMirrored.Filled.MenuBook,
            tint = Palette.metricCyan,
            title = uiString(R.string.l10n_health_screen_lab_book_f966c140),
            subtitle = "Your bloods, BP and body numbers. Kept private here.",
            onClick = onOpenLabBook,
        )
        RecordRow(
            icon = Icons.AutoMirrored.Filled.CompareArrows,
            tint = Palette.accent,
            title = uiString(R.string.l10n_health_screen_your_data_fused_a740fd4a),
            subtitle = "The best-sourced number per metric, across your bands.",
            onClick = onOpenFusedRecord,
        )
    }
}

/** One navigation row in the Records & sources section: a tinted glyph, a title + subtitle, and a
 *  trailing chevron, wrapped in a clickable NoopCard with a combined accessibility label. */
@Composable
private fun RecordRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    // liquidPress on the whole tappable row — the SAME interactionSource drives the clickable + the press
    // so the card settles inward on tap (the pilot LiquidPressStyle feel). Nav route is unchanged.
    val interaction = remember { MutableInteractionSource() }
    NoopCard(
        modifier = Modifier
            .liquidPress(interaction)
            .clickable(
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .semantics { contentDescription = uiString(R.string.l10n_health_screen_title_subtitle_8d9004e8, title, subtitle) },
        padding = Metrics.space16,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(RoundedCornerShape(Metrics.cornerSm))
                    .background(tint.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.space2)) {
                Text(title, style = NoopType.headline, color = Palette.textPrimary)
                Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
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

// MARK: - Skin-temperature suite (v5 pillar) — a Health section
//
// Composes the locked SkinTempCardsScreen cards from the engine RESULTS the ViewModel publishes:
//   • Cycle awareness — OPT-IN (default OFF). Shows the opt-in card until enabled, then the result card.
//   • Body clock — rendered only when the engine returned a phase estimate (the activity-bin input pipe
//     is a future source; until then it's silently absent rather than a faked card).
//   • Illness heads-up — rendered only when the engine returned a non-quiet level, mirroring the existing
//     amber-alert treatment; never a diagnosis.
// Every card carries its own privacy + non-clinical copy; the section header keeps the umbrella framing.

/**
 * #801: whether the cycle-awareness OPT-IN invitation should be offered for a profile with this [sex]
 * value. Cycle phase is read from the menstrual skin-temperature shift, so the invitation is NOT offered
 * for a male profile; "female"/"nonbinary" (and any unrecognised value, default-show rather than hide)
 * qualify. Pure so it's unit-tested directly; mirrors the iOS SkinTempSection.cycleOptInApplies
 * (`profile.sex.lowercased() != "male"`). ProfileStore.sex is "male" | "female" | "nonbinary".
 */
internal fun cycleOptInApplies(sex: String): Boolean = sex.lowercase(Locale.US) != "male"

@Composable
private fun SkinTempSuiteSection(
    signals: V5HealthSignals.Snapshot?,
    cycleEnabled: Boolean,
    // #801: whether the cycle-awareness opt-in invitation is offered for this profile (sex-gated).
    cycleOptInApplies: Boolean,
    onEnableCycle: () -> Unit,
    // #801: symmetric off-control, surfaced on the live card.
    onTurnOffCycle: () -> Unit,
    onLogPeriod: () -> Unit,
    onOpenCycleTracker: () -> Unit,
) {
    val showsCycleSection = cycleEnabled || cycleOptInApplies
    val hasTemperatureResult =
        signals?.illness?.level?.let { it != IllnessSignalEngine.Level.QUIET } == true ||
            signals?.bodyClock != null

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        if (showsCycleSection) {
            SectionHeader(
                stringResource(R.string.appwide_cycle_health_section_title),
                overline = stringResource(R.string.appwide_cycle_health_overline),
            )

            if (cycleEnabled) {
                CycleAwarenessCard(
                    result = signals?.cycle ?: cycleTrackingLearningResult(),
                    onLogPeriod = onLogPeriod,
                    onOpenDetail = onOpenCycleTracker,
                    onTurnOff = onTurnOffCycle,
                )
            } else {
                CycleAwarenessOptInCard(onEnable = onEnableCycle)
            }
        }

        SectionHeader("Skin Temperature", overline = "From your nightly readings")

        signals?.illness?.let { illness ->
            if (illness.level != IllnessSignalEngine.Level.QUIET) {
                HeadsUpCard(result = illness, distance = signals.illnessDistance)
            }
        }

        signals?.bodyClock?.let { BodyClockCard(estimate = it) }

        if (!hasTemperatureResult) {
            Text(
                stringResource(R.string.appwide_cycle_health_missing_temperature),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
        }

        Text(
            uiString(R.string.l10n_health_screen_cycle_phase_body_clock_and_illness_59e2d9a4) +
                "your own nightly temperature, heart rate and HRV: observations about your own numbers, " +
                "never a diagnosis. They never leave this phone.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Contributors (README screen #5) — labelled progress bars on the health detail
//
// "CONTRIBUTORS" - the signals that drive recovery (HRV / Resting HR / Sleep / Respiratory), each as a
// labelled progress bar in the shared stage/zone bar style (inset track, round-capped metric-hue fill,
// right-aligned read-out). Per the Titanium & Gold recovery detail, HRV + Resting HR read on the gold
// recovery world and Sleep + Respiratory on the blue sleep world. A SOLID/CALIBRATING pill states data
// confidence. Fractions are presentation-only normalisations of today's row to typical adult spans —
// no scoring change. Mirrors the Today RecoveryContributorsSection so the two screens read identically.

@Composable
private fun HealthContributorsSection(day: DailyMetric?) {
    val hrv = day?.avgHrv
    val rhr = day?.restingHr?.toDouble()
    val sleepMin = day?.totalSleepMin
    val resp = day?.respRateBpm
    if (hrv == null && rhr == null && sleepMin == null && resp == null) return

    // SOLID once recovery has been scored from these signals; CALIBRATING while the baseline seeds.
    val solid = day.recovery != null
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.weight(1f)) {
                SectionHeader("Contributors", overline = "Recovery")
            }
            StatePill(
                title = if (solid) "SOLID" else "CALIBRATING",
                tone = if (solid) StrandTone.Accent else StrandTone.Neutral,
            )
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
                // Recovery-world tints, matched to HealthView.swift's RecoveryContributorsSection (NO gold):
                // HRV = teal (metricCyan), Resting HR = WHOOP green (chargeColor, the recovery contributor
                // hue), Sleep + Respiratory share the blue sleep world (sleepLight). Each bar reveals with
                // a staggered fade+rise, mirroring iOS `.staggeredAppear(index:)`.
                ContributorBar(
                    label = "HRV",
                    readout = hrv?.let { "${it.roundToInt()} ms" } ?: "-",
                    fraction = hrv?.let { (it - 20.0) / 100.0 },
                    color = Palette.metricCyan,
                    modifier = Modifier.staggeredAppear(0),
                )
                ContributorBar(
                    label = uiString(R.string.l10n_health_screen_resting_hr_26677094),
                    readout = rhr?.let { "${it.roundToInt()} bpm" } ?: "-",
                    fraction = rhr?.let { 1.0 - ((it - 40.0) / 40.0) },
                    color = Palette.chargeColor,
                    modifier = Modifier.staggeredAppear(1),
                )
                ContributorBar(
                    label = uiString(R.string.l10n_health_screen_sleep_3cac34e6),
                    readout = sleepMin?.let { sleepHoursText(it) } ?: "-",
                    fraction = sleepMin?.let { (it / 60.0) / 8.0 },
                    color = Palette.sleepLight,
                    modifier = Modifier.staggeredAppear(2),
                )
                ContributorBar(
                    label = uiString(R.string.l10n_health_screen_respiratory_1cd8c175),
                    readout = resp?.let { String.format(Locale.US, "%.1f rpm", it) } ?: "-",
                    fraction = resp?.let { 1.0 - ((it - 12.0) / 8.0) },
                    color = Palette.sleepLight,
                    modifier = Modifier.staggeredAppear(3),
                )
                Text(
                    uiString(R.string.l10n_health_screen_baselines_learned_on_device_over_14_c107f375) +
                        "typical adult range (approximate, not medical advice).",
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** "Hh Mm" for sleep minutes, matching the Today Rest read-out. */
private fun sleepHoursText(totalMin: Double): String {
    val t = totalMin.roundToInt()
    return "${t / 60}h ${t % 60}m"
}

/** One labelled contributor bar: a label + right-aligned read-out over the NOOP signature segmented
 *  [PipBar] (metric-hue pips that cascade up to the strength on appear/change), mirroring
 *  HealthView.swift's `ContributorBar` / `PipBar(value:tint:)`. A null fraction renders an empty
 *  (calibrating) bar — no fabricated fill. */
@Composable
private fun ContributorBar(
    label: String,
    readout: String,
    fraction: Double?,
    color: Color,
    modifier: Modifier = Modifier,
) {
    // PipBar takes a 0…100 value; map the presentation fraction up onto that span (null → empty bar).
    val strength = fraction?.coerceIn(0.0, 1.0)?.let { (it * 100.0).toFloat() } ?: 0f
    Column(
        modifier = modifier.semantics { contentDescription = uiString(R.string.l10n_health_screen_label_readout_3f166607, label, readout) },
        verticalArrangement = Arrangement.spacedBy(Metrics.space6),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Overline(label, modifier = Modifier.weight(1f))
            Text(readout, style = NoopType.captionNumber, color = Palette.textPrimary)
        }
        PipBar(value = strength, tint = color)
    }
}

// MARK: - Fitness Age
//
// The on-device "Fitness Age": a weekly number (the engine keys it to each week's Saturday) that maps
// resting HR + recent activity against population norms for your age. The AUTHORITATIVE value is the
// latest "fitness_age" the IntelligenceEngine writes into metricSeries under the computed "-noop"
// source — this section only READS it; it never recomputes the headline. Honest framing throughout:
// it's a broad fitness comparison (roughly ±19–21 model years), never a biological age, and waist lives under
// "Unlocks your VO₂max", never as if they sharpen the age. When no value exists yet we show the
// readiness checklist instead, so the user knows exactly what's still needed.

/** Fitness Age readiness from what a screen can see: RHR coverage over the last 7 merged daily rows
 *  (drives the "N more nights" countdown), a scored-strain day as the activity signal, and the profile
 *  basics. Shared by the Health hub's [FitnessAgeSection] and the Today card's [VitalDetailScreen]
 *  tap-through so ONE gate feeds both surfaces (no drift). Both coverage counts feed the not-ready lead;
 *  the weekly value remains the authority. */
@Composable
private fun rememberFitnessReadiness(
    days: List<DailyMetric>,
    profile: ProfileStore,
): Triple<Int, Int, FitnessAgeReadiness> {
    val rhrDays = remember(days) { days.takeLast(7).count { it.restingHr != null } }
    val activityDays = remember(days) { days.takeLast(7).count { it.strain != null } }
    val readiness = remember(
        days, profile.age, profile.sex, profile.waistCm,
        profile.ageInputConfirmed, profile.sexInputConfirmed,
    ) {
        FitnessAgeEngine.assessReadiness(
            hasAge = profile.ageInputConfirmed && FitnessAgeEngine.supportsAge(profile.age.toDouble()),
            hasSex = profile.sexInputConfirmed && FitnessAgeEngine.supportsSex(profile.sex),
            rhrDays = rhrDays,
            activityDays = activityDays,
            hasWaist = profile.waistCm > 0,
        )
    }
    return Triple(rhrDays, activityDays, readiness)
}

@Composable
private fun FitnessAgeSection(
    vm: AppViewModel,
    days: List<DailyMetric>,
    profile: ProfileStore,
    activeDeviceId: String,
) {
    val context = LocalContext.current
    // Latest weekly value + its optional VO₂max companion, read once (metricSeries has no Flow, so we
    // re-read whenever the merged history changes — a fresh sync/import is what moves these).
    var fitnessAge by remember { mutableStateOf<Double?>(null) }
    var fitnessAgeHistory by remember { mutableStateOf<List<Pair<String, Double>>>(emptyList()) }
    var vo2max by remember { mutableStateOf<Double?>(null) }
    var measuredVo2max by remember { mutableStateOf<Double?>(null) }
    // Manual-refresh plumbing: the not-ready card's refresh button recomputes Fitness Age NOW and bumps
    // this tick, which re-keys the read below so a freshly written value shows without waiting for a sync.
    var refreshTick by remember { mutableStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    val profileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val ageMetricDataVersion by vm.ageMetricDataVersion.collectAsStateWithLifecycle()
    val profileState = remember(profileVersion) { profile.ageMetricStateToken }
    var loadedProfileState by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(days, refreshTick, profileVersion, ageMetricDataVersion, activeDeviceId) {
        if (!profile.fitnessInputsConfirmed ||
            !FitnessAgeEngine.supportsAge(profile.age.toDouble()) ||
            !FitnessAgeEngine.supportsSex(profile.sex)
        ) {
            fitnessAge = null
            fitnessAgeHistory = emptyList()
            vo2max = null
            measuredVo2max = null
            loadedProfileState = profileState
            return@LaunchedEffect
        }
        // Fitness Age is weekly and sparse; retain the last eight persisted points for the visible graph.
        val faSeries = runCatching {
            vm.repo.metricSeriesComputedUnion(
                activeDeviceId, "fitness_age", "0000-01-01", "9999-12-31",
            ).takeLast(8)
        }.getOrDefault(emptyList())
        val fa = faSeries.lastOrNull()?.value
        val vo2 = runCatching {
            vm.repo.latestMetricComputedUnion(activeDeviceId, "vo2max_est")?.value
        }.getOrNull()
        val measuredVo2 = runCatching {
            val appleHealth = vm.repo.appleDaily(
                WhoopRepository.APPLE_HEALTH_SOURCE,
                "0000-01-01",
                "9999-12-31",
            ).asReversed().firstNotNullOfOrNull { it.vo2max }
            val healthConnect = vm.repo.appleDaily(
                WhoopRepository.HEALTH_CONNECT_SOURCE,
                "0000-01-01",
                "9999-12-31",
            ).asReversed().firstNotNullOfOrNull { it.vo2max }
            appleHealth ?: healthConnect ?: vm.repo.resolvedSeries(
                key = "vo2max",
                preferredSource = WhoopRepository.APPLE_HEALTH_SOURCE,
                from = "0000-01-01",
                to = "9999-12-31",
                strapDeviceId = activeDeviceId,
            ).points.lastOrNull()?.value
        }.getOrNull()
        val faProfile = runCatching {
            vm.repo.latestMetricComputedUnion(
                activeDeviceId, AgeMetricProfile.FITNESS_AGE_KEY,
            )?.value
        }.getOrNull()
        val vo2Profile = runCatching {
            vm.repo.latestMetricComputedUnion(
                activeDeviceId, AgeMetricProfile.VO2MAX_ESTIMATE_KEY,
            )?.value
        }.getOrNull()
        val acceptsFitnessAge = profile.acceptsFitnessAge(faProfile)
        fitnessAge = fa.takeIf { acceptsFitnessAge }
        fitnessAgeHistory = if (acceptsFitnessAge) {
            faSeries.map { it.day to it.value }
        } else {
            emptyList()
        }
        vo2max = vo2.takeIf { profile.acceptsVO2maxEstimate(vo2Profile) }
        measuredVo2max = measuredVo2
        loadedProfileState = profileState
    }

    // Readiness from the last 7 merged daily rows. Both RHR and observed activity coverage are required;
    // waist remains optional and only unlocks VO₂max.
    val (rhrDays, activityDays, readiness) = rememberFitnessReadiness(days, profile)

    var showChecklist by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        val modelBand = (FitnessAgeEngine.uncertaintyBandYears(profile.sex) ?: 20.0).roundToInt()
        SectionHeader("Fitness Age", overline = "Weekly", trailing = "model ± $modelBand yr")
        val value = fitnessAge.takeIf { loadedProfileState == profileState }
        val visibleVo2max = vo2max.takeIf { loadedProfileState == profileState }
        if (value != null) {
            FitnessAgeHero(
                fitnessAge = value,
                chronoAge = profile.age,
                vo2max = visibleVo2max,
                modelBandYears = modelBand,
                onHowAccurate = { showChecklist = !showChecklist },
                checklistOpen = showChecklist,
            )
            FitnessAgeWeeklyProgress(fitnessAgeHistory)
            FitnessAgeContextCard(
                days = days,
                measuredVo2max = measuredVo2max,
                estimatedVo2max = visibleVo2max,
            )
            if (showChecklist) {
                FitnessReadinessCard(readiness = readiness, headed = false)
            }
        } else {
            // No weekly value yet — lead with a concrete countdown, then the checklist. The refresh button
            // forces the weekly recompute now (from stored data), so a ready user doesn't have to wait.
            FitnessReadinessCard(
                readiness = readiness, headed = true,
                lead = fitnessReadyLead(
                    rhrDays,
                    activityDays,
                    profile.ageInputConfirmed && FitnessAgeEngine.supportsAge(profile.age.toDouble()),
                    profile.sexInputConfirmed && FitnessAgeEngine.supportsSex(profile.sex),
                ),
                refreshing = refreshing,
                onRefresh = {
                    refreshing = true
                    vm.refreshFitnessAgeNow { wrote ->
                        refreshing = false
                        refreshTick++
                        val message = if (wrote) {
                            "Fitness Age updated."
                        } else {
                            "Not enough wear yet - keep Noop Band on overnight."
                        }
                        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
                    }
                },
            )
        }
    }
}

/** Vitality / Wellness Age: an experimental weekly wellness score + age-shaped comparison. It is not
 *  WHOOP Age or biological age. Recomputes the live best/worst factor for the why. */
@Composable
private fun VitalitySection(
    vm: AppViewModel,
    days: List<DailyMetric>,
    profile: ProfileStore,
    activeDeviceId: String,
) {
    var vitality by remember { mutableStateOf<Double?>(null) }
    var bodyAge by remember { mutableStateOf<Double?>(null) }
    val profileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val ageMetricDataVersion by vm.ageMetricDataVersion.collectAsStateWithLifecycle()
    val profileState = remember(profileVersion) { profile.ageMetricStateToken }
    var loadedProfileState by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(days, profileVersion, ageMetricDataVersion, activeDeviceId) {
        if (!profile.ageInputConfirmed || profile.age !in 20..80) {
            vitality = null
            bodyAge = null
            loadedProfileState = profileState
            return@LaunchedEffect
        }
        // Latest-value reads (LIMIT-1 per source) — the full-series `.lastOrNull()` scan is gone (perf).
        val newVitality = runCatching {
            vm.repo.latestMetricComputedUnion(activeDeviceId, "vitality")?.value
        }.getOrNull()
        val newBodyAge = runCatching {
            vm.repo.latestMetricComputedUnion(activeDeviceId, "body_age")?.value
        }.getOrNull()
        val provenance = runCatching {
            vm.repo.latestMetricComputedUnion(
                activeDeviceId, AgeMetricProfile.VITALITY_KEY,
            )?.value
        }.getOrNull()
        val accepted = profile.acceptsVitality(provenance)
        vitality = newVitality.takeIf { accepted }
        bodyAge = newBodyAge.takeIf { accepted }
        loadedProfileState = profileState
    }
    val contributions = remember(days, profile.age) {
        val last21 = days.takeLast(21)
        // Match the STORED headline's aggregation (IntelligenceEngine.medianOfDoubles): median resting HR +
        // HRV (robust to one outlier night) + mean sleep. The shared builder also enforces the provenance
        // boundary: un-sourced DailyMetric.steps is omitted rather than shown as a measured contribution.
        VitalityEngine.contributions(
            IntelligenceEngine.vitalityInputs(last21, profile.age.toDouble()),
        )
    }
    val v = vitality.takeIf { loadedProfileState == profileState }
    val ba = bodyAge.takeIf { loadedProfileState == profileState }
    if (v != null && ba != null) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            SectionHeader("Vitality", overline = "Weekly", trailing = "Wellness Age ${ba.roundToInt()}")
            VitalityHero(vitality = v, bodyAge = ba, chronoAge = profile.age, contributions = contributions)
        }
    }
}

@Composable
private fun VitalityHero(
    vitality: Double, bodyAge: Double, chronoAge: Int,
    contributions: List<VitalityEngine.Contribution>,
) {
    val delta = chronoAge - bodyAge.roundToInt()
    val younger = bodyAge < chronoAge
    val sorted = contributions.sortedBy { it.lnHazard }
    val best = sorted.firstOrNull()
    val worst = sorted.lastOrNull()
    val modelBand = VitalityEngine.bandYears(
        maxOf(VitalityEngine.minFactors, contributions.size),
    ).roundToInt()
    // The frosted liquid hero-card wrapper floats the vessel + white count-up over the sky (the pilot).
    LiquidHeroCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline("Vitality")
                    // The Vitality 0–100 rides a filling LiquidVessel on the charge world, the count-up
                    // number rolled up over it (white, tabular) — the Today HeroScoreVessel idiom. Same
                    // value + fraction (vitality / 100) as the bare headline this replaced.
                    HealthHeroVessel(
                        fraction = vitality / 100.0,
                        value = vitality,
                        tint = Palette.chargeColor,
                        diameter = 96.dp,
                    )
                    Text(uiString(R.string.l10n_health_screen_out_of_100_da0953a8), style = NoopType.footnote, color = Palette.textTertiary)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Overline("Wellness Age")
                    CountUpText(
                        value = bodyAge,
                        format = { it.roundToInt().toString() },
                        style = NoopType.number(34f),
                        color = Palette.textPrimary,
                    )
                    Text(
                        if (delta == 0) "about your age"
                        else "${kotlin.math.abs(delta)} ${yearWord(delta)} ${if (younger) "younger" else "older"}",
                        style = NoopType.footnote,
                        color = if (delta == 0) Palette.textSecondary
                        else if (younger) Palette.statusPositiveText else Palette.statusWarningText,
                    )
                }
            }
            if (best != null && best.lnHazard < 0) {
                Text(uiString(R.string.l10n_health_screen_helping_most_best_label_edee8773, best.label), style = NoopType.footnote, color = Palette.statusPositiveText)
            }
            if (worst != null && worst.lnHazard > 0) {
                Text(uiString(R.string.l10n_health_screen_holding_you_back_worst_label_863a1809, worst.label), style = NoopType.footnote, color = Palette.statusWarningText)
            }
            Text(
                uiString(R.string.wellness_age_model_range, modelBand),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
            Text(
                uiString(R.string.wellness_age_experimental_disclaimer),
                style = NoopType.footnote, color = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Liquid hero-card wrapper + hero vessel (the pilot idiom)
//
// The frosted translucent-black hero-card wrapper (mock rgba(13,14,20,.80), radius 26, white@0.11
// hairline) that floats the hero over the day-of-sky so the vessel + white count-up stay crisp — the
// card does the contrast work, not a muted sky. Byte-matched to the Today pilot's LIQUID_HERO_* values.
private val HEALTH_HERO_FILL: Color =
    Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val HEALTH_HERO_RADIUS: Dp = 26.dp

/** Wrap a hero's content in the frosted liquid glass surface so it floats over the sky backdrop. Applied
 *  to the HERO cards only (Fitness Age, Vitality), matching the pilot's heroCard: the content sits DIRECTLY
 *  in the translucent box (no inner NoopCard surface to double up on the glass), padded like a card. */
@Composable
private fun LiquidHeroCard(content: @Composable () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(HEALTH_HERO_RADIUS))
            .background(HEALTH_HERO_FILL)
            .border(1.dp, Color.White.copy(alpha = 0.11f), RoundedCornerShape(HEALTH_HERO_RADIUS))
            .padding(Metrics.cardPadding),
    ) {
        content()
    }
}

/**
 * The health hero gauge: a [LiquidVessel] filled to [fraction] (0..1) in the domain [tint], with a
 * [CountUpText] rolled up over it — white, tabular, a soft shadow, hit-transparent so a tap falls through
 * to the vessel (which owns its own splash+haptic). The Today `HeroScoreVessel` idiom, reused verbatim so
 * the Fitness Age / Vitality numbers ride a filling vessel instead of a bare hand-drawn gauge. The number
 * size tracks the diameter (≈0.27×, capped) so the vessel and numeral stay balanced. Values/fraction/tint
 * are the SAME as the number this replaced — presentation only.
 */
@Composable
private fun HealthHeroVessel(
    fraction: Double,
    value: Double,
    tint: Color,
    diameter: Dp,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
    format: (Double) -> String = { it.roundToInt().toString() },
) {
    Box(modifier = modifier.size(diameter), contentAlignment = Alignment.Center) {
        LiquidVessel(
            value = fraction.coerceIn(0.0, 1.0),
            tint = tint,
            animated = animated,
            modifier = Modifier.size(diameter),
        )
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

/** The hero tile: a big Fitness Age number on the gold Charge world, the younger/older read-out, an
 *  optional VO₂max chip, the honest ± band caption, and a "How accurate is this?" toggle. */
@Composable
private fun FitnessAgeHero(
    fitnessAge: Double,
    chronoAge: Int,
    vo2max: Double?,
    modelBandYears: Int,
    onHowAccurate: () -> Unit,
    checklistOpen: Boolean,
) {
    val parts = FitnessAgePresentation.parts(fitnessAge)
    val younger = parts.totalMonths <= chronoAge * 12
    val deltaWord = FitnessAgePresentation.localizedComparison(fitnessAge, chronoAge)
    // Vessel fill: a bounded, honest reading of the SAME younger/older signal the card already states,
    // mapped across the model-error band the section advertises - "about your age" is half-full,
    // younger fills it up, older empties it. Presentation only; the shown number is unchanged.
    val youthFraction = if (chronoAge > 0) {
        (0.5 + (chronoAge - fitnessAge) / (2.0 * modelBandYears.coerceAtLeast(1))).coerceIn(0.0, 1.0)
    } else 0.5

    // The "How accurate is this?" toggle presses inward on tap (the pilot liquidPress feel); the SAME
    // interactionSource drives its clickable + press.
    val howAccurateInteraction = remember { MutableInteractionSource() }

    // The frosted liquid hero-card wrapper floats the vessel + white count-up over the sky (the pilot).
    LiquidHeroCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space20),
            ) {
                HealthHeroVessel(
                    fraction = youthFraction,
                    value = fitnessAge,
                    tint = Palette.chargeColor,
                    diameter = 96.dp,
                    format = FitnessAgePresentation::vesselValue,
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(Metrics.space2),
                ) {
                    Overline("Fitness Age")
                    Text(
                        text = FitnessAgePresentation.value(fitnessAge),
                        style = NoopType.chartValueLarge,
                        color = Palette.textPrimary,
                    )
                    Text(
                        text = FitnessAgePresentation.localizedSpokenValue(fitnessAge),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                    Text(
                        text = deltaWord,
                        style = NoopType.subhead,
                        color = if (parts.totalMonths == chronoAge * 12) Palette.textSecondary
                        else if (younger) Palette.statusPositiveText else Palette.statusWarningText,
                    )
                }
                if (vo2max != null) {
                    StatePill(
                        title = uiString(R.string.l10n_health_screen_vo_max_vo2max_roundtoint_c32a04b3, vo2max.roundToInt()),
                        tone = StrandTone.Accent,
                        showsDot = false,
                    )
                }
            }

            Text(
                text = uiString(R.string.fitness_age_model_uncertainty, modelBandYears),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )

            // "How accurate is this?" affordance - toggles the readiness checklist below the hero.
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(Metrics.cornerSm))
                    .liquidPress(howAccurateInteraction)
                    .clickable(
                        interactionSource = howAccurateInteraction,
                        indication = null,
                        onClick = onHowAccurate,
                    )
                    .padding(vertical = Metrics.space4)
                    .semantics { contentDescription = uiString(R.string.l10n_health_screen_how_accurate_is_this_fitness_age_935c9a6d) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
            ) {
                Text(
                    uiString(R.string.l10n_health_screen_how_accurate_is_this_dae653a8),
                    style = NoopType.captionNumber,
                    color = Palette.accent,
                )
                Text(
                    if (checklistOpen) "▾" else "›",
                    style = NoopType.captionNumber,
                    color = Palette.accent,
                )
            }
        }
    }
}

@Composable
private fun FitnessAgeWeeklyProgress(history: List<Pair<String, Double>>) {
    val points = history.takeLast(8)
    val latest = points.lastOrNull() ?: return
    NoopCard(tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(
                    uiString(R.string.appwide_fitness_age_weekly_progress),
                    modifier = Modifier.weight(1f),
                )
                Text(
                    FitnessAgePresentation.value(latest.second),
                    style = NoopType.captionNumber,
                    color = Palette.textPrimary,
                )
            }
            LineChart(
                values = points.map { it.second },
                color = Palette.chargeColor,
                modifier = Modifier.height(48.dp),
                fill = false,
                selectionEnabled = true,
                formatValue = FitnessAgePresentation::value,
                selectionLabels = points.map { it.first },
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (points.size > 1) {
                        FitnessAgePresentation.localizedWeeklyProgress(
                            current = latest.second,
                            previous = points[points.lastIndex - 1].second,
                        )
                    } else {
                        uiString(R.string.appwide_fitness_age_first_weekly_estimate)
                    },
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    uiString(R.string.appwide_fitness_age_weeks_count, points.size),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

private data class FitnessContextReading(
    val label: String,
    val value: String,
    val caption: String,
)

@Composable
private fun FitnessAgeContextCard(
    days: List<DailyMetric>,
    measuredVo2max: Double?,
    estimatedVo2max: Double?,
) {
    val readings = remember(days, measuredVo2max, estimatedVo2max) {
        val recent = days.takeLast(7).asReversed()
        buildList {
            recent.mapNotNull { it.totalSleepMin }.firstOrNull()?.let { sleep ->
                val total = sleep.roundToInt()
                add(FitnessContextReading(
                    uiString(R.string.l10n_health_screen_sleep_3cac34e6),
                    "${total / 60}h ${total % 60}m",
                    uiString(R.string.appwide_fitness_age_recent_context),
                ))
            }
            recent.mapNotNull { it.recovery }.firstOrNull()?.let {
                add(FitnessContextReading(
                    uiString(R.string.l10n_health_screen_recovery_ea924f72),
                    "${it.roundToInt()}%",
                    uiString(R.string.appwide_fitness_age_recent_context),
                ))
            }
            recent.mapNotNull { it.avgHrv }.firstOrNull()?.let {
                add(FitnessContextReading(
                    "HRV",
                    "${it.roundToInt()} ms",
                    uiString(R.string.appwide_fitness_age_recent_context),
                ))
            }
            recent.mapNotNull { it.spo2Pct }.firstOrNull()?.let {
                add(FitnessContextReading(
                    "SpO₂",
                    "${it.roundToInt()}%",
                    uiString(R.string.appwide_fitness_age_recent_context),
                ))
            }
            measuredVo2max?.let {
                add(FitnessContextReading(
                    "VO₂max",
                    "${it.roundToInt()} ml/kg/min",
                    uiString(R.string.appwide_fitness_age_recent_context),
                ))
            } ?: estimatedVo2max?.let {
                add(FitnessContextReading(
                    "VO₂max",
                    "${it.roundToInt()} ml/kg/min",
                    uiString(R.string.appwide_fitness_age_companion_estimate),
                ))
            }
        }
    }
    if (readings.isEmpty()) return
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Overline(
                    uiString(R.string.appwide_fitness_age_measured_context),
                    modifier = Modifier.weight(1f),
                )
                Text(
                    uiString(R.string.appwide_fitness_age_not_inputs),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            readings.chunked(2).forEach { row ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
                ) {
                    row.forEach { reading ->
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(Metrics.space2),
                        ) {
                            Overline(reading.label)
                            Text(
                                reading.value,
                                style = NoopType.bodyNumber,
                                color = Palette.textPrimary,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                reading.caption,
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

/** Both RHR and activity need four observed days. Copy matches iOS `fitnessReadyLeadCopy`. */
internal fun fitnessReadyLead(
    rhrDays: Int,
    activityDays: Int,
    hasAge: Boolean,
    hasSex: Boolean,
): String {
    if (!hasAge || !hasSex) {
        return "Fitness Age needs a supported profile: age 20–80 and a male or female model coefficient."
    }
    val rhrProgress = rhrDays.coerceIn(0, FitnessAgeEngine.minCoverageDays)
    val activityProgress = activityDays.coerceIn(0, FitnessAgeEngine.minCoverageDays)
    if (FitnessAgeEngine.coverageDaysUntilReady(rhrDays) == 0 &&
        FitnessAgeEngine.coverageDaysUntilReady(activityDays) == 0
    ) {
        return "Resting heart rate and activity coverage are ready. Refresh to calculate your Fitness Age."
    }
    return "Calibration progress: resting heart rate $rhrProgress of 4 nights; " +
        "activity $activityProgress of 4 days."
}

/** The readiness checklist card: each input as a ✓ / ⚠ / ○ glyph + its detail, grouped by role into
 *  "Drives your Fitness Age" and "Unlocks your VO₂max". When [headed] (no value yet) it leads with the
 *  [lead] countdown and floats the required-missing items to the top of their group. */
@Composable
private fun FitnessReadinessCard(
    readiness: FitnessAgeReadiness,
    headed: Boolean,
    lead: String = "",
    // When set (the headed/not-ready state), a small refresh affordance sits by the lead and forces an
    // immediate Fitness Age recompute; [refreshing] swaps it for a spinner while that runs.
    onRefresh: (() -> Unit)? = null,
    refreshing: Boolean = false,
) {
    val drivesAge = readiness.items
        .filter { it.role == FitnessReadinessRole.DRIVES_AGE }
        .sortedBy { if (headed) readinessSortKey(it) else 0 }
    val unlocksVo2 = readiness.items
        .filter { it.role == FitnessReadinessRole.UNLOCKS_VO2MAX }
        .sortedBy { if (headed) readinessSortKey(it) else 0 }

    NoopCard(tint = if (headed) Palette.chargeColor else null) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            if (headed) {
                Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                    Row(verticalAlignment = Alignment.Top) {
                        Text(
                            lead.ifBlank { "A few more days and we can show your Fitness Age." },
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        // Force-recompute affordance: NOOP scores Fitness Age weekly, so this lets an
                        // impatient user apply it NOW from stored data (no strap needed). Spinner while it runs.
                        if (onRefresh != null) {
                            if (refreshing) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(20.dp),
                                    strokeWidth = 2.dp,
                                    color = Palette.accent,
                                )
                            } else {
                                IconButton(onClick = onRefresh, modifier = Modifier.size(28.dp)) {
                                    Icon(
                                        Icons.Filled.Refresh,
                                        contentDescription = uiString(R.string.l10n_health_screen_refresh_fitness_age_now_85fc516f),
                                        tint = Palette.accent,
                                    )
                                }
                            }
                        }
                    }
                    Text(
                        uiString(R.string.l10n_health_screen_it_compares_your_resting_heart_rate_e83e00f5) +
                            "Wear Noop Band for a full week and it appears here.",
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }

            ReadinessGroup(title = uiString(R.string.l10n_health_screen_drives_your_fitness_age_9d0d1219), items = drivesAge)
            ReadinessGroup(title = uiString(R.string.l10n_health_screen_unlocks_your_vo_max_b3c67dda), items = unlocksVo2)

            Text(
                uiString(R.string.l10n_health_screen_weight_height_and_waist_add_a_fd2699f5),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

/** Sort key for the headed (no-value-yet) state: required-missing first, then partial, then the rest. */
private fun readinessSortKey(item: FitnessReadinessItem): Int = when {
    item.required && item.status == FitnessReadinessStatus.MISSING -> 0
    item.status == FitnessReadinessStatus.MISSING -> 1
    item.status == FitnessReadinessStatus.PARTIAL -> 2
    else -> 3
}

@Composable
private fun ReadinessGroup(title: String, items: List<FitnessReadinessItem>) {
    if (items.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Overline(title)
        items.forEach { ReadinessRow(it) }
    }
}

@Composable
private fun ReadinessRow(item: FitnessReadinessItem) {
    val glyph = when (item.status) {
        FitnessReadinessStatus.SATISFIED -> "✓"
        FitnessReadinessStatus.PARTIAL -> "⚠"
        FitnessReadinessStatus.MISSING -> "○"
    }
    val glyphColor = when (item.status) {
        FitnessReadinessStatus.SATISFIED -> Palette.chargeColor
        FitnessReadinessStatus.PARTIAL -> Palette.statusWarning
        FitnessReadinessStatus.MISSING -> Palette.textTertiary
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = uiString(R.string.l10n_health_screen_item_label_item_detail_5985e927, item.label, item.detail) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
    ) {
        Text(
            glyph,
            style = NoopType.captionNumber,
            color = glyphColor,
            modifier = Modifier.width(16.dp),
        )
        Text(
            item.label,
            style = NoopType.subhead,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Text(
            item.detail,
            style = NoopType.footnote,
            color = Palette.textTertiary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

private fun yearWord(years: Int): String = if (kotlin.math.abs(years) == 1) "year" else "years"

@Composable
fun VitalSignsScreen(vm: AppViewModel, onVitalClick: (String) -> Unit = {}) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    var selectedDayOffset by remember { mutableIntStateOf(0) }
    val selectedDay = remember(selectedDayOffset) { LocalDate.now().minusDays(selectedDayOffset.toLong()) }
    val selectedDayKey = remember(selectedDay) { selectedDay.toString() }
    val selectedMetric = remember(days, selectedDayKey) { days.lastOrNull { it.day == selectedDayKey } }
    val tempUnit = UnitPrefs.temperature(LocalContext.current)
    val vitals = remember(selectedMetric, days, tempUnit) {
        selectedMetric?.let { vitalsFor(it, days, tempUnit) }.orEmpty()
    }

    ScreenScaffold(
        title = uiString(R.string.l10n_health_screen_vital_signs_e7d9e1b1),
        subtitle = "Historical vitals from your cached daily metrics.",
    ) {
        RecentDaySelectorBar(selectedOffset = selectedDayOffset, onSelect = { selectedDayOffset = it })
        if (selectedMetric == null || vitals.all { it.value == null }) {
            DataPendingNote(
                title = missingVitalsTitle(selectedDayOffset),
                body = "Try Yesterday or 2 days ago from the bar above if the strap or import did not produce a daily vitals snapshot yet.",
            )
        } else {
            VitalsSection(
                title = uiString(R.string.l10n_health_screen_vital_signs_e7d9e1b1),
                overline = selectedDayLabel(selectedDayOffset),
                trailing = "as of ${selectedMetric.day}",
                vitals = vitals,
                onVitalClick = onVitalClick,
                footer = false,
                captionMode = VitalCaptionMode.RANGE,
            )
        }
    }
}

// MARK: - Heart rate hero (live)

@Composable
private fun HeartRateSection(vm: AppViewModel, hrMax: Int) {
    // PERF (#scroll-jank): collect the BLE live state + smoothed bpm HERE, in the HR hero leaf, instead
    // of receiving them from the screen body. Both tick ~1Hz; reading them at body scope recomposed the
    // whole Health screen on every heartbeat. Scoping the collection to this section confines the ~1Hz
    // re-render to the HR hero alone — the rest of the screen no longer recomposes per beat. Mirrors the
    // shipped Today fix (HeartRateTrendCard scopes its own collection). Appearance + behaviour identical.
    val live by vm.live.collectAsStateWithLifecycle()
    val bpm by vm.bpm.collectAsStateWithLifecycle()
    var liveTrackingOptedIn by remember { mutableStateOf(false) }
    var liveTrackingStartSequence by remember { mutableStateOf<Long?>(null) }
    val hasFreshPacket = hasFreshHeartRatePacket(
        optedIn = liveTrackingOptedIn,
        startSequence = liveTrackingStartSequence,
        currentSequence = live.heartRateSampleSequence,
    )
    val displayHr = sessionLiveDisplayHr(
        optedIn = liveTrackingOptedIn,
        startSequence = liveTrackingStartSequence,
        bpm = bpm,
        live = live,
    )
    val hasLiveHr = displayHr != null
    val derived = hrIsDerived(live)
    val fraction = hrFraction(displayHr, hrMax)
    val zone = hrZone(fraction)
    // Accumulate the streamed HR over time so the hero chart actually moves (issue #18 — it used to
    // derive from sparse R-R and flat-line). Each sample now carries its arrival time so the hero can
    // render a real time x-axis (#198). Lives in UI state; resets when you leave the screen.
    // #941 (ryanbr): sample at a FIXED 1 Hz wall clock, not on value change. The smoothed bpm is a
    // StateFlow, which conflates duplicate emissions, so a steady stretch banked ZERO points; with a
    // real-time x-axis the next change was then joined to the last point across the whole quiet
    // interval, drawing a phantom ramp where HR was actually flat. A clock tick banks the latest
    // (already spike-filtered) value every second, so steady HR draws flat and the 180-sample cap
    // finally means a strict rolling ~3 minutes. rememberUpdatedState lets the loop read the CURRENT
    // value without restarting the effect.
    //
    // Lifecycle gate (data-honesty): the BLE foreground service keeps the process (and this composition)
    // alive while backgrounded, but the inputs bpm/live are collected with collectAsStateWithLifecycle,
    // which STOPS at ON_STOP - so an ungated loop would bank the frozen last value once a second with
    // real timestamps, fabricating a flat trace for the whole background stretch (and persisting it if
    // the strap dropped meanwhile). Running the tick inside repeatOnLifecycle(STARTED) suspends banking
    // exactly when the inputs freeze and resumes it when fresh state flows again, matching iOS (its timer
    // suspends when backgrounded). See LiveHrSamplingTest for the contract.
    val hrHistory = remember { mutableStateListOf<LiveHrSample>() }
    val latestDisplayHr by rememberUpdatedState(displayHr)
    val lifecycleOwner = LocalLifecycleOwner.current

    // This card owns one foreground realtime lease after an explicit Start. Stopping or leaving
    // Health disposes the true-keyed effect and releases only this card's lease.
    DisposableEffect(liveTrackingOptedIn) {
        if (liveTrackingOptedIn) vm.requestRealtimeHr()
        onDispose {
            if (liveTrackingOptedIn) vm.releaseRealtimeHr()
        }
    }

    // A transport gap invalidates the old packet. Reconnect keeps the logical lease but waits for a
    // genuinely newer sensor sequence before the card can return to Streaming.
    LaunchedEffect(live.connected) {
        if (liveTrackingOptedIn) {
            liveTrackingStartSequence = live.heartRateSampleSequence
            hrHistory.clear()
        }
    }

    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                appendLiveHrSample(hrHistory, latestDisplayHr, System.currentTimeMillis())
                delay(1000)
            }
        }
    }
    val series = if (hasFreshPacket) hrSeries(hrHistory, live, displayHr) else emptyList()
    val zoneColor = Palette.hrZoneColor(zone)

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(
            title = uiString(R.string.l10n_health_screen_heart_rate_dde6e8f7),
            overline = if (liveTrackingOptedIn) "Live" else "Paused",
            trailing = if (hasFreshPacket && derived) "from R-R" else null,
        )

        NoopCard(tint = Palette.metricRose) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Icon(
                        Icons.Filled.MonitorHeart,
                        contentDescription = null,
                        tint = if (liveTrackingOptedIn) Palette.metricRose else Palette.textSecondary,
                        modifier = Modifier.size(24.dp),
                    )
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                    ) {
                        Text(
                            stringResource(
                                if (liveTrackingOptedIn) {
                                    R.string.health_live_hr_on
                                } else {
                                    R.string.health_live_hr_off
                                },
                            ),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(
                                if (liveTrackingOptedIn) {
                                    R.string.health_live_hr_on_detail
                                } else {
                                    R.string.health_live_hr_off_detail
                                },
                            ),
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                        Text(
                            stringResource(R.string.health_live_hr_battery_notice),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
                NoopButton(
                    text = stringResource(
                        if (liveTrackingOptedIn) {
                            R.string.health_stop_live_hr
                        } else {
                            R.string.health_start_live_hr
                        },
                    ),
                    leadingIcon = if (liveTrackingOptedIn) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                    kind = if (liveTrackingOptedIn) NoopButtonKind.Secondary else NoopButtonKind.Primary,
                    fullWidth = true,
                    enabled = liveTrackingOptedIn || (live.connected && !live.backfilling),
                    onClick = {
                        if (liveTrackingOptedIn) {
                            liveTrackingOptedIn = false
                            liveTrackingStartSequence = null
                            hrHistory.clear()
                        } else if (live.connected && !live.backfilling) {
                            liveTrackingStartSequence = live.heartRateSampleSequence
                            hrHistory.clear()
                            liveTrackingOptedIn = true
                        }
                    },
                )
            }
        }

        // The live HR hero is Apple-flat — a plain card tinted rose (heart-rate's metric accent) over a
        // SUBTLE time-of-day backdrop, NOT a scenic starfield/bloom. Mirrors HealthView.swift's reset:
        // "No scenic starfield / bloom: fill contrast carries the edge (Apple-flat)."
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Metrics.cardRadius))
                .timeOfDayBackground(),
        ) {
            NoopCard(padding = Metrics.space18, tint = Palette.metricRose) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                // Card header: title + subtitle on the left, live bpm read-out right.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(uiString(R.string.l10n_health_screen_heart_rate_dde6e8f7), style = NoopType.headline, color = Palette.textPrimary)
                        Text(
                            text = when {
                                hasFreshPacket && derived -> "Estimated from R-R interval"
                                hasLiveHr -> "Streaming live"
                                liveTrackingOptedIn -> stringResource(R.string.health_awaiting_wearable)
                                else -> stringResource(R.string.health_live_display_paused)
                            },
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                    }
                    Text(
                        text = if (hasLiveHr) "$displayHr bpm" else "-",
                        style = NoopType.metricInline,
                        color = if (hasLiveHr) zoneColor else Palette.textTertiary,
                    )
                }

                // Hero chart: a tall HR line tinted to the current zone, with a status
                // pill floated top-trailing. Falls back to a big number when R-R is sparse.
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight)
                        .semantics {
                            contentDescription = if (hasLiveHr) {
                                "Live heart rate over time, $displayHr beats per minute, zone $zone"
                            } else {
                                "Live heart rate over time, no data"
                            }
                        },
                ) {
                    if (series.size > 1) {
                        LiveHrTimeChart(
                            samples = series,
                            color = zoneColor,
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                        )
                    } else {
                        Column(
                            modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center,
                        ) {
                            // The big fallback numeral ticks up to the live value (mirrors HealthView.swift's
                            // CountUpText); a crisp em-dash when there's no HR yet.
                            if (displayHr != null) {
                                CountUpText(
                                    value = displayHr.toDouble(),
                                    format = { it.roundToInt().toString() },
                                    style = NoopType.display(72f),
                                    color = zoneColor,
                                )
                            } else {
                                Text(
                                    text = "-",
                                    style = NoopType.display(72f),
                                    color = Palette.textTertiary,
                                )
                            }
                            Text("bpm", style = NoopType.subhead, color = Palette.textTertiary)
                        }
                    }

                    StatePill(
                        title = zoneLabel(liveTrackingOptedIn, hasLiveHr, zone, fraction),
                        tone = if (hasLiveHr) StrandTone.Accent else StrandTone.Neutral,
                        showsDot = hasLiveHr,
                        pulsing = hasLiveHr,
                        modifier = Modifier.align(Alignment.TopEnd),
                    )
                }

                // Footer read-out row: Zone · % Max · Max HR · State.
                HeartRateFooter(
                    zone = if (hasLiveHr) "Z$zone" else "-",
                    percentMax = if (hasLiveHr) "${(fraction * 100).roundToInt()}%" else "-",
                    maxHr = "$hrMax",
                    state = when {
                        hasLiveHr -> "STREAMING"
                        liveTrackingOptedIn -> "WAITING"
                        else -> "PAUSED"
                    },
                )
            }
            }
        }
    }
}

private fun zoneLabel(
    liveTrackingOptedIn: Boolean,
    hasLiveHr: Boolean,
    zone: Int,
    fraction: Double,
): String {
    if (!liveTrackingOptedIn) return "Paused"
    if (!hasLiveHr) return "Idle"
    return "Zone $zone · ${(fraction * 100).roundToInt()}%"
}

@Composable
private fun HeartRateFooter(zone: String, percentMax: String, maxHr: String, state: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(top = Metrics.space4)) {
        FooterStat("Zone", zone, Modifier.weight(1f))
        FooterStat("% Max", percentMax, Modifier.weight(1f))
        FooterStat("Max HR", maxHr, Modifier.weight(1f))
        FooterStat("State", state, Modifier.weight(1f))
    }
}

@Composable
private fun FooterStat(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Metrics.space2)) {
        Overline(label)
        Text(value, style = NoopType.captionNumber, color = Palette.textPrimary)
    }
}

// MARK: - Live HR time chart
//
// The live HR hero plotted over a real TIME x-axis (HH:mm:ss), so the trace visibly scrolls as new
// samples arrive (#198). Replaces the axis-less LineChart on this hero — a phone user has no hover,
// so the visible clock axis is the fix. A local Canvas chart (not the shared LineChart, which has no
// axis): x is time-proportional, y auto-fits with headroom, the zone colour drives line + soft fill.

private val liveHrAxisFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("HH:mm:ss", Locale.US).withZone(ZoneId.systemDefault())

@Composable
private fun LiveHrTimeChart(
    samples: List<LiveHrSample>,
    color: Color,
    modifier: Modifier,
) {
    Box(modifier = modifier.fillMaxWidth().clipToBounds()) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            if (samples.size < 2 || size.width <= 0f || size.height <= 0f) {
                drawHrBaseline()
                return@Canvas
            }

            val strokePx = 2.5f
            val topPad = strokePx + 4f
            // Reserve a strip at the bottom for the time labels.
            val axisHeight = 26f
            val plotBottom = (size.height - axisHeight).coerceAtLeast(1f)
            val usableH = (plotBottom - topPad).coerceAtLeast(1f)

            val tMin = samples.first().timeMs
            val tMax = samples.last().timeMs
            val tSpan = (tMax - tMin).coerceAtLeast(1L)

            val values = samples.map { it.bpm }
            val vMin = values.min()
            val vMax = values.max()
            val vSpan = (vMax - vMin)
            // A little y-headroom so the trace never kisses the plot edges.
            val pad = if (vSpan > 0.0) vSpan * 0.12 else 5.0
            val lo = vMin - pad
            val hi = vMax + pad
            val span = (hi - lo).coerceAtLeast(0.0001)

            fun xFor(t: Long): Float = ((t - tMin).toFloat() / tSpan.toFloat()) * size.width
            fun yFor(v: Double): Float {
                val norm = ((v - lo) / span).toFloat()
                return topPad + (1f - norm) * usableH
            }

            val pts = samples.map { Offset(xFor(it.timeMs), yFor(it.bpm)) }

            // Soft gradient fill under the curve (down to the plot baseline, above the axis strip).
            val fillPath = Path().apply {
                moveTo(pts.first().x, plotBottom)
                lineTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                lineTo(pts.last().x, plotBottom)
                close()
            }
            drawPath(
                path = fillPath,
                brush = Brush.verticalGradient(
                    colors = listOf(
                        color.copy(alpha = StrandAlpha.chartFillStrong),
                        color.copy(alpha = StrandAlpha.chartFillSoft),
                        Color.Transparent,
                    ),
                    startY = 0f,
                    endY = plotBottom,
                ),
            )

            // The line itself.
            val linePath = Path().apply {
                moveTo(pts.first().x, pts.first().y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            }
            drawPath(
                path = linePath,
                color = color,
                style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )

            // Time x-axis: a faint baseline + evenly-spaced clock labels across the time span.
            drawLine(
                color = Palette.hairline.copy(alpha = 0.4f),
                start = Offset(0f, plotBottom),
                end = Offset(size.width, plotBottom),
                strokeWidth = 1f,
                cap = StrokeCap.Round,
            )
            val tickCount = 4
            drawContext.canvas.nativeCanvas.apply {
                val paint = android.graphics.Paint().apply {
                    isAntiAlias = true
                    textSize = 24f
                    this.color = Palette.textTertiary.toArgb()
                }
                val baselineY = size.height - 6f
                for (i in 0 until tickCount) {
                    val frac = i.toFloat() / (tickCount - 1)
                    val t = tMin + (tSpan * frac).toLong()
                    val label = liveHrAxisFormatter.format(Instant.ofEpochMilli(t))
                    val labelWidth = paint.measureText(label)
                    // Keep the first/last labels inside the plot bounds.
                    val rawX = frac * size.width
                    val x = rawX.coerceIn(0f, (size.width - labelWidth).coerceAtLeast(0f))
                    drawText(label, x, baselineY, paint)
                }
            }
        }
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawHrBaseline() {
    val y = size.height / 2f
    drawLine(
        color = Palette.hairline.copy(alpha = StrandAlpha.subtleLine),
        start = Offset(0f, y),
        end = Offset(size.width, y),
        strokeWidth = 1f,
        cap = StrokeCap.Round,
    )
}

// MARK: - Vitals grid (uniform StatTiles)

private val HEALTH_MONITOR_KEYS = setOf("resp", "spo2", "rhr", "hrv", "skin")

@Composable
private fun VitalsSection(
    title: String,
    overline: String,
    trailing: String? = null,
    vitals: List<Vital>,
    onVitalClick: (String) -> Unit,
    footer: Boolean = true,
    captionMode: VitalCaptionMode = VitalCaptionMode.AS_OF,
) {
    // Temperature display preference (D#103). Skin temp is stored in °C; the toggle re-labels it to °F.
    // Display-only — banding still runs on the stored °C value.
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(title = title, overline = overline, trailing = trailing)
        val rangeSummary = summarizeVitalRanges(vitals)
        val rangeSummaryMessage = when {
            rangeSummary.availableCount == 0 ->
                stringResource(R.string.vital_range_summary_none)
            rangeSummary.availableCount == 1 && rangeSummary.inRangeCount == 1 ->
                stringResource(R.string.vital_range_summary_one_within)
            rangeSummary.availableCount == 1 ->
                stringResource(R.string.vital_range_summary_one_outside)
            else -> stringResource(
                R.string.vital_range_summary_many,
                rangeSummary.inRangeCount,
                rangeSummary.availableCount,
            )
        }
        HealthMonitorSummary(
            vitals = vitals,
            rangeSummary = rangeSummary,
            summary = rangeSummaryMessage,
        )

        // A uniform 2-column grid of fixed-height tiles. The macOS LazyVGrid is
        // adaptive(min: 168); on phones two columns is the faithful equivalent.
        vitals.chunked(2).forEach { rowVitals ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
            ) {
                rowVitals.forEach { v ->
                    // liquidPress on the tappable vital tile — the SAME interactionSource drives its
                    // clickable + the press so the whole tile settles inward on tap (the pilot feel).
                    // Keyed on the vital key so each tile keeps a stable source across recomposition.
                    // The detail route (onVitalClick) is unchanged.
                    val tileInteraction = remember(v.key) { MutableInteractionSource() }
                    VitalTile(
                        modifier = Modifier
                            .weight(1f)
                            .liquidPress(tileInteraction)
                            .clickable(
                                interactionSource = tileInteraction,
                                indication = null,
                            ) { onVitalClick(v.key) }
                            .semantics { contentDescription = v.accessibilityText },
                        vital = v,
                        value = v.formattedValue ?: "-",
                        caption = when (captionMode) {
                            VitalCaptionMode.AS_OF -> v.asOfLabel ?: v.stateCaption
                            VitalCaptionMode.RANGE -> v.rangeCaption ?: v.stateCaption
                        },
                        accent = v.accent,
                    )
                }
                // Pad an odd final row so the tile keeps half-width, matching the grid.
                if (rowVitals.size == 1) Spacer(Modifier.weight(1f))
            }
        }

        if (footer) {
            Text(
                text = uiString(R.string.l10n_health_screen_spo_respiratory_rate_and_skin_temperature_0ae0ad8f) +
                    "aggregates from your most recent imported day; resting HR and HRV update daily. " +
                    "Once NOOP has 14 nights of history, in-range compares each vital to your own " +
                    "baseline (approximate, not medical advice); until then typical adult ranges apply.",
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun HealthMonitorSummary(
    vitals: List<Vital>,
    rangeSummary: VitalRangeSummary,
    summary: String,
) {
    NoopCard(
        modifier = Modifier
            .fillMaxWidth()
            .clearAndSetSemantics { contentDescription = summary },
        padding = Metrics.space14,
        tint = Palette.statusPositive,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(modifier = Modifier.fillMaxWidth()) {
                vitals.forEachIndexed { index, vital ->
                    if (index > 0) {
                        Box(
                            Modifier
                                .width(1.dp)
                                .height(66.dp)
                                .background(Palette.hairline),
                        )
                    }
                    HealthMonitorSignal(vital = vital, modifier = Modifier.weight(1f))
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Palette.hairline))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                Icon(
                    imageVector = if (rangeSummary.allAvailableInRange) {
                        Icons.Filled.CheckCircle
                    } else {
                        Icons.Filled.Info
                    },
                    contentDescription = null,
                    tint = if (rangeSummary.allAvailableInRange) {
                        Palette.statusPositive
                    } else {
                        Palette.textTertiary
                    },
                    modifier = Modifier.size(18.dp),
                )
                Text(summary, style = NoopType.subhead, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun HealthMonitorSignal(vital: Vital, modifier: Modifier = Modifier) {
    val available = vital.value?.isFinite() == true &&
        vital.banding.band != VitalBands.Band.NO_DATA
    val inRange = available && vital.banding.band == VitalBands.Band.IN_RANGE
    val statusColor = when {
        inRange -> Palette.statusPositive
        available -> Palette.statusWarning
        else -> Palette.textTertiary
    }
    val icon = when (vital.key) {
        "resp" -> Icons.Filled.Air
        "spo2" -> Icons.Filled.WaterDrop
        "rhr" -> Icons.Filled.Favorite
        "hrv" -> Icons.Filled.MonitorHeart
        else -> Icons.Filled.Thermostat
    }
    val label = when (vital.key) {
        "resp" -> "RESP"
        "spo2" -> "SPO₂"
        "rhr" -> "RHR"
        "hrv" -> "HRV"
        else -> "TEMP"
    }
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        Icon(icon, contentDescription = null, tint = vital.metricColor, modifier = Modifier.size(19.dp))
        Text(
            label,
            style = NoopType.overline,
            color = Palette.textSecondary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Icon(
            imageVector = if (inRange) Icons.Filled.CheckCircle else Icons.Filled.Info,
            contentDescription = null,
            tint = statusColor,
            modifier = Modifier.size(17.dp),
        )
    }
}

// MARK: - Vital model

@Composable
private fun VitalTile(
    vital: Vital,
    modifier: Modifier = Modifier,
    value: String = vital.formattedValue ?: "-",
    caption: String = vital.stateCaption,
    accent: Color = vital.accent,
) {
    // The tile borrows its accent as a faint card wash, so each vital reads as part of its colour
    // world while staying legible on the deep blue-black — matching Today's StatTile.
    NoopCard(modifier = modifier.height(Metrics.tileHeight), padding = Metrics.space14, tint = accent) {
        Column {
            Overline(vital.label)
            Spacer(Modifier.weight(1f))
            Text(
                text = value,
                style = NoopType.tileValueLarge,
                color = accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // A metric-tinted sparkline trail with a glowing "now" end-cap, mirroring Today's tiles.
            // Hidden below two points so a sparse vital shows the caption with no flat trail.
            if (vital.sparkline.size > 1) {
                TileSparkline(
                    values = vital.sparkline,
                    color = vital.metricColor,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(20.dp)
                        .padding(top = Metrics.space4),
                )
            }
            Text(
                text = caption,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = Metrics.space2),
            )
        }
    }
}

/**
 * A compact metric-tinted sparkline for a tile trail: a soft gradient fill under a coloured line,
 * capped with a glowing end-cap (a halo + white core) at the latest point so it reads as "now".
 * Built locally with Canvas + Palette colours (there is no shared tile-spark composable), mirroring
 * the Bevel chart end-cap used on the macOS sparkline and the Today HR chart. Decorative — the tile
 * already carries a combined contentDescription, so the spark is not separately announced.
 */
@Composable
private fun TileSparkline(values: List<Double>, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.clipToBounds()) {
        if (values.size < 2 || size.width <= 0f || size.height <= 0f) return@Canvas
        val strokePx = 2f
        val pad = strokePx + 2f
        val usableH = (size.height - pad * 2).coerceAtLeast(1f)
        val lo = values.min()
        val hi = values.max()
        val span = (hi - lo).takeIf { it > 0.0 } ?: 1.0
        val n = values.size
        fun xFor(i: Int): Float = if (n > 1) size.width * i / (n - 1) else 0f
        fun yFor(v: Double): Float {
            val norm = ((v - lo) / span).toFloat().coerceIn(0f, 1f)
            return pad + (1f - norm) * usableH
        }
        val pts = values.mapIndexed { i, v -> Offset(xFor(i), yFor(v)) }

        // Soft gradient fill under the curve.
        val fillPath = Path().apply {
            moveTo(pts.first().x, size.height)
            lineTo(pts.first().x, pts.first().y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            lineTo(pts.last().x, size.height)
            close()
        }
        drawPath(
            path = fillPath,
            brush = Brush.verticalGradient(
                colors = listOf(
                    color.copy(alpha = StrandAlpha.chartFillSoft),
                    Color.Transparent,
                ),
                startY = 0f,
                endY = size.height,
            ),
        )

        // The line, tinted lighter → full at the leading edge so it reads as building toward "now".
        val linePath = Path().apply {
            moveTo(pts.first().x, pts.first().y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
        }
        drawPath(
            path = linePath,
            brush = Brush.horizontalGradient(
                colors = listOf(color.copy(alpha = 0.5f), color),
                startX = 0f,
                endX = size.width,
            ),
            style = Stroke(width = strokePx, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )

        // Glowing "now" end-cap at the latest point: a soft halo + white core.
        val end = pts.last()
        drawCircle(color = color.copy(alpha = 0.30f), radius = 6f, center = end)
        drawCircle(color = color.copy(alpha = 0.65f), radius = 3.5f, center = end)
        drawCircle(color = Palette.tipCore, radius = 1.6f, center = end)
    }
}

private data class VitalDetailModel(
    val key: String,
    val title: String,
    val unit: String,
    val color: Color,
    val readings: List<VitalReading>,
    val format: (Double) -> String,
) {
    /** (day, value) projection the trend chart + range helpers consume — SAME order as [readings], so the
     *  chart, the header count, and the table can never drift apart. */
    val points: List<Pair<String, Double>> get() = readings.map { it.day to it.value }
}

/** Metric-detail keys that are NOT plain DailyMetric columns but series the engines/importers persist
 *  (Fitness Age + Vitality under the computed strap, Steps estimate, Apple active energy). Each Today
 *  dashboard card taps through to ITS OWN focused trend here (2026-07-03), so these load their
 *  series from the repo on demand rather than off the cached `days` columns. Mirrors iOS metricDetail. */
private val SERIES_BACKED_VITAL_KEYS = setOf(
    "fitness_age", "vitality", "steps_est", "active_kcal", "rest",
    "weight", "hrv", "rhr", "body_fat", "lean_mass", "vo2max",
)

@Composable
fun VitalDetailScreen(vm: AppViewModel, key: String) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val activeDeviceId by vm.selectedDeviceId.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val tempUnit = UnitPrefs.temperature(context)
    val massUnit = UnitPrefs.mass(context)
    // The Effort detail renders per the user's Effort display scale (0-100 vs 0-21), like the Today tile.
    val effortScale = UnitPrefs.effortScale(context)
    // Profile drives the Fitness Age readiness/countdown shown when that vital has no value yet.
    val profile = remember { ProfileStore.from(context.applicationContext) }
    val profileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val ageMetricDataVersion by vm.ageMetricDataVersion.collectAsStateWithLifecycle()
    val ageMetricState = remember(profileVersion) { profile.ageMetricStateToken }
    val isSeriesBacked = key in SERIES_BACKED_VITAL_KEYS

    // Series-backed metrics are loaded async from metricSeries; the plain daily vitals build synchronously
    // off the cached `days`. `seriesLoaded` guards the empty-state so a still-loading trend doesn't flash
    // "not enough history" before its rows arrive.
    var seriesDetail by remember(key, activeDeviceId) { mutableStateOf<VitalDetailModel?>(null) }
    var seriesLoaded by remember(key, activeDeviceId) { mutableStateOf(false) }
    // Manual-refresh plumbing for the Fitness Age not-ready state (readiness branch below): the refresh
    // button recomputes then bumps this tick, re-running the series read so a fresh value shows at once.
    var refreshTick by remember { mutableStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    var loadedAgeMetricState by remember(key, activeDeviceId) { mutableStateOf<String?>(null) }
    if (isSeriesBacked) {
        LaunchedEffect(key, refreshTick, profileVersion, ageMetricDataVersion, activeDeviceId) {
            val profileAllowsMetric = when (key) {
                "fitness_age" -> profile.fitnessInputsConfirmed &&
                    FitnessAgeEngine.supportsAge(profile.age.toDouble()) &&
                    FitnessAgeEngine.supportsSex(profile.sex)
                "vitality" -> profile.ageInputConfirmed && profile.age in 20..80
                else -> true
            }
            val provenanceAllowsMetric = if (!profileAllowsMetric) false else when (key) {
                "fitness_age" -> profile.acceptsFitnessAge(
                    vm.repo.latestMetricComputedUnion(
                        activeDeviceId, AgeMetricProfile.FITNESS_AGE_KEY,
                    )?.value,
                )
                "vitality" -> profile.acceptsVitality(
                    vm.repo.latestMetricComputedUnion(
                        activeDeviceId, AgeMetricProfile.VITALITY_KEY,
                    )?.value,
                )
                else -> true
            }
            seriesDetail = if (provenanceAllowsMetric) {
                buildSeriesVitalDetail(vm, key, massUnit, activeDeviceId)
            } else {
                null
            }
            loadedAgeMetricState = ageMetricState
            seriesLoaded = true
        }
    }
    val ageMetricCurrent = key !in setOf("fitness_age", "vitality") || loadedAgeMetricState == ageMetricState
    val detail = if (isSeriesBacked) seriesDetail.takeIf { ageMetricCurrent }
    else remember(days, key, tempUnit, effortScale) { buildVitalDetail(days, key, tempUnit, effortScale) }
    var range by remember { mutableStateOf(VitalDetailRange.MONTH) }

    // The subtitle tracks how much history the metric has, so we never promise a "historical trend" the
    // view isn't showing: Fitness Age with no reading yet -> what it still needs; ANY metric with a single
    // reading -> that reading (trend to follow); two+ -> the trend. Pre-load falls through to trend.
    val loadedPoints = if (seriesLoaded) (detail?.points?.size ?: 0) else -1
    // #430 parity: the detail carries the SAME backdrop as the screen that pushed it — the day-cycle sky
    // when the setting is on (full-viewport when "Sky behind cards" is also on, so the transparent cards
    // reveal it the whole way down; the top band otherwise), the plain canvas when off. Same gates the
    // Today screen uses.
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }
    val skyBehindCards = remember { NoopPrefs.skyBehindCards(context) }
    ScreenScaffold(
        title = detail?.title ?: "Vital Signs",
        subtitle = when {
            key == "fitness_age" && loadedPoints == 0 -> "What your Fitness Age still needs."
            loadedPoints == 1 -> "Your latest reading - trend to follow."
            else -> "Historical trend from cached daily metrics."
        },
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky(fillHeight = skyBehindCards) } } else null,
        // Sky-behind-cards needs the full-viewport container too — the band container's status-bar
        // offset left the lower cards on plain canvas (tester report).
        fullBleedBackground = showDayCycleBackground && skyBehindCards,
    ) {
        if (isSeriesBacked && !seriesLoaded) {
            DataPendingNote(
                title = uiString(R.string.l10n_health_screen_loading_33ce4174),
                body = "Fetching this metric's history.",
            )
            return@ScreenScaffold
        }
        if (detail == null || detail.points.size < 2) {
            // Fitness Age with NO value yet (zero points): show the readiness checklist + the "N more
            // nights of wear" countdown - what it actually needs - instead of the generic "needs two
            // readings to chart" note, which describes the trend line and left the Today card's tap-through
            // a dead end. (A single reading is handled below, generically, for every metric.)
            if (key == "fitness_age" && (detail?.points?.isEmpty() != false)) {
                val (rhrDays, activityDays, readiness) = rememberFitnessReadiness(days, profile)
                FitnessReadinessCard(
                    readiness = readiness, headed = true,
                    lead = fitnessReadyLead(
                        rhrDays,
                        activityDays,
                        profile.ageInputConfirmed && FitnessAgeEngine.supportsAge(profile.age.toDouble()),
                        profile.sexInputConfirmed && FitnessAgeEngine.supportsSex(profile.sex),
                    ),
                    refreshing = refreshing,
                    onRefresh = {
                        refreshing = true
                        vm.refreshFitnessAgeNow { wrote ->
                            refreshing = false
                            refreshTick++
                            Toast.makeText(
                                context,
                                if (wrote) "Fitness Age updated."
                                else "Not enough wear yet - keep Noop Band on overnight.",
                                Toast.LENGTH_SHORT,
                            ).show()
                        }
                    },
                )
                return@ScreenScaffold
            }
            // ANY metric with exactly ONE reading: the Today card already shows this value, so the generic
            // "Not enough history yet" note read as a contradiction on tap-through - only the TREND CHART
            // needs a second point. Show the value + when the chart fills in, never a no-data dead end.
            // Matches iOS, which renders the value hero at a single point. First hit on Fitness Age, then
            // Vitality — both weekly-ish computed scores that sit at one reading for a while.
            if (detail != null && detail.points.size == 1) {
                val one = detail.points.last()   // size 1: the single reading (last == the latest)
                NoopCard {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Overline("Latest")
                        Text(
                            text = uiString(R.string.l10n_health_screen_detail_format_one_second_detail_unit_6fde90d3, detail.format(one.second), detail.unit).trim(),
                            style = NoopType.chartValueLarge,
                            color = detail.color,
                        )
                        Text(
                            text = uiString(R.string.l10n_health_screen_as_of_one_first_2b409612, one.first),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                        Text(
                            text = uiString(R.string.l10n_health_screen_one_reading_so_far_your_trend_eaad57f2) +
                                "reading lands.",
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    }
                }
                return@ScreenScaffold
            }
            DataPendingNote(
                title = uiString(R.string.l10n_health_screen_not_enough_history_yet_0e2f93b6),
                body = "This vital needs at least two historical readings before NOOP can chart it.",
            )
            return@ScreenScaffold
        }

        // #943 (ryanbr): gate the range chips by available history so short history can't draw six
        // byte-identical charts. A locked selection (e.g. the MONTH default during the first week)
        // coerces DOWN to the largest unlocked range so a calibrating user always has a live chart.
        val unlockedRanges = remember(detail) { unlockedVitalRanges(vitalHistorySpanDays(detail.points)) }
        val effectiveRange = coercedVitalRange(range, unlockedRanges)
        // The trend chart, the "N readings" header, AND the readings table all derive from this ONE
        // windowed list, so the count and the rows can never disagree (task #8). filteredPoints is just
        // its (day, value) projection for the existing chart/stat code.
        val filteredReadings = remember(detail, effectiveRange) { filterVitalReadings(detail.readings, effectiveRange) }
        val filteredPoints = filteredReadings.map { it.day to it.value }
        if (filteredPoints.size < 2) {
            DataPendingNote(
                title = uiString(R.string.l10n_health_screen_not_enough_history_in_this_range_2da72f80),
                body = "Try a longer interval like 3M, 6M, 1Y, or ALL to see this vital’s trend.",
            )
            return@ScreenScaffold
        }

        val values = filteredPoints.map { it.second }
        val latest = filteredPoints.last()
        val min = values.minOrNull()
        val max = values.maxOrNull()
        val avg = values.average()

        SectionHeader(detail.title, overline = "Vital Signs", trailing = "${filteredReadings.size} readings")
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(modifier = Modifier.weight(1f)) {
                        Overline("Latest")
                        Text(
                            text = uiString(R.string.l10n_health_screen_detail_format_latest_second_detail_unit_9664278b, detail.format(latest.second), detail.unit).trim(),
                            style = NoopType.chartValueLarge,
                            color = detail.color,
                        )
                        Text(
                            text = uiString(R.string.l10n_health_screen_as_of_latest_first_726f20bb, latest.first),
                            style = NoopType.footnote,
                            color = Palette.textTertiary,
                        )
                    }
                }
                SegmentedPillControl(
                    items = VitalDetailRange.entries,
                    selection = effectiveRange,
                    label = { it.label },
                    onSelect = { range = it },
                    adaptsToAvailableWidth = true,
                    enabled = { it in unlockedRanges },
                )
                if (unlockedRanges.size < VitalDetailRange.entries.size) {
                    Text(
                        uiString(R.string.l10n_health_screen_longer_ranges_unlock_as_more_history_d7da5fee),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                LineChart(
                    values = values,
                    modifier = Modifier.height(Metrics.chartHeight),
                    color = detail.color,
                    fill = true,
                    selectionEnabled = true, // the Vital Signs detail chart is meant to be tappable
                    formatValue = detail.format,
                )
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.divider)
                        .background(Palette.hairline),
                )
                Row(modifier = Modifier.fillMaxWidth()) {
                    listOf(
                        "Min" to min,
                        "Avg" to avg,
                        "Max" to max,
                    ).forEach { (label, metric) ->
                        Column(modifier = Modifier.weight(1f)) {
                            Overline(label, color = Palette.textTertiary)
                            Text(
                                text = metric?.let { "${detail.format(it)} ${detail.unit}".trim() } ?: "-",
                                style = NoopType.bodyNumber,
                                color = Palette.textPrimary,
                            )
                        }
                    }
                }
            }
        }

        // Per-reading breakdown so the provenance behind the trend is visible — whether each reading came
        // from the WHOOP strap, a Health Connect / Apple Health import, or the on-device pipeline — not
        // just the "N readings" count. Rows derive from the SAME [filteredReadings] the header counts,
        // newest first, and reuse [provenanceDisplayLabel] for the source words (task #8).
        val readingRows = remember(filteredReadings, detail, activeDeviceId) {
            vitalReadingRows(filteredReadings, detail.unit, activeDeviceId, detail.format)
        }
        VitalReadingsTable(rows = readingRows)
    }
}

/** The readings table below a vital's chart: one row per windowed reading (newest first), each showing
 *  its day, formatted value, and source (tinted by [provenanceLabelTint], so the same source reads the
 *  same colour as the Today rings). Empty [rows] render nothing. */
@Composable
private fun VitalReadingsTable(rows: List<VitalReadingRow>) {
    if (rows.isEmpty()) return
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Overline("Readings")
            // Slim column header naming the three columns — SAME weights as the data rows below so each
            // label sits over its column. Swift twin (MetricExplorerView.readingsTable) mirrors this.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    uiString(R.string.l10n_health_screen_date_eb9a4bc1),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    uiString(R.string.l10n_health_screen_value_8dce170d),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                )
                Text(
                    uiString(R.string.l10n_health_screen_source_6da13add),
                    style = NoopType.footnote,
                    color = Palette.textSecondary,
                    textAlign = TextAlign.End,
                    modifier = Modifier.weight(1f),
                )
            }
            rows.forEachIndexed { index, row ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        row.time,
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        row.value,
                        style = NoopType.bodyNumber,
                        color = Palette.textPrimary,
                    )
                    Text(
                        row.source,
                        style = NoopType.footnote,
                        color = provenanceLabelTint(row.source),
                        textAlign = TextAlign.End,
                        modifier = Modifier.weight(1f),
                    )
                }
                if (index < rows.size - 1) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(Metrics.divider)
                            .background(Palette.hairline),
                    )
                }
            }
        }
    }
}

@Composable
private fun RecentDaySelectorBar(selectedOffset: Int, onSelect: (Int) -> Unit) {
    ThreeDaySelectorBar(selectedOffset = selectedOffset, onSelect = onSelect)
}

private fun buildVitalDetail(
    days: List<DailyMetric>,
    key: String,
    tempUnit: TemperatureUnit,
    effortScale: EffortScale = EffortScale.HUNDRED,
): VitalDetailModel? {
    return when (key) {
    // The Today Key-Metrics Recovery tile's drill-in: the Recovery (Charge) trend timeline, matching the
    // Sleep night-detail pattern. Today's DRIVERS stay on the hero ring's breakdown sheet; this is history.
    "recovery" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_recovery_ea924f72),
        unit = "%",
        color = Palette.chargeColor,
        readings = days.mapNotNull { row -> row.recovery?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { it.roundToInt().toString() },
    )
    // The Today Key-Metrics Effort tile's drill-in: the day-strain trend, rendered per the user's Effort
    // display scale like the tile itself. Readings store the RAW 0-100 composite; only format() scales.
    "strain" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_effort_8c974bc6),
        unit = if (effortScale == EffortScale.HUNDRED) "%" else "",
        color = Palette.effortColor,
        readings = days.mapNotNull { row -> row.strain?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { UnitFormatter.effortDisplay(it, effortScale) },
    )
    "resp" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_respiratory_rate_3fbb532f),
        unit = "rpm",
        color = Palette.metricCyan,
        readings = days.mapNotNull { row -> row.respRateBpm?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { String.format(Locale.US, "%.1f", it) },
    )
    "spo2" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_blood_oxygen_a8ad9ff5),
        unit = "%",
        color = Palette.metricCyan,
        readings = days.mapNotNull { row -> row.spo2Pct?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { String.format(Locale.US, "%.0f", it) },
    )
    "rhr" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_resting_heart_rate_9700f4d8),
        unit = "bpm",
        color = Palette.metricRose,
        readings = days.mapNotNull { row -> row.restingHr?.toDouble()?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { it.roundToInt().toString() },
    )
    "hrv" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_heart_rate_variability_20f0069e),
        unit = "ms",
        color = Palette.metricPurple,
        readings = days.mapNotNull { row -> row.avgHrv?.let { VitalReading(row.day, it, row.deviceId) } },
        format = { it.roundToInt().toString() },
    )
    "skin" -> {
        val latest = days.asReversed().asSequence().mapNotNull { it.skinTempDevC }.firstOrNull() ?: return null
        val absolute = VitalBands.isAbsoluteSkinTemp(latest)
        val unit = UnitFormatter.temperatureUnit(tempUnit)
        val format: (Double) -> String = { c ->
            val full = if (absolute) {
                UnitFormatter.temperatureFromCelsius(c, tempUnit, decimals = 1)
            } else {
                UnitFormatter.temperatureDeltaFromCelsius(c, tempUnit, decimals = 1)
            }
            full.removeSuffix(" $unit")
        }
        VitalDetailModel(
            key = key,
            title = uiString(R.string.l10n_health_screen_skin_temperature_f59127f6),
            unit = unit,
            color = Palette.metricAmber,
            readings = days.mapNotNull { row ->
                row.skinTempDevC
                    ?.takeIf { VitalBands.isAbsoluteSkinTemp(it) == absolute }
                    ?.let { value -> VitalReading(row.day, value, row.deviceId) }
            },
            format = format,
        )
    }
    else -> null
    }
}

/** Build a metric-detail trend for a [SERIES_BACKED_VITAL_KEYS] key by reading its persisted series from
 *  the repo (async): Fitness Age + Vitality off the computed strap the IntelligenceEngine writes, Steps
 *  off the resolved step series (imported ∪ estimated), Active Energy off the Apple-Health import. Colours
 *  match each card's dashboard tint. Returns null for an unknown key. */
private suspend fun buildSeriesVitalDetail(
    vm: AppViewModel,
    key: String,
    massUnit: MassUnit,
    activeDeviceId: String,
): VitalDetailModel? = when (key) {
    // The Today Key-Metrics Rest tile's drill-in: the Rest composite (sleep_performance) trend, read via
    // the SAME imported-wins resolvedSeries merge the tile's score/sparkline use, so the detail can never
    // disagree with the tile (#248 lineage). Each reading names its winning source for the caption.
    "rest" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_rest_b79e5f48),
        unit = "%",
        color = Palette.restColor,
        readings = vm.repo.resolvedSeries("sleep_performance", "my-whoop", "0000-00-00", "9999-99-99",
            strapDeviceId = activeDeviceId)
            .points.map { VitalReading(it.day, it.value, it.source) },
        format = { it.roundToInt().toString() },
    )
    "fitness_age" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_fitness_age_12383b4a),
        unit = "",
        color = Palette.chargeColor,
        readings = vm.repo.metricSeriesComputedUnion(activeDeviceId, "fitness_age", "0000-01-01", "9999-12-31")
            .map { VitalReading(it.day, it.value, it.deviceId) },
        format = FitnessAgePresentation::value,
    )
    "vitality" -> VitalDetailModel(
        key = key,
        title = uiString(R.string.l10n_health_screen_vitality_be320b06),
        unit = "",
        color = Palette.metricPurple,
        readings = vm.repo.metricSeriesComputedUnion(activeDeviceId, "vitality", "0000-01-01", "9999-12-31")
            .map { VitalReading(it.day, it.value, it.deviceId) },
        format = { it.roundToInt().toString() },
    )
    "weight", "hrv", "rhr", "body_fat", "lean_mass", "vo2max" -> {
        val preferredSource = if (key == "hrv" || key == "rhr") "my-whoop" else "apple-health"
        val resolved = vm.repo.resolvedSeries(
            key = key,
            preferredSource = preferredSource,
            from = "0000-01-01",
            to = "9999-12-31",
            strapDeviceId = activeDeviceId,
        )
        val title = when (key) {
            "weight" -> "Weight"
            "hrv" -> "HRV"
            "rhr" -> "Resting HR"
            "body_fat" -> "Body Fat"
            "lean_mass" -> "Lean Body Mass"
            else -> "VO₂ Max"
        }
        val unit = when (key) {
            "weight", "lean_mass" -> UnitFormatter.massUnit(massUnit)
            "hrv" -> "ms"
            "rhr" -> "bpm"
            "body_fat" -> "%"
            else -> "ml/kg/min"
        }
        val format: (Double) -> String = when (key) {
            "weight", "lean_mass" -> { value ->
                UnitFormatter.massFromKilograms(value, massUnit).removeSuffix(" $unit")
            }
            "hrv", "rhr" -> { value -> value.roundToInt().toString() }
            else -> { value -> String.format(Locale.US, "%.1f", value) }
        }
        VitalDetailModel(
            key = key,
            title = title,
            unit = unit,
            color = biomarkerTrendColor(key),
            readings = resolved.points.map { VitalReading(it.day, it.value, it.source) },
            format = format,
        )
    }
    "steps_est" -> {
        // #377: the Today Steps tile resolves an imported measured Health Connect / Apple Health count
        // first, then WHOOP 5/MG's @57 motion estimate, then the calibrated motion-model fallback.
        // detail read the calibrated estimate ALONE, so a WHOOP 5.0 with an @57 value saw that history —
        // clamped flat at StepsEstimateEngine.MAX_DAILY_STEPS = 60,000 when the motion fit over-shoots —
        // instead of its direct motion estimate. Resolve per day with the SAME precedence so graph + Readings
        // match the card. iOS routes the @57 path through its explicitly motion-estimate descriptor.
        // Strap estimates live in DailyMetric.steps; imported measured steps in AppleDaily; the calibrated
        // estimate in the "steps_est" series - three disjoint stores, so the
        // per-day `?:` chain never double-counts.
        val motionDerived = vm.repo.resolvedSeries("steps", "my-whoop", "0000-00-00", "9999-99-99",
            strapDeviceId = activeDeviceId)
            .points.associateBy({ it.day }, {
                VitalReading(it.day, it.value, MOTION_DERIVED_STEPS_SOURCE)
            })
        val imported = LinkedHashMap<String, VitalReading>()
        for (r in vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31") +
            vm.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31")) {
            val s = r.steps
            if (s != null && s > 0) {
                val candidate = VitalReading(r.day, s.toDouble(), r.deviceId)
                if (candidate.value > (imported[r.day]?.value ?: Double.NEGATIVE_INFINITY)) {
                    imported[r.day] = candidate
                }
            }
        }
        val calibratedEstimate = vm.repo.resolvedSeries("steps_est", "my-whoop", "0000-00-00", "9999-99-99",
            strapDeviceId = activeDeviceId)
            .points.associateBy({ it.day }, {
                VitalReading(it.day, it.value, CALIBRATED_MOTION_STEPS_SOURCE)
            })
        VitalDetailModel(
            key = key,
            title = uiString(R.string.l10n_health_screen_steps_cdde4f20),
            unit = "steps",
            color = Palette.metricCyan,
            readings = mergeStepsReadings(motionDerived, imported, calibratedEstimate),
            format = { it.roundToInt().toString() },
        )
    }
    "active_kcal" -> {
        // #616: calories, like steps (#377), come from TWO disjoint stores — the on-device HR estimate
        // (DailyMetric.activeKcalEst, exposed by resolvedSeries("active_kcal")) and imported Apple/Health-
        // Connect active energy (AppleDaily.activeKcal, where Health Connect writes it — NOT an active_kcal
        // metricSeries row). Reading imports ALONE opened an empty / HealthConnect-only detail for a WHOOP
        // 5.0 user whose calories are on-device, and disagreed with the Key-Metrics tile. Resolve per day
        // IMPORTED-FIRST (the phone's activeKcal, else NOOP's on-device estimate) — matching the tile + card
        // so the chart + Readings agree, while keeping every imported day in the union.
        val real = vm.repo.resolvedSeries("active_kcal", "my-whoop", "0000-00-00", "9999-99-99",
            strapDeviceId = activeDeviceId)
            .points.associateBy({ it.day }, { VitalReading(it.day, it.value, it.source) })
        val imported = LinkedHashMap<String, VitalReading>()
        for (r in vm.repo.appleDaily("apple-health", "0000-01-01", "9999-12-31") +
            vm.repo.appleDaily("health-connect", "0000-01-01", "9999-12-31")) {
            val k = r.activeKcal
            if (k != null && k > 0) imported.putIfAbsent(r.day, VitalReading(r.day, k, r.deviceId))
        }
        VitalDetailModel(
            key = key,
            title = uiString(R.string.l10n_health_screen_active_energy_2d3288f9),
            unit = "kcal",
            color = Palette.metricAmber,
            readings = mergeReadings(imported, real),   // imported wins its day, else on-device estimate
            format = { it.roundToInt().toString() },
        )
    }
    else -> null
}

// MARK: - Empty state

@Composable
private fun HealthEmptyState() {
    DataPendingNote(
        title = uiString(R.string.l10n_health_screen_no_biometrics_yet_7c594a6c),
        body = "No biometrics yet. Import a wearable export (and Apple Health if you " +
            "have it) in Data Sources to fill this in.",
    )
}
