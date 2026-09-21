import SwiftUI

enum FriendsNavigationCopy {
    static let invitationInstruction =
        "In Noop, open More → Friends → Enter invite details. Sharing starts only after I accept your request."
}

struct FriendsView: View {
    #if os(macOS)
    @ObservedObject private var macManagedService =
        MacManagedViewerService.shared
    #endif

    var body: some View {
        #if os(iOS)
        ManagedFriendsView()
        #elseif os(macOS)
        MacManagedFriendsView(service: macManagedService)
        #endif
    }
}
