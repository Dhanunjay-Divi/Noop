import NoopBandSDK

/// The app-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
///
/// This does not register a transport. Production source coordinators receive
/// no NOOP-band factory until a separately reviewed supplier adapter exists.
enum NoopBandSDKBoundary {
    static let pinnedSourceRevision =
        "8fb464471fdd4ae09d5750feedcc25d50bdb1c20"

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
