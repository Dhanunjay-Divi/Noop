package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.DailyAutonomicLoad
import com.noop.analytics.RecoveryScorer
import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric
import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

private const val MONTH_YEAR_PATTERN = "MMMM yyyy"

internal enum class CalendarMetric(
    @StringRes val titleRes: Int,
    val icon: ImageVector,
    val valence: CalendarMetricValence,
) {
    EFFORT(
        R.string.appwide_day_overview_effort,
        Icons.Filled.LocalFireDepartment,
        CalendarMetricValence.NEUTRAL_QUANTITY,
    ),
    RECOVERY(
        R.string.appwide_day_overview_recovery,
        Icons.Filled.Favorite,
        CalendarMetricValence.HIGHER_IS_BETTER,
    ),
    SLEEP(
        R.string.appwide_day_overview_sleep,
        Icons.Filled.Bedtime,
        CalendarMetricValence.HIGHER_IS_BETTER,
    ),
    STRESS(
        R.string.nav_stress,
        Icons.Filled.Spa,
        CalendarMetricValence.HIGHER_IS_WORSE,
    ),
    ENERGY(
        R.string.l10n_health_screen_active_energy_2d3288f9,
        Icons.Filled.Bolt,
        CalendarMetricValence.NEUTRAL_QUANTITY,
    ),
    NUTRITION(
        R.string.nav_nutrition,
        Icons.Filled.Restaurant,
        CalendarMetricValence.NEUTRAL_QUANTITY,
    ),
}

internal fun CalendarMetric.dayOverviewScope(): DayOverviewScope = when (this) {
    CalendarMetric.EFFORT -> DayOverviewScope.ACTIVITY
    CalendarMetric.RECOVERY -> DayOverviewScope.RECOVERY
    CalendarMetric.SLEEP -> DayOverviewScope.SLEEP
    CalendarMetric.STRESS -> DayOverviewScope.STRESS
    CalendarMetric.ENERGY -> DayOverviewScope.ENERGY
    CalendarMetric.NUTRITION -> DayOverviewScope.NUTRITION
}

internal enum class CalendarMetricValence {
    HIGHER_IS_BETTER,
    HIGHER_IS_WORSE,
    NEUTRAL_QUANTITY,
}

internal data class CalendarMonthSnapshot(
    val dailyByDay: Map<String, DailyMetric> = emptyMap(),
    val stressByDay: Map<String, Double> = emptyMap(),
    val energyByDay: Map<String, Double> = emptyMap(),
    val nutritionByDay: Map<String, Double> = emptyMap(),
)

internal fun calendarMetricValue(
    metric: CalendarMetric,
    day: String,
    snapshot: CalendarMonthSnapshot,
): Double? = when (metric) {
    CalendarMetric.EFFORT -> snapshot.dailyByDay[day]?.strain
    CalendarMetric.RECOVERY -> snapshot.dailyByDay[day]?.recovery
    CalendarMetric.SLEEP -> snapshot.dailyByDay[day]?.let(RestScorer::restFromDaily)
    CalendarMetric.STRESS -> snapshot.stressByDay[day]
    CalendarMetric.ENERGY -> snapshot.energyByDay[day]
    CalendarMetric.NUTRITION -> snapshot.nutritionByDay[day]
}?.takeIf(Double::isFinite)

internal fun calendarNormalizedProgress(
    metric: CalendarMetric,
    value: Double,
    observedValues: Collection<Double>,
): Double {
    if (!value.isFinite()) return 0.0
    return when (metric) {
        CalendarMetric.EFFORT,
        CalendarMetric.RECOVERY,
        CalendarMetric.SLEEP -> value.coerceIn(0.0, 100.0)
        CalendarMetric.STRESS -> (value / 3.0 * 100.0).coerceIn(0.0, 100.0)
        CalendarMetric.ENERGY,
        CalendarMetric.NUTRITION -> {
            val ceiling = observedValues.filter { it.isFinite() && it > 0.0 }.maxOrNull() ?: 0.0
            if (ceiling <= 0.0) 0.0 else (value / ceiling * 100.0).coerceIn(0.0, 100.0)
        }
    }
}

internal fun calendarStressByDay(
    days: List<DailyMetric>,
    preferred: Map<String, Double>,
    fromDay: String,
    throughDay: String,
): Map<String, Double> {
    val merged = DailyAutonomicLoad.causalTrend(
        days.map {
            DailyAutonomicLoad.Day(
                day = it.day,
                restingHeartRate = it.restingHr?.toDouble(),
                hrv = it.avgHrv,
            )
        },
    ).asSequence()
        .filter { it.confidence == DailyAutonomicLoad.Confidence.RELIABLE }
        .mapNotNull { readout ->
            val day = readout.asOf ?: return@mapNotNull null
            val value = readout.value ?: return@mapNotNull null
            (day to value).takeIf {
                day in fromDay..throughDay && value.isFinite() && value >= 0.0
            }
        }
        .toMap(LinkedHashMap())

    preferred.forEach { (day, value) ->
        if (day in fromDay..throughDay && value.isFinite() && value >= 0.0) {
            merged[day] = value
        }
    }
    return merged
}

private data class CalendarDayOverviewTarget(
    val day: LocalDate,
    val metric: CalendarMetric,
    val focusValue: Double?,
)

private data class CalendarDayOverviewContent(
    val target: CalendarDayOverviewTarget,
    val daily: DailyMetric?,
    val metricRows: List<MetricSeriesRow>,
)

@Composable
internal fun CalendarMonthScreen(
    vm: AppViewModel,
) {
    val allWorkouts by vm.workouts.collectAsStateWithLifecycle()
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()
    val metricDataVersion by vm.metricDataVersion.collectAsStateWithLifecycle()
    val workoutDataVersion by vm.workoutDataVersion.collectAsStateWithLifecycle()
    val dailyDataSignature = recentDays.hashCode()
    var month by remember { mutableStateOf(YearMonth.now()) }
    var metric by remember { mutableStateOf(CalendarMetric.RECOVERY) }
    var snapshot by remember { mutableStateOf(CalendarMonthSnapshot()) }
    var loading by remember { mutableStateOf(true) }
    var loadFailed by remember { mutableStateOf(false) }
    var selectedOverview by remember { mutableStateOf<CalendarDayOverviewTarget?>(null) }
    var overviewContent by remember { mutableStateOf<CalendarDayOverviewContent?>(null) }

    LaunchedEffect(vm.activeStrapId, workoutDataVersion) {
        vm.loadWorkouts()
    }

    LaunchedEffect(month, vm.activeStrapId, metricDataVersion, dailyDataSignature) {
        loading = true
        loadFailed = false
        val from = month.atDay(1).toString()
        val through = month.atEndOfMonth().toString()
        val baselineFrom = month.atDay(1)
            .minusDays(
                (DailyAutonomicLoad.BASELINE_WINDOW_DAYS +
                    DailyAutonomicLoad.MINIMUM_BASELINE_DAYS).toLong(),
            )
            .toString()
        try {
            snapshot = coroutineScope {
                val daily = async {
                    vm.repo.daysMerged(vm.activeStrapId, baselineFrom, through)
                }
                val stress = async {
                    vm.repo.resolvedSeries(
                        key = "stress",
                        preferredSource = vm.activeStrapId,
                        from = from,
                        to = through,
                        strapDeviceId = vm.activeStrapId,
                    ).points
                }
                val appleEnergy = async {
                    vm.repo.metricSeries(
                        WhoopRepository.APPLE_HEALTH_SOURCE,
                        "active_kcal",
                        from,
                        through,
                    )
                }
                val healthConnectEnergy = async {
                    vm.repo.metricSeries(
                        WhoopRepository.HEALTH_CONNECT_SOURCE,
                        "active_kcal",
                        from,
                        through,
                    )
                }
                val nutrition = async {
                    vm.repo.resolvedSeries(
                        key = "calories_in",
                        preferredSource = "nutrition-log",
                        from = from,
                        to = through,
                        strapDeviceId = vm.activeStrapId,
                    ).points
                }

                val energyByDay = LinkedHashMap<String, Double>()
                healthConnectEnergy.await()
                    .filter { it.value.isFinite() && it.value >= 0.0 }
                    .forEach { energyByDay[it.day] = it.value }
                appleEnergy.await()
                    .filter { it.value.isFinite() && it.value >= 0.0 }
                    .forEach { energyByDay[it.day] = it.value }

                val history = daily.await()
                val preferredStress = stress.await()
                        .filter { it.value.isFinite() && it.value >= 0.0 }
                        .associate { it.day to it.value }
                CalendarMonthSnapshot(
                    dailyByDay = history
                        .filter { it.day in from..through }
                        .associateBy(DailyMetric::day),
                    stressByDay = calendarStressByDay(
                        days = history,
                        preferred = preferredStress,
                        fromDay = from,
                        throughDay = through,
                    ),
                    energyByDay = energyByDay,
                    nutritionByDay = nutrition.await()
                        .filter { it.value.isFinite() && it.value >= 0.0 }
                        .associate { it.day to it.value },
                )
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            snapshot = CalendarMonthSnapshot()
            loadFailed = true
        } finally {
            loading = false
        }
    }

    ScreenScaffold(
        title = stringResource(R.string.appwide_calendar_your_month),
        subtitle = stringResource(R.string.appwide_calendar_subtitle),
        topBackground = { CalendarHeaderBackdrop() },
    ) {
        CalendarMonthHeader(
            month = month,
            canAdvance = month < YearMonth.now(),
            onPrevious = { month = month.minusMonths(1) },
            onNext = { if (month < YearMonth.now()) month = month.plusMonths(1) },
        )
        CalendarMetricPicker(metric = metric, onSelect = { metric = it })
        CalendarMonthGrid(
            month = month,
            metric = metric,
            snapshot = snapshot,
            loading = loading,
            loadFailed = loadFailed,
            onSelectDay = { day ->
                selectedOverview = CalendarDayOverviewTarget(
                    day = day,
                    metric = metric,
                    focusValue = calendarMetricValue(metric, day.toString(), snapshot),
                )
            },
        )
        CalendarLegend(metric)
        CalendarMonthSummary(month, metric, snapshot)
    }

    selectedOverview?.let { target ->
        val scope = target.metric.dayOverviewScope()
        LaunchedEffect(target, vm.activeStrapId, metricDataVersion, dailyDataSignature) {
            overviewContent = null
            val key = target.day.toString()
            overviewContent = try {
                coroutineScope {
                    val daily = async {
                        vm.repo.daysMerged(vm.activeStrapId, key, key)
                            .lastOrNull { it.day == key }
                    }
                    val metrics = async {
                        if (scope.loadsMetricRows) vm.repo.metricSeriesForDay(key) else emptyList()
                    }
                    CalendarDayOverviewContent(
                        target = target,
                        daily = daily.await(),
                        metricRows = metrics.await(),
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                CalendarDayOverviewContent(target, null, emptyList())
            }
        }

        val exact = overviewContent?.takeIf { it.target == target }
        val zone = ZoneId.systemDefault()
        val dayWorkouts = if (scope.includesSessions) {
            allWorkouts.filter {
                Instant.ofEpochSecond(it.startTs).atZone(zone).toLocalDate() == target.day
            }
        } else {
            emptyList()
        }
        WorkoutDayOverviewSheet(
            day = target.day,
            scope = scope,
            focusValue = target.focusValue,
            daily = exact?.daily,
            workouts = dayWorkouts,
            metricRows = exact?.metricRows.orEmpty(),
            journal = emptyList(),
            activeStrapId = vm.activeStrapId,
            loading = exact == null,
            onDismiss = {
                selectedOverview = null
                overviewContent = null
            },
        )
    }
}

@Composable
private fun CalendarHeaderBackdrop() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(380.dp)
            .background(
                Brush.verticalGradient(
                    colors = listOf(
                        Color(0xFF042918),
                        Color.Black.copy(alpha = 0.88f),
                        Color.Black.copy(alpha = 0.30f),
                        Color.Transparent,
                    ),
                ),
            ),
    )
}

@Composable
private fun CalendarMonthHeader(
    month: YearMonth,
    canAdvance: Boolean,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
) {
    val locale = Locale.getDefault()
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onPrevious, modifier = Modifier.size(44.dp)) {
            Icon(
                Icons.Filled.ChevronLeft,
                contentDescription = stringResource(R.string.appwide_calendar_previous_month),
                tint = Palette.textSecondary,
            )
        }
        Text(
            month.atDay(1).format(DateTimeFormatter.ofPattern(MONTH_YEAR_PATTERN, locale)),
            style = NoopType.headline,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .weight(1f)
                .testTag("noop.calendar.month"),
        )
        IconButton(
            onClick = onNext,
            enabled = canAdvance,
            modifier = Modifier.size(44.dp),
        ) {
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = stringResource(R.string.appwide_calendar_next_month),
                tint = if (canAdvance) Palette.textSecondary else Palette.textTertiary.copy(alpha = 0.35f),
            )
        }
    }
}

@Composable
private fun CalendarMetricPicker(
    metric: CalendarMetric,
    onSelect: (CalendarMetric) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        CalendarMetric.entries.forEach { option ->
            val isSelected = option == metric
            val tint = option.calendarTint()
            Row(
                modifier = Modifier
                    .height(44.dp)
                    .clip(CircleShape)
                    .background(
                        if (isSelected) tint.copy(alpha = 0.18f)
                        else Palette.surfaceInset.copy(alpha = 0.72f),
                    )
                    .border(
                        width = 1.dp,
                        color = if (isSelected) tint.copy(alpha = 0.5f) else Palette.hairline,
                        shape = CircleShape,
                    )
                    .clickable(onClick = { onSelect(option) })
                    .semantics {
                        selected = isSelected
                        role = Role.Button
                    }
                    .padding(horizontal = Metrics.space12),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MetricGlyph(option.icon, size = 18.dp)
                Text(
                    stringResource(option.titleRes),
                    style = NoopType.subhead,
                    color = if (isSelected) Palette.textPrimary else Palette.textSecondary,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun CalendarMonthGrid(
    month: YearMonth,
    metric: CalendarMetric,
    snapshot: CalendarMonthSnapshot,
    loading: Boolean,
    loadFailed: Boolean,
    onSelectDay: (LocalDate) -> Unit,
) {
    val locale = Locale.getDefault()
    val firstWeekday = remember(locale) { WeekFields.of(locale).firstDayOfWeek }
    val weekdayInitials = remember(locale, firstWeekday) {
        (0L..6L).map {
            firstWeekday.plus(it).getDisplayName(TextStyle.NARROW_STANDALONE, locale)
        }
    }
    val first = month.atDay(1)
    val leading = (first.dayOfWeek.value - firstWeekday.value + 7) % 7
    val cells = List<LocalDate?>(leading) { null } +
        (1..month.lengthOfMonth()).map(month::atDay)
    val values = remember(metric, snapshot) {
        cells.mapNotNull { it?.toString()?.let { key -> calendarMetricValue(metric, key, snapshot) } }
    }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MetricGlyph(metric.icon, size = 16.dp)
                Text(
                    stringResource(metric.titleRes),
                    style = NoopType.subhead,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    calendarMetricUnit(metric),
                    style = NoopType.captionNumber,
                    color = Palette.textSecondary,
                )
            }
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(Palette.hairline),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
            ) {
                weekdayInitials.forEach {
                    Text(
                        it,
                        style = NoopType.overline,
                        color = Palette.textTertiary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f),
                    )
                }
            }
            cells.chunked(7).forEach { week ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
                ) {
                    week.forEach { day ->
                        if (day == null) {
                            Spacer(Modifier.weight(1f).height(52.dp))
                        } else {
                            CalendarDayCell(
                                day = day,
                                metric = metric,
                                value = calendarMetricValue(metric, day.toString(), snapshot),
                                observedValues = values,
                                onClick = { onSelectDay(day) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                    repeat(7 - week.size) {
                        Spacer(Modifier.weight(1f).height(52.dp))
                    }
                }
            }
            if (loading) {
                CircularProgressIndicator(
                    modifier = Modifier
                        .align(Alignment.CenterHorizontally)
                        .size(20.dp),
                    color = Palette.accent,
                    strokeWidth = 2.dp,
                )
            } else if (loadFailed) {
                Text(
                    stringResource(R.string.appwide_day_overview_no_data),
                    style = NoopType.footnote,
                    color = Palette.statusCritical,
                    modifier = Modifier.align(Alignment.CenterHorizontally),
                )
            }
        }
    }
}

@Composable
private fun CalendarDayCell(
    day: LocalDate,
    metric: CalendarMetric,
    value: Double?,
    observedValues: Collection<Double>,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = value?.let { calendarNormalizedProgress(metric, it, observedValues) }
    val today = day == LocalDate.now()
    val metricTitle = stringResource(metric.titleRes)
    val spoken = if (value == null) {
        stringResource(
            if (today) R.string.appwide_calendar_a11y_today_no_data_format
            else R.string.appwide_calendar_a11y_day_no_data_format,
            day.dayOfMonth,
        )
    } else {
        stringResource(
            if (today) R.string.appwide_calendar_a11y_today_value_format
            else R.string.appwide_calendar_a11y_day_value_format,
            day.dayOfMonth,
            metricTitle,
            calendarMetricFormat(metric, value),
        )
    }

    Column(
        modifier = modifier
            .height(52.dp)
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = spoken
                role = Role.Button
            }
            .testTag("noop.calendar.day.${day}"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(
            modifier = Modifier.size(34.dp),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val stroke = 4.dp.toPx()
                drawCircle(
                    color = Palette.hairlineStrong.copy(alpha = 0.48f),
                    style = Stroke(width = stroke),
                )
                progress?.let {
                    drawArc(
                        color = calendarStepColor(it, metric),
                        startAngle = -90f,
                        sweepAngle = max(9.0, it * 3.6).toFloat(),
                        useCenter = false,
                        style = Stroke(width = stroke, cap = StrokeCap.Round),
                    )
                }
                if (today) {
                    drawCircle(
                        color = Palette.textPrimary.copy(alpha = 0.88f),
                        radius = size.minDimension / 2f + 2.dp.toPx(),
                        style = Stroke(width = 1.4.dp.toPx()),
                    )
                }
            }
            value?.let {
                Text(
                    calendarMetricCellValue(metric, it),
                    style = NoopType.number(
                        if (metric == CalendarMetric.ENERGY ||
                            metric == CalendarMetric.NUTRITION
                        ) {
                            8f
                        } else {
                            9f
                        },
                    ),
                    color = Palette.textPrimary,
                    maxLines = 1,
                )
            }
        }
        Text(
            day.dayOfMonth.toString(),
            style = NoopType.number(10f),
            color = if (today) Palette.textPrimary else Palette.textTertiary,
            maxLines = 1,
        )
    }
}

@Composable
private fun CalendarLegend(metric: CalendarMetric) {
    val labels = when {
        metric == CalendarMetric.RECOVERY -> listOf(
            recoveryBandLabel(0.0),
            recoveryBandLabel(50.0),
            recoveryBandLabel(100.0),
        )
        metric.valence == CalendarMetricValence.HIGHER_IS_BETTER -> listOf(
            stringResource(R.string.appwide_calendar_legend_low),
            stringResource(R.string.appwide_calendar_legend_middling),
            stringResource(R.string.appwide_calendar_legend_strong),
        )
        metric.valence == CalendarMetricValence.HIGHER_IS_WORSE -> listOf(
            stringResource(R.string.appwide_calendar_legend_calm),
            stringResource(R.string.appwide_calendar_legend_elevated),
            stringResource(R.string.appwide_calendar_legend_high),
        )
        else -> if (metric == CalendarMetric.EFFORT) {
            listOf(
                stringResource(R.string.appwide_calendar_legend_easy),
                stringResource(R.string.appwide_calendar_legend_moderate),
                stringResource(R.string.appwide_calendar_legend_hard),
            )
        } else {
            listOf(
                stringResource(R.string.appwide_calendar_legend_low),
                stringResource(R.string.appwide_calendar_legend_middling),
                stringResource(R.string.appwide_calendar_legend_high),
            )
        }
    }
    val provenance = when (metric) {
        CalendarMetric.STRESS -> R.string.appwide_calendar_stress_provenance
        CalendarMetric.ENERGY -> R.string.appwide_calendar_energy_provenance
        CalendarMetric.NUTRITION -> R.string.appwide_calendar_nutrition_provenance
        else -> null
    }
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            labels.forEachIndexed { index, label ->
                CalendarLegendChip(
                    label = label,
                    color = calendarStepColor(listOf(10.0, 50.0, 90.0)[index], metric),
                )
            }
            CalendarLegendChip(
                label = stringResource(R.string.appwide_calendar_legend_no_data),
                color = Color.Transparent,
                outlined = true,
            )
        }
        provenance?.let {
            Text(
                stringResource(it),
                style = NoopType.caption,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun CalendarLegendChip(
    label: String,
    color: Color,
    outlined: Boolean = false,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Metrics.space4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(10.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(color)
                .then(
                    if (outlined) {
                        Modifier.border(1.dp, Palette.hairline, RoundedCornerShape(3.dp))
                    } else {
                        Modifier
                    },
                ),
        )
        Text(label, style = NoopType.caption, color = Palette.textTertiary, maxLines = 1)
    }
}

@Composable
private fun CalendarMonthSummary(
    month: YearMonth,
    metric: CalendarMetric,
    snapshot: CalendarMonthSnapshot,
) {
    val values = (1..month.lengthOfMonth()).mapNotNull {
        calendarMetricValue(metric, month.atDay(it).toString(), snapshot)
    }
    val title = stringResource(metric.titleRes).lowercase(Locale.getDefault())
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
            Overline(stringResource(R.string.appwide_calendar_summary_overline))
            if (values.isEmpty()) {
                Text(
                    stringResource(R.string.appwide_calendar_summary_empty_format, title),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            } else {
                val mean = values.average()
                Text(
                    stringResource(
                        R.string.appwide_calendar_summary_scored_format,
                        values.size,
                        calendarMetricFormat(metric, mean),
                    ),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Text(
                    stringResource(R.string.appwide_calendar_summary_gaps),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

private fun CalendarMetric.calendarTint(): Color = when (this) {
    CalendarMetric.EFFORT -> Palette.effortColor
    CalendarMetric.RECOVERY -> Palette.chargeColor
    CalendarMetric.SLEEP -> Palette.restColor
    CalendarMetric.STRESS -> Palette.metricAmber
    CalendarMetric.ENERGY -> Palette.statusWarning
    CalendarMetric.NUTRITION -> Palette.statusPositive
}

private fun calendarStepColor(
    progress: Double,
    metric: CalendarMetric,
): Color {
    val value = progress.coerceIn(0.0, 100.0)
    if (metric == CalendarMetric.RECOVERY) {
        return RecoveryBandPresentation.color(value).copy(alpha = 0.9f)
    }
    val low = value < RecoveryScorer.bandRedMax
    val middle = value < RecoveryScorer.bandYellowMax
    return when (metric.valence) {
        CalendarMetricValence.HIGHER_IS_BETTER -> when {
            low -> Palette.statusCritical.copy(alpha = 0.85f)
            middle -> Palette.statusWarning.copy(alpha = 0.85f)
            else -> metric.calendarTint().copy(alpha = 0.9f)
        }
        CalendarMetricValence.HIGHER_IS_WORSE -> when {
            low -> metric.calendarTint().copy(alpha = 0.9f)
            middle -> Palette.statusWarning.copy(alpha = 0.85f)
            else -> Palette.statusCritical.copy(alpha = 0.85f)
        }
        CalendarMetricValence.NEUTRAL_QUANTITY -> metric.calendarTint().copy(
            alpha = when {
                low -> 0.55f
                middle -> 0.75f
                else -> 0.95f
            },
        )
    }
}

private fun calendarMetricFormat(metric: CalendarMetric, value: Double): String = when (metric) {
    CalendarMetric.EFFORT -> "${value.roundToInt()} /100"
    CalendarMetric.RECOVERY,
    CalendarMetric.SLEEP -> "${value.roundToInt()}%"
    CalendarMetric.STRESS -> String.format(Locale.getDefault(), "%.1f /3", value)
    CalendarMetric.ENERGY,
    CalendarMetric.NUTRITION -> "${value.roundToInt()} kcal"
}

private fun calendarMetricUnit(metric: CalendarMetric): String = when (metric) {
    CalendarMetric.EFFORT -> "/100"
    CalendarMetric.RECOVERY, CalendarMetric.SLEEP -> "%"
    CalendarMetric.STRESS -> "/3"
    CalendarMetric.ENERGY, CalendarMetric.NUTRITION -> "kcal"
}

internal fun calendarMetricCellValue(
    metric: CalendarMetric,
    value: Double,
    locale: Locale = Locale.getDefault(),
): String = when (metric) {
    CalendarMetric.EFFORT,
    CalendarMetric.RECOVERY,
    CalendarMetric.SLEEP -> value.roundToInt().toString()
    CalendarMetric.STRESS -> String.format(locale, "%.1f", value)
    CalendarMetric.ENERGY,
    CalendarMetric.NUTRITION -> {
        val rounded = value.roundToInt()
        if (abs(rounded) < 1_000) {
            rounded.toString()
        } else {
            val thousands = (value / 100.0).roundToInt() / 10.0
            if (thousands == thousands.roundToInt().toDouble()) {
                "${thousands.roundToInt()}k"
            } else {
                String.format(locale, "%.1fk", thousands)
            }
        }
    }
}
