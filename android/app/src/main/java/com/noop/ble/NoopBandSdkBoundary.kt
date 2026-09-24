package com.noop.ble

import com.noop.bandsdk.BandDiagnosticsRecorder
import com.noop.bandsdk.BandHistoryCheckpoint
import com.noop.bandsdk.BandSessionMachine

/**
 * App-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
 *
 * This does not register a transport. Production composition roots supply no
 * NOOP-band factory until a separately reviewed supplier adapter exists.
 */
object NoopBandSdkBoundary {
    const val PINNED_SOURCE_REVISION =
        "b02808372b7c537f22058c7ebc75d92c750373be"

    fun newSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        historyCheckpoint: BandHistoryCheckpoint? = null,
    ): BandSessionMachine = BandSessionMachine(
        diagnostics = diagnostics,
        restoredHistoryCheckpoint = historyCheckpoint,
    )
}
