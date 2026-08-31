package com.noop.ui

import com.noop.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.analytics.BalanceRead
import com.noop.analytics.RestScorer
import com.noop.analytics.WeeklyDigest
import com.noop.analytics.WeeklyDigestEngine
import com.noop.analytics.WeeklyMetric
import com.noop.analytics.WeeklyMetricSummary
import com.noop.data.DailyMetric
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - Weekly Digest (#208)
//
// A deterministic, offline "week in review". Kotlin parity for the macOS/iOS
// WeeklyDigestView. Reads the merged daily history from the view model, pulls each
// tracked metric into a "yyyy-MM-dd"→value map, and feeds the pure
// WeeklyDigestEngine to produce a Monday-anchored summary: per-metric this-week
// mean + week-over-week delta + vs-baseline, the biggest movers, a strain-vs-recovery
// balance read, and 1–2 plain-English focal points. No AI, no network.
//
// Two surfaces are exposed so navigation can wire whichever it wants:
//   • WeeklyDigestCard  — an embeddable card (drop into Today / Trends).
//   • WeeklyDigestScreen — a full ScreenScaffold screen (for a nav destination).
// Both share WeeklyDigestContent so they never drift. Framing is informational
// (non-clinical), consistent with the app disclaimer.

/**
 * The engine's Effort display factor for the user's scale (#268/#463): moverSentence's
 * "(avg X vs Y)" prints stored 0-100 Effort means, so the 0-21 toggle rescales them for
 * display only. 1.0 leaves every sentence byte-identical to the pre-toggle output.
 */
internal fun effortDisplayFactor(scale: EffortScale): Double =
    if (scale == EffortScale.WHOOP) UnitFormatter.EFFORT_SCALE_FACTOR else 1.0

/**
 * Build the weekly digest for the week containing today's logical local day from a
 * [DailyMetric] history. Extracts each metric into a day→value map and hands it to the
 * pure engine. [effortDisplayFactor] follows the Effort display-scale toggle so the
 * engine's focal sentences quote Effort on the scale the user reads everywhere else.
 */
fun buildWeeklyDigest(
    days: List<DailyMetric>,
    anchorDay: String = logicalDayKeyNow(),
    effortDisplayFactor: Double = 1.0,
): WeeklyDigest {
    val charge = HashMap<String, Double>()
    val effort = HashMap<String, Double>()
    val rest = HashMap<String, Double>()
    val rhr = HashMap<String, Double>()
    val hrv = HashMap<String, Double>()
    for (d in days) {
        d.recovery?.let { charge[d.day] = it }
        d.strain?.let { effort[d.day] = it }
        // Rest = the sleep-performance composite recomputed on the persisted day.
        RestScorer.restFromDaily(d)?.let { rest[d.day] = it }
        d.restingHr?.let { rhr[d.day] = it.toDouble() }
        d.avgHrv?.let { hrv[d.day] = it }
    }
    return WeeklyDigestEngine.build(
        byMetric = mapOf(
            WeeklyMetric.CHARGE to charge,
            WeeklyMetric.EFFORT to effort,
            WeeklyMetric.REST to rest,
            WeeklyMetric.RHR to rhr,
            WeeklyMetric.HRV to hrv,
        ),
        anchorDay = anchorDay,
        effortDisplayFactor = effortDisplayFactor,
    )
}

// MARK: - Embeddable card

/**
 * The weekly digest as a single card (for Today / Trends). Renders nothing when there's
 * no data this week, so it's safe to always place.
 */
@Composable
fun WeeklyDigestCard(vm: AppViewModel, modifier: Modifier = Modifier) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val factor = effortDisplayFactor(UnitPrefs.effortScale(LocalContext.current))
    val digest = buildWeeklyDigest(days, effortDisplayFactor = factor)
    if (digest.isEmpty) return
    Box(modifier = modifier) {
        WeeklyDigestContent(digest = digest, compact = true)
    }
}

// MARK: - Full screen

/** The weekly digest as a full screen (for a nav destination). */
@Composable
fun WeeklyDigestScreen(vm: AppViewModel) {
    val days by vm.recentDays.collectAsStateWithLifecycle()
    val factor = effortDisplayFactor(UnitPrefs.effortScale(LocalContext.current))
    ScreenScaffold(title = uiString(R.string.l10n_weekly_digest_card_week_in_review_66d95a07), subtitle = "Your Monday-to-Sunday, read in one glance.") {
        val digest = buildWeeklyDigest(days, effortDisplayFactor = factor)
        if (digest.isEmpty) {
            DataPendingNote(
                title = uiString(R.string.l10n_weekly_digest_card_no_readings_this_week_yet_0745a2df),
                body = "Wear your strap or import a wearable export in Data Sources. Once this week has a " +
                    "day or two of data, your week-in-review appears here.",
            )
        } else {
            WeeklyDigestContent(digest = digest, compact = false)
        }
    }
}

// MARK: - Shared content

private val MONTHS = arrayOf(
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)

private val DISPLAY_ORDER = listOf(
    WeeklyMetric.CHARGE, WeeklyMetric.EFFORT, WeeklyMetric.REST, WeeklyMetric.HRV, WeeklyMetric.RHR,
)
private val SCORE_ORDER = listOf(WeeklyMetric.CHARGE, WeeklyMetric.EFFORT, WeeklyMetric.REST)

private data class DigestDomain(
    val color: Color,
    val bright: Color,
)

private fun digestDomain(metric: WeeklyMetric): DigestDomain = when (metric) {
    WeeklyMetric.CHARGE -> DigestDomain(Palette.chargeColor, Palette.chargeBright)
    WeeklyMetric.EFFORT -> DigestDomain(Palette.effortColor, Palette.effortBright)
    WeeklyMetric.REST -> DigestDomain(Palette.restColor, Palette.restBright)
    WeeklyMetric.HRV -> DigestDomain(Palette.metricPurple, Palette.restBright)
    WeeklyMetric.RHR -> DigestDomain(Palette.metricRose, Palette.metricAmber)
}

/**
 * The inner content shared by the card and the full screen. [compact] trims the metric
 * grid to the headline rows for the card; the full screen shows everything plus a footer.
 */
@Composable
fun WeeklyDigestContent(digest: WeeklyDigest, compact: Boolean = false) {
    val effortScale = UnitPrefs.effortScale(LocalContext.current)
    val scoreSummaries = SCORE_ORDER.mapNotNull(digest::summary)
    val secondarySignals = if (compact) {
        emptyList()
    } else {
        listOf(WeeklyMetric.HRV, WeeklyMetric.RHR).mapNotNull(digest::summary)
    }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        DigestHeader(digest)
        if (scoreSummaries.isNotEmpty()) {
            DigestScoreRow(scoreSummaries, effortScale)
        }
        if (digest.focalPoints.isNotEmpty() || secondarySignals.isNotEmpty() || !compact) {
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (digest.focalPoints.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                            digest.focalPoints.forEach { FocalRow(it) }
                        }
                    }
                    if (secondarySignals.isNotEmpty()) {
                        if (digest.focalPoints.isNotEmpty()) {
                            HorizontalDivider(color = Palette.hairline)
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
                            secondarySignals.forEach { MetricRow(it, effortScale) }
                        }
                    }
                    if (!compact) {
                        HorizontalDivider(color = Palette.hairline)
                        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space6)) {
                            digest.sleepConsistencySD?.let { sd ->
                                Text(
                                    uiString(
                                        R.string.l10n_weekly_digest_card_sleep_steadiness_rest_varied_fmt1_sd_44997f21,
                                        fmt1(sd),
                                    ),
                                    style = NoopType.footnote,
                                    color = Palette.textTertiary,
                                )
                            }
                            Text(
                                digest.balance.sentence,
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                            Text(
                                uiString(R.string.l10n_weekly_digest_card_informational_only_not_medical_advice_593feb77),
                                style = NoopType.footnote,
                                color = Palette.textTertiary,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DigestHeader(digest: WeeklyDigest) {
    NoopCard(padding = 0.dp, tint = Palette.chargeColor) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(104.dp)
                .sceneHeroBackground(maxAlpha = 0.26f, fadeEndFraction = 0.96f)
                .padding(Metrics.cardPadding),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Metrics.space2),
            ) {
                Overline("Week in review")
                Text(
                    weekRangeLabel(digest),
                    style = NoopType.title1,
                    color = Palette.textPrimary,
                )
            }
            Text(
                uiString(
                    R.string.l10n_weekly_digest_card_digest_dayswithdata_7_days_182e6a18,
                    digest.daysWithData,
                ),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.semantics {
                    contentDescription = uiString(
                        R.string.l10n_weekly_digest_card_digest_dayswithdata_of_7_days_had_8068f0ee,
                        digest.daysWithData,
                    )
                },
            )
        }
    }
}

@Composable
private fun DigestScoreRow(
    summaries: List<WeeklyMetricSummary>,
    effortScale: EffortScale,
) {
    NoopCard(padding = Metrics.space8) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
        ) {
            summaries.forEachIndexed { index, summary ->
                DigestScoreColumn(
                    summary = summary,
                    effortScale = effortScale,
                    modifier = Modifier.weight(1f),
                )
                if (index < summaries.lastIndex) {
                    Box(
                        Modifier
                            .padding(vertical = Metrics.space12)
                            .width(1.dp)
                            .height(128.dp)
                            .background(Palette.hairline),
                    )
                }
            }
        }
    }
}

@Composable
private fun DigestScoreColumn(
    summary: WeeklyMetricSummary,
    effortScale: EffortScale,
    modifier: Modifier = Modifier,
) {
    val domain = digestDomain(summary.metric)
    val hasValue = summary.thisWeek.n > 0
    val value = summary.thisWeek.mean.coerceIn(0.0, 100.0)
    val number = when {
        !hasValue -> null
        summary.metric == WeeklyMetric.EFFORT ->
            UnitFormatter.effortDisplay(summary.thisWeek.mean, effortScale)
        else -> summary.thisWeek.mean.roundToInt().toString()
    }
    val denominator = if (summary.metric == WeeklyMetric.EFFORT) {
        UnitFormatter.effortScaleMax(effortScale)
    } else {
        100
    }

    Column(
        modifier = modifier
            .semantics(mergeDescendants = true) {
                contentDescription = rowAccessibility(summary, effortScale)
            }
            .padding(horizontal = Metrics.space4),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space6),
    ) {
        Text(
            summary.metric.label.uppercase(),
            style = NoopType.overline,
            color = domain.color,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
        DigestGauge(
            fraction = if (hasValue) value / 100.0 else 0.0,
            color = domain.color,
            tipColor = domain.bright,
            number = number,
        )
        if (hasValue) {
            Text(
                stringResource(R.string.weekly_digest_of_value, denominator),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                maxLines = 1,
            )
        }
        if (hasComparison(summary)) {
            DeltaChip(summary)
        }
    }
}

@Composable
private fun DigestGauge(
    fraction: Double,
    color: Color,
    tipColor: Color,
    number: String?,
) {
    val startAngle = 140f
    val totalSweep = 260f
    val safeFraction = fraction.coerceIn(0.0, 1.0).toFloat()
    Box(
        modifier = Modifier.size(82.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 10.dp.toPx()
            val radius = (size.minDimension - stroke) / 2f
            val topLeft = Offset(center.x - radius, center.y - radius)
            val arcSize = androidx.compose.ui.geometry.Size(radius * 2f, radius * 2f)
            drawArc(
                color = Palette.surfaceInset,
                startAngle = startAngle,
                sweepAngle = totalSweep,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = stroke, cap = StrokeCap.Round),
            )
            if (safeFraction > 0f) {
                val sweep = totalSweep * safeFraction
                drawArc(
                    color = color,
                    startAngle = startAngle,
                    sweepAngle = sweep,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
                val radians = Math.toRadians((startAngle + sweep).toDouble())
                drawCircle(
                    color = tipColor,
                    radius = 3.2.dp.toPx(),
                    center = Offset(
                        x = center.x + kotlin.math.cos(radians).toFloat() * radius,
                        y = center.y + kotlin.math.sin(radians).toFloat() * radius,
                    ),
                )
            }
            drawCircle(
                color = Palette.hairline,
                radius = radius - stroke * 0.72f,
                style = Stroke(width = 1.dp.toPx()),
            )
        }
        if (number != null) {
            Text(
                number,
                style = NoopType.number(22f),
                color = Palette.textPrimary,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun FocalRow(line: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Top,
        modifier = Modifier.semantics(mergeDescendants = true) { contentDescription = line },
    ) {
        Icon(
            Icons.Filled.AutoAwesome,
            contentDescription = null,
            tint = Palette.accent,
            modifier = Modifier.size(16.dp),
        )
        Text(
            line,
            style = NoopType.subhead,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun MetricRow(s: WeeklyMetricSummary, effortScale: EffortScale) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .semantics(mergeDescendants = true) { contentDescription = rowAccessibility(s, effortScale) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(7.dp)
                .background(digestDomain(s.metric).color, RoundedCornerShape(50)),
        )
        Text(
            s.metric.label,
            style = NoopType.subhead,
            color = Palette.textSecondary,
            modifier = Modifier.width(84.dp),
        )
        Text(
            meanText(s, effortScale),
            style = NoopType.bodyNumber,
            color = Palette.textPrimary,
            // 84 (was 64) so the Effort scale read-out ("21.6 / 100") fits on one line.
            modifier = Modifier.width(84.dp),
        )
        Spacer(Modifier.weight(1f))
        DeltaChip(s)
    }
}

@Composable
private fun DeltaChip(s: WeeklyMetricSummary) {
    val tone = chipTone(s)
    val arrow: ImageVector = when {
        s.wowDelta > 0 -> Icons.Filled.ArrowUpward
        s.wowDelta < 0 -> Icons.Filled.ArrowDownward
        else -> Icons.Filled.Remove
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .background(tone.copy(alpha = 0.12f), RoundedCornerShape(Metrics.cornerPill))
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .clearAndSetSemantics { },
    ) {
        Icon(arrow, contentDescription = null, tint = tone, modifier = Modifier.size(10.dp))
        val sign = when {
            !hasComparison(s) -> ""
            s.wowDelta > 0 -> "+"
            s.wowDelta < 0 -> "−"
            else -> ""
        }
        Text(
            stringResource(R.string.weekly_digest_signed_delta, sign, deltaText(s)),
            style = NoopType.captionNumber,
            color = tone,
        )
    }
}

private fun hasComparison(s: WeeklyMetricSummary): Boolean =
    s.weekOverWeek.current.n > 0 && s.weekOverWeek.previous.n > 0

// MARK: - Formatting

private fun weekRangeLabel(digest: WeeklyDigest): String {
    val start = WeeklyDigestEngine.parseYMD(digest.weekStart)
    val end = WeeklyDigestEngine.parseYMD(digest.weekEnd)
    if (start == null || end == null) {
        return "${shortDate(digest.weekStart)}–${shortDate(digest.weekEnd)}"
    }
    if (start[1] == end[1]) {
        return "${shortMonth(start[1])} ${start[2]}–${end[2]}"
    }
    return "${shortDate(digest.weekStart)}–${shortDate(digest.weekEnd)}"
}

/** "Jun 8" from "2026-06-08", via the engine's own pure parse (no Calendar). */
private fun shortDate(ymd: String): String {
    val p = WeeklyDigestEngine.parseYMD(ymd) ?: return ymd
    return "${shortMonth(p[1])} ${p[2]}"
}

private fun shortMonth(month: Int): String =
    if (month in 1..12) MONTHS[month - 1] else month.toString()

internal fun meanText(s: WeeklyMetricSummary, effortScale: EffortScale): String {
    if (s.thisWeek.n == 0) return "-"
    // #463: Effort is STORED 0-100; render it on the user's chosen display scale WITH the denominator
    // ("4.6 / 21", "21.6 / 100") so the card can't read as a different number than the Trends chart.
    if (s.metric == WeeklyMetric.EFFORT) {
        return "${UnitFormatter.effortDisplay(s.thisWeek.mean, effortScale)} / " +
            UnitFormatter.effortScaleMax(effortScale)
    }
    val v = s.thisWeek.mean.roundToInt()
    return if (s.metric.unit.isEmpty()) "$v" else "$v ${s.metric.unit}"
}

internal fun deltaText(s: WeeklyMetricSummary): String {
    if (s.weekOverWeek.current.n == 0 || s.weekOverWeek.previous.n == 0) return "new"
    val pct = s.weekOverWeek.pctChange
    // Sub-1% (or unpercentable) moves read "<1%", matching Swift. The old fallback printed the raw
    // points delta: a bare "0.1", and for Effort a stored 0-100 figure the scale toggle never saw.
    return if (pct != null && abs(pct) >= 1) "${abs(pct).roundToInt()}%" else "<1%"
}

/**
 * Tone: good moves green, bad moves rose, flat/uncomparable grey — folding in each
 * metric's higherIsBetter (so a Resting-HR rise reads as a warning). A ROUGH comparison
 * (either side thin, engine's [WeeklyMetricSummary.isRoughComparison], the deferred half of
 * the 4.2.10 fix for #463) keeps its arrow + % but stays grey regardless of direction.
 */
private fun chipTone(s: WeeklyMetricSummary): Color = when {
    s.isRoughComparison -> Palette.textTertiary
    s.wowGoodness == 1 -> Palette.statusPositive
    s.wowGoodness == -1 -> Palette.statusCritical
    else -> Palette.textTertiary
}

private fun rowAccessibility(s: WeeklyMetricSummary, effortScale: EffortScale): String {
    val mean = meanText(s, effortScale)
    if (s.weekOverWeek.current.n == 0 || s.weekOverWeek.previous.n == 0) {
        return "${s.metric.label}: $mean this week, no comparison."
    }
    val dir = if (s.wowDelta > 0) "up" else if (s.wowDelta < 0) "down" else "unchanged"
    // A rough comparison drops the verdict framing too, so VoiceOver/TalkBack matches the neutral chip.
    val frame = when {
        s.isRoughComparison -> ""
        s.wowGoodness == 1 -> ", a good sign"
        s.wowGoodness == -1 -> ", worth a look"
        else -> ""
    }
    return "${s.metric.label}: $mean this week, $dir ${deltaText(s)} week over week$frame."
}

private fun fmt1(x: Double): String = ((x * 10).roundToInt() / 10.0).toString()
