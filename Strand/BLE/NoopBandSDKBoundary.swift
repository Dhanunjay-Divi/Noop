import NoopBandSDK

/// The app-owned boundary for the pinned, supplier-neutral NOOP Band SDK.
///
/// This does not register a transport. Production source coordinators receive
/// no NOOP-band factory until a separately reviewed supplier adapter exists.
enum NoopBandSDKBoundary {
    static let pinnedSourceRevision =
        "0abd9a3ce4f808b51bdc93ad28504ac810914631"

    static func makeSession(
        diagnostics: BandDiagnosticsRecorder = BandDiagnosticsRecorder()
    ) -> BandSessionMachine {
        BandSessionMachine(diagnostics: diagnostics)
    }
}
