import NoopBandSDK

/// The app-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
///
/// This does not register a transport. Production source coordinators receive
/// no NOOP-band factory until a separately reviewed supplier adapter exists.
enum NoopBandSDKBoundary {
    static let pinnedSourceRevision =
        "a9d3f1a2a55b5436bf1b65b0299a27667241afa4"

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
