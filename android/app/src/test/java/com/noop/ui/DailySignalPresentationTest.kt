package com.noop.ui

import com.noop.R
import com.noop.analytics.DailySignalStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class DailySignalPresentationTest {
    @Test
    fun signalStatesUseTheirOwnVocabularyResources() {
        assertEquals(
            R.string.appwide_daily_signal_status_aligned,
            dailySignalStatusLabelRes(DailySignalStatus.STEADY),
        )
        assertEquals(
            R.string.appwide_daily_signal_status_recheck,
            dailySignalStatusLabelRes(DailySignalStatus.WATCH),
        )
        assertEquals(
            R.string.appwide_daily_signal_status_check_in,
            dailySignalStatusLabelRes(DailySignalStatus.ALERT),
        )
        assertEquals(
            R.string.appwide_daily_signal_status_building,
            dailySignalStatusLabelRes(DailySignalStatus.BUILDING),
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
