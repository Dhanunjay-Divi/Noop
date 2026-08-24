package com.noop.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
internal fun RhythmRoute(viewModel: AppViewModel) {
    val context = LocalContext.current
    val deviceId by viewModel.selectedDeviceId.collectAsStateWithLifecycle()
    val lastHistorySyncAt by viewModel.lastHistorySyncAt.collectAsStateWithLifecycle()
    var consentRevision by remember { mutableIntStateOf(0) }
    var readout by remember(deviceId) { mutableStateOf(RhythmNightReadout.Empty) }

    LaunchedEffect(deviceId, lastHistorySyncAt, consentRevision) {
        if (!RhythmConsent.consentGiven(context)) {
            readout = RhythmNightReadout.Empty
            return@LaunchedEffect
        }
        readout = loadRhythmNight(viewModel, deviceId)
    }

    RhythmScreen(
        night = readout.night,
        windows = readout.windows,
        onConsentAccepted = { consentRevision += 1 },
    )
}

private suspend fun loadRhythmNight(
    viewModel: AppViewModel,
    deviceId: String,
): RhythmNightReadout = withContext(Dispatchers.IO) {
    val repository = viewModel.repo
    val now = System.currentTimeMillis() / 1_000L
    val from = now - 14L * 86_400L
    val sleep = runCatching {
        repository.sleepSessionsMerged(deviceId, from, now, limit = 4_000)
    }.getOrDefault(emptyList())
        .filter { it.endTs > it.effectiveStartTs }
        .maxByOrNull { it.endTs }
        ?: return@withContext RhythmNightReadout.Empty

    val start = sleep.effectiveStartTs
    val end = sleep.endTs
    val sourceIds = (
        repository.importedSourceIds(deviceId) + repository.computedSourceIds(deviceId)
    ).distinct()
    val rrSources = sourceIds.mapNotNull { sourceId ->
        runCatching {
            repository.rrIntervals(sourceId, start, end, limit = 200_000)
        }.getOrDefault(emptyList()).takeIf { it.isNotEmpty() }
    }
    if (rrSources.isEmpty()) return@withContext RhythmNightReadout.Empty

    val gravity = runCatching {
        repository.gravitySamplesUnion(deviceId, start, end, limit = 200_000)
    }.getOrDefault(emptyList())
    val workouts = runCatching {
        repository.workoutsOverlappingAllSources(start, end, limit = 20_000)
    }.getOrDefault(emptyList())
    val dismissedWorkouts = runCatching {
        repository.dismissedDetectedAllSources()
    }.getOrDefault(emptyList())

    RhythmNightAssembler.assembleBest(
        rrSources = rrSources,
        gravity = gravity,
        workouts = workouts,
        dismissedWorkouts = dismissedWorkouts,
        from = start,
        to = end,
    )
}
