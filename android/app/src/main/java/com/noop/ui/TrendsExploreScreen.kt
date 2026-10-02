package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowDropUp
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.HydrationStore
import com.noop.data.DailyMetric
import com.noop.data.MoodStore
import com.noop.data.NutritionLogContract
import com.noop.data.WhoopRepository
import com.noop.analytics.BodyProfilePolicy
import com.noop.ingest.HealthConnectImporter
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Explore (Metric Explorer)
//
// Port of the macOS MetricExplorerView focus: a metric picker → a hero LineChart of
// the chosen metric over a selectable window → a uniform StatTile row of summary
// stats (Average / Min / Max / Latest / Δ vs previous window).
//
// On macOS the catalog is driven by a shared MetricCatalog with per-metric formatters
// and a cross-catalog Pearson correlation sweep. On Android the daily metrics we hold
// are the built-in DailyMetric columns (recovery / strain / hrv / rhr / sleep / spo2 /
// respiratory / efficiency) plus any extra long-format keys in the metricSeries table.
// We expose exactly those as the picker, so there is no faked data: every chartable
// metric maps to a real cached series.
//
// macOS "sparse-window" rule preserved: a window is taken RELATIVE TO THE LATEST data
// point (not "now"); if the selected window holds ≥1 point we show it, and only when it
// holds ZERO points do we auto-widen to the smallest larger range that does. The hero
// always reads the latest available point + "as of <day>".

// MARK: - Window range (W / M / 3M / 6M / 1Y / ALL)

private enum class ExploreRange(val days: Int?, val label: String, val windowName: String) {
    Week(7, "W", "week"),
    Month(30, "M", "month"),
    Quarter(90, "3M", "quarter"),
    Half(180, "6M", "6 months"),
    Year(365, "1Y", "year"),
    All(null, "ALL", "all time");

    /** This range plus every larger range, ascending , the auto-widen search order. */
    val widening: List<ExploreRange>
        get() = entries.dropWhile { it != this }

    /** True when this range can reach PAST the bounded dashboard cap (WhoopRepository.RECENT_DAYS_CAP),
     *  so the built-in series must come from the UNCAPPED full history rather than the bounded `recentDays`
     *  flow to avoid silently truncating a deep import (#797 Explore-'All' follow-up). Only the open-ended
     *  'All' range ([days] == null) does; every fixed range is ≤ the cap, so it keeps using the cheap flow. */
    val reachesDeep: Boolean get() = days == null || days > WhoopRepository.RECENT_DAYS_CAP
}

// MARK: - Source-qualified metric catalog

internal data class MetricHistoryDescriptor(
    val key: String,
    val title: String,
    val category: String,
    val unit: String,
    val source: String,
    val sourceLabel: String,
    val decimals: Int,
    val higherIsBetter: Boolean?,
    val description: String? = null,
    val note: String? = null,
) {
    val id: String get() = "$source:$key"
}

/**
 * Explicit customer-facing history catalog. Internal revision, confidence, evidence, and
 * motion-estimate keys stay out of this list. A repeated key under two providers is deliberately
 * represented twice; selection and loading always use [MetricHistoryDescriptor.id].
 */
internal object AndroidMetricHistoryCatalog {
    const val DIRECT_SOURCE = "my-whoop"
    const val NOOP_SOURCE = "my-whoop-noop"

    val categories = listOf("Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind")

    val all: List<MetricHistoryDescriptor> = buildList {
        fun addMetric(
            source: String,
            sourceLabel: String,
            key: String,
            title: String,
            category: String,
            unit: String,
            decimals: Int = 0,
            higherIsBetter: Boolean? = null,
            description: String? = null,
            note: String? = null,
        ) {
            add(
                MetricHistoryDescriptor(
                    key = key,
                    title = title,
                    category = category,
                    unit = unit,
                    source = source,
                    sourceLabel = sourceLabel,
                    decimals = decimals,
                    higherIsBetter = higherIsBetter,
                    description = description,
                    note = note,
                ),
            )
        }

        fun direct(
            key: String,
            title: String,
            category: String,
            unit: String,
            decimals: Int = 0,
            higherIsBetter: Boolean? = null,
            description: String? = null,
        ) = addMetric(
            DIRECT_SOURCE, "Compatible band", key, title, category, unit,
            decimals, higherIsBetter, description,
        )

        fun noop(
            key: String,
            title: String,
            category: String,
            unit: String,
            decimals: Int = 0,
            higherIsBetter: Boolean? = null,
            description: String? = null,
        ) = addMetric(
            NOOP_SOURCE, "NOOP", key, title, category, unit,
            decimals, higherIsBetter, description,
        )

        fun apple(
            key: String,
            title: String,
            category: String,
            unit: String,
            decimals: Int = 0,
            higherIsBetter: Boolean? = null,
            note: String? = null,
        ) = addMetric(
            WhoopRepository.APPLE_HEALTH_SOURCE, "Apple Health", key, title, category, unit,
            decimals, higherIsBetter, note = note,
        )

        fun healthConnect(
            key: String,
            title: String,
            category: String,
            unit: String,
            decimals: Int = 0,
            higherIsBetter: Boolean? = null,
            note: String? = null,
        ) = addMetric(
            HealthConnectImporter.DEVICE_ID, "Health Connect", key, title, category, unit,
            decimals, higherIsBetter, note = note,
        )

        // Compatible-band measurements and imported vendor summaries.
        direct("avg_hr", "Average Heart Rate", "Heart", "bpm")
        direct("max_hr", "Max Heart Rate", "Heart", "bpm")
        direct("energy_kcal", "Calories", "Heart", "kcal")
        direct("recovery", "Recovery", "Charge", "%", higherIsBetter = true)
        direct("hrv", "Heart Rate Variability", "Charge", "ms", higherIsBetter = true)
        direct("rhr", "Resting Heart Rate", "Charge", "bpm", higherIsBetter = false)
        direct("resp_rate", "Respiratory Rate", "Charge", "rpm", decimals = 1)
        direct("spo2", "Blood Oxygen", "Charge", "%", higherIsBetter = true)
        direct("skin_temp", "Skin Temperature", "Charge", "°C", decimals = 1)
        direct("sleep_performance", "Sleep Score", "Rest", "%", higherIsBetter = true)
        direct("in_bed_min", "Time in Bed", "Rest", "min")
        direct("sleep_total_min", "Asleep Time", "Rest", "min", higherIsBetter = true)
        direct("hours_vs_needed_pct", "Hours vs Needed", "Rest", "%", higherIsBetter = true)
        direct("sleep_consistency", "Sleep Consistency", "Rest", "%", higherIsBetter = true)
        direct("restorative_pct", "Restorative Sleep", "Rest", "%", higherIsBetter = true)
        direct("restorative_min", "Restorative Sleep", "Rest", "min", higherIsBetter = true)
        direct("sleep_efficiency", "Sleep Efficiency", "Rest", "%", higherIsBetter = true)
        direct("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", higherIsBetter = true)
        direct("sleep_rem_min", "REM Sleep", "Rest", "min", higherIsBetter = true)
        direct("sleep_light_min", "Light Sleep", "Rest", "min")
        direct("sleep_need_min", "Sleep Need", "Rest", "min")
        direct("sleep_debt_min", "Sleep Debt", "Rest", "min", higherIsBetter = false)
        direct("strain", "Effort", "Effort", "/100", decimals = 1)
        direct("hr_zones13_min", "HR Zones 1-3", "Effort", "min")
        direct("hr_zones45_min", "HR Zones 4-5", "Effort", "min")
        direct("hr_zones_all_min", "HR Zones (All)", "Effort", "min")
        direct("strength_min", "Strength Activity Time", "Effort", "min")
        direct("stress", "Day Stress", "Health", "/3", decimals = 1, higherIsBetter = false)

        // NOOP-computed outputs remain separate from direct/imported values.
        noop("fitness_age", "Fitness Age", "Heart", "", higherIsBetter = false)
        noop("vo2max_est", "VO₂ Max (estimated)", "Heart", "", decimals = 1, higherIsBetter = true)
        noop("vitality", "Vitality", "Heart", "", higherIsBetter = true)
        noop("body_age", "Wellness Age", "Heart", "yrs", higherIsBetter = false)
        noop("energy_kcal", "Calories (estimated)", "Heart", "kcal")
        noop("recovery", "Recovery", "Charge", "%", higherIsBetter = true)
        noop("hrv", "Heart Rate Variability", "Charge", "ms", higherIsBetter = true)
        noop("rhr", "Resting Heart Rate", "Charge", "bpm", higherIsBetter = false)
        noop("resp_rate", "Respiratory Rate", "Charge", "rpm", decimals = 1)
        noop("spo2", "Blood Oxygen", "Charge", "%", higherIsBetter = true)
        noop("skin_temp", "Skin Temperature", "Charge", "°C", decimals = 1)
        noop("sleep_performance", "Sleep Score", "Rest", "%", higherIsBetter = true)
        noop("sleep_total_min", "Asleep Time", "Rest", "min", higherIsBetter = true)
        noop("sleep_efficiency", "Sleep Efficiency", "Rest", "%", higherIsBetter = true)
        noop("sleep_deep_min", "Deep (SWS) Sleep", "Rest", "min", higherIsBetter = true)
        noop("sleep_rem_min", "REM Sleep", "Rest", "min", higherIsBetter = true)
        noop("sleep_light_min", "Light Sleep", "Rest", "min")
        noop("strain", "Effort", "Effort", "/100", decimals = 1)
        noop("active_zone_moderate_min", "Moderate Active Minutes", "Effort", "min")
        noop("active_zone_vigorous_min", "Vigorous Active Minutes", "Effort", "min")
        noop("active_zone_credited_min", "Credited Active Minutes", "Effort", "min")
        noop("active_zone_observed_min", "Observed Active Minutes", "Effort", "min")

        // Apple Health flattened series and AppleDaily/DailyMetric projections.
        apple("avg_hr", "Average Heart Rate", "Heart", "bpm")
        apple("max_hr", "Max Heart Rate", "Heart", "bpm")
        apple("walking_hr", "Walking Heart Rate", "Heart", "bpm")
        apple("vo2max", "VO₂ Max", "Heart", "", decimals = 1, higherIsBetter = true)
        apple("resting_hr", "Resting Heart Rate", "Charge", "bpm", higherIsBetter = false)
        apple("hrv", "Heart Rate Variability", "Charge", "ms", higherIsBetter = true)
        apple("resp_rate", "Respiratory Rate", "Charge", "rpm", decimals = 1)
        apple("spo2", "Blood Oxygen", "Charge", "%", higherIsBetter = true)
        apple("in_bed_min", "Time in Bed", "Rest", "min")
        apple("asleep_min", "Asleep Time", "Rest", "min", higherIsBetter = true)
        apple("deep_min", "Deep (SWS) Sleep", "Rest", "min", higherIsBetter = true)
        apple("rem_min", "REM Sleep", "Rest", "min", higherIsBetter = true)
        apple("core_min", "Core Sleep", "Rest", "min")
        apple("awake_min", "Awake Time", "Rest", "min", higherIsBetter = false)
        apple("steps", "Steps", "Effort", "", higherIsBetter = true)
        apple("active_kcal", "Active Energy", "Effort", "kcal")
        apple("basal_kcal", "Resting Energy", "Effort", "kcal")
        apple("weight", "Weight", "Health", "kg", decimals = 1)
        apple("body_fat", "Body Fat", "Health", "%", decimals = 1, higherIsBetter = false)
        apple("lean_mass", "Lean Body Mass", "Health", "kg", decimals = 1, higherIsBetter = true)
        apple("bmi", "BMI", "Health", "", decimals = 1)
        apple(
            HealthConnectImporter.BODY_TEMPERATURE_KEY,
            "Body Temperature",
            "Health",
            "°C",
            decimals = 1,
            note = "Absolute body temperature; separate from skin-temperature deviation.",
        )
        apple(
            "wrist_temp",
            "Sleeping Wrist Temperature",
            "Health",
            "°C",
            decimals = 1,
            note = "Apple sleeping-wrist temperature; separate from body and skin temperature.",
        )
        apple(HydrationStore.KEY, "Hydration", "Health", "ml")

        // Health Connect owns its own source-qualified copies; no Apple fallback is implied.
        healthConnect("avg_hr", "Average Heart Rate", "Heart", "bpm")
        healthConnect("vo2max", "VO₂ Max", "Heart", "", decimals = 1, higherIsBetter = true)
        healthConnect("resting_hr", "Resting Heart Rate", "Charge", "bpm", higherIsBetter = false)
        healthConnect("hrv", "Heart Rate Variability", "Charge", "ms", higherIsBetter = true)
        healthConnect("resp_rate", "Respiratory Rate", "Charge", "rpm", decimals = 1)
        healthConnect("spo2", "Blood Oxygen", "Charge", "%", higherIsBetter = true)
        healthConnect("asleep_min", "Asleep Time", "Rest", "min", higherIsBetter = true)
        healthConnect("steps", "Steps", "Effort", "", higherIsBetter = true)
        healthConnect("active_kcal", "Active Energy", "Effort", "kcal")
        healthConnect("basal_kcal", "Resting Energy", "Effort", "kcal")
        healthConnect("weight", "Weight", "Health", "kg", decimals = 1)
        healthConnect("body_fat", "Body Fat", "Health", "%", decimals = 1, higherIsBetter = false)
        healthConnect("lean_mass", "Lean Body Mass", "Health", "kg", decimals = 1, higherIsBetter = true)
        healthConnect(
            "bmi",
            "BMI",
            "Health",
            "",
            decimals = 1,
            note = "Derived by the importer from measured weight and confirmed profile height.",
        )
        healthConnect(
            HealthConnectImporter.BODY_TEMPERATURE_KEY,
            "Body Temperature",
            "Health",
            "°C",
            decimals = 1,
            note = "Absolute body temperature; separate from skin-temperature deviation.",
        )
        healthConnect(
            HealthConnectImporter.BASAL_BODY_TEMPERATURE_KEY,
            "Basal Body Temperature",
            "Health",
            "°C",
            decimals = 2,
        )
        healthConnect(HydrationStore.KEY, "Hydration", "Health", "ml")

        addMetric(
            HydrationStore.SOURCE_ID, "NOOP", HydrationStore.KEY, "Hydration",
            "Health", "ml", 0, null,
        )
        addMetric(
            NutritionLogContract.DEVICE_ID, "Nutrition", "calories_in", "Calories In",
            "Nutrition", "kcal", 0, null,
        )
        addMetric(
            NutritionLogContract.DEVICE_ID, "Nutrition", "protein_g", "Protein",
            "Nutrition", "g", 0, null,
        )
        addMetric(
            NutritionLogContract.DEVICE_ID, "Nutrition", "carbs_g", "Carbs",
            "Nutrition", "g", 0, null,
        )
        addMetric(
            NutritionLogContract.DEVICE_ID, "Nutrition", "fat_g", "Fat",
            "Nutrition", "g", 0, null,
        )
        addMetric(
            MoodStore.MOOD_DEVICE_ID, "Mood", "mood", "Mood",
            "Mind", "/5", 0, true,
        )
    }

    fun visible(canPresentBmi: Boolean): List<MetricHistoryDescriptor> =
        all.filter { canPresentBmi || it.key != "bmi" }

    fun byId(id: String, canPresentBmi: Boolean = true): MetricHistoryDescriptor? =
        visible(canPresentBmi).firstOrNull { it.id == id }
}

private data class MetricSpec(
    val descriptor: MetricHistoryDescriptor,
    val accent: Color,
    val effortScale: EffortScale = EffortScale.HUNDRED,
) {
    val id: String get() = descriptor.id
    val key: String get() = descriptor.key
    val title: String get() = descriptor.title
    val unit: String get() = descriptor.unit
    val category: String get() = descriptor.category
    val sourceLabel: String get() = descriptor.sourceLabel
    val higherIsBetter: Boolean? get() = descriptor.higherIsBetter
    val decimals: Int get() = descriptor.decimals
    val description: String? get() = descriptor.description

    private val whoopEffort: Boolean get() = key == "strain" && effortScale == EffortScale.WHOOP
    val displayUnit: String get() = if (whoopEffort) "/21" else unit

    fun format(v: Double): String {
        if (!v.isFinite()) return ","
        if (key == "fitness_age") return FitnessAgePresentation.value(v)
        val shown = if (whoopEffort) UnitFormatter.effortValue(v, EffortScale.WHOOP) else v
        val n = if (decimals == 0) "${shown.roundToInt()}" else String.format(Locale.US, "%.${decimals}f", shown)
        return if (displayUnit.isEmpty()) n else "$n $displayUnit"
    }
}

private fun MetricHistoryDescriptor.toMetricSpec(): MetricSpec {
    val accent = when {
        key in setOf("avg_hr", "max_hr", "walking_hr", "rhr", "resting_hr") -> Palette.metricRose
        key == "hrv" -> Palette.metricPurple
        key == "spo2" -> Palette.metricCyan
        key.contains("kcal") || key == "skin_temp" || key.contains("temp") -> Palette.metricAmber
        category == "Effort" -> Palette.strain066
        category == "Heart" -> Palette.chargeColor
        else -> Palette.accent
    }
    return MetricSpec(this, accent)
}

// MARK: - Loaded series and calendar windows

internal data class SeriesPoint(val day: String, val value: Double)

internal fun calendarDayWindow(
    points: List<SeriesPoint>,
    days: Int?,
): List<SeriesPoint> {
    val dated = points.mapNotNull { point ->
        val day = runCatching { LocalDate.parse(point.day) }.getOrNull() ?: return@mapNotNull null
        point.takeIf { it.value.isFinite() }?.let { day to it }
    }.sortedBy { it.first }
    if (days == null) return dated.map { it.second }
    if (days <= 0 || dated.isEmpty()) return emptyList()
    val latest = dated.last().first
    val cutoff = latest.minusDays((days - 1).toLong())
    return dated.filter { (day, _) -> !day.isBefore(cutoff) && !day.isAfter(latest) }
        .map { it.second }
}

private fun List<SeriesPoint>.windowFor(range: ExploreRange): List<SeriesPoint> =
    calendarDayWindow(this, range.days)

internal fun metricHistoryPhysicalSources(logicalSource: String, activeStrapId: String): List<String> =
    when (logicalSource) {
        AndroidMetricHistoryCatalog.DIRECT_SOURCE ->
            WhoopRepository.importedSourceIdsFor(activeStrapId)
        AndroidMetricHistoryCatalog.NOOP_SOURCE ->
            WhoopRepository.computedSourceIdsFor(activeStrapId)
        else -> listOf(logicalSource)
    }

private fun dailyMetricHistoryValue(key: String, row: DailyMetric): Double? = when (key) {
    "recovery" -> row.recovery
    "hrv" -> row.avgHrv
    "rhr", "resting_hr" -> row.restingHr?.toDouble()
    "strain" -> row.strain
    "resp_rate" -> row.respRateBpm
    "spo2" -> row.spo2Pct
    "skin_temp" -> row.skinTempDevC
    "sleep_total_min", "asleep_min" -> row.totalSleepMin
    "sleep_efficiency" -> row.efficiency
    "sleep_deep_min", "deep_min" -> row.deepMin
    "sleep_rem_min", "rem_min" -> row.remMin
    "sleep_light_min", "core_min" -> row.lightMin
    "energy_kcal" -> row.activeKcalEst
    "steps" -> row.steps?.toDouble()
    else -> null
}

private fun appleDailyMetricHistoryValue(key: String, row: com.noop.data.AppleDaily): Double? = when (key) {
    "steps" -> row.steps?.toDouble()
    "active_kcal" -> row.activeKcal
    "basal_kcal" -> row.basalKcal
    "vo2max" -> row.vo2max
    "avg_hr" -> row.avgHr?.toDouble()
    "max_hr" -> row.maxHr?.toDouble()
    "walking_hr" -> row.walkingHr?.toDouble()
    "weight" -> row.weightKg
    else -> null
}

internal suspend fun loadMetricHistorySeries(
    repo: WhoopRepository,
    metric: MetricHistoryDescriptor,
    activeStrapId: String,
    from: String = "0000-00-00",
    to: String = "9999-99-99",
): List<Pair<String, Double>> {
    val merged = LinkedHashMap<String, Double>()
    for (source in metricHistoryPhysicalSources(metric.source, activeStrapId)) {
        val sourceRows = LinkedHashMap<String, Double>()
        for (row in repo.metricSeries(source, metric.key, from, to)) {
            if (row.value.isFinite()) sourceRows[row.day] = row.value
        }
        for (row in repo.daysInRange(source, from, to)) {
            dailyMetricHistoryValue(metric.key, row)
                ?.takeIf(Double::isFinite)
                ?.let { sourceRows.putIfAbsent(row.day, it) }
        }
        if (source == WhoopRepository.APPLE_HEALTH_SOURCE ||
            source == WhoopRepository.HEALTH_CONNECT_SOURCE
        ) {
            for (row in repo.appleDaily(source, from, to)) {
                appleDailyMetricHistoryValue(metric.key, row)
                    ?.takeIf(Double::isFinite)
                    ?.let { sourceRows.putIfAbsent(row.day, it) }
            }
        }
        for ((day, value) in sourceRows) merged.putIfAbsent(day, value)
    }
    return merged.entries.sortedBy { it.key }.map { it.key to it.value }
}

// MARK: - Summary stats over a window

private data class Stat(val n: Int, val mean: Double, val min: Double, val max: Double)

private fun statOf(values: List<Double>): Stat {
    val v = values.filter { it.isFinite() }
    if (v.isEmpty()) return Stat(0, Double.NaN, Double.NaN, Double.NaN)
    return Stat(v.size, v.sum() / v.size, v.min(), v.max())
}

// MARK: - Screen

@Composable
fun TrendsExploreScreen(vm: AppViewModel) {
    // The Deep Timeline (#575) is presented INLINE from Explore , no NavHost route needed, so this stays
    // self-contained in the Explore entry-point file. System back / the in-screen reset returns here.
    var showDeepTimeline by remember { mutableStateOf(false) }
    if (showDeepTimeline) {
        FullDayChartScreen(vm = vm, onBack = { showDeepTimeline = false })
        return
    }

    // The registry's ACTIVE strap id (SPINE / #814): the daysMerged / metricKeys reads resolve the
    // active-id ∪ canonical "my-whoop" union, so a re-added strap's data and the canonical import both
    // surface. A single-WHOOP install resolves this to "my-whoop", so the reads are byte-identical there.
    val deviceId = vm.activeStrapId
    val recentDays by vm.recentDays.collectAsStateWithLifecycle()
    val ageMetricDataVersion by vm.ageMetricDataVersion.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val profile = remember(context) { ProfileStore.from(context) }
    val profileVersion by ProfileStore.ageMetricProfileChanges.collectAsStateWithLifecycle()
    val canPresentBmi = remember(profileVersion) {
        BodyProfilePolicy.canPresentAdultBmi(
            age = profile.age,
            currentWeightKg = profile.weightKg,
            heightCm = profile.heightCm,
            ageConfirmed = profile.ageInputConfirmed,
            heightConfirmed = profile.heightInputConfirmed,
            currentWeightConfirmed = profile.weightInputConfirmed,
        )
    }

    val metrics = remember(canPresentBmi) {
        AndroidMetricHistoryCatalog.visible(canPresentBmi).map { it.toMetricSpec() }
    }

    // Effort display scale (#268) , carried on the selected spec so the Effort column's value + unit
    // follow the toggle through every read-out (hero, footer stats, Y-axis). Display-only.
    val effortScale = UnitPrefs.effortScale(LocalContext.current)

    val defaultMetricId = "${AndroidMetricHistoryCatalog.DIRECT_SOURCE}:recovery"
    var selectedId by remember { mutableStateOf(defaultMetricId) }
    LaunchedEffect(canPresentBmi) {
        if (!canPresentBmi && metrics.firstOrNull { it.id == selectedId }?.key == "bmi") {
            selectedId = defaultMetricId
        }
    }
    var range by remember { mutableStateOf(ExploreRange.Month) }
    val selected = (metrics.firstOrNull { it.id == selectedId } ?: metrics.first())
        .copy(effortScale = effortScale)

    // Load only the selected source partition. `recentDays` is a recomposition generation signal;
    // the actual read below is uncapped full history and never merges another provider.
    var seriesIdLoaded by remember { mutableStateOf<String?>(null) }
    var loadedSeries by remember { mutableStateOf<List<SeriesPoint>>(emptyList()) }
    LaunchedEffect(selected.id, recentDays, ageMetricDataVersion, deviceId) {
        loadedSeries = runCatching {
            loadMetricHistorySeries(vm.repo, selected.descriptor, deviceId)
                .map { (day, value) -> SeriesPoint(day, value) }
        }.getOrDefault(emptyList())
        seriesIdLoaded = selected.id
    }

    // Resolve the active window with the macOS sparse-widen rule.
    val series = if (seriesIdLoaded == selected.id) loadedSeries else emptyList()
    val effectiveRange = remember(series, range) {
        if (series.isEmpty()) range
        else range.widening.firstOrNull { series.windowFor(it).isNotEmpty() } ?: ExploreRange.All
    }
    val windowed = remember(series, effectiveRange) { series.windowFor(effectiveRange) }
    val fellBack = effectiveRange != range

    // PERF (#707): lazy scaffold so only the on-screen rows (the hero chart card especially) compose +
    // are accessibility-walked on scroll. Each top-level child is one `item { }` in the same order; the
    // conditional empty-state note uses `if (cond) { item {} }` so it adds no row when hidden. No standalone
    // Spacers here , the LazyColumn's `spacedBy(20.dp)` reproduces the eager column's row spacing exactly.
    LazyScreenScaffold(title = stringResource(R.string.nav_explore), subtitle = stringResource(R.string.explore_subtitle)) {

        // The headline tap-through (#575): a full-day, full-resolution, zoomable timeline. Sits above the
        // per-metric catalog because it's a different kind of view , every second of one day, not one
        // number per day. Mirrors the macOS MetricExplorerView "Deep Timeline" hero row.
        item { DeepTimelineEntry(onClick = { showDeepTimeline = true }) }

        // Nothing to explore until history is imported , lead with the verbatim note so
        // the empty picker/chart below is explained.
        if (series.isEmpty()) {
            item {
            DataPendingNote(
                title = stringResource(R.string.explore_import_title),
                body = stringResource(R.string.explore_import_body),
            )
            }
        }

        // METRIC PICKER , a dropdown replacing the old horizontal chip row.
        item {
        MetricDropdown(
            metrics = metrics,
            selected = selected,
            onSelect = { selectedId = it },
        )
        }

        // RANGE BAR , overline + title + the one segmented window control, with a caption
        // that flags a sparse auto-widen.
        item {
        Row(verticalAlignment = Alignment.Top) {
            Column(modifier = Modifier.weight(1f)) {
                Overline("${selected.category} · ${selected.sourceLabel}")
                Text(selected.title, style = NoopType.title2, color = Palette.textPrimary)
                // The plain-English one-liner for the three headline scores (Charge/Effort/Rest);
                // null for every other metric, so only the scores show a subtitle here.
                selected.description?.let { blurb ->
                    Text(
                        blurb,
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                        modifier = Modifier.padding(top = Metrics.space2),
                    )
                }
            }
            SegmentedPillControl(
                items = ExploreRange.entries.toList(),
                selection = range,
                label = { it.label },
                onSelect = { range = it },
            )
        }
        }
        item {
        Text(
            text = rangeCaption(series, windowed, range, effectiveRange, fellBack),
            style = NoopType.footnote,
            color = if (fellBack) Palette.statusWarning else Palette.textTertiary,
        )
        }

        // HERO CHART , line over the window + latest "as of" read-out in the card.
        item {
        HeroChartCard(
            metric = selected,
            windowed = windowed,
            latest = series.lastOrNull(),
            effectiveRange = effectiveRange,
            range = range,
            fellBack = fellBack,
        )
        }

        // STAT ROW , Average / Min / Max / Latest / Δ vs previous window.
        item {
        StatRow(
            metric = selected,
            series = series,
            windowed = windowed,
            effectiveRange = effectiveRange,
        )
        }

        item {
            MetricEducationCard(metric = selected)
        }
    }
}

// MARK: - Deep Timeline entry (#575)

/** The hero entry that opens the Deep Timeline , a full-bleed card above the per-metric catalog. */
@Composable
private fun DeepTimelineEntry(onClick: () -> Unit) {
    NoopCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(42.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(Palette.metricRose.copy(alpha = StrandAlpha.chartFillStrong)),
                contentAlignment = Alignment.Center,
            ) {
                Text("∿", style = NoopType.title2, color = Palette.metricRose)
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.deep_timeline_title), style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    stringResource(R.string.explore_deep_timeline_hint),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = Palette.textTertiary,
            )
        }
    }
}

// MARK: - Metric picker dropdown

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MetricDropdown(
    metrics: List<MetricSpec>,
    selected: MetricSpec,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val grouped = remember(metrics) { metrics.groupBy { it.category } }
    val shape = RoundedCornerShape(Metrics.cornerSm)

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor()
                .clip(shape)
                .background(Palette.surfaceInset)
                .border(Metrics.divider, Palette.accent.copy(alpha = StrandAlpha.selectedBorder), shape)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(modifier = Modifier.size(10.dp).clip(CircleShape).background(selected.accent))
            Column(modifier = Modifier.weight(1f)) {
                Overline("${selected.category} · ${selected.sourceLabel}", color = Palette.textTertiary)
                Text(selected.title, style = NoopType.headline, color = Palette.textPrimary)
            }
            Icon(
                if (expanded) Icons.Filled.ArrowDropUp else Icons.Filled.ArrowDropDown,
                contentDescription = stringResource(R.string.explore_pick_metric),
                tint = if (expanded) Palette.accent else Palette.textSecondary,
            )
        }

        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier
                .background(Palette.surfaceRaised)
                .border(Metrics.divider, Palette.hairline, shape),
        ) {
            grouped.entries.forEachIndexed { groupIdx, (category, items) ->
                if (groupIdx > 0) {
                    HorizontalDivider(
                        color = Palette.hairline,
                        modifier = Modifier.padding(vertical = 4.dp),
                    )
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Palette.surfaceRaised)
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(Palette.accent))
                    Overline(category, color = Palette.accent)
                }
                items.forEach { metric ->
                    val isSelected = metric.id == selected.id
                    DropdownMenuItem(
                        text = {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Box(modifier = Modifier.size(8.dp).clip(CircleShape).background(metric.accent))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        metric.title,
                                        style = NoopType.body,
                                        color = if (isSelected) Palette.accent else Palette.textPrimary,
                                    )
                                    Text(
                                        metric.sourceLabel,
                                        style = NoopType.footnote,
                                        color = Palette.textTertiary,
                                    )
                                }
                                if (isSelected) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = Palette.accent,
                                        modifier = Modifier.size(16.dp),
                                    )
                                }
                            }
                        },
                        onClick = { onSelect(metric.id); expanded = false },
                        modifier = if (isSelected) {
                            Modifier.background(Palette.accent.copy(alpha = StrandAlpha.selectedFill))
                        } else Modifier,
                    )
                }
            }
        }
    }
}

// MARK: - Hero chart card

@Composable
private fun HeroChartCard(
    metric: MetricSpec,
    windowed: List<SeriesPoint>,
    latest: SeriesPoint?,
    effectiveRange: ExploreRange,
    range: ExploreRange,
    fellBack: Boolean,
) {
    val heroValue = latest?.let { metric.format(it.value) } ?: ","
    val asOf = latest?.let { "as of ${it.day}" } ?: "no readings yet"
    // The range bar above already prints the authoritative reading-count caption; the hero only
    // names its window so the count isn't doubled in one card height.
    val subtitle = if (fellBack) {
        "Trailing ${effectiveRange.windowName}"
    } else {
        "Trailing ${range.windowName}"
    }
    // Wash the hero card in the metric's domain world (Charge green / Effort amber / Rest indigo).
    NoopCard(tint = domainTint(metric.category)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Row(verticalAlignment = Alignment.Top) {
                Column(modifier = Modifier.weight(1f)) {
                    Overline(metric.title)
                    Text(subtitle, style = NoopType.footnote, color = Palette.textTertiary)
                }
                Column(horizontalAlignment = Alignment.End) {
                    Text(heroValue, style = NoopType.number(20f), color = metric.accent)
                    Text(asOf, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }

            if (windowed.size >= 2) {
                // Chart flanked by a max/avg/min Y-axis column and a first/mid/last date X-axis row,
                // so the line reads against real numbers and dates rather than a bare curve. The
                // Y-labels reuse the metric's own formatter but drop the unit suffix to keep the
                // narrow left gutter compact.
                val values = windowed.map { it.value }
                val maxV = values.max()
                val avgV = values.average()
                val minV = values.min()
                val fmtY: (Double) -> String = { v -> metric.format(v).substringBefore(' ').take(7) }
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Row(
                        modifier = Modifier.height(IntrinsicSize.Min),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Column(
                            modifier = Modifier.height(Metrics.chartHeight),
                            verticalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(fmtY(maxV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                            Text(fmtY(avgV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                            Text(fmtY(minV), style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
                        }
                        // The shared LineChart with a glowing "now" end-cap on its latest sample ,
                        // the Bevel idiom from Today's OverviewHRChart.
                        Box(modifier = Modifier.weight(1f).height(Metrics.chartHeight)) {
                            LineChart(
                                values = values,
                                modifier = Modifier.fillMaxSize(),
                                color = metric.accent,
                                fill = true,
                                selectionEnabled = true,
                                selectionLabels = windowed.map { prettyExploreDate(it.day) },
                            )
                            ExploreGlowEndCap(values = values, tipColor = metric.accent)
                        }
                    }
                    val days = windowed.map { it.day }
                    Row(modifier = Modifier.fillMaxWidth()) {
                        listOf(days.first(), days.getOrNull(days.lastIndex / 2), days.last()).forEach { d ->
                            Text(
                                prettyExploreDate(d),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                                modifier = Modifier.weight(1f),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(Metrics.chartHeight),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        if (windowed.isEmpty()) {
                            stringResource(R.string.explore_empty_metric, metric.title.lowercase())
                        } else {
                            stringResource(R.string.explore_single_reading)
                        },
                        style = NoopType.subhead,
                        color = Palette.textTertiary,
                    )
                }
            }

            // Footer chips, mirroring the macOS ChartFooter (Window / Points / Latest).
            Row(horizontalArrangement = Arrangement.spacedBy(Metrics.sectionGap)) {
                ChartFootItem(stringResource(R.string.explore_chart_window), effectiveRange.label)
                ChartFootItem(stringResource(R.string.explore_chart_points), "${windowed.size}")
                ChartFootItem(stringResource(R.string.explore_latest), heroValue)
            }
        }
    }
}

/** ISO "yyyy-MM-dd" to the same compact date used by both the axis and selection label. */
private fun prettyExploreDate(day: String?): String =
    day?.let {
        runCatching { LocalDate.parse(it).format(DateTimeFormatter.ofPattern("d MMM", Locale.US)) }
            .getOrDefault(it)
    }.orEmpty()

@Composable
private fun ChartFootItem(label: String, value: String) {
    Column {
        Overline(label, color = Palette.textTertiary)
        Text(value, style = NoopType.captionNumber, color = Palette.textSecondary)
    }
}

/** The metric category's domain colour world for the card wash; brand green for neutral categories. */
private fun domainTint(category: String): Color = when (category) {
    uiString(R.string.explore_category_charge) -> Palette.chargeColor
    uiString(R.string.explore_category_effort) -> Palette.effortColor
    uiString(R.string.explore_category_rest) -> Palette.restColor
    else -> Palette.accent
}

/**
 * A glowing "now" end-cap on a LineChart's latest sample (soft halo + bright core + white centre),
 * matching Today's OverviewHRChart. Reproduces LineChart's own point geometry so the dot sits on the
 * curve's final point. Drawn as a sibling overlay , the shared LineChart stays untouched.
 */
@Composable
private fun ExploreGlowEndCap(values: List<Double>, tipColor: Color) {
    val clean = remember(values) { values.filter { it.isFinite() } }
    if (clean.size < 2) return
    Canvas(modifier = Modifier.fillMaxSize()) {
        val strokePx = 2.5f
        val topPad = strokePx + 4f
        val bottomPad = strokePx + 4f
        val minV = clean.min()
        val maxV = clean.max()
        val span = (maxV - minV).takeIf { it > 0.0 } ?: 1.0
        val usableH = (size.height - topPad - bottomPad).coerceAtLeast(1f)
        val norm = ((clean.last() - minV) / span).toFloat().coerceIn(0f, 1f)
        val center = Offset(size.width, topPad + (1f - norm) * usableH)
        drawCircle(color = tipColor.copy(alpha = 0.30f), radius = 9f, center = center)
        drawCircle(color = tipColor.copy(alpha = 0.65f), radius = 5.5f, center = center)
        drawCircle(color = Palette.tipCore, radius = 2.4f, center = center)
    }
}

// MARK: - Stat tile row

@Composable
private fun StatRow(
    metric: MetricSpec,
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    effectiveRange: ExploreRange,
) {
    val values = windowed.map { it.value }
    val s = statOf(values)
    val latest = series.lastOrNull()

    // Δ vs the previous equal-length window (by point count), tinted by higherIsBetter.
    val prev = remember(series, windowed) { previousWindow(series, windowed) }
    val prevStat = statOf(prev.map { it.value })
    val hasDelta = s.n > 0 && prevStat.n > 0
    val delta = if (hasDelta) s.mean - prevStat.mean else Double.NaN
    val deltaText = if (hasDelta) signed(metric, delta) else ","
    val pctChange = if (hasDelta && prevStat.mean != 0.0) {
        ((s.mean - prevStat.mean) / abs(prevStat.mean)) * 100.0
    } else null
    val deltaColor: Color = run {
        val better = metric.higherIsBetter
        if (!hasDelta || delta == 0.0 || better == null) Palette.textTertiary
        else if ((delta > 0) == better) Palette.statusPositive else Palette.statusCritical
    }
    val deltaCaption = when {
        hasDelta -> stringResource(R.string.explore_vs_prev_window, effectiveRange.windowName)
        effectiveRange == ExploreRange.All -> stringResource(R.string.explore_all_history)
        else -> stringResource(R.string.explore_no_prior_window, effectiveRange.windowName)
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        SectionHeader(stringResource(R.string.explore_summary), overline = stringResource(R.string.explore_over_visible_window), trailing = stringResource(R.string.explore_n_pts, s.n))

        // Average summarizes the selected range, so it leads at the full two-column width.
        StatTile(
            modifier = Modifier.fillMaxWidth(),
            label = stringResource(R.string.explore_average),
            value = if (s.n > 0) metric.format(s.mean) else ",",
            caption = pluralStringResource(R.plurals.explore_n_days, s.n, s.n),
            accent = metric.accent,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_min),
                value = if (s.n > 0) metric.format(s.min) else ",",
                accent = Palette.textPrimary,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_max),
                value = if (s.n > 0) metric.format(s.max) else ",",
                accent = Palette.textPrimary,
            )
        }
        // Half-width gives the comparison tile room for its value, delta chip and window caption.
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_delta_vs_prev),
                value = deltaText,
                caption = deltaCaption,
                accent = Palette.textPrimary,
                delta = pctChange?.let { "${if (it >= 0) "+" else ""}${String.format(Locale.US, "%.1f", it)}%" },
                deltaColor = deltaColor,
            )
            StatTile(
                modifier = Modifier.weight(1f),
                label = stringResource(R.string.explore_latest),
                value = latest?.let { metric.format(it.value) } ?: ",",
                caption = latest?.day,
                accent = metric.accent,
            )
        }
    }
}

// MARK: - Metric education

/**
 * A stable explanation contract for every chartable metric. The eight built-in health metrics use
 * metric-specific copy; a newly discovered long-format series gets an explicit generic fallback so the
 * UI never invents a sensor method or medical interpretation.
 */
@Composable
private fun MetricEducationCard(metric: MetricSpec) {
    val education = AndroidMetricKnowledge.educationFor(metric.key)
    NoopCard(tint = domainTint(metric.category)) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space16)) {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
                Overline(stringResource(R.string.appwide_metric_education_overline), color = metric.accent)
                Text(
                    stringResource(R.string.appwide_metric_education_title),
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                )
            }

            MetricEducationBlock(
                title = stringResource(R.string.appwide_metric_education_heading_what),
                body = stringResource(education.whatItIs),
            )
            HorizontalDivider(color = Palette.hairline)
            MetricEducationBlock(
                title = stringResource(R.string.appwide_metric_education_heading_why),
                body = stringResource(education.whyItMatters),
            )
            HorizontalDivider(color = Palette.hairline)
            MetricEducationBlock(
                title = stringResource(R.string.appwide_metric_education_heading_method),
                body = stringResource(education.howMeasured),
            )
            HorizontalDivider(color = Palette.hairline)
            MetricEducationBlock(
                title = stringResource(R.string.appwide_metric_education_heading_limits),
                body = stringResource(education.limitations),
                bodyColor = Palette.textTertiary,
            )
            HorizontalDivider(color = Palette.hairline)
            MetricEducationBlock(
                title = stringResource(R.string.appwide_metric_education_heading_action),
                body = stringResource(education.whatYouCanTry),
            )

            Text(
                stringResource(R.string.appwide_metric_education_safety_boundary),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun MetricEducationBlock(
    title: String,
    body: String,
    bodyColor: Color = Palette.textSecondary,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
        Overline(title)
        Text(body, style = NoopType.subhead, color = bodyColor)
    }
}

// MARK: - Window / formatting helpers

/** The window immediately preceding [windowed] (equal length, by point count). */
private fun previousWindow(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
): List<SeriesPoint> {
    val size = windowed.size
    if (size == 0 || series.size <= size) return emptyList()
    val firstDay = windowed.firstOrNull()?.day ?: return emptyList()
    val lo = series.indexOfFirst { it.day == firstDay }
    if (lo <= 0) return emptyList()
    val prevLo = (lo - size).coerceAtLeast(0)
    return series.subList(prevLo, lo)
}

private fun signed(metric: MetricSpec, delta: Double): String {
    val sign = if (delta >= 0) "+" else "−"
    return sign + metric.format(abs(delta))
}

private fun rangeCaption(
    series: List<SeriesPoint>,
    windowed: List<SeriesPoint>,
    range: ExploreRange,
    effectiveRange: ExploreRange,
    fellBack: Boolean,
): String {
    if (series.isEmpty()) return ","
    val n = windowed.size
    val unit = if (n == 1) "reading" else "readings"
    return if (fellBack) "$n $unit · sparse , widened to ${effectiveRange.windowName}"
    else "$n $unit · ${range.windowName}"
}
