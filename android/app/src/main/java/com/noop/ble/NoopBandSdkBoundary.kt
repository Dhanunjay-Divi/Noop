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
        "44559aeb4b1b50af9e6ab8b8dc786f87821c72d9"

    fun newSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        historyCheckpoint: BandHistoryCheckpoint? = null,
    ): BandSessionMachine = BandSessionMachine(
        diagnostics = diagnostics,
        restoredHistoryCheckpoint = historyCheckpoint,
    )
}
