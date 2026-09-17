import Foundation

/// The band reports one `DOUBLE_TAP` event, not individual tap counts. This policy therefore counts
/// repeated double-tap events and never claims that the hardware can identify a literal triple tap.
struct SafetySOSGestureAccumulator {
    enum Result: Equatable {
        case progress(Int)
        case triggered
    }

    static let minimumEvents = 3
    static let maximumEvents = 4
    static let maximumGapSeconds: TimeInterval = 2.75

    private(set) var eventCount = 0
    private var lastEventUptime: TimeInterval?

    mutating func record(
        eventUptime: TimeInterval,
        requiredEvents: Int,
        maximumGapSeconds: TimeInterval = Self.maximumGapSeconds
    ) -> Result {
        let required = min(max(requiredEvents, Self.minimumEvents), Self.maximumEvents)
        guard eventUptime.isFinite, eventUptime >= 0,
              maximumGapSeconds.isFinite, maximumGapSeconds > 0
        else {
            reset()
            return .progress(0)
        }

        if let lastEventUptime {
            let gap = eventUptime - lastEventUptime
            if gap <= 0 || gap > maximumGapSeconds {
                eventCount = 0
            }
        }
        lastEventUptime = eventUptime
        eventCount += 1

        if eventCount >= required {
            reset()
            return .triggered
        }
        return .progress(eventCount)
    }

    mutating func reset() {
        eventCount = 0
        lastEventUptime = nil
    }
}

enum SafetySOSGesturePreferences {
    static let enabledKey = "safety.sosGesture.enabled"
    static let requiredEventsKey = "safety.sosGesture.requiredEvents"
    static let shareLocationKey = "safety.sosGesture.shareLocation"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var requiredEvents: Int {
        let stored = UserDefaults.standard.object(forKey: requiredEventsKey) as? Int ?? 4
        return min(
            max(stored, SafetySOSGestureAccumulator.minimumEvents),
            SafetySOSGestureAccumulator.maximumEvents
        )
    }

    static var sharesLocation: Bool {
        UserDefaults.standard.bool(forKey: shareLocationKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    static func setRequiredEvents(_ count: Int) {
        UserDefaults.standard.set(
            min(
                max(count, SafetySOSGestureAccumulator.minimumEvents),
                SafetySOSGestureAccumulator.maximumEvents
            ),
            forKey: requiredEventsKey
        )
    }

    static func setSharesLocation(_ sharesLocation: Bool) {
        UserDefaults.standard.set(sharesLocation, forKey: shareLocationKey)
    }
}
