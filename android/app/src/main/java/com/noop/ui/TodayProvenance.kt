package com.noop.ui

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.analytics.FusionSource
import com.noop.analytics.ReadinessEngine
import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.WhoopRepository

@StringRes
internal fun readinessHeadlineResource(level: ReadinessEngine.Level): Int = when (level) {
    ReadinessEngine.Level.INSUFFICIENT -> R.string.appwide_readiness_insufficient_headline
    ReadinessEngine.Level.RUNDOWN -> R.string.appwide_readiness_rundown_headline
    ReadinessEngine.Level.STRAINED -> R.string.appwide_readiness_strained_headline
    ReadinessEngine.Level.PRIMED -> R.string.appwide_readiness_primed_headline
    ReadinessEngine.Level.BALANCED -> R.string.appwide_readiness_balanced_headline
}

@Composable
internal fun localizedReadinessHeadline(readiness: ReadinessEngine.Readiness): String =
    stringResource(readinessHeadlineResource(readiness.level))

@Composable
internal fun localizedReadinessSummary(readiness: ReadinessEngine.Readiness): String {
    val resource = when (readiness.level) {
        ReadinessEngine.Level.INSUFFICIENT -> {
            if (readiness.limitations.any { it == "No daily recovery row is available for this date." }) {
                R.string.appwide_readiness_insufficient_current_summary
            } else {
                R.string.appwide_readiness_insufficient_summary
            }
        }
        ReadinessEngine.Level.RUNDOWN -> R.string.appwide_readiness_rundown_summary
        ReadinessEngine.Level.STRAINED -> R.string.appwide_readiness_strained_summary
        ReadinessEngine.Level.PRIMED -> R.string.appwide_readiness_primed_summary
        ReadinessEngine.Level.BALANCED -> R.string.appwide_readiness_balanced_summary
    }
    return stringResource(resource)
}

@Composable
internal fun localizedReadinessLimitation(
    raw: String,
    readiness: ReadinessEngine.Readiness,
): String = when {
    raw == "No daily recovery row is available for this date." ->
        stringResource(R.string.appwide_readiness_limitation_no_daily_row)
    raw == "No current recovery signal has enough prior variation for comparison." ->
        stringResource(R.string.appwide_readiness_limitation_no_current_signal)
    raw == "This read is based on one current recovery signal." ->
        stringResource(R.string.appwide_readiness_limitation_one_signal)
    raw.startsWith("The personal baseline has ") ->
        stringResource(R.string.appwide_readiness_limitation_baseline_building, readiness.baselineDays)
    else -> raw
}

/**
 * The Today provenance label for the day's REAL merge winner, extends the existing By-Day badge
 * vocabulary consistently. NOOP-computed reads "On-device" (the spec's wording for the By-Day badge,
 * versus the FusedRecord screen's terser "NOOP"), an imported strap day reads "Whoop", and a phone
 * aggregate reads "Apple Health" / "Health Connect". Null when no source owns the day (nothing to
 * stamp). Mirrors the Swift `provenanceBadgeLabel`.
 */
internal fun dayOwnerSource(deviceId: String?): FusionSource? = when {
    deviceId == null -> null
    deviceId.endsWith("-noop") -> FusionSource.NOOP_COMPUTED
    deviceId == WhoopRepository.APPLE_HEALTH_SOURCE -> FusionSource.APPLE_HEALTH
    deviceId == WhoopRepository.HEALTH_CONNECT_SOURCE -> FusionSource.HEALTH_CONNECT
    // The merged Today rows carry the imported strap deviceId ("my-whoop") on days a real WHOOP import
    // covers, and the "-noop" sibling otherwise; any other strap deviceId is still an imported strap day.
    else -> FusionSource.WHOOP_IMPORT
}

internal fun provenanceBadgeLabel(owner: FusionSource?): String? = when (owner) {
    FusionSource.NOOP_COMPUTED -> "On-device"
    FusionSource.WHOOP_IMPORT -> "Imported"
    FusionSource.APPLE_HEALTH -> "Apple Health"
    FusionSource.HEALTH_CONNECT -> "Health Connect"
    FusionSource.XIAOMI_BAND -> "Mi Band"
    FusionSource.NUTRITION_CSV -> "Nutrition"
    FusionSource.LOCAL_CACHE -> "Cached"
    null -> null
}

/**
 * PURE mapper (unit-tested), a RAW resolver source id (as returned by [WhoopRepository.resolvedSeries]'s
 * winning point, e.g. "my-whoop", "my-whoop-noop", "apple-health") onto the spec's provenance labels,
 * given the strap's real [deviceId]. ANY NOOP-computed strap sibling (a "-noop"-suffixed id, not just the
 * active strap's) reads "On-device" - matching by suffix rather than "$deviceId-noop" so a computed row
 * from a non-active strap can't fall through to [FusionSource.NOOP_COMPUTED]'s raw "NOOP" displayName
 * (the internal id must never surface); the imported strap source ([deviceId], normally "my-whoop") reads
 * "Whoop"; the Apple-Health source reads "Apple Health". Any other real source (Health Connect, Mi Band,
 * nutrition) keeps its [FusionSource.displayName], still the genuine merge winner, never a blanket claim.
 * Mirrors the Swift `provenanceDisplayLabel` EXACTLY. This is the PER-METRIC mapper the Today rings use;
 * the day-level [dayOwnerSource]/[provenanceBadgeLabel] pair stays for the legacy By-Day vocabulary.
 */
internal fun provenanceDisplayLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String {
    if (rawSource == MOTION_DERIVED_STEPS_SOURCE) return "Motion-derived estimate"
    if (rawSource == CALIBRATED_MOTION_STEPS_SOURCE) return "Calibrated motion estimate"
    if (rawSource.endsWith("-noop")) return "On-device"
    if (rawSource == deviceId || rawSource == WhoopRepository.WHOOP_SOURCE) return "Imported"
    if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) return "Apple Health"
    // Fall back to the FusionSource display name for any other known source; else the raw id verbatim.
    return FusionSource.entries.firstOrNull { it.id == rawSource }?.displayName ?: rawSource
}

/** Today uses the audience-facing sensor name for Apple Health scores, matching the Swift Today lane. */
internal fun todayProvenanceChipLabel(
    rawSource: String,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String = if (rawSource == WhoopRepository.APPLE_HEALTH_SOURCE) {
    "Apple Watch"
} else {
    provenanceDisplayLabel(rawSource, deviceId).let {
        if (it == "Imported") WhoopModel.CUSTOMER_NAME else it
    }
}

/**
 * One compact source label for the liquid score hero. Raw winners arrive in Charge / Effort / Rest order;
 * identical display names collapse and mixed winners are capped at two so the badge stays readable.
 * Mirrors LiquidTodayView.heroSourceLabel value-for-value.
 */
internal fun heroSourceLabel(
    rawSources: List<String>,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String? {
    val labels = LinkedHashSet<String>()
    for (rawSource in rawSources) {
        labels.add(todayProvenanceChipLabel(rawSource, deviceId))
        if (labels.size == 2) break
    }
    return labels.takeIf { it.isNotEmpty() }?.joinToString(" + ")
}

/** A mixed hero label still represents a live compatible-band source and must retain sync feedback. */
internal fun sourceLabelIncludesCompatibleBand(label: String): Boolean =
    label.split("+").any { it.trim().equals(WhoopModel.CUSTOMER_NAME, ignoreCase = true) }

/** Transfer activity ending can also mean timeout or disconnect. Confirm only when completion advanced. */
internal fun bandSyncCompletionAdvanced(startedAt: Long?, completedAt: Long?): Boolean =
    completedAt != null && (startedAt == null || completedAt > startedAt)

/**
 * Source label for the three visible hero scores. Today can show a carried Charge from the previous
 * scored night while today's recovery is still absent (#543); in that state the selected-day
 * "recovery" provenance is also absent, so use the carried night's resolved recovery source instead of
 * letting the card badge omit or misrepresent the visible Charge (#390).
 */
internal fun scoreHeroSourceLabel(
    provenanceByMetric: Map<String, String>,
    carriedRecoverySource: String?,
    usesCarriedRecovery: Boolean,
    deviceId: String = WhoopRepository.WHOOP_SOURCE,
): String? {
    val recoverySource = provenanceByMetric["recovery"]
        ?: if (usesCarriedRecovery) carriedRecoverySource else null
    return heroSourceLabel(
        rawSources = listOfNotNull(
            recoverySource,
            provenanceByMetric["strain"],
            provenanceByMetric["sleep_performance"],
        ),
        deviceId = deviceId,
    )
}

/** Today pull-to-sync mirrors the BLE client's manual-sync guard, so the gesture never starts a sync while
 *  disconnected, still bonding, or already offloading. Kept pure for the UI-specific contract test. */
internal fun todayPullToSyncEnabled(
    connected: Boolean,
    bonded: Boolean,
    backfilling: Boolean,
): Boolean = WhoopBleClient.canRequestSync(connected, bonded, backfilling)

/** The tint for a per-metric provenance badge, keyed on the resolved LABEL, gold for Whoop, cyan for
 *  Apple Health, the positive status hue for on-device (and anything else). Matches the Data Sources
 *  footer + the Swift `provenanceTint` so the same source reads the same colour on Today. */
internal fun provenanceLabelTint(label: String): Color = when (label) {
    "Imported", WhoopModel.CUSTOMER_NAME -> Palette.accent
    "Apple Health" -> Palette.metricCyan
    "Health Connect" -> Palette.metricPurple
    else -> Palette.statusPositive
}

/**
 * S4 (#205): the descriptive readiness read kept on the hero now the full Readiness
 * card folded into the Charge-ring tap. PURE mapping of the existing [ReadinessEngine.Level]; INSUFFICIENT
 * returns null (the hero then shows no word, matching the old card hiding itself). Byte-identical twin of
 * the Swift TodayView.readinessWord.
 */
internal fun readinessWord(level: ReadinessEngine.Level): String? = when (level) {
    ReadinessEngine.Level.PRIMED -> "Aligned"
    ReadinessEngine.Level.BALANCED -> "Within range"
    ReadinessEngine.Level.STRAINED -> "Recheck"
    ReadinessEngine.Level.RUNDOWN -> "Multiple shifts"
    ReadinessEngine.Level.INSUFFICIENT -> null
}

/**
 * S5: the collapsed Data Sources footer summary, "Synced from: WHOOP, Apple Watch", listing only sources
 * with data (Apple Health reads as "Apple Watch", the device the audience knows), or "No sources yet".
 * PURE + unit-tested. Twin of the Swift TodayView.syncedFromSummary, plus the Android-only
 * hasHealthConnect source - Health Connect is named for what it is, never folded under "Apple Watch"
 * (issue #176).
 */
internal fun syncedFromSummary(hasWhoop: Boolean, hasApple: Boolean, hasHealthConnect: Boolean = false, hasXiaomi: Boolean): String {
    val names = buildList {
        if (hasWhoop) add(WhoopModel.CUSTOMER_NAME)
        if (hasApple) add("Apple Watch")
        if (hasHealthConnect) add("Health Connect")
        if (hasXiaomi) add("Mi Band")
    }
    return if (names.isEmpty()) "No sources yet" else "Synced from: " + names.joinToString(", ")
}
