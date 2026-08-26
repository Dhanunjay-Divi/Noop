package com.noop.analytics

import com.noop.data.SleepSession

/**
 * Publication boundary for locally computed detailed sleep stages.
 *
 * Imported provider stages remain independently publishable in-app. A local stage split may publish
 * only for the current canonical main-night group when every fragment carries exact-session evidence
 * produced for its current bounds and the aggregated five-minute R-R coverage is sustained.
 */
object DetailedSleepStagePublication {
    data class SessionKey(
        val deviceId: String,
        val startTs: Long,
        val endTs: Long,
    )

    data class RrWindowCounts(
        val eligible: Int,
        val valid: Int,
    )

    fun key(session: SleepSession): SessionKey =
        SessionKey(session.deviceId, session.startTs, session.endTs)

    /**
     * Return attributable counts only when both nullable columns form a valid pair for the row's exact
     * current effective bounds. Any partial, negative, impossible, overflowed, or stale pair fails closed.
     */
    fun exactRrWindowCounts(session: SleepSession): RrWindowCounts? {
        val eligible = session.rrEligibleWindowCount ?: return null
        val valid = session.rrValidWindowCount ?: return null
        if (eligible < 0 || valid < 0 || valid > eligible) return null
        val start = session.effectiveStartTs
        val end = session.endTs
        // Health-session bounds are non-negative epoch seconds. Validate ordering before subtraction so
        // hostile/corrupt Long extremes cannot wrap into a plausible duration.
        if (start < 0L || end < 0L || end <= start) return null
        val duration = end - start
        val expectedEligible = duration / AnalyticsEngine.REST_EVIDENCE_WINDOW_SECONDS
        if (expectedEligible > Int.MAX_VALUE || eligible != expectedEligible.toInt()) return null
        return RrWindowCounts(eligible = eligible, valid = valid)
    }

    /**
     * Indices of one exact local source/day's canonical main-night group that may publish detail.
     * Same-day naps are never authorized by the main night's evidence.
     */
    fun publishableLocalMainGroupIndices(
        sessions: List<SleepSession>,
        offsetSec: Long,
        habitualMidsleepSec: Long?,
    ): Set<Int> {
        if (sessions.isEmpty() ||
            sessions.any { !it.deviceId.endsWith("-noop") } ||
            sessions.mapTo(hashSetOf()) { it.deviceId }.size != 1
        ) {
            return emptySet()
        }
        val indices = SleepStageTotals.mainNightGroupIndices(
            sessions.map { SleepStageTotals.NightBlock(it.effectiveStartTs, it.endTs) },
            offsetSec,
            habitualMidsleepSec,
        ).orEmpty()
        if (indices.isEmpty()) return emptySet()
        val selected = indices.map(sessions::get)
        // Evidence authorizes the classification process, not an arbitrary cached number. The exact
        // selected payload must still decode before any detailed stage can cross a publication boundary.
        if (selected.any { SleepStageTotals.minutes(it.stagesJSON) == null }) return emptySet()
        return if (hasSustainedExactRrEvidence(selected)) {
            indices.toSet()
        } else {
            emptySet()
        }
    }

    /**
     * Verdict for an already resolved cross-source main-night group, as shown by the Sleep screen.
     * Imported-only stages retain provenance. If any local fragment supplies stages, all current local
     * fragments from that source must carry attributable counts and their aggregate must be sustained.
     */
    fun canPublishCurrentMainGroup(group: List<SleepSession>): Boolean {
        val stageProducers = group.filter { SleepStageTotals.minutes(it.stagesJSON) != null }
        // A bridged group is one customer-facing night. Publishing only the fragments that happened
        // to decode would present a partial split as complete, so every selected fragment must carry
        // a recognized positive-duration stage payload.
        if (stageProducers.isEmpty() || stageProducers.size != group.size) return false
        val localStageSources = stageProducers.asSequence()
            .map(SleepSession::deviceId)
            .filter { it.endsWith("-noop") }
            .toSet()
        if (localStageSources.isEmpty()) return true
        return localStageSources.all { source ->
            hasSustainedExactRrEvidence(group.filter { it.deviceId == source })
        }
    }

    fun hasSustainedExactRrEvidence(sessions: List<SleepSession>): Boolean {
        if (sessions.isEmpty()) return false
        var eligible = 0L
        var valid = 0L
        for (session in sessions) {
            val counts = exactRrWindowCounts(session) ?: return false
            eligible += counts.eligible.toLong()
            valid += counts.valid.toLong()
            if (eligible > Int.MAX_VALUE || valid > Int.MAX_VALUE) return false
        }
        return AnalyticsEngine.hasSustainedRestEvidence(
            validWindowCount = valid.toInt(),
            eligibleWindowCount = eligible.toInt(),
        )
    }
}
