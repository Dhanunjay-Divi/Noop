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
        "7794bae631c1704e18ae5c341fbc32e89c9dc647"

    fun newSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        historyCheckpoint: BandHistoryCheckpoint? = null,
    ): BandSessionMachine = BandSessionMachine(
        diagnostics = diagnostics,
        restoredHistoryCheckpoint = historyCheckpoint,
    )
}
