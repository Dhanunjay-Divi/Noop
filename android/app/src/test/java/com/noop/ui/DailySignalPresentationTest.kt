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
}
