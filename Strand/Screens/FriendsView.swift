import SwiftUI

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
