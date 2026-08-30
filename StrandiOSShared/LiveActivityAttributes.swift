#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?
        // Strap battery is optional for compatibility with activities created before this field existed
        // and while the band is still resolving its first battery packet.
        public var batteryPct: Int?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil,
                    batteryPct: Int? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
            self.batteryPct = batteryPct
        }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
