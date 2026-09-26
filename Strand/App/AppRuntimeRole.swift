import Foundation

/// Defines which responsibilities this process may own.
///
/// The first release has one phone collector per band. macOS is a signed-in
/// viewer and must never compete for BLE, weight-scale, or other live-source
/// ownership.
enum AppRuntimeRole: Equatable {
    case phoneCollector
    case managedViewer

    static var currentPlatform: AppRuntimeRole {
        #if os(macOS)
        return .managedViewer
        #else
        return .phoneCollector
        #endif
    }

    var allowsLocalCollection: Bool {
        self == .phoneCollector
    }

    /// Only the collector phone owns device discovery, pairing, and durable
    /// local-band setup. A managed viewer must reach its account-backed shell
    /// without entering those steps.
    var requiresCollectorOnboarding: Bool {
        allowsLocalCollection
    }

    var allowsLocalAnalysisAndGuidance: Bool {
        true
    }

    /// The macOS target has a signed-in, read-only managed transport. Runtime
    /// configuration still fails closed when its separate App Check identity
    /// or managed endpoint is absent.
    var hasManagedViewerTransport: Bool {
        self == .managedViewer
    }

    /// Preserve the existing local macOS history, export, and analysis shell.
    /// Collector-only actions remain gated by `allowsLocalCollection`, so
    /// macOS cannot compete with the phone for live-source ownership.
    var canPresentOperationalShell: Bool {
        allowsLocalAnalysisAndGuidance || hasManagedViewerTransport
    }
}
