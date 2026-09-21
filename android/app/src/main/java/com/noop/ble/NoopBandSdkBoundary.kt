package com.noop.ble

import com.noop.bandsdk.BandDiagnosticsRecorder
import com.noop.bandsdk.BandSessionMachine

/**
 * App-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
 *
 * This does not register a transport. Production composition roots supply no
 * NOOP-band factory until a separately reviewed supplier adapter exists.
 */
object NoopBandSdkBoundary {
    const val PINNED_SOURCE_REVISION =
        "0abd9a3ce4f808b51bdc93ad28504ac810914631"

    fun newSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
    ): BandSessionMachine = BandSessionMachine(diagnostics)
}
