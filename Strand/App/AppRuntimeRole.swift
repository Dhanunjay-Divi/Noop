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

    var allowsLocalAnalysisAndGuidance: Bool {
        self == .phoneCollector
    }

    /// A viewer label must not imply that account transport exists. The current
    /// macOS target deliberately has no managed-auth or restore composition.
    var hasManagedViewerTransport: Bool {
        false
    }

    /// Never mount the operational repository-backed shell for a viewer until
    /// an authenticated managed transport can establish account provenance.
    var canPresentOperationalShell: Bool {
        allowsLocalCollection || hasManagedViewerTransport
    }
}
