package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.TrendingUp
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.testTag
import com.noop.R

internal enum class ReviewSamplePhase {
    ENTRY,
    DISCLOSURE,
    ACTIVE,
    CONTINUE_SETUP,
}

@Composable
internal fun ReviewSampleEntry(
    onExplore: () -> Unit,
    onContinueSetup: () -> Unit,
) {
    ReviewSamplePage {
        Spacer(Modifier.height(24.dp))
        BrandMark(size = 76.dp)
        Text(
            stringResource(R.string.review_sample_entry_title),
            style = NoopType.title1,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            stringResource(R.string.review_sample_entry_body),
            style = NoopType.body,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
        NoopCard(tint = Palette.accent) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Icon(Icons.Filled.Visibility, null, tint = Palette.accent)
                    Text(
                        stringResource(R.string.review_sample_card_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                }
                Text(
                    stringResource(R.string.review_sample_card_body),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        }
        NoopButton(
            text = stringResource(R.string.review_sample_explore),
            leadingIcon = Icons.AutoMirrored.Filled.ArrowForward,
            fullWidth = true,
            modifier = Modifier.testTag("noop.review.entry.explore"),
            onClick = onExplore,
        )
        NoopButton(
            text = stringResource(R.string.review_sample_continue_setup),
            leadingIcon = Icons.AutoMirrored.Filled.ArrowForward,
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            modifier = Modifier.testTag("noop.review.entry.continue"),
            onClick = onContinueSetup,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
internal fun ReviewSampleDisclosure(
    onBack: () -> Unit,
    onEnter: () -> Unit,
) {
    ReviewSamplePage {
        Spacer(Modifier.height(24.dp))
        Icon(
            Icons.Filled.CheckCircle,
            null,
            tint = Palette.accent,
            modifier = Modifier.size(54.dp),
        )
        Text(
            stringResource(R.string.review_sample_disclosure_title),
            style = NoopType.title1,
            color = Palette.textPrimary,
            textAlign = TextAlign.Center,
        )
        Text(
            stringResource(R.string.review_sample_disclosure_warning),
            style = NoopType.headline,
            color = Palette.statusWarningText,
            textAlign = TextAlign.Center,
        )
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                ReviewDisclosureRow(
                    Icons.Filled.Memory,
                    R.string.review_sample_in_memory_title,
                    R.string.review_sample_in_memory_body,
                )
                HorizontalDivider(color = Palette.hairline)
                ReviewDisclosureRow(
                    Icons.Filled.Block,
                    R.string.review_sample_external_title,
                    R.string.review_sample_external_body,
                )
                HorizontalDivider(color = Palette.hairline)
                ReviewDisclosureRow(
                    Icons.Filled.Shield,
                    R.string.review_sample_wellness_title,
                    R.string.review_sample_wellness_body,
                )
            }
        }
        NoopButton(
            text = stringResource(R.string.review_sample_enter),
            leadingIcon = Icons.AutoMirrored.Filled.ArrowForward,
            fullWidth = true,
            modifier = Modifier.testTag("noop.review.disclosure.enter"),
            onClick = onEnter,
        )
        NoopButton(
            text = stringResource(R.string.review_sample_back),
            leadingIcon = Icons.AutoMirrored.Filled.ArrowBack,
            kind = NoopButtonKind.Tertiary,
            fullWidth = true,
            onClick = onBack,
        )
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ReviewSamplePage(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxSize()
            .testTag("noop.review.gate"),
        color = Palette.surfaceBase,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            content = content,
        )
    }
}

@Composable
private fun ReviewDisclosureRow(
    icon: ImageVector,
    @StringRes title: Int,
    @StringRes body: Int,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, null, tint = Palette.accent, modifier = Modifier.size(24.dp))
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(stringResource(title), style = NoopType.headline, color = Palette.textPrimary)
            Text(stringResource(body), style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}

private enum class ReviewSampleTab(
    @StringRes val title: Int,
    val icon: ImageVector,
) {
    TODAY(R.string.nav_today, Icons.Filled.Home),
    TRENDS(R.string.nav_trends, Icons.AutoMirrored.Filled.TrendingUp),
    WORKOUTS(R.string.nav_workouts, Icons.Filled.FitnessCenter),
    SLEEP(R.string.nav_sleep, Icons.Filled.Bedtime),
    MORE(R.string.nav_more, Icons.Filled.MoreHoriz),
}

private data class ReviewSampleMetric(
    val id: String,
    @StringRes val title: Int,
    val value: String,
    val unit: String,
    @StringRes val summary: Int,
    val history: List<Float>,
)

private val reviewSampleMetrics = listOf(
    ReviewSampleMetric(
        "recovery",
        R.string.review_sample_recovery,
        "78",
        "%",
        R.string.review_sample_recovery_summary,
        listOf(64f, 69f, 73f, 66f, 75f, 72f, 78f),
    ),
    ReviewSampleMetric(
        "effort",
        R.string.review_sample_effort,
        "9.6",
        "",
        R.string.review_sample_effort_summary,
        listOf(6.1f, 7.4f, 8.8f, 5.9f, 10.2f, 8.4f, 9.6f),
    ),
    ReviewSampleMetric(
        "sleep",
        R.string.nav_sleep,
        "7h 42m",
        "",
        R.string.review_sample_sleep_summary,
        listOf(6.8f, 7.1f, 7.6f, 6.9f, 8f, 7.3f, 7.7f),
    ),
    ReviewSampleMetric(
        "hrv",
        R.string.review_sample_hrv,
        "64",
        "ms",
        R.string.review_sample_hrv_summary,
        listOf(57f, 60f, 63f, 59f, 66f, 62f, 64f),
    ),
    ReviewSampleMetric(
        "rhr",
        R.string.review_sample_resting_hr,
        "54",
        "bpm",
        R.string.review_sample_rhr_summary,
        listOf(57f, 56f, 54f, 55f, 53f, 54f, 54f),
    ),
    ReviewSampleMetric(
        "spo2",
        R.string.review_sample_blood_oxygen,
        "97",
        "%",
        R.string.review_sample_spo2_summary,
        listOf(97f, 96f, 97f, 98f, 97f, 97f, 97f),
    ),
)

private enum class ReviewSampleMoreDestination {
    FRIENDS,
    PRIVACY,
    DEVICES,
}

@Composable
internal fun ReviewSampleRoot(onExit: () -> Unit) {
    var selectedTab by remember { mutableStateOf(ReviewSampleTab.TODAY) }
    var metricDetail by remember { mutableStateOf<ReviewSampleMetric?>(null) }
    var moreDetail by remember { mutableStateOf<ReviewSampleMoreDestination?>(null) }

    if (metricDetail != null) {
        ReviewSampleMetricDetail(metricDetail!!, onBack = { metricDetail = null }, onExit = onExit)
        return
    }
    if (moreDetail != null) {
        ReviewSampleMoreDetail(moreDetail!!, onBack = { moreDetail = null }, onExit = onExit)
        return
    }

    Scaffold(
        modifier = Modifier
            .fillMaxSize()
            .testTag("noop.review.root"),
        containerColor = Palette.surfaceBase,
        topBar = { ReviewSampleBanner(onExit) },
        bottomBar = {
            NavigationBar(
                containerColor = Palette.surfaceRaised,
                modifier = Modifier.navigationBarsPadding(),
            ) {
                ReviewSampleTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        icon = { Icon(tab.icon, null) },
                        label = {
                            Text(
                                stringResource(tab.title),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        modifier = Modifier.testTag("noop.review.tab.${tab.name.lowercase()}"),
                    )
                }
            }
        },
    ) { inner ->
        when (selectedTab) {
            ReviewSampleTab.TODAY -> ReviewSampleToday(
                modifier = Modifier.padding(inner),
                onMetric = { metricDetail = it },
            )
            ReviewSampleTab.TRENDS -> ReviewSampleTrends(
                modifier = Modifier.padding(inner),
                onMetric = { metricDetail = it },
            )
            ReviewSampleTab.WORKOUTS -> ReviewSampleWorkouts(Modifier.padding(inner))
            ReviewSampleTab.SLEEP -> ReviewSampleSleep(Modifier.padding(inner))
            ReviewSampleTab.MORE -> ReviewSampleMore(
                modifier = Modifier.padding(inner),
                onOpen = { moreDetail = it },
                onExit = onExit,
            )
        }
    }
}

@Composable
private fun ReviewSampleBanner(onExit: () -> Unit) {
    Surface(color = Palette.surfaceRaised) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .heightIn(min = 44.dp)
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Filled.Visibility, null, tint = Palette.accent, modifier = Modifier.size(18.dp))
            Text(
                stringResource(R.string.review_sample_label),
                style = NoopType.overline,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onExit)
                    .testTag("noop.review.exit"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, stringResource(R.string.review_sample_exit))
            }
        }
    }
}

@Composable
private fun ReviewSampleToday(
    modifier: Modifier,
    onMetric: (ReviewSampleMetric) -> Unit,
) {
    ReviewSampleContent(modifier) {
        Text(
            stringResource(R.string.review_sample_good_morning),
            style = NoopType.title1,
            color = Palette.textPrimary,
        )
        Text(
            stringResource(R.string.review_sample_fictional_monday),
            style = NoopType.subhead,
            color = Palette.textSecondary,
        )
        NoopCard(tint = Palette.statusPositive) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(84.dp)
                        .clip(CircleShape)
                        .background(Palette.accentMuted),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("78", style = NoopType.display(38f), color = Palette.textPrimary)
                }
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        stringResource(R.string.review_sample_steady_capacity),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.review_sample_balanced_day),
                        style = NoopType.subhead,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
        reviewSampleMetrics.chunked(2).forEach { pair ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                pair.forEach { metric ->
                    ReviewMetricCard(
                        metric,
                        modifier = Modifier.weight(1f),
                        onClick = { onMetric(metric) },
                    )
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.review_sample_next_action),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.review_sample_next_action_body),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun ReviewMetricCard(
    metric: ReviewSampleMetric,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    NoopCard(
        modifier = modifier
            .clickable(role = Role.Button, onClick = onClick)
            .testTag("noop.review.metric.${metric.id}"),
    ) {
        Column(
            modifier = Modifier.heightIn(min = 108.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Text(
                stringResource(metric.title),
                style = NoopType.overline,
                color = Palette.textSecondary,
                maxLines = 2,
            )
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    metric.value,
                    style = NoopType.title2,
                    color = Palette.textPrimary,
                    maxLines = 1,
                )
                if (metric.unit.isNotEmpty()) {
                    Spacer(Modifier.width(4.dp))
                    Text(metric.unit, style = NoopType.footnote, color = Palette.textTertiary)
                }
            }
            Text(
                stringResource(R.string.review_sample_open_detail),
                style = NoopType.footnote,
                color = Palette.accent,
            )
        }
    }
}

@Composable
private fun ReviewSampleMetricDetail(
    metric: ReviewSampleMetric,
    onBack: () -> Unit,
    onExit: () -> Unit,
) {
    ReviewSampleDetailScaffold(
        title = stringResource(metric.title),
        onBack = onBack,
        onExit = onExit,
    ) { modifier ->
        ReviewSampleContent(modifier) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(metric.value, style = NoopType.display(56f), color = Palette.textPrimary)
                if (metric.unit.isNotEmpty()) {
                    Spacer(Modifier.width(8.dp))
                    Text(metric.unit, style = NoopType.headline, color = Palette.textSecondary)
                }
            }
            Text(
                stringResource(metric.summary),
                style = NoopType.body,
                color = Palette.textSecondary,
            )
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text(
                        stringResource(R.string.review_sample_last_seven_days),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    ReviewSampleBars(metric.history)
                }
            }
            NoopCard {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        stringResource(R.string.review_sample_how_to_read),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        stringResource(R.string.review_sample_how_to_read_body),
                        style = NoopType.body,
                        color = Palette.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun ReviewSampleBars(values: List<Float>) {
    val maximum = values.maxOrNull()?.coerceAtLeast(1f) ?: 1f
    val dayLabels = listOf(
        stringResource(R.string.review_sample_day_1),
        stringResource(R.string.review_sample_day_2),
        stringResource(R.string.review_sample_day_3),
        stringResource(R.string.review_sample_day_4),
        stringResource(R.string.review_sample_day_5),
        stringResource(R.string.review_sample_day_6),
        stringResource(R.string.review_sample_day_7),
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(122.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        values.forEachIndexed { index, value ->
            Column(
                modifier = Modifier.weight(1f),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height((96f * value / maximum).coerceAtLeast(14f).dp)
                        .clip(RoundedCornerShape(99.dp))
                        .background(if (index == values.lastIndex) Palette.accent else Palette.textTertiary),
                )
                Text(
                    dayLabels[index],
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun ReviewSampleTrends(
    modifier: Modifier,
    onMetric: (ReviewSampleMetric) -> Unit,
) {
    var interval by remember { mutableIntStateOf(0) }
    ReviewSampleContent(modifier) {
        Text(stringResource(R.string.nav_trends), style = NoopType.title1, color = Palette.textPrimary)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(Palette.surfaceRaised)
                .padding(4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            listOf("7D", "30D", "90D").forEachIndexed { index, label ->
                val selected = interval == index
                Text(
                    label,
                    style = NoopType.headline,
                    color = if (selected) Palette.accentInk else Palette.textSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(if (selected) Palette.accent else Color.Transparent)
                        .clickable { interval = index }
                        .semantics { stateDescription = if (selected) "selected" else "not selected" }
                        .padding(vertical = 10.dp)
                        .testTag("noop.review.trends.interval.$index"),
                )
            }
        }
        reviewSampleMetrics.take(4).forEach { metric ->
            NoopCard(
                modifier = Modifier.clickable(role = Role.Button) { onMetric(metric) },
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row {
                        Text(
                            stringResource(metric.title),
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            listOf(metric.value, metric.unit)
                                .filter(String::isNotEmpty)
                                .joinToString(separator = " "),
                            style = NoopType.headline,
                            color = Palette.accent,
                        )
                    }
                    ReviewSampleBars(metric.history)
                }
            }
        }
    }
}

@Composable
private fun ReviewSampleWorkouts(modifier: Modifier) {
    ReviewSampleContent(modifier) {
        Text(stringResource(R.string.nav_workouts), style = NoopType.title1, color = Palette.textPrimary)
        NoopCard(tint = Palette.accent) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row {
                    Text(
                        stringResource(R.string.review_sample_strength_training),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        stringResource(R.string.review_sample_workout_duration),
                        style = NoopType.headline,
                        color = Palette.accent,
                    )
                }
                Text(
                    stringResource(R.string.review_sample_fictional_session),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                HorizontalDivider(color = Palette.hairline)
                ReviewValueRow(R.string.review_sample_average_hr, "126 bpm")
                ReviewValueRow(R.string.review_sample_peak_hr, "161 bpm")
                ReviewValueRow(R.string.review_sample_active_energy, "318 kcal")
                ReviewValueRow(R.string.review_sample_workout_effort, "7.4")
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    stringResource(R.string.review_sample_weekly_plan),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.review_sample_weekly_plan_body),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
                LinearProgressIndicator(
                    progress = { 2f / 3f },
                    color = Palette.accent,
                    trackColor = Palette.hairline,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

@Composable
private fun ReviewSampleSleep(modifier: Modifier) {
    ReviewSampleContent(modifier) {
        Text(stringResource(R.string.nav_sleep), style = NoopType.title1, color = Palette.textPrimary)
        NoopCard(tint = Palette.sleepDeep) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.review_sample_sleep_duration),
                            style = NoopType.display(50f),
                            color = Palette.textPrimary,
                        )
                        Text(
                            stringResource(R.string.review_sample_sleep_span),
                            style = NoopType.subhead,
                            color = Palette.textSecondary,
                        )
                    }
                    Text("92%", style = NoopType.title2, color = Palette.sleepDeep)
                }
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(14.dp)
                        .clip(RoundedCornerShape(99.dp)),
                ) {
                    Box(Modifier.weight(0.08f).fillMaxHeight().background(Palette.sleepAwake))
                    Box(Modifier.weight(0.49f).fillMaxHeight().background(Palette.sleepLight))
                    Box(Modifier.weight(0.20f).fillMaxHeight().background(Palette.sleepDeep))
                    Box(Modifier.weight(0.21f).fillMaxHeight().background(Palette.sleepREM))
                }
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                ReviewSleepRow(R.string.review_sample_awake, "38 min", Palette.sleepAwake)
                ReviewSleepRow(R.string.review_sample_light, "3h 47m", Palette.sleepLight)
                ReviewSleepRow(R.string.review_sample_deep, "1h 34m", Palette.sleepDeep)
                ReviewSleepRow(R.string.review_sample_rem, "2h 21m", Palette.sleepREM)
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.review_sample_wake_events),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.review_sample_wake_events_body),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun ReviewSampleMore(
    modifier: Modifier,
    onOpen: (ReviewSampleMoreDestination) -> Unit,
    onExit: () -> Unit,
) {
    ReviewSampleContent(modifier) {
        Text(stringResource(R.string.nav_more), style = NoopType.title1, color = Palette.textPrimary)
        NoopCard(padding = 0.dp) {
            Column {
                ReviewMoreRow(R.string.review_sample_friends, Icons.Filled.People) {
                    onOpen(ReviewSampleMoreDestination.FRIENDS)
                }
                HorizontalDivider(color = Palette.hairline)
                ReviewMoreRow(R.string.review_sample_privacy, Icons.Filled.Shield) {
                    onOpen(ReviewSampleMoreDestination.PRIVACY)
                }
                HorizontalDivider(color = Palette.hairline)
                ReviewMoreRow(R.string.review_sample_devices, Icons.Filled.Watch) {
                    onOpen(ReviewSampleMoreDestination.DEVICES)
                }
            }
        }
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    stringResource(R.string.review_sample_isolation),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Text(
                    stringResource(R.string.review_sample_isolation_body),
                    style = NoopType.body,
                    color = Palette.textSecondary,
                )
            }
        }
        NoopButton(
            text = stringResource(R.string.review_sample_exit),
            leadingIcon = Icons.Filled.Close,
            kind = NoopButtonKind.Secondary,
            fullWidth = true,
            onClick = onExit,
        )
    }
}

@Composable
private fun ReviewSampleMoreDetail(
    destination: ReviewSampleMoreDestination,
    onBack: () -> Unit,
    onExit: () -> Unit,
) {
    val title = when (destination) {
        ReviewSampleMoreDestination.FRIENDS -> stringResource(R.string.review_sample_friends)
        ReviewSampleMoreDestination.PRIVACY -> stringResource(R.string.review_sample_privacy)
        ReviewSampleMoreDestination.DEVICES -> stringResource(R.string.review_sample_devices)
    }
    val body = when (destination) {
        ReviewSampleMoreDestination.FRIENDS -> stringResource(R.string.review_sample_friends_body)
        ReviewSampleMoreDestination.PRIVACY -> stringResource(R.string.review_sample_privacy_body)
        ReviewSampleMoreDestination.DEVICES -> stringResource(R.string.review_sample_devices_body)
    }
    ReviewSampleDetailScaffold(title, onBack, onExit) { modifier ->
        ReviewSampleContent(modifier) {
            NoopCard {
                Text(body, style = NoopType.body, color = Palette.textSecondary)
            }
            when (destination) {
                ReviewSampleMoreDestination.FRIENDS -> {
                    ReviewDetailRow(R.string.review_sample_circle, R.string.review_sample_three_members)
                    ReviewDetailRow(R.string.review_sample_pokes, R.string.review_sample_disabled)
                    ReviewDetailRow(R.string.review_sample_location, R.string.review_sample_not_shared)
                }
                ReviewSampleMoreDestination.PRIVACY -> {
                    ReviewDetailRow(R.string.review_sample_bluetooth_scan, R.string.review_sample_not_requested)
                    ReviewDetailRow(R.string.nav_apple_health, R.string.review_sample_not_requested)
                    ReviewDetailRow(R.string.managed_cloud_brand, R.string.review_sample_off)
                    ReviewDetailRow(R.string.nav_notifications, R.string.review_sample_off)
                }
                ReviewSampleMoreDestination.DEVICES -> {
                    ReviewDetailRow(R.string.review_sample_connected_device, R.string.review_sample_none)
                    ReviewDetailRow(R.string.review_sample_bluetooth_scan, R.string.review_sample_disabled)
                    ReviewDetailRow(R.string.review_sample_stored_hardware_data, R.string.review_sample_none)
                }
            }
        }
    }
}

@Composable
private fun ReviewSampleDetailScaffold(
    title: String,
    onBack: () -> Unit,
    onExit: () -> Unit,
    content: @Composable (Modifier) -> Unit,
) {
    Scaffold(
        containerColor = Palette.surfaceBase,
        topBar = {
            Column {
                ReviewSampleBanner(onExit)
                Surface(color = Palette.surfaceBase) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = 50.dp)
                            .padding(horizontal = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .clickable(role = Role.Button, onClick = onBack),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                stringResource(R.string.review_sample_back),
                            )
                        }
                        Text(
                            title,
                            style = NoopType.headline,
                            color = Palette.textPrimary,
                            modifier = Modifier.weight(1f),
                            textAlign = TextAlign.Center,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Spacer(Modifier.width(40.dp))
                    }
                }
            }
        },
    ) { inner -> content(Modifier.padding(inner)) }
}

@Composable
private fun ReviewSampleContent(
    modifier: Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        content = content,
    )
}

@Composable
private fun ReviewValueRow(@StringRes title: Int, value: String) {
    Row {
        Text(
            stringResource(title),
            style = NoopType.subhead,
            color = Palette.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Text(value, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

@Composable
private fun ReviewSleepRow(@StringRes title: Int, value: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(8.dp))
        Text(
            stringResource(title),
            style = NoopType.subhead,
            color = Palette.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Text(value, style = NoopType.subhead, color = Palette.textPrimary)
    }
}

@Composable
private fun ReviewMoreRow(
    @StringRes title: Int,
    icon: ImageVector,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, null, tint = Palette.accent)
        Text(
            stringResource(title),
            style = NoopType.body,
            color = Palette.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Icon(Icons.Filled.ChevronRight, null, tint = Palette.textTertiary)
    }
}

@Composable
private fun ReviewDetailRow(@StringRes title: Int, @StringRes value: Int) {
    NoopCard {
        Row {
            Text(
                stringResource(title),
                style = NoopType.body,
                color = Palette.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(stringResource(value), style = NoopType.subhead, color = Palette.textSecondary)
        }
    }
}
