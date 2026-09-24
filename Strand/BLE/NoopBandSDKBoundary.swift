import NoopBandSDK

/// The app-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
///
/// This does not register a transport. Production source coordinators receive
/// no NOOP-band factory until a separately reviewed supplier adapter exists.
enum NoopBandSDKBoundary {
    static let pinnedSourceRevision =
        "50a16fbc75f9ae604e773ff6608c87f0b96b67f7"

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
