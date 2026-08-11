import Foundation

/// Pure lifecycle policy for battery-intensive, high-rate sensor streaming.
///
/// Callers may retain logical leases while the app is backgrounded (for example, an in-progress
/// workout or Live Session). The transport is armed only when at least one lease exists *and* the app
/// is foreground-active. Returning to the foreground re-arms exactly once; leaving it releases exactly
/// once. Lightweight connection/history sync and BLEManager's separate Continuous HRV preference do
/// not flow through this policy.
struct ForegroundRealtimeLeasePolicy {
    enum Transition: Equatable {
        case none
        case arm
        case disarm
    }

    private(set) var leaseCount: Int = 0
    private(set) var isForeground: Bool
    private(set) var transportArmed: Bool = false

    /// Start closed until the owning scene explicitly reports `.active`. This prevents a restored
    /// workout/session from briefly arming the high-rate transport during cold-launch setup.
    init(isForeground: Bool = false) {
        self.isForeground = isForeground
    }

    var shouldArm: Bool { isForeground && leaseCount > 0 }

    mutating func requestLease() -> Transition {
        leaseCount += 1
        return reconcile()
    }

    mutating func releaseLease() -> Transition {
        leaseCount = max(0, leaseCount - 1)
        return reconcile()
    }

    mutating func setForeground(_ foreground: Bool) -> Transition {
        isForeground = foreground
        return reconcile()
    }

    private mutating func reconcile() -> Transition {
        let wanted = shouldArm
        guard wanted != transportArmed else { return .none }
        transportArmed = wanted
        return wanted ? .arm : .disarm
    }
}
