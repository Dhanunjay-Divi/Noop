import NoopBandSDK

/// The app-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
///
/// This does not register a transport. Production source coordinators receive
/// no NOOP-band factory until a separately reviewed supplier adapter exists.
enum NoopBandSDKBoundary {
    static let pinnedSourceRevision =
        "38cf7de3b1c92dd30dad343af2adfa2cb61dea2e"

    static func makeSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder(),
        historyCheckpoint: BandHistoryCheckpoint? = nil
    ) -> BandSessionMachine {
        BandSessionMachine(
            diagnostics: diagnostics,
            historyCheckpoint: historyCheckpoint
        )
    }
}
