package com.noop.ui

import com.noop.R
import com.noop.analytics.DailySignalStatus
import com.noop.analytics.ReadinessEngine
import org.junit.Assert.assertEquals
import org.junit.Test

class DailySignalPresentationTest {
    @Test
    fun signalPillMatchesReadinessVocabularyAndPolarity() {
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_readiness_primed_headline,
                DailySignalPillPolarity.POSITIVE,
            ),
            dailySignalPillPresentation(DailySignalStatus.STEADY, ReadinessEngine.Level.PRIMED),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_readiness_balanced_headline,
                DailySignalPillPolarity.POSITIVE,
            ),
            dailySignalPillPresentation(DailySignalStatus.STEADY, ReadinessEngine.Level.BALANCED),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_readiness_strained_headline,
                DailySignalPillPolarity.WARNING,
            ),
            dailySignalPillPresentation(DailySignalStatus.WATCH, ReadinessEngine.Level.STRAINED),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_readiness_rundown_headline,
                DailySignalPillPolarity.CRITICAL,
            ),
            dailySignalPillPresentation(DailySignalStatus.WATCH, ReadinessEngine.Level.RUNDOWN),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_daily_signal_status_recheck,
                DailySignalPillPolarity.WARNING,
            ),
            dailySignalPillPresentation(DailySignalStatus.WATCH, ReadinessEngine.Level.BALANCED),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_daily_signal_status_check_in,
                DailySignalPillPolarity.CRITICAL,
            ),
            dailySignalPillPresentation(DailySignalStatus.ALERT, ReadinessEngine.Level.BALANCED),
        )
        assertEquals(
            DailySignalPillPresentation(
                R.string.appwide_daily_signal_status_building,
                DailySignalPillPolarity.NEUTRAL,
            ),
            dailySignalPillPresentation(DailySignalStatus.BUILDING, ReadinessEngine.Level.PRIMED),
        )
    }

    @Test
    fun coachEntryPrioritizesBandReadinessThenCurrentRecovery() {
        assertEquals(
            LiveSessionEntryState.BAND_REQUIRED,
            liveSessionEntryState(bandReady = false, hasCurrentRecovery = true),
        )
        assertEquals(
            R.string.appwide_live_session_connect_band,
            liveSessionEntryTitleRes(LiveSessionEntryState.BAND_REQUIRED),
        )
        assertEquals(
            R.string.appwide_live_session_band_required,
            liveSessionEntryDetailRes(LiveSessionEntryState.BAND_REQUIRED),
        )

        assertEquals(
            LiveSessionEntryState.RECOVERY_UNAVAILABLE,
            liveSessionEntryState(bandReady = true, hasCurrentRecovery = false),
        )
        assertEquals(
            R.string.appwide_live_session_start_detail_unavailable,
            liveSessionEntryDetailRes(LiveSessionEntryState.RECOVERY_UNAVAILABLE),
        )

        assertEquals(
            LiveSessionEntryState.READY,
            liveSessionEntryState(bandReady = true, hasCurrentRecovery = true),
        )
        assertEquals(
            R.string.appwide_live_session_start_detail,
            liveSessionEntryDetailRes(LiveSessionEntryState.READY),
        )
    }
}
