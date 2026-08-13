import Foundation

/// Pure freshness contract shared by the iOS Live Activity controller and its regression tests.
/// A transport connection is not a biometric observation: a cached BPM may be displayed only while
/// its original packet is recent. This prevents a reconnect, app relaunch, or UI republish from
/// turning an old heart-rate value back into a green "live" surface.
enum LiveHeartRateSurfacePolicy {
    static let maximumSampleAge: TimeInterval = 30

    static func isLive(connected: Bool, bpm: Int?, observedAt: Date?, now: Date) -> Bool {
        guard connected,
              let bpm, (30...220).contains(bpm),
              let observedAt else { return false }
        let age = now.timeIntervalSince(observedAt)
        return age >= 0 && age <= maximumSampleAge
    }

    static func expiryDelay(observedAt: Date, now: Date) -> TimeInterval {
        max(0, observedAt.addingTimeInterval(maximumSampleAge).timeIntervalSince(now))
    }
}
