package com.noop.ui

import com.noop.analytics.AutoWorkoutDetector
import com.noop.analytics.AutoWorkoutDetectorTrace
import com.noop.analytics.CoarseWorkoutClass
import com.noop.analytics.WorkoutTypeClassifier
import com.noop.analytics.WorkoutTypeFeatureExtractor
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Shared suggestion-only auto-workout scan used by both the Today card and the background notifier.
 * It performs reads and detection only: it never saves, dismisses, or otherwise mutates a workout.
 */
internal object AutoWorkoutCandidateScan {
    private const val DAYS_BACK = 2L

    /**
     * Scan recent active/canonical strap history, exclude every saved or dismissed span, and return the
     * newest surviving candidate. [traceSink] selects the diagnostic detector twin when supplied; that
     * twin returns the same candidates as the normal detector.
     */
    suspend fun latest(
        repository: WhoopRepository,
        activeDeviceId: String,
        days: List<DailyMetric>,
        dismissedTokens: Set<String>,
        nowSec: Long = System.currentTimeMillis() / 1_000L,
        traceSink: ((String) -> Unit)? = null,
    ): AutoWorkoutDetector.DetectedWorkout? = withContext(Dispatchers.Default) {
        val fromSec = nowSec - DAYS_BACK * 86_400L

        // Live/re-added straps bank under their active id while imports retain `my-whoop`; use the same
        // active-first union as Today so a background scan and the visible card cannot disagree.
        val hr = repository.hrSamplesUnion(activeDeviceId, fromSec, nowSec, limit = 200_000)
        if (hr.size < 2) return@withContext null
        val gravity = repository.gravitySamplesUnion(activeDeviceId, fromSec, nowSec, limit = 200_000)

        // Most recent nightly RHR, else AutoWorkoutDetector's own default. Matches the existing card path.
        val restingHr = days.lastOrNull { it.restingHr != null }?.restingHr

        // One bounded, source-complete overlap read. This automatically includes imported activity files,
        // every paired/retired device id, each computed sibling and future sources.
        val saved = repository.workoutsOverlappingAllSources(fromSec, nowSec, limit = 200_000)
            .map { it.startTs to it.endTs }

        val candidates = if (traceSink != null) {
            val (results, trace) = AutoWorkoutDetectorTrace.detectTrace(
                hr = hr,
                restingHR = restingHr,
                gravity = gravity,
                savedWorkouts = saved,
                path = "autoDetect",
            )
            trace.forEach(traceSink)
            results
        } else {
            AutoWorkoutDetector.detect(
                hr = hr,
                restingHR = restingHr,
                gravity = gravity,
                savedWorkouts = saved,
            )
        }

        val candidate = candidates
            .filter { candidate -> dismissedTokens.none { AutoWorkoutPrefs.matches(it, candidate) } }
            .maxByOrNull { it.startSec } ?: return@withContext null

        // Broad type is strictly advisory and only shown when the strap supplied real decoded
        // activity-class ticks across the window. HR/motion-only captures remain generic rather than
        // turning a synthetic-fixture heuristic into a confident-looking sport label.
        val steps = repository.stepSamplesUnion(activeDeviceId, candidate.startSec, candidate.endSec)
        val features = WorkoutTypeFeatureExtractor.extract(
            hr = hr,
            gravity = gravity,
            steps = steps,
            start = candidate.startSec,
            end = candidate.endSec,
            restingHR = restingHr?.toDouble(),
        ) ?: return@withContext candidate
        if (features.tickCoverage < WorkoutTypeClassifier.minTickCoverage) return@withContext candidate
        val prediction = WorkoutTypeClassifier.classify(features)
        if (prediction.predictedClass == CoarseWorkoutClass.OTHER ||
            prediction.confidence < WorkoutTypeClassifier.minAdvisoryConfidence
        ) return@withContext candidate
        return@withContext candidate.copy(
            suggestedClass = prediction.predictedClass,
            suggestionConfidence = prediction.confidence,
        )
    }
}
