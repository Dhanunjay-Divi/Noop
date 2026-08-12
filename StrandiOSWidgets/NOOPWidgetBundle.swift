import WidgetKit
import SwiftUI
import StrandDesign

/// The widget extension entry point. Bundles the glanceable widget and the live-HR Live Activity.
@main
struct NOOPWidgetBundle: WidgetBundle {
    init() {
        // WidgetKit renders in a separate process. Seed the complete surface variant before any
        // configuration evaluates palette tokens; individual views below also force Light/Dark.
        StrandPalette.appearanceMode = AppearanceMode.resolve(WidgetAppearancePreference.load())
    }

    var body: some Widget {
        NOOPWidget()
        NOOPVitalsWidget()
        NOOPSleepWidget()
        NOOPLiveActivity()
    }
}
